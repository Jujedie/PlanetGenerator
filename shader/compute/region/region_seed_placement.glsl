#[compute]
#version 450

// ===========================================================================
// REGION SEED PLACEMENT SHADER
// ===========================================================================
// Place un nombre cible de seeds administratifs sur la terre uniquement.
//
// Entrées :
//   - geo_texture (binding 0) : R=height pour déterminer terre/eau
//   - water_mask (binding 1) : masque eau (0=terre, 1/2=eau)
//
// Sorties :
//   - region_map (binding 2) : R32UI - ID de région (-1 = non assigné)
//   - region_cost (binding 3) : R32F - coût accumulé (INF = non assigné)
//   - region_seeds (binding 4) : RGBA32F - R=budget_remaining, G=origin_x, B=origin_y, A=is_active
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D region_map;
layout(set = 0, binding = 3, r32f) uniform writeonly image2D region_cost;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SeedParams {
    uint width;
    uint height;
    uint seed;
    float seed_probability;    // Probabilité dérivée de la surface et de la cible
    float sea_level;
    float budget_variation;    // 0.5 = variation de ±50%
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

uint hash3(uint x, uint y, uint z) {
    return hash(hash2(x, y) ^ (z * 2654435761u));
}

// Retourne un float dans [0, 1]
float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

bool isLand(ivec2 p) {
    uint waterType = imageLoad(water_mask, p).r;
    float elevation = imageLoad(geo_texture, p).r;
    return waterType == 0u && elevation >= params.sea_level;
}

// Distribution Matérn/blue-noise discrète : un pixel doit être candidat puis
// posséder le plus petit hash candidat de son voisinage 3x3. Cette répulsion
// locale évite à la fois les amas de seeds et les grands déserts continentaux
// produits par un simple tirage Bernoulli plafonné à 2 %.
bool isBlueNoiseSeed(ivec2 pixel, int w, int h, uint pixelHash) {
    if (hashToFloat(pixelHash) >= params.seed_probability) return false;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = wrapX(pixel.x + dx, w);
            int ny = clamp(pixel.y + dy, 0, h - 1);
            ivec2 candidate = ivec2(nx, ny);
            if (!isLand(candidate)) continue;
            uint candidateHash = hash3(uint(nx), uint(ny), params.seed);
            if (hashToFloat(candidateHash) >= params.seed_probability) continue;
            if (candidateHash < pixelHash ||
                    (candidateHash == pixelHash && (ny * w + nx) < (pixel.y * w + pixel.x))) {
                return false;
            }
        }
    }
    return true;
}

// Garantit un seed aux îles/enclaves entièrement contenues dans une fenêtre
// de 9x9. Une petite zone isolée reste ainsi autonome au lieu d'être rattachée
// par un saut à travers la mer.
bool isSmallComponentSeed(ivec2 pixel, int w, int h, uint pixelHash) {
    const int RADIUS = 4;
    bool touchesWindow = false;
    uint bestHash = pixelHash;
    ivec2 bestPixel = pixel;

    for (int dy = -RADIUS; dy <= RADIUS; dy++) {
        for (int dx = -RADIUS; dx <= RADIUS; dx++) {
            int nx = wrapX(pixel.x + dx, w);
            int ny = clamp(pixel.y + dy, 0, h - 1);
            ivec2 candidate = ivec2(nx, ny);
            if (!isLand(candidate)) continue;
            if (abs(dx) == RADIUS || abs(dy) == RADIUS) touchesWindow = true;

            uint candidateHash = hash3(uint(nx), uint(ny), params.seed);
            if (candidateHash < bestHash ||
                    (candidateHash == bestHash && (ny * w + nx) < (bestPixel.y * w + bestPixel.x))) {
                bestHash = candidateHash;
                bestPixel = candidate;
            }
        }
    }
    return !touchesWindow && all(equal(bestPixel, pixel));
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Vérifier si on est sur terre
    bool is_land = isLand(pixel);
    
    // Initialiser avec valeurs par défaut
    // region_map = 0xFFFFFFFF (invalide)
    // region_cost = +INF (pas encore atteint)
    
    if (!is_land) {
        // Eau : marquer comme infranchissable
        imageStore(region_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Hash déterministe pour ce pixel
    uint pixel_hash = hash3(uint(pixel.x), uint(pixel.y), params.seed);
    // Répartition régulière mais non quadrillée, plus une garantie dédiée aux
    // très petites îles entièrement contenues dans la fenêtre de contrôle.
    bool is_seed = isBlueNoiseSeed(pixel, w, h, pixel_hash) ||
        isSmallComponentSeed(pixel, w, h, pixel_hash);
    
    if (is_seed) {
        // Ce pixel est un seed de région !
        // Utiliser un ID séquentiel basé sur la position pour des couleurs uniques
        // L'ID est basé sur x + y*width pour avoir un ordre cohérent
        uint region_id = uint(pixel.x) + uint(pixel.y) * uint(w);
        
        // Écrire le seed
        imageStore(region_map, pixel, uvec4(region_id, 0u, 0u, 0u));
        // Coût de chemin nul au seed. Sa position est déjà encodée par l'ID.
        imageStore(region_cost, pixel, vec4(0.0));
    } else {
        // Pixel terre normal : en attente d'assignation
        imageStore(region_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(region_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
    }
}
