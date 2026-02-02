#[compute]
#version 450

// ============================================================================
// BIOME CLASSIFICATION SHADER
// ============================================================================
// Classifie chaque pixel en biome basé sur le diagramme de Whittaker :
// - Température (climate_texture.R) en °C
// - Humidité/Précipitations (climate_texture.G) normalisé 0-1
// - Élévation (geo_texture.R) en mètres
// - Masque eau (water_mask)
// - Type de planète (atmosphere_type)
//
// EXCLUT explicitement : rivières, calottes glaciaires, régions
// Utilise des tables Whittaker différentes par type de planète
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES D'ENTRÉE ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;       // R=height, G=bedrock, B=sediment, A=water_height
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;   // R=temperature, G=humidity, B=windX, A=windY
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;          // 0=terre, 1=eau salée, 2=eau douce
layout(set = 0, binding = 3, r32f) uniform readonly image2D river_flux;           // Intensité flux (pour humidité sol uniquement)

// === SET 0 : TEXTURES DE SORTIE ===
layout(set = 0, binding = 4, r32ui) uniform writeonly uimage2D biome_id;          // ID du biome
layout(set = 0, binding = 5, rgba8) uniform writeonly image2D biome_colored;      // Couleur RGBA8

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform BiomeParams {
    uint width;
    uint height;
    uint atmosphere_type;    // 0=Terran, 1=Toxic, 2=Volcanic, 3=NoAtmo, 4=Dead, 5=Sterile
    uint seed;
    float sea_level;
    float cylinder_radius;
    float flux_humidity_boost;  // Boost d'humidité près des flux d'eau
    float padding;
};

// === SET 2 : SSBO BIOMES DATA ===
// Structure alignée std430 (64 bytes par biome)
struct BiomeData {
    vec4 color;              // RGB + alpha (couleur du biome) - 16 bytes
    float temp_min;          // Température minimale (°C) - 4 bytes
    float temp_max;          // Température maximale (°C) - 4 bytes
    float humid_min;         // Humidité minimale (0-1) - 4 bytes
    float humid_max;         // Humidité maximale (0-1) - 4 bytes
    float elev_min;          // Élévation minimale (m) - 4 bytes
    float elev_max;          // Élévation maximale (m) - 4 bytes
    uint water_need;         // 0=pas d'eau, 1=eau salée, 2=eau douce - 4 bytes
    uint planet_type_mask;   // Bitmask des types de planètes valides - 4 bytes
    uint is_freshwater_only; // 1 si biome eau douce uniquement - 4 bytes
    uint is_saltwater_only;  // 1 si biome eau salée uniquement - 4 bytes
    uint padding1;           // Alignement - 4 bytes
    uint padding2;           // Alignement - 4 bytes
    // Total: 64 bytes
};

layout(set = 2, binding = 0, std430) readonly buffer BiomeLUT {
    uint biome_count;
    uint padding1;
    uint padding2;
    uint padding3;
    BiomeData biomes[];
};

// === CONSTANTES ===
const uint TYPE_TERRAN = 0u;
const uint TYPE_TOXIC = 1u;
const uint TYPE_VOLCANIC = 2u;
const uint TYPE_NO_ATMOS = 3u;
const uint TYPE_DEAD = 4u;
const uint TYPE_STERILE = 5u;
const uint TYPE_GAZEUZE = 6u;

// Types de planètes sans eau (comme sans atmosphère)
// Gazeuse = pas de surface solide, donc pas d'eau liquide
// Stérile = CAN have water (exception demandée par l'utilisateur)
bool is_waterless_planet_type(uint ptype) {
    return (ptype == TYPE_NO_ATMOS) || (ptype == TYPE_GAZEUZE);
}

// Types de planètes sans atmosphère (affecte l'humidité)
bool is_airless_planet_type(uint ptype) {
    return (ptype == TYPE_NO_ATMOS) || (ptype == TYPE_GAZEUZE);
}

const float ALTITUDE_MAX = 25000.0;

// === FONCTIONS UTILITAIRES ===

