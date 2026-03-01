#[compute]
#version 450

// ===========================================================================
// HIERARCHY CLEANUP SHADER
// ===========================================================================
// Nettoyage agressif : assigne tout pixel du domaine non couvert à la
// super-région la plus proche, via recherche en spirale (rayon 1→16).
// Paramétrable par domaine (terre/mer).
//
// Entrées :
//   - water_mask (binding 0) : masque eau (R8UI)
//   - super_map_in (binding 1) : super_map lecture (R32UI)
//
// Sorties :
//   - super_map_out (binding 2) : super_map écriture (R32UI)
//   - super_cost_out (binding 3) : coût fictif (R32F)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r8ui)   uniform readonly  uimage2D water_mask;
layout(set = 0, binding = 1, r32ui)  uniform readonly  uimage2D super_map_in;
layout(set = 0, binding = 2, r32ui)  uniform writeonly uimage2D super_map_out;
layout(set = 0, binding = 3, r32f)   uniform writeonly image2D  super_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform CleanupParams {
    uint width;
    uint height;
    uint seed;
    uint domain;               // 0 = terre, 1 = mer
} params;

// === FONCTIONS UTILITAIRES ===

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) {
        return;
    }

    // Vérifier le domaine
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_water = (water_type > 0u);
    bool in_domain = (params.domain == 0u) ? !is_water : is_water;

    if (!in_domain) {
        imageStore(super_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(super_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }

    uint current_region = imageLoad(super_map_in, pixel).r;

    // Déjà assigné → garder tel quel
    if (current_region != 0xFFFFFFFFu) {
        imageStore(super_map_out, pixel, uvec4(current_region, 0u, 0u, 0u));
        imageStore(super_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        return;
    }

    // Recherche en spirale croissante (rayon 1→16)
    uint assigned_region = 0xFFFFFFFFu;

    for (int radius = 1; radius <= 16 && assigned_region == 0xFFFFFFFFu; radius++) {
        for (int sdy = -radius; sdy <= radius; sdy++) {
            for (int sdx = -radius; sdx <= radius; sdx++) {
                if (abs(sdx) != radius && abs(sdy) != radius) continue;

                int nx = wrapX(pixel.x + sdx, w);
                int ny = clampY(pixel.y + sdy, h);
                ivec2 neighbor_pos = ivec2(nx, ny);

                // Le voisin doit être dans le même domaine
                uint n_water = imageLoad(water_mask, neighbor_pos).r;
                bool n_is_water = (n_water > 0u);
                bool n_in_domain = (params.domain == 0u) ? !n_is_water : n_is_water;
                if (!n_in_domain) continue;

                uint neighbor_region = imageLoad(super_map_in, neighbor_pos).r;
                if (neighbor_region != 0xFFFFFFFFu) {
                    assigned_region = neighbor_region;
                    break;
                }
            }
            if (assigned_region != 0xFFFFFFFFu) break;
        }
    }

    imageStore(super_map_out, pixel, uvec4(assigned_region, 0u, 0u, 0u));
    imageStore(super_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
}
