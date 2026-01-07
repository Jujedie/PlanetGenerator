#[compute]
#version 450

// ============================================================================
// EROSION FLOW SHADER - Étape 2.2 : Écoulement de l'eau
// ============================================================================
// Deuxième passe du cycle d'érosion hydraulique.
// Calcule le flux d'eau entre cellules voisines selon le gradient de surface.
// Utilise une approche "pull" : chaque cellule collecte l'eau des voisins plus hauts.
//
// Entrées :
// - GeoTexture Input (RGBA32F) : lecture seule
//
// Sorties :
// - GeoTexture Output (RGBA32F) : écriture seule (ping-pong)
// - FluxTexture (R32F) : flux sortant pour accumulation rivières
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture entrée (lecture)
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_input;

// GeoTexture sortie (écriture) - ping-pong
layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D geo_output;

// FluxTexture (R32F) - pour accumulation rivières
layout(set = 0, binding = 2, r32f) uniform image2D flux_texture;

// Uniform Buffer : Paramètres d'écoulement
layout(set = 1, binding = 0, std140) uniform FlowParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    float flow_rate;         // Fraction d'eau qui s'écoule (0-1) - typiquement 0.1-0.5
    float min_slope;         // Pente minimale pour écoulement
    float sea_level;         // Niveau de la mer
    float gravity;           // Accélération gravitationnelle (9.81 pour Terre)
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float MIN_WATER = 0.0001;

// Offsets des 8 voisins (Moore neighborhood)
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// Distances aux voisins (1 pour cardinaux, sqrt(2) pour diagonaux)
const float NEIGHBOR_DIST[8] = float[8](
    1.41421, 1.0, 1.41421,
    1.0,          1.0,
    1.41421, 1.0, 1.41421
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection équirectangulaire (seamless)
int wrapX(int x, int w) {
    return (x + w) % w;
}

/// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

/// Obtenir la coordonnée voisine avec wrapping correct
ivec2 getNeighborCoord(ivec2 pixel, int neighborIdx, int w, int h) {
    ivec2 offset = NEIGHBORS[neighborIdx];
    int nx = wrapX(pixel.x + offset.x, w);
    int ny = clampY(pixel.y + offset.y, h);
    return ivec2(nx, ny);
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
    
    // Lire les données de la cellule courante
    vec4 geo = imageLoad(geo_input, pixel);
    
    float height = geo.r;
    float bedrock = geo.g;
    float sediment = geo.b;
    float water = geo.a;
    
    // Surface = hauteur terrain + eau
    float surface = height + water;
    
    // Ignorer les cellules sous le niveau de la mer (océan)
    if (height < params.sea_level) {
        // Dans l'océan, pas d'écoulement simulé
        imageStore(geo_output, pixel, geo);
        imageStore(flux_texture, pixel, vec4(0.0));
        return;
    }
    
    // === APPROCHE "PULL" : Collecter l'eau des voisins plus hauts ===
    // Pour chaque voisin plus haut, une fraction de son eau coule vers nous
    
    float water_received = 0.0;
    float total_outflow = 0.0;
    
    // D'abord, calculer combien de notre eau part vers les voisins plus bas
    float total_slope_down = 0.0;
    
    for (int i = 0; i < 8; i++) {
        ivec2 neighbor = getNeighborCoord(pixel, i, w, h);
        vec4 n_geo = imageLoad(geo_input, neighbor);
        
        float n_height = n_geo.r;
        float n_water = n_geo.a;
        float n_surface = n_height + n_water;
        
        // Pente vers le voisin
        float slope = (surface - n_surface) / NEIGHBOR_DIST[i];
        
        if (slope > params.min_slope) {
            // Ce voisin est plus bas, on peut y envoyer de l'eau
            total_slope_down += slope;
        }
    }
    
    // Distribuer notre eau vers les voisins plus bas (proportionnel à la pente)
    if (total_slope_down > 0.0 && water > MIN_WATER) {
        float water_to_distribute = water * params.flow_rate;
        
        for (int i = 0; i < 8; i++) {
            ivec2 neighbor = getNeighborCoord(pixel, i, w, h);
            vec4 n_geo = imageLoad(geo_input, neighbor);
            
            float n_height = n_geo.r;
            float n_water = n_geo.a;
            float n_surface = n_height + n_water;
            
            float slope = (surface - n_surface) / NEIGHBOR_DIST[i];
            
            if (slope > params.min_slope) {
                float fraction = slope / total_slope_down;
                total_outflow += water_to_distribute * fraction;
            }
        }
    }
    
    // Maintenant, collecter l'eau des voisins (approche symétrique)
    for (int i = 0; i < 8; i++) {
        ivec2 neighbor = getNeighborCoord(pixel, i, w, h);
        vec4 n_geo = imageLoad(geo_input, neighbor);
        
        float n_height = n_geo.r;
        float n_water = n_geo.a;
        float n_surface = n_height + n_water;
        
        // Le voisin est plus haut que nous ?
        float slope = (n_surface - surface) / NEIGHBOR_DIST[i];
        
        if (slope > params.min_slope && n_water > MIN_WATER) {
            // Calculer combien le voisin nous envoie
            // Il faut calculer sa distribution totale vers ses voisins plus bas
            
            float n_total_slope_down = 0.0;
            for (int j = 0; j < 8; j++) {
                ivec2 nn = getNeighborCoord(neighbor, j, w, h);
                vec4 nn_geo = imageLoad(geo_input, nn);
                float nn_surface = nn_geo.r + nn_geo.a;
                float nn_slope = (n_surface - nn_surface) / NEIGHBOR_DIST[j];
                if (nn_slope > params.min_slope) {
                    n_total_slope_down += nn_slope;
                }
            }
            
            if (n_total_slope_down > 0.0) {
                // Notre part de l'eau du voisin
                float our_slope = slope;  // C'est la pente du voisin vers nous
                float fraction = our_slope / n_total_slope_down;
                float n_water_to_distribute = n_water * params.flow_rate;
                water_received += n_water_to_distribute * fraction;
            }
        }
    }
    
    // === MISE À JOUR DE L'EAU ===
    float new_water = water - total_outflow + water_received;
    new_water = max(new_water, 0.0);
    
    // === ENREGISTRER LE FLUX SORTANT ===
    // Le flux est utilisé pour détecter les rivières
    float flux = total_outflow;
    
    // === ÉCRITURE DES RÉSULTATS ===
    vec4 new_geo = vec4(height, bedrock, sediment, new_water);
    
    imageStore(geo_output, pixel, new_geo);
    
    // Accumuler le flux (lecture-modification-écriture)
    float prev_flux = imageLoad(flux_texture, pixel).r;
    imageStore(flux_texture, pixel, vec4(prev_flux + flux, 0.0, 0.0, 0.0));
}
