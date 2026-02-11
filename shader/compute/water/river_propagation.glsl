#[compute]
#version 450

// ============================================================================
// RIVER PROPAGATION SHADER - Propagation physique des rivières
// ============================================================================
// Simule l'écoulement de l'eau en suivant la topographie.
// 
// APPROCHE : Collecte en amont (backward-collect)
// Chaque pixel regarde ses 8 voisins. Pour chaque voisin, il calcule
// la direction de steepest descent de ce voisin. Si ce voisin pointe vers
// le pixel courant, on collecte son flux.
// Les sources injectent du flux à chaque passe.
//
// Ce shader est exécuté en ping-pong (flux_input → flux_output) pendant
// N itérations (N ≈ max(width, height) pour que le flux traverse toute la carte).
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height
// - river_sources (R32UI) : Points sources (ID > 0)
// - water_mask (R8UI) : Pour arrêter à l'eau existante
// - flux_input (R32F) : Flux actuel (ping)
//
// Sorties :
// - flux_output (R32F) : Flux mis à jour (pong)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r32ui)   uniform readonly uimage2D river_sources;
layout(set = 0, binding = 2, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 3, r32f)    uniform readonly image2D flux_input;
layout(set = 0, binding = 4, r32f)    uniform writeonly image2D flux_output;

layout(set = 1, binding = 0, std140) uniform PropagationParams {
    uint width;
    uint height;
    uint pass_index;
    float sea_level;
    float source_flux;     // Flux ajouté aux sources à chaque passe
    float min_slope;       // Pente minimale pour drainage
    float flux_transfer;   // Fraction du flux transféré (ex: 0.95)
    uint seed;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// 8 voisins (Moore neighborhood)
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// Distances aux voisins (diagonales = sqrt(2))
const float NEIGHBOR_DIST[8] = float[8](
    1.41421, 1.0, 1.41421,
    1.0,          1.0,
    1.41421, 1.0, 1.41421
);

// Index du voisin opposé (si voisin[i] est NW, opposé est SE = index 7)
const int OPPOSITE[8] = int[8](7, 6, 5, 4, 3, 2, 1, 0);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire (cylindrique)
int wrapX(int x, int w) {
    return ((x % w) + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Trouver la direction de drainage d'un pixel (voisin avec la plus grande pente descendante)
/// Retourne l'index du voisin (0-7), ou -1 si pas de descente.
int findDrainageDir(ivec2 pixel, float my_height, int w, int h) {
    int best_dir = -1;
    float best_slope = params.min_slope;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        float n_height = imageLoad(geo_texture, ivec2(nx, ny)).r;
        float slope = (my_height - n_height) / NEIGHBOR_DIST[i];
        
        if (slope > best_slope) {
            best_slope = slope;
            best_dir = i;
        }
    }
    
    return best_dir;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) return;
    
    // === PIXEL SUR L'EAU : absorbe le flux, ne propage plus ===
    uint water_type = imageLoad(water_mask, pixel).r;
    float current_flux = imageLoad(flux_input, pixel).r;
    
    if (water_type > 0u) {
        // L'eau absorbe : on conserve le flux accumulé (embouchure)
        imageStore(flux_output, pixel, vec4(current_flux, 0.0, 0.0, 0.0));
        return;
    }
    
    // === INJECTION AUX SOURCES ===
    uint source_id = imageLoad(river_sources, pixel).r;
    float new_flux = 0.0;
    
    if (source_id > 0u) {
        new_flux += params.source_flux;
    }
    
    // === COLLECTE DU FLUX EN AMONT ===
    // Pour chaque voisin, vérifier si ce voisin draine vers nous
    float my_height = imageLoad(geo_texture, pixel).r;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);
        
        // Pas de flux depuis l'eau
        uint n_water = imageLoad(water_mask, neighbor).r;
        if (n_water > 0u) continue;
        
        // Flux du voisin
        float n_flux = imageLoad(flux_input, neighbor).r;
        if (n_flux < 0.001) continue;
        
        // Hauteur du voisin
        float n_height = imageLoad(geo_texture, neighbor).r;
        
        // Direction de drainage du voisin
        int n_drain_dir = findDrainageDir(neighbor, n_height, w, h);
        
        // Le voisin i draine vers nous si sa direction de drainage est l'opposé de i
        if (n_drain_dir == OPPOSITE[i]) {
            new_flux += n_flux * params.flux_transfer;
        }
    }
    
    // === ÉCRITURE ===
    imageStore(flux_output, pixel, vec4(new_flux, 0.0, 0.0, 0.0));
}
