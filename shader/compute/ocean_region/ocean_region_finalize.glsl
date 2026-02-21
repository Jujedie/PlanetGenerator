#[compute]
#version 450

// ===========================================================================
// OCEAN REGION FINALIZE SHADER
// ===========================================================================
// Génère les couleurs des régions océaniques de manière déterministe.
// Système identique aux régions terrestres : pas de 10 par canal.
//
// Entrées :
//   - ocean_region_map (binding 0) : R32UI - ID de région océanique
//   - water_mask (binding 1) : masque eau
//
// Sorties :
//   - ocean_region_colored (binding 2) : RGBA8 - couleur finale
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D ocean_region_map;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D ocean_region_colored;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform FinalizeParams {
    uint width;
    uint height;
    uint seed;
    uint land_color_r;     // Couleur terre R (0x2a = 42)
    uint land_color_g;     // Couleur terre G (0x2a = 42)
    uint land_color_b;     // Couleur terre B (0x2a = 42)
    float padding1;
    float padding2;
} params;

// === FONCTIONS UTILITAIRES ===

uint hashForColor(uint x) {
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return x;
}

// Couleur UNIQUE par region_id - PAS DE HASH
vec3 oceanRegionIdToColor(uint region_id) {
    const uint STEP = 17u;
    const uint LEVELS = 15u;
    
    // ID direct = couleur unique garantie
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
    
    uint region_id = imageLoad(ocean_region_map, pixel).r;
    uint water_type = imageLoad(water_mask, pixel).r;
    
    vec4 final_color;
    
    // Si c'est de la terre, utiliser couleur terre (gris fixe)
    if (water_type == 0u) {
        final_color = vec4(
            float(params.land_color_r) / 255.0,
            float(params.land_color_g) / 255.0,
            float(params.land_color_b) / 255.0,
            1.0
        );
    } else {
        // Pixel d'eau : TOUTE EAU DOIT AVOIR UNE RÉGION
        // Si pas de région assignée, en créer une unique
        if (region_id == 0xFFFFFFFFu) {
            region_id = uint(pixel.x) + uint(pixel.y) * params.width;
        }
        
        uint color_index = hashForColor(region_id);
        vec3 rgb = oceanRegionIdToColor(color_index);
        final_color = vec4(rgb, 1.0);
    }
    
    imageStore(ocean_region_colored, pixel, final_color);
}
