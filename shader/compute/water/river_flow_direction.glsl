#[compute]
#version 450

// ============================================================================
// RIVER FLOW DIRECTION SHADER - Calcul des directions d'ecoulement D8
// ============================================================================
// Calcule la direction de plus forte pente descendante (D8) pour chaque pixel.
// Chaque pixel terrestre pointe vers l'un de ses 8 voisins (celui avec la
// pente descendante la plus forte). Cela cree un graphe de drainage
// deterministe ou chaque pixel a exactement un exutoire.
//
// Utilise l'elevation remplie (Planchon-Darboux) pour garantir qu'aucune
// depression terrestre ne bloque l'ecoulement.
//
// Gestion des zones plates :
// - Une micro-perturbation basee sur un hash est ajoutee a la hauteur
//   pour casser les egalites et garantir un ecoulement meme sur terrain plat.
//
// Entrees :
// - filled_elevation (R32F) : Elevation apres remplissage des depressions
// - water_mask (R8UI) : 0=terre, >0=eau
//
// Sorties :
// - flow_direction (R8UI) : Direction 0-7 (index voisin), 255 = puits/eau
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, r32f)    uniform readonly image2D filled_elevation;
layout(set = 0, binding = 1, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r8ui)    uniform writeonly uimage2D flow_direction;

layout(set = 1, binding = 0, std140) uniform FlowParams {
    uint width;
    uint height;
    uint seed;
    float sea_level;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// 8 voisins (Moore neighborhood) - meme ordre que river_propagation
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// Distances aux voisins (diagonales = sqrt(2))
const float NEIGHBOR_DIST[8] = float[8](
    1.41421, 1.0, 1.41421,
    1.0,          1.0,
    1.41421, 1.0, 1.41421
);

// Direction indiquant un puits (pas d'ecoulement possible)
const uint DIR_SINK = 255u;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection equirectangulaire (cylindrique)
int wrapX(int x, int w) {
    return ((x % w) + w) % w;
}

/// Clamp Y pour les poles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Hash pseudo-aleatoire pour micro-perturbation des zones plates
float microPerturbation(ivec2 pixel, uint seed) {
    uint h = uint(pixel.x) * 374761393u + uint(pixel.y) * 668265263u + seed;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    // Perturbation tres faible : entre 0 et 0.001 metre
    return float(h & 0xFFFFu) / 65535.0 * 0.001;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) return;

    // Exclure les rangees polaires (eviter convergence artificielle due a clampY)
    if (pixel.y < 2 || pixel.y >= h - 2) {
        imageStore(flow_direction, pixel, uvec4(DIR_SINK, 0u, 0u, 0u));
        return;
    }

    // Les pixels d'eau sont des puits absorbants
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(flow_direction, pixel, uvec4(DIR_SINK, 0u, 0u, 0u));
        return;
    }

    // Hauteur du pixel courant avec micro-perturbation
    float my_height = imageLoad(filled_elevation, pixel).r;
    float my_perturbed = my_height + microPerturbation(pixel, params.seed);

    // Chercher le voisin avec la plus forte pente descendante
    uint best_dir = DIR_SINK;
    float best_slope = 0.0;  // Pas de seuil minimum - on veut toujours ecouler

    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);

        float n_height = imageLoad(filled_elevation, ivec2(nx, ny)).r;
        float n_perturbed = n_height + microPerturbation(ivec2(nx, ny), params.seed);

        // Pixels d'eau voisins : consideres comme etant au niveau de la mer
        // (attire l'ecoulement vers l'ocean)
        uint n_water = imageLoad(water_mask, ivec2(nx, ny)).r;
        if (n_water > 0u) {
            n_perturbed = min(n_perturbed, params.sea_level);
        }

        float slope = (my_perturbed - n_perturbed) / NEIGHBOR_DIST[i];

        if (slope > best_slope) {
            best_slope = slope;
            best_dir = uint(i);
        }
    }

    // Si aucun voisin n'est plus bas (depression locale),
    // chercher un voisin d'eau uniquement pour eviter les cycles.
    // Les pixels d'eau sont des puits (DIR_SINK=255) et ne pointent
    // jamais vers la terre, donc aucun cycle ne peut se former.
    // Les depressions interieures sans eau adjacente restent des puits.
    if (best_dir == DIR_SINK && my_height >= params.sea_level) {
        for (int i = 0; i < 8; i++) {
            int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
            int ny = clampY(pixel.y + NEIGHBORS[i].y, h);

            uint n_water = imageLoad(water_mask, ivec2(nx, ny)).r;
            if (n_water > 0u) {
                best_dir = uint(i);
                break;
            }
        }
    }

    imageStore(flow_direction, pixel, uvec4(best_dir, 0u, 0u, 0u));
}
