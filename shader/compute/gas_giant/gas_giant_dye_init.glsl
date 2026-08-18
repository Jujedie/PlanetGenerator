#[compute]
#version 450

// ============================================================================
// GAS GIANT DYE INIT — colorant initial (bandes de couleur) avant advection
// ============================================================================
// Peint les bandes de couleur de base, AVANT tout écoulement. Ce "colorant"
// sera ensuite étiré/tourbillonné par gas_giant_advect.glsl le long du champ
// de vélocité calculé dans gas_giant_velocity_init.glsl.
//
// La sélection d'une famille de couleurs cohérente est une fonction pure du
// seed. Les familles ne sont pas croisées : un mélange arbitraire de teintes
// chaudes et violettes produisait parfois des palettes rose néon.
//
// Sortie :
// - dye_texture (RGBA32F) : RGB = couleur initiale, A = densité (1.0)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D dye_texture;

layout(set = 1, binding = 0, std140) uniform DyeParams {
    uint seed;
    uint width;
    uint height;
    uint num_bands;
    float cylinder_radius;
    float avg_temperature;
    float padding1;
    float padding2;
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

    return mix(mix(n00, n10, u.y), mix(n01, n11, u.y), u.z);
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
// PALETTES (doivent rester identiques à gas_giant_final.glsl)
// ============================================================================

const vec3 SCHEME_0[8] = vec3[8](vec3(0.82,0.68,0.50),vec3(0.76,0.52,0.32),vec3(0.90,0.78,0.62),vec3(0.70,0.45,0.28),vec3(0.85,0.72,0.55),vec3(0.60,0.38,0.22),vec3(0.92,0.85,0.72),vec3(0.75,0.55,0.35));
const vec3 SCHEME_1[8] = vec3[8](vec3(0.15,0.30,0.62),vec3(0.22,0.40,0.72),vec3(0.30,0.50,0.80),vec3(0.12,0.25,0.55),vec3(0.25,0.42,0.70),vec3(0.18,0.35,0.65),vec3(0.35,0.55,0.82),vec3(0.20,0.38,0.68));
const vec3 SCHEME_2[8] = vec3[8](vec3(0.85,0.78,0.55),vec3(0.75,0.68,0.42),vec3(0.92,0.85,0.65),vec3(0.68,0.60,0.38),vec3(0.80,0.72,0.50),vec3(0.72,0.62,0.40),vec3(0.88,0.82,0.60),vec3(0.78,0.70,0.48));
const vec3 SCHEME_3[8] = vec3[8](vec3(0.40,0.72,0.70),vec3(0.30,0.62,0.60),vec3(0.50,0.78,0.75),vec3(0.25,0.55,0.55),vec3(0.45,0.70,0.68),vec3(0.35,0.65,0.62),vec3(0.55,0.80,0.78),vec3(0.32,0.60,0.58));
const vec3 SCHEME_4[8] = vec3[8](vec3(0.72,0.38,0.25),vec3(0.62,0.30,0.18),vec3(0.80,0.50,0.35),vec3(0.55,0.25,0.15),vec3(0.75,0.42,0.28),vec3(0.58,0.28,0.16),vec3(0.85,0.55,0.40),vec3(0.65,0.35,0.22));
const vec3 SCHEME_5[8] = vec3[8](vec3(0.55,0.45,0.70),vec3(0.45,0.35,0.62),vec3(0.65,0.55,0.78),vec3(0.40,0.30,0.58),vec3(0.58,0.48,0.72),vec3(0.48,0.38,0.65),vec3(0.70,0.60,0.82),vec3(0.52,0.42,0.68));

vec3 getSchemeColor(uint scheme, int band_index) {
    int idx = band_index % 8;
    switch (scheme) {
        case 0u: return SCHEME_0[idx];
        case 1u: return SCHEME_1[idx];
        case 2u: return SCHEME_2[idx];
        case 3u: return SCHEME_3[idx];
        case 4u: return SCHEME_4[idx];
        case 5u: return SCHEME_5[idx];
        default: return SCHEME_0[idx];
    }
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);
    if (pos.x >= w || pos.y >= h) return;

    float v = float(pos.y) / float(h);
    float lat = (v - 0.5) * 2.0;

    vec3 cyl = getCylindricalCoords(pos, params.width, params.height, params.cylinder_radius);
    float base_freq = 1.4 / params.cylinder_radius;

    // Une seule famille atmosphérique par planète. La variation de luminosité
    // reste modérée afin de conserver des couleurs de nuages plausibles.
    const uint NUM_SCHEMES = 6u;
    uint scheme_hash = hash(params.seed + 77777u);
    uint scheme = scheme_hash % NUM_SCHEMES;
    float palette_exposure = mix(0.90, 1.02, hashFloat(params.seed + 88888u));

    // Largeur de bande légèrement modulée pour éviter la répétition parfaite
    float width_noise = fbm(cyl * base_freq * 0.15, 3, 0.5, 2.0, params.seed + 9000u);
    float band_freq_mod = float(params.num_bands) * PI * (0.85 + 0.3 * width_noise);

    float band_value = sin(lat * band_freq_mod);
    float band_continuous = (lat + 1.0) * 0.5 * float(params.num_bands);
    int band_index_a = int(floor(band_continuous)) % int(params.num_bands);
    int band_index_b = (band_index_a + 1) % int(params.num_bands);

    vec3 color_a = getSchemeColor(scheme, band_index_a);
    vec3 color_b = getSchemeColor(scheme, band_index_b);
    float blend = smoothstep(-0.3, 0.3, band_value);
    vec3 color = mix(color_a, color_b, blend) * palette_exposure;

    // Petit grain de texture initial : c'est ce grain que l'advection va
    // étirer en filaments cohérents au fil des itérations.
    float grain = fbm(cyl * base_freq * 5.0, 3, 0.5, 2.0, params.seed + 6000u);
    color += vec3((grain - 0.5) * 0.045);

    imageStore(dye_texture, pos, vec4(clamp(color, 0.02, 0.92), 1.0));
}
