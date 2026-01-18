#[compute]
#version 450

// ============================================================================
// PRECIPITATION SHADER - Étape 3.2 : Calcul d'Humidité/Précipitations
// ============================================================================
// Génère la carte de précipitations basée sur :
// - Combinaison de 3 bruits (main, detail, cellular)
// - Influence de la latitude (ITCZ, déserts subtropicaux, pôles secs)
// - Scaling global via avg_precipitation
//
// Entrées :
// - geo_texture (R=height pour effet orographique futur)
// - climate_texture (R=temperature en lecture)
// - Paramètres UBO
//
// Sorties :
// - climate_texture.G = humidité normalisée [0, 1]
// - precipitation_colored = couleur finale RGBA8 (palette Enum.gd)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture entrée/sortie : ClimateTexture (lit R=temp, écrit G=humidity)
layout(set = 0, binding = 0, rgba32f) uniform image2D climate_texture;

// Texture de sortie colorée : RGBA8 pour export direct
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D precipitation_colored;

// GeoTexture en lecture seule pour effet orographique
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D geo_texture;

// Uniform Buffer : Paramètres de génération
layout(set = 1, binding = 0, std140) uniform PrecipParams {
    uint seed;              // Graine de génération
    uint width;             // Largeur texture
    uint height;            // Hauteur texture
    float avg_precipitation;// Facteur global humidité [0, 1]
    float cylinder_radius;  // width / (2*PI) pour bruit seamless
    uint atmosphere_type;   // 0=Terre, 1=Toxique, 2=Volcanique, 3=Sans atm
    float sea_level;        // Niveau de la mer pour effet orographique
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// FONCTIONS UTILITAIRES - Hash et Bruit
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

float rand(uint h) {
    return float(h) / 4294967295.0;
}

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Value Noise 3D
float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    const float BIG_OFFSET = 10000.0;
    ivec3 ii = ivec3(i + BIG_OFFSET);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    float c000 = rand(hash(ix ^ hash(iy ^ hash(iz))));
    float c100 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz))));
    float c010 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz))));
    float c110 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz))));
    float c001 = rand(hash(ix ^ hash(iy ^ hash(iz+1u))));
    float c101 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz+1u))));
    float c011 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz+1u))));
    float c111 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz+1u))));
    
    float x00 = mix(c000, c100, u.x);
    float x10 = mix(c010, c110, u.x);
    float x01 = mix(c001, c101, u.x);
    float x11 = mix(c011, c111, u.x);
    
    float xy0 = mix(x00, x10, u.y);
    float xy1 = mix(x01, x11, u.y);
    
    return mix(xy0, xy1, u.z) * 2.0 - 1.0;
}

// fBm classique
float fbm(vec3 p, int octaves, float gain, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * valueNoise3D(p * frequency, seed_offset + uint(i) * 1000u);
        maxValue += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value / maxValue;
}

// Cellular Noise pour fronts météo
float cellularNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist = 1.0;
    
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                const float BIG_OFFSET = 10000.0;
                ivec3 ii = ivec3(i + neighbor + BIG_OFFSET);
                uint h = hash(uint(ii.x) + seed_offset ^ hash(uint(ii.y) ^ hash(uint(ii.z))));
                vec3 point = neighbor + vec3(rand(h), rand(hash(h + 1u)), rand(hash(h + 2u))) - f;
                float dist = length(point);
                minDist = min(minDist, dist);
            }
        }
    }
    
    return minDist;
}

// Simplex noise (3D) - Ashima implementation (used for two simplex noises)
vec3 mod289(vec3 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 1.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(vec3 v) {
    const vec2 C = vec2(1.0/6.0, 1.0/3.0);
    const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
    // First corner
    vec3 i = floor(v + dot(v, vec3(C.y)));
    vec3 x0 = v - i + dot(i, vec3(C.x));
    // Other corners
    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);
    vec3 x1 = x0 - i1 + vec3(C.x);
    vec3 x2 = x0 - i2 + vec3(2.0 * C.x);
    vec3 x3 = x0 - 1.0 + vec3(3.0 * C.x);
    // Permutations
    i = mod289(i);
    vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0))
        + i.y + vec4(0.0, i1.y, i2.y, 1.0))
        + i.x + vec4(0.0, i1.x, i2.x, 1.0));
    // Gradients
    float n_ = 1.0/7.0;
    vec3 ns = n_ * D.wyz - D.xzx;
    vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
    vec4 x_ = floor(j * ns.z);
    vec4 y_ = floor(j - 7.0 * x_);
    vec4 x = x_ * ns.x + ns.y;
    vec4 y = y_ * ns.x + ns.y;
    vec4 h = 1.0 - abs(x) - abs(y);
    vec4 b0 = vec4(x.xy, y.xy);
    vec4 b1 = vec4(x.zw, y.zw);
    vec4 s0 = floor(b0) * 2.0 + 1.0;
    vec4 s1 = floor(b1) * 2.0 + 1.0;
    vec4 sh = -step(h, vec4(0.0));
    vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    vec3 p0 = vec3(a0.x, a0.y, h.x);
    vec3 p1 = vec3(a0.z, a0.w, h.y);
    vec3 p2 = vec3(a1.x, a1.y, h.z);
    vec3 p3 = vec3(a1.z, a1.w, h.w);
    // Normalise gradients
    vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;
    // Mix contributions
    vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

