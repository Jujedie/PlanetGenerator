#[compute]
#version 450

// ============================================================================
// EROSION RAINFALL SHADER - Étape 2.1 : Pluie et Évaporation
// ============================================================================
// Première passe du cycle d'érosion hydraulique.
// Ajoute de l'eau de pluie basée sur la précipitation locale et applique l'évaporation.
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height, G=bedrock, B=sediment, A=water_height
// - ClimateTexture (RGBA32F) : R=temperature, G=humidity/precipitation
//
// Sorties :
// - GeoTexture : A=water_height mis à jour
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture/écriture
// R = height (mètres)
// G = bedrock (résistance 0-1)
// B = sediment (épaisseur sédiments)
// A = water_height (colonne d'eau)
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_texture;

// ClimateTexture en lecture seule
// R = temperature (°C)
// G = humidity/precipitation (0-1)
// B = wind_x
// A = wind_y
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;

// Uniform Buffer : Paramètres d'érosion
layout(set = 1, binding = 0, std140) uniform ErosionParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    float rain_rate;         // Taux de pluie (m/itération) - typiquement 0.001-0.01
    float evap_rate;         // Taux d'évaporation (0-1) - typiquement 0.01-0.05
    float sea_level;         // Niveau de la mer (pour ignorer océan)
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float MIN_WATER = 0.0001;  // Seuil minimal d'eau

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérification des limites
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    
    float height = geo.r;
    float bedrock = geo.g;
    float sediment = geo.b;
    float water = geo.a;
    
    float temperature = climate.r;
    float precipitation = climate.g;  // 0-1 normalisé
    
    // === PHASE 1 : PLUIE ===
    // Ajouter de l'eau uniquement au-dessus du niveau de la mer
    // La quantité dépend de la précipitation locale
    
    if (height > params.sea_level) {
        // Plus de pluie si précipitation élevée
        float rain_amount = params.rain_rate * precipitation;
        
        // Légère variation avec la température (moins d'eau si gel)
        if (temperature < 0.0) {
            rain_amount *= 0.3;  // Neige = moins d'eau liquide immédiate
        }
        
        water += rain_amount;
    }
    
    // === PHASE 2 : ÉVAPORATION ===
    // L'eau s'évapore proportionnellement à la température
    // Plus chaud = plus d'évaporation
    
    if (water > MIN_WATER) {
        // Taux d'évaporation augmente avec la température
        float temp_factor = clamp((temperature + 20.0) / 60.0, 0.1, 2.0);
        float evap_amount = params.evap_rate * temp_factor;
        
        // Appliquer l'évaporation
        water *= (1.0 - evap_amount);
        
        // Seuil minimal
        if (water < MIN_WATER) {
            water = 0.0;
        }
    }
    
    // === ÉCRITURE DU RÉSULTAT ===
    // Seul water_height (canal A) est modifié
    geo.a = water;
    
    imageStore(geo_texture, pixel, geo);
}
