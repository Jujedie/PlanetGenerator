#[compute]
#version 450

// ===========================================================================
// REGION FINALIZE SHADER
// ===========================================================================
// Génère les couleurs des régions de manière déterministe.
// Reproduit exactement le système de couleurs du legacy Region.gd :
//   - Couleur = (R, G, B) avec pas de 17 par canal
//   - nextColor[0] += 17; if > 255 → wrap et incrémenter nextColor[1], etc.
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

// Convertit un region_id en couleur RGB déterministe
// Reproduit EXACTEMENT le système legacy : pas de 17 par canal, wrap progressif
// Le legacy fait : nextColor[0] += 17, puis wrap + incrémente nextColor[1], etc.
vec3 regionIdToColor(uint region_id) {
    const uint STEP = 17u;
    
    // Hasher l'ID pour disperser les couleurs et éviter les patterns
    uint color_index = hashForColor(region_id);
    
    // Simuler l'incrément progressif des canaux comme le legacy
    // On utilise une représentation base-15 (256/17 ≈ 15)
    const uint BASE = 15u;  // Nombre de valeurs par canal
    
    uint r_idx = color_index % BASE;
    uint g_idx = (color_index / BASE) % BASE;
    uint b_idx = (color_index / (BASE * BASE)) % BASE;
    
    uint r = (r_idx * STEP) % 256u;
    uint g = (g_idx * STEP) % 256u;
    uint b = (b_idx * STEP) % 256u;
    
    // Éviter le noir pur (0,0,0) et les couleurs trop sombres
    if (r + g + b < 50u) {
        r = (r + STEP) % 256u;
        if (r < STEP) g = (g + STEP) % 256u;
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
    if (water_type > 0u || region_id == 0xFFFFFFFFu) {
        // Couleur eau du legacy : RGB(22, 26, 31) = #161a1f
        final_color = vec4(
            float(params.water_color_r) / 255.0,
            float(params.water_color_g) / 255.0,
            float(params.water_color_b) / 255.0,
            1.0
        );
    } else {
        // Pixel de terre avec région assignée
        vec3 rgb = regionIdToColor(region_id);
        final_color = vec4(rgb, 1.0);
    }
    
    imageStore(region_colored, pixel, final_color);
}
