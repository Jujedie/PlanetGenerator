#[compute]
#version 450

// ============================================================================
// WATER FILL SHADER - Initialisation des exutoires océaniques
// ============================================================================
// Étape 1 du système d'eau :
// - Identifie uniquement les pixels sous le niveau de la mer (eau potentielle)
// - Vérifie la plage thermique du fluide propre au type de planète
//
// Les lacs sont construits après le Priority-Flood à partir de la profondeur
// et de l'aire réelles des bassins, jamais à partir d'un minimum local isolé.
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height (altitude en mètres)
// - ClimateTexture (RGBA32F) : R=temperature (°C) - DOIT être calculée AVANT
//
// Sorties :
// - water_mask (R8UI) : 0=terre, 1=eau (sera reclassifié après)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// Masque d'eau en écriture (R8UI)
layout(set = 0, binding = 1, r8ui) uniform writeonly uimage2D water_mask;

// Texture climat en lecture (R=température en °C)
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D climate_texture;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform WaterParams {
    uint width;           // Largeur texture
    uint height;          // Hauteur texture
    float sea_level;      // Niveau de la mer
    float lake_threshold; // Réservé pour compatibilité UBO (non utilisé)
    uint atmosphere_type; // 0=Terran, 1=Toxique, 2=Volcanique, 4=Mort
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE = 0u;
const uint WATER_POTENTIAL = 1u;  // Eau potentielle (sera classifiée après)

// Limites de l'eau liquide Terran / monde mort.
const float WATER_MIN_TEMP = -21.0;    // Point de congélation (°C)
const float WATER_MAX_TEMP = 100.0;  // Point d'ébullition (°C)

bool temperatureAllowsSurfaceFluid(float temperature) {
    if (params.atmosphere_type == 1u) {
        // Saumures/acides et solvants exotiques du type toxique.
        return temperature >= -55.0 && temperature <= 550.0;
    }
    if (params.atmosphere_type == 2u) {
        // Le masque hydrologique représente ici de la lave ou du magma.
        return temperature >= 150.0 && temperature <= 550.0;
    }
    return temperature >= WATER_MIN_TEMP && temperature <= WATER_MAX_TEMP;
}

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
    // Eau, saumure/acide ou lave selon le monde. En dehors de sa plage de
    // stabilité, le fluide n'est pas classé comme surface liquide.
    bool temperature_allows_water = temperatureAllowsSurfaceFluid(temperature);
    
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
    
    // === ÉCRITURE DES RÉSULTATS ===
    
    // Masque d'eau
    uint water_type = is_water ? WATER_POTENTIAL : WATER_NONE;
    imageStore(water_mask, pixel, uvec4(water_type, 0u, 0u, 0u));
    
}
