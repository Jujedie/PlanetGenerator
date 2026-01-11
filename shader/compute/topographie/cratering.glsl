#[compute]
#version 450

// ============================================================================
// CRATERING SHADER - Impacts de météorites (planètes sans atmosphère)
// ============================================================================
//
// Ce shader applique des cratères d'impact sur la heightmap pour les planètes
// sans atmosphère (atmosphere_type == 3). Les cratères sont générés de façon
// procédurale et déterministe à partir de la seed.
//
// Caractéristiques :
// - Distribution en loi de puissance (petits cratères fréquents, gros rares)
// - Profil réaliste : bowl (cuvette) + rim (rebord) + ejecta (éjectas)
// - Gestion du wrap X (projection équirectangulaire seamless)
// - Variation azimutale pour éviter les cercles parfaits
//
// Entrées (UBO) :
// - seed           : Graine de génération
// - width, height  : Dimensions de la texture
// - num_craters    : Nombre de cratères à générer
// - max_radius     : Rayon maximum en pixels
// - depth_ratio    : Ratio profondeur/rayon (typiquement 0.2-0.4)
// - rim_height     : Hauteur relative du rebord (0.1-0.3)
// - ejecta_extent  : Extension des éjectas (1.5-3.0 × rayon)
//
// Sorties :
// - GeoTexture modifiée (R=height, G=bedrock)
//
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée/sortie : GeoTexture (état géophysique)
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_texture;

