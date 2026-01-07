#[compute]
#version 450

// ============================================================================
// CLOUDS RENDER SHADER - Étape 3.3c : Rendu Procédural Multi-Couches
// ============================================================================
// Génération de nuages réalistes via 5 systèmes procéduraux combinés :
// 1. ITCZ (bande équatoriale) - Zone de Convergence Intertropicale
// 2. Fronts des latitudes moyennes - Ondes baroclines
// 3. Cyclones tropicaux - Spirales de tempêtes
// 4. Cirrus du jet stream - Traînées d'altitude
// 5. Cumulus dispersés - Remplissage convectif
//
// Combine patterns procéduraux (60%) + vapeur simulée (40%)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : VaporTexture (densité de vapeur simulée)
layout(set = 0, binding = 0, r32f) uniform readonly image2D vapor_texture;

// Texture de sortie : CloudsTexture RGBA8 (blanc avec alpha variable)
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D clouds_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform CloudsRenderParams {
    uint seed;
    uint width;
    uint height;
    float condensation_threshold;
    float cylinder_radius;
    uint atmosphere_type;
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// FONCTIONS DE BRUIT
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
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
    
    float c000 = rand(hash(ix ^ hash(iy ^ hash(iz))));
    float c100 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz))));
    float c010 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz))));
    float c110 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz))));
    float c001 = rand(hash(ix ^ hash(iy ^ hash(iz+1u))));
    float c101 = rand(hash((ix+1u) ^ hash(iy ^ hash(iz+1u))));
    float c011 = rand(hash(ix ^ hash((iy+1u) ^ hash(iz+1u))));
    float c111 = rand(hash((ix+1u) ^ hash((iy+1u) ^ hash(iz+1u))));
    
    float x00 = mix(c000, c100, u.x);
    float x10 = mix(c010, c110, u.x);
    float x01 = mix(c001, c101, u.x);
    float x11 = mix(c011, c111, u.x);
    
    float xy0 = mix(x00, x10, u.y);
    float xy1 = mix(x01, x11, u.y);
    
    return mix(xy0, xy1, u.z) * 2.0 - 1.0;
}

// fBm avec octaves
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

// Bruit cellulaire pour formes organiques
float cellularNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist = 1.0;
    
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                const float BIG_OFFSET = 10000.0;
                ivec3 ii = ivec3(i + neighbor + BIG_OFFSET);
                uint h = hash(uint(ii.x) + seed_offset ^ hash(uint(ii.y) ^ hash(uint(ii.z))));
                vec3 point = neighbor + vec3(rand(h), rand(hash(h + 1u)), rand(hash(h + 2u))) - f;
                float dist = length(point);
                minDist = min(minDist, dist);
            }
        }
    }
    
    return minDist;
}

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float cylinder_radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
    return vec3(cx, cy, cz);
}

// ============================================================================
// SYSTÈME 1 : ITCZ - Zone de Convergence Intertropicale
// ============================================================================
// Bande de nuages épais près de l'équateur avec ondulations

float generateITCZ(vec3 coords, float lat_abs, uint seed) {
    // Bande équatoriale : maximum à lat=0, décroissance douce
    float lat_factor = 1.0 - smoothstep(0.0, 0.20, lat_abs);
    
    if (lat_factor < 0.01) return 0.0;
    
    // Ondulations le long de l'équateur (ondes de Kelvin)
    float wave_freq = 3.0 / params.cylinder_radius;
    float wave = fbm(coords * wave_freq, 3, 0.5, 2.0, seed + 200000u);
    
    // Déplacement latitudinal de la bande
    float lat_offset = wave * 0.08;
    float adjusted_lat_factor = 1.0 - smoothstep(0.0, 0.18, abs(lat_abs - 0.02 + lat_offset));
    
    // Texture de nuages avec fBm
    float cloud_freq = 8.0 / params.cylinder_radius;
    float cloud_texture = fbm(coords * cloud_freq, 4, 0.55, 2.2, seed + 210000u);
    cloud_texture = (cloud_texture + 1.0) * 0.5; // [0, 1]
    
    // Cellulaire pour masses convectives
    float cell_freq = 12.0 / params.cylinder_radius;
    float cells = 1.0 - cellularNoise3D(coords * cell_freq, seed + 220000u);
    cells = smoothstep(0.3, 0.8, cells);
    
    return adjusted_lat_factor * (cloud_texture * 0.6 + cells * 0.4);
}

// ============================================================================
// SYSTÈME 2 : FRONTS DES LATITUDES MOYENNES
// ============================================================================
// Bandes diagonales (NE-SW / SE-NW) typiques des dépressions extratropicales

