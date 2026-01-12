#[compute]
#version 450

// ============================================================================
// WATER CLASSIFICATION SHADER - Classification des masses d'eau
// ============================================================================
// Classifie chaque pixel d'eau en :
// - 0 = Terre (pas d'eau)
// - 1 = Océan (grande masse sous niveau mer, >ocean_threshold)
// - 2 = Mer (masse moyenne sous niveau mer)
// - 3 = Lac (petite masse d'eau, altitude >= sea_level OU petite masse sous mer)
// - 4 = Affluent (flux faible)
// - 5 = Rivière (flux moyen)
// - 6 = Fleuve (flux élevé)
//
// Utilise le JFA (Jump Flooding Algorithm) pour propager les IDs de composantes.
// Ce shader est la première passe : initialisation + seuillage.
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height, A=water_height
// - RiverPathsTexture (R32F) : flux accumulé des rivières
//
// Sorties :
// - WaterTypesTexture (R32UI) : type d'eau (0-6)
// - WaterJFATexture (RG32I) : coordonnées du seed pour JFA (ou -1,-1 si non-eau)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// RiverPathsTexture (R32F) - lecture du flux
layout(set = 0, binding = 1, r32f) uniform readonly image2D river_paths;

// WaterTypesTexture (R32UI) - écriture du type
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D water_types;

// WaterJFATexture (RG32I) - pour propagation composantes connexes
layout(set = 0, binding = 3, rg32i) uniform writeonly iimage2D water_jfa;

// Uniform Buffer : Paramètres de classification
layout(set = 1, binding = 0, std140) uniform ClassificationParams {
    uint width;                  // Largeur texture
    uint height;                 // Hauteur texture
    float sea_level;             // Niveau de la mer
    float flux_threshold_low;    // Seuil flux affluent (ex: 10)
    float flux_threshold_mid;    // Seuil flux rivière (ex: 100)
    float flux_threshold_high;   // Seuil flux fleuve (ex: 500)
    float lake_min_water;        // Eau minimale pour lac en altitude (ex: 0.5)
    float padding;
} params;

// ============================================================================
// CONSTANTES : TYPES D'EAU
// ============================================================================

const uint WATER_NONE     = 0u;  // Terre
const uint WATER_OCEAN    = 1u;  // Océan (sera affiné par JFA)
const uint WATER_SEA      = 2u;  // Mer (sera affiné par JFA)
const uint WATER_LAKE     = 3u;  // Lac
const uint WATER_AFFLUENT = 4u;  // Affluent
const uint WATER_RIVER    = 5u;  // Rivière
const uint WATER_FLEUVE   = 6u;  // Fleuve

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
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    float flux = imageLoad(river_paths, pixel).r;
    
    float height = geo.r;
    float water_height = geo.a;
    
    uint water_type = WATER_NONE;
    ivec2 jfa_seed = ivec2(-1, -1);  // -1,-1 = pas de seed (terre)
    
    // === CLASSIFICATION PRIMAIRE ===
    
    // 1. Rivières et fleuves (basé sur le flux)
    if (flux > params.flux_threshold_high) {
        water_type = WATER_FLEUVE;
    }
    else if (flux > params.flux_threshold_mid) {
        water_type = WATER_RIVER;
    }
    else if (flux > params.flux_threshold_low) {
        water_type = WATER_AFFLUENT;
    }
    
    // 2. Eau de surface (océans, mers, lacs)
    // Les rivières ont priorité sur l'eau de surface
    if (water_type == WATER_NONE) {
        // Sous le niveau de la mer = océan/mer (à affiner par taille)
        if (height < params.sea_level) {
            // Temporairement classé comme océan, sera affiné par JFA
            water_type = WATER_OCEAN;
            jfa_seed = pixel;  // Ce pixel est son propre seed pour JFA
        }
        // Au-dessus du niveau de la mer avec eau = lac en altitude
        else if (water_height > params.lake_min_water) {
            water_type = WATER_LAKE;
            jfa_seed = pixel;
        }
    }
    
    // Les rivières n'ont pas de seed JFA (on ne calcule pas leur taille)
    // mais on pourrait les utiliser pour détecter les estuaires
    
    // === ÉCRITURE DES RÉSULTATS ===
    imageStore(water_types, pixel, uvec4(water_type, 0u, 0u, 0u));
    imageStore(water_jfa, pixel, ivec4(jfa_seed, 0, 0));
}
