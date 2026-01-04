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
// G = border_dist (distance au bord de plaque)
// B = plate_elevation (élévation de base du plateau)
// A = is_oceanic (1.0 si océanique, 0.0 si continental)
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

// Value Noise 3D
float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Utiliser fade pour le lissage
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    uvec3 i0 = uvec3(i) + uvec3(seed_offset);
    
    // Échantillonner 8 coins du cube
    float c000 = rand(hash3(i0 + uvec3(0, 0, 0)));
    float c100 = rand(hash3(i0 + uvec3(1, 0, 0)));
    float c010 = rand(hash3(i0 + uvec3(0, 1, 0)));
    float c110 = rand(hash3(i0 + uvec3(1, 1, 0)));
    float c001 = rand(hash3(i0 + uvec3(0, 0, 1)));
    float c101 = rand(hash3(i0 + uvec3(1, 0, 1)));
    float c011 = rand(hash3(i0 + uvec3(0, 1, 1)));
    float c111 = rand(hash3(i0 + uvec3(1, 1, 1)));
    
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
    
    // Contributions des 4 coins
    uvec3 ii = uvec3(i) + uvec3(seed_offset);
    
    vec4 w;
    w.x = 0.6 - dot(x0, x0);
    w.y = 0.6 - dot(x1, x1);
    w.z = 0.6 - dot(x2, x2);
    w.w = 0.6 - dot(x3, x3);
    
    w = max(w, 0.0);
    vec4 w4 = w * w * w * w;
    
    // Gradients
    vec3 g0 = grad3(hash3(ii));
    vec3 g1 = grad3(hash3(uvec3(i + i1) + uvec3(seed_offset)));
    vec3 g2 = grad3(hash3(uvec3(i + i2) + uvec3(seed_offset)));
    vec3 g3 = grad3(hash3(uvec3(i + vec3(1.0)) + uvec3(seed_offset)));
    
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
// IDENTIQUE AU LEGACY : cy = float(y) SANS normalisation !
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    // Angle de longitude [0, 2π]
    float angle = (float(pixel.x) / float(w)) * TAU;
    
    // Coordonnées cylindriques (comme le legacy MapGenerator.gd)
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = float(pixel.y);  // Y brut, NON normalisé - clé pour l'aspect ratio
    
    return vec3(cx, cy, cz);
}

// ============================================================================
// PLAQUES TECTONIQUES (Voronoi)
// ============================================================================

// Génère les centres des plaques tectoniques
vec2 getPlateCenter(int plateId, uint seed) {
    uint h = hash(uint(plateId) + seed * 7919u);
    vec2 center = rand2(h);
    return center;  // Position normalisée [0, 1]
}

// Vérifie si une plaque est océanique (~70% océanique)
bool isPlateOceanic(int plateId, uint seed) {
    uint h = hash(uint(plateId) + seed * 3571u);
    return rand(h) < 0.7;
}

// Obtient l'élévation de base d'une plaque (plateaux)
// Valeurs RÉDUITES pour laisser le bruit dominer
float getPlateBaseElevation(int plateId, uint seed, bool isOceanic) {
    uint h = hash(uint(plateId) + seed * 8831u);
    float r = rand(h);
    
    if (isOceanic) {
        // Plaques océaniques : -800 à -200m (influence légère)
        return -800.0 + r * 600.0;
    } else {
        // Plaques continentales : plateaux entre 50 et 400m
        return 50.0 + r * 350.0;
    }
}

// Distance cyclique sur X (wrap horizontal pour continuité)
float cyclicDistanceX(float x1, float x2, float width) {
    float dx = abs(x1 - x2);
    return min(dx, width - dx);
}

