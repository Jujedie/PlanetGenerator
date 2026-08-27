#[compute]
#version 450

// ============================================================================
// FINAL MAP SHADER - Combinaison des couches visuelles
// ============================================================================
// Ce shader génère la carte finale en combinant plusieurs couches :
// 1. geo_texture : palette hypsométrique et ombrage topographique
// 2. biome_id : modulation écologique de la palette cartographique
// 3. river_flux : cours d'eau principaux
// 4. ice_caps : banquise en overlay prioritaire
//
// Le résultat n'est volontairement ni une copie de biome_colored, ni une
// simple texture de végétation : c'est une carte physique stylisée.
//
// Entrées :
// - biome_id (R32UI) : Index du biome pour lookup SSBO
// - biome_colored (RGBA8) : Couleur distinctive des biomes (modulation)
// - river_flux (R32F) : Intensité du flux des rivières
// - geo_texture (RGBA32F) : R=height pour calcul ombrage
// - ice_caps (RGBA8) : Banquise (blanc/transparent)
// - BiomeLUT (SSBO) : Couleurs végétation des biomes
//
// Sorties :
// - final_map (RGBA8) : Carte physique stylisée, directement utilisable
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
const vec3 BANQUISE_DEFAULT = vec3(0.87, 0.86, 0.80);  // Ivoire froid cartographique
const vec3 BANQUISE_VOLCANIC = vec3(0.231, 0.192, 0.169);  // Cooled lava

vec3 getBanquiseColor(uint atmo) {
    // Bleu-gris naturel pour tous les types d'atmosphère sauf volcanic.
    if (atmo == 2u) return BANQUISE_VOLCANIC;  // Volcanic banquise is cooled lava
    return BANQUISE_DEFAULT;
}

// ============================================================================
// RIVER COLOR BY ATMOSPHERE - Mélange dynamique selon le type de planète
// ============================================================================

/// Calcule la couleur finale de la rivière en fonction du terrain et du type d'atmosphère
/// Chaque type de planète utilise un mode de mélange adapté à son esthétique
vec3 getRiverBlendedColor(vec3 terrain_color, vec3 river_color, uint atmo) {
    // TYPE_VOLCANIC (2) : Rivières de lave - elles brillent et dominent le terrain
    if (atmo == 2u) {
        // Forte dominance de la couleur lave, légère influence du terrain
        return mix(terrain_color, river_color, 0.85);
    }
    // TYPE_TOXIC (1) : Rivières acides - très visibles, teinte acide dominante
    if (atmo == 1u) {
        return mix(terrain_color, river_color, 0.75);
    }
    // TYPE_DEAD (4) : Rivières polluées/boueuses - se fondent plus avec le terrain
    if (atmo == 4u) {
        return mix(terrain_color, river_color, 0.65);
    }
    // TYPE_TERRAN (0) et autres : bleu-vert sombre accordé aux eaux de la
    // carte physique. Le biome rivière ne sert plus que de variation légère,
    // afin d'éviter les filaments cyan clair sur les plaines olive.
    vec3 natural_water = mix(vec3(0.23, 0.40, 0.42), river_color, 0.10);
    // Équivalent d'un alpha faible sur la carte finale opaque : le terrain
    // reste dominant et le réseau hydrographique n'apparaît qu'en filigrane.
    return mix(terrain_color, natural_water, 0.26);
}

// ============================================================================
// HILLSHADE CALCULATION
// ============================================================================

ivec2 wrappedPosition(ivec2 pos, int w, int h) {
    return ivec2((pos.x % w + w) % w, clamp(pos.y, 0, h - 1));
}

float elevationAt(ivec2 pos, int w, int h) {
    return imageLoad(geo_texture, wrappedPosition(pos, w, h)).r;
}

// Filtre en croix très léger réservé au rendu. Il ne modifie jamais la donnée
// physique et évite que le bruit pixel par pixel transforme les isolignes en
// un maillage illisible.
float displayElevation(ivec2 pos, int w, int h) {
    float center = elevationAt(pos, w, h) * 4.0;
    center += elevationAt(pos + ivec2(-1, 0), w, h);
    center += elevationAt(pos + ivec2(1, 0), w, h);
    center += elevationAt(pos + ivec2(0, -1), w, h);
    center += elevationAt(pos + ivec2(0, 1), w, h);
    return center * 0.125;
}

