#[compute]
#version 450

// ============================================================================
// GAS GIANT FINAL MAP SHADER
// ============================================================================
// Génère l'apparence d'une planète gazeuse (type Jupiter/Saturne/Neptune)
// à partir des données climat (température + précipitation).
//
// Caractéristiques visuelles :
// - Bandes horizontales colorées (zones/ceintures)
// - Turbulences atmosphériques (bruit multi-octave)
// - Tourbillons de tempêtes (vortex)
// - Variations de couleur basées sur la température et l'humidité
//
// Entrées :
// - climate_texture (RGBA32F) : R=température, G=humidité
//
// Sorties :
// - final_map (RGBA8) : Carte finale colorée
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D final_map;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform GasGiantParams {
    uint width;
    uint height;
    uint seed;
    float cylinder_radius;
    float avg_temperature;   // Température moyenne configurée
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;

// Nombre de bandes atmosphériques principales
const int NUM_BANDS = 12;

// ============================================================================
// FONCTIONS DE BRUIT
// ============================================================================

// Hash pour bruit procédural (reproductible via seed)
uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    return x;
}

uint hash2(uint x, uint y) {
    return hash(x ^ (y * 0x27d4eb2du));
}

uint hash3(uint x, uint y, uint z) {
    return hash(x ^ (y * 0x27d4eb2du) ^ (z * 0x165667b1u));
}

float hashFloat(uint x) {
    return float(hash(x)) / float(0xFFFFFFFFu);
}

// Bruit de valeur 3D (pour coordonnées cylindriques)
float valueNoise3D(vec3 p, uint s) {
    ivec3 i = ivec3(floor(p));
    vec3 f = fract(p);
    
    // Smoothstep pour interpolation
    vec3 u = f * f * (3.0 - 2.0 * f);
    
    float n000 = hashFloat(hash3(uint(i.x) + s, uint(i.y), uint(i.z)));
    float n100 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y), uint(i.z)));
    float n010 = hashFloat(hash3(uint(i.x) + s, uint(i.y + 1), uint(i.z)));
    float n110 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y + 1), uint(i.z)));
    float n001 = hashFloat(hash3(uint(i.x) + s, uint(i.y), uint(i.z + 1)));
    float n101 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y), uint(i.z + 1)));
    float n011 = hashFloat(hash3(uint(i.x) + s, uint(i.y + 1), uint(i.z + 1)));
    float n111 = hashFloat(hash3(uint(i.x + 1) + s, uint(i.y + 1), uint(i.z + 1)));
    
    float n00 = mix(n000, n100, u.x);
    float n10 = mix(n010, n110, u.x);
    float n01 = mix(n001, n101, u.x);
    float n11 = mix(n011, n111, u.x);
    
    float n0 = mix(n00, n10, u.y);
    float n1 = mix(n01, n11, u.y);
    
    return mix(n0, n1, u.z);
}

// fBm (Fractal Brownian Motion) 3D
float fbm(vec3 p, int octaves, float persistence, float lacunarity, uint s) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float max_value = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += valueNoise3D(p * frequency, s + uint(i) * 7919u) * amplitude;
        max_value += amplitude;
        amplitude *= persistence;
        frequency *= lacunarity;
    }
    
    return value / max_value;
}

// Coordonnées cylindriques seamless (wrap horizontal)
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cyl_r) {
    float angle = float(pixel.x) / float(w) * 2.0 * PI;
    float y = float(pixel.y) / float(h);
    return vec3(cos(angle) * cyl_r, y * cyl_r * 2.0, sin(angle) * cyl_r);
}

// ============================================================================
// PALETTE DE COULEURS GAZ GÉANT
// ============================================================================

// Palette inspirée de Jupiter / Saturne
// On utilise la température pour choisir entre palette chaude et froide
// et l'humidité pour ajuster la saturation

// Couleurs de bandes chaudes (type Jupiter)
const vec3 BAND_WARM_COLORS[8] = vec3[8](
    vec3(0.82, 0.68, 0.50),   // Beige doré
    vec3(0.76, 0.52, 0.32),   // Orange brun
    vec3(0.90, 0.78, 0.62),   // Crème clair
    vec3(0.70, 0.45, 0.28),   // Brun rougeâtre
    vec3(0.85, 0.72, 0.55),   // Sable
    vec3(0.60, 0.38, 0.22),   // Brun foncé
    vec3(0.92, 0.85, 0.72),   // Ivoire
    vec3(0.75, 0.55, 0.35)    // Caramel
);

