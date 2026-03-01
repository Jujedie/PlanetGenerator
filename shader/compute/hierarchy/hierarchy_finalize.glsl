#[compute]
#version 450

// ===========================================================================
// HIERARCHY FINALIZE SHADER
// ===========================================================================
// Convertit les IDs d'un niveau hiérarchique en couleurs RGBA8 uniques.
// Système identique à region_finalize : step=17 par canal, 3375 couleurs max.
//
// Paramétrable via UBO :
//   - domain : 0=terre, 1=mer
//   - bg_color_r/g/b : couleur de fond pour le domaine opposé
//     (terre → bleu sombre pour cartes terrestres, mer → gris pour cartes mer)
//
// Entrées :
//   - super_map (binding 0) : IDs du niveau hiérarchique (R32UI)
//   - water_mask (binding 1) : masque eau (R8UI)
//
// Sorties :
//   - colored_output (binding 2) : image colorée (RGBA8)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r32ui)  uniform readonly  uimage2D super_map;
layout(set = 0, binding = 1, r8ui)   uniform readonly  uimage2D water_mask;
layout(set = 0, binding = 2, rgba8)  uniform writeonly image2D  colored_output;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform FinalizeParams {
    uint width;
    uint height;
    uint seed;
    uint domain;               // 0 = terre, 1 = mer
    uint bg_color_r;           // Fond R (pour le domaine opposé)
    uint bg_color_g;           // Fond G
    uint bg_color_b;           // Fond B
    uint padding;
} params;

// === FONCTIONS UTILITAIRES ===

uint hashForColor(uint x) {
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return x;
}

vec3 regionIdToColor(uint region_id) {
    const uint STEP = 17u;
    const uint LEVELS = 15u;

    uint idx = region_id % (LEVELS * LEVELS * LEVELS);

    uint r_level = idx % LEVELS;
    uint g_level = (idx / LEVELS) % LEVELS;
    uint b_level = (idx / (LEVELS * LEVELS)) % LEVELS;

    uint r = r_level * STEP;
    uint g = g_level * STEP;
    uint b = b_level * STEP;

    if (r == 0u && g == 0u && b == 0u) {
        r = STEP;
    }

    return vec3(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) {
        return;
    }

    uint super_id = imageLoad(super_map, pixel).r;
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_water = (water_type > 0u);
    bool in_domain = (params.domain == 0u) ? !is_water : is_water;

    vec4 final_color;

    if (!in_domain) {
        // Hors domaine → couleur de fond
        final_color = vec4(
            float(params.bg_color_r) / 255.0,
            float(params.bg_color_g) / 255.0,
            float(params.bg_color_b) / 255.0,
            1.0
        );
    } else {
        if (super_id == 0xFFFFFFFFu) {
            // Fallback : ID basé sur position
            super_id = uint(pixel.x) + uint(pixel.y) * params.width;
        }

        uint color_index = hashForColor(super_id);
        vec3 rgb = regionIdToColor(color_index);
        final_color = vec4(rgb, 1.0);
    }

    imageStore(colored_output, pixel, final_color);
}
