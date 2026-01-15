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

// Convertit un region_id en couleur RGB déterministe
// Reproduit le système legacy : pas de 17 par canal, wrap progressif
vec3 regionIdToColor(uint region_id) {
    // Utiliser le hash de l'ID pour obtenir un index de couleur
    // Chaque région doit avoir une couleur unique et répétable
    
    // On simule le compteur legacy en utilisant l'ID comme index
    // Le pas est 17, donc on calcule combien de "pas" on a fait
    
    // Approche : utiliser l'ID modulo un grand nombre pour avoir un index
    // puis convertir en couleur avec le système de pas de 17
    
    uint color_index = region_id;
    
    // Calculer R, G, B comme si on avait incrémenté color_index fois
    // Chaque canal a 256/17 ≈ 15 valeurs avant overflow
    
    // Nombre de valeurs par canal avant wrap
    const uint STEP = 17u;
    const uint VALUES_PER_CHANNEL = 256u / STEP;  // 15
    
    // Décomposer l'index en R, G, B
    uint r_index = color_index % VALUES_PER_CHANNEL;
    uint g_index = (color_index / VALUES_PER_CHANNEL) % VALUES_PER_CHANNEL;
    uint b_index = (color_index / (VALUES_PER_CHANNEL * VALUES_PER_CHANNEL)) % VALUES_PER_CHANNEL;
    
    // Convertir en valeurs de couleur [0, 255]
    uint r = (r_index * STEP) % 256u;
    uint g = (g_index * STEP) % 256u;
    uint b = (b_index * STEP) % 256u;
    
    // Éviter le noir pur (0,0,0) qui pourrait être confondu avec autre chose
    if (r == 0u && g == 0u && b == 0u) {
        r = STEP;  // Première couleur valide
    }
    
    return vec3(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0);
}

// Hash pour obtenir un index de couleur stable depuis un region_id
uint hashForColor(uint x) {
    // Simple hash pour disperser les IDs
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return x;
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
        // Utiliser un hash de l'ID pour disperser les couleurs
        uint color_index = hashForColor(region_id);
        vec3 rgb = regionIdToColor(color_index);
        final_color = vec4(rgb, 1.0);
    }
    
    imageStore(region_colored, pixel, final_color);
}