float generateMidLatitudeFronts(vec3 coords, float lat_signed, float lon_norm, uint seed) {
    float lat_abs = abs(lat_signed);
    
    // Zone active : 30°-65° de latitude (0.33-0.72)
    float zone_factor = smoothstep(0.28, 0.38, lat_abs) * (1.0 - smoothstep(0.65, 0.75, lat_abs));
    
    if (zone_factor < 0.01) return 0.0;
    
    // Ondes baroclines : diagonales inclinées
    // Direction différente selon l'hémisphère
    float hemisphere = sign(lat_signed);
    float diagonal = lon_norm * TAU + lat_signed * PI * 3.0 * hemisphere;
    
    // Multiple ondes avec longueurs différentes
    float wave1 = sin(diagonal * 5.0) * 0.5 + 0.5;
    float wave2 = sin(diagonal * 8.0 + 1.5) * 0.5 + 0.5;
    float wave3 = sin(diagonal * 3.0 + 3.0) * 0.5 + 0.5;
    
    // Moduler par du bruit pour irrégularité
    float noise_freq = 6.0 / params.cylinder_radius;
    float modulation = fbm(coords * noise_freq, 3, 0.6, 2.0, seed + 300000u);
    modulation = (modulation + 1.0) * 0.5;
    
    // Combiner les ondes
    float fronts = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2) * modulation;
    
    // Texture détaillée
    float detail_freq = 15.0 / params.cylinder_radius;
    float detail = fbm(coords * detail_freq, 3, 0.5, 2.5, seed + 310000u);
    detail = (detail + 1.0) * 0.5;
    
    return zone_factor * fronts * detail;
}

// ============================================================================
// SYSTÈME 3 : CYCLONES TROPICAUX
// ============================================================================
// Spirales caractéristiques des ouragans/typhons

float generateCyclones(vec3 coords, ivec2 pixel, float lat_signed, float lon_norm, uint seed) {
    float lat_abs = abs(lat_signed);
    
    // Zone de formation : 8°-25° de latitude (0.09-0.28)
    float zone_factor = smoothstep(0.06, 0.12, lat_abs) * (1.0 - smoothstep(0.25, 0.32, lat_abs));
    
    if (zone_factor < 0.01) return 0.0;
    
    float total = 0.0;
    
    // Générer plusieurs cyclones potentiels (5-8 par hémisphère)
    for (int i = 0; i < 6; i++) {
        // Position pseudo-aléatoire du centre du cyclone
        uint h = hash(seed + 400000u + uint(i) * 7919u);
        float cyclone_lon = rand(h);  // Longitude [0, 1]
        float cyclone_lat = rand(hash(h + 1u)) * 0.18 + 0.08;  // Latitude [0.08, 0.26]
        
        // Appliquer à l'hémisphère
        if (lat_signed < 0.0) cyclone_lat = -cyclone_lat;
        
        // Distance au centre du cyclone
        float dx = lon_norm - cyclone_lon;
        // Wrap pour continuité cylindrique
        if (dx > 0.5) dx -= 1.0;
        if (dx < -0.5) dx += 1.0;
        float dy = lat_signed - cyclone_lat;
        
        float dist = sqrt(dx * dx * 4.0 + dy * dy);  // Ellipse
        
        // Spirale logarithmique
        float angle = atan(dy, dx);
        float spiral = sin(angle * 5.0 - dist * 40.0);
        spiral = spiral * 0.5 + 0.5;
        
        // Atténuation radiale
        float radial = 1.0 - smoothstep(0.0, 0.12, dist);
        
        // Œil du cyclone (zone claire au centre)
        float eye = smoothstep(0.008, 0.015, dist);
        
        // Intensité variable selon le cyclone
        float intensity = rand(hash(h + 2u)) * 0.5 + 0.5;
        
        total += radial * spiral * eye * intensity;
    }
    
    return zone_factor * clamp(total, 0.0, 1.0);
}

// ============================================================================
// SYSTÈME 4 : CIRRUS DU JET STREAM
// ============================================================================
// Traînées fines et allongées aux latitudes des jets

