#[compute]
#version 450

// ============================================================================
// CLOUDS SHADER - Génération de Nuages Procéduraux
// ============================================================================
// Génère des amas nuageux stylisés et seamless basés sur du bruit fBm.
// Sortie : texture RGBA en alpha droit (RGB=blanc nuage, A=opacité), avec
// RGBA=(0,0,0,0) dans le ciel clair, directement exploitable dans le jeu.
// Pas de nuages si atmosphere_type == 3 (sans atmosphère)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture de sortie : Nuages (RGBA8) - RGB=couleur, A=opacité
layout(set = 0, binding = 0, rgba8) uniform writeonly image2D clouds_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform CloudsParams {
    uint seed;
    uint width;
    uint height;
    float cloud_coverage;    // Couverture nuageuse [0, 1] (0.5 = 50%)
    float cylinder_radius;   // Pour bruit seamless
    uint atmosphere_type;    // 0=Terre, 1=Toxique, 2=Volcanique, 3=Sans atm
    float cloud_density;     // Densité des nuages [0, 1]
    float padding1;
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
    
    return mix(xy0, xy1, u.z);
}

/// fBm multi-octave pour nuages réalistes
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

/// Coordonnées cylindriques pour bruit seamless (wrap horizontal)
vec3 getCylindricalCoords(ivec2 pixel) {
    float angle = (float(pixel.x) / float(params.width)) * TAU;
    float cx = cos(angle) * params.cylinder_radius;
    float cz = sin(angle) * params.cylinder_radius;
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(params.height) - 0.5) * params.cylinder_radius * PI;
    return vec3(cx, cy, cz);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Pas de nuages si pas d'atmosphère
    if (params.atmosphere_type == 3u) {
        imageStore(clouds_texture, pixel, vec4(0.0));
        return;
    }
    
    // Coordonnées pour bruit seamless. La fréquence est exprimée dans l'espace
    // de la planète : une exportation plus grande révèle davantage de détail
    // au lieu d'agrandir les mêmes taches cotonneuses.
    vec3 coords = getCylindricalCoords(pixel);
    float resolution_scale = clamp(
        sqrt(max(float(params.width) / 2048.0, float(params.height) / 1024.0)),
        0.82,
        2.4
    );
    float noise_scale = (9.5 * resolution_scale) / max(params.cylinder_radius, 1.0);
    
    // Latitude pour variation des nuages
    float latitude = (float(pixel.y) / float(params.height) - 0.5) * 2.0;
    float lat = abs(latitude);

    // Deux déformations emboîtées donnent aux fronts leurs crochets et leurs
    // spirales. Toutes les coordonnées restent cylindriques, donc la couture
    // longitudinale demeure continue.
    vec3 p = coords * noise_scale;
    vec3 broad_warp = vec3(
        fbm(p * 0.18, 3, 0.55, 2.0, params.seed + 41000u),
        fbm(p * 0.18, 3, 0.55, 2.0, params.seed + 42000u),
        fbm(p * 0.18, 3, 0.55, 2.0, params.seed + 43000u)
    );
    p += (broad_warp - 0.5) * 2.25;
    vec3 curl_warp = vec3(
        fbm(p * 0.46, 3, 0.56, 2.03, params.seed + 51000u),
        fbm(p * 0.46, 3, 0.56, 2.03, params.seed + 52000u),
        fbm(p * 0.46, 3, 0.56, 2.03, params.seed + 53000u)
    );
    p += (curl_warp - 0.5) * 0.92;

    // Les systèmes frontaux sont étirés zonalement et cisaillés en sens
    // opposés dans chaque hémisphère (circulation générale simplifiée).
    vec3 front_p = p;
    front_p.y *= 1.35;
    front_p.xz *= 0.90;
    front_p.x += latitude * 0.80;
    
    // === Couche 1 : Grandes structures nuageuses ===
    float synoptic_moisture = fbm(p * 0.44, 5, 0.52, 2.0, params.seed);
    
    // === Couche 2 : Détails moyens ===
    float frontal_field = fbm(front_p * 0.92, 5, 0.55, 2.08, params.seed + 10000u);
    
    // === Couche 3 : Petits détails (wisps) ===
    float fine_details = fbm(p * 5.6, 3, 0.58, 2.0, params.seed + 20000u);
    float cellular_field = fbm(p * 2.25, 4, 0.54, 2.1, params.seed + 26000u);
    
    // Les bandes principales suivent des lignes de niveau étroites du champ
    // frontal. Le champ synoptique décide où elles peuvent se développer ; le
    // bruit cellulaire les brise en systèmes distincts au lieu de continents.
    float front_distance = abs(frontal_field - 0.51);
    float frontal_filaments = 1.0 - smoothstep(0.035, 0.235, front_distance);
    float secondary_filaments = 1.0 - smoothstep(
        0.025,
        0.135,
        abs(frontal_field + (fine_details - 0.5) * 0.16 - 0.37)
    );
    float moisture_gate = smoothstep(0.31, 0.69, synoptic_moisture);
    float broken_cells = smoothstep(0.34, 0.72, cellular_field);
    float cloud_noise = synoptic_moisture * 0.45
        + frontal_filaments * 0.16
        + secondary_filaments * 0.04
        + broken_cells * 0.24
        + fine_details * 0.11;
    cloud_noise *= mix(0.58, 1.08, moisture_gate);
    
    // === Modulation par latitude (plus de nuages aux latitudes moyennes) ===
    // Équateur : quelques nuages (ITCZ)
    // Subtropicaux (0.3) : moins de nuages (haute pression)
    // Latitudes moyennes (0.5-0.7) : plus de nuages (fronts)
    // Pôles : moins de nuages (air froid sec)
    
    float itcz = exp(-pow(lat / 0.11, 2.0));
    float subtropical_dry = exp(-pow((lat - 0.28) / 0.11, 2.0));
    float storm_tracks = exp(-pow((lat - 0.56) / 0.16, 2.0));
    float polar_dry = smoothstep(0.78, 1.0, lat);
    float circulation = itcz * 0.08 - subtropical_dry * 0.10
        + storm_tracks * 0.08 - polar_dry * 0.10;
    cloud_noise += circulation;
    
    // === Seuillage pour créer des nuages distincts ===
    // Le seuil dépend de la couverture nuageuse souhaitée
    float threshold = mix(0.68, 0.16, clamp(params.cloud_coverage, 0.0, 1.0));
    
    // Appliquer le seuil avec transition douce
    float cloud_alpha = smoothstep(threshold - 0.055, threshold + 0.115, cloud_noise);
    float textured_edge = smoothstep(0.23, 0.76, fine_details * 0.55 + broken_cells * 0.45);
    cloud_alpha *= mix(0.34, 1.0, textured_edge);
    
    // Moduler par la densité
    cloud_alpha *= mix(0.28, 0.92, clamp(params.cloud_density, 0.0, 1.0));
    
    // Ajouter variation de densité interne aux nuages
    if (cloud_alpha > 0.0) {
        float density_variation = fbm(p * 3.4, 3, 0.5, 2.0, params.seed + 30000u);
        cloud_alpha *= 0.58 + density_variation * 0.42;
    }
    
    // Un seuil franc garantit de vrais pixels transparents dans le ciel clair.
    cloud_alpha = clamp(cloud_alpha, 0.0, 1.0);
    if (cloud_alpha < 0.025) cloud_alpha = 0.0;
    
    // Vue orbitale : les bords fins sont gris bleuté et les noyaux optiquement
    // épais approchent le blanc. Les autres atmosphères gardent une légère
    // signature sans modifier l'alpha physique du nuage.
    float optical_depth = smoothstep(0.06, 0.78, cloud_alpha);
    vec3 cloud_shadow = vec3(0.66, 0.70, 0.73);
    vec3 cloud_top = vec3(0.97, 0.98, 0.985);
    if (params.atmosphere_type == 1u) {
        cloud_shadow = vec3(0.62, 0.61, 0.48);
        cloud_top = vec3(0.91, 0.86, 0.66);
    } else if (params.atmosphere_type == 2u) {
        cloud_shadow = vec3(0.39, 0.34, 0.32);
        cloud_top = vec3(0.70, 0.66, 0.61);
    } else if (params.atmosphere_type == 4u) {
        cloud_shadow = vec3(0.52, 0.55, 0.53);
        cloud_top = vec3(0.82, 0.83, 0.79);
    } else if (params.atmosphere_type == 5u) {
        cloud_shadow = vec3(0.59, 0.53, 0.47);
        cloud_top = vec3(0.84, 0.79, 0.72);
    }
    float cloud_luminance = clamp(optical_depth * 0.82 + fine_details * 0.18, 0.0, 1.0);
    vec3 cloud_rgb = cloud_alpha > 0.0
        ? mix(cloud_shadow, cloud_top, cloud_luminance)
        : vec3(0.0);
    imageStore(clouds_texture, pixel, vec4(cloud_rgb, cloud_alpha));
}
