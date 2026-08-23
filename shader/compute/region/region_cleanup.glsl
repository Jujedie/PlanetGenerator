#[compute]
#version 450

// ===========================================================================
// REGION CLEANUP SHADER
// ===========================================================================
// Phase de nettoyage connexe : propage uniquement depuis les quatre voisins
// terrestres directs. Aucun ID ne peut sauter par-dessus une mer.
//
// Entrées :
//   - water_mask (binding 0) : masque eau (reste infranchissable)
//   - region_map_in (binding 1) : état actuel des régions
//
// Sorties :
//   - region_map_out (binding 2) : régions après nettoyage
//   - region_cost_out (binding 3) : coûts fictifs (non utilisés)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D region_map_in;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D region_map_out;
layout(set = 0, binding = 3, r32f) uniform writeonly image2D region_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform CleanupParams {
    uint width;
    uint height;
    uint seed;
    float sea_level;
} params;

// === FONCTIONS UTILITAIRES ===

// Wrap X pour projection équirectangulaire
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x85ebca6bu;
    x ^= x >> 13u;
    x *= 0xc2b2ae35u;
    x ^= x >> 16u;
    return x;
}

const ivec2 NEIGHBORS[4] = ivec2[4](
    ivec2(-1, 0),   // Gauche
    ivec2(1, 0),    // Droite
    ivec2(0, -1),   // Haut
    ivec2(0, 1)     // Bas
);

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Vérifier si c'est de l'eau
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        // Eau : copier tel quel
        imageStore(region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire l'état actuel de ce pixel
    uint current_region = imageLoad(region_map_in, pixel).r;
    
    // Si déjà assigné, garder tel quel
    if (current_region != 0xFFFFFFFFu) {
        imageStore(region_map_out, pixel, uvec4(current_region, 0u, 0u, 0u));
        imageStore(region_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        return;
    }
    
    // Pas encore assigné : adopter seulement une région terrestre adjacente.
    uint assigned_region = 0xFFFFFFFFu;
    for (int i = 0; i < 4; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        ivec2 neighbor_pos = ivec2(nx, ny);
        if (imageLoad(water_mask, neighbor_pos).r > 0u) continue;
        uint neighbor_region = imageLoad(region_map_in, neighbor_pos).r;
        if (neighbor_region != 0xFFFFFFFFu &&
                (assigned_region == 0xFFFFFFFFu || neighbor_region < assigned_region)) {
            assigned_region = neighbor_region;
        }
    }

    // Si toute la composante était dépourvue de seed, ses minima locaux
    // déterministes démarrent des départements indépendants. Les passes
    // suivantes couvrent la composante sans jamais franchir la mer.
    if (assigned_region == 0xFFFFFFFFu) {
        uint linear = uint(pixel.y * w + pixel.x);
        uint my_hash = hash(linear ^ params.seed);
        bool local_minimum = true;
        for (int i = 0; i < 4; i++) {
            int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
            int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
            ivec2 neighbor_pos = ivec2(nx, ny);
            if (imageLoad(water_mask, neighbor_pos).r > 0u) continue;
            uint neighbor_linear = uint(ny * w + nx);
            uint neighbor_hash = hash(neighbor_linear ^ params.seed);
            if (neighbor_hash < my_hash ||
                    (neighbor_hash == my_hash && neighbor_linear < linear)) {
                local_minimum = false;
            }
        }
        if (local_minimum) assigned_region = linear;
    }
    
    // Écrire le résultat
    imageStore(region_map_out, pixel, uvec4(assigned_region, 0u, 0u, 0u));
    imageStore(region_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
}
