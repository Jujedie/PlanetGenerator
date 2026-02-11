#[compute]
#version 450

// ============================================================================
// CLOUDS SHADER - Génération de Nuages Procéduraux
// ============================================================================
// Génère une carte de nuages réaliste basée sur du bruit fBm.
// Sortie : Blanc (RGB=1) avec transparence variable (A=densité)
// Pas de nuages si atmosphere_type == 3 (sans atmosphère)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture de sortie : Nuages (RGBA8) - RGB=blanc, A=opacité
layout(set = 0, binding = 0, rgba8) uniform writeonly image2D clouds_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform CloudsParams {
    uint seed;
    uint width;
    uint height;
    float cloud_coverage;    // Couverture nuageuse [0, 1] (0.5 = 50%)
    float cylinder_radius;   // Pour bruit seamless
    uint atmosphere_type;    // 0=Terre, 1=Toxique, 2=Volcanique, 3=Sans atm
    float cloud_density;     // Densité des nuages [0, 1]
    float padding1;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// FONCTIONS DE BRUIT
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
    
    return mix(xy0, xy1, u.z);
}

/// fBm multi-octave pour nuages réalistes
float fbm(vec3 p, int octaves, float gain, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * valueNoise3D(p * frequency, seed_offset + uint(i) * 1000u);
        maxValue += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value / maxValue;
}

/// Coordonnées cylindriques pour bruit seamless (wrap horizontal)
vec3 getCylindricalCoords(ivec2 pixel) {
    float angle = (float(pixel.x) / float(params.width)) * TAU;
    float cx = cos(angle) * params.cylinder_radius;
    float cz = sin(angle) * params.cylinder_radius;
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(params.height) - 0.5) * params.cylinder_radius * PI;
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
    
    // Pas de nuages si pas d'atmosphère
    if (params.atmosphere_type == 3u) {
        imageStore(clouds_texture, pixel, vec4(0.0));
        return;
    }
    
    // Coordonnées pour bruit seamless
    vec3 coords = getCylindricalCoords(pixel);
    float noise_scale = 4.0 / params.cylinder_radius;
    
    // Latitude pour variation des nuages
    float lat = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;
    
    // === Couche 1 : Grandes structures nuageuses ===
    float large_clouds = fbm(coords * noise_scale * 0.5, 5, 0.5, 2.0, params.seed);
    
    // === Couche 2 : Détails moyens ===
    float medium_details = fbm(coords * noise_scale * 1.5, 4, 0.55, 2.2, params.seed + 10000u);
    
    // === Couche 3 : Petits détails (wisps) ===
    float fine_details = fbm(coords * noise_scale * 4.0, 3, 0.6, 2.0, params.seed + 20000u);
    
    // Combiner les couches
    float cloud_noise = large_clouds * 0.6 + medium_details * 0.3 + fine_details * 0.1;
    
    // === Modulation par latitude (plus de nuages aux latitudes moyennes) ===
    // Équateur : quelques nuages (ITCZ)
    // Subtropicaux (0.3) : moins de nuages (haute pression)
    // Latitudes moyennes (0.5-0.7) : plus de nuages (fronts)
    // Pôles : moins de nuages (air froid sec)
    
    float lat_factor = 1.0;
    lat_factor -= smoothstep(0.15, 0.35, lat) * 0.3;  // Réduction subtropicale
    lat_factor += smoothstep(0.35, 0.55, lat) * 0.2;  // Boost latitudes moyennes
    lat_factor -= smoothstep(0.75, 0.95, lat) * 0.25; // Réduction polaire
    
    cloud_noise *= lat_factor;
    
    // === Seuillage pour créer des nuages distincts ===
    // Le seuil dépend de la couverture nuageuse souhaitée
    float threshold = 1.0 - params.cloud_coverage;
    
    // Appliquer le seuil avec transition douce
    float cloud_alpha = smoothstep(threshold - 0.1, threshold + 0.2, cloud_noise);
    
    // Moduler par la densité
    cloud_alpha *= params.cloud_density;
    
    // Ajouter variation de densité interne aux nuages
    if (cloud_alpha > 0.0) {
        float density_variation = fbm(coords * noise_scale * 3.0, 3, 0.5, 2.0, params.seed + 30000u);
        cloud_alpha *= 0.7 + density_variation * 0.3;
    }
    
    // Clamp final
    cloud_alpha = clamp(cloud_alpha, 0.0, 1.0);
    
    // Sortie : Blanc avec transparence variable
    imageStore(clouds_texture, pixel, vec4(1.0, 1.0, 1.0, cloud_alpha));
}
