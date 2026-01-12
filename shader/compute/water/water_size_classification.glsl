#[compute]
#version 450

// ============================================================================
// WATER SIZE CLASSIFICATION SHADER - Classification finale par taille
// ============================================================================
// Après le JFA, chaque pixel d'eau connaît son seed.
// Cette passe compte les pixels par composante (via atomics) puis classifie :
// - Océan : > ocean_threshold pixels
// - Mer : entre sea_min et ocean_threshold pixels
// - Lac : < sea_min pixels (ou lac en altitude)
//
// PASSE 1 : Comptage atomique des pixels par seed
// PASSE 2 (shader séparé) : Lecture des compteurs et reclassification
//
// Ce shader effectue uniquement le comptage.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// WaterJFATexture (RG32I) - lecture des seeds
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D water_jfa;

// WaterTypesTexture (R32UI) - lecture du type initial
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D water_types;

// Compteur de pixels par seed (SSBO)
// Index = seed.y * width + seed.x
// Valeur = nombre de pixels avec ce seed
layout(set = 0, binding = 2, std430) buffer PixelCounter {
    uint pixel_counts[];
};

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform SizeParams {
    uint width;
    uint height;
    uint padding1;
    uint padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE = 0u;
const uint WATER_OCEAN = 1u;
const uint WATER_SEA = 2u;
const uint WATER_LAKE = 3u;

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    // Vérification des limites
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Lire le type d'eau
    uint water_type = imageLoad(water_types, pixel).r;
    
    // Ne compter que les masses d'eau (océan/mer/lac), pas les rivières
    if (water_type < WATER_OCEAN || water_type > WATER_LAKE) {
        return;
    }
    
    // Lire le seed JFA
    ivec2 seed = imageLoad(water_jfa, pixel).rg;
    
    if (seed.x < 0 || seed.y < 0) {
        return;  // Pas de seed valide
    }
    
    // Incrémenter le compteur atomiquement
    uint seed_index = uint(seed.y) * params.width + uint(seed.x);
    atomicAdd(pixel_counts[seed_index], 1u);
}
