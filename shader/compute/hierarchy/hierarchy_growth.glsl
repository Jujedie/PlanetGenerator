#[compute]
#version 450

// ===========================================================================
// HIERARCHY GROWTH SHADER (Jump Flooding Algorithm)
// ===========================================================================
// Propage les super-régions via JFA, identique en structure à region_growth.
// Chaque pixel vérifie 9 voisins à ±step_size et adopte le seed le plus proche.
//
// Paramétrable via UBO :
//   - domain : 0=terre, 1=mer (filtre les pixels hors domaine)
//   - step_size : taille du saut JFA (décroît par puissances de 2)
//   - noise_strength : perturbation pour frontières organiques
//
// Entrées :
//   - water_mask (binding 0) : masque eau (R8UI)
//   - super_map_in (binding 1) : IDs super-région lecture (R32UI)
//   - super_cost_in (binding 2) : position seed lecture (R32F)
//
// Sorties :
//   - super_map_out (binding 3) : IDs super-région écriture (R32UI)
//   - super_cost_out (binding 4) : position seed écriture (R32F)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r8ui)   uniform readonly  uimage2D water_mask;
layout(set = 0, binding = 1, r32ui)  uniform readonly  uimage2D super_map_in;
layout(set = 0, binding = 2, r32f)   uniform readonly  image2D  super_cost_in;
layout(set = 0, binding = 3, r32ui)  uniform writeonly uimage2D super_map_out;
layout(set = 0, binding = 4, r32f)   uniform writeonly image2D  super_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform GrowthParams {
    uint width;
    uint height;
    uint step_size;            // Taille du pas JFA
    uint seed;
    uint domain;               // 0 = terre, 1 = mer
    float noise_strength;      // Perturbation en pixels pour frontières organiques
    float padding1;
    float padding2;
} params;

// === FONCTIONS UTILITAIRES ===

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

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// Décodage position seed depuis le float encodé
ivec2 unpackCoords(float packed, uint w) {
    uint total = uint(packed - 1.0);
    return ivec2(int(total % w), int(total / w));
}

// Distance² euclidienne avec wrap horizontal
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

    // Vérifier le domaine
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_water = (water_type > 0u);
    bool in_domain = (params.domain == 0u) ? !is_water : is_water;

    if (!in_domain) {
        imageStore(super_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(super_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }

    // Lire l'état actuel
    uint current_region = imageLoad(super_map_in, pixel).r;
    float current_packed = imageLoad(super_cost_in, pixel).r;

    // Perturbation par pixel pour frontières organiques
    uint ph = hash2(uint(pixel.x) + params.seed, uint(pixel.y) + params.seed * 7u);
    float perturb_x = (hashToFloat(ph) - 0.5) * params.noise_strength * 2.0;
    float perturb_y = (hashToFloat(hash(ph)) - 0.5) * params.noise_strength * 2.0;
    vec2 perturbed = vec2(float(pixel.x) + perturb_x, float(pixel.y) + perturb_y);

    // Meilleur candidat
    uint best_region = current_region;
    float best_packed = current_packed;
    float best_dist = 1e30;

    if (current_region != 0xFFFFFFFFu) {
        ivec2 seed_pos = unpackCoords(current_packed, params.width);
        best_dist = wrappedDistSq(perturbed, seed_pos, w);
    }

    int step = int(params.step_size);

    // JFA : 9 voisins à ±step
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = wrapX(pixel.x + dx * step, w);
            int ny = clampY(pixel.y + dy * step, h);
            ivec2 neighbor = ivec2(nx, ny);

            uint n_region = imageLoad(super_map_in, neighbor).r;
            if (n_region == 0xFFFFFFFFu) continue;

            float n_packed = imageLoad(super_cost_in, neighbor).r;
            ivec2 n_seed = unpackCoords(n_packed, params.width);

            float dist = wrappedDistSq(perturbed, n_seed, w);

            if (dist < best_dist) {
                best_dist = dist;
                best_region = n_region;
                best_packed = n_packed;
            }
        }
    }

    imageStore(super_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
    imageStore(super_cost_out, pixel, vec4(best_packed, 0.0, 0.0, 0.0));
}
