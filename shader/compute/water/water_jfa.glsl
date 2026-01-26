#[compute]
#version 450

// ============================================================================
// WATER JFA SHADER - Jump Flooding Algorithm pour composantes connexes
// ============================================================================
// Propage les seeds pour regrouper les pixels d'eau en composantes connexes.
// Chaque pixel d'eau finit par pointer vers un unique pixel "représentant"
// de sa composante, permettant ensuite de compter la taille.
//
// Entrées :
// - water_component_input (RG32I) : Seeds actuels
// - water_mask (R8UI) : Masque d'eau (pour savoir quels pixels sont de l'eau)
//
// Sorties :
// - water_component_output (RG32I) : Seeds mis à jour après une passe JFA
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Composantes entrée (ping)
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D component_input;

// Composantes sortie (pong)
layout(set = 0, binding = 1, rg32i) uniform writeonly iimage2D component_output;

// Masque d'eau pour vérifier la connectivité
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform JFAParams {
    uint width;      // Largeur texture
    uint height;     // Hauteur texture
    int step_size;   // Taille du pas JFA (diminue à chaque passe : W/2, W/4, ..., 1)
    uint pass_index; // Index de la passe (pour debug)
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// 8 directions + self pour JFA
const ivec2 JFA_OFFSETS[9] = ivec2[9](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0), ivec2(0,  0), ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Distance au carré entre deux points (avec wrap X)
float distanceSquared(ivec2 a, ivec2 b, int w) {
    int dx = abs(a.x - b.x);
    dx = min(dx, w - dx);  // Wrap horizontal
    int dy = a.y - b.y;
    return float(dx * dx + dy * dy);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    // Vérification des limites
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Si ce n'est pas de l'eau, conserver (-1, -1)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type == 0u) {
        imageStore(component_output, pixel, ivec4(-1, -1, 0, 0));
        return;
    }
    
    // Lire le seed actuel
    ivec2 current_seed = imageLoad(component_input, pixel).xy;
    float current_dist = (current_seed.x >= 0) ? distanceSquared(pixel, current_seed, w) : 1e10;
    
    ivec2 best_seed = current_seed;
    float best_dist = current_dist;
    
    // Parcourir les 9 directions JFA
    for (int i = 0; i < 9; i++) {
        ivec2 offset = JFA_OFFSETS[i] * params.step_size;
        int nx = wrapX(pixel.x + offset.x, w);
        int ny = clampY(pixel.y + offset.y, h);
        ivec2 neighbor = ivec2(nx, ny);
        
        // Lire le seed du voisin
        ivec2 n_seed = imageLoad(component_input, neighbor).xy;
        if (n_seed.x < 0) {
            continue;  // Pas de seed valide
        }
        
        // Calculer la distance à ce seed
        float n_dist = distanceSquared(pixel, n_seed, w);
        
        // Garder le seed le plus proche
        if (n_dist < best_dist) {
            best_dist = n_dist;
            best_seed = n_seed;
        }
    }
    
    // Écrire le meilleur seed trouvé
    imageStore(component_output, pixel, ivec4(best_seed, 0, 0));
}
