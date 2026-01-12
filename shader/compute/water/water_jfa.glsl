#[compute]
#version 450

// ============================================================================
// WATER JFA SHADER - Jump Flooding Algorithm pour composantes connexes
// ============================================================================
// Propage les seeds pour calculer les composantes connexes des masses d'eau.
// Après N passes (log2(max(w,h))), chaque pixel connaît le seed de sa composante.
//
// Entrées/Sorties (ping-pong) :
// - WaterJFAInput (RG32I) : coordonnées du seed actuel
// - WaterJFAOutput (RG32I) : coordonnées du seed mis à jour
//
// Le step_size commence à max(w,h)/2 et est divisé par 2 à chaque passe.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// WaterJFAInput (RG32I) - lecture
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D jfa_input;

// WaterJFAOutput (RG32I) - écriture (ping-pong)
layout(set = 0, binding = 1, rg32i) uniform writeonly iimage2D jfa_output;

// WaterTypesTexture (R32UI) - pour vérifier le type d'eau
layout(set = 0, binding = 2, r32ui) uniform readonly uimage2D water_types;

// Uniform Buffer : Paramètres JFA
layout(set = 1, binding = 0, std140) uniform JFAParams {
    uint width;       // Largeur texture
    uint height;      // Hauteur texture
    int step_size;    // Taille du pas (commence à w/2, divisé par 2 chaque passe)
    uint padding;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE = 0u;

// 9 directions (centre + 8 voisins à distance step_size)
const ivec2 DIRECTIONS[9] = ivec2[9](
    ivec2( 0,  0),
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire
int wrapX(int x, int w) {
    return (x + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Distance euclidienne au carré (évite sqrt)
int distSq(ivec2 a, ivec2 b, int w) {
    // Gérer le wrapping en X
    int dx = abs(a.x - b.x);
    dx = min(dx, w - dx);  // Distance cyclique
    int dy = a.y - b.y;
    return dx * dx + dy * dy;
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
    
    // Si ce n'est pas de l'eau (type NONE), pas de propagation
    uint my_type = imageLoad(water_types, pixel).r;
    if (my_type == WATER_NONE) {
        imageStore(jfa_output, pixel, ivec4(-1, -1, 0, 0));
        return;
    }
    
    // Seed actuel de ce pixel
    ivec2 my_seed = imageLoad(jfa_input, pixel).rg;
    int best_dist_sq = (my_seed.x >= 0) ? distSq(pixel, my_seed, w) : 0x7FFFFFFF;
    ivec2 best_seed = my_seed;
    
    // Parcourir les 9 directions
    for (int i = 0; i < 9; i++) {
        ivec2 offset = DIRECTIONS[i] * params.step_size;
        int nx = wrapX(pixel.x + offset.x, w);
        int ny = clampY(pixel.y + offset.y, h);
        
        // Vérifier que le voisin est aussi de l'eau (même type général)
        uint n_type = imageLoad(water_types, ivec2(nx, ny)).r;
        if (n_type == WATER_NONE) {
            continue;
        }
        
        // Pour JFA océan/mer/lac, on ne mélange pas les types
        // Un océan et un lac ne sont pas la même composante
        // Exception : océan et mer sont fusionnables (même masse sous la mer)
        bool compatible = false;
        if (my_type == n_type) {
            compatible = true;
        }
        // Océan (1) et Mer (2) sont compatibles
        else if ((my_type == 1u || my_type == 2u) && (n_type == 1u || n_type == 2u)) {
            compatible = true;
        }
        
        if (!compatible) {
            continue;
        }
        
        // Seed du voisin
        ivec2 n_seed = imageLoad(jfa_input, ivec2(nx, ny)).rg;
        
        if (n_seed.x < 0) {
            continue;  // Pas de seed valide
        }
        
        // Distance au seed du voisin
        int dist_sq = distSq(pixel, n_seed, w);
        
        if (dist_sq < best_dist_sq) {
            best_dist_sq = dist_sq;
            best_seed = n_seed;
        }
    }
    
    // Écrire le meilleur seed
    imageStore(jfa_output, pixel, ivec4(best_seed, 0, 0));
}
