#[compute]
#version 450

// ===========================================================================
// REGION CLEANUP SHADER
// ===========================================================================
// Phase de nettoyage agressif : assigne TOUTE terre non couverte à la région
// la plus proche, sans considération de coût. Garantit qu'aucun pixel terrestre
// ne reste sans région après la phase de croissance.
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
    uint padding;
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

// Voisinage étendu 8-connecté pour nettoyage agressif
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, 0),   // Gauche
    ivec2(1, 0),    // Droite
    ivec2(0, -1),   // Haut
    ivec2(0, 1),    // Bas
    ivec2(-1, -1),  // Haut-gauche
    ivec2(1, -1),   // Haut-droite
    ivec2(-1, 1),   // Bas-gauche
    ivec2(1, 1)     // Bas-droite
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
    
    // Pas encore assigné : chercher dans un rayon croissant
    uint assigned_region = 0xFFFFFFFFu;
    
    // D'abord voisins directs (8-connecté)
    for (int i = 0; i < 8; i++) {
        ivec2 neighbor_offset = NEIGHBORS[i];
        int nx = wrapX(pixel.x + neighbor_offset.x, w);
        int ny = clampY(pixel.y + neighbor_offset.y, h);
        
        if (nx == pixel.x && ny == pixel.y) continue;
        
        ivec2 neighbor_pos = ivec2(nx, ny);
        
        uint neighbor_water = imageLoad(water_mask, neighbor_pos).r;
        if (neighbor_water > 0u) continue;
        
        uint neighbor_region = imageLoad(region_map_in, neighbor_pos).r;
        
        if (neighbor_region != 0xFFFFFFFFu) {
            assigned_region = neighbor_region;
            break;
        }
    }
    
    // Si toujours pas trouvé, chercher dans un rayon de 2
    if (assigned_region == 0xFFFFFFFFu) {
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                if (dx == 0 && dy == 0) continue;
                
                int nx = wrapX(pixel.x + dx, w);
                int ny = clampY(pixel.y + dy, h);
                
                ivec2 neighbor_pos = ivec2(nx, ny);
                
                uint neighbor_water = imageLoad(water_mask, neighbor_pos).r;
                if (neighbor_water > 0u) continue;
                
                uint neighbor_region = imageLoad(region_map_in, neighbor_pos).r;
                
                if (neighbor_region != 0xFFFFFFFFu) {
                    assigned_region = neighbor_region;
                    break;
                }
            }
            if (assigned_region != 0xFFFFFFFFu) break;
        }
    }
    
    // Écrire le résultat (même si toujours non assigné, le prochain pass pourrait le résoudre)
    imageStore(region_map_out, pixel, uvec4(assigned_region, 0u, 0u, 0u));
    imageStore(region_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
}
