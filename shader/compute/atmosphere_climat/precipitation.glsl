#[compute]
#version 450

// ============================================================================
// PRECIPITATION SHADER - Zones par Bruit Pur
// ============================================================================
// Génère de grandes zones cohérentes (sèches ou humides) via bruit.
// AUCUN pattern latitudinal.
// avg_precipitation contrôle l'équilibre global sec/humide.
//
// Sortie : climate_texture.G = humidité [0, 1]
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform image2D climate_texture;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D precipitation_colored;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D geo_texture;

layout(set = 1, binding = 0, std140) uniform PrecipParams {
    uint seed;
    uint width;
    uint height;
    float avg_precipitation;  // [0, 1] - équilibre sec/humide global
    float cylinder_radius;
    uint atmosphere_type;
    float sea_level;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================
const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// HASH FUNCTIONS
// ============================================================================

// Hash pseudo-aléatoire déterministe
// Fonctionnement :
//   Prend un uint en entrée et retourne un uint "aléatoire"
//   Utilisé pour générer des variations basées sur la position et le seed global
//   Permet d'avoir des résultats reproductibles
uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

uint hash2(uint x, uint y) {
    return hash(x ^ hash(y));
}

uint hash3(uint x, uint y, uint z) {
    return hash(x ^ hash(y ^ hash(z)));
}

float rand(uint h) {
    return float(h) / 4294967295.0;
}

// ============================================================================
// GRADIENT NOISE 3D
// ============================================================================

vec3 grad3(uint h) {
    h = h % 12u;
    float u = h < 8u ? 1.0 : 0.0;
    float v = h < 4u ? 1.0 : (h == 12u || h == 14u ? 1.0 : 0.0);
    float a = ((h & 1u) == 0u) ? u : -u;
    float b = ((h & 2u) == 0u) ? v : -v;
    float c = ((h & 4u) == 0u) ? 0.0 : ((h & 8u) == 0u ? 1.0 : -1.0);
    return vec3(a, b, c);
}

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float gradientNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    ivec3 ii = ivec3(i) + ivec3(10000);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    uint h000 = hash3(ix, iy, iz);
    uint h100 = hash3(ix + 1u, iy, iz);
    uint h010 = hash3(ix, iy + 1u, iz);
    uint h110 = hash3(ix + 1u, iy + 1u, iz);
    uint h001 = hash3(ix, iy, iz + 1u);
    uint h101 = hash3(ix + 1u, iy, iz + 1u);
    uint h011 = hash3(ix, iy + 1u, iz + 1u);
    uint h111 = hash3(ix + 1u, iy + 1u, iz + 1u);
    
    vec3 g000 = grad3(h000);
    vec3 g100 = grad3(h100);
    vec3 g010 = grad3(h010);
    vec3 g110 = grad3(h110);
    vec3 g001 = grad3(h001);
    vec3 g101 = grad3(h101);
    vec3 g011 = grad3(h011);
    vec3 g111 = grad3(h111);
    
    float n000 = dot(g000, f - vec3(0, 0, 0));
    float n100 = dot(g100, f - vec3(1, 0, 0));
    float n010 = dot(g010, f - vec3(0, 1, 0));
    float n110 = dot(g110, f - vec3(1, 1, 0));
    float n001 = dot(g001, f - vec3(0, 0, 1));
    float n101 = dot(g101, f - vec3(1, 0, 1));
    float n011 = dot(g011, f - vec3(0, 1, 1));
    float n111 = dot(g111, f - vec3(1, 1, 1));
    
    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    float nxy0 = mix(nx00, nx10, u.y);
    float nxy1 = mix(nx01, nx11, u.y);
    
    return mix(nxy0, nxy1, u.z);
}

// Fractal Brownian Motion - retourne valeur dans [-1, 1]
float fbm(vec3 p, int octaves, float persistence, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 1.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * gradientNoise3D(p, seed_offset + uint(i) * 7919u);
        maxValue += amplitude;
        amplitude *= persistence;
        p *= lacunarity;
    }
    
    return value / maxValue;
}

// ============================================================================
// COORDONNÉES CYLINDRIQUES (seamless horizontal)
// ============================================================================

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    return vec3(
        cos(angle) * radius,
        (float(pixel.y) / float(h) - 0.5) * radius * 2.0,
        sin(angle) * radius
    );
}

// ============================================================================
// PALETTE COULEURS
// ============================================================================