float calculateTopoShading(ivec2 pos, int w, int h) {
    float h_left = displayElevation(pos + ivec2(-1, 0), w, h);
    float h_right = displayElevation(pos + ivec2(1, 0), w, h);
    float h_up = displayElevation(pos + ivec2(0, -1), w, h);
    float h_down = displayElevation(pos + ivec2(0, 1), w, h);
    
    // Les hauteurs sont en mètres : normaliser le gradient évite que quelques
    // centaines de mètres entre pixels produisent des murs noirs artificiels.
    float dx = (h_right - h_left) / 2400.0;
    float dy = (h_down - h_up) / 2400.0;
    
    vec3 light_dir = normalize(vec3(-1.0, -1.0, 1.0));
    vec3 normal = normalize(vec3(-dx, -dy, 1.0));
    float shade = dot(normal, light_dir);
    
    // Une surface plane vaut exactement 0.5. Le relief pourra donc éclaircir
    // autant qu'assombrir sans ternir uniformément toute la carte.
    return clamp(0.5 + (shade - light_dir.z) * 0.65, 0.0, 1.0);
}

// Palette inspirée des cartes physiques de référence : plaines olive, reliefs
// sable/saumon et sommets crème. Les transitions restent continues.
vec3 terranLandHypsometry(float relative_height) {
    const vec3 COAST = vec3(0.66, 0.67, 0.47);
    const vec3 LOWLAND = vec3(0.62, 0.61, 0.37);
    const vec3 UPLAND = vec3(0.76, 0.63, 0.43);
    const vec3 HIGHLAND = vec3(0.91, 0.70, 0.55);
    const vec3 MOUNTAIN = vec3(0.96, 0.80, 0.66);
    const vec3 SUMMIT = vec3(0.96, 0.88, 0.75);

    vec3 color = mix(COAST, LOWLAND, smoothstep(0.0, 220.0, relative_height));
    color = mix(color, UPLAND, smoothstep(220.0, 900.0, relative_height));
    color = mix(color, HIGHLAND, smoothstep(900.0, 2200.0, relative_height));
    color = mix(color, MOUNTAIN, smoothstep(2200.0, 3800.0, relative_height));
    return mix(color, SUMMIT, smoothstep(3800.0, 6200.0, relative_height));
}

// Donne au relief une géologie cohérente avec le climat du biome. L'ancienne
// version appliquait la même base olive à toutes les terres, ce qui transformait
// notamment les déserts et les régions polaires en variantes désaturées d'une
// même couleur. Les intervalles du biome permettent de corriger cela sans
// dépendre de son index ni de son nom.
vec3 terranBiomeSurface(BiomeData biome_data, vec3 classified_color, float relative_height) {
    vec3 physical = terranLandHypsometry(relative_height);

    float dry = 1.0 - smoothstep(0.18, 0.52, biome_data.humid_max);
    float cold = 1.0 - smoothstep(-10.0, 7.0, biome_data.temp_max);

    const vec3 DRY_LOWLAND = vec3(0.76, 0.62, 0.39);
    const vec3 DRY_UPLAND = vec3(0.67, 0.42, 0.27);
    const vec3 DRY_SUMMIT = vec3(0.86, 0.70, 0.54);
    vec3 dry_physical = mix(DRY_LOWLAND, DRY_UPLAND, smoothstep(250.0, 2100.0, relative_height));
    dry_physical = mix(dry_physical, DRY_SUMMIT, smoothstep(3000.0, 5900.0, relative_height));

    const vec3 COLD_LOWLAND = vec3(0.60, 0.64, 0.62);
    const vec3 COLD_UPLAND = vec3(0.73, 0.78, 0.79);
    const vec3 COLD_SUMMIT = vec3(0.90, 0.94, 0.95);
    vec3 cold_physical = mix(COLD_LOWLAND, COLD_UPLAND, smoothstep(200.0, 1900.0, relative_height));
    cold_physical = mix(cold_physical, COLD_SUMMIT, smoothstep(2100.0, 5000.0, relative_height));

    physical = mix(physical, dry_physical, dry);
    // Le froid prévaut sur l'aridité pour qu'un désert polaire reste minéral
    // et glacé plutôt que de devenir ocre.
    physical = mix(physical, cold_physical, cold);

    // La seconde couleur du biome est une couleur de matériau conçue pour la
    // carte finale. La couleur d'identification ne sert que de légère nuance :
    // elle ne peut plus transformer le rendu en copie délavée de biome_map.
    vec3 material = mix(biome_data.color.rgb, classified_color, 0.06);
    float identity_strength = 0.70 + 0.10 * max(dry, cold);
    identity_strength -= 0.06 * smoothstep(2600.0, 6000.0, relative_height);
    return mix(physical, material, identity_strength);
}

