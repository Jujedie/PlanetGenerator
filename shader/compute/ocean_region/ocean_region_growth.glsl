#[compute]
#version 450

// ===========================================================================
// OCEAN REGION GROWTH SHADER (Dijkstra-like)
// ===========================================================================
// Propage les régions océaniques avec système de coûts basé sur la profondeur.
// Inverse du système terrestre : propagation sur water_type > 0, terre = barrière.
//
// Système de coûts :
//   - Profondeur plate/montante : coût = 1
//   - Profondeur descendante (plus profond) : coût = 2
//
// Utilise un ping-pong sur ocean_region_cost / ocean_region_cost_temp.
//
// Entrées :
//   - geo_texture (binding 0) : R=height pour calcul de profondeur
//   - water_mask (binding 1) : masque eau (seulement water_type > 0)
//   - ocean_region_map_in (binding 2) : état actuel des régions
//   - ocean_region_cost_in (binding 3) : coûts accumulés actuels
//
// Sorties :
//   - ocean_region_map_out (binding 4) : nouveaux IDs de région
//   - ocean_region_cost_out (binding 5) : nouveaux coûts accumulés
// ===========================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32ui) uniform readonly uimage2D ocean_region_map_in;
layout(set = 0, binding = 3, r32f) uniform readonly image2D ocean_region_cost_in;
layout(set = 0, binding = 4, r32ui) uniform writeonly uimage2D ocean_region_map_out;
layout(set = 0, binding = 5, r32f) uniform writeonly image2D ocean_region_cost_out;

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform GrowthParams {
    uint width;
    uint height;
    uint pass_index;
    uint seed;
    float sea_level;
    float cost_flat;           // Coût profondeur plate/montante (1.0)
    float cost_deeper;         // Coût descente profondeur (2.0)
    float noise_strength;      // Force du bruit pour frontières irrégulières (10.0)
    float mean_spacing_px;
    float padding2;
    float padding3;
    float padding4;
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

float organicBoundaryNoise(ivec2 pixel, int w, int h) {
    const float TAU = 6.28318530718;
    float angle = (float(pixel.x) + 0.5) / float(w) * TAU;
    float latitude = ((float(pixel.y) + 0.5) / float(h) - 0.5) * 3.14159265359;
    float featureCount = max(float(w) / max(params.mean_spacing_px, 2.0) * 0.50, 1.0);
    vec3 p = vec3(cos(angle), latitude, sin(angle)) * featureCount;
    float broad = valueNoise3D(p, params.seed + 17011u);
    float detail = valueNoise3D(p * 2.1, params.seed + 29009u);
    return broad * 0.72 + detail * 0.28;
}

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

const ivec2 NEIGHBORS[4] = ivec2[4](
    ivec2(-1, 0),
    ivec2(1, 0),
    ivec2(0, -1),
    ivec2(0, 1)
);

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    uint current_region = imageLoad(ocean_region_map_in, pixel).r;
    float current_cost = imageLoad(ocean_region_cost_in, pixel).r;
    
    // Vérifier si c'est de la terre (infranchissable pour océans)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type == 0u) {
        // Terre : copier tel quel (reste infranchissable)
        imageStore(ocean_region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
        imageStore(ocean_region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire la profondeur de ce pixel
    vec4 geo = imageLoad(geo_texture, pixel);
    float my_depth = abs(geo.r - params.sea_level);
    
    // Chercher le meilleur voisin (coût minimal)
    // Si le pixel est déjà assigné, il garde sa région (stable)
    // Si le pixel n'est PAS assigné, on cherche le voisin avec le meilleur coût
    bool is_assigned = (current_region != 0xFFFFFFFFu);
    uint best_region = current_region;
    float best_cost = current_cost;
    
    // Si PAS assigné, on accepte n'importe quel voisin valide
    if (!is_assigned) {
        best_region = 0xFFFFFFFFu;  // Reset pour trouver le meilleur voisin
        best_cost = 1e30;  // Reset pour trouver le minimum
    }
    
    for (int i = 0; i < 4; i++) {
        ivec2 neighbor_offset = NEIGHBORS[i];
        int nx = wrapX(pixel.x + neighbor_offset.x, w);
        int ny = clampY(pixel.y + neighbor_offset.y, h);
        
        if (nx == pixel.x && ny == pixel.y) continue;
        
        ivec2 neighbor_pos = ivec2(nx, ny);
        
        // Vérifier que le voisin est de l'eau
        uint neighbor_water = imageLoad(water_mask, neighbor_pos).r;
        if (neighbor_water == 0u) continue;
        
        uint neighbor_region = imageLoad(ocean_region_map_in, neighbor_pos).r;
        float neighbor_cost = imageLoad(ocean_region_cost_in, neighbor_pos).r;
        
        if (neighbor_region == 0xFFFFFFFFu) continue;
        
        // Calculer le coût de traversée
        vec4 neighbor_geo = imageLoad(geo_texture, neighbor_pos);
        float neighbor_depth = abs(neighbor_geo.r - params.sea_level);
        
        float edge_cost = params.cost_flat;
        
        // Pénalité si on descend (plus profond)
        if (my_depth > neighbor_depth) {
            edge_cost = params.cost_deeper;
        }
        
        // Bruit lisse et cylindrique : les frontières restent organiques et
        // seamless sans le damier produit par un hash indépendant par pixel.
        float noise = organicBoundaryNoise(pixel, w, h);
        float organicFactor = mix(
            1.0 - clamp(params.noise_strength, 0.0, 1.0) * 0.32,
            1.0 + clamp(params.noise_strength, 0.0, 1.0) * 0.32,
            noise
        );
        float total_cost = neighbor_cost + edge_cost * organicFactor;
        
        if (total_cost < best_cost) {
            best_cost = total_cost;
            best_region = neighbor_region;
        }
    }
    
    imageStore(ocean_region_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
    imageStore(ocean_region_cost_out, pixel, vec4(best_cost, 0.0, 0.0, 0.0));
}
