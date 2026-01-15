#[compute]
#version 450

// ============================================================================
// RIVER PROPAGATION SHADER - Propagation physique des rivières
// ============================================================================
// Simule l'écoulement de l'eau en suivant la topographie :
// - L'eau descend vers le voisin le plus bas (steepest descent)
// - Le flux s'accumule quand plusieurs rivières convergent (affluents)
// - Les rivières s'arrêtent quand elles atteignent l'eau (lac/mer)
//
// Utilise un schéma ping-pong pour éviter les race conditions.
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height
// - river_sources (R32UI) : Points sources
// - water_mask (R8UI) : Pour arrêter à l'eau
// - river_flux_input (R32F) : Flux actuel
//
// Sorties :
// - river_flux_output (R32F) : Flux mis à jour
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// Sources de rivières
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D river_sources;

// Masque d'eau
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

// Flux entrée (ping)
layout(set = 0, binding = 3, r32f) uniform readonly image2D flux_input;

// Flux sortie (pong)
layout(set = 0, binding = 4, r32f) uniform writeonly image2D flux_output;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform PropagationParams {
    uint width;           // Largeur texture
    uint height;          // Hauteur texture
    uint pass_index;      // Index de la passe
    float sea_level;      // Niveau de la mer
    float base_flux;      // Flux ajouté aux sources à chaque passe
    float min_slope;      // Pente minimale pour continuer
    float flux_decay;     // Facteur de décroissance du flux (ex: 0.999)
    uint seed;            // Seed pour variations
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float MIN_FLUX = 0.01;

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

// Direction opposée pour chaque voisin (pour savoir qui draine vers nous)
const int OPPOSITE_DIR[8] = int[8](7, 6, 5, 4, 3, 2, 1, 0);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Trouver la direction de drainage (voisin avec la plus grande pente descendante)
int findDrainageDirection(ivec2 pixel, float my_height, int w, int h) {
    int best_dir = -1;
    float best_slope = params.min_slope;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
        float n_height = n_geo.r;
        
        // Calculer la pente (positif = descente)
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
    
    // Vérification des limites
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Lire le flux actuel
    float current_flux = imageLoad(flux_input, pixel).r;
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    float my_height = geo.r;
    uint water_type = imageLoad(water_mask, pixel).r;
    uint source_id = imageLoad(river_sources, pixel).r;
    
    // === SI C'EST DE L'EAU : conserver le flux mais ne pas propager ===
    if (water_type > 0u) {
        // L'eau absorbe le flux (embouchure de rivière)
        imageStore(flux_output, pixel, vec4(current_flux, 0.0, 0.0, 0.0));
        return;
    }
    
    // === SOURCE : ajouter du flux continu ===
    if (source_id > 0u) {
        current_flux += params.base_flux;
    }
    
    // === ACCUMULATION : collecter le flux des voisins en amont ===
    float incoming_flux = 0.0;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);
        
        // Flux du voisin
        float n_flux = imageLoad(flux_input, neighbor).r;
        if (n_flux < MIN_FLUX) {
            continue;
        }
        
        // Est-ce que ce voisin est sur l'eau ? (pas de flux depuis l'eau)
        uint n_water = imageLoad(water_mask, neighbor).r;
        if (n_water > 0u) {
            continue;
        }
        
        // Altitude du voisin
        vec4 n_geo = imageLoad(geo_texture, neighbor);
        float n_height = n_geo.r;
        
        // Trouver vers où ce voisin draine
        int n_drain_dir = findDrainageDirection(neighbor, n_height, w, h);
        
        // Est-ce que le voisin draine vers nous ?
        int opposite_dir = OPPOSITE_DIR[i];
        
        if (n_drain_dir == opposite_dir) {
            // Le voisin draine vers nous : accumuler son flux
            incoming_flux += n_flux * params.flux_decay;
        }
    }
    
    // === MISE À JOUR DU FLUX ===
    float new_flux = current_flux + incoming_flux;
    
    // === ÉCRITURE DU RÉSULTAT ===
    imageStore(flux_output, pixel, vec4(new_flux, 0.0, 0.0, 0.0));
}
