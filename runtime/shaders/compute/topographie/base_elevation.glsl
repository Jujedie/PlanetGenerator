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
    float ocean_threshold;  // Seuil océan/continent (configurable UI)
    float padding3;
    float planet_radius_km; // Échelle physique, indépendante de la texture
    uint active_plate_count;// Nombre de plaques adapté à la surface
    float feature_frequency_scale;
    float chain_width_km;   // Largeur physique des chaînes tectoniques
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const int MAX_PLATES = 48;

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
    // Y centré [-R*π/2, +R*π/2] pour isotropie RÉELLE du bruit
    // Pas vertical par pixel = R*π/H ≈ 1.0, identique au pas horizontal
    // (l'ancien facteur 2.0 donnait un pas de ~0.637, étirant les features de ~57%)
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * PI;
    
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
// Seuil configurable via params.ocean_threshold (défini par UI)
bool isLocallyOceanic(vec3 coords, float cylinder_radius, uint seed) {
    // Bruit continental à TRÈS grande échelle
    // Fréquence réduite = zones plus grandes et cohérentes
    float continental_freq = 0.8 * params.feature_frequency_scale / cylinder_radius;
    float continentalNoise = fbm(coords * continental_freq, 6, 0.6, 2.0, seed + 77777u);
    // Seuil configurable depuis l'UI (params.ocean_threshold)
    // FBM produit [-1, 1], threshold dans [-0.25, 0.80] selon ratio océan
    return continentalNoise < params.ocean_threshold;
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
// CORRIGÉ : Utilise du bruit 3D sur coordonnées cylindriques pour un wrap seamless en X
// L'ancien noise2D en espace UV créait une couture visible au bord horizontal
vec2 domainWarp(vec2 uv, uint seed) {
    // Convertir UV en coordonnées cylindriques 3D pour seamless X
    float angle = uv.x * TAU;
    float cy = (uv.y - 0.5) * PI;  // [-π/2, π/2] proportionnel à latitude
    vec3 p = vec3(cos(angle), cy, sin(angle));
    
    vec2 offset = vec2(0.0);
    float amplitude = 0.035;
    float frequency = 3.0;  // Ajusté pour l'espace 3D cylindrique
    
    // 4 octaves pour variété organique
    for (int i = 0; i < 4; i++) {
        float ox = valueNoise3D(p * frequency, seed + uint(i) * 5000u);
        float oy = valueNoise3D(p * frequency, seed + uint(i) * 5000u + 500u);
        offset += vec2(ox, oy) * amplitude;
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
    
    for (int i = 0; i < MAX_PLATES; i++) {
        if (i >= int(params.active_plate_count)) break;
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
    
    // Le profil est exprimé en kilomètres : changer la résolution de sortie ne
    // change donc plus la largeur des cordillères et dorsales.
    float chainWidthAngle = params.chain_width_km / max(params.planet_radius_km, 1.0);
    float borderStrength = exp(-borderDist / max(chainWidthAngle, 0.0001));
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
float calculateTectonicUplift(PlateInfo info, bool isOceanic1, bool isOceanic2, vec3 coords, uint seed, bool localIsOceanic) {
    float uplift = 0.0;
    float convergence = info.convergence;
    // La frontière géométrique ne fournit qu'une zone d'influence. Les anciens
    // profils en anneau (amplitude nulle au centre puis deux épaules hautes)
    // dessinaient exactement les faux canyons visibles dans la heightmap.
    // L'échelle du bruit est exprimée relativement au rayon du cylindre afin
    // de ne pas changer avec la résolution de texture.
    float pairSign = info.plateId < info.secondPlateId ? 1.0 : -1.0;
    float borderDistanceKm = info.borderDist * max(params.planet_radius_km, 1.0);
    float chainWidthKm = max(params.chain_width_km, 1.0);
    vec3 physicalCoords = coords / max(params.cylinder_radius, 1.0);
    float boundaryWarp =
        fbm(physicalCoords * 6.5, 4, 0.58, 2.0, seed + 42731u) * 0.72 +
        fbm(physicalCoords * 13.0, 3, 0.55, 2.0, seed + 52733u) * 0.28;
    float signedBorderDistanceKm = borderDistanceKm * pairSign;
    float naturalBorderDistanceKm = abs(
        signedBorderDistanceKm + boundaryWarp * chainWidthKm * 1.35
    );
    // Une assise unique, large et monotone remplace la crête étroite et les
    // bandes en retrait. La structure montagneuse vient du bruit ridgé 3D,
    // pas d'une courbe de distance uniforme qui pourrait devenir une muraille.
    float normalizedBorderDistance = naturalBorderDistanceKm / chainWidthKm;
    float broadFoothills = exp(-pow(normalizedBorderDistance / 3.8, 2.0));
    float ridgeTexture = clamp(ridgedMultifractal(
        physicalCoords * (11.0 * params.feature_frequency_scale),
        5, 0.52, 2.05, seed + 64123u
    ), 0.0, 1.0);
    float segmentNoise = fbm(
        physicalCoords * 4.2, 4, 0.57, 2.0, seed + 918273u
    );
    float segmentation = mix(0.18, 1.0, smoothstep(-0.42, 0.38, segmentNoise));
    float strength = broadFoothills * mix(0.12, 1.0, ridgeTexture) * segmentation;
    if (naturalBorderDistanceKm > chainWidthKm * 6.0 || strength < 0.004) {
        return 0.0;
    }
    
    float localNoise = fbm(
        physicalCoords * 17.0, 4, 0.6, 2.0, seed + 88888u
    );
    float variation = clamp(0.72 + 0.34 * localNoise, 0.46, 1.08);
    
    if (convergence > 0.2) {
        // === CONVERGENCE ===
        float conv_strength = min(convergence, 1.0);
        
        if (!isOceanic1 && !isOceanic2) {
            // Continent-Continent : chaîne haute, texturée et dotée de larges
            // piémonts, sans altitude directement alignée sur le bord.
            uplift = strength * 2800.0 * conv_strength;
        } else if (isOceanic1 && isOceanic2) {
            // Aucune fosse ni couronne à deux épaules. La bathymétrie d'âge de
            // croûte reste responsable du relief océanique à grande échelle.
            uplift = strength * 520.0 * conv_strength;
        } else {
            // Sur une limite mixte, le masque local détermine le côté actuel.
            // Le continent reçoit une cordillère large et positive dès la
            // côte : il n'existe donc plus de chenal bas entre deux bourrelets.
            uplift = strength * (localIsOceanic ? 180.0 : 2100.0) * conv_strength;
        }
    } else if (convergence < -0.2) {
        // === DIVERGENCE ===
        float div_strength = min(-convergence, 1.0);
        
        if (isOceanic1 && isOceanic2) {
            // Dorsale médio-océanique
            uplift = strength * 1700.0 * div_strength;
        } else if (!isOceanic1 && !isOceanic2) {
            // Les rifts continentaux n'incisent plus le relief tant que la
            // génération de canyons est désactivée.
            uplift = 0.0;
        } else {
            uplift = 0.0;
        }
    } else {
        // === TRANSFORMANTE ===
        // Effet minimal, légère déformation
        uplift = strength * 80.0 * max(localNoise, 0.0);
    }
    
    // Une compression même modérée renforce les massifs du même champ large.
    // Aucun second profil décalé n'est ajouté : deux profils parallèles
    // recréeraient précisément le chenal artificiel que l'on supprime.
    float compression = smoothstep(0.03, 0.45, convergence);
    if (!localIsOceanic && (!isOceanic1 || !isOceanic2)) {
        uplift += strength * compression * 520.0;
    }

    // Garantie explicite : aucune contribution tectonique négative ne peut
    // creuser une cellule continentale et recréer un canyon linéaire.
    if (!localIsOceanic) {
        uplift = max(uplift, 0.0);
    }

    return uplift * variation;
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
    float base_freq = 2.0 * params.feature_frequency_scale / params.cylinder_radius;
    float detail_freq = 1.504 * pow(params.feature_frequency_scale, 1.15) / params.cylinder_radius;
    float tectonic_freq = 0.4 * params.feature_frequency_scale / params.cylinder_radius;
    float continental_freq = 0.8 * params.feature_frequency_scale / params.cylinder_radius;
    
    // === MASQUE CONTINENTAL (indépendant des plaques) ===
    // Crée la dichotomie océan/continent de façon naturelle
    // Seuil configurable via params.ocean_threshold
    float continentalNoise = fbm(coords * continental_freq, 6, 0.6, 2.0, params.seed + 77777u);
    bool isOceanic = continentalNoise < params.ocean_threshold;
    
    // === SYSTÈME D'ÉLÉVATION À 5 NIVEAUX ===
    // Basé sur la courbe hypsométrique terrestre réelle
    // Niveau 1: Océan profond (dorsale de référence) = -2600m
    // Niveau 2: Plateau continental (shelf) = -100m à 0m
    // Niveau 3: Plaines côtières = 0m à 150m
    // Niveau 4: Plaines intérieures/bassins = 50m à 300m
    // Niveau 5: Hauts plateaux = 500m à 1000m
    
    float oceanElev = -2600.0;     // Dorsale médio-océanique (référence)
    float shelfElev = -50.0;       // Plateau continental
    float coastalElev = 50.0;      // Plaines côtières
    float plainsElev = 150.0;      // Plaines intérieures
    float plateauElev = 600.0;     // Hauts plateaux (rares)
    
    // Bruit secondaire pour varier les types de terrain continental
    float basinNoise = fbm(coords * continental_freq * 0.5, 4, 0.5, 2.0, params.seed + 88888u);
    
    // Calcul des seuils de transition relatifs à ocean_threshold
    float deep_ocean_thresh = params.ocean_threshold - 0.30;  // Océan profond
    float shelf_thresh = params.ocean_threshold - 0.15;       // Début plateau continental
    float coast_thresh = params.ocean_threshold + 0.05;       // Plaines côtières
    float plains_thresh = params.ocean_threshold + 0.20;      // Plaines intérieures
    
    float baseElevation;
    if (continentalNoise < deep_ocean_thresh) {
        // Océan profond
        baseElevation = oceanElev;
    } else if (continentalNoise < shelf_thresh) {
        // Transition océan → plateau continental
        float t = smoothstep(deep_ocean_thresh, shelf_thresh, continentalNoise);
        baseElevation = mix(oceanElev, shelfElev, t);
    } else if (continentalNoise < coast_thresh) {
        // Plateau continental → plaines côtières
        float t = smoothstep(shelf_thresh, coast_thresh, continentalNoise);
        baseElevation = mix(shelfElev, coastalElev, t);
    } else if (continentalNoise < plains_thresh) {
        // Plaines côtières → plaines intérieures
        // Avec possibilité de bassins sédimentaires (zones basses)
        float t = smoothstep(coast_thresh, plains_thresh, continentalNoise);
        float targetElev = plainsElev;
        // Bassins sédimentaires : zones déprimées à l'intérieur des continents
        if (basinNoise < -0.2) {
            targetElev = mix(0.0, 100.0, (basinNoise + 0.5) / 0.3);  // Bassin: 0-100m
        }
        baseElevation = mix(coastalElev, targetElev, t);
    } else {
        // Intérieur continental continu. L'ancienne branche conservait une
        // valeur exactement égale à 150 m sur basinNoise [-0.1, 0.3], ce qui
        // produisait de vastes plateaux parfaitement stagnants. Une courbe
        // lissée garde des bassins et quelques hauts plateaux sans marche.
        float basin01 = basinNoise * 0.5 + 0.5;
        float interiorShape = smoothstep(0.22, 0.82, basin01);
        baseElevation = mix(45.0, plateauElev, interiorShape);

        // Empêcher la transition côte/intérieur d'introduire une cassure.
        float inlandBlend = smoothstep(plains_thresh, plains_thresh + 0.18, continentalNoise);
        baseElevation = mix(plainsElev, baseElevation, inlandBlend);
    }
    
    // === BRUIT PRINCIPAL (Relief général) ===
    // Amplitude réduite et biais minimal pour élévation médiane réaliste (~840m)
    float noise1 = fbm(coords * base_freq, 8, 0.75, 2.0, params.seed);
    float noise2 = fbm(coords * base_freq, 8, 0.75, 2.0, params.seed + 10000u);
    
    // Relief de bruit : amplitude 2400m avec biais modéré (+200m)
    // Plage résultante: [-2200, +2800m], centrée sur ~300m
    // Combiné avec baseElevation (~150m) → médiane continentale ~850m (réaliste)
    float noiseElevation = noise1 * 1500.0 + 200.0 + clamp(noise2, 0.0, 1.0) * params.elevation_modifier * 0.4;
    
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
    // Utiliser MÊME seuil params.ocean_threshold pour cohérence avec isLocallyOceanic
    bool isOceanic1 = fbm(coords1 * continental_freq, 6, 0.6, 2.0, params.seed + 77777u) < params.ocean_threshold;
    bool isOceanic2 = fbm(coords2 * continental_freq, 6, 0.6, 2.0, params.seed + 77777u) < params.ocean_threshold;
    
    // === UPLIFT TECTONIQUE AUX FRONTIÈRES ===
    // Le masque local protège explicitement le terrain continental de toute
    // incision négative assimilable à un canyon.
    float tectonicUplift = calculateTectonicUplift(plateInfo, isOceanic1, isOceanic2, coords, params.seed, isOceanic);
    
    // Les jonctions triples sont déjà incluses dans la superposition des
    // assises tectoniques continues. L'ancien masque binaire 3+ plaques
    // ajoutait ici un plateau uniforme aux contours Voronoï anguleux : ce sont
    // les petites taches claires isolées visibles dans la heightmap.
    
    // Plafonner l'uplift total (réalisme géologique)
    tectonicUplift = clamp(tectonicUplift, -5000.0, 4000.0);
    
    // Rugosité intracontinentale diffuse. L'ancien isoband
    // `0.38 < abs(noise) < 0.62` dessinait de longues courbes artificielles
    // ressemblant à des canyons ou à des digues, sans rapport tectonique.
    float interiorNoise = fbmSimplex(coords * tectonic_freq, 6, 0.55, 2.0, params.seed + 20000u);
    float continentalInterior = isOceanic ? 0.0 : (1.0 - plateInfo.borderStrength);
    float interiorRelief = interiorNoise * 140.0 * continentalInterior;
    
    // === ÉLÉVATION FINALE ===
    float elevation = baseElevation + noiseElevation + tectonicUplift + interiorRelief;
    
    // === CORRECTION ARCHIPEL : Remonter zones continentales légèrement submergées ===
    // Appliqué uniquement aux zones continentales proches du niveau de la mer
    // Évite l'effet archipel sans élever globalement la topographie
    if (!isOceanic && elevation > -300.0 && elevation < 0.0) {
        // Boost progressif : plus on est profond (proche de -300m), plus on booste
        float submersionDepth = -elevation;  // 0 à 300m
        float boostFactor = smoothstep(0.0, 300.0, submersionDepth);
        // Boost max +200m pour les zones à -300m, décroissant vers 0m
        elevation += boostFactor * 200.0;
    }
    
    // === DÉTAILS ADDITIONNELS (limités pour préserver les plaines) ===
    // Seuil augmenté à 2500m et amplitude réduite à 500m
    // Évite la rétroaction positive qui créait des montagnes partout
    if (elevation > 2500.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.85, 3.0, params.seed + 40000u), 0.0, 1.0);
        // Détails proportionnels à l'altitude (plus haut = plus de détails)
        float detailFactor = smoothstep(2500.0, 5000.0, elevation);
        elevation += detail * 500.0 * detailFactor;
    } else if (elevation <= -2000.0) {
        float detail = clamp(fbm(coords * detail_freq, 6, 0.85, 3.0, params.seed + 40000u), -1.0, 0.0);
        // Détails limités dans les abysses - ajout relief océanique
        float detailFactor = smoothstep(-2000.0, -4000.0, elevation);
        elevation += detail * 400.0 * detailFactor;
    }
    
    // === CLAMPING GLOBAL ET COMPRESSION DOUCE ===
    // Éviter les extrêmes irréalistes
    elevation = clamp(elevation, -7500.0, 8500.0);
    // Compression douce uniquement au-dessus de 6000 m.
    if (elevation > 6000.0) {
        elevation = 6000.0 + (elevation - 6000.0) * 0.4;
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
    
    // PlatesTexture : plate_id, velocity_x, velocity_y, signed boundary signal.
    // Le canal A vaut zéro à l'intérieur des plaques et tend vers -1/+1 au
    // coeur d'une limite divergente/convergente. L'ancienne valeur catégorielle
    // remplissait des régions entières et transformait ces régions en seeds JFA.
    float convergenceType = 0.0;
    if (plateInfo.convergence > 0.2) convergenceType = 1.0;
    else if (plateInfo.convergence < -0.2) convergenceType = -1.0;
    
    vec4 plate_data = vec4(
        float(plateInfo.plateId), 
        plateInfo.velocity1.x, 
        plateInfo.velocity1.y, 
        convergenceType * plateInfo.borderStrength
    );
    imageStore(plates_texture, pixel, plate_data);
}
