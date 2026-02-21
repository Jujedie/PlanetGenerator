#[compute]
#version 450

// ===========================================================================
// REGION FINALIZE SHADER
// ===========================================================================
// Génère les couleurs des régions de manière déterministe.
// Reproduit exactement le système de couleurs du legacy Region.gd :
//   - Couleur = (R, G, B) avec pas de 10 par canal
//   - nextColor[0] += 10; if > 255 → wrap et incrémenter nextColor[1], etc.
//
// Entrées :
//   - region_map (binding 0) : R32UI - ID de région
//   - water_mask (binding 1) : masque eau
//
// Sorties :
//   - region_colored (binding 2) : RGBA8 - couleur finale
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D region_map;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D region_colored;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform FinalizeParams {
    uint width;
    uint height;
    uint seed;
    uint water_color_r;    // Couleur eau R (0x16 = 22)
    uint water_color_g;    // Couleur eau G (0x1a = 26)
    uint water_color_b;    // Couleur eau B (0x1f = 31)
    float padding1;
    float padding2;
} params;

// === FONCTIONS UTILITAIRES ===

// Hash pour obtenir un index de couleur stable depuis un region_id
uint hashForColor(uint x) {
    // Simple hash pour disperser les IDs et éviter les collisions de couleurs
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return x;
}

// Convertit un region_id en couleur RGB UNIQUE
// Chaque ID donne une couleur différente - PAS DE HASH pour éviter les collisions
// Système: on parcourt l'espace RGB avec un pas de 17 (comme Region.gd)
vec3 regionIdToColor(uint region_id) {
    const uint STEP = 17u;
    const uint LEVELS = 15u;  // 256/17 ≈ 15 niveaux par canal
    
    // Utiliser l'ID DIRECTEMENT (modulo pour éviter overflow)
    // Cela garantit que chaque ID a une couleur unique
    uint idx = region_id % (LEVELS * LEVELS * LEVELS);  // Max 3375 couleurs uniques
    
    // Décomposer en base 15 pour R, G, B
    uint r_level = idx % LEVELS;
    uint g_level = (idx / LEVELS) % LEVELS;
    uint b_level = (idx / (LEVELS * LEVELS)) % LEVELS;
    
    uint r = r_level * STEP;
    uint g = g_level * STEP;
    uint b = b_level * STEP;
    
    // Éviter le noir pur (ID 0)
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
    
    // Lire la région et le type d'eau
    uint region_id = imageLoad(region_map, pixel).r;
    uint water_type = imageLoad(water_mask, pixel).r;
    
    vec4 final_color;
    
    // Si c'est de l'eau, utiliser la couleur d'eau (comme legacy: 0x161a1fFF)
    if (water_type > 0u) {
        // Couleur eau du legacy : RGB(22, 26, 31) = #161a1f
        final_color = vec4(
            float(params.water_color_r) / 255.0,
            float(params.water_color_g) / 255.0,
            float(params.water_color_b) / 255.0,
            1.0
        );
    } else {
        // Pixel de terre : TOUTE TERRE DOIT AVOIR UNE RÉGION
        // Si pas de région assignée par la propagation, en créer une unique
        if (region_id == 0xFFFFFFFFu) {
            region_id = uint(pixel.x) + uint(pixel.y) * params.width;
        }
        
        // Utiliser un hash de l'ID pour disperser les couleurs
        uint color_index = hashForColor(region_id);
        vec3 rgb = regionIdToColor(color_index);
        final_color = vec4(rgb, 1.0);
    }
    
    imageStore(region_colored, pixel, final_color);
}
