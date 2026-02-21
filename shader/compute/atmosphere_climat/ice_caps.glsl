#[compute]
#version 450

// ============================================================================
// ICE CAPS SHADER - Étape 3.4 : Génération des Banquises et Glaciers
// ============================================================================
// Génère la carte de glace basée sur :
// - Température négative (climate.R < 0)
// - FBM noise pour variations naturelles (évite les trous aléatoires)
// - Extension sur terre pour glaciers et calottes polaires
//
// Deux types de glace :
// - Banquise (sur eau) : glace flottante
// - Glaciers continentaux (sur terre) : calottes polaires, glaciers d'altitude
//
// Entrées :
// - geo_texture (R=height, A=water_height)
// - climate_texture (R=temperature)
//
// Sorties :
// - ice_caps_texture : RGBA8 (blanc=glace, transparent=pas de glace)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D ice_caps_texture;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D water_colored;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform IceParams {
    uint seed;
    uint width;
    uint height;
    float ice_probability;  // Probabilité de glace si conditions remplies (0.9 par défaut)
    uint atmosphere_type;
    float sea_level;        // Niveau de la mer (m) - seul critère fiable pour eau
    float padding2;
    float padding3;
} params;

// ============================================================================
// FONCTIONS UTILITAIRES - Hash déterministe
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

uint hash2D(uint x, uint y, uint seed) {
    return hash(x ^ hash(y ^ hash(seed)));
}

float rand(uint h) {
    return float(h) / 4294967295.0;
}

// ============================================================================
// FONCTIONS FBM - Bruit cohérent pour glace naturelle
// ============================================================================

// Value Noise 3D
float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    vec3 u = f * f * (3.0 - 2.0 * f);
    
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

// FBM multi-octaves
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

// Conversion coordonnées cylindriques
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h) {
    float PI = 3.14159265359;
    float TAU = 6.28318530718;
    float cylinder_radius = float(w) / TAU;
    
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * PI;
    
    return vec3(cx, cy, cz);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Couleurs de sortie
    vec4 ice_color = vec4(1.0, 1.0, 1.0, 1.0);   // Blanc opaque = glace
    vec4 no_ice_color = vec4(0.0, 0.0, 0.0, 0.0); // Transparent = pas de glace
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    
    float height = geo.r;
    float temperature = climate.r;
    
    // === Condition 1 : Présence d'eau (banquise = glace flottante uniquement) ===
    // On vérifie directement water_colored (source de vérité pour l'eau visible).
    // Ni geo.a (résidus d'érosion) ni sea_level seul ne suffisent.
    vec4 water = imageLoad(water_colored, pixel);
    if (water.a <= 0.0) {
        // Pas d'eau visible sur ce pixel = pas de banquise
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === Condition 2 : Température négative ===
    if (temperature > 0.0) {
        // Trop chaud = pas de glace
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === FBM Noise pour variations naturelles ===
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height);
    float cylinder_radius = float(params.width) / 6.28318530718;
    
    // Bruit à moyenne échelle pour variations de banquise
    float ice_noise = fbm(coords * (0.5 / cylinder_radius), 4, 0.6, 2.0, params.seed + 99999u);
    
    // Facteur de température : plus il fait froid, plus il y a de glace
    // -1°C  → peu de glace (seuil strict)
    // -5°C  → glace dense
    // -10°C → glace garantie
    float temp_factor = smoothstep(0.0, -5.0, temperature);
    
    // Seuil d'apparition de glace basé sur le bruit et la température
    // Plus il fait froid, plus le seuil est bas (plus de glace)
    float ice_threshold = mix(0.3, -0.5, temp_factor);
    
    bool has_ice = (ice_noise > ice_threshold);
    
    if (has_ice) {
        // Glace !
        imageStore(ice_caps_texture, pixel, ice_color);
    } else {
        // Pas de glace
        imageStore(ice_caps_texture, pixel, no_ice_color);
    }
}
