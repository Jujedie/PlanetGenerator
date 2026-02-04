#[compute]
#version 450

// ===========================================================================
// OCEAN REGION SEED PLACEMENT SHADER
// ===========================================================================
// Place des seeds de régions océaniques de manière probabiliste sur l'eau.
// Inverse du système terrestre : seeds uniquement sur water_type > 0.
//
// Entrées :
//   - geo_texture (binding 0) : R=height (pour référence profondeur)
//   - water_mask (binding 1) : masque eau (seulement où water_type > 0)
//
// Sorties :
//   - ocean_region_map (binding 2) : R32UI - ID région océanique (0xFFFFFFFF = non assigné)
//   - ocean_region_cost (binding 3) : R32F - Coût (0.0 pour seed, 1e30 sinon)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D ocean_region_map;
layout(set = 0, binding = 3, r32f) uniform writeonly image2D ocean_region_cost;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SeedParams {
    uint width;
    uint height;
    uint seed;
    float sea_level;
    float seed_probability;  // Probabilité par pixel d'être un seed
    float budget_variation;  // Variation du budget de case par région (non utilisé ici)
    uint nb_cases_region;    // Nombre de cases par région (pour info)
    uint padding;
} params;

// === FONCTIONS UTILITAIRES ===

// Hash pseudo-aléatoire déterministe
uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x85ebca6bu;
    x ^= x >> 13u;
    x *= 0xc2b2ae35u;
    x ^= x >> 16u;
    return x;
}

uint hash2(uint x, uint y) {
    return hash(x ^ (y * 1664525u + 1013904223u));
}

uint hash3(uint x, uint y, uint z) {
    return hash(hash2(x, y) ^ (z * 2654435761u));
}

float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Lire le type d'eau
    uint water_type = imageLoad(water_mask, pixel).r;
    
    // Valeurs par défaut : pas de région, coût infini
    uint region_id = 0xFFFFFFFFu;
    float cost = 1e30;
    
    // Seulement sur l'eau (inverse du système terrestre)
    if (water_type > 0u) {
        // Probabilité qu'un pixel eau soit un seed = 1 / nb_cases_region
        // Cela garantit qu'en moyenne il y a 1 seed par nb_cases_region pixels
        float seed_prob = 1.0 / float(params.nb_cases_region);
        
        // Déterminer si ce pixel devient un seed
        uint pixel_hash = hash3(uint(pixel.x), uint(pixel.y), params.seed);
        float rand_val = hashToFloat(pixel_hash);
        
        if (rand_val < seed_prob) {
            // Ce pixel est un seed : ID unique basé sur position
            region_id = uint(pixel.x) + uint(pixel.y) * params.width;
            cost = 0.0;  // Coût de départ
        }
    }
    // Sinon (terre) : reste non assigné avec coût infini
    
    imageStore(ocean_region_map, pixel, uvec4(region_id, 0u, 0u, 0u));
    imageStore(ocean_region_cost, pixel, vec4(cost, 0.0, 0.0, 0.0));
}