// Trouve la plaque la plus proche et calcule la distance au bord
// Retourne : vec4(plate_id, distance_to_border, second_plate_id, border_strength)
vec4 findClosestPlate(vec2 uv, uint seed) {
    float minDist = 1e10;
    float secondDist = 1e10;
    int closestPlate = 0;
    int secondPlate = 0;
    
    for (int i = 0; i < NUM_PLATES; i++) {
        vec2 center = getPlateCenter(i, seed);
        
        // Distance avec wrap sur X
        float dx = cyclicDistanceX(uv.x, center.x, 1.0);
        float dy = uv.y - center.y;
        float dist = sqrt(dx * dx + dy * dy);
        
        if (dist < minDist) {
            secondDist = minDist;
            secondPlate = closestPlate;
            minDist = dist;
            closestPlate = i;
        } else if (dist < secondDist) {
            secondDist = dist;
            secondPlate = i;
        }
    }
    
    // Distance au bord = différence entre les deux plus proches
    float borderDist = secondDist - minDist;
    
    // Force du bord (plus c'est proche du bord, plus c'est fort)
    // Bordures ÉTROITES : smoothstep de 0 à 0.025 (était 0.15)
    float borderStrength = 1.0 - smoothstep(0.0, 0.025, borderDist);
    
    return vec4(float(closestPlate), borderDist, float(secondPlate), borderStrength);
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
    
    // Coordonnées normalisées pour Voronoi (plaques tectoniques)
    vec2 uv = vec2(float(pixel.x) / float(params.width), 
                   float(pixel.y) / float(params.height));
    
    // Coordonnées cylindriques pour le bruit (comme legacy MapGenerator)
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // === PLAQUES TECTONIQUES ===
    vec4 plateInfo = findClosestPlate(uv, params.seed);
    int plateId = int(plateInfo.x);
    float borderDist = plateInfo.y;
    int secondPlateId = int(plateInfo.z);
    float borderStrength = plateInfo.w;
    
    bool isOceanic = isPlateOceanic(plateId, params.seed);
    bool isSecondOceanic = isPlateOceanic(secondPlateId, params.seed);
    
    // Élévation de base de la plaque (plateau continental ou plancher océanique)
    float plateElevation = getPlateBaseElevation(plateId, params.seed, isOceanic);
    
    // === FROTTEMENT AUX FRONTIÈRES DE PLAQUES ===
    // Valeurs RÉDUITES pour un effet plus subtil
    float tectonicUplift = 0.0;
    
    if (borderStrength > 0.01) {
        // Type de frontière basé sur les types de plaques
        if (!isOceanic && !isSecondOceanic) {
            // Collision continent-continent : MONTAGNES (Himalaya-like)
            tectonicUplift = borderStrength * 1500.0;
        } else if (isOceanic && !isSecondOceanic) {
            // Subduction océan sous continent : Cordillère
            tectonicUplift = borderStrength * 1000.0;
        } else if (!isOceanic && isSecondOceanic) {
            // Subduction (de l'autre côté)
            tectonicUplift = borderStrength * 800.0;
        } else {
            // Océan-océan : dorsale océanique ou fosse
            uint boundaryHash = hash(uint(plateId * 13 + secondPlateId * 17) + params.seed);
            if (rand(boundaryHash) > 0.5) {
                tectonicUplift = borderStrength * 500.0;  // Dorsale
            } else {
                tectonicUplift = -borderStrength * 600.0; // Fosse
            }
        }
    }
    
    // === PARAMÈTRES DE BRUIT ===
    // Fréquences FIXES pour cohérence (indépendantes de la résolution)
    float base_freq = 0.008;
    float detail_freq = 0.02;
    float tectonic_freq = 0.003;
    
    // === BRUIT PRINCIPAL (Relief général) ===
    // Le bruit doit DOMINER l'élévation, pas les plaques
    float noise1 = fbm(coords * base_freq, 8, 0.65, 2.0, params.seed);
    float noise2 = fbm(coords * base_freq * 0.5, 6, 0.55, 2.0, params.seed + 10000u);
    
    // Élévation de bruit : -3000 à +3000m (centre sur 0)
    float noiseElevation = noise1 * 3000.0 + noise2 * 1500.0 + clamp(noise2, 0.0, 1.0) * params.elevation_modifier;
    
    // === STRUCTURES TECTONIQUES LEGACY (Chaînes de montagnes additionnelles) ===
    float tectonic_mountain = abs(fbmSimplex(coords * tectonic_freq, 10, 0.55, 2.0, params.seed + 20000u));
    
    float legacyMountains = 0.0;
    if (tectonic_mountain > 0.45 && tectonic_mountain < 0.55) {
        float band_strength = 1.0 - abs(tectonic_mountain - 0.5) * 20.0;
        legacyMountains = 1200.0 * band_strength;  // Réduit de 2500 à 1200
    }
    
    // === STRUCTURES TECTONIQUES LEGACY (Canyons/Rifts) ===
    float tectonic_canyon = abs(fbmSimplex(coords * tectonic_freq, 4, 0.55, 2.0, params.seed + 30000u));
    
    float legacyCanyons = 0.0;
    if (tectonic_canyon > 0.45 && tectonic_canyon < 0.55) {
        float band_strength = 1.0 - abs(tectonic_canyon - 0.5) * 20.0;
        legacyCanyons = -800.0 * band_strength;  // Réduit de 1500 à 800
    }
    
    // === ÉLÉVATION FINALE ===
    float elevation = plateElevation + noiseElevation + tectonicUplift + legacyMountains + legacyCanyons;
    
    // === DÉTAILS ADDITIONNELS (Montagnes hautes / Fosses profondes) ===
    // Détails plus subtils pour ne pas créer d'extrêmes
    if (elevation > 500.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.75, 2.5, params.seed + 40000u), 0.0, 1.0);
        elevation += detail * 1500.0;  // Réduit de 5000 à 1500
    } else if (elevation <= -500.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.75, 2.5, params.seed + 40000u), -1.0, 0.0);
        elevation += detail * 1000.0;  // Réduit de 5000 à 1000
    }
    
    // === CALCUL DES COMPOSANTS GeoTexture ===
    float height = elevation;
    
    // Bedrock : résistance basée sur altitude + bruit + frontières (plus dur aux frontières)
    float bedrock_noise = fbm(coords * 4.0, 4, 0.5, 2.0, params.seed + 50000u) * 0.3;
    float bedrock = clamp(0.5 + height / 10000.0 + bedrock_noise + borderStrength * 0.3, 0.0, 1.0);
    
    // Sediment : zéro au départ (sera rempli par l'érosion)
    float sediment = 0.0;
    
    // Water height : colonne d'eau si sous le niveau de la mer
    float water_height = max(0.0, params.sea_level - height);
    
    // === ÉCRITURE SORTIES ===
    vec4 geo_data = vec4(height, bedrock, sediment, water_height);
    imageStore(geo_texture, pixel, geo_data);
    
    // PlatesTexture : plate_id, border_dist, plate_elevation, is_oceanic
    vec4 plate_data = vec4(float(plateId), borderDist, plateElevation, isOceanic ? 1.0 : 0.0);
    imageStore(plates_texture, pixel, plate_data);
}
