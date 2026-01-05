#[compute]
#version 450

// ============================================================================
// BASE ELEVATION SHADER - Étape 0 : Génération Topographique de Base
// ============================================================================
// Génère une heightmap initiale avec :
// - Bruit fBm multi-octaves (relief général)
// - Plaques tectoniques (Voronoi) avec frottement aux frontières
// - Plateaux sur les plaques continentales
// - Seamless sur l'axe X (projection équirectangulaire)
//
// Entrées (UBO) :
// - seed           : Graine de génération
// - width, height  : Dimensions de la texture
// - elevation_modifier : Amplificateur d'altitude
// - sea_level      : Niveau de la mer
// - cylinder_radius: Rayon du cylindre pour le bruit (width / (2*PI))
//
// Sorties :
// - GeoTexture (RGBA32F) : R=height, G=bedrock, B=sediment, A=water_height
// - PlatesTexture (RGBA32F) : R=plate_id, G=border_dist, B=plate_elevation, A=is_oceanic
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture de sortie : GeoTexture (état géophysique dense)
// R = height (mètres)
// G = bedrock (résistance 0-1)
// B = sediment (épaisseur sédiments, 0 au départ)
// A = water height (colonne d'eau)
layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D geo_texture;

// Texture de sortie : PlatesTexture (plaques tectoniques)
// R = plate_id (numéro de plaque 0-11)
// G = velocity_x (composante X de la vélocité de la plaque)
// B = velocity_y (composante Y de la vélocité de la plaque)  
// A = convergence_type (-1=divergence, 0=transformante, +1=convergence)
layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D plates_texture;

// Uniform Buffer : Paramètres globaux de génération
layout(set = 1, binding = 0, std140) uniform GenerationParams {
    uint seed;              // Graine de génération
    uint width;             // Largeur texture
    uint height;            // Hauteur texture
    float elevation_modifier; // Multiplicateur altitude (terrain_scale)
    float sea_level;        // Niveau de la mer
    float cylinder_radius;  // Rayon cylindre = width / (2*PI)
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const int NUM_PLATES = 12;  // Nombre de plaques tectoniques

// ============================================================================
// FONCTIONS UTILITAIRES - Bruit (Simplex/Value Noise)
// ============================================================================

// Hash function pour générer du pseudo-aléatoire reproductible
uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

uint hash2(uvec2 v) {
    return hash(v.x ^ hash(v.y));
}

uint hash3(uvec3 v) {
    return hash(v.x ^ hash(v.y ^ hash(v.z)));
}

// Valeur aléatoire normalisée [0, 1] à partir d'un hash
float rand(uint h) {
    return float(h) / 4294967295.0;
}

// Deux valeurs aléatoires [0, 1] pour les centres de plaques
vec2 rand2(uint h) {
    return vec2(rand(h), rand(hash(h + 1u)));
}

// Gradient 3D pour Simplex noise
vec3 grad3(uint h) {
    uint idx = h & 15u;
    float u = idx < 8u ? 1.0 : -1.0;
    float v = (idx & 4u) != 0u ? 1.0 : -1.0;
    float w = (idx & 2u) != 0u ? 1.0 : -1.0;
    return vec3(u, v, w);
}

// Fonction de lissage (smoothstep quintic pour de meilleurs dérivées)
float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Value Noise 3D - Version corrigée pour coordonnées négatives
float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Utiliser fade pour le lissage
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    // CORRECTION: Utiliser mod pour éviter les coordonnées négatives
    // On ajoute un grand offset pour garantir des valeurs positives
    const float BIG_OFFSET = 10000.0;
    ivec3 ii = ivec3(i + BIG_OFFSET);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    // Échantillonner 8 coins du cube avec hash robuste
    float c000 = rand(hash(ix ^ hash(iy ^ hash(iz))));
    float c100 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz))));
    float c010 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz))));
    float c110 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz))));
    float c001 = rand(hash(ix ^ hash(iy ^ hash(iz+1u))));
    float c101 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz+1u))));
    float c011 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz+1u))));
    float c111 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz+1u))));
    
    // Interpolation trilinéaire
    float x00 = mix(c000, c100, u.x);
    float x10 = mix(c010, c110, u.x);
    float x01 = mix(c001, c101, u.x);
    float x11 = mix(c011, c111, u.x);
    
    float xy0 = mix(x00, x10, u.y);
    float xy1 = mix(x01, x11, u.y);
    
    return mix(xy0, xy1, u.z) * 2.0 - 1.0; // Remap [-1, 1]
}

