#[compute]
#version 450

// ============================================================================
// RIVER SOURCES SHADER - Génération des sources de rivières
// ============================================================================
// Génère N points sources de rivières basés sur :
// - Altitude au-dessus du niveau de la mer
// - Précipitations suffisantes
// - Distance minimale entre sources (via hash spatial)
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height, A=water_height
// - ClimateTexture (RGBA32F) : G=precipitation
//
// Sorties :
// - RiverSourcesTexture (R32UI) : R=source_id (0 = pas de source)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// ClimateTexture en lecture seule
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;

// RiverSourcesTexture en écriture (R32UI)
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D sources_texture;

// Uniform Buffer : Paramètres de génération
layout(set = 1, binding = 0, std140) uniform SourceParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    uint seed;               // Seed pour génération pseudo-aléatoire
    uint max_sources;        // Nombre max de sources
    float sea_level;         // Niveau de la mer
    float min_altitude;      // Altitude minimale au-dessus de la mer (ex: 100m)
    float min_precipitation; // Précipitation minimale (ex: 0.3)
    float cell_size;         // Taille de cellule pour distance minimale
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

/// Hash pseudo-aléatoire uint -> float [0, 1]
float hash_u(uint n) {
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

/// Hash pour grille de cellules (évite clustering)
uint hashCell(ivec2 cell, uint seed) {
    uint h = uint(cell.x) * 374761393u + uint(cell.y) * 668265263u + seed;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return h;
}

/// Vérifier si ce pixel est éligible comme source
bool isValidSource(ivec2 pixel, float height, float precipitation) {
    // 1. Au-dessus du niveau de la mer + altitude minimale
    if (height < params.sea_level + params.min_altitude) {
        return false;
    }
    
    // 2. Précipitations suffisantes
    if (precipitation < params.min_precipitation) {
        return false;
    }
    
    // 3. Pas sur le bord Y (éviter sources aux pôles)
    if (pixel.y < 2 || pixel.y >= int(params.height) - 2) {
        return false;
    }
    
    return true;
}

/// Détermine si ce pixel est le "champion" de sa cellule
/// Un seul pixel par cellule peut être source (celui avec le meilleur hash)
bool isCellChampion(ivec2 pixel, uint seed) {
    // Calculer la cellule de ce pixel
    int cell_size = max(1, int(params.cell_size));
    ivec2 cell = pixel / cell_size;
    
    // Hash de la cellule pour déterminer la position du champion
    uint cell_hash = hashCell(cell, seed);
    
    // Position du champion dans la cellule
    int champ_x = int(cell_hash % uint(cell_size));
    int champ_y = int((cell_hash / uint(cell_size)) % uint(cell_size));
    
    ivec2 champ_local = ivec2(champ_x, champ_y);
    ivec2 pixel_local = pixel - cell * cell_size;
    
    return pixel_local == champ_local;
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
    
    // Valeur par défaut : pas de source
    uint source_id = 0u;
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    
    float height = geo.r;
    float precipitation = climate.g;  // Canal G = humidité/précipitation
    
    // Vérifier l'éligibilité
    if (isValidSource(pixel, height, precipitation)) {
        // Vérifier si ce pixel est le champion de sa cellule
        if (isCellChampion(pixel, params.seed)) {
            // Hash final pour décider si c'est vraiment une source
            // Basé sur la position et le seed
            float selection_hash = hash21(vec2(pixel) + float(params.seed) * 0.01);
            
            // Seuil adaptatif basé sur les précipitations
            // Plus il pleut, plus de chances d'avoir une source
            // Seuil réduit pour créer plus de sources
            float threshold = 0.3 - (precipitation - params.min_precipitation) * 0.4;
            threshold = clamp(threshold, 0.1, 0.5);
            
            if (selection_hash > threshold) {
                // Générer un ID unique pour cette source (basé sur position)
                source_id = uint(pixel.y * w + pixel.x) + 1u;
            }
        }
    }
    
    // Écrire le résultat
    imageStore(sources_texture, pixel, uvec4(source_id, 0u, 0u, 0u));
}
