#[compute]
#version 450

// ============================================================================
// TEMPERATURE SHADER - Étape 3.1 : Calcul de Température
// ============================================================================
// Génère la carte de température basée sur :
// - Latitude (gradient équateur → pôles)
// - Altitude (gradient adiabatique -6.5°C/km)
// - Bruit fBm pour variations régionales
// - Atténuation océanique
//
// Entrées :
// - geo_texture (R=height) - altitude pour gradient adiabatique
// - Paramètres UBO (seed, avg_temperature, sea_level, etc.)
//
// Sorties :
// - climate_texture.R = température en °C (float)
// - temperature_colored = couleur finale RGBA8 (palette Enum.gd)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : GeoTexture (lecture seule)
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;

// Texture de sortie : ClimateTexture (R=temp, G=humidity, B=wind_x, A=wind_y)
layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D climate_texture;

// Texture de sortie colorée : RGBA8 pour export direct
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D temperature_colored;

// Uniform Buffer : Paramètres de génération
layout(set = 1, binding = 0, std140) uniform ClimateParams {
    uint seed;              // Graine de génération
    uint width;             // Largeur texture
    uint height;            // Hauteur texture
    float avg_temperature;  // Température moyenne globale (°C)
    float sea_level;        // Niveau de la mer (mètres)
    float cylinder_radius;  // width / (2*PI) pour bruit seamless
    uint atmosphere_type;   // 0=Terre, 1=Toxique, 2=Volcanique, 3=Sans atm
    float padding;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Constantes climatiques
const float EQUATOR_OFFSET = 8.0;      // Bonus température équateur
const float POLE_OFFSET = 35.0;        // Refroidissement pôles
const float LAPSE_RATE = -6.5;         // °C par 1000m au-dessus mer
const float DEPTH_RATE = 2.0;          // °C par 1000m sous mer
const float OCEAN_DAMPING = 0.8;       // Atténuation thermique océan

// ============================================================================
// FONCTIONS UTILITAIRES - Hash et Bruit
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

vec3 grad3(uint h) {
    uint idx = h & 15u;
    float u = idx < 8u ? 1.0 : -1.0;
    float v = (idx & 4u) != 0u ? 1.0 : -1.0;
    float w = (idx & 2u) != 0u ? 1.0 : -1.0;
    return vec3(u, v, w);
}

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Value Noise 3D
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

// fBm classique
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

// Cellular noise pour anomalies thermiques
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

// ============================================================================
// CONVERSION COORDONNÉES - Équirectangulaire vers Cylindrique
// ============================================================================

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// PALETTE DE COULEURS TEMPÉRATURE (Hard-coded depuis Enum.gd)
// 33 seuils de -200°C à +200°C
// ============================================================================

vec4 getTemperatureColor(float temp) {
    // Palette extraite de COULEURS_TEMPERATURE dans Enum.gd
    // Format: seuil en °C, couleur RGBA normalisée
    
    if (temp <= -200.0) return vec4(0.278, 0.561, 0.902, 1.0); // 0x478fe6
    if (temp <= -150.0) return vec4(0.302, 0.000, 0.478, 1.0); // 0x4D007A
    if (temp <= -100.0) return vec4(0.294, 0.000, 0.510, 1.0); // 0x4B0082
    if (temp <= -90.0)  return vec4(0.337, 0.000, 0.580, 1.0); // 0x560094
    if (temp <= -80.0)  return vec4(0.361, 0.000, 0.620, 1.0); // 0x5c009e
    if (temp <= -70.0)  return vec4(0.384, 0.000, 0.659, 1.0); // 0x6200a8
    if (temp <= -60.0)  return vec4(0.408, 0.000, 0.702, 1.0); // 0x6800b3
    if (temp <= -50.0)  return vec4(0.235, 0.000, 0.702, 1.0); // 0x3c00b3
    if (temp <= -45.0)  return vec4(0.247, 0.000, 0.741, 1.0); // 0x3f00bd
    if (temp <= -35.0)  return vec4(0.259, 0.000, 0.780, 1.0); // 0x4200c7
    if (temp <= -25.0)  return vec4(0.275, 0.000, 0.820, 1.0); // 0x4600d1
    if (temp <= -20.0)  return vec4(0.286, 0.000, 0.859, 1.0); // 0x4900db
    if (temp <= -15.0)  return vec4(0.235, 0.275, 0.482, 1.0); // 0x3c467b
    if (temp <= -10.0)  return vec4(0.278, 0.318, 0.553, 1.0); // 0x47518d
    if (temp <= -5.0)   return vec4(0.290, 0.345, 0.639, 1.0); // 0x4a58a3
    if (temp <= 0.0)    return vec4(0.306, 0.361, 0.690, 1.0); // 0x4e5cb0
    if (temp <= 5.0)    return vec4(0.149, 0.447, 0.157, 1.0); // 0x267228
    if (temp <= 10.0)   return vec4(0.149, 0.467, 0.157, 1.0); // 0x267728
    if (temp <= 15.0)   return vec4(0.153, 0.502, 0.161, 1.0); // 0x278029
    if (temp <= 20.0)   return vec4(0.149, 0.518, 0.157, 1.0); // 0x268428
    if (temp <= 25.0)   return vec4(0.855, 0.753, 0.059, 1.0); // 0xdac00f
    if (temp <= 30.0)   return vec4(0.831, 0.725, 0.059, 1.0); // 0xd4b90f
    if (temp <= 35.0)   return vec4(0.855, 0.510, 0.059, 1.0); // 0xda820f
    if (temp <= 40.0)   return vec4(0.824, 0.490, 0.059, 1.0); // 0xd27d0f
    if (temp <= 45.0)   return vec4(0.784, 0.471, 0.055, 1.0); // 0xc8780e
    if (temp <= 50.0)   return vec4(0.784, 0.141, 0.055, 1.0); // 0xc8240e
    if (temp <= 60.0)   return vec4(0.749, 0.133, 0.051, 1.0); // 0xbf220d
    if (temp <= 70.0)   return vec4(0.710, 0.125, 0.051, 1.0); // 0xb5200d
    if (temp <= 80.0)   return vec4(0.675, 0.122, 0.047, 1.0); // 0xac1f0c
    if (temp <= 90.0)   return vec4(0.635, 0.114, 0.043, 1.0); // 0xa21d0b
    if (temp <= 100.0)  return vec4(0.431, 0.078, 0.031, 1.0); // 0x6e1408
    if (temp <= 150.0)  return vec4(0.706, 0.094, 0.380, 1.0); // 0xb41861
    return vec4(0.729, 0.090, 0.169, 1.0); // 0xba172b (200°C+)
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérifier les limites
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire les données géographiques
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;           // Altitude en mètres
    
    // Calculer la latitude normalisée [0, 1] : 0=équateur, 1=pôles
    float lat_normalized = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;
    
    // Coordonnées cylindriques pour le bruit seamless
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === 1. Température de base (latitude) ===
    float lat_curve = pow(lat_normalized, 1.5);
    float base_temp = params.avg_temperature + EQUATOR_OFFSET * (1.0 - lat_normalized) - POLE_OFFSET * lat_curve;
    
    // === 2. Variations régionales (bruit fBm) ===
    // Bruit principal (zones climatiques) - fréquence 3.0/circonference
    float noise_freq = 3.0 / params.cylinder_radius;
    float climate_zone = fbm(coords * noise_freq, 6, 0.5, 2.0, params.seed);
    float longitudinal_variation = climate_zone * 8.0;
    
    // Bruit secondaire (courants océaniques)
    float noise_freq2 = 1.5 / params.cylinder_radius;
    float secondary = fbm(coords * noise_freq2, 4, 0.6, 2.0, params.seed + 10000u);
    float secondary_variation = secondary * 5.0;
    
    // Bruit cellulaire (anomalies thermiques locales)
    float noise_freq3 = 6.0 / params.cylinder_radius;
    float cellular = cellularNoise3D(coords * noise_freq3, params.seed + 20000u);
    float local_variation = (cellular - 0.5) * 6.0;
    
    // === 3. Gradient d'altitude ===
    float altitude_temp = 0.0;
    // NOTE: On utilise height < sea_level au lieu de water_height > 0
    // car la température est calculée AVANT la phase eau.
    // water_height (geo.a) est un indicateur brut de base_elevation,
    // mais la vraie classification eau se fait APRÈS en tenant compte de la température.
    bool is_below_sea = (height < params.sea_level);
    
    if (!is_below_sea) {
        float altitude_above_sea = max(0.0, height - params.sea_level);
        altitude_temp = LAPSE_RATE * (altitude_above_sea / 1000.0);
    } else {
        // Sous le niveau de la mer : température plus stable (fond marin ou futur océan)
        float depth_below_sea = params.sea_level - height;
        // Gradient modéré sous la mer (l'eau profonde est froide mais stable)
        altitude_temp = -DEPTH_RATE * (depth_below_sea / 1000.0);
    }
    
    // === 4. Calcul final ===
    float temp = base_temp + longitudinal_variation + secondary_variation + local_variation + altitude_temp;
    
    // Atténuation pour les zones sous le niveau de la mer (futur océan)
    // L'eau modère les températures : attire vers la moyenne
    if (is_below_sea) {
        temp = temp * OCEAN_DAMPING + params.avg_temperature * (1.0 - OCEAN_DAMPING);
    }
    
    temp = clamp(temp, -200.0, 200.0);
    
    // === 5. Écriture des résultats ===
    
    // ClimateTexture : R=temp (les autres canaux seront remplis par precipitation/wind)
    imageStore(climate_texture, pixel, vec4(temp, 0.0, 0.0, 0.0));
    
    // Texture colorée pour export direct
    vec4 color = getTemperatureColor(temp);
    imageStore(temperature_colored, pixel, color);
}
