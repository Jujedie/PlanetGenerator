#[compute]
#version 450

// ============================================================================
// RIVER PROPAGATION SHADER - Propagation des rivières par descente de gradient
// ============================================================================
// Propage les rivières depuis les sources vers l'aval en suivant le terrain.
// Chaque itération, l'eau descend d'un pixel vers le voisin le plus bas.
// Le flux est accumulé quand plusieurs chemins convergent (affluents).
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height pour calculer la pente
// - RiverPathsInput (R32F) : flux accumulé jusqu'ici
// - RiverSourcesTexture (R32UI) : sources de rivières
//
// Sorties :
// - RiverPathsOutput (R32F) : flux mis à jour après propagation
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// RiverPathsInput (R32F) - lecture
layout(set = 0, binding = 1, r32f) uniform readonly image2D paths_input;

// RiverPathsOutput (R32F) - écriture (ping-pong)
layout(set = 0, binding = 2, r32f) uniform writeonly image2D paths_output;

// RiverSourcesTexture (R32UI) - lecture des sources
layout(set = 0, binding = 3, r32ui) uniform readonly uimage2D sources_texture;

// Uniform Buffer : Paramètres de propagation
layout(set = 1, binding = 0, std140) uniform PropagationParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    uint pass_index;         // Index de la passe (pour debug)
    float sea_level;         // Niveau de la mer
    float base_flux;         // Flux initial par source
    float min_slope;         // Pente minimale pour continuer (évite stagnation)
    float meander_factor;    // Facteur de méandre (0 = droit, 1 = sinueux)
    uint seed;               // Seed pour variation des méandres
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float MIN_FLUX = 0.001;
const float FLUX_DECAY = 0.999;  // Légère perte par évaporation

// 8 voisins (Moore neighborhood)
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// Distances aux voisins
const float NEIGHBOR_DIST[8] = float[8](
    1.41421, 1.0, 1.41421,
    1.0,          1.0,
    1.41421, 1.0, 1.41421
);

// Direction opposée pour chaque voisin
const int OPPOSITE_DIR[8] = int[8](7, 6, 5, 4, 3, 2, 1, 0);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire
int wrapX(int x, int w) {
    return (x + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Hash pseudo-aléatoire pour méandres
float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

/// Trouver la direction de drainage (voisin avec la plus grande pente descendante)
/// Avec légère variation pour créer des méandres naturels
int findDrainageDirection(ivec2 pixel, float surface, int w, int h) {
    int best_dir = -1;
    float best_slope = params.min_slope;
    
    // Bruit de méandre basé sur la position
    float meander_noise = hash21(vec2(pixel) * 0.1 + float(params.seed) * 0.01);
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
        float n_surface = n_geo.r;
        
        float slope = (surface - n_surface) / NEIGHBOR_DIST[i];
        
        // Ajouter une perturbation pour les méandres
        // Plus le terrain est plat, plus les méandres sont prononcés
        float meander_bonus = 0.0;
        if (params.meander_factor > 0.0 && slope > 0.0 && slope < 0.1) {
            float dir_hash = hash21(vec2(float(i), meander_noise));
            meander_bonus = dir_hash * params.meander_factor * 0.05;
        }
        
        float effective_slope = slope + meander_bonus;
        
        if (effective_slope > best_slope) {
            best_slope = effective_slope;
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
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    float current_flux = imageLoad(paths_input, pixel).r;
    uint source_id = imageLoad(sources_texture, pixel).r;
    
    float height = geo.r;
    
    // === SOURCE : Ajouter le flux de base si c'est une source ===
    if (source_id > 0u && params.pass_index == 0u) {
        current_flux = max(current_flux, params.base_flux);
    }
    
    // === SOUS LA MER : Les rivières se terminent ===
    if (height < params.sea_level) {
        // Conserver le flux (embouchure) mais ne pas propager
        imageStore(paths_output, pixel, vec4(current_flux, 0.0, 0.0, 0.0));
        return;
    }
    
    // === ACCUMULATION : Collecter le flux des voisins en amont ===
    float incoming_flux = 0.0;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
        float n_flux = imageLoad(paths_input, ivec2(nx, ny)).r;
        float n_height = n_geo.r;
        
        // Le voisin est-il sous la mer ?
        if (n_height < params.sea_level) {
            continue;
        }
        
        // La direction de drainage du voisin
        int n_drain_dir = findDrainageDirection(ivec2(nx, ny), n_height, w, h);
        
        // Est-ce que le voisin draine vers nous ?
        int opposite_dir = OPPOSITE_DIR[i];
        
        if (n_drain_dir == opposite_dir && n_flux > MIN_FLUX) {
            incoming_flux += n_flux * FLUX_DECAY;
        }
    }
    
    // === MISE À JOUR DU FLUX ===
    float new_flux = current_flux + incoming_flux;
    
    // Note: Le flux de source est injecté uniquement à pass_index == 0 (ligne 154)
    // Les passes suivantes ne font que propager et accumuler le flux
    
    // === ÉCRITURE DU RÉSULTAT ===
    imageStore(paths_output, pixel, vec4(new_flux, 0.0, 0.0, 0.0));
}
