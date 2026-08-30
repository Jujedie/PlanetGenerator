#[compute]
#version 450

// ============================================================================
// FINAL MAP SHADER - Combinaison des couches visuelles
// ============================================================================
// Ce shader génère la carte finale en combinant plusieurs couches :
// 1. geo_texture : palette hypsométrique et ombrage topographique
// 2. biome_id : modulation écologique de la palette cartographique
// 3. river_flux : cours d'eau principaux
// 4. ice_caps : banquise maritime en overlay prioritaire
// 5. climat + relief : neige et givre terrestres calculés localement
//
// Le résultat n'est volontairement ni une copie de biome_colored, ni une
// simple texture de végétation : c'est une carte physique stylisée.
//
// Entrées :
// - biome_id (R32UI) : Index du biome pour lookup SSBO
// - biome_colored (RGBA8) : Couleur distinctive des biomes (modulation)
// - river_flux (R32F) : Intensité du flux des rivières
// - geo_texture (RGBA32F) : R=height pour calcul ombrage
// - climate_texture (RGBA32F) : R=température, G=humidité continues
// - ice_caps (RGBA8) : Banquise uniquement (couleur, alpha=concentration)
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
layout(set = 0, binding = 8, rgba32f) uniform readonly image2D climate_texture;

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
// CRYOSPHERE FALLBACK COLOR BY ATMOSPHERE
// ============================================================================

const vec3 ICE_TERRAN = vec3(0.88, 0.92, 0.93);
const vec3 ICE_TOXIC = vec3(0.78, 0.86, 0.73);
const vec3 ICE_VOLCANIC = vec3(0.76, 0.77, 0.76);
const vec3 ICE_AIRLESS = vec3(0.76, 0.84, 0.88);
const vec3 ICE_DEAD = vec3(0.72, 0.75, 0.70);
const vec3 ICE_STERILE = vec3(0.82, 0.84, 0.83);

vec3 getCryosphereColor(uint atmo) {
    if (atmo == 1u) return ICE_TOXIC;
    if (atmo == 2u) return ICE_VOLCANIC;
    if (atmo == 3u) return ICE_AIRLESS;
    if (atmo == 4u) return ICE_DEAD;
    if (atmo == 5u) return ICE_STERILE;
    return ICE_TERRAN;
}

// ============================================================================
// RIVER COLOR BY ATMOSPHERE - Mélange dynamique selon le type de planète
// ============================================================================