// Simplex Noise 3D (version simplifiée pour GPU)
// Basé sur l'implémentation de Stefan Gustavson
const float F3 = 0.333333333;
const float G3 = 0.166666667;

float simplexNoise3D(vec3 p, uint seed_offset) {
    // Skew
    float s = (p.x + p.y + p.z) * F3;
    vec3 i = floor(p + s);
    float t = (i.x + i.y + i.z) * G3;
    vec3 x0 = p - (i - t);
    
    // Déterminer quel simplexe
    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);
    
    vec3 x1 = x0 - i1 + G3;
    vec3 x2 = x0 - i2 + 2.0 * G3;
    vec3 x3 = x0 - 1.0 + 3.0 * G3;
    
    // CORRECTION: Offset pour éviter les négatifs
    const float BIG_OFFSET = 10000.0;
    ivec3 ii = ivec3(i + BIG_OFFSET);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    vec4 w;
    w.x = 0.6 - dot(x0, x0);
    w.y = 0.6 - dot(x1, x1);
    w.z = 0.6 - dot(x2, x2);
    w.w = 0.6 - dot(x3, x3);
    
    w = max(w, 0.0);
    vec4 w4 = w * w * w * w;
    
    // Gradients avec hash corrigé
    vec3 g0 = grad3(hash(ix ^ hash(iy ^ hash(iz))));
    ivec3 ii1 = ivec3(i + i1 + BIG_OFFSET);
    vec3 g1 = grad3(hash(uint(ii1.x) + seed_offset ^ hash(uint(ii1.y) ^ hash(uint(ii1.z)))));
    ivec3 ii2 = ivec3(i + i2 + BIG_OFFSET);
    vec3 g2 = grad3(hash(uint(ii2.x) + seed_offset ^ hash(uint(ii2.y) ^ hash(uint(ii2.z)))));
    ivec3 ii3 = ivec3(i + vec3(1.0) + BIG_OFFSET);
    vec3 g3 = grad3(hash(uint(ii3.x) + seed_offset ^ hash(uint(ii3.y) ^ hash(uint(ii3.z)))));
    
    vec4 n = vec4(dot(g0, x0), dot(g1, x1), dot(g2, x2), dot(g3, x3));
    
    return 32.0 * dot(w4, n);
}

// ============================================================================
// FONCTIONS fBm (Fractional Brownian Motion)
// ============================================================================

// fBm classique avec paramètres configurables
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

// fBm avec Simplex noise
float fbmSimplex(vec3 p, int octaves, float gain, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * simplexNoise3D(p * frequency, seed_offset + uint(i) * 1000u);
        maxValue += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value / maxValue;
}

// Ridged Multifractal (pour les crêtes de montagnes)
float ridgedMultifractal(vec3 p, int octaves, float gain, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float weight = 1.0;
    
    for (int i = 0; i < octaves; i++) {
        float signal = simplexNoise3D(p * frequency, seed_offset + uint(i) * 1000u);
        signal = 1.0 - abs(signal); // Créer des crêtes
        signal = signal * signal;   // Accentuer
        signal *= weight;
        weight = clamp(signal * 2.0, 0.0, 1.0);
        
        value += signal * amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value;
}

// ============================================================================
// CONVERSION COORDONNÉES - Équirectangulaire vers Cylindrique
// ============================================================================

// Convertit les coordonnées pixel (x, y) en coordonnées 3D cylindriques
// CORRIGÉ : Y normalisé pour bruit isotrope (même échelle que X/Z)
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    // Angle de longitude [0, 2π]
    float angle = (float(pixel.x) / float(w)) * TAU;
    
    // Coordonnées cylindriques avec Y NORMALISÉ
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    // Y centré [-radius, +radius] pour isotropie du bruit
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    
    return vec3(cx, cy, cz);
}

// ============================================================================
// CONVERSION COORDONNÉES - UV vers Sphère (pour Voronoi cohérent)
// ============================================================================

// Convertit des coordonnées UV [0,1]x[0,1] en point 3D sur sphère unitaire
vec3 uvToSphere(vec2 uv) {
    float lon = uv.x * TAU;              // Longitude [0, 2π]
    float lat = (uv.y - 0.5) * PI;       // Latitude [-π/2, π/2]
    
    return vec3(
        cos(lat) * cos(lon),
        sin(lat),
        cos(lat) * sin(lon)
    );
}

