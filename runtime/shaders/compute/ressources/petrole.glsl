#[compute]
#version 450

// ============================================================================
// OIL SHADER - Génération de Gisements Pétroliers
// ============================================================================
// Génère une carte de pétrole basée sur la géologie :
// - Bassins sédimentaires (zones basses, anciens fonds marins)
// - Présence de pièges structuraux (failles, anticlinaux)
// - Distance à la côte favorable
// Sortie : Noir (pétrole) avec transparence variable, transparent sinon
// Pas de pétrole si atmosphere_type == 3 (sans atmosphère = pas de vie = pas de pétrole)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : Géologie (RGBA32F) - R=height, G=bedrock, B=sediment, A=water_height
layout(set = 0, binding = 0) uniform texture2D geo_texture;
layout(set = 0, binding = 1) uniform sampler geo_sampler;

// Texture de sortie : Pétrole (RGBA8) - RGB=noir, A=opacité
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D oil_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform OilParams {
    uint seed;
    uint width;
    uint height;
    float sea_level;
    float cylinder_radius;
    uint atmosphere_type;
    float oil_probability;    // Probabilité globale (0.025 dans enum.gd)
    float deposit_size;       // Taille moyenne des gisements (200)
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

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

// fBm multi-octave pour bassins sédimentaires
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

// Cellular noise pour structures géologiques (pièges, failles)
vec2 voronoiCellular(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist1 = 1000.0;
    float minDist2 = 1000.0;
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                
                const float BIG_OFFSET = 10000.0;
                ivec3 cell = ivec3(i + neighbor + BIG_OFFSET);
                uint h = hash(uint(cell.x) + seed_offset) ^ hash(uint(cell.y)) ^ hash(uint(cell.z));
                
                vec3 point = neighbor + vec3(rand(h), rand(hash(h + 1u)), rand(hash(h + 2u))) - f;
                float dist = length(point);
                
                if (dist < minDist1) {
                    minDist2 = minDist1;
                    minDist1 = dist;
                } else if (dist < minDist2) {
                    minDist2 = dist;
                }
            }
        }
    }
    
    return vec2(minDist1, minDist2);
}

// Coordonnées cylindriques pour bruit seamless horizontal
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
    
    // Pas de pétrole si pas d'atmosphère (pas de vie organique = pas d'hydrocarbures)
    if (params.atmosphere_type == 3u) {
        imageStore(oil_texture, pixel, vec4(0.0));
        return;
    }
    
    // Lire les données géologiques
    vec2 uv = (vec2(pixel) + 0.5) / vec2(float(params.width), float(params.height));
    vec4 geo_data = texture(sampler2D(geo_texture, geo_sampler), uv);
    
    float elevation = geo_data.r;
    float bedrock = geo_data.g;
    float sediment = geo_data.b;
    float water_height = geo_data.a;
    
    // Déterminer si on est sous l'eau
    bool is_underwater = water_height > 0.1;
    
    // Le pétrole ne se forme que sur terre ou proche des côtes
    // Pas de pétrole en haute mer profonde
    if (is_underwater && elevation < params.sea_level - 500.0) {
        imageStore(oil_texture, pixel, vec4(0.0));
        return;
    }
    
    // Coordonnées cylindriques pour bruit seamless
    vec3 coords = getCylindricalCoords(pixel);
    float noise_scale = 3.0 / params.cylinder_radius;
    
    // === FACTEUR 1 : Bassin sédimentaire ===
    // Le pétrole se forme dans les bassins sédimentaires (zones basses)
    float basin_noise = fbm(coords * noise_scale * 0.3, 5, 0.5, 2.0, params.seed);
    
    // Les zones basses (près du niveau de la mer) sont favorables
    float elevation_factor = 1.0 - smoothstep(params.sea_level - 200.0, params.sea_level + 1000.0, elevation);
    elevation_factor = max(elevation_factor, 0.5); // Base élevée
    
    // === FACTEUR 2 : Présence de sédiments (ancien fond marin) ===
    float sediment_factor = smoothstep(0.0, 50.0, sediment);
    sediment_factor = max(sediment_factor, 0.6); // Base élevée
    
    // === FACTEUR 3 : Pièges structuraux (failles, anticlinaux) ===
    vec2 cell = voronoiCellular(coords * noise_scale * 1.5, params.seed + 50000u);
    float edge_factor = cell.y - cell.x; // Distance aux bordures cellulaires
    float trap_factor = smoothstep(0.1, 0.4, edge_factor);
    
    // === FACTEUR 4 : Distribution aléatoire des gisements ===
    float deposit_noise = fbm(coords * noise_scale * 1.0, 3, 0.6, 2.2, params.seed + 100000u);
    
    // === FACTEUR 5 : Domain warping pour éviter les patterns rectilignes ===
    vec3 warp_offset = vec3(
        fbm(coords * noise_scale * 0.25 + vec3(100.0, 0.0, 0.0), 3, 0.5, 2.0, params.seed + 200000u),
        fbm(coords * noise_scale * 0.25 + vec3(0.0, 100.0, 0.0), 3, 0.5, 2.0, params.seed + 300000u),
        fbm(coords * noise_scale * 0.25 + vec3(0.0, 0.0, 100.0), 3, 0.5, 2.0, params.seed + 400000u)
    ) * 0.5;
    
    float warped_deposit = fbm((coords + warp_offset) * noise_scale * 1.2, 4, 0.5, 2.0, params.seed + 500000u);
    
    // === COMBINER TOUS LES FACTEURS ===
    float combined = basin_noise * 0.3 
                   + deposit_noise * 0.3 
                   + warped_deposit * 0.2
                   + trap_factor * 0.2;
    
    // Appliquer les facteurs géologiques
    combined *= elevation_factor;
    combined *= sediment_factor;
    
    // Seuil très bas pour avoir beaucoup de ressources
    float base_threshold = 0.15;
    
    // Intensité brute de 0 à 1 avec une grande plage
    float raw_intensity = smoothstep(base_threshold, 0.7, combined);
    
    // Moduler par la probabilité : multiplication plus douce
    float probability_factor = pow(params.oil_probability * 40.0, 0.3); // ~0.84 pour 0.025
    raw_intensity *= probability_factor;
    
    // Si sous le seuil minimal, transparent
    if (raw_intensity < 0.02) {
        imageStore(oil_texture, pixel, vec4(0.0));
        return;
    }
    
    // Ajouter variation locale pour la densité
    float local_variation = fbm(coords * noise_scale * 3.0, 2, 0.5, 2.0, params.seed + 600000u);
    float intensity = raw_intensity * mix(0.6, 1.0, local_variation);
    
    // Couleur noire (pétrole) * intensité dans RGB, alpha = intensité
    vec3 oil_color = vec3(0.0, 0.0, 0.0); // Noir
    imageStore(oil_texture, pixel, vec4(oil_color, intensity));
}