// Générateur pseudo-aléatoire simple
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Bruit Simplex 2D pour irrégularité naturelle des frontières
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x*34.0)+1.0)*x); }

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Calcule un score de correspondance pour un biome donné
// Retourne 0.0 si incompatible, > 0 si compatible (plus haut = meilleur match)
float compute_biome_score(
    BiomeData biome,
    float temperature,
    float humidity,
    float elevation,
    bool is_water,
    bool is_freshwater,
    bool is_saltwater,
    uint planet_type
) {
    // Vérifier le type de planète (bitmask)
    uint planet_bit = 1u << planet_type;
    if ((biome.planet_type_mask & planet_bit) == 0u) {
        return 0.0;
    }
    
    // === GESTION EAU DOUCE / EAU SALÉE ===
    // water_need: 0=pas d'eau, 1=eau salée préférée, 2=eau douce préférée
    bool biome_needs_water = (biome.water_need > 0u);
    bool biome_prefers_freshwater = (biome.is_freshwater_only == 1u);
    bool biome_prefers_saltwater = (biome.is_saltwater_only == 1u);
    
    // Si le biome nécessite de l'eau mais le pixel n'en a pas
    if (biome_needs_water && !is_water) {
        return 0.0;
    }
    
    // LOGIQUE STRICTE : Un biome d'eau DOIT correspondre au type d'eau du pixel
    if (biome_needs_water && is_water) {
        // Si le biome est marqué eau douce uniquement
        if (biome_prefers_freshwater) {
            // Le pixel DOIT être eau douce
            if (!is_freshwater) {
                return 0.0;  // Pixel eau salée sur biome eau douce → REJET
            }
        }
        // Si le biome est marqué eau salée uniquement
        else if (biome_prefers_saltwater) {
            // Le pixel DOIT être eau salée
            if (is_freshwater) {
                return 0.0;  // Pixel eau douce sur biome eau salée → REJET
            }
        }
        // Si le biome n'a ni flag freshwater ni saltwater
        // C'est un biome "générique" qui accepte les deux types d'eau
        // (cas rare, normalement tous les biomes d'eau devraient avoir un flag)
    }
    
    // Vérifier si le pixel est dans les plages acceptables
    // Température
    if (temperature < biome.temp_min || temperature > biome.temp_max) {
        return 0.0;
    }
    
    // Humidité
    if (humidity < biome.humid_min || humidity > biome.humid_max) {
        return 0.0;
    }
    
    // Élévation
    if (elevation < biome.elev_min || elevation > biome.elev_max) {
        return 0.0;
    }
    
    // Calculer un score basé sur la proximité du centre des plages
    float temp_center = (biome.temp_min + biome.temp_max) * 0.5;
    float humid_center = (biome.humid_min + biome.humid_max) * 0.5;
    float elev_center = (biome.elev_min + biome.elev_max) * 0.5;
    
    float temp_range = max(biome.temp_max - biome.temp_min, 1.0);
    float humid_range = max(biome.humid_max - biome.humid_min, 0.01);
    float elev_range = max(biome.elev_max - biome.elev_min, 1.0);
    
    // Distance normalisée au centre (0 = parfait, 1 = aux bords)
    float temp_dist = abs(temperature - temp_center) / (temp_range * 0.5);
    float humid_dist = abs(humidity - humid_center) / (humid_range * 0.5);
    float elev_dist = abs(elevation - elev_center) / (elev_range * 0.5);
    
    // Score inversé (plus proche du centre = meilleur score)
    float score = 3.0 - (temp_dist + humid_dist + elev_dist);
    
    // Bonus pour correspondance exacte du type d'eau
    if (biome_needs_water && is_water) {
        score += 0.5;
        // Bonus supplémentaire si le type d'eau correspond exactement
        if (biome_prefers_freshwater && is_freshwater) {
            score += 1.0;  // Gros bonus pour eau douce sur biome eau douce
        } else if (biome_prefers_saltwater && is_saltwater) {
            score += 1.0;  // Gros bonus pour eau salée sur biome eau salée
        }
    }
    
    // Pénalité légère pour les plages très larges (favorise la spécificité)
    float specificity = 1.0 / (1.0 + temp_range / 50.0 + humid_range + elev_range / 5000.0);
    score += specificity * 0.3;
    
    return max(score, 0.001);  // Toujours > 0 si on arrive ici
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérification des limites
    if (pixel.x >= int(width) || pixel.y >= int(height)) {
        return;
    }
    
    // === LECTURE DES DONNÉES D'ENTRÉE ===
    vec4 geo = imageLoad(geo_texture, pixel);
    vec4 climate = imageLoad(climate_texture, pixel);
    uint water_type = imageLoad(water_mask, pixel).r;
    float flux = imageLoad(river_flux, pixel).r;
    
    float elevation = geo.r;           // Hauteur en mètres
    float water_height = geo.a;        // Colonne d'eau
    float temperature = climate.r;     // Température en °C
    float humidity = climate.g;        // Humidité 0-1
    
    // === GESTION DES TYPES DE PLANÈTES SPÉCIAUX ===
    // Planètes gazeuses et sans atmosphère : pas d'eau liquide
    bool waterless_planet = is_waterless_planet_type(atmosphere_type);
    bool airless_planet = is_airless_planet_type(atmosphere_type);
    
    // Pour les planètes sans eau, forcer water_type à 0
    if (waterless_planet) {
        water_type = 0u;
        water_height = 0.0;
    }
    
    // Pour les planètes sans atmosphère, l'humidité n'a pas de sens
    if (airless_planet) {
        humidity = 0.0;
    }
    
    // Boost d'humidité près des flux d'eau (zones humides, pas rivières)
    // Seulement si la planète a de l'eau et une atmosphère
    if (!waterless_planet && !airless_planet) {
        float flux_boost = min(flux * flux_humidity_boost, 0.3);
        humidity = min(humidity + flux_boost, 1.0);
    }
    
    // Déterminer le type d'eau
    // water_mask: 0=terre, 1=eau salée, 2=eau douce
    bool is_water = (water_type > 0u) || (water_height > 0.1);
    bool is_freshwater = (water_type == 2u);
    bool is_saltwater = (water_type == 1u) || (is_water && !is_freshwater);
    bool is_underwater = (elevation < sea_level && water_height > 0.1);
    
    // Forcer pas d'eau si planète sans eau
    if (waterless_planet) {
        is_water = false;
        is_freshwater = false;
        is_saltwater = false;
    }
    
    // Ajuster l'élévation pour les zones sous-marines (profondeur)
    float effective_elevation = elevation;
    if (is_underwater) {
        effective_elevation = elevation;  // Garder la profondeur réelle
    }
    
    // Ajouter un peu de bruit pour les frontières naturelles
    vec2 noise_pos = vec2(pixel) * 0.02 + vec2(float(seed) * 0.1);
    float noise = snoise(noise_pos) * 5.0;  // ±5°C de variation
    float temp_with_noise = temperature + noise * 0.1;
    
    // Pour les planètes sans atmosphère, pas de bruit d'humidité
    float humid_with_noise = humidity;
    if (!airless_planet) {
        float humid_noise = snoise(noise_pos * 0.5 + vec2(100.0)) * 0.05;
        humid_with_noise = clamp(humidity + humid_noise, 0.0, 1.0);
    }
    
    // === RECHERCHE DU MEILLEUR BIOME ===
    // Constante spéciale pour "aucun biome trouvé"
    const uint NO_BIOME_FOUND = 0xFFFFFFFFu;
    const vec4 ERROR_COLOR = vec4(1.0, 0.0, 0.0, 1.0);  // ROUGE = erreur/pas de biome
    
    uint best_biome_id = NO_BIOME_FOUND;
    float best_score = 0.0;
    vec4 best_color = ERROR_COLOR;  // Rouge par défaut si aucun biome trouvé
    
    for (uint i = 0u; i < biome_count; i++) {
        BiomeData biome = biomes[i];
        
        float score = compute_biome_score(
            biome,
            temp_with_noise,
            humid_with_noise,
            effective_elevation,
            is_water,
            is_freshwater,
            is_saltwater,
            atmosphere_type
        );
        
        // Bruit spatial cohérent pour les frontières irrégulières (pas de hash par biome!)
        // Le bruit est basé uniquement sur la position, pas sur l'ID du biome
        // pour éviter les artefacts de "lignes"
        
        if (score > best_score) {
            best_score = score;
            best_biome_id = i;
            best_color = biome.color;
        }
    }
    
    // Si aucun biome trouvé, garder le rouge et un ID spécial
    // Cela indique un problème de configuration des biomes pour ce type de planète
    if (best_biome_id == NO_BIOME_FOUND) {
        best_biome_id = 0xFFFFu;  // ID invalide pour debug
        // best_color reste rouge
    }
    
    // === ÉCRITURE DES RÉSULTATS ===
    imageStore(biome_id, pixel, uvec4(best_biome_id, 0u, 0u, 0u));
    imageStore(biome_colored, pixel, best_color);
}
