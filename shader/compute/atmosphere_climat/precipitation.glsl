#[compute]
#version 450

// ============================================================================
// PRECIPITATION SHADER - Génération d'Humidité Diversifiée
// ============================================================================
// Génère une carte d'humidité avec :
// - Diversité maximale : valeurs RÉELLEMENT de 0.0 à 1.0
// - avg_precipitation contrôle la MOYENNE, pas un seuil
// - Motifs réalistes : déserts, forêts tropicales, climats tempérés
// - Seamless sur cylindre (wrap horizontal)
//
// Sortie : climate_texture.G = humidité [0, 1]
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform image2D climate_texture;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D precipitation_colored;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D geo_texture;

layout(set = 1, binding = 0, std140) uniform PrecipParams {
    uint seed;
    uint width;
    uint height;
    float avg_precipitation;  // [0, 1] - moyenne désirée
    float cylinder_radius;
    uint atmosphere_type;
    float sea_level;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================
const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// ============================================================================
// HASH FUNCTIONS
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

// ============================================================================
// GRADIENT NOISE 3D (Perlin-like)
// ============================================================================

vec3 grad3(uint h) {
    h = h % 12u;
    float u = h < 8u ? 1.0 : 0.0;
    float v = h < 4u ? 1.0 : (h == 12u || h == 14u ? 1.0 : 0.0);
    float a = ((h & 1u) == 0u) ? u : -u;
    float b = ((h & 2u) == 0u) ? v : -v;
    float c = ((h & 4u) == 0u) ? 0.0 : ((h & 8u) == 0u ? 1.0 : -1.0);
    return vec3(a, b, c);
}

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float gradientNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    
    ivec3 ii = ivec3(i) + ivec3(10000);
    uint ix = uint(ii.x) + seed_offset;
    uint iy = uint(ii.y);
    uint iz = uint(ii.z);
    
    // 8 corners
    uint h000 = hash3(ix, iy, iz);
    uint h100 = hash3(ix + 1u, iy, iz);
    uint h010 = hash3(ix, iy + 1u, iz);
    uint h110 = hash3(ix + 1u, iy + 1u, iz);
    uint h001 = hash3(ix, iy, iz + 1u);
    uint h101 = hash3(ix + 1u, iy, iz + 1u);
    uint h011 = hash3(ix, iy + 1u, iz + 1u);
    uint h111 = hash3(ix + 1u, iy + 1u, iz + 1u);
    
    vec3 g000 = grad3(h000);
    vec3 g100 = grad3(h100);
    vec3 g010 = grad3(h010);
    vec3 g110 = grad3(h110);
    vec3 g001 = grad3(h001);
    vec3 g101 = grad3(h101);
    vec3 g011 = grad3(h011);
    vec3 g111 = grad3(h111);
    
    float n000 = dot(g000, f - vec3(0, 0, 0));
    float n100 = dot(g100, f - vec3(1, 0, 0));
    float n010 = dot(g010, f - vec3(0, 1, 0));
    float n110 = dot(g110, f - vec3(1, 1, 0));
    float n001 = dot(g001, f - vec3(0, 0, 1));
    float n101 = dot(g101, f - vec3(1, 0, 1));
    float n011 = dot(g011, f - vec3(0, 1, 1));
    float n111 = dot(g111, f - vec3(1, 1, 1));
    
    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    float nxy0 = mix(nx00, nx10, u.y);
    float nxy1 = mix(nx01, nx11, u.y);
    
    return mix(nxy0, nxy1, u.z);
}

// Fractal Brownian Motion
float fbm(vec3 p, int octaves, float persistence, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 1.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * gradientNoise3D(p, seed_offset + uint(i) * 7919u);
        maxValue += amplitude;
        amplitude *= persistence;
        p *= lacunarity;
    }
    
    return value / maxValue;  // [-1, 1]
}

// ============================================================================
// CELLULAR/WORLEY NOISE (pour zones distinctes)
// ============================================================================

