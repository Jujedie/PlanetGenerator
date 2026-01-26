#[compute]
#version 450

// ============================================================================
// RIVER SOURCES SHADER - Détection des points sources de rivières
// ============================================================================
// Identifie les points de départ des rivières basés sur :
// - Altitude élevée au-dessus du niveau de la mer
// - Précipitations suffisantes
// - Espacement minimum entre sources (grille de cellules)
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height
// - ClimateTexture (RGBA32F) : G=precipitation
// - water_mask (R8UI) : Pour éviter de placer sources dans l'eau existante
//
// Sorties :
// - river_sources (R32UI) : ID unique de la source (0 = pas de source)
// - river_flux (R32F) : Flux initial aux sources
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// ClimateTexture en lecture seule
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;

// Masque d'eau pour éviter sources sur l'eau
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

// Sources de rivières en écriture (R32UI)
layout(set = 0, binding = 3, r32ui) uniform writeonly uimage2D river_sources;

// Flux initial en écriture (R32F)
layout(set = 0, binding = 4, r32f) uniform writeonly image2D river_flux;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform SourceParams {
    uint width;               // Largeur texture
    uint height;              // Hauteur texture
    uint seed;                // Seed pour variation
    float sea_level;          // Niveau de la mer
    float min_altitude;       // Altitude min au-dessus du niveau mer (ex: 200m)
    float min_precipitation;  // Précipitation min pour créer une source (ex: 0.3)
    float cell_size;          // Espacement entre sources (taille cellule en pixels)
    float base_flux;          // Flux initial par source
} params;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Hash pseudo-aléatoire 2D -> float [0, 1]
float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

/// Hash pour grille de cellules
uint hashCell(ivec2 cell, uint seed) {
    uint h = uint(cell.x) * 374761393u + uint(cell.y) * 668265263u + seed;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return h;
}

/// Calcule un score pour ce pixel dans sa cellule
float getCellScore(ivec2 pixel, ivec2 cell, uint seed) {
    // Hash unique pour ce pixel basé sur position relative dans la cellule
    uint h = hashCell(cell, seed) ^ uint(pixel.x * 73856093) ^ uint(pixel.y * 19349663);
    return float(h & 0xFFFFu) / 65535.0;
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
    
    // Valeurs par défaut : pas de source
    uint source_id = 0u;
    float flux = 0.0;
    
    // Vérifier si ce pixel est sur de l'eau (pas de source sur l'eau)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(river_sources, pixel, uvec4(source_id, 0u, 0u, 0u));
        imageStore(river_flux, pixel, vec4(flux, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    
    float height = geo.r;
    float precipitation = climate.g;  // Canal G = humidité/précipitation
    
    // Critères de base pour être une source potentielle
    bool is_eligible = true;
    
    // 1. Au-dessus du niveau de la mer + altitude minimale
    if (height < params.sea_level + params.min_altitude) {
        is_eligible = false;
    }
    
    // 2. Précipitations suffisantes
    if (precipitation < params.min_precipitation) {
        is_eligible = false;
    }
    
    // 3. Pas trop près des pôles (éviter sources aux extrêmes)
    if (pixel.y < 5 || pixel.y >= h - 5) {
        is_eligible = false;
    }
    
    if (is_eligible) {
        // Déterminer la cellule de ce pixel
        int cell_size = max(1, int(params.cell_size));
        ivec2 cell = pixel / cell_size;
        
        // Calculer le score de ce pixel
        float my_score = getCellScore(pixel, cell, params.seed);
        
        // Calculer les limites de la cellule
        ivec2 cell_start = cell * cell_size;
        ivec2 cell_end = min(cell_start + ivec2(cell_size), ivec2(w, h));
        
        // Trouver si on est le meilleur pixel éligible de la cellule
        bool is_best = true;
        
        for (int cy = cell_start.y; cy < cell_end.y && is_best; cy++) {
            for (int cx = cell_start.x; cx < cell_end.x && is_best; cx++) {
                ivec2 other = ivec2(cx, cy);
                if (other == pixel) continue;
                
                // Vérifier si l'autre pixel est éligible
                uint other_water = imageLoad(water_mask, other).r;
                if (other_water > 0u) continue;  // Sur l'eau
                
                vec4 other_geo = imageLoad(geo_texture, other);
                vec4 other_climate = imageLoad(climate_texture, other);
                
                float other_height = other_geo.r;
                float other_precip = other_climate.g;
                
                // Est-il éligible ?
                bool other_eligible = (other_height >= params.sea_level + params.min_altitude) 
                                   && (other_precip >= params.min_precipitation)
                                   && (other.y >= 5 && other.y < h - 5);
                
                if (other_eligible) {
                    float other_score = getCellScore(other, cell, params.seed);
                    if (other_score > my_score) {
                        is_best = false;
                    }
                }
            }
        }
        
        // Si on est le meilleur de la cellule, on devient une source
        if (is_best) {
            // Hash final pour probabilité (basé sur précipitations)
            float prob_hash = hash21(vec2(pixel) * 0.1 + float(params.seed) * 0.001);
            
            // Plus il pleut, plus de chance d'avoir une source
            float probability = 0.7 + precipitation * 0.3;  // 70% à 100%
            
            if (prob_hash < probability) {
                // Générer un ID unique (basé sur position)
                source_id = uint(pixel.y * w + pixel.x) + 1u;
                
                // Flux initial proportionnel aux précipitations
                flux = params.base_flux * (0.5 + precipitation);
            }
        }
    }
    
    // Écrire les résultats
    imageStore(river_sources, pixel, uvec4(source_id, 0u, 0u, 0u));
    imageStore(river_flux, pixel, vec4(flux, 0.0, 0.0, 0.0));
}
