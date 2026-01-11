#[compute]
#version 450

// ============================================================================
// RESOURCES SHADER - Génération de Gisements de Ressources Minérales
// ============================================================================
// Génère une carte encodant tous les types de ressources minérales.
// Chaque ressource a une probabilité, taille et couleur définie.
// Sortie : RGBA32F où R = resource_id (0-107), G = intensity, B = cluster_id, A = 1.0
// Les ressources ne se génèrent que sur terre (pas sous l'eau)
// SUPERPOSITION AUTORISÉE : Chaque ressource est générée indépendamment
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : Géologie (RGBA32F)
layout(set = 0, binding = 0) uniform texture2D geo_texture;
layout(set = 0, binding = 1) uniform sampler geo_sampler;

// Texture de sortie : Resources (RGBA32F) - R=resource_id, G=intensity, B=cluster_id, A=has_resource
layout(set = 0, binding = 2, rgba32f) uniform writeonly image2D resources_texture;

// Uniform Buffer avec paramètres
layout(set = 1, binding = 0, std140) uniform ResourcesParams {
    uint seed;
    uint width;
    uint height;
    float sea_level;
    float cylinder_radius;
    uint atmosphere_type;
    float global_richness;    // Multiplicateur global de ressources [0.5-2.0]
    float padding1;
} params;

// ============================================================================
// CONSTANTES : Données des ressources (depuis enum.gd - 116 ressources)
// ============================================================================

const int NUM_RESOURCES = 116;

// Probabilités relatives (depuis enum.gd)
// Organisées par catégorie pour correspondre à enum.gd
const float RESOURCE_PROBABILITIES[NUM_RESOURCES] = float[](
    // CAT 1: Ultra-abondants (6) - indices 0-5
    0.95, 0.85, 0.80, 0.70, 0.55, 0.50,
    // CAT 2: Très communs (6) - indices 6-11
    0.40, 0.35, 0.30, 0.28, 0.45, 0.42,
    // CAT 3: Communs (10) - indices 12-21
    0.22, 0.20, 0.18, 0.16, 0.15, 0.14, 0.13, 0.12, 0.35, 0.15,
    // CAT 4: Modérément rares (7) - indices 22-28
    0.08, 0.07, 0.06, 0.055, 0.05, 0.045, 0.09,
    // CAT 5: Rares (9) - indices 29-37
    0.035, 0.032, 0.030, 0.028, 0.026, 0.024, 0.022, 0.020, 0.018,
    // CAT 6: Très rares (7) - indices 38-44
    0.012, 0.010, 0.008, 0.007, 0.006, 0.005, 0.004,
    // CAT 7: Extrêmement rares (8) - indices 45-52
    0.003, 0.0025, 0.002, 0.0015, 0.001, 0.0008, 0.0006, 0.0004,
    // CAT 8: Terres rares (16) - indices 53-68
    0.015, 0.013, 0.011, 0.010, 0.008, 0.006, 0.005, 0.0045, 0.004, 0.003, 0.0025, 0.002, 0.0015, 0.0012, 0.0008, 0.007,
    // CAT 9: Hydrocarbures (7) - indices 69-75
    0.18, 0.20, 0.25, 0.15, 0.30, 0.12, 0.08,
    // CAT 10: Pierres précieuses (12) - indices 76-87
    0.0018, 0.0012, 0.0010, 0.0010, 0.0015, 0.0020, 0.0008, 0.0010, 0.0025, 0.0018, 0.0012, 0.0008,
    // CAT 11: Minéraux industriels (22) - indices 88-109
    0.65, 0.60, 0.45, 0.55, 0.40, 0.38, 0.32, 0.35, 0.30, 0.50, 0.28, 0.48, 0.75, 0.70, 0.42, 0.15, 0.18, 0.10, 0.12, 0.14, 0.20, 0.16,
    // CAT 12: Minéraux spéciaux (6) - indices 110-115
    0.008, 0.006, 0.002, 0.004, 0.05, 0.025
);

