#[compute]
#version 450

// ============================================================================
// WATER FINALIZE SHADER - Reclassification finale eau salée/eau douce
// ============================================================================
// Lit les compteurs de pixels par composante et reclassifie :
// - Eau salée (type 1) : masse d'eau >= saltwater_threshold pixels
// - Eau douce (type 3) : masse d'eau < saltwater_threshold pixels
// - Lacs en altitude : toujours eau douce (type 3)
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
    uint saltwater_threshold;  // Seuil eau salée (>= ce seuil = eau salée)
    uint padding1;             // Ancien sea_threshold (non utilisé)
    uint padding2;             // Ancien lake_threshold (non utilisé)
    float padding3;
    float padding4;
} params;

// ============================================================================
// CONSTANTES - Types d'eau simplifiés
// ============================================================================

const uint WATER_NONE      = 0u;  // Terre
const uint WATER_SALTWATER = 1u;  // Eau salée (ex-océan) - grande masse >= saltwater_threshold
const uint WATER_SEA       = 2u;  // Non utilisé, gardé pour compatibilité export
const uint WATER_FRESHWATER = 3u; // Eau douce (lacs, petites masses) - < saltwater_threshold
const uint WATER_AFFLUENT  = 4u;  // Affluent (rivière)
const uint WATER_RIVER     = 5u;  // Rivière
const uint WATER_FLEUVE    = 6u;  // Fleuve

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
    
    // === RECLASSIFICATION EAU SALÉE / EAU DOUCE ===
    uint new_type;
    
    if (is_highland_lake) {
        // Les lacs en altitude sont TOUJOURS de l'eau douce
        new_type = WATER_FRESHWATER;
    }
    else if (component_size == 0u) {
        // Si le compteur n'a pas été rempli, fallback basé sur position du seed
        // Si le seed est proche du centre ou des bords, c'est probablement un océan
        // Sinon, on garde le type initial (eau sous la mer = eau salée par défaut)
        new_type = WATER_SALTWATER;
    }
    else if (component_size >= params.saltwater_threshold) {
        // Grande masse d'eau sous le niveau de la mer = eau salée
        new_type = WATER_SALTWATER;
    }
    else {
        // Petite masse d'eau sous le niveau de la mer = eau douce (lac intérieur)
        new_type = WATER_FRESHWATER;
    }
    
    // Écrire le nouveau type
    imageStore(water_types, pixel, uvec4(new_type, 0u, 0u, 0u));
}