// Distance géodésique (arc de grand cercle) entre deux points sur la sphère
float geodesicDistance(vec3 p1, vec3 p2) {
    float cosAngle = clamp(dot(p1, p2), -1.0, 1.0);
    return acos(cosAngle);  // Retourne angle en radians [0, π]
}

// ============================================================================
// PLAQUES TECTONIQUES (Voronoi Sphérique avec Domain Warping)
// ============================================================================

// Génère les centres des plaques tectoniques en coordonnées UV [0,1]
vec2 getPlateCenter(int plateId, uint seed) {
    uint h = hash(uint(plateId) + seed * 7919u);
    vec2 center = rand2(h);
    return center;
}

// Génère la vélocité d'une plaque (direction + magnitude)
// Retourne vec2 en coordonnées tangentielles (vx, vy) normalisé
vec2 getPlateVelocity(int plateId, uint seed) {
    uint h1 = hash(uint(plateId) + seed * 4421u);
    uint h2 = hash(uint(plateId) + seed * 6619u);
    
    // Angle de mouvement [0, 2π]
    float angle = rand(h1) * TAU;
    // Vitesse normalisée [0.3, 1.0] - évite les plaques immobiles
    float speed = 0.3 + rand(h2) * 0.7;
    
    return vec2(cos(angle), sin(angle)) * speed;
}

// Détermine si un point est océanique basé sur le bruit continental
// Indépendant des plaques - permet zones mixtes dans une même plaque
bool isLocallyOceanic(vec3 coords, float cylinder_radius, uint seed) {
    // Bruit continental à grande échelle
    float continental_freq = 0.8 / cylinder_radius;
    float continentalNoise = fbm(coords * continental_freq, 6, 0.6, 2.0, seed + 77777u);
    // Seuil : ~60% océan, ~40% continent
    return continentalNoise < 0.1;
}

// Distance cyclique sur X (wrap horizontal pour continuité)
float cyclicDistanceX(float x1, float x2, float width) {
    float dx = abs(x1 - x2);
    return min(dx, width - dx);
}

// Bruit 2D simple pour perturber les coordonnées Voronoi
// Version corrigée avec offset pour éviter les négatifs
vec2 noise2D(vec2 p, uint seed) {
    // Offset pour garantir des valeurs positives
    vec2 pp = p + vec2(1000.0);
    vec2 i = floor(pp);
    vec2 f = fract(pp);
    
    // Smoothstep pour interpolation
    vec2 u = f * f * (3.0 - 2.0 * f);
    
    // Convertir en uint de façon sûre
    uint ix = uint(i.x);
    uint iy = uint(i.y);
    
    // 4 coins avec hash robuste
    float a = rand(hash(ix + seed ^ hash(iy)));
    float b = rand(hash(ix + 1u + seed ^ hash(iy)));
    float c = rand(hash(ix + seed ^ hash(iy + 1u)));
    float d = rand(hash(ix + 1u + seed ^ hash(iy + 1u)));
    
    float nx = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    
    // Deuxième composante avec offset
    uint seed2 = seed + 1000u;
    float a2 = rand(hash(ix + seed2 ^ hash(iy)));
    float b2 = rand(hash(ix + 1u + seed2 ^ hash(iy)));
    float c2 = rand(hash(ix + seed2 ^ hash(iy + 1u)));
    float d2 = rand(hash(ix + 1u + seed2 ^ hash(iy + 1u)));
    
    float ny = mix(mix(a2, b2, u.x), mix(c2, d2, u.x), u.y);
    
    return vec2(nx, ny) * 2.0 - 1.0;  // [-1, 1]
}

