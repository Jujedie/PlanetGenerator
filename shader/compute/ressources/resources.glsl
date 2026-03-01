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
// CONSTANTES : Données des ressources (depuis enum.gd - 115 ressources)
// ============================================================================

const int NUM_RESOURCES = 115;

// Probabilités relatives (depuis enum.gd)
// Organisées par catégorie pour correspondre à enum.gd
const float RESOURCE_PROBABILITIES[NUM_RESOURCES] = float[](
    // CAT 1: Ultra-abondants (6) - indices 0-5
    27.7, 8.1, 5.0, 3.6, 2.1, 2.0,
    // CAT 2: Très communs (6) - indices 6-11
    0.56, 0.1, 0.1, 0.1, 0.08, 0.08,
    // CAT 3: Communs (10) - indices 12-21
    0.04, 0.04, 0.02, 0.02, 0.02, 0.01, 0.01, 0.01, 0.01, 0.01,
    // CAT 4: Modérément rares (7) - indices 22-28
    0.002, 0.002, 0.002, 0.002, 0.001, 0.001, 0.001,
    // CAT 5: Rares (9) - indices 29-37
    0.0002, 0.0002, 0.0002, 0.0002, 0.0002, 0.0002, 0.0002, 0.00005, 0.00005,
    // CAT 6: Très rares (7) - indices 38-44
    0.000007, 0.000005, 0.000005, 0.000005, 0.000001, 0.000001, 0.000001,
    // CAT 7: Extrêmement rares (8) - indices 45-52
    0.0000004, 0.0000001, 0.0000001, 0.0000001, 0.0000001, 0.0000001, 0.0000001, 0.0000001,
    // CAT 8: Terres rares (16) - indices 53-68
    0.006, 0.003, 0.003, 0.0005, 0.0005, 0.0005, 0.0005, 0.0005, 0.0005, 0.0001, 0.0001, 0.0001, 0.0001, 0.0001, 0.0001, 0.0001,
    // CAT 9: Hydrocarbures (6) - indices 69-74 (pétrole retiré - géré par petrole.glsl)
    0.5, 0.5, 0.5, 1.0, 1.0, 0.1,
    // CAT 10: Pierres précieuses (12) - indices 75-86
    0.001, 0.001, 0.001, 0.001, 0.01, 0.5, 0.01, 0.01, 0.5, 0.01, 0.01, 0.01,
    // CAT 11: Minéraux industriels (22) - indices 87-108
    5.0, 5.0, 5.0, 15.0, 5.0, 5.0, 0.5, 10.0, 2.0, 10.0, 2.0, 10.0, 15.0, 15.0, 10.0, 2.0, 2.0, 0.5, 0.5, 0.5, 0.5, 0.5,
    // CAT 12: Minéraux spéciaux (6) - indices 109-114
    0.0003, 0.0019, 0.0003, 0.009, 0.0000008, 0.01
);

// Tailles moyennes des gisements (échelle 2048px)
const float RESOURCE_SIZES[NUM_RESOURCES] = float[](
    // CAT 1: Ultra-abondants (6)
    1000.0, 800.0, 700.0, 650.0, 550.0, 500.0,
    // CAT 2: Très communs (6)
    450.0, 400.0, 380.0, 400.0, 700.0, 700.0,
    // CAT 3: Communs (10)
    280.0, 260.0, 220.0, 200.0, 190.0, 170.0, 160.0, 150.0, 500.0, 180.0,
    // CAT 4: Modérément rares (7)
    100.0, 90.0, 85.0, 80.0, 70.0, 65.0, 120.0,
    // CAT 5: Rares (9)
    50.0, 48.0, 45.0, 42.0, 40.0, 38.0, 35.0, 30.0, 28.0,
    // CAT 6: Très rares (7)
    20.0, 18.0, 16.0, 14.0, 12.0, 12.0, 10.0,
    // CAT 7: Extrêmement rares (8)
    15.0, 10.0, 10.0, 8.0, 8.0, 8.0, 8.0, 6.0,
    // CAT 8: Terres rares (16)
    40.0, 35.0, 35.0, 28.0, 26.0, 24.0, 22.0, 20.0, 18.0, 14.0, 12.0, 10.0, 8.0, 8.0, 6.0, 20.0,
    // CAT 9: Hydrocarbures (6) - pétrole retiré
    450.0, 500.0, 420.0, 550.0, 400.0, 300.0,
    // CAT 10: Pierres précieuses (12)
    12.0, 10.0, 10.0, 10.0, 18.0, 50.0, 15.0, 15.0, 55.0, 18.0, 16.0, 14.0,
    // CAT 11: Minéraux industriels (22)
    900.0, 850.0, 700.0, 1000.0, 650.0, 600.0, 400.0, 550.0, 600.0, 800.0, 500.0, 700.0, 1000.0, 950.0, 700.0, 250.0, 280.0, 180.0, 200.0, 220.0, 300.0, 250.0,
    // CAT 12: Minéraux spéciaux (6)
    20.0, 25.0, 15.0, 35.0, 80.0, 60.0
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
    // CAT 9: Hydrocarbures (6): Gaz naturel, Lignite, Anthracite, Tourbe, Schiste, Méthane (pétrole retiré)
    1, 1, 1, 1, 1, 5,
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
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(params.height) - 0.5) * params.cylinder_radius * PI;
    return vec3(cx, cy, cz);
}