// Uniform Buffer : Paramètres de génération
layout(set = 1, binding = 0, std140) uniform CrateringParams {
    uint seed;              // Graine de génération
    uint width;             // Largeur texture
    uint height;            // Hauteur texture
    uint num_craters;       // Nombre de cratères
    float max_radius;       // Rayon maximum (pixels)
    float min_radius;       // Rayon minimum (pixels)
    float depth_ratio;      // Profondeur / rayon (en unités réelles)
    float rim_height_ratio; // Hauteur rebord / profondeur
    float ejecta_extent;    // Extension éjectas (× rayon)
    float ejecta_decay;     // Décroissance exponentielle éjectas
    float azimuth_variation;// Variation azimutale (0-1)
    float meters_per_pixel; // Échelle de conversion pixels → mètres
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Nombre maximum de cratères testés par pixel (pour éviter boucle infinie)
const int MAX_CRATERS_PER_PIXEL = 200;

// ============================================================================
// FONCTIONS HASH (génération déterministe)
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

float rand(uint h) {
    return float(h) / 4294967295.0;
}

// ============================================================================
// GÉNÉRATION PROCÉDURALE DE CRATÈRE
// ============================================================================

// Génère les paramètres d'un cratère à partir de son index
struct Crater {
    vec2 center;    // Position (x, y) en pixels
    float radius;   // Rayon en pixels
    float depth;    // Profondeur en mètres
    float rim_h;    // Hauteur du rebord en mètres
    float rotation; // Rotation pour variation azimutale
};

Crater generateCrater(uint crater_idx, uint seed_base) {
    Crater c;
    
    // Hash unique pour ce cratère
    uint h0 = hash(crater_idx + seed_base);
    uint h1 = hash(h0);
    uint h2 = hash(h1);
    uint h3 = hash(h2);
    uint h4 = hash(h3);
    uint h5 = hash(h4);
    
    // Position aléatoire (uniforme sur la surface)
    c.center.x = rand(h0) * float(params.width);
    c.center.y = rand(h1) * float(params.height);
    
    // Rayon : distribution en loi de puissance (exposant -2)
    // Favorise les petits cratères, rend les gros rares
    float u = rand(h2);
    float min_r = params.min_radius;
    float max_r = params.max_radius;
    // Inverse de la CDF de la loi de puissance
    c.radius = min_r * pow(max_r / min_r, u);
    
    // Profondeur EN MÈTRES : rayon (pixels) × échelle × ratio
    // Cratères lunaires typiques : profondeur ≈ 5-10% du diamètre
    float radius_meters = c.radius * params.meters_per_pixel;
    float depth_base = radius_meters * params.depth_ratio;
    // Variation ±30% pour réalisme
    c.depth = depth_base * (0.7 + 0.6 * rand(h3));
    
    // Hauteur du rebord EN MÈTRES
    c.rim_h = c.depth * params.rim_height_ratio * (0.8 + 0.4 * rand(h4));
    
    // Rotation pour variation azimutale
    c.rotation = rand(h5) * TAU;
    
    return c;
}

// ============================================================================
// DISTANCE CYCLIQUE (wrap X pour équirectangulaire)
// ============================================================================

float cyclicDistanceX(float x1, float x2, float width) {
    float dx = abs(x1 - x2);
    return min(dx, width - dx);
}

// Distance 2D avec wrap X
float cyclicDistance2D(vec2 p1, vec2 p2, float width) {
    float dx = cyclicDistanceX(p1.x, p2.x, width);
    float dy = p1.y - p2.y;
    return sqrt(dx * dx + dy * dy);
}

// ============================================================================
// PROFIL DE CRATÈRE
// ============================================================================

// Calcule la modification d'élévation due à un cratère
// Retourne (delta_height, delta_bedrock)
vec2 craterProfile(vec2 pixel, Crater crater, float width) {
    float dist = cyclicDistance2D(pixel, crater.center, width);
    float r = crater.radius;
    
    // Hors de la zone d'influence (éjectas)
    if (dist > r * params.ejecta_extent) {
        return vec2(0.0);
    }
    
    float normalized_dist = dist / r;
    
    // Angle pour variation azimutale
    vec2 dir = pixel - crater.center;
    // Gérer wrap X pour direction
    if (abs(dir.x) > width * 0.5) {
        dir.x = (dir.x > 0.0) ? dir.x - width : dir.x + width;
    }
    float angle = atan(dir.y, dir.x) + crater.rotation;
    
    // Variation azimutale (rend le cratère non-circulaire)
    float azimuth_factor = 1.0 + params.azimuth_variation * 0.3 * (
        sin(angle * 2.0) * 0.5 + 
        sin(angle * 3.0 + 1.5) * 0.3 +
        sin(angle * 5.0 + 2.7) * 0.2
    );
    
    // Appliquer variation au rayon effectif
    float effective_r = r * azimuth_factor;
    float eff_normalized = dist / effective_r;
    
    float delta_height = 0.0;
    float delta_bedrock = 0.0;
    
    if (eff_normalized < 1.0) {
        // === INTÉRIEUR DU CRATÈRE ===
        
        // Profil en bol (bowl) - parabole inversée
        // Forme : depth * (1 - (d/r)^2) * smoothstep pour bords
        float bowl_factor = 1.0 - eff_normalized * eff_normalized;
        float edge_smooth = smoothstep(0.0, 0.3, 1.0 - eff_normalized);
        delta_height = -crater.depth * bowl_factor * edge_smooth;
        
        // Fond plat pour gros cratères (> 50 pixels)
        if (crater.radius > 50.0 && eff_normalized < 0.4) {
            float flat_factor = smoothstep(0.4, 0.2, eff_normalized);
            float flat_depth = -crater.depth * 0.85;
            delta_height = mix(delta_height, flat_depth, flat_factor);
        }
        
        // Rebord (rim) - pic gaussien près du bord
        float rim_center = 0.9;
        float rim_width = 0.15;
        float rim_factor = exp(-pow((eff_normalized - rim_center) / rim_width, 2.0));
        delta_height += crater.rim_h * rim_factor;
        
        // Bedrock exposé sur les parois (roche mise à nu)
        delta_bedrock = 0.2 * (1.0 - eff_normalized);
        
    } else if (eff_normalized < params.ejecta_extent) {
        // === ZONE D'ÉJECTAS ===
        
        // Rebord externe (rim externe)
        if (eff_normalized < 1.3) {
            float outer_rim = exp(-pow((eff_normalized - 1.0) / 0.15, 2.0));
            delta_height = crater.rim_h * 0.7 * outer_rim;
        }
        
        // Éjectas : décroissance exponentielle
        float ejecta_start = 1.2;
        if (eff_normalized > ejecta_start) {
            float ejecta_dist = (eff_normalized - ejecta_start) / (params.ejecta_extent - ejecta_start);
            float ejecta_height = crater.depth * 0.15 * exp(-params.ejecta_decay * ejecta_dist);
            
            // Variation radiale pour texture des éjectas
            float ray_pattern = 0.5 + 0.5 * sin(angle * 12.0 + crater.rotation * 5.0);
            ejecta_height *= (0.5 + 0.5 * ray_pattern);
            
            delta_height += ejecta_height;
        }
        
        // Légère augmentation bedrock (débris rocheux)
        delta_bedrock = 0.05 * (params.ejecta_extent - eff_normalized) / params.ejecta_extent;
    }
    
    return vec2(delta_height, delta_bedrock);
}

// ============================================================================
// MAIN SHADER
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Bounds check
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire les données actuelles
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    float bedrock = geo.g;
    
    // Position du pixel
    vec2 pixelPos = vec2(float(pixel.x), float(pixel.y));
    
    // Accumuler les effets de tous les cratères
    float total_delta_height = 0.0;
    float total_delta_bedrock = 0.0;
    
    // Pour chaque cratère, calculer son effet sur ce pixel
    uint num_to_process = min(params.num_craters, uint(MAX_CRATERS_PER_PIXEL * 20));
    
    for (uint i = 0u; i < num_to_process; i++) {
        Crater c = generateCrater(i, params.seed);
        
        // Optimisation : skip si trop loin (au-delà de la zone d'influence max)
        float max_influence = c.radius * params.ejecta_extent;
        float dist = cyclicDistance2D(pixelPos, c.center, float(params.width));
        
        if (dist <= max_influence) {
            vec2 delta = craterProfile(pixelPos, c, float(params.width));
            
            // Les cratères plus récents (index plus élevé) modifient les précédents
            // Utiliser un blend qui privilégie les impacts profonds
            total_delta_height += delta.x;
            total_delta_bedrock = max(total_delta_bedrock, delta.y);
        }
    }
    
    // Appliquer les modifications
    height += total_delta_height;
    bedrock = clamp(bedrock + total_delta_bedrock, 0.0, 1.0);
    
    // Écrire le résultat
    geo.r = height;
    geo.g = bedrock;
    
    imageStore(geo_texture, pixel, geo);
}