// Tailles moyennes des gisements (échelle 2048px)
const float RESOURCE_SIZES[NUM_RESOURCES] = float[](
    // CAT 1: Ultra-abondants (6)
    800.0, 600.0, 550.0, 500.0, 400.0, 380.0,
    // CAT 2: Très communs (6)
    350.0, 320.0, 280.0, 300.0, 600.0, 550.0,
    // CAT 3: Communs (10)
    200.0, 180.0, 160.0, 140.0, 130.0, 120.0, 110.0, 100.0, 400.0, 120.0,
    // CAT 4: Modérément rares (7)
    60.0, 55.0, 50.0, 45.0, 40.0, 35.0, 80.0,
    // CAT 5: Rares (9)
    30.0, 28.0, 25.0, 22.0, 20.0, 18.0, 16.0, 15.0, 12.0,
    // CAT 6: Très rares (7)
    10.0, 8.0, 6.0, 5.0, 4.0, 4.0, 3.0,
    // CAT 7: Extrêmement rares (8)
    6.0, 4.0, 3.0, 2.0, 2.0, 2.0, 2.0, 1.0,
    // CAT 8: Terres rares (16)
    25.0, 22.0, 20.0, 18.0, 15.0, 12.0, 10.0, 8.0, 7.0, 5.0, 4.0, 3.0, 2.0, 2.0, 1.0, 12.0,
    // CAT 9: Hydrocarbures (7)
    350.0, 320.0, 400.0, 300.0, 450.0, 280.0, 200.0,
    // CAT 10: Pierres précieuses (12)
    4.0, 3.0, 2.0, 2.0, 3.0, 4.0, 2.0, 2.0, 5.0, 3.0, 3.0, 2.0,
    // CAT 11: Minéraux industriels (22)
    700.0, 650.0, 450.0, 550.0, 400.0, 380.0, 320.0, 350.0, 400.0, 500.0, 300.0, 480.0, 800.0, 750.0, 420.0, 150.0, 180.0, 100.0, 120.0, 140.0, 200.0, 160.0,
    // CAT 12: Minéraux spéciaux (6)
    8.0, 6.0, 2.0, 4.0, 50.0, 30.0
);

// Types de ressources pour facteurs géologiques
// 0 = ubiquiste, 1 = sédimentaire, 2 = montagne, 3 = volcanique, 4 = plaine, 5 = côtier
const int RESOURCE_GEO_TYPE[NUM_RESOURCES] = int[](
    // CAT 1: Ultra-abondants (ubiquistes) (6)
    0, 0, 0, 0, 0, 0,
    // CAT 2: Très communs (6): Titane, Phosphate, Manganèse, Soufre, Charbon, Calcaire
    0, 1, 0, 3, 1, 1,
    // CAT 3: Communs (10): Baryum, Strontium, Zirconium, Vanadium, Chrome, Nickel, Zinc, Cuivre, Sel, Fluorine
    1, 1, 0, 2, 2, 2, 2, 2, 5, 0,
    // CAT 4: Modérément rares (7): Cobalt, Lithium, Niobium, Plomb, Bore, Thorium, Graphite
    2, 2, 2, 2, 2, 2, 0,
    // CAT 5: Rares (9): Étain, Béryllium, Arsenic, Germanium, Uranium, Molybdène, Tungstène, Antimoine, Tantale
    2, 2, 2, 2, 0, 2, 2, 2, 2,
    // CAT 6: Très rares (7): Argent, Cadmium, Mercure, Sélénium, Indium, Bismuth, Tellure
    2, 0, 3, 3, 2, 2, 3,
    // CAT 7: Extrêmement rares (8): Or, Platine, Palladium, Rhodium, Iridium, Osmium, Ruthénium, Rhénium
    2, 2, 2, 2, 2, 2, 2, 2,
    // CAT 8: Terres rares (16)
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    // CAT 9: Hydrocarbures (7): Pétrole, Gaz naturel, Lignite, Anthracite, Tourbe, Schiste, Méthane
    1, 1, 1, 1, 1, 1, 5,
    // CAT 10: Pierres précieuses (12)
    2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2,
    // CAT 11: Minéraux industriels (22): Quartz, Feldspath, Mica, Argile, Kaolin, Gypse, Talc, Bauxite, Marbre, Granit, Ardoise, Grès, Sable, Gravier, Basalte, Obsidienne, Pierre ponce, Amiante, Vermiculite, Perlite, Bentonite, Zéolite
    0, 0, 0, 4, 4, 1, 4, 1, 2, 0, 2, 1, 4, 4, 3, 3, 3, 2, 2, 3, 1, 2,
    // CAT 12: Minéraux spéciaux (6): Hafnium, Gallium, Césium, Rubidium, Hélium, Terres rares mélangées
    2, 2, 1, 2, 1, 2
);

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// FONCTIONS DE HASH ET BRUIT
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

uint hash2(uint x, uint y) {
    return hash(x ^ hash(y));
}

