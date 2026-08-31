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

// === SET 2: PALETTE DE COULEURS DYNAMIQUE (SSBO) ===
// Construite depuis les biomes dans Enum.gd
// Chaque entrée = 16 bytes : float threshold, float r, float g, float b
struct PaletteEntry {
    float threshold;
    float r;
    float g;
    float b;
};

layout(set = 2, binding = 0, std430) readonly buffer ColorPalette {
    uint entry_count;
    uint _pad1;
    uint _pad2;
    uint _pad3;
    PaletteEntry entries[];
};

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Constantes climatiques
const float EQUATOR_OFFSET = 9.0;      // Bonus température équateur
const float POLE_OFFSET = 37.0;        // Refroidissement pôles
const float LAPSE_RATE = -6.2;         // °C par 1000m au-dessus mer
const float DEPTH_RATE = 0.7;          // Faible correction des bassins océaniques

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
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * PI;
    return vec3(cx, cy, cz);
}

ivec2 wrappedPixel(ivec2 pixel) {
    int w = int(params.width);
    int h = int(params.height);
    int wrapped_x = ((pixel.x % w) + w) % w;
    return ivec2(wrapped_x, clamp(pixel.y, 0, h - 1));
}

bool isOceanAt(ivec2 pixel) {
    return imageLoad(geo_texture, wrappedPixel(pixel)).r < params.sea_level;
}

// Mesure grossière de la continentalité à deux échelles. Elle permet de
// réduire les anomalies sur l'océan et les littoraux sans exiger la texture
// hydrologique, qui n'existe pas encore à cette étape du pipeline.
float nearbyOceanFraction(ivec2 pixel) {
    const ivec2 directions[8] = ivec2[8](
        ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1),
        ivec2(1, 1), ivec2(-1, 1), ivec2(1, -1), ivec2(-1, -1)
    );
    float ocean_samples = 0.0;
    for (int i = 0; i < 8; i++) {
        int distance_px = i < 4 ? 4 : 11;
        ocean_samples += isOceanAt(pixel + directions[i] * distance_px) ? 1.0 : 0.0;
    }
    return ocean_samples / 8.0;
}

// ============================================================================
// PALETTE DE COULEURS TEMPÉRATURE (Dynamique via SSBO)
// Interpolation linéaire entre les entrées de la palette
// Construite depuis les biomes actifs du type de planète courant
// ============================================================================