// Perturbation multi-octaves pour les bordures de plaques (Domain Warping)
// Appliqué en espace sphérique pour cohérence avec la projection
vec2 domainWarp(vec2 uv, uint seed) {
    vec2 offset = vec2(0.0);
    float amplitude = 0.05;   // Force de la perturbation
    float frequency = 4.0;    // Fréquence de base
    
    // 4 octaves pour bordures organiques et fractales
    for (int i = 0; i < 4; i++) {
        offset += noise2D(uv * frequency, seed + uint(i) * 5000u) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return offset;
}

// Structure pour stocker les infos de frontière
struct PlateInfo {
    int plateId;
    int secondPlateId;
    float borderDist;
    float borderStrength;
    vec2 velocity1;
    vec2 velocity2;
    float convergence;  // >0 = convergence, <0 = divergence
};

// Trouve la plaque la plus proche avec Voronoi SPHÉRIQUE + domain warping
PlateInfo findClosestPlate(vec2 uv, uint seed) {
    PlateInfo info;
    
    // Domain warping pour bordures organiques
    vec2 warpOffset = domainWarp(uv, seed);
    vec2 warpedUV = uv + warpOffset;
    
    // Wrap X, clamp Y
    warpedUV.x = fract(warpedUV.x);
    warpedUV.y = clamp(warpedUV.y, 0.001, 0.999);
    
    // Convertir en point 3D sur sphère
    vec3 pointOnSphere = uvToSphere(warpedUV);
    
    float minDist = 1e10;
    float secondDist = 1e10;
    int closestPlate = 0;
    int secondPlate = 0;
    vec2 closestCenter = vec2(0.0);
    vec2 secondCenter = vec2(0.0);
    
    for (int i = 0; i < NUM_PLATES; i++) {
        vec2 centerUV = getPlateCenter(i, seed);
        vec3 centerOnSphere = uvToSphere(centerUV);
        
        // Distance GÉODÉSIQUE (correcte sur la sphère)
        float dist = geodesicDistance(pointOnSphere, centerOnSphere);
        
        if (dist < minDist) {
            secondDist = minDist;
            secondPlate = closestPlate;
            secondCenter = closestCenter;
            minDist = dist;
            closestPlate = i;
            closestCenter = centerUV;
        } else if (dist < secondDist) {
            secondDist = dist;
            secondPlate = i;
            secondCenter = centerUV;
        }
    }
    
    // Distance au bord (en radians, typiquement 0 à ~0.5)
    float borderDist = secondDist - minDist;
    
    // Décroissance exponentielle pour effet localisé aux bordures
    // Facteur 100 : effet significatif jusqu'à ~0.02 rad (~1.1°)
    float borderStrength = exp(-borderDist * 100.0);
    borderStrength = clamp(borderStrength, 0.0, 1.0);
    
    // Vélocités des deux plaques
    vec2 vel1 = getPlateVelocity(closestPlate, seed);
    vec2 vel2 = getPlateVelocity(secondPlate, seed);
    
    // Calcul de la convergence
    // Direction de la frontière (du centre1 vers centre2)
    vec2 toSecond = secondCenter - closestCenter;
    // Gérer le wrap X
    if (toSecond.x > 0.5) toSecond.x -= 1.0;
    if (toSecond.x < -0.5) toSecond.x += 1.0;
    vec2 borderNormal = normalize(toSecond);
    
    // Vélocité relative projetée sur la normale
    vec2 relVel = vel1 - vel2;
    float convergence = -dot(relVel, borderNormal);  // Positif = les plaques se rapprochent
    
    info.plateId = closestPlate;
    info.secondPlateId = secondPlate;
    info.borderDist = borderDist;
    info.borderStrength = borderStrength;
    info.velocity1 = vel1;
    info.velocity2 = vel2;
    info.convergence = convergence;
    
    return info;
}

// Calcule l'uplift tectonique basé sur le type de frontière
float calculateTectonicUplift(PlateInfo info, bool isOceanic1, bool isOceanic2, vec3 coords, uint seed) {
    if (info.borderStrength < 0.05) {
        return 0.0;  // Trop loin de la bordure
    }
    
    float uplift = 0.0;
    float convergence = info.convergence;
    float strength = info.borderStrength;
    
    // Bruit local pour variation le long de la frontière
    float localNoise = fbm(coords * 0.02, 4, 0.6, 2.0, seed + 88888u);
    float variation = 0.7 + 0.6 * localNoise;  // [0.7, 1.3]
    
    if (convergence > 0.2) {
        // === CONVERGENCE ===
        float conv_strength = min(convergence, 1.0);
        
        if (!isOceanic1 && !isOceanic2) {
            // Continent-Continent : Hautes montagnes (Himalaya)
            uplift = strength * 4000.0 * conv_strength;
        } else if (isOceanic1 && isOceanic2) {
            // Océan-Océan : Fosse + Arc insulaire
            // Position relative pour asymétrie
            float side = sign(dot(info.velocity1, vec2(1.0, 0.0)));
            if (info.borderDist < 0.01) {
                // Fosse profonde
                uplift = -strength * 5000.0 * conv_strength;
            } else if (info.borderDist < 0.03) {
                // Arc insulaire (50-100km en arrière de la fosse)
                float arcFactor = smoothstep(0.01, 0.015, info.borderDist) * 
                                  smoothstep(0.03, 0.025, info.borderDist);
                uplift = arcFactor * 1500.0 * conv_strength;
            }
        } else {
            // Océan-Continent : Subduction asymétrique
            if (isOceanic1) {
                // Ce côté est océanique - FOSSE
                uplift = -strength * 4000.0 * conv_strength;
            } else {
                // Ce côté est continental - CORDILLÈRE
                uplift = strength * 3000.0 * conv_strength;
            }
        }
    } else if (convergence < -0.2) {
        // === DIVERGENCE ===
        float div_strength = min(-convergence, 1.0);
        
        if (isOceanic1 && isOceanic2) {
            // Dorsale médio-océanique
            uplift = strength * 2500.0 * div_strength;
        } else if (!isOceanic1 && !isOceanic2) {
            // Rift continental (Vallée du Rift)
            // Vallée centrale + épaules surélevées
            if (info.borderDist < 0.008) {
                uplift = -strength * 800.0 * div_strength;  // Vallée
            } else if (info.borderDist < 0.02) {
                float shoulderFactor = smoothstep(0.008, 0.012, info.borderDist) *
                                       smoothstep(0.02, 0.016, info.borderDist);
                uplift = shoulderFactor * 500.0 * div_strength;  // Épaules
            }
        } else {
            // Rift mixte
            uplift = -strength * 400.0 * div_strength;
        }
    } else {
        // === TRANSFORMANTE ===
        // Effet minimal, légère déformation
        uplift = strength * 100.0 * (localNoise - 0.5) * 2.0;
    }
    
    return uplift * variation;
}

// ============================================================================
// TRIPLE JUNCTIONS - Détection et cumul d'effets
// ============================================================================

// Compte les plaques distinctes dans un voisinage et retourne l'uplift cumulé
float calculateTripleJunctionUplift(vec2 uv, vec3 coords, uint seed, float continental_freq) {
    // Échantillonner les plaques dans un voisinage 3x3
    int plates[9];
    int numUnique = 0;
    
    float pixelSizeU = 1.0 / float(params.width);
    float pixelSizeV = 1.0 / float(params.height);
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 sampleUV = uv + vec2(float(dx) * pixelSizeU * 2.0, float(dy) * pixelSizeV * 2.0);
            sampleUV.x = fract(sampleUV.x);  // Wrap X
            sampleUV.y = clamp(sampleUV.y, 0.0, 1.0);
            
            PlateInfo sampleInfo = findClosestPlate(sampleUV, seed);
            plates[dy * 3 + dx + 4] = sampleInfo.plateId;
        }
    }
    
    // Compter les plaques uniques
    int uniquePlates[4];  // Max 4 plaques différentes dans un 3x3
    numUnique = 0;
    
    for (int i = 0; i < 9; i++) {
        bool found = false;
        for (int j = 0; j < numUnique; j++) {
            if (uniquePlates[j] == plates[i]) {
                found = true;
                break;
            }
        }
        if (!found && numUnique < 4) {
            uniquePlates[numUnique] = plates[i];
            numUnique++;
        }
    }
    
    // Si moins de 3 plaques, pas de triple junction
    if (numUnique < 3) {
        return 0.0;
    }
    
    // === TRIPLE JUNCTION DÉTECTÉ ===
    // Cumuler les effets des paires de plaques
    float totalUplift = 0.0;
    
    for (int i = 0; i < numUnique; i++) {
        for (int j = i + 1; j < numUnique; j++) {
            // Calculer l'interaction entre plaques i et j
            vec2 vel_i = getPlateVelocity(uniquePlates[i], seed);
            vec2 vel_j = getPlateVelocity(uniquePlates[j], seed);
            
            vec2 center_i = getPlateCenter(uniquePlates[i], seed);
            vec2 center_j = getPlateCenter(uniquePlates[j], seed);
            
            // Direction entre centres
            vec2 toJ = center_j - center_i;
            if (toJ.x > 0.5) toJ.x -= 1.0;
            if (toJ.x < -0.5) toJ.x += 1.0;
            vec2 normal = normalize(toJ);
            
            // Convergence
            float conv = -dot(vel_i - vel_j, normal);
            
            // Déterminer type océan/continent pour chaque plaque
            vec3 c_i = getCylindricalCoords(ivec2(center_i * vec2(params.width, params.height)),
                                            params.width, params.height, params.cylinder_radius);
            vec3 c_j = getCylindricalCoords(ivec2(center_j * vec2(params.width, params.height)),
                                            params.width, params.height, params.cylinder_radius);
            bool ocean_i = fbm(c_i * continental_freq, 6, 0.6, 2.0, seed + 77777u) < 0.1;
            bool ocean_j = fbm(c_j * continental_freq, 6, 0.6, 2.0, seed + 77777u) < 0.1;
            
            // Calculer contribution (version simplifiée)
            if (conv > 0.2) {
                // Convergence
                if (!ocean_i && !ocean_j) {
                    totalUplift += 1500.0 * min(conv, 1.0);  // Continent-continent
                } else if (ocean_i && ocean_j) {
                    totalUplift += 800.0 * min(conv, 1.0);   // Océan-océan
                } else {
                    totalUplift += 1200.0 * min(conv, 1.0);  // Mixte
                }
            } else if (conv < -0.2) {
                // Divergence
                if (ocean_i && ocean_j) {
                    totalUplift += 1000.0 * min(-conv, 1.0);  // Dorsale
                } else {
                    totalUplift -= 300.0 * min(-conv, 1.0);   // Rift
                }
            }
        }
    }
    
    // Bruit local pour instabilité géologique
    float instability = fbm(coords * 0.03, 3, 0.7, 2.0, seed + 99999u);
    totalUplift *= (0.8 + 0.4 * instability);
    
    // PLAFONNER l'effet cumulé
    return clamp(totalUplift, -6000.0, 6000.0);
}