vec4 getPrecipitationColor(float p) {
    // 0.0 = très sec (violet), 1.0 = très humide (bleu foncé)
    if (p <= 0.0) return vec4(0.694, 0.094, 0.706, 1.0);
    if (p <= 0.1) return vec4(0.553, 0.078, 0.565, 1.0);
    if (p <= 0.2) return vec4(0.424, 0.086, 0.635, 1.0);
    if (p <= 0.3) return vec4(0.290, 0.094, 0.686, 1.0);
    if (p <= 0.4) return vec4(0.322, 0.102, 0.757, 1.0);
    if (p <= 0.5) return vec4(0.173, 0.106, 0.773, 1.0);
    if (p <= 0.6) return vec4(0.114, 0.200, 0.827, 1.0);
    if (p <= 0.7) return vec4(0.141, 0.224, 0.859, 1.0);
    if (p <= 0.8) return vec4(0.110, 0.286, 0.808, 1.0);
    if (p <= 0.9) return vec4(0.122, 0.310, 0.878, 1.0);
    return vec4(0.192, 0.365, 0.890, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Sans atmosphère = sec
    if (params.atmosphere_type == 3u) {
        vec4 climate = imageLoad(climate_texture, pixel);
        imageStore(climate_texture, pixel, vec4(climate.r, 0.0, 0.0, 0.0));
        imageStore(precipitation_colored, pixel, getPrecipitationColor(0.0));
        return;
    }
    
    // Coordonnées cylindriques pour seamless wrap
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // =========================================================================
    // BRUIT MULTI-COUCHES INDÉPENDANTES
    // =========================================================================
    // Chaque couche a sa propre échelle, seed, et contribution
    // Ensemble elles créent une distribution riche qui couvre [0, 1]
    
    float total_weight = 0.0;
    float accumulated = 0.0;
    
    // --- COUCHE 1 : Continentale (très grandes masses, 2-3 sur la planète) ---
    float s1 = 0.15 / params.cylinder_radius;
    float n1 = fbm(coords * s1, 4, 0.5, 2.0, params.seed + 1000u);
    accumulated += n1 * 0.20;
    total_weight += 0.20;
    
    // --- COUCHE 2 : Régionale (5-8 zones par planète) ---
    float s2 = 0.4 / params.cylinder_radius;
    float n2 = fbm(coords * s2, 4, 0.5, 2.0, params.seed + 2000u);
    accumulated += n2 * 0.18;
    total_weight += 0.18;
    
    // --- COUCHE 3 : Sous-régionale ---
    float s3 = 0.8 / params.cylinder_radius;
    float n3 = fbm(coords * s3, 3, 0.5, 2.0, params.seed + 3000u);
    accumulated += n3 * 0.14;
    total_weight += 0.14;
    
    // --- COUCHE 4 : Locale majeure ---
    float s4 = 1.5 / params.cylinder_radius;
    float n4 = fbm(coords * s4, 3, 0.5, 2.0, params.seed + 4000u);
    accumulated += n4 * 0.12;
    total_weight += 0.12;
    
    // --- COUCHE 5 : Locale mineure ---
    float s5 = 2.5 / params.cylinder_radius;
    float n5 = fbm(coords * s5, 3, 0.5, 2.0, params.seed + 5000u);
    accumulated += n5 * 0.10;
    total_weight += 0.10;
    
    // --- COUCHE 6 : Mésoscale ---
    float s6 = 4.0 / params.cylinder_radius;
    float n6 = fbm(coords * s6, 2, 0.5, 2.0, params.seed + 6000u);
    accumulated += n6 * 0.08;
    total_weight += 0.08;
    
    // --- COUCHE 7 : Détail majeur ---
    float s7 = 7.0 / params.cylinder_radius;
    float n7 = fbm(coords * s7, 2, 0.5, 2.0, params.seed + 7000u);
    accumulated += n7 * 0.06;
    total_weight += 0.06;
    
    // --- COUCHE 8 : Détail mineur ---
    float s8 = 12.0 / params.cylinder_radius;
    float n8 = fbm(coords * s8, 2, 0.5, 2.0, params.seed + 8000u);
    accumulated += n8 * 0.05;
    total_weight += 0.05;
    
    // --- COUCHE 9 : Micro-variation 1 ---
    float s9 = 20.0 / params.cylinder_radius;
    float n9 = fbm(coords * s9, 2, 0.5, 2.0, params.seed + 9000u);
    accumulated += n9 * 0.04;
    total_weight += 0.04;
    
    // --- COUCHE 10 : Micro-variation 2 (haute fréquence) ---
    float s10 = 35.0 / params.cylinder_radius;
    float n10 = gradientNoise3D(coords * s10, params.seed + 10000u);
    accumulated += n10 * 0.03;
    total_weight += 0.03;
    
    // =========================================================================
    // NORMALISATION
    // =========================================================================
    // accumulated est dans [-total_weight, +total_weight] théoriquement
    // En pratique la somme de bruits tend vers une distribution plus centrée
    
    float noise = accumulated / total_weight;  // [-1, 1] approx
    
    // =========================================================================
    // TRANSFORMATION VERS [0, 1] - COURBE DE PUISSANCE
    // =========================================================================
    
    // 1. Le bruit FBM produit environ [-0.7, 0.7] en pratique
    //    On étire pour couvrir [-1, 1] réellement
    noise = noise * 1.5;
    
    // 2. Convertir vers [0, 1] et clamper
    float base = clamp(noise * 0.5 + 0.5, 0.0, 1.0);
    
    // 3. Appliquer avg_precipitation via courbe de puissance
    //    L'exposant contrôle la distribution globale :
    //      avg=0.0 → exp2(4)  = 16.0  → tout écrasé vers 0 (très sec)
    //      avg=0.2 → exp2(2.4) ≈ 5.3  → majorité sèche
    //      avg=0.5 → exp2(0)  = 1.0   → distribution linéaire (équilibre)
    //      avg=0.8 → exp2(-2.4) ≈ 0.19 → majorité humide
    //      avg=1.0 → exp2(-4) = 0.0625 → tout poussé vers 1 (très humide)
    float power = exp2((0.5 - params.avg_precipitation) * 8.0);
    float humidity = pow(base, power);
    
    // 4. Clamp de sécurité
    humidity = clamp(humidity, 0.0, 1.0);
    
    // =========================================================================
    // ÉCRITURE
    // =========================================================================
    
    vec4 climate = imageLoad(climate_texture, pixel);
    imageStore(climate_texture, pixel, vec4(climate.r, humidity, 0.0, 0.0));
    imageStore(precipitation_colored, pixel, getPrecipitationColor(humidity));
}