uint hash3(uint x, uint y, uint z) {
    return hash(x ^ hash(y ^ hash(z)));
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
    
    float c000 = rand(hash3(ix, iy, iz));
    float c100 = rand(hash3(ix+1u, iy, iz));
    float c010 = rand(hash3(ix, iy+1u, iz));
    float c110 = rand(hash3(ix+1u, iy+1u, iz));
    float c001 = rand(hash3(ix, iy, iz+1u));
    float c101 = rand(hash3(ix+1u, iy, iz+1u));
    float c011 = rand(hash3(ix, iy+1u, iz+1u));
    float c111 = rand(hash3(ix+1u, iy+1u, iz+1u));
    
    float x00 = mix(c000, c100, u.x);
    float x10 = mix(c010, c110, u.x);
    float x01 = mix(c001, c101, u.x);
    float x11 = mix(c011, c111, u.x);
    
    float xy0 = mix(x00, x10, u.y);
    float xy1 = mix(x01, x11, u.y);
    
    return mix(xy0, xy1, u.z);
}

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

// Cellular noise pour distribution en clusters
float cellularNoise(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist = 1000.0;
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                
                const float BIG_OFFSET = 10000.0;
                ivec3 cell = ivec3(i + neighbor + BIG_OFFSET);
                uint h = hash3(uint(cell.x) + seed_offset, uint(cell.y), uint(cell.z));
                
                vec3 point = neighbor + vec3(rand(h), rand(hash(h + 1u)), rand(hash(h + 2u))) - f;
                float dist = length(point);
                
                minDist = min(minDist, dist);
            }
        }
    }
    
    return minDist;
}

