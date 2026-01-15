#[compute]
#version 450

// ===========================================================================
// REGION SEED PLACEMENT SHADER
// ===========================================================================
// Place les seeds de régions aléatoirement sur la terre uniquement.
// Chaque seed reçoit un budget de points basé sur nb_cases_region.
//
// Entrées :
//   - geo_texture (binding 0) : R=height pour déterminer terre/eau
//   - water_mask (binding 1) : masque eau (0=terre, 1/2=eau)
//
// Sorties :
//   - region_map (binding 2) : R32UI - ID de région (-1 = non assigné)
//   - region_cost (binding 3) : R32F - coût accumulé (INF = non assigné)
//   - region_seeds (binding 4) : RGBA32F - R=budget_remaining, G=origin_x, B=origin_y, A=is_active
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D region_map;
layout(set = 0, binding = 3, r32f) uniform writeonly image2D region_cost;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SeedParams {
    uint width;
    uint height;
    uint seed;
    uint nb_cases_region;      // Budget moyen par région
    float sea_level;
    float budget_variation;    // 0.5 = variation de ±50%
    float padding1;
    float padding2;
} params;

// === FONCTIONS UTILITAIRES ===

// Hash pseudo-aléatoire (Déterministe)
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

// Retourne un float dans [0, 1]
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
    
    // Vérifier si on est sur terre
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_water = (water_type > 0u);
    
    // Lire l'élévation
    vec4 geo = imageLoad(geo_texture, pixel);
    float height_val = geo.r;
    bool is_above_sea = (height_val >= params.sea_level);
    
    // Un pixel est sur terre s'il n'est pas marqué eau ET au-dessus du niveau de la mer
    bool is_land = !is_water && is_above_sea;
    
    // Initialiser avec valeurs par défaut
    // region_map = 0xFFFFFFFF (invalide)
    // region_cost = +INF (pas encore atteint)
    
    if (!is_land) {
        // Eau : marquer comme infranchissable
        imageStore(region_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Décider si ce pixel est un seed de région
    // On utilise une grille spatiale pour espacer les seeds
    // La taille de cellule est calculée pour avoir environ (W*H/2) / nb_cases_region régions
    
    // Estimation du nombre de régions attendues
    float land_area_estimate = float(w * h) * 0.35;  // ~35% de terre (approximatif)
    float num_regions_expected = land_area_estimate / float(params.nb_cases_region);
    
    // Taille de grille pour espacer les seeds
    float grid_cell_size = sqrt(land_area_estimate / max(num_regions_expected, 1.0));
    int cell_size = max(int(grid_cell_size), 1);
    
    // Position dans la grille
    int cell_x = pixel.x / cell_size;
    int cell_y = pixel.y / cell_size;
    
    // Hash pour cette cellule de grille
    uint cell_hash = hash3(uint(cell_x), uint(cell_y), params.seed);
    
    // Position "élue" dans cette cellule (Poisson-like simple)
    int elected_x = (cell_x * cell_size) + int(cell_hash % uint(cell_size));
    int elected_y = (cell_y * cell_size) + int((cell_hash >> 8) % uint(cell_size));
    
    // Ce pixel est-il le représentant élu de sa cellule ?
    bool is_seed = (pixel.x == elected_x && pixel.y == elected_y);
    
    if (is_seed) {
        // Ce pixel est un seed de région !
        // Calculer un ID unique basé sur la position (pour couleur déterministe)
        uint region_id = hash2(uint(pixel.x), uint(pixel.y));
        
        // Calculer le budget avec variation
        float base_budget = float(params.nb_cases_region);
        float variation = (hashToFloat(hash(region_id)) - 0.5) * 2.0 * params.budget_variation;
        float budget = base_budget * (1.0 + variation);
        budget = max(budget, 10.0);  // Minimum 10 cases par région
        
        // Écrire le seed
        imageStore(region_map, pixel, uvec4(region_id, 0u, 0u, 0u));
        imageStore(region_cost, pixel, vec4(0.0, 0.0, 0.0, 0.0));  // Coût 0 au départ
    } else {
        // Pixel terre normal : en attente d'assignation
        imageStore(region_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
    }
}
