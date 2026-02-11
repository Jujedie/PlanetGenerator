#[compute]
#version 450

// ============================================================================
// RIVER SOURCES SHADER - Détection des points sources de rivières
// ============================================================================
// Identifie les points de départ des rivières basés sur :
// - Altitude élevée au-dessus du niveau de la mer
// - Précipitations suffisantes
// - Espacement minimum entre sources (grille de cellules compétitives)
// - Score pondéré par altitude * précipitations pour choisir le meilleur candidat
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height
// - ClimateTexture (RGBA32F) : R=temperature, G=precipitation
// - water_mask (R8UI) : Pour éviter de placer sources dans l'eau existante
//
// Sorties :
// - river_sources (R32UI) : ID unique de la source (0 = pas de source)
// - river_flux (R32F) : Flux initial aux sources
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 3, r32ui)   uniform writeonly uimage2D river_sources;
layout(set = 0, binding = 4, r32f)    uniform writeonly image2D river_flux;

layout(set = 1, binding = 0, std140) uniform SourceParams {
    uint width;
    uint height;
    uint seed;
    float sea_level;
    float min_altitude;        // Altitude min au-dessus du niveau mer
    float min_precipitation;   // Précipitation min pour créer une source
    float cell_size;           // Espacement entre sources (taille cellule en pixels)
    float base_flux;           // Flux initial par source
} params;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Hash pseudo-aléatoire pour grille de cellules
uint hashCell(ivec2 cell, uint seed) {
    uint h = uint(cell.x) * 374761393u + uint(cell.y) * 668265263u + seed;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return h;
}

/// Score de compétition pour un pixel dans sa cellule
/// Pondéré par altitude et précipitations pour favoriser les bonnes sources
float getCompetitionScore(ivec2 pixel, ivec2 cell, uint seed, float height, float precipitation) {
    uint h = hashCell(cell, seed) ^ uint(pixel.x * 73856093) ^ uint(pixel.y * 19349663);
    float random_part = float(h & 0xFFFFu) / 65535.0;
    // Score = 40% random + 30% altitude normalisée + 30% précipitations
    float alt_normalized = clamp((height - params.sea_level) / 5000.0, 0.0, 1.0);
    return random_part * 0.4 + alt_normalized * 0.3 + precipitation * 0.3;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) return;
    
    // Valeurs par défaut : pas de source
    uint source_id = 0u;
    float flux = 0.0;
    
    // Pas de source sur l'eau existante
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(river_sources, pixel, uvec4(0u));
        imageStore(river_flux, pixel, vec4(0.0));
        return;
    }
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    
    float height = geo.r;
    float precipitation = climate.g;
    
    // === CRITÈRES D'ÉLIGIBILITÉ ===
    bool is_eligible = true;
    
    // Au-dessus du niveau de la mer + altitude minimale
    if (height < params.sea_level + params.min_altitude)
        is_eligible = false;
    
    // Précipitations suffisantes
    if (precipitation < params.min_precipitation)
        is_eligible = false;
    
    // Pas aux pôles extrêmes
    if (pixel.y < 3 || pixel.y >= h - 3)
        is_eligible = false;
    
    if (is_eligible) {
        // Déterminer la cellule
        int cell_size = max(1, int(params.cell_size));
        ivec2 cell = pixel / cell_size;
        
        // Score de ce pixel
        float my_score = getCompetitionScore(pixel, cell, params.seed, height, precipitation);
        
        // Limites de la cellule
        ivec2 cell_start = cell * cell_size;
        ivec2 cell_end = min(cell_start + ivec2(cell_size), ivec2(w, h));
        
        // Compétition : est-on le meilleur pixel éligible de la cellule ?
        bool is_best = true;
        
        for (int cy = cell_start.y; cy < cell_end.y && is_best; cy++) {
            for (int cx = cell_start.x; cx < cell_end.x && is_best; cx++) {
                ivec2 other = ivec2(cx, cy);
                if (other == pixel) continue;
                
                uint other_water = imageLoad(water_mask, other).r;
                if (other_water > 0u) continue;
                
                vec4 other_geo = imageLoad(geo_texture, other);
                vec4 other_climate = imageLoad(climate_texture, other);
                
                float other_height = other_geo.r;
                float other_precip = other_climate.g;
                
                bool other_eligible = (other_height >= params.sea_level + params.min_altitude) 
                                   && (other_precip >= params.min_precipitation)
                                   && (other.y >= 3 && other.y < h - 3);
                
                if (other_eligible) {
                    float other_score = getCompetitionScore(other, cell, params.seed, other_height, other_precip);
                    if (other_score > my_score) {
                        is_best = false;
                    }
                }
            }
        }
        
        if (is_best) {
            // Générer un ID unique (position-based, +1 pour éviter 0)
            source_id = uint(pixel.y * w + pixel.x) + 1u;
            
            // Flux initial proportionnel aux précipitations et à l'altitude
            float alt_factor = clamp((height - params.sea_level) / 3000.0, 0.5, 2.0);
            flux = params.base_flux * (0.5 + precipitation * 0.5) * alt_factor;
        }
    }
    
    imageStore(river_sources, pixel, uvec4(source_id, 0u, 0u, 0u));
    imageStore(river_flux, pixel, vec4(flux, 0.0, 0.0, 0.0));
}
