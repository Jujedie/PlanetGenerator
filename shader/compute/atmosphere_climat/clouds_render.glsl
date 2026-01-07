#[compute]
#version 450

// ============================================================================
// CLOUDS RENDER SHADER - Étape 3.3c : Rendu Final des Nuages
// ============================================================================
// Convertit le champ de vapeur en texture de nuages visible.
// Applique un seuil de condensation + bruit pour formes irrégulières.
//
// Entrées :
// - vapor_texture : densité de vapeur simulée
// - climate_texture.G : humidité de base (pour influence)
//
// Sorties :
// - clouds_texture : RGBA8 (blanc/transparent)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : VaporTexture (densité de vapeur simulée)
layout(set = 0, binding = 0, r32f) uniform readonly image2D vapor_texture;

// Texture de sortie : CloudsTexture RGBA8 (blanc/transparent)
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D clouds_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform CloudsRenderParams {
    uint seed;
    uint width;
    uint height;
    float condensation_threshold; // Seuil de formation des nuages (0.5 - 0.8)
    float cylinder_radius;
    uint atmosphere_type;
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// FONCTIONS UTILITAIRES
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

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    const float BIG_OFFSET = 10000.0;
    ivec3 ii = ivec3(i + BIG_OFFSET);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    float c000 = rand(hash(ix ^ hash(iy ^ hash(iz))));
    float c100 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz))));
    float c010 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz))));
    float c110 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz))));
    float c001 = rand(hash(ix ^ hash(iy ^ hash(iz+1u))));
    float c101 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz+1u))));
    float c011 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz+1u))));
    float c111 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz+1u))));
    
    float x00 = mix(c000, c100, u.x);
    float x10 = mix(c010, c110, u.x);
    float x01 = mix(c001, c101, u.x);
    float x11 = mix(c011, c111, u.x);
    
    float xy0 = mix(x00, x10, u.y);
    float xy1 = mix(x01, x11, u.y);
    
    return mix(xy0, xy1, u.z) * 2.0 - 1.0;
}

// Cellular noise pour formes rondes
float cellularNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist = 1.0;
    
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                const float BIG_OFFSET = 10000.0;
                ivec3 ii = ivec3(i + neighbor + BIG_OFFSET);
                uint h = hash(uint(ii.x) + seed_offset ^ hash(uint(ii.y) ^ hash(uint(ii.z))));
                vec3 point = neighbor + vec3(rand(h), rand(hash(h + 1u)), rand(hash(h + 2u))) - f;
                float dist = length(point);
                minDist = min(minDist, dist);
            }
        }
    }
    
    return minDist;
}

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Skip pour atmosphères sans nuages
    if (params.atmosphere_type == 2u || params.atmosphere_type == 3u) {
        imageStore(clouds_texture, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire la vapeur simulée
    float vapor = imageLoad(vapor_texture, pixel).r;
    
    // Coordonnées pour le bruit
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === 1. Bruit cellulaire pour formes rondes (comme NuageMapGenerator) ===
    float noise_freq_cell = 6.0 / params.cylinder_radius;
    float cell_val = cellularNoise3D(coords * noise_freq_cell, params.seed + 100000u);
    cell_val = 1.0 - cell_val; // Inverser pour avoir des formes pleines
    
    // === 2. Bruit de forme pour variété ===
    float noise_freq_shape = 4.0 / params.cylinder_radius;
    float shape_val = valueNoise3D(coords * noise_freq_shape, params.seed + 110000u);
    shape_val = (shape_val + 1.0) / 2.0; // [0, 1]
    
    // === 3. Bruit de détail pour bords irréguliers ===
    float noise_freq_detail = 15.0 / params.cylinder_radius;
    float detail_val = valueNoise3D(coords * noise_freq_detail, params.seed + 120000u) * 0.15;
    
    // === 4. Combiner vapeur simulée + bruit ===
    float cloud_val = vapor * 0.4 + cell_val * 0.35 + shape_val * 0.2 + detail_val;
    
    // === 5. Seuil de condensation ===
    vec4 cloud_color;
    
    if (cloud_val > params.condensation_threshold) {
        // Nuage visible : blanc opaque
        cloud_color = vec4(1.0, 1.0, 1.0, 1.0);
    } else {
        // Pas de nuage : transparent
        cloud_color = vec4(0.0, 0.0, 0.0, 0.0);
    }
    
    imageStore(clouds_texture, pixel, cloud_color);
}