vec4 getTemperatureColor(float temp) {
    // Fallback si palette vide
    if (entry_count == 0u) return vec4(1.0, 0.0, 1.0, 1.0);  // Magenta = erreur
    
    // Sous le premier seuil → couleur du premier seuil
    if (temp <= entries[0].threshold) {
        return vec4(entries[0].r, entries[0].g, entries[0].b, 1.0);
    }
    
    // Interpolation continue : évite les bandes de couleur par paliers.
    for (uint i = 0u; i < entry_count - 1u; i++) {
        if (temp <= entries[i + 1u].threshold) {
            float span = max(entries[i + 1u].threshold - entries[i].threshold, 0.0001);
            float blend = smoothstep(0.0, 1.0, (temp - entries[i].threshold) / span);
            vec3 cold = vec3(entries[i].r, entries[i].g, entries[i].b);
            vec3 warm = vec3(entries[i + 1u].r, entries[i + 1u].g, entries[i + 1u].b);
            return vec4(mix(cold, warm, blend), 1.0);
        }
    }
    
    // Au-dessus du dernier seuil → couleur du dernier seuil
    uint last = entry_count - 1u;
    return vec4(entries[last].r, entries[last].g, entries[last].b, 1.0);
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
    
    // Latitude géographique signée [-1, 1]. La latitude climatique sera
    // déplacée plus bas par les anomalies planétaires afin d'éviter des
    // frontières parfaitement horizontales.
    float signed_latitude = (((float(pixel.y) + 0.5) / float(params.height)) - 0.5) * 2.0;
    float lat_normalized = abs(signed_latitude);
    
    // Coordonnées cylindriques pour le bruit seamless
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === 1. Circulation planétaire et variations régionales ===
    vec3 domain = coords / max(params.cylinder_radius, 1.0);
    float warp_a = fbm(domain * 1.15, 3, 0.55, 2.03, params.seed + 7001u);
    float warp_b = fbm(domain * 1.15 + vec3(3.7, 1.9, 5.1), 3, 0.55, 2.03, params.seed + 9001u);
    vec3 warped = domain + vec3(warp_a * 0.24, warp_b * 0.10, warp_b * 0.24);
    float planetary = fbm(warped * 2.15, 5, 0.54, 2.02, params.seed + 11003u);
    float regional = fbm(warped * 5.2, 4, 0.52, 2.04, params.seed + 17011u);
    float local = fbm(domain * 12.0, 3, 0.50, 2.08, params.seed + 23003u);
    float angle = (float(pixel.x) / float(params.width)) * TAU;
    float latitude_taper = 1.0 - smoothstep(0.80, 1.0, lat_normalized);
    float latitude_shift = (
        warp_a * 0.30
        + warp_b * 0.10
        + sin(angle * 2.0 + warp_b * 2.6) * 0.06
    ) * latitude_taper;
    float effective_signed_latitude = clamp(signed_latitude + latitude_shift, -1.0, 1.0);
    float effective_latitude = abs(effective_signed_latitude);
    float planetary_wave = sin(angle * 2.0 + warp_a * 2.4 + effective_latitude * PI) * 2.4;

    // === 2. Température de base (latitude climatique ondulée) ===
    float lat_curve = pow(effective_latitude, 1.42);
    float base_temp = params.avg_temperature
        + EQUATOR_OFFSET * (1.0 - pow(effective_latitude, 0.72))
        - POLE_OFFSET * lat_curve;
    
    // === 3. Gradient d'altitude ===
    float altitude_temp = 0.0;
    // NOTE: On utilise height < sea_level au lieu de water_height > 0
    // car la température est calculée AVANT la phase eau.
    // water_height (geo.a) est un indicateur brut de base_elevation,
    // mais la vraie classification eau se fait APRÈS en tenant compte de la température.
    bool is_below_sea = (height < params.sea_level);
    float ocean_fraction = nearbyOceanFraction(pixel);
    
    if (!is_below_sea) {
        float altitude_above_sea = max(0.0, height - params.sea_level);
        altitude_temp = max(LAPSE_RATE * (altitude_above_sea / 1000.0), -48.0);
    } else {
        // Sous le niveau de la mer : température plus stable (fond marin ou futur océan)
        float depth_below_sea = params.sea_level - height;
        // Gradient modéré sous la mer (l'eau profonde est froide mais stable)
        altitude_temp = max(-DEPTH_RATE * (depth_below_sea / 1000.0), -4.0);
    }
    
    // === 4. Calcul final ===
    float continentality = 1.0 - ocean_fraction;
    float anomaly_strength = is_below_sea
        ? 0.42
        : mix(0.58, 1.08, continentality);
    float anomaly = (
        planetary * 8.2
        + regional * 4.0
        + local * 1.0
        + planetary_wave
    ) * anomaly_strength;
    // Les intérieurs continentaux connaissent des extrêmes un peu plus forts,
    // surtout aux latitudes moyennes et hautes.
    float inland_seasonality = (is_below_sea ? 0.0 : continentality)
        * smoothstep(0.22, 0.82, effective_latitude)
        * planetary * 3.6;
    float temp = base_temp + anomaly + inland_seasonality + altitude_temp;
    
    // Le contrôle UI et les presets montent à 500 °C. Conserver cette
    // plage est indispensable pour distinguer correctement les biomes
    // vénusiens et les mers de lave au lieu de tout rabattre sur 200 °C.
    temp = clamp(temp, -200.0, 550.0);
    
    // === 5. Écriture des résultats ===
    
    // ClimateTexture : R=temp (les autres canaux seront remplis par precipitation/wind)
    imageStore(climate_texture, pixel, vec4(temp, 0.0, 0.0, 0.0));
    
    // Texture colorée pour export direct
    vec4 color = getTemperatureColor(temp);
    imageStore(temperature_colored, pixel, color);
}
