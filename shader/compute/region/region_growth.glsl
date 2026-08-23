#[compute]
#version 450

// ===========================================================================
// REGION GROWTH SHADER (coût de chemin connexe)
// ===========================================================================
// Chaque pixel adopte seulement l'ID d'un voisin cardinal avec un coût de
// chemin strictement croissant. Une région reste donc toujours connexe.
//
// Utilise un ping-pong sur region_map / region_map_temp.
//
// Entrées :
//   - geo_texture (binding 0) : R=height (réservé pour usage futur)
//   - water_mask (binding 1) : masque eau (infranchissable)
//   - river_flux (binding 2) : flux des rivières (réservé)
//   - region_map_in (binding 3) : état actuel des régions
//   - region_cost_in (binding 4) : coût cumulé depuis le seed
//
// Sorties :
//   - region_map_out (binding 5) : nouveaux IDs de région
//   - region_cost_out (binding 6) : nouveaux coûts cumulés
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
    float mean_spacing_px;      // Échelle moyenne d'un département
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

float fade(float t) {
    return t * t * (3.0 - 2.0 * t);
}

float valueNoise3D(vec3 p, uint seedOffset) {
    vec3 base = floor(p);
    vec3 f = fract(p);
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    ivec3 i = ivec3(base + vec3(10000.0));

    float values[8];
    int index = 0;
    for (int dz = 0; dz <= 1; dz++) {
        for (int dy = 0; dy <= 1; dy++) {
            for (int dx = 0; dx <= 1; dx++) {
                uint hx = uint(i.x + dx);
                uint hy = uint(i.y + dy);
                uint hz = uint(i.z + dz);
                values[index++] = hashToFloat(hash(hx ^ hash(hy ^ hash(hz + seedOffset))));
            }
        }
    }

    float x00 = mix(values[0], values[1], u.x);
    float x10 = mix(values[2], values[3], u.x);
    float x01 = mix(values[4], values[5], u.x);
    float x11 = mix(values[6], values[7], u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
}

// Wrap X pour projection équirectangulaire (seamless horizontalement)
int wrapX(int x, int w) {
    return (x % w + w) % w;
}

// Clamp Y pour les pôles
int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

vec3 organicNoisePoint(ivec2 pixel, int w, int h) {
    const float TAU = 6.28318530718;
    float angle = (float(pixel.x) + 0.5) / float(w) * TAU;
    float latitude = ((float(pixel.y) + 0.5) / float(h) - 0.5) * 3.14159265359;
    float featureCount = max(float(w) / max(params.mean_spacing_px, 2.0) * 0.42, 1.0);
    return vec3(cos(angle), latitude, sin(angle)) * featureCount;
}

float traversalCost(ivec2 pixel, ivec2 neighbor, int w, int h) {
    float cost = max(params.cost_flat, 0.05);

    // Champ lisse de résistance du terrain : les fronts de croissance ondulent
    // sans bruit blanc, triangle de Voronoï ou segment rectiligne prolongé.
    vec3 grainPoint = organicNoisePoint(pixel, w, h) * 1.75;
    float grain = valueNoise3D(grainPoint, params.seed + 911u);
    float grainStrength = clamp(params.noise_strength, 0.0, 1.0) * 0.38;
    cost *= mix(1.0 - grainStrength, 1.0 + grainStrength, grain);

    float hereHeight = imageLoad(geo_texture, pixel).r;
    float neighborHeight = imageLoad(geo_texture, neighbor).r;
    float reliefBarrier = min(abs(hereHeight - neighborHeight) / 450.0, 3.0);
    cost += reliefBarrier * max(params.cost_uphill - params.cost_flat, 0.0);

    float riverFlux = max(imageLoad(river_flux, pixel).r, imageLoad(river_flux, neighbor).r);
    if (riverFlux > params.river_threshold) {
        cost += max(params.cost_river, 0.0);
    }
    return max(cost, 0.01);
}

// Distance au seed en espace équirectangulaire : longitude raccordée, puis
// corrigée par cos(latitude). La pénalité est douce et ne laisse jamais de
// terre vide, mais elle rend une extension très longue nettement moins
// compétitive qu'un seed côtier proche.
float seedShapePenalty(ivec2 pixel, uint regionId, int w, int h) {
    int seedX = int(regionId % uint(w));
    int seedY = int(regionId / uint(w));
    float dx = abs(float(pixel.x - seedX));
    dx = min(dx, float(w) - dx);
    float meanY = 0.5 * (float(pixel.y) + float(seedY));
    float latitude = ((meanY + 0.5) / float(h) - 0.5) * 3.14159265359;
    dx *= max(cos(latitude), 0.05);
    float distancePx = length(vec2(dx, float(pixel.y - seedY)));
    float softRadius = max(params.mean_spacing_px * 1.10, 2.0);
    float excess = max(distancePx - softRadius, 0.0) / softRadius;
    return excess * excess * max(params.cost_flat, 0.25) * 6.0;
}

const ivec2 CARDINAL[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
);

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
    float current_cost = imageLoad(region_cost_in, pixel).r;
    
    // Meilleur candidat trouvé
    uint best_region = current_region;
    float best_cost = current_cost;
    
    // Une propagation cardinale locale garantit que l'ID reste connexe et ne
    // peut jamais traverser une mer ou couper diagonalement un masque côtier.
    for (int i = 0; i < 4; i++) {
        int nx = wrapX(pixel.x + CARDINAL[i].x, w);
        int ny = clampY(pixel.y + CARDINAL[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);
        uint neighborWater = imageLoad(water_mask, neighbor).r;
        if (neighborWater > 0u) continue;

        uint n_region = imageLoad(region_map_in, neighbor).r;
        if (n_region == 0xFFFFFFFFu) continue;

        float neighbor_cost = imageLoad(region_cost_in, neighbor).r;
        float candidate_cost = neighbor_cost + traversalCost(pixel, neighbor, w, h);
        candidate_cost += seedShapePenalty(pixel, n_region, w, h);

        if (candidate_cost < best_cost ||
                (candidate_cost == best_cost && n_region < best_region)) {
            best_cost = candidate_cost;
            best_region = n_region;
        }
    }
    
    // Écrire le résultat et son coût de chemin monotone.
    imageStore(region_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
    imageStore(region_cost_out, pixel, vec4(best_cost, 0.0, 0.0, 0.0));
}
