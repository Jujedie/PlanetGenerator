#[compute]
#version 450

// ===========================================================================
// REGION GROWTH SHADER (Dijkstra-like)
// ===========================================================================
// Propage les régions vers les pixels voisins non assignés avec système de coûts.
//
// Système de coûts :
//   - Terrain plat (même altitude ou descente) : coût = 1
//   - Altitude plus haute que le pixel courant : coût = 2
//   - Traverser une rivière (flux > seuil) : coût = 3
//
// Utilise un ping-pong sur region_cost / region_cost_temp.
//
// Entrées :
//   - geo_texture (binding 0) : R=height pour calcul de pente
//   - water_mask (binding 1) : masque eau (infranchissable)
//   - river_flux (binding 2) : flux des rivières (barrière naturelle)
//   - region_map_in (binding 3) : état actuel des régions
//   - region_cost_in (binding 4) : coûts accumulés actuels
//
// Sorties :
//   - region_map_out (binding 5) : nouveaux IDs de région
//   - region_cost_out (binding 6) : nouveaux coûts accumulés
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux;
layout(set = 0, binding = 3, r32ui) uniform readonly uimage2D region_map_in;
layout(set = 0, binding = 4, r32f) uniform readonly image2D region_cost_in;
layout(set = 0, binding = 5, r32ui) uniform writeonly uimage2D region_map_out;
layout(set = 0, binding = 6, r32f) uniform writeonly image2D region_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform GrowthParams {
    uint width;
    uint height;
    uint pass_index;
    uint seed;                 // Pour le bruit
    float sea_level;
    float river_threshold;     // Seuil de flux pour considérer comme rivière
    float cost_flat;           // Coût terrain plat (1.0)
    float cost_uphill;         // Coût montée (2.0)
    float cost_river;          // Coût traversée rivière (3.0)
    float noise_strength;      // Force du bruit (comme randf() * 10.0 du legacy)
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

float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

// Wrap X pour projection équirectangulaire (seamless horizontalement)
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// Voisinage 4-connecté (comme le legacy)
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
    
    // Lire l'état actuel de ce pixel
    uint current_region = imageLoad(region_map_in, pixel).r;
    float current_cost = imageLoad(region_cost_in, pixel).r;
    
    // Vérifier si c'est de l'eau (infranchissable)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        // Eau : copier tel quel (reste infranchissable)
        imageStore(region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire les données géographiques de ce pixel
    vec4 geo = imageLoad(geo_texture, pixel);
    float my_height = geo.r;
    float my_river_flux = imageLoad(river_flux, pixel).r;
    
    // Chercher le meilleur voisin (coût minimal)
    // Si le pixel est déjà assigné, il garde sa région (stable)
    // Si le pixel n'est PAS assigné, on cherche le voisin avec le meilleur coût
    bool is_assigned = (current_region != 0xFFFFFFFFu);
    uint best_region = current_region;
    float best_cost = current_cost;
    
    // Si PAS assigné, on accepte n'importe quel voisin valide
    if (!is_assigned) {
        best_region = 0xFFFFFFFFu;  // Reset pour trouver le meilleur voisin
        best_cost = 1e30;  // Reset pour trouver le minimum
    }
    
    for (int i = 0; i < 4; i++) {
        ivec2 neighbor_offset = NEIGHBORS[i];
        int nx = wrapX(pixel.x + neighbor_offset.x, w);
        int ny = clampY(pixel.y + neighbor_offset.y, h);
        
        // Ignorer si même pixel (après wrap)
        if (nx == pixel.x && ny == pixel.y) continue;
        
        ivec2 neighbor_pos = ivec2(nx, ny);
        
        // Vérifier que le voisin n'est pas de l'eau
        uint neighbor_water = imageLoad(water_mask, neighbor_pos).r;
        if (neighbor_water > 0u) continue;
        
        // Lire la région et le coût du voisin
        uint neighbor_region = imageLoad(region_map_in, neighbor_pos).r;
        float neighbor_cost = imageLoad(region_cost_in, neighbor_pos).r;
        
        // Si le voisin n'est pas assigné, il ne peut pas nous influencer
        if (neighbor_region == 0xFFFFFFFFu) continue;
        
        // Calculer le coût de traversée depuis le voisin vers nous
        vec4 neighbor_geo = imageLoad(geo_texture, neighbor_pos);
        float neighbor_height = neighbor_geo.r;
        
        // Coût de base : terrain plat
        float edge_cost = params.cost_flat;
        
        // Pénalité si on monte (notre altitude > altitude voisin)
        if (my_height > neighbor_height) {
            edge_cost = params.cost_uphill;
        }
        
        // Pénalité si on traverse une rivière (sur notre position)
        if (my_river_flux > params.river_threshold) {
            edge_cost += params.cost_river;
        }
        
        // Ajouter du bruit pour rendre les frontières irrégulières (comme legacy randf() * 10.0)
        // NOTE: Le bruit doit être CONSTANT par pixel (pas dépendre de pass_index)
        // sinon les frontières "bougent" et les régions ne peuvent pas s'étendre de manière stable
        uint noise_hash = hash3(uint(pixel.x), uint(pixel.y), params.seed);
        float noise = hashToFloat(noise_hash) * params.noise_strength;
        
        // Coût total pour atteindre ce pixel via ce voisin
        float total_cost = neighbor_cost + edge_cost + noise;
        
        // Si c'est meilleur, mettre à jour
        if (total_cost < best_cost) {
            best_cost = total_cost;
            best_region = neighbor_region;
        }
    }
    
    // Écrire le résultat
    imageStore(region_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
    imageStore(region_cost_out, pixel, vec4(best_cost, 0.0, 0.0, 0.0));
}