// ============================================================================
// CONVERSION COORDONNÉES
// ============================================================================

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// PALETTE DE COULEURS PRÉCIPITATION (Hard-coded depuis Enum.gd)
// 8 seuils de 0.0 à 1.0
// ============================================================================

vec4 getPrecipitationColor(float precip) {
    // Palette extraite de COULEUR_PRECIPITATION dans Enum.gd
    // 0.0 = très sec (violet), 1.0 = très humide (bleu)
    
    if (precip <= 0.0) return vec4(0.694, 0.094, 0.706, 1.0); // 0xb118b4
    if (precip <= 0.1) return vec4(0.553, 0.078, 0.565, 1.0); // 0x8d1490
    if (precip <= 0.2) return vec4(0.424, 0.086, 0.635, 1.0); // 0x6c16a2
    if (precip <= 0.3) return vec4(0.290, 0.094, 0.686, 1.0); // 0x4a18af
    if (precip <= 0.4) return vec4(0.173, 0.106, 0.773, 1.0); // 0x2c1bc5
    if (precip <= 0.5) return vec4(0.114, 0.200, 0.827, 1.0); // 0x1d33d3
    if (precip <= 0.7) return vec4(0.122, 0.310, 0.878, 1.0); // 0x1f4fe0
    return vec4(0.208, 0.514, 0.890, 1.0); // 0x3583e3 (1.0)
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérifier les limites
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Skip pour planètes sans atmosphère
    if (params.atmosphere_type == 3u) {
        // Lire la température existante
        vec4 climate = imageLoad(climate_texture, pixel);
        // Écrire humidité = 0
        imageStore(climate_texture, pixel, vec4(climate.r, 0.0, 0.0, 0.0));
        imageStore(precipitation_colored, pixel, getPrecipitationColor(0.0));
        return;
    }
    
    // Coordonnées cylindriques pour le bruit seamless
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // Latitude normalisée [0, 1] : 0 = équateur, 1 = pôles
    float latitude = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;
    
    // === 1. Combine three noises (1 Perlin-FBM + 2 simplex) ===
    float noise_freq_main = 2.5 / params.cylinder_radius;
    float main_value = fbm(coords * noise_freq_main, 6, 0.5, 2.0, params.seed + 50000u);
    main_value = (main_value + 1.0) * 0.5; // Normaliser [0, 1]

    float noise_freq_s1 = 4.0 / params.cylinder_radius;
    float s1 = snoise(coords * noise_freq_s1 + vec3(float(params.seed + 60000u)));
    s1 = (s1 + 1.0) * 0.5; // Normaliser [0, 1]

    float noise_freq_s2 = 8.0 / params.cylinder_radius;
    float s2 = snoise(coords * noise_freq_s2 + vec3(float(params.seed + 70000u)));
    s2 = (s2 + 1.0) * 0.5; // Normaliser [0, 1]

    // Pondérations : main influence forte, deux simplex moins influents
    float value = clamp(main_value * 0.7 + s1 * 0.15 + s2 * 0.15, 0.0, 1.0);

    // Application du facteur global d'humidité
    value *= params.avg_precipitation;
    value = clamp(value, 0.0, 1.0);

    // === 8. Écriture des résultats ===    
    // === 8. Écriture des résultats ===
    
    // Lire la température existante
    vec4 climate = imageLoad(climate_texture, pixel);
    
    // Écrire humidité dans canal G
    imageStore(climate_texture, pixel, vec4(climate.r, value, 0.0, 0.0));
    
    // Texture colorée pour export direct
    vec4 color = getPrecipitationColor(value);
    imageStore(precipitation_colored, pixel, color);
}