float worley3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    float minDist = 1.0;
    
    for (int dz = -1; dz <= 1; dz++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                vec3 neighbor = vec3(float(dx), float(dy), float(dz));
                ivec3 ii = ivec3(i + neighbor) + ivec3(10000);
                uint h = hash3(uint(ii.x) + seed_offset, uint(ii.y), uint(ii.z));
                
                vec3 point = neighbor + vec3(
                    rand(h),
                    rand(hash(h + 1u)),
                    rand(hash(h + 2u))
                ) - f;
                
                float dist = dot(point, point);  // squared distance
                minDist = min(minDist, dist);
            }
        }
    }
    
    return sqrt(minDist);
}

// ============================================================================
// COORDONNÉES CYLINDRIQUES (seamless horizontal)
// ============================================================================

vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h, float radius) {
    float angle = (float(pixel.x) / float(w)) * TAU;
    return vec3(
        cos(angle) * radius,
        (float(pixel.y) / float(h) - 0.5) * radius * 2.0,
        sin(angle) * radius
    );
}

// ============================================================================
// PALETTE COULEURS
// ============================================================================

vec4 getPrecipitationColor(float p) {
    // 0.0 = très sec (violet), 1.0 = très humide (bleu foncé)
    if (p <= 0.0) return vec4(0.694, 0.094, 0.706, 1.0);
    if (p <= 0.1) return vec4(0.553, 0.078, 0.565, 1.0);
    if (p <= 0.2) return vec4(0.424, 0.086, 0.635, 1.0);
    if (p <= 0.3) return vec4(0.290, 0.094, 0.686, 1.0);
    if (p <= 0.4) return vec4(0.322, 0.102, 0.757, 1.0);
    if (p <= 0.5) return vec4(0.173, 0.106, 0.773, 1.0);
    if (p <= 0.6) return vec4(0.114, 0.200, 0.827, 1.0);
    if (p <= 0.7) return vec4(0.141, 0.224, 0.859, 1.0);
    if (p <= 0.8) return vec4(0.110, 0.286, 0.808, 1.0);
    if (p <= 0.9) return vec4(0.122, 0.310, 0.878, 1.0);
    return vec4(0.192, 0.365, 0.890, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Sans atmosphère = sec
    if (params.atmosphere_type == 3u) {
        vec4 climate = imageLoad(climate_texture, pixel);
        imageStore(climate_texture, pixel, vec4(climate.r, 0.0, 0.0, 0.0));
        imageStore(precipitation_colored, pixel, getPrecipitationColor(0.0));
        return;
    }
    
    // Coordonnées
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    float latitude = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;  // 0=equateur, 1=pôles
    
    // Lecture élévation
    vec4 geo = imageLoad(geo_texture, pixel);
    float elevation = geo.r;
    bool is_water = (elevation < params.sea_level);
    
    // =========================================================================
    // GÉNÉRATION MULTI-ÉCHELLE
    // =========================================================================
    
    // Échelle 1: Grandes zones climatiques (continents humides vs déserts)
    float scale1 = 2.0 / params.cylinder_radius;
    float n1 = fbm(coords * scale1, 5, 0.55, 2.1, params.seed + 1000u);
    // n1 ∈ [-1, 1], on garde ainsi pour contraste
    
    // Échelle 2: Régions (forêts, steppes, etc.)
    float scale2 = 5.0 / params.cylinder_radius;
    float n2 = fbm(coords * scale2, 4, 0.5, 2.0, params.seed + 2000u);
    
    // Échelle 3: Détails locaux
    float scale3 = 12.0 / params.cylinder_radius;
    float n3 = fbm(coords * scale3, 3, 0.45, 2.0, params.seed + 3000u);
    
    // Échelle 4: Worley pour zones distinctes (déserts isolés, oasis)
    float scale4 = 4.0 / params.cylinder_radius;
    float worley = worley3D(coords * scale4, params.seed + 4000u);
    // worley ∈ [0, ~0.9], inverser pour avoir des "poches"
    float w_factor = 1.0 - worley * 1.2;  // [-0.08, 1.0]
    
    // =========================================================================
    // COMBINAISON POUR DIVERSITÉ MAXIMALE
    // =========================================================================
    
    // Combiner les bruits avec des poids qui préservent la variance
    // On veut une distribution qui utilise TOUTE la plage [0, 1]
    float combined = n1 * 0.45 + n2 * 0.30 + n3 * 0.15 + w_factor * 0.10;
    // combined ∈ environ [-0.9, 0.9]
    
    // Normaliser vers [0, 1] avec étirement
    combined = (combined + 1.0) * 0.5;  // [0.05, 0.95] approx
    
    // Étirer pour atteindre les extrêmes
    combined = (combined - 0.5) * 1.3 + 0.5;  // étirement autour de 0.5
    
    // =========================================================================
    // APPLICATION DU PARAMÈTRE avg_precipitation
    // =========================================================================
    // avg_precipitation = 0.0 → planète désertique (shift vers le bas)
    // avg_precipitation = 0.5 → équilibrée
    // avg_precipitation = 1.0 → planète humide (shift vers le haut)
    //
    // On utilise un OFFSET additif pour déplacer la moyenne
    // tout en préservant la variance (la diversité)
    
    float offset = (params.avg_precipitation - 0.5) * 1.0;  // [-0.5, 0.5]
    combined = combined + offset;
    
    // =========================================================================
    // MODULATION LATITUDINALE (subtile, ±10%)
    // =========================================================================
    // ITCZ (equateur) = plus humide
    // Subtropiques (lat 0.25-0.35) = plus sec (Hadley descendant)
    // Tempérées (lat 0.5-0.7) = modéré
    // Polaires = sec (air froid = peu d'humidité)
    
    float lat_mod = 0.0;
    
    if (latitude < 0.1) {
        // Zone équatoriale: +10%
        lat_mod = 0.1 * (1.0 - latitude / 0.1);
    } else if (latitude > 0.2 && latitude < 0.4) {
        // Zone subtropicale: -10% (déserts)
        float t = (latitude - 0.2) / 0.2;
        lat_mod = -0.1 * sin(t * PI);
    } else if (latitude > 0.8) {
        // Zone polaire: -8%
        lat_mod = -0.08 * ((latitude - 0.8) / 0.2);
    }
    
    combined = combined + lat_mod;
    
    // =========================================================================
    // EFFET OCÉAN/CONTINENT
    // =========================================================================
    // L'océan a une humidité atmosphérique plus stable
    // Les continents ont plus de variance
    
    if (is_water) {
        // Océan: légèrement plus humide, moins de variance
        combined = combined * 0.8 + 0.15;
    } else {
        // Terre: garder la variance, légère réduction si altitude élevée
        if (elevation > 2000.0) {
            float alt_factor = min((elevation - 2000.0) / 4000.0, 1.0);
            combined = combined - alt_factor * 0.15;  // montagnes plus sèches côté sous le vent
        }
    }
    
    // =========================================================================
    // CLAMP FINAL ET COURBE DE CONTRASTE
    // =========================================================================
    
    // Appliquer une légère courbe S pour accentuer les extrêmes
    combined = clamp(combined, 0.0, 1.0);
    combined = combined * combined * (3.0 - 2.0 * combined);  // smoothstep-like
    
    // RE-étirer car smoothstep compresse vers 0.5
    combined = (combined - 0.5) * 1.1 + 0.5;
    combined = clamp(combined, 0.0, 1.0);
    
    // =========================================================================
    // ÉCRITURE
    // =========================================================================
    
    vec4 climate = imageLoad(climate_texture, pixel);
    imageStore(climate_texture, pixel, vec4(climate.r, combined, 0.0, 0.0));
    imageStore(precipitation_colored, pixel, getPrecipitationColor(combined));
}
