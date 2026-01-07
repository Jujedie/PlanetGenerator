#[compute]
#version 450

// ============================================================================
// PRECIPITATION SHADER - Étape 3.2 : Calcul d'Humidité/Précipitations
// ============================================================================
// Génère la carte de précipitations basée sur :
// - Combinaison de 3 bruits (main, detail, cellular)
// - Influence de la latitude (ITCZ, déserts subtropicaux, pôles secs)
// - Scaling global via avg_precipitation
//
// Entrées :
// - geo_texture (R=height pour effet orographique futur)
// - climate_texture (R=temperature en lecture)
// - Paramètres UBO
//
// Sorties :
// - climate_texture.G = humidité normalisée [0, 1]
// - precipitation_colored = couleur finale RGBA8 (palette Enum.gd)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture entrée/sortie : ClimateTexture (lit R=temp, écrit G=humidity)
layout(set = 0, binding = 0, rgba32f) uniform image2D climate_texture;

// Texture de sortie colorée : RGBA8 pour export direct
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D precipitation_colored;

// Uniform Buffer : Paramètres de génération
layout(set = 1, binding = 0, std140) uniform PrecipParams {
    uint seed;              // Graine de génération
    uint width;             // Largeur texture
    uint height;            // Hauteur texture
    float avg_precipitation;// Facteur global humidité [0, 1]
    float cylinder_radius;  // width / (2*PI) pour bruit seamless
    uint atmosphere_type;   // 0=Terre, 1=Toxique, 2=Volcanique, 3=Sans atm
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

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

// Cellular Noise pour fronts météo
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
// CONVERSION COORDONNÉES
// ============================================================================

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// PALETTE DE COULEURS PRÉCIPITATION (Hard-coded depuis Enum.gd)
// 8 seuils de 0.0 à 1.0
// ============================================================================

vec4 getPrecipitationColor(float precip) {
    // Palette extraite de COULEUR_PRECIPITATION dans Enum.gd
    // 0.0 = très sec (violet), 1.0 = très humide (bleu)
    
    if (precip <= 0.0) return vec4(0.694, 0.094, 0.706, 1.0); // 0xb118b4
    if (precip <= 0.1) return vec4(0.553, 0.078, 0.565, 1.0); // 0x8d1490
    if (precip <= 0.2) return vec4(0.424, 0.086, 0.635, 1.0); // 0x6c16a2
    if (precip <= 0.3) return vec4(0.290, 0.094, 0.686, 1.0); // 0x4a18af
    if (precip <= 0.4) return vec4(0.173, 0.106, 0.773, 1.0); // 0x2c1bc5
    if (precip <= 0.5) return vec4(0.114, 0.200, 0.827, 1.0); // 0x1d33d3
    if (precip <= 0.7) return vec4(0.122, 0.310, 0.878, 1.0); // 0x1f4fe0
    return vec4(0.208, 0.514, 0.890, 1.0); // 0x3583e3 (1.0)
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
    
    // Skip pour planètes sans atmosphère
    if (params.atmosphere_type == 3u) {
        // Lire la température existante
        vec4 climate = imageLoad(climate_texture, pixel);
        // Écrire humidité = 0
        imageStore(climate_texture, pixel, vec4(climate.r, 0.0, 0.0, 0.0));
        imageStore(precipitation_colored, pixel, getPrecipitationColor(0.0));
        return;
    }
    
    // Coordonnées cylindriques pour le bruit seamless
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // Latitude normalisée [0, 1] : 0 = équateur, 1 = pôles
    float latitude = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;
    
    // === 1. Bruit principal (zones de pression) ===
    float noise_freq_main = 2.5 / params.cylinder_radius;
    float main_value = fbm(coords * noise_freq_main, 6, 0.55, 2.0, params.seed + 50000u);
    main_value = (main_value + 1.0) / 2.0; // Normaliser [0, 1]
    
    // === 2. Bruit de détail (variations locales) ===
    float noise_freq_detail = 6.0 / params.cylinder_radius;
    float detail_value = fbm(coords * noise_freq_detail, 4, 0.5, 2.0, params.seed + 60000u);
    detail_value = (detail_value + 1.0) / 2.0;
    
    // === 3. Bruit cellulaire (fronts météo) ===
    float noise_freq_cells = 4.0 / params.cylinder_radius;
    float cell_value = cellularNoise3D(coords * noise_freq_cells, params.seed + 70000u);
    // Normaliser (cellularNoise retourne [0, ~1])
    
    // === 4. Combiner les bruits ===
    float base_precip = main_value * 0.6 + detail_value * 0.25 + cell_value * 0.15;
    
    // === 5. Influence de la latitude ===
    float lat_influence = 1.0;
    
    // Équateur (ITCZ) : plus humide
    if (latitude < 0.2) {
        lat_influence = 1.0 + 0.15 * (1.0 - latitude / 0.2);
    }
    // Subtropiques (déserts) : plus sec
    else if (latitude > 0.25 && latitude < 0.4) {
        float t = (latitude - 0.25) / 0.15;
        lat_influence = 1.0 - 0.2 * sin(t * PI);
    }
    // Pôles : plus sec
    else if (latitude > 0.85) {
        lat_influence = 1.0 - 0.3 * (latitude - 0.85) / 0.15;
    }
    
    // === 6. Application du facteur global ===
    float value = base_precip * lat_influence;
    value = value * (0.4 + params.avg_precipitation * 0.6);
    value = clamp(value, 0.0, 1.0);
    
    // === 7. Écriture des résultats ===
    
    // Lire la température existante
    vec4 climate = imageLoad(climate_texture, pixel);
    
    // Écrire humidité dans canal G
    imageStore(climate_texture, pixel, vec4(climate.r, value, 0.0, 0.0));
    
    // Texture colorée pour export direct
    vec4 color = getPrecipitationColor(value);
    imageStore(precipitation_colored, pixel, color);
}
