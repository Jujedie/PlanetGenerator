#[compute]
#version 450

// ============================================================================
// WATER FINALIZE SHADER - Reclassification finale par taille
// ============================================================================
// Lit les compteurs de pixels par composante et reclassifie :
// - Océan : > ocean_threshold pixels
// - Mer : entre sea_threshold et ocean_threshold pixels
// - Lac : < sea_threshold pixels
//
// Les rivières (types 4, 5, 6) ne sont pas modifiées.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// WaterJFATexture (RG32I) - lecture des seeds
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D water_jfa;

// WaterTypesTexture (R32UI) - lecture/écriture du type
layout(set = 0, binding = 1, r32ui) uniform uimage2D water_types;

// Compteur de pixels par seed (SSBO) - lecture seule
layout(set = 0, binding = 2, std430) readonly buffer PixelCounter {
    uint pixel_counts[];
};

// GeoTexture en lecture seule (pour lacs en altitude)
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D geo_texture;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform FinalizeParams {
    uint width;
    uint height;
    float sea_level;
    uint ocean_threshold;     // Seuil océan (ex: 10000 pixels)
    uint sea_threshold;       // Seuil mer (ex: 1000 pixels)
    uint lake_threshold;      // Seuil lac (ex: 100 pixels pour très petits)
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE     = 0u;
const uint WATER_OCEAN    = 1u;
const uint WATER_SEA      = 2u;
const uint WATER_LAKE     = 3u;
const uint WATER_AFFLUENT = 4u;
const uint WATER_RIVER    = 5u;
const uint WATER_FLEUVE   = 6u;

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
    
    // Lire le type d'eau actuel
    uint water_type = imageLoad(water_types, pixel).r;
    
    // Ne pas toucher aux rivières/fleuves/affluents
    if (water_type >= WATER_AFFLUENT) {
        return;
    }
    
    // Ne pas toucher à la terre
    if (water_type == WATER_NONE) {
        return;
    }
    
    // Lire le seed JFA
    ivec2 seed = imageLoad(water_jfa, pixel).rg;
    
    if (seed.x < 0 || seed.y < 0) {
        // Pas de seed valide, garder le type actuel
        return;
    }
    
    // Lire le compteur de pixels pour cette composante
    uint seed_index = uint(seed.y) * params.width + uint(seed.x);
    uint component_size = pixel_counts[seed_index];
    
    // Lire l'altitude pour déterminer si c'est un lac en altitude
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    bool is_highland_lake = (height >= params.sea_level);
    
    // === RECLASSIFICATION PAR TAILLE ===
    uint new_type = water_type;
    
    if (is_highland_lake) {
        // Les lacs en altitude restent des lacs quelle que soit leur taille
        new_type = WATER_LAKE;
    }
    else if (component_size > params.ocean_threshold) {
        new_type = WATER_OCEAN;
    }
    else if (component_size > params.sea_threshold) {
        new_type = WATER_SEA;
    }
    else {
        // Petite masse d'eau sous le niveau de la mer = lac intérieur
        new_type = WATER_LAKE;
    }
    
    // Écrire le nouveau type
    imageStore(water_types, pixel, uvec4(new_type, 0u, 0u, 0u));
}
