#[compute]
#version 450

// ============================================================================
// EROSION SEDIMENT SHADER - Étape 2.3 : Transport de Sédiments
// ============================================================================
// Troisième passe du cycle d'érosion hydraulique.
// Gère l'érosion (arrachage de matériau) et le dépôt (sédimentation).
// La capacité de transport dépend de la vitesse d'écoulement et de la pente.
//
// Entrées :
// - GeoTexture Input (RGBA32F) : lecture seule (ping-pong)
//
// Sorties :
// - GeoTexture Output (RGBA32F) : écriture seule
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// GeoTexture entrée (lecture)
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_input;

// GeoTexture sortie (écriture) - ping-pong
layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D geo_output;

// FluxTexture (R32F) - en lecture pour estimer la vélocité
layout(set = 0, binding = 2, r32f) uniform readonly image2D flux_texture;

// Uniform Buffer : Paramètres de sédiment
layout(set = 1, binding = 0, std140) uniform SedimentParams {
    uint width;                  // Largeur texture
    uint height;                 // Hauteur texture
    float erosion_rate;          // Taux d'érosion (0-1) - typiquement 0.01-0.1
    float deposition_rate;       // Taux de dépôt (0-1) - typiquement 0.01-0.1
    float capacity_multiplier;   // Multiplicateur capacité transport
    float min_slope;             // Pente minimale pour érosion
    float sea_level;             // Niveau de la mer
    float bedrock_hardness;      // Résistance du bedrock (0-1)
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float MIN_WATER = 0.0001;
const float MIN_SEDIMENT = 0.00001;

// Offsets des 4 voisins cardinaux (pour calcul de pente)
const ivec2 CARDINAL[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0),
    ivec2(0, -1), ivec2(0, 1)
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

/// Calculer la pente maximale descendante
float calculateMaxSlope(ivec2 pixel, float surface, int w, int h) {
    float max_slope = 0.0;
    
    for (int i = 0; i < 4; i++) {
        int nx = wrapX(pixel.x + CARDINAL[i].x, w);
        int ny = clampY(pixel.y + CARDINAL[i].y, h);
        
        vec4 n_geo = imageLoad(geo_input, ivec2(nx, ny));
        float n_surface = n_geo.r + n_geo.a;
        
        float slope = (surface - n_surface);
        max_slope = max(max_slope, slope);
    }
    
    return max_slope;
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
    vec4 geo = imageLoad(geo_input, pixel);
    float flux = imageLoad(flux_texture, pixel).r;
    
    float height = geo.r;
    float bedrock = geo.g;
    float sediment = geo.b;
    float water = geo.a;
    
    // Ignorer les cellules océaniques
    if (height < params.sea_level) {
        imageStore(geo_output, pixel, geo);
        return;
    }
    
    // Surface = terrain + eau
    float surface = height + water;
    
    // === CALCUL DE LA CAPACITÉ DE TRANSPORT ===
    // La capacité dépend de :
    // - La quantité d'eau (plus d'eau = plus de transport)
    // - La vitesse (approximée par le flux)
    // - La pente (plus raide = plus de capacité)
    
    float max_slope = calculateMaxSlope(pixel, surface, w, h);
    
    // Estimation de la vélocité basée sur le flux
    float velocity = flux / max(water, MIN_WATER);
    velocity = clamp(velocity, 0.0, 10.0);  // Limiter
    
    // Capacité de transport : C = Kc * slope * velocity * water
    float capacity = params.capacity_multiplier * max_slope * velocity * water;
    capacity = max(capacity, 0.0);
    
    // === ÉROSION OU DÉPÔT ===
    float delta_sediment = 0.0;
    float delta_height = 0.0;
    
    if (sediment < capacity && water > MIN_WATER && max_slope > params.min_slope) {
        // === ÉROSION ===
        // L'eau peut transporter plus de sédiment qu'elle n'en a
        // -> Éroder le terrain
        
        float erosion_amount = (capacity - sediment) * params.erosion_rate;
        
        // Le bedrock résiste à l'érosion
        // bedrock = 1.0 = roche dure, bedrock = 0.0 = sédiment meuble
        float hardness = mix(0.1, 1.0, bedrock * params.bedrock_hardness);
        erosion_amount /= hardness;
        
        // Ne pas éroder plus que ce qui est disponible
        erosion_amount = min(erosion_amount, height - params.sea_level + 100.0);
        erosion_amount = max(erosion_amount, 0.0);
        
        delta_height = -erosion_amount;
        delta_sediment = erosion_amount;
        
    } else if (sediment > capacity) {
        // === DÉPÔT ===
        // L'eau transporte plus de sédiment qu'elle ne peut
        // -> Déposer l'excès
        
        float deposition_amount = (sediment - capacity) * params.deposition_rate;
        deposition_amount = min(deposition_amount, sediment);  // Ne pas déposer plus qu'on a
        
        delta_height = deposition_amount;
        delta_sediment = -deposition_amount;
    }
    
    // === APPLIQUER LES CHANGEMENTS ===
    float new_height = height + delta_height;
    float new_sediment = sediment + delta_sediment;
    
    // Clamping de sécurité
    new_sediment = max(new_sediment, 0.0);
    
    // Le bedrock diminue légèrement là où l'érosion se produit
    // (création de sédiments meubles)
    float new_bedrock = bedrock;
    if (delta_height < 0.0) {
        new_bedrock = max(bedrock - 0.001, 0.0);
    } else if (delta_height > 0.0) {
        // Les dépôts sont meubles
        new_bedrock = max(bedrock - 0.005, 0.0);
    }
    
    // === ÉCRITURE DU RÉSULTAT ===
    vec4 new_geo = vec4(new_height, new_bedrock, new_sediment, water);
    
    imageStore(geo_output, pixel, new_geo);
}