// Couleurs de bandes froides (type Neptune/Uranus)
const vec3 BAND_COLD_COLORS[8] = vec3[8](
    vec3(0.30, 0.50, 0.72),   // Bleu acier
    vec3(0.22, 0.40, 0.65),   // Bleu profond
    vec3(0.45, 0.62, 0.78),   // Bleu ciel
    vec3(0.18, 0.35, 0.58),   // Bleu marine
    vec3(0.38, 0.55, 0.75),   // Azur
    vec3(0.25, 0.42, 0.68),   // Bleu cobalt
    vec3(0.50, 0.68, 0.82),   // Bleu glacé
    vec3(0.20, 0.38, 0.62)    // Indigo doux
);

// Couleurs intermédiaires (type Saturne)
const vec3 BAND_MID_COLORS[8] = vec3[8](
    vec3(0.78, 0.72, 0.55),   // Jaune pâle
    vec3(0.65, 0.58, 0.42),   // Olive doré
    vec3(0.85, 0.80, 0.65),   // Crème doré
    vec3(0.58, 0.52, 0.38),   // Kaki
    vec3(0.72, 0.68, 0.52),   // Chamois
    vec3(0.55, 0.50, 0.36),   // Bronze pâle
    vec3(0.82, 0.78, 0.62),   // Parchemin
    vec3(0.62, 0.55, 0.40)    // Ambre pâle
);

// ============================================================================
// FONCTIONS AUXILIAIRES
// ============================================================================

// Interpole entre les trois palettes selon la température
vec3 getBandColor(int band_index, float temp_factor) {
    int idx = band_index % 8;
    
    // temp_factor : 0 = très froid (Neptune), 0.5 = moyen (Saturne), 1 = chaud (Jupiter)
    if (temp_factor < 0.4) {
        float t = temp_factor / 0.4;
        return mix(BAND_COLD_COLORS[idx], BAND_MID_COLORS[idx], t);
    } else {
        float t = (temp_factor - 0.4) / 0.6;
        return mix(BAND_MID_COLORS[idx], BAND_WARM_COLORS[idx], t);
    }
}

