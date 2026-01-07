#[compute]
#version 450

// ============================================================================
// ICE CAPS SHADER - Étape 3.4 : Génération des Banquises
// ============================================================================
// Génère la carte des banquises basée sur :
// - Présence d'eau (geo.A > 0)
// - Température négative (climate.R < 0)
// - Probabilité déterministe via hash (90% de glace)
//
// Reproduit la logique de BanquiseMapGenerator.gd
//
// Entrées :
// - geo_texture (A=water_height)
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

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform IceParams {
    uint seed;
    uint width;
    uint height;
    float ice_probability;  // Probabilité de glace si conditions remplies (0.9 par défaut)
    uint atmosphere_type;
    float padding1;
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
    
    float water_height = geo.a;
    float temperature = climate.r;
    
    // === Condition 1 : Présence d'eau ===
    if (water_height <= 0.0) {
        // Pas d'eau = pas de banquise
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === Condition 2 : Température négative ===
    if (temperature >= 0.0) {
        // Trop chaud = pas de glace
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === Condition 3 : Probabilité déterministe ===
    // Reproduit le comportement de BanquiseMapGenerator :
    // if randf() < 0.9 -> glace
    
    uint h = hash2D(uint(pixel.x), uint(pixel.y), params.seed);
    float random_val = rand(h);
    
    if (random_val < params.ice_probability) {
        // Glace !
        imageStore(ice_caps_texture, pixel, ice_color);
    } else {
        // Eau libre (10% de probabilité par défaut)
        imageStore(ice_caps_texture, pixel, no_ice_color);
    }
}
