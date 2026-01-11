#[compute]
#version 450

/*
 * Region Cost Field Shader
 * ========================
 * Calcule le champ de coût terrain pour la croissance des régions.
 * Le coût dépend de : pentes, rivières (barrières naturelles), bruit (irrégularité).
 * 
 * Entrées :
 *   - geo : GeoTexture (R=height, A=water_height)
 *   - river_flux : Carte de flux pour rivières
 * 
 * Sortie :
 *   - region_cost_field : Coût de traversée par pixel (R32F)
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée
layout(rgba32f, binding = 0) uniform readonly image2D geo;
layout(r32f, binding = 1) uniform readonly image2D river_flux;

// Texture de sortie
layout(r32f, binding = 2) uniform writeonly image2D cost_field;

// Paramètres uniformes
layout(std140, binding = 3) uniform Params {
    int width;
    int height;
    float k_slope;          // Poids de la pente dans le coût (défaut: 5.0)
    float k_river;          // Poids des rivières comme barrières (défaut: 10.0)
    float k_noise;          // Amplitude du bruit d'irrégularité (défaut: 2.0)
    float river_threshold;  // Seuil de flux pour considérer une rivière (défaut: 0.1)
    uint seed;              // Graine pour le bruit
    float base_cost;        // Coût de base (défaut: 1.0)
};

// === FONCTIONS UTILITAIRES ===

// Wrap X pour projection équirectangulaire (longitude seamless)
int wrapX(int x) {
    return (x + width) % width;
}

// Clamp Y (pas de wrap aux pôles)
int clampY(int y) {
    return clamp(y, 0, height - 1);
}

// Hash pour bruit pseudo-aléatoire déterministe
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// FBM simplifié pour domain warping
float fbm2(vec2 p, uint s) {
    float val = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    vec2 offset = vec2(float(s) * 0.123, float(s) * 0.456);
    
    for (int i = 0; i < 3; i++) {
        val += amp * (hash21((p + offset) * freq) * 2.0 - 1.0);
        amp *= 0.5;
        freq *= 2.0;
    }
    return val;
}

// === CALCUL DE PENTE ===
float computeSlope(ivec2 pixel) {
    // Gradient via différences finies (4 voisins)
    float h_center = imageLoad(geo, pixel).r;
    
    int x = pixel.x;
    int y = pixel.y;
    
    float h_left = imageLoad(geo, ivec2(wrapX(x - 1), y)).r;
    float h_right = imageLoad(geo, ivec2(wrapX(x + 1), y)).r;
    float h_up = imageLoad(geo, ivec2(x, clampY(y - 1))).r;
    float h_down = imageLoad(geo, ivec2(x, clampY(y + 1))).r;
    
    float dx = (h_right - h_left) * 0.5;
    float dy = (h_down - h_up) * 0.5;
    
    // Magnitude du gradient (pente)
    return sqrt(dx * dx + dy * dy);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
    
    // Lire les données géophysiques
    vec4 geo_data = imageLoad(geo, pixel);
    float water_height = geo_data.a;
    
    // Lire le flux de rivière
    float flux = imageLoad(river_flux, pixel).r;
    
    // Coût infini si eau (infranchissable pour régions terrestres)
    // On utilise une grande valeur plutôt que INF pour éviter les problèmes numériques
    if (water_height > 0.0) {
        imageStore(cost_field, pixel, vec4(1e10, 0.0, 0.0, 0.0));
        return;
    }
    
    // Calcul du coût de traversée
    float cost = base_cost;
    
    // 1. Contribution de la pente (montagnes = frontières naturelles)
    float slope = computeSlope(pixel);
    cost += k_slope * slope;
    
    // 2. Contribution des rivières (barrières naturelles)
    if (flux > river_threshold) {
        cost += k_river * (flux / river_threshold);
    }
    
    // 3. Bruit d'irrégularité (domain warping pour éviter lignes droites)
    vec2 p = vec2(float(pixel.x) / float(width), float(pixel.y) / float(height));
    vec2 warp = vec2(fbm2(p * 10.0, seed), fbm2(p * 10.0 + vec2(5.0, 3.0), seed + 1u));
    vec2 p_warped = p + warp * 0.05;
    float noise_val = hash21(p_warped * 100.0 + vec2(float(seed)));
    cost += k_noise * noise_val;
    
    // Stocker le coût final
    imageStore(cost_field, pixel, vec4(cost, 0.0, 0.0, 0.0));
}
