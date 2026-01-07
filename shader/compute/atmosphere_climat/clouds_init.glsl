#[compute]
#version 450

// ============================================================================
// CLOUDS INIT SHADER - Étape 3.3a : Initialisation du Champ de Vapeur
// ============================================================================
// Initialise le champ de vapeur d'eau et le champ de vent pour la simulation.
// - Vapeur basée sur l'humidité (climate.G) + perturbation
// - Vent basé sur les cellules de Hadley simplifiées (dépend latitude)
//
// Entrées :
// - climate_texture (R=temp, G=humidity)
// - geo_texture (pour masque terre/mer)
//
// Sorties :
// - vapor_texture : densité de vapeur [0, 1]
// - climate_texture.BA : wind_x, wind_y
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

// fBm (Fractional Brownian Motion)
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

// Cellular Noise 3D
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
    // Basée sur l'humidité avec perturbation
    float noise_freq = 4.0 / params.cylinder_radius;
    float perturbation = valueNoise3D(coords * noise_freq, params.seed + 80000u) * 0.2;
    float vapor = clamp(humidity + perturbation, 0.0, 1.0);
    
    imageStore(vapor_texture, pixel, vec4(vapor, 0.0, 0.0, 0.0));
    
    // === 2. Calculer le champ de vent (Modèle atmosphérique réaliste) ===
    // 
    // Structure atmosphérique terrestre avec:
    // - Cellules de Hadley/Ferrel/Polaire
    // - Jet streams subtropicaux et polaires
    // - Ondes de Rossby (méandres du jet stream)
    // - Instabilités baroclines (formation de cyclones)
    
    float wind_x = 0.0;
    float wind_y = 0.0;
    
    // === JET STREAMS ===
    // Subtropical jet (~30° latitude)
    float jet_subtropical = 0.0;
    if (abs(lat_abs - 0.33) < 0.08) {
        float t = 1.0 - abs(lat_abs - 0.33) / 0.08;
        jet_subtropical = t * t * 2.5; // Forme gaussienne, très fort
    }
    
    // Polar jet (~55° latitude)
    float jet_polar = 0.0;
    if (abs(lat_abs - 0.60) < 0.10) {
        float t = 1.0 - abs(lat_abs - 0.60) / 0.10;
        jet_polar = t * t * 2.0;
    }
    
    // === CELLULES DE CIRCULATION ===
    // Cellule de Hadley (0-30°)
    if (lat_abs < 0.33) {
        // Alizés (Trade winds)
        wind_x = -0.8;
        wind_y = -sign(lat_signed) * 0.25;
    }
    // Cellule de Ferrel (30-60°)
    else if (lat_abs < 0.67) {
        // Westerlies + Jet streams
        wind_x = 1.2 + jet_subtropical + jet_polar;
        wind_y = sign(lat_signed) * 0.2;
    }
    // Cellule polaire (60-90°)
    else {
        // Polar easterlies
        wind_x = -0.6;
        wind_y = -sign(lat_signed) * 0.15;
    }
    
    // === ONDES DE ROSSBY ===
    // Grandes ondulations du jet stream (longueur d'onde ~60° longitude)
    float rossby_freq = 6.0 / params.cylinder_radius;
    float rossby_wave = fbm(coords * rossby_freq, 3, 0.6, 2.5, params.seed + 30000u);
    // Les ondes de Rossby sont plus fortes aux latitudes moyennes
    float rossby_strength = (jet_subtropical + jet_polar) * 0.8;
    wind_x += rossby_wave * rossby_strength;
    
    // === INSTABILITÉS BAROCLINES ===
    // Créent les cyclones extratropicaux (dépressions)
    float baroclinic_freq = 8.0 / params.cylinder_radius;
    float baroclinic = fbm(coords * baroclinic_freq, 4, 0.55, 2.2, params.seed + 40000u);
    // Plus fort dans la zone du jet polaire (frontière air chaud/froid)
    float baroclinic_strength = jet_polar * 1.2;
    wind_y += baroclinic * baroclinic_strength * sign(lat_signed);
    
    // === CISAILLEMENT ET TOURBILLONS ===
    // Bruit cellulaire pour créer des centres de rotation
    float cell_freq = 5.0 / params.cylinder_radius;
    float cellular = cellularNoise3D(coords * cell_freq, params.seed + 50000u);
    // Convertir en perturbation rotationnelle
    float angle = cellular * TAU;
    vec2 rotational = vec2(cos(angle), sin(angle)) * 0.4;
    
    // === PERTURBATION HAUTE FRÉQUENCE ===
    float detail_freq = 12.0 / params.cylinder_radius;
    float detail = valueNoise3D(coords * detail_freq, params.seed + 60000u);
    
    // === COMBINER ===
    wind_x = wind_x * params.wind_base_speed + rotational.x + detail * 0.3;
    wind_y = wind_y * params.wind_base_speed + rotational.y + detail * 0.2;
    
    // Écrire le vent dans climate.BA
    imageStore(climate_texture, pixel, vec4(climate.r, climate.g, wind_x, wind_y));
}