// Coordonnées cylindriques pour seamless horizontal
vec3 getCylindricalCoords(ivec2 pixel) {
    float angle = (float(pixel.x) / float(params.width)) * TAU;
    float cx = cos(angle) * params.cylinder_radius;
    float cz = sin(angle) * params.cylinder_radius;
    float cy = (float(pixel.y) / float(params.height) - 0.5) * params.cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// FACTEURS GÉOLOGIQUES PAR TYPE DE RESSOURCE
// ============================================================================

// Facteur d'altitude basé sur le type géologique
// 0 = ubiquiste, 1 = sédimentaire, 2 = montagne, 3 = volcanique, 4 = plaine, 5 = côtier
float getElevationFactor(int resource_id, float elevation, float sea_level) {
    float rel_elev = elevation - sea_level;
    
    // Utiliser le type géologique au lieu de l'ID directement
    int geo_type = RESOURCE_GEO_TYPE[resource_id];
    
    // Type 0: Ubiquiste - présent partout
    if (geo_type == 0) {
        return mix(0.9, 1.0, smoothstep(-500.0, 2000.0, rel_elev));
    }
    // Type 1: Sédimentaire - bassins et zones basses
    else if (geo_type == 1) {
        return mix(1.0, 0.6, smoothstep(0.0, 1000.0, rel_elev));
    }
    // Type 2: Montagne/métamorphique - haute altitude
    else if (geo_type == 2) {
        return mix(0.6, 1.0, smoothstep(200.0, 2500.0, rel_elev));
    }
    // Type 3: Volcanique - zones volcaniques (altitude moyenne-haute)
    else if (geo_type == 3) {
        float mid = smoothstep(500.0, 1500.0, rel_elev);
        float high = 1.0 - smoothstep(3000.0, 5000.0, rel_elev);
        return mid * high;
    }
    // Type 4: Plaine - basse altitude, zones plates
    else if (geo_type == 4) {
        return mix(1.0, 0.5, smoothstep(0.0, 800.0, rel_elev));
    }
    // Type 5: Côtier - près du niveau de la mer
    else if (geo_type == 5) {
        float dist_to_sea = abs(rel_elev);
        return 1.0 - smoothstep(0.0, 500.0, dist_to_sea);
    }
    
    return 0.9; // Base élevée par défaut
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire les données géologiques
    vec2 uv = (vec2(pixel) + 0.5) / vec2(float(params.width), float(params.height));
    vec4 geo_data = texture(sampler2D(geo_texture, geo_sampler), uv);
    
    float elevation = geo_data.r;
    float water_height = geo_data.a;
    
    // Pas de ressources sous l'eau
    if (water_height > 0.5) {
        imageStore(resources_texture, pixel, vec4(-1.0, 0.0, 0.0, 0.0));
        return;
    }
    
    // Coordonnées cylindriques
    vec3 coords = getCylindricalCoords(pixel);
    float noise_scale = 4.0 / params.cylinder_radius;
    
    // Variables pour stocker la meilleure ressource trouvée
    float best_intensity = 0.0;
    int best_resource_id = -1;
    float best_cluster_id = 0.0;
    
    // Calculer la somme des probabilités pour normalisation
    float total_prob = 0.0;
    for (int i = 0; i < NUM_RESOURCES; i++) {
        if (i != 69) { // Skip pétrole (indice 69 - géré séparément)
            total_prob += RESOURCE_PROBABILITIES[i];
        }
    }
    
    // Hash de base pour ce pixel
    uint pixel_hash = hash2(uint(pixel.x) + params.seed, uint(pixel.y));
    float pixel_rand = rand(pixel_hash);
    
    // Déterminer le type de ressource dominant pour ce pixel
    // basé sur les probabilités cumulatives
    float cumulative = 0.0;
    int selected_resource = -1;
    
    // Bruit de base pour variation spatiale - échelle plus grande pour zones plus larges
    float base_noise = fbm(coords * noise_scale * 0.3, 4, 0.5, 2.0, params.seed);
    
    // Domain warping pour éviter les patterns rectilignes
    vec3 warp = vec3(
        fbm(coords * noise_scale * 0.2 + vec3(50.0, 0.0, 0.0), 3, 0.5, 2.0, params.seed + 100000u),
        fbm(coords * noise_scale * 0.2 + vec3(0.0, 50.0, 0.0), 3, 0.5, 2.0, params.seed + 200000u),
        fbm(coords * noise_scale * 0.2 + vec3(0.0, 0.0, 50.0), 3, 0.5, 2.0, params.seed + 300000u)
    ) * 0.4;
    
    vec3 warped_coords = coords + warp;
    
    // Tester chaque ressource
    for (int i = 0; i < NUM_RESOURCES; i++) {
        // Skip pétrole (indice 69 - géré par oil.glsl)
        if (i == 69) continue;
        
        float prob = RESOURCE_PROBABILITIES[i];
        float size = RESOURCE_SIZES[i] * (float(params.width) / 2048.0); // Ajuster à la résolution
        
        // Facteur géologique basé sur l'altitude
        float geo_factor = getElevationFactor(i, elevation, params.sea_level);
        
        // Si le facteur géologique est trop bas, skip
        if (geo_factor < 0.1) continue;
        
        // Bruit spécifique à cette ressource
        uint resource_seed = params.seed + uint(i) * 50000u;
        
        // Échelle basée sur la taille du gisement - zones plus larges
        float resource_scale = noise_scale * (60.0 / max(size, 1.0));
        
        // Cellular noise pour créer des clusters distincts
        float cell_dist = cellularNoise(warped_coords * resource_scale, resource_seed);
        
        // Transformer en présence de ressource (centres de cellules = ressources)
        // Seuil bas pour avoir de grandes zones
        float presence = 1.0 - smoothstep(0.0, 0.5, cell_dist);
        
        // Ajouter variation avec fBm - échelle plus grande
        float detail = fbm(warped_coords * resource_scale * 1.2, 3, 0.5, 2.0, resource_seed + 10000u);
        presence *= mix(0.6, 1.0, detail);
        
        // Appliquer les facteurs
        presence *= geo_factor;
        presence *= params.global_richness;
        
        // Seuil très bas pour avoir beaucoup de ressources
        float base_threshold = 0.15;
        
        // Intensité brute avec grande plage
        float raw_intensity = smoothstep(base_threshold, 0.7, presence);
        
        // Moduler par la probabilité : multiplication très douce
        float probability_factor = pow(prob * 4.0, 0.25); // Très peu de réduction
        probability_factor = clamp(probability_factor, 0.5, 1.0);
        raw_intensity *= probability_factor;
        
        // Si l'intensité dépasse le seuil minimal ET est meilleure que l'actuelle
        if (raw_intensity > 0.02 && raw_intensity > best_intensity) {
            best_intensity = raw_intensity;
            best_resource_id = i;
            best_cluster_id = cell_dist * 1000.0; // ID unique du cluster
        }
    }
    
    // Écrire le résultat
    if (best_resource_id >= 0) {
        // R = resource_id, G = intensity (0-1), B = cluster_id, A = 1.0 (has resource)
        float intensity = smoothstep(0.0, 1.0, best_intensity);
        imageStore(resources_texture, pixel, vec4(
            float(best_resource_id),
            intensity,
            best_cluster_id,
            1.0
        ));
    } else {
        // Pas de ressource : -1 en R, A = 0
        imageStore(resources_texture, pixel, vec4(-1.0, 0.0, 0.0, 0.0));
    }
}
