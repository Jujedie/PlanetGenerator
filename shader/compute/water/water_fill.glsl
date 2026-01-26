#[compute]
#version 450

// ============================================================================
// WATER FILL SHADER - Identification des zones d'eau
// ============================================================================
// Étape 1 du système d'eau :
// - Identifie les pixels sous le niveau de la mer (eau potentielle)
// - Identifie les lacs en altitude (dépressions au-dessus du niveau mer)
// - Initialise les seeds JFA pour la détection des composantes connexes
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height
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

// 4 voisins cardinaux pour détection dépressions
const ivec2 NEIGHBORS_4[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
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
    
    // Lire l'altitude ET la colonne d'eau (déjà calculée dans base_elevation)
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    float water_height = geo.a;  // Canal A = colonne d'eau si sous le niveau de la mer
    
    // === CLASSIFICATION DE BASE ===
    bool is_water = false;
    
    // 1. Si water_height > 0, c'est que c'est sous le niveau de la mer
    if (water_height > 0.0) {
        is_water = true;
    }
    // 2. Détection des lacs en altitude (dépressions locales)
    else if (params.lake_threshold > 0.0) {
        // Un lac en altitude est une dépression : tous les voisins sont plus hauts
        bool is_depression = true;
        float min_neighbor_height = 1e10;
        
        for (int i = 0; i < 4; i++) {
            int nx = wrapX(pixel.x + NEIGHBORS_4[i].x, w);
            int ny = clampY(pixel.y + NEIGHBORS_4[i].y, h);
            
            vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
            float n_height = n_geo.r;
            
            min_neighbor_height = min(min_neighbor_height, n_height);
            
            // Si un voisin est plus bas ou au même niveau, pas une dépression
            if (n_height <= height) {
                is_depression = false;
            }
        }
        
        // C'est un lac si c'est une dépression significative
        if (is_depression && (min_neighbor_height - height) > params.lake_threshold) {
            is_water = true;
        }
    }
    
    // === ÉCRITURE DES RÉSULTATS ===
    
    // Masque d'eau
    uint water_type = is_water ? WATER_POTENTIAL : WATER_NONE;
    imageStore(water_mask, pixel, uvec4(water_type, 0u, 0u, 0u));
    
    // Seed JFA : chaque pixel d'eau est son propre seed au départ
    // (-1, -1) pour les pixels de terre
    ivec2 seed = is_water ? pixel : ivec2(-1, -1);
    imageStore(water_component, pixel, ivec4(seed, 0, 0));
}