vec3 terranWaterHypsometry(float depth, vec3 source_water) {
    // Vue satellite stylisée : lacs, mers et océans partagent la même famille
    // bleu-vert. La profondeur ne crée plus un écart cyan/bleu artificiel.
    const vec3 SHALLOW = vec3(0.30, 0.46, 0.47);
    const vec3 MID = vec3(0.27, 0.43, 0.45);
    const vec3 DEEP = vec3(0.24, 0.39, 0.42);
    vec3 color = mix(SHALLOW, MID, smoothstep(80.0, 1200.0, depth));
    color = mix(color, DEEP, smoothstep(1200.0, 5200.0, depth));
    return mix(color, source_water, 0.03);
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
    float elevation = imageLoad(geo_texture, pos).r;
    float relative_height = elevation - params.sea_level;
    
    bool is_water = water.a > 0.0;  // L'eau a alpha > 0 dans water_colored
    bool is_banquise = ice.a > 0.025;
    bool is_river = (river_bid != 0xFFFFFFFFu) &&
        (flux >= params.river_threshold);
    
    // === STEP 1: Base physique + modulation écologique ===
    vec3 color = biome.rgb;
    vec3 vegetation_color = biome.rgb;
    if (biome_count > 0u && biome_index < biome_count) {
        vegetation_color = biomes[biome_index].color.rgb;
    }

    if (params.atmosphere_type == 0u) {
        if (is_water) {
            color = terranWaterHypsometry(max(-relative_height, 0.0), water.rgb);
        } else {
            if (biome_count > 0u && biome_index < biome_count) {
                color = terranBiomeSurface(
                    biomes[biome_index],
                    biome.rgb,
                    max(relative_height, 0.0)
                );
            } else {
                color = mix(
                    terranLandHypsometry(max(relative_height, 0.0)),
                    biome.rgb,
                    0.55
                );
            }
        }
    } else {
        color = vegetation_color;
    }
    
    // === STEP 2: Apply subtle, continuous terrain lighting ===
    float shading = calculateTopoShading(pos, w, h);
    
    // Réduire l'intensité du relief sur l'eau
    float effective_strength = params.relief_strength;
    if (is_water) {
        effective_strength *= params.water_relief_factor;  // Relief très atténué sur l'eau
    }
    
    float shade_factor = 1.0 + (shading - 0.5) * 2.0 * effective_strength;
    color *= shade_factor;
    
    // === STEP 3: Rivers overlay ===
    // Si un biome rivière est assigné, appliquer la colorisation dynamique
    // selon le type d'atmosphère de la planète
    if (is_river && river_bid < river_biome_count) {
        vec3 river_veg_color = river_biomes[river_bid].color.rgb;
        // Mélange adapté au type de planète (lave, acide, boue, eau...)
        color = getRiverBlendedColor(color, river_veg_color, params.atmosphere_type);
    }
    
    // === STEP 4: Banquise overlay (highest priority) ===
    // Banquise uniquement sur les pixels eau (double vérification)
    if (is_banquise && is_water) {
        // Respecter la variation bord/cœur calculée par ice_caps au lieu de
        // remplacer toute la calotte par un même bleu pâle.
        vec3 banquise_color = mix(
            getBanquiseColor(params.atmosphere_type),
            ice.rgb,
            params.atmosphere_type == 2u ? 0.25 : 0.65
        );
        // ice.a encode désormais la concentration. Une lisière peu compacte
        // doit laisser voir l'océan, tandis que le pack ancien reste opaque.
        float ice_opacity = smoothstep(0.025, 0.92, ice.a) * 0.84;
        color = mix(color, banquise_color, ice_opacity);
    }
    
    // === OUTPUT ===
    imageStore(final_map, pos, vec4(color, 1.0));
}
