#[compute]
#version 450

// ============================================================================
// CRUST AGE PROPAGATION - Jump Flooding Algorithm (JFA)
// ============================================================================
//
// Ce shader implémente l'algorithme JFA pour propager l'âge de la croûte océanique
// à partir des dorsales (frontières divergentes).
//
// Le JFA est exécuté en plusieurs passes avec un stepSize décroissant :
// - Pass 0: Initialisation (seeds aux dorsales)
// - Pass 1+: stepSize = max_dim/2, puis /2 jusqu'à 1
//
// FORMAT DE CRUST_AGE_TEXTURE:
// - R = seed_x (coordonnée X du pixel seed le plus proche, ou -1)
// - G = seed_y (coordonnée Y du pixel seed le plus proche, ou -1)
// - B = distance² (distance au carré pour éviter sqrt pendant JFA)
// - A = réservé
//
// Le calcul final de l'âge et subsidence se fait dans crust_age_finalize.glsl
//
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// ============================================================================
// BINDINGS
// ============================================================================

// Set 0: Textures
layout(set = 0, binding = 0, rgba32f) uniform readonly  image2D plates_texture;
layout(set = 0, binding = 1, rgba32f) uniform           image2D crust_age_texture;

// Set 1: Paramètres
layout(set = 1, binding = 0) uniform Params {
    uint width;
    uint height;
    uint pass_index;    // 0 = initialisation, 1+ = propagation JFA
    uint step_size;     // Taille du saut (commence à max_dim/2, divisé par 2 à chaque passe)
    float spreading_rate;  // Taux d'expansion en km/Ma (non utilisé ici)
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// Valeur "invalide" pour seed
const float NO_SEED = -1.0;

// Seuil pour détecter une dorsale (divergence < -0.2)
const float RIDGE_THRESHOLD = -0.2;

// Distance infinie (initialement)
const float INF_DIST = 1e20;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

// Wrap coordonnée X (continuité horizontale de la planète)
int wrapX(int x, int width) {
    if (x < 0) return x + width;
    if (x >= width) return x - width;
    return x;
}

// Clamp coordonnée Y (pôles)
int clampY(int y, int height) {
    return clamp(y, 0, height - 1);
}

// Calcule la distance² entre deux pixels (avec wrap horizontal)
float distanceSquared(ivec2 p1, ivec2 p2) {
    float dx = float(p1.x - p2.x);
    float w = float(params.width);
    
    // Wrap-around horizontal (plus court chemin)
    if (dx > w * 0.5) dx -= w;
    if (dx < -w * 0.5) dx += w;
    
    float dy = float(p1.y - p2.y);
    
    return dx * dx + dy * dy;
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
    
    // === PASSE 0: INITIALISATION ===
    if (params.pass_index == 0u) {
        // Lire les données de plaque
        vec4 plate_data = imageLoad(plates_texture, pixel);
        float convergence_type = plate_data.a;
        
        // Est-ce une dorsale (frontière divergente)?
        bool isRidge = convergence_type < RIDGE_THRESHOLD;
        
        vec4 result;
        if (isRidge) {
            // Ce pixel est un seed (dorsale)
            result = vec4(
                float(pixel.x),  // R: seed_x = self
                float(pixel.y),  // G: seed_y = self
                0.0,             // B: distance² = 0
                1.0              // A: valide
            );
        } else {
            // Pas de seed
            result = vec4(
                NO_SEED,         // R: pas de seed
                NO_SEED,         // G: pas de seed
                INF_DIST,        // B: distance infinie
                0.0              // A: invalide
            );
        }
        imageStore(crust_age_texture, pixel, result);
        return;
    }
    
    // === PASSES 1+: PROPAGATION JFA ===
    
    // Lire l'état actuel
    vec4 current = imageLoad(crust_age_texture, pixel);
    
    float best_seed_x = current.r;
    float best_seed_y = current.g;
    float best_dist_sq = current.b;
    
    int stepSize = int(params.step_size);
    
    // Parcourir les 9 voisins du pattern JFA (3x3 avec pas)
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = wrapX(pixel.x + dx * stepSize, int(params.width));
            int ny = clampY(pixel.y + dy * stepSize, int(params.height));
            
            ivec2 neighbor = ivec2(nx, ny);
            vec4 neighbor_data = imageLoad(crust_age_texture, neighbor);
            
            // Le voisin a-t-il un seed valide?
            if (neighbor_data.r != NO_SEED) {
                // Récupérer la position du seed du voisin
                ivec2 seed_pos = ivec2(int(neighbor_data.r), int(neighbor_data.g));
                
                // Calculer la distance² de ce pixel au seed du voisin
                float dist_sq = distanceSquared(pixel, seed_pos);
                
                // Est-ce mieux que notre meilleur actuel?
                if (dist_sq < best_dist_sq) {
                    best_dist_sq = dist_sq;
                    best_seed_x = neighbor_data.r;
                    best_seed_y = neighbor_data.g;
                }
            }
        }
    }
    
    // Écrire le résultat
    vec4 result = vec4(best_seed_x, best_seed_y, best_dist_sq, 
                       (best_seed_x != NO_SEED) ? 1.0 : 0.0);
    imageStore(crust_age_texture, pixel, result);
}