float generateJetStreamCirrus(vec3 coords, float lat_abs, float lon_norm, uint seed) {
    float cirrus = 0.0;
    
    // Jet subtropical (~30°, lat_abs ≈ 0.33)
    float jet_sub_factor = 1.0 - smoothstep(0.0, 0.08, abs(lat_abs - 0.33));
    if (jet_sub_factor > 0.01) {
        // Traînées allongées dans le sens du vent (Est)
        float streak_freq = 20.0 / params.cylinder_radius;
        vec3 stretched = coords * vec3(streak_freq * 0.3, streak_freq * 1.5, streak_freq * 0.3);
        float streak = fbm(stretched, 3, 0.5, 2.5, seed + 500000u);
        streak = smoothstep(-0.2, 0.4, streak);
        
        cirrus += jet_sub_factor * streak * 0.6;
    }
    
    // Jet polaire (~55°, lat_abs ≈ 0.61)
    float jet_pol_factor = 1.0 - smoothstep(0.0, 0.10, abs(lat_abs - 0.61));
    if (jet_pol_factor > 0.01) {
        float streak_freq = 18.0 / params.cylinder_radius;
        vec3 stretched = coords * vec3(streak_freq * 0.25, streak_freq * 1.8, streak_freq * 0.25);
        float streak = fbm(stretched, 3, 0.55, 2.3, seed + 600000u);
        streak = smoothstep(-0.15, 0.5, streak);
        
        cirrus += jet_pol_factor * streak * 0.5;
    }
    
    return clamp(cirrus, 0.0, 1.0);
}

// ============================================================================
// SYSTÈME 5 : CUMULUS DISPERSÉS
// ============================================================================
// Petits nuages dispersés pour remplir les zones vides

float generateCumulus(vec3 coords, float vapor, uint seed) {
    // Bruit cellulaire inversé pour amas de cumulus
    float cell_freq = 10.0 / params.cylinder_radius;
    float cells = cellularNoise3D(coords * cell_freq, seed + 700000u);
    cells = 1.0 - cells;  // Inverser pour blobs
    cells = smoothstep(0.4, 0.8, cells);
    
    // Moduler par l'humidité/vapeur
    cells *= smoothstep(0.2, 0.6, vapor);
    
    // Détails haute fréquence
    float detail_freq = 25.0 / params.cylinder_radius;
    float detail = valueNoise3D(coords * detail_freq, seed + 710000u);
    detail = (detail + 1.0) * 0.5;
    
    return cells * detail * 0.4;  // Faible intensité
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Skip pour atmosphères sans nuages
    if (params.atmosphere_type == 2u || params.atmosphere_type == 3u) {
        imageStore(clouds_texture, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        return;
    }
    
    // Lire la vapeur simulée
    float vapor = imageLoad(vapor_texture, pixel).r;
    
    // Coordonnées
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    float lon_norm = float(pixel.x) / float(params.width);  // [0, 1]
    float lat_signed = (float(pixel.y) / float(params.height)) * 2.0 - 1.0;  // [-1, 1]
    float lat_abs = abs(lat_signed);
    
    // =========================================================================
    // GÉNÉRATION DES 5 SYSTÈMES
    // =========================================================================
    
    float itcz = generateITCZ(coords, lat_abs, params.seed);
    float fronts = generateMidLatitudeFronts(coords, lat_signed, lon_norm, params.seed);
    float cyclones = generateCyclones(coords, pixel, lat_signed, lon_norm, params.seed);
    float cirrus = generateJetStreamCirrus(coords, lat_abs, lon_norm, params.seed);
    float cumulus = generateCumulus(coords, vapor, params.seed);
    
    // =========================================================================
    // COMBINAISON
    // =========================================================================
    
    // Patterns procéduraux (poids relatifs)
    float procedural = 0.0;
    procedural += itcz * 1.0;        // Poids fort pour ITCZ
    procedural += fronts * 0.9;      // Fronts importants
    procedural += cyclones * 1.2;    // Cyclones très visibles
    procedural += cirrus * 0.5;      // Cirrus subtils
    procedural += cumulus * 0.4;     // Cumulus légers
    
    // Normaliser pour éviter saturation
    procedural = clamp(procedural, 0.0, 1.0);
    
    // Mélange procédural (60%) + vapeur simulée (40%)
    float cloud_density = procedural * 0.6 + vapor * 0.4;
    
    // =========================================================================
    // FONCTION DE TRANSFERT (smoothstep pour contraste)
    // =========================================================================
    
    // Seuil adaptatif
    float threshold = params.condensation_threshold;
    
    // Appliquer smoothstep pour transition douce
    float alpha = smoothstep(threshold - 0.15, threshold + 0.25, cloud_density);
    
    // Boost pour les zones de haute densité
    alpha = alpha * alpha * (3.0 - 2.0 * alpha);  // Smootherstep
    
    // =========================================================================
    // SORTIE
    // =========================================================================
    
    // Blanc avec alpha variable pour effet volumétrique
    vec4 cloud_color = vec4(1.0, 1.0, 1.0, alpha);
    
    imageStore(clouds_texture, pixel, cloud_color);
}