// ============================================================================
// MAIN SHADER
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Bounds check
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Coordonnées normalisées UV [0,1] pour Voronoi
    vec2 uv = vec2(float(pixel.x) / float(params.width), 
                   float(pixel.y) / float(params.height));
    
    // Coordonnées cylindriques 3D pour le bruit (NORMALISÉES)
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === FRÉQUENCES BASÉES SUR CYLINDER_RADIUS (cohérence avec legacy) ===
    float base_freq = 2.0 / params.cylinder_radius;
    float detail_freq = 1.504 / params.cylinder_radius;
    float tectonic_freq = 0.4 / params.cylinder_radius;
    float continental_freq = 0.8 / params.cylinder_radius;
    
    // === MASQUE CONTINENTAL (indépendant des plaques) ===
    // Crée la dichotomie océan/continent de façon naturelle
    float continentalNoise = fbm(coords * continental_freq, 6, 0.6, 2.0, params.seed + 77777u);
    bool isOceanic = continentalNoise < 0.1;  // ~60% océan
    
    // Élévation de base continent/océan
    float baseElevation = isOceanic ? -2500.0 : 200.0;
    // Transition douce entre océan et continent
    float oceanContBlend = smoothstep(-0.1, 0.3, continentalNoise);
    baseElevation = mix(-2500.0, 200.0, oceanContBlend);
    
    // === PLAQUES TECTONIQUES (Voronoi sphérique) ===
    PlateInfo plateInfo = findClosestPlate(uv, params.seed);
    
    // Déterminer si chaque côté de la frontière est océanique
    // Utiliser le bruit continental aux centres des plaques pour cohérence
    vec2 center1 = getPlateCenter(plateInfo.plateId, params.seed);
    vec2 center2 = getPlateCenter(plateInfo.secondPlateId, params.seed);
    vec3 coords1 = getCylindricalCoords(ivec2(center1 * vec2(params.width, params.height)), 
                                         params.width, params.height, params.cylinder_radius);
    vec3 coords2 = getCylindricalCoords(ivec2(center2 * vec2(params.width, params.height)), 
                                         params.width, params.height, params.cylinder_radius);
    bool isOceanic1 = fbm(coords1 * continental_freq, 6, 0.6, 2.0, params.seed + 77777u) < 0.1;
    bool isOceanic2 = fbm(coords2 * continental_freq, 6, 0.6, 2.0, params.seed + 77777u) < 0.1;
    
    // === UPLIFT TECTONIQUE AUX FRONTIÈRES ===
    float tectonicUplift = calculateTectonicUplift(plateInfo, isOceanic1, isOceanic2, coords, params.seed);
    
    // === TRIPLE JUNCTIONS (là où 3+ plaques se rencontrent) ===
    float tripleJunctionUplift = calculateTripleJunctionUplift(uv, coords, params.seed, continental_freq);
    
    // Combiner uplift de frontière et triple junction
    // Le triple junction ajoute un effet supplémentaire, pas un remplacement
    tectonicUplift += tripleJunctionUplift * 0.5;  // Effet modéré
    
    // Plafonner l'uplift total (réalisme géologique)
    tectonicUplift = clamp(tectonicUplift, -8000.0, 6000.0);
    
    // === BRUIT PRINCIPAL (Relief général) ===
    float noise1 = fbm(coords * base_freq, 8, 0.75, 2.0, params.seed);
    float noise2 = fbm(coords * base_freq, 8, 0.75, 2.0, params.seed + 10000u);
    
    // Relief de bruit
    float noiseElevation = noise1 * 3500.0 + clamp(noise2, 0.0, 1.0) * params.elevation_modifier;
    
    // === STRUCTURES TECTONIQUES LEGACY (Chaînes de montagnes supplémentaires) ===
    float tectonic_mountain = abs(fbmSimplex(coords * tectonic_freq, 10, 0.55, 2.0, params.seed + 20000u));
    
    float legacyMountains = 0.0;
    if (tectonic_mountain > 0.45 && tectonic_mountain < 0.55) {
        float band_strength = 1.0 - abs(tectonic_mountain - 0.5) * 20.0;
        legacyMountains = 2500.0 * band_strength;
    }
    
    // === STRUCTURES TECTONIQUES LEGACY (Canyons/Rifts) ===
    float tectonic_canyon = abs(fbmSimplex(coords * tectonic_freq, 4, 0.55, 2.0, params.seed + 30000u));
    
    float legacyCanyons = 0.0;
    if (tectonic_canyon > 0.45 && tectonic_canyon < 0.55) {
        float band_strength = 1.0 - abs(tectonic_canyon - 0.5) * 20.0;
        legacyCanyons = -1500.0 * band_strength;
    }
    
    // === ÉLÉVATION FINALE ===
    float elevation = baseElevation + noiseElevation + tectonicUplift + legacyMountains + legacyCanyons;
    
    // === DÉTAILS ADDITIONNELS (comme legacy) ===
    if (elevation > 800.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.85, 3.0, params.seed + 40000u), 0.0, 1.0);
        elevation += detail * 5000.0;
    } else if (elevation <= -800.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.85, 3.0, params.seed + 40000u), -1.0, 0.0);
        elevation += detail * 5000.0;
    }
    
    // === CALCUL DES COMPOSANTS GeoTexture ===
    float height = elevation;
    
    // Bedrock : résistance basée sur altitude + bruit + proximité frontière
    float bedrock_noise = fbm(coords * 0.01, 4, 0.5, 2.0, params.seed + 50000u) * 0.3;
    float bedrock = clamp(0.5 + height / 10000.0 + bedrock_noise + plateInfo.borderStrength * 0.2, 0.0, 1.0);
    
    // Sediment : zéro au départ (sera rempli par l'érosion)
    float sediment = 0.0;
    
    // Water height : colonne d'eau si sous le niveau de la mer
    float water_height = max(0.0, params.sea_level - height);
    
    // === ÉCRITURE SORTIES ===
    vec4 geo_data = vec4(height, bedrock, sediment, water_height);
    imageStore(geo_texture, pixel, geo_data);
    
    // PlatesTexture : plate_id, velocity_x, velocity_y, convergence_type
    float convergenceType = 0.0;
    if (plateInfo.convergence > 0.2) convergenceType = 1.0;
    else if (plateInfo.convergence < -0.2) convergenceType = -1.0;
    
    vec4 plate_data = vec4(
        float(plateInfo.plateId), 
        plateInfo.velocity1.x, 
        plateInfo.velocity1.y, 
        convergenceType
    );
    imageStore(plates_texture, pixel, plate_data);
}
