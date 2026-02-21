#[compute]
#version 450

// ============================================================================
// WATER FILL SHADER - Identification des zones d'eau
// ============================================================================
// Étape 1 du système d'eau :
// - Identifie les pixels sous le niveau de la mer (eau potentielle)
// - Identifie les lacs en altitude (dépressions au-dessus du niveau mer)
// - Vérifie la température : l'eau liquide n'existe que si T ∈ [0°C, 100°C]
// - Initialise les seeds JFA pour la détection des composantes connexes
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height (altitude en mètres)
// - ClimateTexture (RGBA32F) : R=temperature (°C) - DOIT être calculée AVANT
//
// Sorties :
// - water_mask (R8UI) : 0=terre, 1=eau (sera reclassifié après)
// - water_component (RG32I) : Coordonnées seed pour JFA (-1,-1 si terre)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// Masque d'eau en écriture (R8UI)
layout(set = 0, binding = 1, r8ui) uniform writeonly uimage2D water_mask;

// Composantes connexes JFA (RG32I) - seed initial
layout(set = 0, binding = 2, rg32i) uniform writeonly iimage2D water_component;

// Texture climat en lecture (R=température en °C)
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D climate_texture;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform WaterParams {
    uint width;           // Largeur texture
    uint height;          // Hauteur texture
    float sea_level;      // Niveau de la mer
    float lake_threshold; // Seuil pour détection des lacs en altitude (profondeur min)
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE = 0u;
const uint WATER_POTENTIAL = 1u;  // Eau potentielle (sera classifiée après)

// Limites de température pour l'existence de l'eau liquide
// En dessous de WATER_MIN_TEMP → glace (pas d'eau liquide)
// Au dessus de WATER_MAX_TEMP → vapeur (pas d'eau liquide)
const float WATER_MIN_TEMP = -21.0;    // Point de congélation (°C)
const float WATER_MAX_TEMP = 100.0;  // Point d'ébullition (°C)

// 4 voisins cardinaux pour détection dépressions
const ivec2 NEIGHBORS_4[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
);

// Voisinage étendu pour détection robuste des lacs (rayon 2, 12 voisins)
const int LAKE_NEIGHBOR_COUNT = 12;
const ivec2 LAKE_NEIGHBORS[12] = ivec2[12](
    // Rayon 1 : cardinaux
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1),
    // Rayon 1 : diagonaux
    ivec2(-1, -1), ivec2(1, -1), ivec2(-1, 1), ivec2(1, 1),
    // Rayon 2 : cardinaux
    ivec2(-2, 0), ivec2(2, 0), ivec2(0, -2), ivec2(0, 2)
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire (cyclique)
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

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
    
    // Lire l'altitude
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    
    // Lire la température (calculée dans la phase atmosphère AVANT l'eau)
    float temperature = imageLoad(climate_texture, pixel).r;
    
    // === VÉRIFICATION TEMPÉRATURE ===
    // L'eau liquide ne peut exister que dans la plage [WATER_MIN_TEMP, WATER_MAX_TEMP]
    // En dehors de cette plage : glace ou vapeur, pas d'eau de surface
    bool temperature_allows_water = (temperature >= WATER_MIN_TEMP && temperature <= WATER_MAX_TEMP);
    
    // === CLASSIFICATION DE BASE ===
    bool is_water = false;
    
    // 1. Océan : pixel sous le niveau de la mer ET température compatible
    //    NOTE: On utilise height < sea_level au lieu de geo.a (water_height)
    //    car après l'érosion, geo.a peut contenir de l'eau de pluie résiduelle
    //    pour des pixels TERRESTRES, ce qui créait de faux positifs d'eau
    //    dans des zones chaudes (>100°C) où l'eau ne devrait pas exister.
    if (height < params.sea_level && temperature_allows_water) {
        is_water = true;
    }
    // 2. Détection des lacs en altitude (dépressions locales)
    //    Aussi conditionné par la température
    //    Le lake_threshold agit comme un seuil de profondeur minimale :
    //    plus il est élevé, moins il y a de lacs (seules les grosses dépressions passent).
    //    On vérifie 12 voisins (rayon 2) : TOUS doivent être plus hauts que le pixel central.
    //    La différence minimale entre le voisin le plus bas et le centre doit dépasser le seuil.
    else if (params.lake_threshold > 0.0 && temperature_allows_water) {
        bool is_depression = true;
        float min_neighbor_height = 1e10;
        
        for (int i = 0; i < LAKE_NEIGHBOR_COUNT; i++) {
            int nx = wrapX(pixel.x + LAKE_NEIGHBORS[i].x, w);
            int ny = clampY(pixel.y + LAKE_NEIGHBORS[i].y, h);
            
            float n_height = imageLoad(geo_texture, ivec2(nx, ny)).r;
            min_neighbor_height = min(min_neighbor_height, n_height);
            
            // Si un voisin est plus bas ou au même niveau, pas une dépression
            if (n_height <= height) {
                is_depression = false;
                break;  // Pas besoin de continuer
            }
        }
        
        // C'est un lac si c'est une dépression dont la profondeur dépasse le seuil
        if (is_depression && (min_neighbor_height - height) > params.lake_threshold) {
            is_water = true;
        }
    }
    
    // === ÉCRITURE DES RÉSULTATS ===
    
    // Masque d'eau
    uint water_type = is_water ? WATER_POTENTIAL : WATER_NONE;
    imageStore(water_mask, pixel, uvec4(water_type, 0u, 0u, 0u));
    
    // Label pour composantes connexes :
    // - Chaque pixel d'eau commence avec son propre ID unique = y * width + x
    // - L'algorithme de propagation fera converger vers le minimum
    // - (-1, -1) pour les pixels de terre
    int label = is_water ? (pixel.y * w + pixel.x) : -1;
    imageStore(water_component, pixel, ivec4(label, pixel.y, 0, 0));
}
