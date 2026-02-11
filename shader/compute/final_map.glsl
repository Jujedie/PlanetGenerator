#[compute]
#version 450

// ============================================================================
// FINAL MAP SHADER - Combinaison des couches visuelles
// ============================================================================
// Ce shader génère la carte finale en combinant plusieurs couches :
// 1. biome_id : Index du biome → lookup SSBO pour couleur végétation
// 2. river_flux : Rivières (détection via flux)
// 3. geo_texture : Ombrage topographique (relief)
// 4. ice_caps : Banquise en overlay prioritaire
//
// Formule finale :
// color = biomes[biome_id].color * (hillshade)
// if banquise: color = banquise_color
//
// Entrées :
// - biome_id (R32UI) : Index du biome pour lookup SSBO
// - biome_colored (RGBA8) : Couleur distinctive des biomes (non utilisée ici)
// - river_flux (R32F) : Intensité du flux des rivières
// - geo_texture (RGBA32F) : R=height pour calcul ombrage
// - ice_caps (RGBA8) : Banquise (blanc/transparent)
// - BiomeLUT (SSBO) : Couleurs végétation des biomes
//
// Sorties :
// - final_map (RGBA8) : Carte finale avec couleurs végétation réalistes
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba8) uniform readonly image2D biome_colored;
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D ice_caps;
layout(set = 0, binding = 4, rgba8) uniform readonly image2D water_colored;
layout(set = 0, binding = 5, rgba8) uniform writeonly image2D final_map;
layout(set = 0, binding = 6, r32ui) uniform readonly uimage2D biome_id;
layout(set = 0, binding = 7, r32ui) uniform readonly uimage2D river_biome_id;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform FinalMapParams {
    uint width;
    uint height;
    uint atmosphere_type;
    float river_threshold;      // Seuil de flux pour afficher une rivière (défaut: 5.0)
    float relief_strength;      // Force de l'ombrage topographique (défaut: 0.3)
    float sea_level;
    float min_elevation;        // Élévation minimale pour normalisation
    float max_elevation;        // Élévation maximale pour normalisation
    float water_relief_factor;  // Facteur de réduction du relief sur l'eau (défaut: 0.2)
    float padding1;
} params;

// === SET 2: BIOMES SSBO (VEGETATION COLORS) ===
// Structure alignée std430 (64 bytes par biome) - doit correspondre à biome_classify.glsl
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
    uint header_padding1;
    uint header_padding2;
    uint header_padding3;
    BiomeData biomes[];
};

// === SET 3: RIVER BIOMES SSBO (VEGETATION COLORS) ===
// Structure alignée std430 (64 bytes par biome rivière)
struct RiverBiomeData {
    vec4 color;              // RGB + alpha (couleur végétation rivière) - 16 bytes
    float temp_min;          // Température minimale (°C) - 4 bytes
    float temp_max;          // Température maximale (°C) - 4 bytes
    float humid_min;         // (non utilisé) - 4 bytes
    float humid_max;         // (non utilisé) - 4 bytes
    float elev_min;          // (non utilisé) - 4 bytes
    float elev_max;          // (non utilisé) - 4 bytes
    uint water_need;         // (non utilisé) - 4 bytes
    uint planet_type_mask;   // Bitmask des types de planètes valides - 4 bytes
    uint river_type;         // 0=Affluent, 1=Rivière, 2=Fleuve, 3=Lac, etc. - 4 bytes
    uint rpad1;              // Alignement - 4 bytes
    uint rpad2;              // Alignement - 4 bytes
    uint rpad3;              // Alignement - 4 bytes
    // Total: 64 bytes
};

layout(set = 3, binding = 0, std430) readonly buffer RiverBiomeLUT {
    uint river_biome_count;
    uint river_header_padding1;
    uint river_header_padding2;
    uint river_header_padding3;
    RiverBiomeData river_biomes[];
};

// ============================================================================
// BANQUISE COLOR BY ATMOSPHERE
// ============================================================================

