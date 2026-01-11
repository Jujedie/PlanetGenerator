#[compute]
#version 450

/*
 * Region Growth Shader
 * ====================
 * Croissance itérative des régions par propagation de coût minimum.
 * Similaire à un Dijkstra multi-sources parallélisé.
 * 
 * Algorithme : Pour chaque pixel non-assigné, regarder les voisins.
 * Si un voisin appartient à une région dont le quota n'est pas atteint,
 * et que le coût total (voisin + traversée) est minimal, adopter cette région.
 * 
 * Entrées :
 *   - geo : GeoTexture (A=water_height)
 *   - cost_field : Champ de coût terrain
 *   - region_state_in : État actuel (ping)
 * 
 * Sortie :
 *   - region_state_out : État mis à jour (pong)
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée
layout(rgba32f, binding = 0) uniform readonly image2D geo;
layout(r32f, binding = 1) uniform readonly image2D cost_field;
layout(rgba32f, binding = 2) uniform readonly image2D region_state_in;

// Texture de sortie (ping-pong)
layout(rgba32f, binding = 3) uniform writeonly image2D region_state_out;

// Paramètres uniformes
layout(std140, binding = 4) uniform Params {
    int width;
    int height;
    int is_ocean_mode;      // 0 = terrestre, 1 = océanique
    int iteration;          // Numéro de l'itération actuelle
    float distance_weight;  // Poids de la distance dans le coût (défaut: 1.0)
    float padding1;
    float padding2;
    float padding3;
};

// Directions des 4 voisins (N, S, E, W)
const ivec2 NEIGHBORS[4] = ivec2[4](
    ivec2(0, -1),   // Nord
    ivec2(0, 1),    // Sud
    ivec2(1, 0),    // Est
    ivec2(-1, 0)    // Ouest
);

// === FONCTIONS UTILITAIRES ===

// Wrap X pour projection équirectangulaire
int wrapX(int x) {
    return (x + width) % width;
}

// Clamp Y (pas de wrap aux pôles)
int clampY(int y) {
    return clamp(y, 0, height - 1);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
    
    // Lire l'état actuel du pixel
    vec4 current_state = imageLoad(region_state_in, pixel);
    float current_region_id = current_state.r;
    float current_cost = current_state.g;
    
    // Si déjà assigné à une région, on ne change pas (sauf si on trouve un meilleur chemin)
    // Mais pour simplifier, on considère que les assignations sont définitives
    if (current_region_id >= 0.0) {
        imageStore(region_state_out, pixel, current_state);
        return;
    }
    
    // Lire les données géophysiques
    vec4 geo_data = imageLoad(geo, pixel);
    float water_height = geo_data.a;
    
    // Vérifier si le terrain correspond au mode
    bool valid_terrain = (is_ocean_mode == 0) ? (water_height <= 0.0) : (water_height > 0.0);
    
    if (!valid_terrain) {
        // Terrain invalide pour ce mode, marquer comme infranchissable
        imageStore(region_state_out, pixel, vec4(-2.0, 1e10, 0.0, -1.0));
        return;
    }
    
    // Lire le coût de traversée de ce pixel
    float traverse_cost = imageLoad(cost_field, pixel).r;
    
    // Chercher le meilleur voisin (coût minimum)
    float best_cost = 1e10;
    float best_region = -1.0;
    float best_parent = -1.0;
    
    for (int i = 0; i < 4; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x);
        int ny = clampY(pixel.y + NEIGHBORS[i].y);
        
        // Ignorer si on sort de la carte en Y
        if (pixel.y + NEIGHBORS[i].y < 0 || pixel.y + NEIGHBORS[i].y >= height) {
            continue;
        }
        
        ivec2 neighbor = ivec2(nx, ny);
        vec4 neighbor_state = imageLoad(region_state_in, neighbor);
        float neighbor_region = neighbor_state.r;
        float neighbor_cost = neighbor_state.g;
        
        // Si le voisin appartient à une région valide
        if (neighbor_region >= 0.0) {
            // Calculer le coût total pour rejoindre via ce voisin
            float total_cost = neighbor_cost + traverse_cost * distance_weight;
            
            if (total_cost < best_cost) {
                best_cost = total_cost;
                best_region = neighbor_region;
                best_parent = neighbor_region;  // Le parent au niveau supérieur sera calculé plus tard
            }
        }
    }
    
    // Si on a trouvé une région candidate
    if (best_region >= 0.0) {
        // Assigner ce pixel à la région
        // R=region_id, G=accumulated_cost, B=0 (sera mis à jour pour bordures), A=parent_region
        imageStore(region_state_out, pixel, vec4(best_region, best_cost, 0.0, best_parent));
    } else {
        // Pas de voisin valide, garder l'état non-assigné
        imageStore(region_state_out, pixel, current_state);
    }
}