// Structure de bande atmosphérique
float getBandPattern(float lat_normalized, float turbulence) {
    // Bandes principales (sinusoïdales déformées)
    float band_freq = float(NUM_BANDS) * PI;
    float band = sin(lat_normalized * band_freq + turbulence * 1.5);
    
    // Sous-bandes (détail)
    float sub_band = sin(lat_normalized * band_freq * 2.3 + turbulence * 0.8) * 0.3;
    
    // Micro-bandes
    float micro_band = sin(lat_normalized * band_freq * 5.7 + turbulence * 0.4) * 0.1;
    
    return band + sub_band + micro_band;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pos.x >= w || pos.y >= h) return;
    
    // === Lire les données climatiques ===
    vec4 climate = imageLoad(climate_texture, pos);
    float temperature = climate.r;   // °C
    float humidity = climate.g;      // [0, 1]
    
    // === Coordonnées normalisées ===
    float u = float(pos.x) / float(w);  // [0, 1] longitude
    float v = float(pos.y) / float(h);  // [0, 1] latitude (0=nord, 1=sud)
    
    // Latitude normalisée [-1, 1] (0 = équateur)
    float lat = (v - 0.5) * 2.0;
    float abs_lat = abs(lat);
    
    // Coordonnées cylindriques pour bruit seamless
    vec3 cyl = getCylindricalCoords(pos, params.width, params.height, params.cylinder_radius);
    
    // === Facteur de température global ===
    // Mappe la température moyenne vers un facteur [0, 1]
    // < -50°C = Neptune, ~15°C = Saturne, > 100°C = Jupiter
    float temp_factor = clamp((params.avg_temperature + 50.0) / 150.0, 0.0, 1.0);
    
    // === Turbulence atmosphérique ===
    // Bruit à grande échelle pour déformer les bandes
    float turb_freq = 2.0 / params.cylinder_radius;
    float turbulence_large = fbm(cyl * turb_freq, 6, 0.55, 2.0, params.seed) * 2.0 - 1.0;
    
    // Bruit à moyenne échelle pour les détails des bandes  
    float turb_freq_mid = 5.0 / params.cylinder_radius;
    float turbulence_mid = fbm(cyl * turb_freq_mid, 5, 0.5, 2.0, params.seed + 1000u) * 2.0 - 1.0;
    
    // Bruit à petite échelle pour la texture fine
    float turb_freq_fine = 12.0 / params.cylinder_radius;
    float turbulence_fine = fbm(cyl * turb_freq_fine, 4, 0.45, 2.0, params.seed + 2000u) * 2.0 - 1.0;
    
    // === Profil de bande ===
    // La latitude déformée par la turbulence crée les bandes
    float deformed_lat = lat + turbulence_large * 0.08 + turbulence_mid * 0.03;
    
    // Motif de bande principal
    float band_value = getBandPattern(deformed_lat, turbulence_mid * 0.5);
    
    // Convertir en index de bande discret pour la couleur
    float band_continuous = (deformed_lat + 1.0) * 0.5 * float(NUM_BANDS);
    int band_index_a = int(floor(band_continuous)) % NUM_BANDS;
    int band_index_b = (band_index_a + 1) % NUM_BANDS;
    float band_frac = fract(band_continuous);
    
    // === Couleurs de base des bandes ===
    vec3 color_a = getBandColor(band_index_a, temp_factor);
    vec3 color_b = getBandColor(band_index_b, temp_factor);
    
    // Transition douce entre bandes avec le motif sinusoïdal
    float blend = smoothstep(-0.3, 0.3, band_value);
    vec3 base_color = mix(color_a, color_b, blend);
    
    // === Modulation par les données climatiques ===
    // La température locale module la luminosité
    float temp_normalized = clamp((temperature - params.avg_temperature + 30.0) / 60.0, 0.0, 1.0);
    base_color *= mix(0.85, 1.15, temp_normalized);
    
    // L'humidité module la saturation (zones humides = plus saturées, sèches = plus pâles)
    float saturation_boost = mix(0.9, 1.1, humidity);
    vec3 grey = vec3(dot(base_color, vec3(0.299, 0.587, 0.114)));
    base_color = mix(grey, base_color, saturation_boost);
    
    // === Tourbillons / grandes tempêtes ===
    // Utiliser un bruit cellulaire pour créer des structures de vortex
    float vortex_freq = 3.0 / params.cylinder_radius;
    float vortex_noise = fbm(cyl * vortex_freq + vec3(turbulence_large * 0.5, 0.0, 0.0), 
                              5, 0.6, 2.0, params.seed + 5000u);
    
    // Les vortex sont plus probables à certaines latitudes (zones de cisaillement entre bandes)
    float shear_zone = abs(fract(band_continuous) - 0.5) * 2.0;  // 1 aux frontières de bandes
    float vortex_strength = smoothstep(0.6, 0.9, vortex_noise) * shear_zone;
    
    // Couleur du vortex (légèrement plus sombre/rougeâtre pour les planètes chaudes, plus clair pour les froides)
    vec3 vortex_color = mix(
        base_color * 0.7,                                          // Normale: assombrir
        mix(vec3(0.65, 0.35, 0.20), vec3(0.35, 0.55, 0.75), 1.0 - temp_factor),  // Teinte tempête  
        0.5
    );
    base_color = mix(base_color, vortex_color, vortex_strength * 0.6);
    
    // === Texture fine (chevrons, ondulations) ===
    float fine_detail = turbulence_fine * 0.06;
    base_color += vec3(fine_detail);
    
    // === Grande tache (tempête majeure) ===
    // Position de la grande tache basée sur le seed
    float spot_lon = hashFloat(params.seed + 42u);
    float spot_lat = hashFloat(params.seed + 43u) * 0.4 - 0.2;  // Près de l'équateur
    float spot_size = 0.04 + hashFloat(params.seed + 44u) * 0.03;  // Taille variable
    
    vec2 spot_center = vec2(spot_lon, spot_lat * 0.5 + 0.5);
    float dx = u - spot_center.x;
    // Wrapping horizontal
    if (dx > 0.5) dx -= 1.0;
    if (dx < -0.5) dx += 1.0;
    float dy = v - spot_center.y;
    
    // Ovale horizontal (ellipse 2:1)
    float spot_dist = sqrt(dx * dx / (spot_size * spot_size * 4.0) + dy * dy / (spot_size * spot_size));
    float spot_mask = 1.0 - smoothstep(0.8, 1.2, spot_dist);
    
    if (spot_mask > 0.0) {
        // Spirale dans la tache
        float angle = atan(dy, dx);
        float spiral = sin(angle * 3.0 + spot_dist * 30.0 + turbulence_mid * 2.0) * 0.5 + 0.5;
        
        // Couleur de la tache (plus intensément colorée)
        vec3 spot_color = mix(
            vec3(0.75, 0.35, 0.18),   // Chaud: rouge-orange (Grande Tache Rouge de Jupiter)
            vec3(0.25, 0.55, 0.80),   // Froid: bleu profond (Grande Tache Sombre de Neptune)
            1.0 - temp_factor
        );
        
        // Variation interne avec spirale
        spot_color = mix(spot_color, spot_color * 1.3, spiral * 0.3);
        
        base_color = mix(base_color, spot_color, spot_mask * 0.7);
    }
    
    // === Assombrissement aux pôles ===
    float polar_darkening = 1.0 - pow(abs_lat, 3.0) * 0.25;
    base_color *= polar_darkening;
    
    // === Clamp final ===
    base_color = clamp(base_color, vec3(0.0), vec3(1.0));
    
    // === Écrire le résultat ===
    imageStore(final_map, pos, vec4(base_color, 1.0));
}
