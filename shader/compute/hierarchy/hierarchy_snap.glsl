#[compute]
#version 450

// ===========================================================================
// HIERARCHY SNAP SHADER
// ===========================================================================
// Force la hiérarchie stricte : tous les pixels appartenant au même ID du
// niveau inférieur (prev_level_map) doivent avoir le même super_id.
//
// Algorithme : JFA intra-département.
// Pour chaque pixel, si un voisin à ±step_size partage le même prev_id ET
// a un super_cost inférieur (= plus proche d'un seed), on adopte son super_id.
// L'information se propage depuis les pixels proches des seeds vers les bords
// de chaque département.
//
// Après O(log n) passes JFA décroissantes, tous les pixels d'un même
// département convergent vers le super_id du pixel le plus proche d'un seed.
//
// Entrées :
//   - prev_level_map (binding 0) : IDs du niveau inférieur (R32UI)
//   - snap_map_in (binding 1) : super_map lecture (R32UI)
//   - snap_cost_in (binding 2) : super_cost lecture (R32F)
//
// Sorties :
//   - snap_map_out (binding 3) : super_map écriture (R32UI)
//   - snap_cost_out (binding 4) : super_cost écriture (R32F)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r32ui)  uniform readonly  uimage2D prev_level_map;
layout(set = 0, binding = 1, r32ui)  uniform readonly  uimage2D snap_map_in;
layout(set = 0, binding = 2, r32f)   uniform readonly  image2D  snap_cost_in;
layout(set = 0, binding = 3, r32ui)  uniform writeonly uimage2D snap_map_out;
layout(set = 0, binding = 4, r32f)   uniform writeonly image2D  snap_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SnapParams {
    uint width;
    uint height;
    uint step_size;            // Taille du pas JFA pour snap
    uint padding;
} params;

// === FONCTIONS UTILITAIRES ===

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// Décodage position seed
ivec2 unpackCoords(float packed, uint w) {
    uint total = uint(packed - 1.0);
    return ivec2(int(total % w), int(total / w));
}

// Distance² avec wrap horizontal
float wrappedDistSq(ivec2 a, ivec2 b, int w) {
    float dx = abs(float(a.x) - float(b.x));
    if (dx > float(w) * 0.5) dx = float(w) - dx;
    float dy = float(a.y) - float(b.y);
    return dx * dx + dy * dy;
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) {
        return;
    }

    // Lire l'ID du niveau inférieur de ce pixel
    uint my_prev_id = imageLoad(prev_level_map, pixel).r;

    // Pas dans le domaine (invalide au niveau inférieur)
    if (my_prev_id == 0xFFFFFFFFu) {
        imageStore(snap_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(snap_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }

    // Lire l'état actuel du snap
    uint current_super = imageLoad(snap_map_in, pixel).r;
    float current_cost = imageLoad(snap_cost_in, pixel).r;

    // Meilleur candidat : on cherche le voisin avec le même prev_id
    // et le coût le plus bas (= le plus proche du seed JFA d'origine)
    uint best_super = current_super;
    float best_cost = current_cost;

    int step = int(params.step_size);

    // JFA intra-département : 9 voisins à ±step
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = wrapX(pixel.x + dx * step, w);
            int ny = clampY(pixel.y + dy * step, h);
            ivec2 neighbor = ivec2(nx, ny);

            // Le voisin doit avoir le même prev_id (même département)
            uint n_prev_id = imageLoad(prev_level_map, neighbor).r;
            if (n_prev_id != my_prev_id) continue;

            uint n_super = imageLoad(snap_map_in, neighbor).r;
            if (n_super == 0xFFFFFFFFu) continue;

            float n_cost = imageLoad(snap_cost_in, neighbor).r;

            // Adopter le voisin avec le coût le plus bas
            // (= le plus proche d'un seed dans l'espace JFA)
            if (n_cost < best_cost) {
                best_cost = n_cost;
                best_super = n_super;
            }
        }
    }

    imageStore(snap_map_out, pixel, uvec4(best_super, 0u, 0u, 0u));
    imageStore(snap_cost_out, pixel, vec4(best_cost, 0.0, 0.0, 0.0));
}
