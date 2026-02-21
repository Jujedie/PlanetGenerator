#[compute]
#version 450

// ===========================================================================
// REGION GROWTH SHADER (Jump Flooding Algorithm)
// ===========================================================================
// Propage les régions via JFA : chaque pixel vérifie 9 voisins à ±step_size.
// Converge en O(log2(max_dim)) passes au lieu de O(max_dim) pour Dijkstra.
//
// La position du seed est encodée dans region_cost :
//   packed = float(seed_y * width + seed_x) + 1.0
// Fonctionne tant que width * height < 2^24 (~4096×4096).
//
// Utilise un ping-pong sur region_map / region_map_temp.
//
// Entrées :
//   - geo_texture (binding 0) : R=height (réservé pour usage futur)
//   - water_mask (binding 1) : masque eau (infranchissable)
//   - river_flux (binding 2) : flux des rivières (réservé)
//   - region_map_in (binding 3) : état actuel des régions
//   - region_cost_in (binding 4) : position du seed encodée
//
// Sorties :
//   - region_map_out (binding 5) : nouveaux IDs de région
//   - region_cost_out (binding 6) : nouvelles positions de seed encodées
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux;
layout(set = 0, binding = 3, r32ui) uniform readonly uimage2D region_map_in;
layout(set = 0, binding = 4, r32f) uniform readonly image2D region_cost_in;
layout(set = 0, binding = 5, r32ui) uniform writeonly uimage2D region_map_out;
layout(set = 0, binding = 6, r32f) uniform writeonly image2D region_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform GrowthParams {
    uint width;
    uint height;
    uint step_size;            // Taille du pas JFA (commence grand, diminue par 2)
    uint seed;                 // Seed global pour le bruit
    float sea_level;
    float river_threshold;     // Réservé (compatibilité)
    float cost_flat;           // Réservé (compatibilité)
    float cost_uphill;         // Réservé (compatibilité)
    float cost_river;          // Réservé (compatibilité)
    float noise_strength;      // Perturbation en pixels pour frontières organiques
    float padding1;
    float padding2;
} params;

// === FONCTIONS UTILITAIRES ===

// Hash pseudo-aléatoire (Déterministe)
uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x85ebca6bu;
    x ^= x >> 13u;
    x *= 0xc2b2ae35u;
    x ^= x >> 16u;
    return x;
}

uint hash2(uint x, uint y) {
    return hash(x ^ (y * 1664525u + 1013904223u));
}

float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

// Wrap X pour projection équirectangulaire (seamless horizontalement)
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// === ENCODAGE/DÉCODAGE POSITION SEED ===
// Pack (x, y) en un float : float(y * width + x) + 1.0
// Le +1.0 évite la valeur 0.0 (réservée)
// Précision garantie tant que y * width + x < 2^24 (max ~4096×4096)

ivec2 unpackCoords(float packed, uint w) {
    uint total = uint(packed - 1.0);
    return ivec2(int(total % w), int(total / w));
}

// === DISTANCE EUCLIDIENNE AVEC WRAP ===
// Calcule la distance² entre un point (éventuellement perturbé) et un seed
// Gère le wrap horizontal (projection équirectangulaire)
float wrappedDistSq(vec2 pt, ivec2 seed_pos, int w) {
    float dx = abs(pt.x - float(seed_pos.x));
    if (dx > float(w) * 0.5) dx = float(w) - dx;
    float dy = pt.y - float(seed_pos.y);
    return dx * dx + dy * dy;
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Eau : infranchissable, ne participe pas aux régions
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire l'état actuel de ce pixel
    uint current_region = imageLoad(region_map_in, pixel).r;
    float current_packed = imageLoad(region_cost_in, pixel).r;
    
    // Perturbation par pixel pour frontières organiques
    // Le hash est constant entre passes (ne dépend pas de step_size)
    // Cela crée des frontières irrégulières entre régions
    uint ph = hash2(uint(pixel.x) + params.seed, uint(pixel.y) + params.seed * 7u);
    float perturb_x = (hashToFloat(ph) - 0.5) * params.noise_strength * 2.0;
    float perturb_y = (hashToFloat(hash(ph)) - 0.5) * params.noise_strength * 2.0;
    vec2 perturbed = vec2(float(pixel.x) + perturb_x, float(pixel.y) + perturb_y);
    
    // Meilleur candidat trouvé
    uint best_region = current_region;
    float best_packed = current_packed;
    float best_dist = 1e30;
    
    // Si déjà assigné, calculer la distance au seed actuel
    if (current_region != 0xFFFFFFFFu) {
        ivec2 seed_pos = unpackCoords(current_packed, params.width);
        best_dist = wrappedDistSq(perturbed, seed_pos, w);
    }
    
    int step = int(params.step_size);
    
    // JFA : vérifier les 9 voisins à ±step (incluant le centre)
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = wrapX(pixel.x + dx * step, w);
            int ny = clampY(pixel.y + dy * step, h);
            ivec2 neighbor = ivec2(nx, ny);
            
            // Lire la région du voisin
            uint n_region = imageLoad(region_map_in, neighbor).r;
            if (n_region == 0xFFFFFFFFu) continue;
            
            // Décoder la position du seed de ce voisin
            float n_packed = imageLoad(region_cost_in, neighbor).r;
            ivec2 n_seed = unpackCoords(n_packed, params.width);
            
            // Calculer la distance depuis notre position perturbée vers ce seed
            float dist = wrappedDistSq(perturbed, n_seed, w);
            
            // Si c'est plus proche, adopter ce seed
            if (dist < best_dist) {
                best_dist = dist;
                best_region = n_region;
                best_packed = n_packed;
            }
        }
    }
    
    // Écrire le résultat (région et position du seed encodée)
    imageStore(region_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
    imageStore(region_cost_out, pixel, vec4(best_packed, 0.0, 0.0, 0.0));
}