// ============================================================================
// FACTEURS GÉOLOGIQUES PAR TYPE DE RESSOURCE
// ============================================================================

// Facteur d'altitude basé sur le type géologique
// 0 = ubiquiste, 1 = sédimentaire, 2 = montagne, 3 = volcanique, 4 = plaine, 5 = côtier
float getElevationFactor_type(int geo_type, float elevation, float sea_level) {
    float rel_elev = elevation - sea_level;
    
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
    
    // Coordonnées cylindriques
    vec3 coords = getCylindricalCoords(pixel);
    float noise_scale = 4.0 / params.cylinder_radius;
    
    // Domain warping commun (calculé une seule fois)
    vec3 warp = vec3(
        fbm(coords * noise_scale * 0.2 + vec3(50.0, 0.0, 0.0), 3, 0.5, 2.0, params.seed + 100000u),
        fbm(coords * noise_scale * 0.2 + vec3(0.0, 50.0, 0.0), 3, 0.5, 2.0, params.seed + 200000u),
        fbm(coords * noise_scale * 0.2 + vec3(0.0, 0.0, 50.0), 3, 0.5, 2.0, params.seed + 300000u)
    ) * 0.4;
    
    vec3 warped_coords = coords + warp;
    
    // === ABONDANCE RÉGIONALE ===
    // Pour chaque ressource, un bruit basse fréquence crée des zones
    // plus ou moins riches — variation douce, jamais binaire (plus de tout-ou-rien).
    
    // Pré-calculer le facteur géologique par type (0-5) pour éviter
    // de recalculer getElevationFactor pour chaque ressource
    float geo_factors[6];
    geo_factors[0] = getElevationFactor_type(0, elevation, params.sea_level);
    geo_factors[1] = getElevationFactor_type(1, elevation, params.sea_level);
    geo_factors[2] = getElevationFactor_type(2, elevation, params.sea_level);
    geo_factors[3] = getElevationFactor_type(3, elevation, params.sea_level);
    geo_factors[4] = getElevationFactor_type(4, elevation, params.sea_level);
    geo_factors[5] = getElevationFactor_type(5, elevation, params.sea_level);
    
    // Variables pour stocker la meilleure ressource trouvée
    float best_intensity = 0.0;
    int best_resource_id = -1;
    float best_cluster_id = 0.0;
    
    // === Boucle sur toutes les ressources ===
    for (int i = 0; i < NUM_RESOURCES; i++) {
        float prob = RESOURCE_PROBABILITIES[i];
        
        // Facteur géologique (lookup pré-calculé)
        int geo_type = RESOURCE_GEO_TYPE[i];
        float geo_factor = geo_factors[geo_type];
        if (geo_factor < 0.05) continue;
        
        uint resource_seed = params.seed + uint(i) * 50000u;
        
        // === ABONDANCE RÉGIONALE par ressource ===
        // Bruit très basse fréquence → zones riches/pauvres à l'échelle continentale
        // Chaque ressource a son propre motif régional (seed unique)
        float regional = fbm(warped_coords * noise_scale * 0.08, 2, 0.5, 2.0, resource_seed + 80000u);
        
        // La probabilité contrôle l'étendue des zones riches :
        //   Commun (prob élevée) → seuil bas, zones riches partout
        //   Rare (prob faible) → seuil haut, zones riches limitées
        float prob_norm = clamp((log2(max(prob, 1e-8)) + 27.0) / 27.0, 0.0, 1.0);
        float regional_center = mix(0.70, 0.25, prob_norm);
        float regional_factor = smoothstep(regional_center - 0.15, regional_center + 0.15, regional);
        
        // GARANTIE : plancher minimal pour que la ressource existe toujours
        regional_factor = max(regional_factor, mix(0.05, 0.15, prob_norm));
        
        // Early-out si la combinaison géo × régionale est trop faible
        if (regional_factor * geo_factor < 0.02) continue;
        
        // === TAILLE DES DÉPÔTS (réduite + variée) ===
        float base_size = RESOURCE_SIZES[i] * (float(params.width) / 2048.0);
        // Plafonner les grandes tailles pour éviter les blobs uniformes
        float size = min(base_size, 400.0) * mix(0.6, 1.0, rand(hash(resource_seed + 999u)));
        float resource_scale = noise_scale * (60.0 / max(size, 1.0));
        
        // === DÉPÔTS PRINCIPAUX (clusters) ===
        float cell_dist_main = cellularNoise(warped_coords * resource_scale, resource_seed);
        float presence_main = 1.0 - smoothstep(0.0, 0.45, cell_dist_main);
        
        float presence = presence_main;
        
        // === FILONS SECONDAIRES (plus petits, plus nombreux) ===
        // Seulement calculé hors des dépôts principaux pour économiser du calcul
        if (presence < 0.15) {
            float vein_scale = resource_scale * 3.0;
            float cell_dist_vein = cellularNoise(warped_coords * vein_scale, resource_seed + 30000u);
            float presence_vein = (1.0 - smoothstep(0.0, 0.30, cell_dist_vein)) * 0.45;
            presence = max(presence, presence_vein);
        }
        
        if (presence < 0.03) continue;
        
        // Variation de détail (fBm à 3 octaves)
        float detail = fbm(warped_coords * resource_scale * 1.2, 3, 0.5, 2.0, resource_seed + 10000u);
        presence *= mix(0.5, 1.0, detail);
        
        // Appliquer facteurs
        presence *= geo_factor;
        presence *= regional_factor;
        presence *= params.global_richness;
        
        // Intensité finale
        float raw_intensity = smoothstep(0.02, 0.55, presence);
        
        // La probabilité module l'intensité maximale, PAS la présence
        // Rares = dépôts moins concentrés, pas absents
        float prob_factor = pow(clamp(prob * 10.0, 0.001, 1.0), 0.12);
        prob_factor = clamp(prob_factor, 0.35, 1.0);
        raw_intensity *= prob_factor;
        
        if (raw_intensity > 0.01 && raw_intensity > best_intensity) {
            best_intensity = raw_intensity;
            best_resource_id = i;
            best_cluster_id = cell_dist_main * 1000.0;
        }
    }
    
    // Écrire le résultat
    if (best_resource_id >= 0) {
        // === Ajout de bruit à l'intensité pour variation non-uniforme ===
        // Bruit haute fréquence pour casser les zones plates
        uint res_seed = params.seed + uint(best_resource_id) * 50000u;
        float hf_noise = fbm(warped_coords * noise_scale * 8.0, 3, 0.6, 2.0, res_seed + 20000u);
        // Bruit à grain fin (hash par pixel pour micro-variation)
        float pixel_noise = rand(hash2(uint(pixel.x) + res_seed, uint(pixel.y) + 77u));
        
        // Combiner : variation organique + micro-grain
        float noisy_intensity = best_intensity * mix(0.4, 1.0, hf_noise) * mix(0.85, 1.0, pixel_noise);
        
        // Clamp et smooth
        noisy_intensity = clamp(noisy_intensity, 0.0, 1.0);
        
        // Alpha variable basée sur l'intensité (pas toujours 1.0)
        // Centre des dépôts = plus opaque, bords = plus transparent
        float alpha = smoothstep(0.0, 0.3, noisy_intensity);
        // Ajouter du bruit à l'alpha aussi
        alpha *= mix(0.5, 1.0, hf_noise);
        alpha = clamp(alpha, 0.0, 1.0);
        
        imageStore(resources_texture, pixel, vec4(
            float(best_resource_id),
            noisy_intensity,
            best_cluster_id,
            alpha
        ));
    } else {
        imageStore(resources_texture, pixel, vec4(-1.0, 0.0, 0.0, 0.0));
    }
}
