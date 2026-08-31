#[compute]
#version 450

// ============================================================================
// GAS GIANT VELOCITY INIT — champ d'écoulement statique (curl-noise)
// ============================================================================
// Calcule un champ de vélocité 2D (vx, vy) à divergence nulle, combinant :
// - Des jets zonaux (vent moyen par bande de latitude, alternant de sens)
// - Des tourbillons multi-échelles (curl noise, 3 octaves)
//
// Ce champ est calculé UNE SEULE FOIS et sert ensuite à advecter le
// "colorant" (dye) sur plusieurs passes (gas_giant_advect.glsl), ce qui
// produit un véritable écoulement turbulent au lieu d'un simple warp
// statique : le curl noise est mathématiquement garanti sans divergence,
// donc il forme naturellement des tourbillons/cisaillements au lieu de
// simples taches.
//
// Sortie :
// - velocity_texture (RGBA32F) : R=vx, G=vy, B=vorticité locale (utilisée
//   par la passe finale pour détecter les tempêtes), A=inutilisé
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D velocity_texture;

layout(set = 1, binding = 0, std140) uniform VelocityParams {
    uint seed;
    uint width;
    uint height;
    float cylinder_radius;
    uint num_bands;
    float jet_strength;
    float eddy_strength;
    float padding1;
} params;

const float PI = 3.14159265359;

// ============================================================================
// BRUIT
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    return x;
}

uint hash3(uint x, uint y, uint z) {
    return hash(x ^ (y * 0x27d4eb2du) ^ (z * 0x165667b1u));
}

float hashFloat(uint x) {
    return float(hash(x)) / float(0xFFFFFFFFu);
}

float valueNoise3D(vec3 p, uint s) {
    ivec3 i = ivec3(floor(p));
    vec3 f = fract(p);
    vec3 u = f * f * (3.0 - 2.0 * f);

    float n000 = hashFloat(hash3(uint(i.x) + s, uint(i.y), uint(i.z)));
    float n100 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y), uint(i.z)));
    float n010 = hashFloat(hash3(uint(i.x) + s, uint(i.y + 1), uint(i.z)));
    float n110 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y + 1), uint(i.z)));
    float n001 = hashFloat(hash3(uint(i.x) + s, uint(i.y), uint(i.z + 1)));
    float n101 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y), uint(i.z + 1)));
    float n011 = hashFloat(hash3(uint(i.x) + s, uint(i.y + 1), uint(i.z + 1)));
    float n111 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y + 1), uint(i.z + 1)));

    float n00 = mix(n000, n100, u.x);
    float n10 = mix(n010, n110, u.x);
    float n01 = mix(n001, n101, u.x);
    float n11 = mix(n011, n111, u.x);

    float n0 = mix(n00, n10, u.y);
    float n1 = mix(n01, n11, u.y);

    return mix(n0, n1, u.z);
}

float fbm(vec3 p, int octaves, float persistence, float lacunarity, uint s) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float max_value = 0.0;

    for (int i = 0; i < octaves; i++) {
        value += valueNoise3D(p * frequency, s + uint(i) * 7919u) * amplitude;
        max_value += amplitude;
        amplitude *= persistence;
        frequency *= lacunarity;
    }

    return value / max_value;
}

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cyl_r) {
    float angle = float(pixel.x) / float(w) * 2.0 * PI;
    float y = float(pixel.y) / float(h);
    return vec3(cos(angle) * cyl_r, y * cyl_r * 2.0, sin(angle) * cyl_r);
}

// ============================================================================
// CURL NOISE — champ à divergence nulle (rotationnel)
// ============================================================================
// tangent_lon / tangent_lat sont les directions tangentes réelles à la
// surface du cylindre au point échantillonné : cela garde le champ cohérent
// avec le wrap horizontal seamless.
vec2 curlWarp(vec3 p, vec3 tangent_lon, vec3 tangent_lat, float freq, uint seed_offset, float eps) {
    vec3 pf = p * freq;

    float n_lat_p = fbm(pf + tangent_lat * eps, 4, 0.55, 2.0, seed_offset);
    float n_lat_m = fbm(pf - tangent_lat * eps, 4, 0.55, 2.0, seed_offset);
    float n_lon_p = fbm(pf + tangent_lon * eps, 4, 0.55, 2.0, seed_offset);
    float n_lon_m = fbm(pf - tangent_lon * eps, 4, 0.55, 2.0, seed_offset);

    float d_lat = (n_lat_p - n_lat_m) / (2.0 * eps);
    float d_lon = (n_lon_p - n_lon_m) / (2.0 * eps);

    return vec2(d_lat, -d_lon);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);
    if (pos.x >= w || pos.y >= h) return;

    float u = float(pos.x) / float(w);
    float v = float(pos.y) / float(h);
    float lat = (v - 0.5) * 2.0;
    float angle = u * 2.0 * PI;

    vec3 cyl = getCylindricalCoords(pos, params.width, params.height, params.cylinder_radius);
    vec3 tangent_lon = vec3(-sin(angle), 0.0, cos(angle));
    vec3 tangent_lat = vec3(0.0, 1.0, 0.0);

    float base_freq = 1.4 / params.cylinder_radius;

    vec2 flow_L = curlWarp(cyl, tangent_lon, tangent_lat, base_freq * 0.6, params.seed + 1000u, 0.6);
    vec2 flow_M = curlWarp(cyl, tangent_lon, tangent_lat, base_freq * 2.2, params.seed + 2000u, 0.35);
    vec2 flow_S = curlWarp(cyl, tangent_lon, tangent_lat, base_freq * 6.0, params.seed + 3000u, 0.18);

    vec2 eddy = (flow_L * 1.0 + flow_M * 0.6 + flow_S * 0.3) * params.eddy_strength;

    // Jet zonal moyen : alternance de sens par bande de latitude, magnitude
    // modulée par un bruit lent (comme les jet-streams réels des géantes gazeuses)
    float jet_phase = lat * float(params.num_bands) * PI * 0.5;
    float jet_sign = sin(jet_phase);
    float jet_mod = 0.6 + 0.4 * fbm(cyl * base_freq * 0.2, 3, 0.5, 2.0, params.seed + 5000u);
    float jet_speed = jet_sign * jet_mod * params.jet_strength;

    // vx = composante longitude (le jet souffle est/ouest), vy = composante latitude
    float vx = jet_speed + eddy.y;
    float vy = eddy.x;

    // Vorticité locale (les champs curl sont déjà rotationnels par construction,
    // leur norme donne directement une bonne mesure d'intensité tourbillonnaire)
    float vorticity_mag = length(flow_M) + length(flow_S) * 0.6;

    imageStore(velocity_texture, pos, vec4(vx, vy, vorticity_mag, 0.0));
}