// Banquise color constants
const vec3 BANQUISE_DEFAULT = vec3(0.831, 0.827, 0.824);  // 0xd4d3d2ff
const vec3 BANQUISE_VOLCANIC = vec3(0.231, 0.192, 0.169);  // Cooled lava

vec3 getBanquiseColor(uint atmo) {
    // Couleur banquise: 0xd4d3d2ff = RGB(212, 211, 210) = vec3(0.831, 0.827, 0.824)
    // Utilisé pour tous les types d'atmosphère sauf volcanic
    if (atmo == 2u) return BANQUISE_VOLCANIC;  // Volcanic banquise is cooled lava
    return BANQUISE_DEFAULT;  // 0xd4d3d2ff pour tous les autres
}

// ============================================================================
// HILLSHADE CALCULATION
// ============================================================================

float calculateTopoShading(ivec2 pos, int w, int h) {
    ivec2 left = ivec2((pos.x - 1 + w) % w, pos.y);
    ivec2 right = ivec2((pos.x + 1) % w, pos.y);
    ivec2 up = ivec2(pos.x, max(pos.y - 1, 0));
    ivec2 down = ivec2(pos.x, min(pos.y + 1, h - 1));
    
    float h_left = imageLoad(geo_texture, left).r;
    float h_right = imageLoad(geo_texture, right).r;
    float h_up = imageLoad(geo_texture, up).r;
    float h_down = imageLoad(geo_texture, down).r;
    
    float dx = (h_right - h_left) * 0.5;
    float dy = (h_down - h_up) * 0.5;
    
    vec3 light_dir = normalize(vec3(-1.0, -1.0, 1.0));
    vec3 normal = normalize(vec3(-dx, -dy, 1.0));
    float shade = dot(normal, light_dir);
    
    return clamp((shade + 1.0) * 0.5, 0.0, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pos.x >= w || pos.y >= h) {
        return;
    }
    
    // === READ TEXTURES ===
    vec4 biome = imageLoad(biome_colored, pos);
    vec4 water = imageLoad(water_colored, pos);
    float flux = imageLoad(river_flux, pos).r;
    vec4 ice = imageLoad(ice_caps, pos);
    uint biome_index = imageLoad(biome_id, pos).r;
    uint river_bid = imageLoad(river_biome_id, pos).r;
    
    bool is_water = water.a > 0.0;  // L'eau a alpha > 0 dans water_colored
    bool is_banquise = ice.a > 0.0;
    bool is_river = (river_bid != 0xFFFFFFFFu);
    
    // === STEP 1: Base color ===
    // Utiliser le SSBO pour obtenir la couleur végétation directement via l'index du biome
    vec3 color = biomes[biome_index].color.rgb;
    
    // === STEP 2: Apply hillshade (topographic shading) ===
    float shading = calculateTopoShading(pos, w, h);
    
    // Réduire l'intensité du relief sur l'eau
    float effective_strength = params.relief_strength;
    if (is_water) {
        effective_strength *= params.water_relief_factor;  // Relief très atténué sur l'eau
    }
    
    float shade_factor = mix(1.0 - effective_strength, 1.0, shading);
    color *= shade_factor;
    
    // === STEP 3: Rivers overlay ===
    // Si un biome rivière est assigné, multiplier sa couleur végétation avec la couleur du terrain
    if (is_river && river_bid < river_biome_count) {
        vec3 river_veg_color = river_biomes[river_bid].color.rgb;
        // Multiplicative blending : assombrit le terrain avec la teinte de la rivière
        // Cela donne un aspect naturel où la rivière prend la teinte du terrain environnant
        color = color * river_veg_color * 2.5;
        // Clamp pour éviter la surbrillance
        color = min(color, vec3(1.0));
    }
    
    // === STEP 4: Banquise overlay (highest priority) ===
    if (is_banquise) {
        vec3 banquise_color = getBanquiseColor(params.atmosphere_type);
        color = banquise_color;
    }
    
    // === OUTPUT ===
    imageStore(final_map, pos, vec4(color, 1.0));
}
