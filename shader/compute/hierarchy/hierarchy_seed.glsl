#[compute]
#version 450

// ===========================================================================
// HIERARCHY SEED PLACEMENT SHADER
// ===========================================================================
// Place des seeds pour le niveau hiérarchique supérieur.
// Lit le prev_level_map (département/région/pays) et sélectionne des seeds
// parmi les IDs uniques du niveau inférieur. Chaque seed représente un
// "centre" autour duquel le JFA propagera le nouveau groupement.
//
// Paramétrable via UBO :
//   - domain : 0=terre (water_type==0), 1=mer (water_type>0)
//   - nb_cases_super : nombre de pixels moyen par super-région
//     (contrôle la densité de seeds)
//
// Entrées :
//   - water_mask (binding 0) : masque eau (R8UI)
//   - prev_level_map (binding 1) : IDs du niveau inférieur (R32UI)
//
// Sorties :
//   - super_map (binding 2) : IDs du nouveau niveau (R32UI)
//   - super_cost (binding 3) : position seed encodée pour JFA (R32F)
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r8ui)   uniform readonly  uimage2D water_mask;
layout(set = 0, binding = 1, r32ui)  uniform readonly  uimage2D prev_level_map;
layout(set = 0, binding = 2, r32ui)  uniform writeonly uimage2D super_map;
layout(set = 0, binding = 3, r32f)   uniform writeonly image2D  super_cost;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SeedParams {
    uint width;
    uint height;
    uint seed;
    uint nb_cases_super;       // Budget moyen de pixels par super-région
    uint domain;               // 0 = terre, 1 = mer
    uint level_index;          // 0 = dept→région, 1 = région→pays, 2 = pays→continent
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

uint hash3(uint x, uint y, uint z) {
    return hash(hash2(x, y) ^ (z * 2654435761u));
}

float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) {
        return;
    }

    // Vérifier le domaine (terre ou mer)
    uint water_type = imageLoad(water_mask, pixel).r;
    bool is_water = (water_type > 0u);
    bool in_domain = (params.domain == 0u) ? !is_water : is_water;

    if (!in_domain) {
        // Hors domaine : marquer invalide
        imageStore(super_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(super_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }

    // Lire l'ID du niveau inférieur
    uint prev_id = imageLoad(prev_level_map, pixel).r;

    if (prev_id == 0xFFFFFFFFu) {
        // Pas d'ID au niveau inférieur : invalide
        imageStore(super_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(super_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }

    // Décider si ce pixel est un seed pour le niveau supérieur.
    // On utilise un hash basé sur prev_id pour que tous les pixels d'un même
    // département aient le même résultat → le seed est un "représentant" du département.
    // La probabilité de sélection est 2/nb_cases_super (facteur sécurité x2).
    float seed_probability = 2.0 / float(params.nb_cases_super);

    // Hash déterministe basé sur prev_id + seed global + level
    // Cela garantit que le même département donne toujours le même résultat
    uint dept_hash = hash3(prev_id, params.seed, params.level_index + 100u);
    float random_value = hashToFloat(dept_hash);

    // Parmi les pixels de ce département, on ne veut qu'un seul seed.
    // On utilise un second hash par pixel pour choisir le "premier" pixel
    // qui agira comme le seed physique de ce département-seed.
    uint pixel_hash = hash3(uint(pixel.x), uint(pixel.y), params.seed + params.level_index * 7u);
    float pixel_rand = hashToFloat(pixel_hash);

    // Ce département est sélectionné comme seed ET ce pixel est le représentant
    // (probabilité pixel = très basse pour n'en garder qu'un par département)
    bool dept_is_seed = (random_value < seed_probability);

    if (dept_is_seed && pixel_rand < 0.001) {
        // Ce pixel est un seed ! Son super_id = prev_id (hérite de l'ID département)
        // Cela garantit que chaque seed a un ID unique (basé sur le dept du niveau inférieur)
        uint super_id = prev_id;

        imageStore(super_map, pixel, uvec4(super_id, 0u, 0u, 0u));
        // Encoder la position du seed pour JFA : float(y * width + x) + 1.0
        float packed_pos = float(uint(pixel.y) * params.width + uint(pixel.x)) + 1.0;
        imageStore(super_cost, pixel, vec4(packed_pos, 0.0, 0.0, 0.0));
    } else {
        // Pixel normal en attente d'assignation par JFA
        imageStore(super_map, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(super_cost, pixel, vec4(1e30, 0.0, 0.0, 0.0));
    }
}
