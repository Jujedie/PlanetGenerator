#[compute]
#version 450

// ============================================================================
// WATER CONNECTED COMPONENTS - Local Propagation + Pointer Jumping
// ============================================================================
// Algorithme correct en O(log n) passes :
//
// ÉTAPE 1 : Regarder les 8 voisins DIRECTS (distance=1) et prendre le minimum
//           Cela garantit qu'on ne connecte que des pixels vraiment adjacents
//
// ÉTAPE 2 : Pointer Jumping - "sauter" vers le pixel indiqué par notre label
//           et prendre SON label. Cela accélère la convergence sans créer
//           de fausses connexions car on suit une chaîne déjà établie.
//
// Après log2(N) passes, tous les pixels d'une composante ont le même label.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D component_input;
layout(set = 0, binding = 1, rg32i) uniform writeonly iimage2D component_output;
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

layout(set = 1, binding = 0, std140) uniform JFAParams {
    uint width;
    uint height;
    int step_size;   // Ignoré
    uint pass_index;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// 8 voisins directs pour connectivité
const ivec2 NEIGHBORS_8[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// ============================================================================
// FONCTIONS
// ============================================================================

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Si pas de l'eau, (-1, -1)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type == 0u) {
        imageStore(component_output, pixel, ivec4(-1, -1, 0, 0));
        return;
    }
    
    // Lire le label actuel
    int my_label = imageLoad(component_input, pixel).x;
    
    if (my_label < 0) {
        my_label = pixel.y * w + pixel.x;
    }
    
    int best_label = my_label;
    
    // =========================================================================
    // ÉTAPE 1 : Propagation locale - voisins DIRECTS uniquement
    // =========================================================================
    // Ceci garantit qu'on ne connecte que des pixels vraiment adjacents par eau
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS_8[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS_8[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);
        
        // Vérifier que le voisin est de l'eau
        uint n_water = imageLoad(water_mask, neighbor).r;
        if (n_water == 0u) {
            continue;
        }
        
        int n_label = imageLoad(component_input, neighbor).x;
        if (n_label >= 0 && n_label < best_label) {
            best_label = n_label;
        }
    }
    
    // =========================================================================
    // ÉTAPE 2 : Pointer Jumping - accélère la convergence
    // =========================================================================
    // On "saute" vers le pixel dont l'ID est notre label actuel, et on prend
    // SON label. Cela ne crée PAS de fausses connexions car on suit une chaîne
    // de labels qui a été établie par propagation locale précédente.
    //
    // Répéter plusieurs fois pour une convergence plus rapide
    
    for (int jump = 0; jump < 3; jump++) {
        if (best_label >= 0) {
            int target_x = best_label % w;
            int target_y = best_label / w;
            
            int target_label = imageLoad(component_input, ivec2(target_x, target_y)).x;
            
            if (target_label >= 0 && target_label < best_label) {
                best_label = target_label;
            }
        }
    }
    
    imageStore(component_output, pixel, ivec4(best_label, 0, 0, 0));
}