/// Calcule la couleur finale de la rivière en fonction du terrain et du type d'atmosphère
/// Chaque type de planète utilise un mode de mélange adapté à son esthétique
vec3 getRiverBlendedColor(vec3 terrain_color, vec3 river_color, uint atmo) {
    // TYPE_VOLCANIC (2) : Rivières de lave - elles brillent et dominent le terrain
    if (atmo == 2u) {
        vec3 lava = mix(vec3(0.70, 0.24, 0.06), river_color, 0.45);
        return mix(terrain_color, lava, 0.66);
    }
    // TYPE_TOXIC (1) : Rivières acides - très visibles, teinte acide dominante
    if (atmo == 1u) {
        vec3 acid = mix(vec3(0.36, 0.42, 0.18), river_color, 0.30);
        return mix(terrain_color, acid, 0.58);
    }
    // TYPE_DEAD (4) : Rivières polluées/boueuses - se fondent plus avec le terrain
    if (atmo == 4u) {
        vec3 polluted_water = mix(vec3(0.27, 0.25, 0.20), river_color, 0.30);
        return mix(terrain_color, polluted_water, 0.50);
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

// Détail haute fréquence dérivé du relief brut. Les palettes rocheuses
// perdent facilement leurs petits cratères et coulées lorsqu'elles ne varient
// qu'avec de grands champs climatiques ; ce passe-haut restaure leur lecture
// sans ajouter de bruit arbitraire à la géographie.
float localTerrainDetail(ivec2 pos, int w, int h) {
    float center = elevationAt(pos, w, h);
    float cardinal = (
        elevationAt(pos + ivec2(-1, 0), w, h)
        + elevationAt(pos + ivec2(1, 0), w, h)
        + elevationAt(pos + ivec2(0, -1), w, h)
        + elevationAt(pos + ivec2(0, 1), w, h)
    ) * 0.25;
    float diagonal = (
        elevationAt(pos + ivec2(-1, -1), w, h)
        + elevationAt(pos + ivec2(1, -1), w, h)
        + elevationAt(pos + ivec2(-1, 1), w, h)
        + elevationAt(pos + ivec2(1, 1), w, h)
    ) * 0.25;
    float neighborhood = mix(cardinal, diagonal, 0.34);
    return clamp((center - neighborhood) / 900.0, -1.0, 1.0);
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

// Les biomes sont des catégories utiles pour l'analyse, mais leurs frontières
// ne sont pas des frontières de couleur dans la nature. Cette moyenne spatiale
// construit une nuance écologique douce, sans mélanger la terre avec l'eau.
// Capacité écologique dérivée de l'intervalle de précipitation du biome.
// L'humidité instantanée peut reverdir légèrement un désert après une pluie,
// mais ne doit pas lui donner la couverture végétale d'une forêt.
float biomeVegetationCapacity(BiomeData biome) {
    return smoothstep(0.30, 0.66, biome.humid_max);
}

vec3 smoothedBiomeMaterial(
    ivec2 pos,
    int w,
    int h,
    vec3 fallback,
    float fallback_vegetation_capacity,
    out float vegetation_capacity
) {
    // Garder une largeur d'écotone comparable sur les aperçus et les exports
    // 4K/8K. Contrairement à la cryosphère, ce filtre est purement visuel : un
    // pas plus large évite que les classes de biome réapparaissent comme des
    // frontières de quelques pixels sur une grande planète.
    int sample_step = clamp(int(floor(max(float(w) / 2048.0, float(h) / 1024.0) + 0.5)), 1, 4);
    vec3 accumulated = vec3(0.0);
    float accumulated_capacity = 0.0;
    float total_weight = 0.0;
    for (int oy = -3; oy <= 3; ++oy) {
        for (int ox = -3; ox <= 3; ++ox) {
            ivec2 sample_pos = wrappedPosition(pos + ivec2(ox, oy) * sample_step, w, h);
            if (imageLoad(water_colored, sample_pos).a > 0.0) {
                continue;
            }
            uint sample_id = imageLoad(biome_id, sample_pos).r;
            if (sample_id >= biome_count) {
                continue;
            }
            float distance_sq = float(ox * ox + oy * oy);
            float weight = 1.0 / (1.0 + distance_sq * 0.72);
            accumulated += biomes[sample_id].color.rgb * weight;
            accumulated_capacity += biomeVegetationCapacity(biomes[sample_id]) * weight;
            total_weight += weight;
        }
    }
    if (total_weight > 0.0) {
        vegetation_capacity = accumulated_capacity / total_weight;
        return accumulated / total_weight;
    }
    vegetation_capacity = fallback_vegetation_capacity;
    return fallback;
}

// Surface terrestre pilotée par des valeurs physiques continues. Le biome
// n'apporte plus qu'une faible nuance, ce qui transforme ses frontières nettes
// en écotones. L'altitude expose progressivement la roche puis la neige.
vec3 terranClimateSurface(
    vec3 biome_material,
    float temperature,
    float humidity,
    float relative_height,
    float biome_vegetation_capacity
) {
    const float BIOME_TINT_STRENGTH = 0.16;
    float moisture = clamp(humidity, 0.0, 1.0);
    float sea_level_temperature = temperature + max(relative_height, 0.0) * 0.0065;
    float heat = smoothstep(7.0, 34.0, sea_level_temperature);
    float dryness = 1.0 - smoothstep(0.12, 0.58, moisture);

    const vec3 COOL_SOIL = vec3(0.35, 0.32, 0.23);
    const vec3 WARM_SOIL = vec3(0.55, 0.39, 0.23);
    const vec3 SAND = vec3(0.82, 0.68, 0.44);
    vec3 soil = mix(COOL_SOIL, WARM_SOIL, heat);
    soil = mix(soil, SAND, dryness * (0.48 + heat * 0.38));

    const vec3 BOREAL = vec3(0.16, 0.25, 0.14);
    const vec3 GRASSLAND = vec3(0.34, 0.45, 0.20);
    const vec3 TEMPERATE_FOREST = vec3(0.15, 0.32, 0.14);
    const vec3 TROPICAL_FOREST = vec3(0.075, 0.25, 0.10);
    vec3 open_vegetation = mix(BOREAL, GRASSLAND, smoothstep(-4.0, 16.0, sea_level_temperature));
    vec3 forest = mix(TEMPERATE_FOREST, TROPICAL_FOREST, heat);
    vec3 vegetation_color = mix(open_vegetation, forest, smoothstep(0.48, 0.86, moisture));
    float growing_temperature = smoothstep(-9.0, 5.0, temperature);
    float vegetation_cover = smoothstep(0.12, 0.58, moisture) * growing_temperature;
    vegetation_cover *= 1.0 - dryness * 0.62;

    // Après une pluie intense, un désert peut brièvement reverdir, mais seule
    // une faible fraction du sol porte cette végétation. Le maximum conserve
    // cette exception sans laisser l'humidité brute écraser l'identité aride.
    float ephemeral_greenup = smoothstep(0.68, 0.88, moisture) * 0.18;
    float ecological_capacity = max(
        clamp(biome_vegetation_capacity, 0.0, 1.0),
        ephemeral_greenup
    );
    vegetation_cover *= ecological_capacity;

    vec3 surface = mix(soil, vegetation_color, vegetation_cover * 0.91);
    surface = mix(surface, biome_material, BIOME_TINT_STRENGTH);

    const vec3 COOL_ROCK = vec3(0.47, 0.47, 0.44);
    const vec3 WARM_ROCK = vec3(0.55, 0.44, 0.36);
    vec3 exposed_rock = mix(COOL_ROCK, WARM_ROCK, heat);
    float rock_cover = smoothstep(1450.0, 3500.0, relative_height) * 0.64;
    surface = mix(surface, exposed_rock, rock_cover);

    // La limite des neiges varie d'environ 1 200 m sous climat froid à plus
    // de 5 000 m sous les tropiques. Les sommets convergent donc toujours vers
    // un blanc froid, sans former une bande d'altitude fixe mondiale.
    float snow_line = mix(
        1200.0,
        5200.0,
        smoothstep(-12.0, 34.0, sea_level_temperature)
    );
    float mountain_snow = smoothstep(snow_line - 350.0, snow_line + 700.0, relative_height);
    float permanent_ice = (
        1.0 - smoothstep(-16.0, -6.0, temperature)
    ) * smoothstep(0.22, 0.58, moisture);
    float snow_cover = max(mountain_snow, permanent_ice);
    const vec3 SNOW = vec3(0.89, 0.93, 0.93);
    return mix(surface, SNOW, snow_cover * 0.96);
}

vec3 terranWaterHypsometry(float depth, vec3 source_water) {
    // Vue orbitale stylisée : bleu côtier lisible, puis bleu marine profond.
    // Le rendu reste volontairement un peu plus clair que les pixels d'une
    // photographie spatiale, avant l'assombrissement appliqué à l'export.
    const vec3 SHALLOW = vec3(0.10, 0.29, 0.38);
    const vec3 MID = vec3(0.045, 0.16, 0.29);
    const vec3 DEEP = vec3(0.018, 0.065, 0.18);
    vec3 color = mix(SHALLOW, MID, smoothstep(80.0, 1200.0, depth));
    color = mix(color, DEEP, smoothstep(1200.0, 5200.0, depth));
    return mix(color, source_water, 0.03);
}

vec3 planetaryLandSurface(
    vec3 biome_material,
    float temperature,
    float humidity,
    float relative_height,
    float biome_vegetation_capacity,
    uint atmosphere_type
) {
    if (atmosphere_type == 0u) {
        return terranClimateSurface(
            biome_material,
            temperature,
            humidity,
            relative_height,
            biome_vegetation_capacity
        );
    }

    float moisture = clamp(humidity, 0.0, 1.0);
    float height_factor = smoothstep(200.0, 4200.0, relative_height);
    vec3 physical_surface;
    float biome_identity;

    if (atmosphere_type == 1u) {
        // Toxique : soufre sec, dépôts ferriques chauds et bassins acides.
        float heat = smoothstep(35.0, 360.0, temperature);
        vec3 sulfur = mix(vec3(0.45, 0.43, 0.26), vec3(0.54, 0.39, 0.20), heat);
        vec3 acid_soil = mix(vec3(0.30, 0.32, 0.21), vec3(0.25, 0.28, 0.18), heat);
        physical_surface = mix(sulfur, acid_soil, smoothstep(0.35, 0.82, moisture));
        physical_surface = mix(physical_surface, vec3(0.51, 0.48, 0.34), height_factor * 0.34);
        biome_identity = 0.34;
    } else if (atmosphere_type == 2u) {
        // Volcanique : basalte, cendres, oxydes et soufre, sans végétation
        // Terran injectée dans la palette.
        float heat = smoothstep(80.0, 500.0, temperature);
        vec3 basalt = mix(vec3(0.16, 0.17, 0.18), vec3(0.24, 0.18, 0.16), heat);
        vec3 ash = mix(vec3(0.32, 0.31, 0.30), vec3(0.38, 0.28, 0.23), heat);
        physical_surface = mix(basalt, ash, smoothstep(0.10, 0.62, moisture) * 0.54);
        physical_surface = mix(physical_surface, vec3(0.40, 0.37, 0.32), height_factor * 0.28);
        biome_identity = 0.38;
    } else if (atmosphere_type == 3u) {
        // Sans atmosphère : régolithe neutre dont la valeur suit surtout le
        // relief. La température ne crée aucune fausse verdure.
        vec3 mare = vec3(0.12, 0.14, 0.17);
        vec3 regolith = vec3(0.40, 0.40, 0.39);
        vec3 highland = vec3(0.64, 0.62, 0.57);
        physical_surface = mix(mare, regolith, smoothstep(-1200.0, 600.0, relative_height));
        physical_surface = mix(physical_surface, highland, smoothstep(700.0, 4200.0, relative_height));
        biome_identity = 0.30;
    } else if (atmosphere_type == 4u) {
        // Monde mort : terres désaturées, sel sec et zones humides sombres.
        float heat = smoothstep(5.0, 55.0, temperature);
        vec3 waste = mix(vec3(0.36, 0.34, 0.31), vec3(0.43, 0.34, 0.28), heat);
        vec3 mire = vec3(0.27, 0.28, 0.25);
        physical_surface = mix(waste, mire, smoothstep(0.38, 0.82, moisture) * 0.62);
        physical_surface = mix(physical_surface, vec3(0.46, 0.43, 0.39), height_factor * 0.38);
        biome_identity = 0.34;
    } else if (atmosphere_type == 5u) {
        // Stérile / martien : poussière ferrique dans les plaines, roche plus
        // froide et grise sur les reliefs.
        float warmth = smoothstep(-45.0, 45.0, temperature);
        vec3 cold_rock = vec3(0.43, 0.38, 0.34);
        vec3 ferric_dust = vec3(0.61, 0.39, 0.25);
        physical_surface = mix(cold_rock, ferric_dust, warmth);
        physical_surface = mix(physical_surface, vec3(0.39, 0.36, 0.35), height_factor * 0.58);
        biome_identity = 0.46;
    } else {
        physical_surface = biome_material;
        biome_identity = 1.0;
    }

    // Le matériau de biome est lissé spatialement : il donne l'identité
    // locale sans produire de frontières de couleur artificiellement nettes.
    return mix(physical_surface, biome_material, biome_identity);
}

vec3 planetaryWaterSurface(float depth, vec3 source_water, uint atmosphere_type) {
    if (atmosphere_type == 0u) {
        return terranWaterHypsometry(depth, source_water);
    }

    vec3 shallow;
    vec3 deep;
    float source_identity;
    if (atmosphere_type == 1u) {
        shallow = vec3(0.34, 0.37, 0.21);
        deep = vec3(0.15, 0.19, 0.13);
        source_identity = 0.28;
    } else if (atmosphere_type == 2u) {
        shallow = vec3(0.60, 0.22, 0.08);
        deep = vec3(0.20, 0.075, 0.045);
        source_identity = 0.28;
    } else if (atmosphere_type == 4u) {
        shallow = vec3(0.28, 0.29, 0.25);
        deep = vec3(0.13, 0.17, 0.16);
        source_identity = 0.35;
    } else {
        return source_water;
    }
    vec3 depth_color = mix(shallow, deep, smoothstep(120.0, 4800.0, depth));
    return mix(depth_color, source_water, source_identity);
}

// Couverture de neige/givre terrestre, distincte du masque ice_caps. Elle ne
// dépend pas du nom du biome : la température permet le gel, l'humidité fournit
// le condensat et l'altitude favorise l'accumulation et la conservation.
float landCryosphereCoverage(
    float temperature,
    float humidity,
    float relative_height,
    uint atmosphere_type
) {
    float coldness;
    if (atmosphere_type == 1u) {
        coldness = 1.0 - smoothstep(-55.0, -38.0, temperature);
    } else if (atmosphere_type == 3u) {
        coldness = 1.0 - smoothstep(-165.0, -125.0, temperature);
    } else if (atmosphere_type == 5u) {
        float water_frost = 1.0 - smoothstep(-58.0, -38.0, temperature);
        float carbon_frost = 1.0 - smoothstep(-105.0, -78.0, temperature);
        coldness = max(water_frost * 0.72, carbon_frost);
    } else {
        // Terran, volcanique et monde mort : le givre reste de l'eau et ne
        // peut apparaître que dans leurs régions localement froides.
        coldness = 1.0 - smoothstep(-5.0, 1.5, temperature);
    }

    float moisture_supply = smoothstep(0.035, 0.58, clamp(humidity, 0.0, 1.0));
    float height_retention = smoothstep(650.0, 3900.0, max(relative_height, 0.0));
    float orographic_supply = height_retention * mix(0.10, 0.62, moisture_supply);
    float dry_deposition = 0.0;
    if (atmosphere_type == 3u) {
        dry_deposition = coldness * 0.46; // dépôts dans les pièges froids
    } else if (atmosphere_type == 5u) {
        dry_deposition = coldness * 0.34; // givre polaire / CO2
    } else if (temperature < -14.0) {
        dry_deposition = 0.08;
    }

    float condensate_supply = clamp(
        moisture_supply * 0.82 + orographic_supply + dry_deposition,
        0.0,
        1.0
    );
    float retention = mix(0.72, 1.0, height_retention);
    return clamp(coldness * condensate_supply * retention, 0.0, 1.0);
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
    vec2 climate = imageLoad(climate_texture, pos).rg;
    float elevation = imageLoad(geo_texture, pos).r;
    float relative_height = elevation - params.sea_level;
    
    bool is_water = water.a > 0.0;  // L'eau a alpha > 0 dans water_colored
    bool has_surface_ice = ice.a > 0.025;
    bool is_river = (river_bid != 0xFFFFFFFFu) &&
        (flux >= params.river_threshold);
    
    // === STEP 1: Base physique + modulation écologique ===
    vec3 color = biome.rgb;
    vec3 vegetation_color = biome.rgb;
    if (biome_count > 0u && biome_index < biome_count) {
        vegetation_color = biomes[biome_index].color.rgb;
    }

    if (is_water) {
        color = planetaryWaterSurface(
            max(-relative_height, 0.0),
            water.rgb,
            params.atmosphere_type
        );
    } else if (biome_count > 0u && biome_index < biome_count) {
        float local_vegetation_capacity = biomeVegetationCapacity(biomes[biome_index]);
        float smoothed_vegetation_capacity = local_vegetation_capacity;
        vec3 land_material = smoothedBiomeMaterial(
            pos,
            w,
            h,
            vegetation_color,
            local_vegetation_capacity,
            smoothed_vegetation_capacity
        );
        // Les cartes rocheuses ont besoin de conserver une partie du matériau
        // local. Le lissage 7x7 seul effaçait les petites coulées, cratères et
        // bassins et donnait un aspect flou aux mondes non-Terran.
        float local_material_weight = 0.0;
        if (params.atmosphere_type == 1u) local_material_weight = 0.34;
        else if (params.atmosphere_type == 2u) local_material_weight = 0.46;
        else if (params.atmosphere_type == 3u) local_material_weight = 0.40;
        else if (params.atmosphere_type == 4u) local_material_weight = 0.40;
        land_material = mix(land_material, vegetation_color, local_material_weight);
        color = planetaryLandSurface(
            land_material,
            climate.r,
            climate.g,
            max(relative_height, 0.0),
            smoothed_vegetation_capacity,
            params.atmosphere_type
        );
    } else if (params.atmosphere_type == 0u) {
        // Conserver exactement le fallback historique du type par défaut.
        color = mix(
            terranLandHypsometry(max(relative_height, 0.0)),
            biome.rgb,
            0.55
        );
    } else {
        // Même fallback physique pour les autres types si aucun biome n'est
        // disponible : pas de retour au rendu plat par couleur brute.
        color = planetaryLandSurface(
            biome.rgb,
            climate.r,
            climate.g,
            max(relative_height, 0.0),
            1.0,
            params.atmosphere_type
        );
    }

    // Renforcer les détails géologiques des types signalés comme flous,
    // sans modifier le rendu Terran ni le rendu stérile déjà satisfaisant.
    if (!is_water && params.atmosphere_type >= 1u && params.atmosphere_type <= 4u) {
        float detail_strength = 0.052;
        if (params.atmosphere_type == 2u) detail_strength = 0.066;
        else if (params.atmosphere_type == 3u) detail_strength = 0.085;
        color = clamp(
            color + vec3(localTerrainDetail(pos, w, h) * detail_strength),
            vec3(0.0),
            vec3(1.0)
        );
    }
    
    // === STEP 2: Apply subtle, continuous terrain lighting ===
    float shading = calculateTopoShading(pos, w, h);
    
    // Réduire l'intensité du relief sur l'eau
    float effective_strength = params.relief_strength;
    if (is_water) {
        effective_strength *= params.water_relief_factor;  // Relief très atténué sur l'eau
    } else if (params.atmosphere_type == 1u) {
        effective_strength *= 1.10;
    } else if (params.atmosphere_type == 2u) {
        effective_strength *= 1.18;
    } else if (params.atmosphere_type == 3u) {
        effective_strength *= 1.28;
    } else if (params.atmosphere_type == 4u) {
        effective_strength *= 1.15;
    }
    
    // Une variation additive reste perceptible avec la même intensité sur une
    // forêt sombre, un désert clair ou de la roche grise.
    float relief_light = (shading - 0.5) * 2.0 * effective_strength;
    color = clamp(color + vec3(relief_light), vec3(0.0), vec3(1.0));
    
    // === STEP 3: Rivers overlay ===
    // Si un biome rivière est assigné, appliquer la colorisation dynamique
    // selon le type d'atmosphère de la planète
    if (is_river && river_bid < river_biome_count) {
        vec3 river_veg_color = river_biomes[river_bid].color.rgb;
        // Mélange adapté au type de planète (lave, acide, boue, eau...)
        color = getRiverBlendedColor(color, river_veg_color, params.atmosphere_type);
    }
    
    // === STEP 4: Land snow/frost from continuous physical conditions ===
    // This is deliberately separate from ice_caps, which remains water-only.
    if (!is_water) {
        float land_ice = landCryosphereCoverage(
            climate.r,
            climate.g,
            max(relative_height, 0.0),
            params.atmosphere_type
        );
        float land_ice_opacity = smoothstep(0.06, 0.88, land_ice) * 0.90;
        color = mix(
            color,
            getCryosphereColor(params.atmosphere_type),
            land_ice_opacity
        );
    }

    // === STEP 5: Water-only sea-ice overlay (highest priority) ===
    // Defensive is_water check prevents a stale or malformed ice texture from
    // ever painting an ice cap over land.
    if (has_surface_ice && is_water) {
        vec3 cryosphere_color = mix(
            getCryosphereColor(params.atmosphere_type),
            ice.rgb,
            0.78
        );
        float ice_opacity = smoothstep(0.025, 0.92, ice.a) * 0.84;
        color = mix(color, cryosphere_color, ice_opacity);
    }
    
    // === OUTPUT ===
    imageStore(final_map, pos, vec4(color, 1.0));
}
