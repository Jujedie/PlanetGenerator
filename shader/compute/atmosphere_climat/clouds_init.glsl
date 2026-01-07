#[compute]
#version 450

// ============================================================================
// CLOUDS INIT SHADER - Étape 3.3a : Initialisation (SIMPLIFIÉ)
// ============================================================================
// Initialise le champ de vapeur d'eau et le champ de vent simplifié.
// Le réalisme visuel est assuré par le shader de rendu procédural.
//
// Entrées :
// - climate_texture (R=temp, G=humidity)
//
// Sorties :
// - vapor_texture : densité de vapeur [0, 1]
// - climate_texture.BA : wind_x, wind_y (3 cellules basiques)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture de sortie : VaporTexture (densité de vapeur)
layout(set = 0, binding = 0, r32f) uniform writeonly image2D vapor_texture;

// Texture entrée/sortie : ClimateTexture (lit R=temp, G=humidity, écrit B=wind_x, A=wind_y)
layout(set = 0, binding = 1, rgba32f) uniform image2D climate_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform CloudsInitParams {
    uint seed;
    uint width;
    uint height;
    float wind_base_speed;   // Vitesse de base du vent (0.5 - 2.0)
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
    
    // Skip pour atmosphères spéciales
    if (params.atmosphere_type == 2u || params.atmosphere_type == 3u) {
        imageStore(vapor_texture, pixel, vec4(0.0));
        vec4 climate = imageLoad(climate_texture, pixel);
        imageStore(climate_texture, pixel, vec4(climate.r, climate.g, 0.0, 0.0));
        return;
    }
    
    // Lire données climatiques
    vec4 climate = imageLoad(climate_texture, pixel);
    float humidity = climate.g;
    
    // Latitude normalisée [-1, 1] : -1=pôle sud, 0=équateur, 1=pôle nord
    float lat_signed = (float(pixel.y) / float(params.height)) * 2.0 - 1.0;
    float lat_abs = abs(lat_signed);
    
    // Coordonnées pour bruit
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === 1. Initialiser la vapeur ===
    float noise_freq = 4.0 / params.cylinder_radius;
    float perturbation = valueNoise3D(coords * noise_freq, params.seed + 80000u) * 0.2;
    float vapor = clamp(humidity + perturbation, 0.0, 1.0);
    
    imageStore(vapor_texture, pixel, vec4(vapor, 0.0, 0.0, 0.0));
    
    // === 2. Champ de vent simplifié (3 cellules) ===
    // Hadley (0-30°), Ferrel (30-60°), Polaire (60-90°)
    
    float wind_x = 0.0;
    float wind_y = 0.0;
    
    // Cellule de Hadley (0-30°) : Alizés vers l'ouest
    if (lat_abs < 0.33) {
        wind_x = -0.8;
        wind_y = -sign(lat_signed) * 0.2;
    }
    // Cellule de Ferrel (30-60°) : Westerlies vers l'est
    else if (lat_abs < 0.67) {
        wind_x = 1.2;
        wind_y = sign(lat_signed) * 0.15;
    }
    // Cellule polaire (60-90°) : Easterlies faibles
    else {
        wind_x = -0.5;
        wind_y = -sign(lat_signed) * 0.1;
    }
    
    // Petite perturbation pour variété
    float perturb_freq = 3.0 / params.cylinder_radius;
    float perturb_x = valueNoise3D(coords * perturb_freq, params.seed + 90000u) * 0.3;
    float perturb_y = valueNoise3D(coords * perturb_freq, params.seed + 91000u) * 0.2;
    
    wind_x = (wind_x + perturb_x) * params.wind_base_speed;
    wind_y = (wind_y + perturb_y) * params.wind_base_speed;
    
    // Écrire le vent dans climate.BA
    imageStore(climate_texture, pixel, vec4(climate.r, climate.g, wind_x, wind_y));
}
