#[compute]
#version 450

// ============================================================================
// EROSION FLUX ACCUMULATION SHADER - Étape 2.4 : Accumulation de Drainage
// ============================================================================
// Quatrième passe du cycle d'érosion hydraulique.
// Propage le flux vers l'aval pour créer une carte d'accumulation de drainage.
// Cette carte permet de détecter les rivières (fort flux = rivière).
//
// Utilise une approche itérative : à chaque passe, le flux est propagé
// d'une cellule vers sa direction de drainage (plus grande pente descendante).
//
// Entrées :
// - GeoTexture (RGBA32F) : R=height pour calculer le drainage
// - FluxTexture Input (R32F) : flux accumulé jusqu'ici
//
// Sorties :
// - FluxTexture Output (R32F) : flux mis à jour
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture en lecture seule
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// FluxTexture entrée (lecture)
layout(set = 0, binding = 1, r32f) uniform readonly image2D flux_input;

// FluxTexture sortie (écriture) - ping-pong
layout(set = 0, binding = 2, r32f) uniform writeonly image2D flux_output;

// Uniform Buffer : Paramètres d'accumulation
layout(set = 1, binding = 0, std140) uniform AccumulationParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    uint pass_index;         // Index de la passe (pour débug)
    float sea_level;         // Niveau de la mer
    float base_flux;         // Flux de base par cellule (ex: 1.0 = 1 unité par pixel)
    float propagation_rate;  // Fraction du flux propagée (0-1)
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float MIN_FLUX = 0.001;

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

/// Trouver la direction de drainage (voisin avec la plus grande pente descendante)
int findDrainageDirection(ivec2 pixel, float surface, int w, int h) {
    int best_dir = -1;
    float best_slope = 0.0;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
        float n_surface = n_geo.r + n_geo.a;  // height + water
        
        float slope = (surface - n_surface) / NEIGHBOR_DIST[i];
        
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
    
    // Lire les données
    vec4 geo = imageLoad(geo_texture, pixel);
    float current_flux = imageLoad(flux_input, pixel).r;
    
    float height = geo.r;
    float water = geo.a;
    float surface = height + water;
    
    // Les cellules sous le niveau de la mer accumulent le flux (embouchures)
    // mais ne le propagent pas plus loin
    if (height < params.sea_level) {
        imageStore(flux_output, pixel, vec4(current_flux, 0.0, 0.0, 0.0));
        return;
    }
    
    // === ACCUMULATION : Collecter le flux des voisins en amont ===
    // Un voisin est "en amont" si sa direction de drainage pointe vers nous
    
    float incoming_flux = 0.0;
    
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        
        vec4 n_geo = imageLoad(geo_texture, ivec2(nx, ny));
        float n_flux = imageLoad(flux_input, ivec2(nx, ny)).r;
        
        // Vérifier si ce voisin draine vers nous
        float n_surface = n_geo.r + n_geo.a;
        
        // La direction de drainage du voisin
        int n_drain_dir = findDrainageDirection(ivec2(nx, ny), n_surface, w, h);
        
        // L'index opposé (le voisin nous voit à l'opposé)
        // NEIGHBORS[i] pointe du pixel vers le voisin
        // On veut savoir si le voisin pointe vers nous (direction opposée)
        int opposite_dir = (i + 4) % 8;
        
        if (n_drain_dir == opposite_dir && n_flux > MIN_FLUX) {
            // Ce voisin draine vers nous
            incoming_flux += n_flux * params.propagation_rate;
        }
    }
    
    // === MISE À JOUR DU FLUX ===
    // Ajouter le flux de base (pluie uniforme) + flux entrant
    float new_flux = params.base_flux + incoming_flux;
    
    // Conserver le flux existant et ajouter le nouveau
    // (accumulation progressive)
    new_flux = max(current_flux, new_flux);
    
    // === ÉCRITURE DU RÉSULTAT ===
    imageStore(flux_output, pixel, vec4(new_flux, 0.0, 0.0, 0.0));
}
