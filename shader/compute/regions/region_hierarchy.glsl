#[compute]
#version 450

/*
 * Region Hierarchy Shader
 * =======================
 * Agrège les départements (niveau 1) en régions (niveau 2) puis en zones (niveau 3).
 * Utilise un regroupement par proximité géographique.
 * 
 * Algorithme :
 * - Niveau 2 : Regrouper 3-8 départements voisins
 * - Niveau 3 : Regrouper 2-5 régions voisines
 * 
 * Entrées :
 *   - level_in : Texture du niveau inférieur (ex: départements)
 * 
 * Sortie :
 *   - level_out : Texture du niveau supérieur (ex: régions)
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée/sortie
layout(rgba32f, binding = 0) uniform readonly image2D level_in;
layout(rgba32f, binding = 1) uniform writeonly image2D level_out;

// Paramètres uniformes
layout(std140, binding = 2) uniform Params {
    int width;
    int height;
    int source_num_regions;    // Nombre de régions au niveau source
    int target_num_regions;    // Nombre de régions cible (niveau supérieur)
    uint seed;
    float padding1;
    float padding2;
    float padding3;
};

// === FONCTIONS UTILITAIRES ===

int wrapX(int x) {
    return (x + width) % width;
}

// Hash pour attribution déterministe
uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
    
    // Lire l'ID de région du niveau inférieur
    vec4 lower_state = imageLoad(level_in, pixel);
    float lower_id = lower_state.r;
    float cost = lower_state.g;
    float is_border = lower_state.b;
    
    // Si non-assigné, propager
    if (lower_id < 0.0) {
        imageStore(level_out, pixel, vec4(-1.0, cost, is_border, -1.0));
        return;
    }
    
    // Calculer l'ID du niveau supérieur
    // Simple : diviser l'espace des IDs par le ratio de regroupement
    float ratio = float(source_num_regions) / float(target_num_regions);
    
    // Utiliser un hash pour mélanger l'attribution (évite les bandes régulières)
    uint lower_id_int = uint(lower_id);
    uint hashed = hash(lower_id_int ^ seed);
    
    // Grouper les départements par "bins" avec du bruit
    float noise_factor = float(hashed % 1000u) / 1000.0 * 0.3;  // ±15%
    float adjusted_ratio = ratio * (0.85 + noise_factor);
    
    float upper_id = floor(lower_id / adjusted_ratio);
    upper_id = clamp(upper_id, 0.0, float(target_num_regions - 1));
    
    // Écrire l'état du niveau supérieur
    // R = ID niveau supérieur, G = ID niveau inférieur (pour référence), B = border, A = parent
    imageStore(level_out, pixel, vec4(upper_id, lower_id, is_border, upper_id));
}
