#[compute]
#version 450

/*
 * Region Boundaries Shader
 * ========================
 * Post-traitement des frontières des régions.
 * Détecte les bordures et applique de l'irrégularité via swap local.
 * 
 * Similaire au comportement de BiomeMapGenerator._add_border_irregularity()
 * 
 * Entrées :
 *   - region_state_in : État des régions après croissance
 * 
 * Sortie :
 *   - region_state_out : État avec frontières marquées et potentiellement modifiées
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée/sortie
layout(rgba32f, binding = 0) uniform readonly image2D region_state_in;
layout(rgba32f, binding = 1) uniform image2D region_state_out;

// Paramètres uniformes
layout(std140, binding = 2) uniform Params {
    int width;
    int height;
    uint seed;              // Graine pour randomisation
    float swap_probability; // Probabilité de swap sur les bordures (défaut: 0.3)
    int smoothing_passes;   // Nombre de passes de lissage (défaut: 2)
    int current_pass;       // Passe actuelle
    float padding1;
    float padding2;
};

// Directions 8 voisins
const ivec2 NEIGHBORS_8[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1, 0),                ivec2(1, 0),
    ivec2(-1, 1),  ivec2(0, 1),  ivec2(1, 1)
);

// === FONCTIONS UTILITAIRES ===

int wrapX(int x) {
    return (x + width) % width;
}

int clampY(int y) {
    return clamp(y, 0, height - 1);
}

// Hash pour pseudo-random
float hash31(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
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
    float cost = state.g;
    float is_border = state.b;
    float parent_id = state.a;
    
    // Si non-assigné ou invalide, copier tel quel
    if (region_id < 0.0) {
        imageStore(region_state_out, pixel, state);
        return;
    }
    
    // Compter les voisins de même région et détecter les bordures
    int same_region_count = 0;
    float different_region = -1.0;
    int different_count = 0;
    
    // Structure pour vote majoritaire
    float neighbor_regions[8];
    int neighbor_count = 0;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS_8[i].x);
        int ny = pixel.y + NEIGHBORS_8[i].y;
        
        if (ny < 0 || ny >= height) {
            continue;
        }
        
        vec4 neighbor_state = imageLoad(region_state_in, ivec2(nx, ny));
        float neighbor_region = neighbor_state.r;
        
        if (neighbor_region >= 0.0) {
            neighbor_regions[neighbor_count++] = neighbor_region;
            
            if (abs(neighbor_region - region_id) < 0.5) {
                same_region_count++;
            } else {
                different_count++;
                different_region = neighbor_region;
            }
        }
    }
    
    // Détecter si c'est une bordure
    bool is_border_pixel = (different_count > 0);
    
    // Lissage : vote majoritaire (protège les régions petites)
    if (current_pass < smoothing_passes && neighbor_count >= 5) {
        // Compter les occurrences de chaque région voisine
        float most_common = region_id;
        int max_count = same_region_count;
        
        for (int i = 0; i < neighbor_count; i++) {
            float test_region = neighbor_regions[i];
            int count = 0;
            for (int j = 0; j < neighbor_count; j++) {
                if (abs(neighbor_regions[j] - test_region) < 0.5) {
                    count++;
                }
            }
            if (count > max_count) {
                max_count = count;
                most_common = test_region;
            }
        }
        
        // Si une autre région est plus présente (vote > 5/8), changer
        if (max_count > 5 && abs(most_common - region_id) > 0.5) {
            region_id = most_common;
            parent_id = most_common;
        }
    }
    
    // Irrégularité des bordures : swap aléatoire
    if (is_border_pixel && different_region >= 0.0 && current_pass >= smoothing_passes) {
        float rand_val = hash31(vec3(float(pixel.x), float(pixel.y), float(seed + current_pass)));
        
        if (rand_val < swap_probability) {
            // Échanger avec la région voisine
            region_id = different_region;
            parent_id = different_region;
        }
    }
    
    // Écrire l'état mis à jour
    imageStore(region_state_out, pixel, vec4(region_id, cost, is_border_pixel ? 1.0 : 0.0, parent_id));
}
