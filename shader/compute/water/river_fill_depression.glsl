#[compute]
#version 450

// ============================================================================
// RIVER FILL DEPRESSION - Remplissage de depressions Planchon-Darboux
// ============================================================================
// Remplit les depressions du terrain pour garantir un ecoulement continu.
// Apres convergence, chaque pixel terrestre a au moins un voisin plus bas,
// eliminant les DIR_SINK qui brisent la continuite des rivieres.
//
// Mode 0 (Init) :
//   eau/poles -> hauteur originale
//   terre     -> +infini (1e30)
//
// Mode 1 (Iteration) :
//   filled = max(original_height, min(neighbor_filled) + epsilon)
//   Converge quand toutes les depressions sont rehaussees au niveau du bord.
//
// Reutilise river_flux / river_flux_temp (R32F) pour le ping-pong.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32f)    uniform readonly image2D filled_in;
layout(set = 0, binding = 3, r32f)    uniform writeonly image2D filled_out;

layout(set = 1, binding = 0, std140) uniform FillParams {
    uint width;
    uint height;
    float sea_level;
    uint mode;      // 0 = init, 1 = iterate
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float EPSILON = 0.01;
const float INFINITY_VAL = 1e30;

// 8 voisins (Moore neighborhood)
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

int wrapX(int x, int w) {
    return ((x % w) + w) % w;
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

    if (pixel.x >= w || pixel.y >= h) return;

    float original_height = imageLoad(geo_texture, pixel).r;
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_polar = (pixel.y < 2 || pixel.y >= h - 2);
    bool is_outlet = (water_type > 0u) || is_polar;

    // === MODE 0 : INITIALISATION ===
    if (params.mode == 0u) {
        if (is_outlet) {
            // Exutoires (eau, poles) gardent leur hauteur originale
            imageStore(filled_out, pixel, vec4(original_height, 0.0, 0.0, 0.0));
        } else {
            // Pixels terrestres commencent a +infini
            imageStore(filled_out, pixel, vec4(INFINITY_VAL, 0.0, 0.0, 0.0));
        }
        return;
    }

    // === MODE 1 : ITERATION ===
    // Les exutoires passent sans changement
    if (is_outlet) {
        float current = imageLoad(filled_in, pixel).r;
        imageStore(filled_out, pixel, vec4(current, 0.0, 0.0, 0.0));
        return;
    }

    // Valeur remplie actuelle
    float current_filled = imageLoad(filled_in, pixel).r;

    // Si deja a la hauteur originale, pas de changement possible
    if (current_filled <= original_height) {
        imageStore(filled_out, pixel, vec4(original_height, 0.0, 0.0, 0.0));
        return;
    }

    // Trouver la hauteur remplie minimale parmi les voisins
    float min_neighbor = INFINITY_VAL;
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        float n_filled = imageLoad(filled_in, ivec2(nx, ny)).r;
        min_neighbor = min(min_neighbor, n_filled);
    }

    // Regle de mise a jour Planchon-Darboux :
    // new_filled = max(original_height, min_neighbor + epsilon)
    float new_filled = max(original_height, min_neighbor + EPSILON);

    // Ne mettre a jour que si ca diminue la valeur (convergence monotone)
    new_filled = min(new_filled, current_filled);

    imageStore(filled_out, pixel, vec4(new_filled, 0.0, 0.0, 0.0));
}
