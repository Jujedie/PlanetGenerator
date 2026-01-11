#[compute]
#version 450

/*
 * Region Fill Orphans Shader
 * ==========================
 * Assigne les pixels non-assignés à la région voisine la plus proche.
 * Garantit qu'aucun pixel terrestre/océanique valide ne reste orphelin.
 * 
 * Entrées :
 *   - geo : GeoTexture (A=water_height)
 *   - region_state_in : État actuel
 * 
 * Sortie :
 *   - region_state_out : État avec orphelins remplis
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée
layout(rgba32f, binding = 0) uniform readonly image2D geo;
layout(rgba32f, binding = 1) uniform readonly image2D region_state_in;

// Texture de sortie
layout(rgba32f, binding = 2) uniform writeonly image2D region_state_out;

// Paramètres uniformes
layout(std140, binding = 3) uniform Params {
    int width;
    int height;
    int is_ocean_mode;
    int search_radius;      // Rayon de recherche pour voisin valide (défaut: 5)
};

// === FONCTIONS UTILITAIRES ===

int wrapX(int x) {
    return (x + width) % width;
}

int clampY(int y) {
    return clamp(y, 0, height - 1);
}

// Distance cyclique sur X
float cyclicDistX(int x1, int x2) {
    float dx = abs(float(x1 - x2));
    return min(dx, float(width) - dx);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
    
    // Lire l'état actuel
    vec4 state = imageLoad(region_state_in, pixel);
    float region_id = state.r;
    
    // Si déjà assigné, copier
    if (region_id >= 0.0) {
        imageStore(region_state_out, pixel, state);
        return;
    }
    
    // Vérifier si ce pixel devrait avoir une région
    vec4 geo_data = imageLoad(geo, pixel);
    float water_height = geo_data.a;
    bool valid_terrain = (is_ocean_mode == 0) ? (water_height <= 0.0) : (water_height > 0.0);
    
    if (!valid_terrain) {
        // Terrain invalide pour ce mode, garder non-assigné
        imageStore(region_state_out, pixel, state);
        return;
    }
    
    // Chercher le voisin assigné le plus proche
    float best_region = -1.0;
    float best_distance = 1e10;
    float best_cost = 1e10;
    
    for (int dy = -search_radius; dy <= search_radius; dy++) {
        for (int dx = -search_radius; dx <= search_radius; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            int nx = wrapX(pixel.x + dx);
            int ny = clampY(pixel.y + dy);
            
            if (pixel.y + dy < 0 || pixel.y + dy >= height) continue;
            
            vec4 neighbor_state = imageLoad(region_state_in, ivec2(nx, ny));
            float neighbor_region = neighbor_state.r;
            float neighbor_cost = neighbor_state.g;
            
            if (neighbor_region >= 0.0) {
                float dist = cyclicDistX(pixel.x, nx);
                dist = sqrt(dist * dist + float(dy * dy));
                
                if (dist < best_distance) {
                    best_distance = dist;
                    best_region = neighbor_region;
                    best_cost = neighbor_cost + dist;
                }
            }
        }
    }
    
    // Assigner à la région trouvée
    if (best_region >= 0.0) {
        imageStore(region_state_out, pixel, vec4(best_region, best_cost, 0.0, best_region));
    } else {
        // Toujours orphelin, garder pour la prochaine passe
        imageStore(region_state_out, pixel, state);
    }
}
