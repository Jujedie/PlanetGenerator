#[compute]
#version 450

// ============================================================================
// PRECIPITATION SHADER - Zones climatiques réalistes
// ============================================================================
// Génère une carte de précipitation réaliste avec :
// - Grandes zones sèches et humides bien contrastées (bruit à large échelle)
// - Modulation latitudinale (cellules de Hadley simplifiées)
// - Influence de l'altitude et de la proximité océanique
// - avg_precipitation contrôle l'équilibre global sec/humide
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
    float avg_precipitation;  // [0, 1] - équilibre sec/humide global
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
// GRADIENT NOISE 3D
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

// Fractal Brownian Motion - retourne valeur dans [-1, 1]
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
    
    return value / maxValue;
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
    
    // Coordonnées cylindriques pour seamless wrap
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
    
    // Latitude normalisée [0=équateur, 1=pôle]
    float lat = abs((float(pixel.y) / float(params.height)) - 0.5) * 2.0;
    
    // =========================================================================
    // BRUIT STRUCTURÉ - 3 COUCHES PRINCIPALES (pas 10)
    // =========================================================================
    // Utiliser peu de couches avec le FBM interne pour éviter 
    // l'écrasement de variance par le théorème central limite.
    
    float noise_base = 1.0 / params.cylinder_radius;
    
    // --- COUCHE 1 : Continentale (2-4 grandes masses sec/humide) ---
    // C'est la couche dominante qui crée les grands déserts et jungles
    float continental = fbm(coords * noise_base * 0.3, 5, 0.5, 2.0, params.seed + 1000u);
    
    // --- COUCHE 2 : Régionale (modulation moyenne) ---
    float regional = fbm(coords * noise_base * 1.2, 4, 0.5, 2.0, params.seed + 2000u);
    
    // --- COUCHE 3 : Locale (détails fins) ---
    float local_detail = fbm(coords * noise_base * 4.0, 3, 0.5, 2.0, params.seed + 3000u);
    
    // Combinaison pondérée : la couche continentale domine largement
    // Cela garantit de grandes zones cohérentes sèches ou humides
    float noise = continental * 0.65 + regional * 0.25 + local_detail * 0.10;
    
    // =========================================================================
    // MODULATION LATITUDINALE - Cellules de Hadley simplifiées
    // =========================================================================
    // Sur Terre :
    // - Équateur (~0°) : ITCZ, très humide (convergence, air ascendant)
    // - Subtropicaux (~30°) : Très sec (air descendant, déserts)
    // - Latitudes moyennes (~50-60°) : Humide (fronts, dépressions)
    // - Pôles (~90°) : Sec (air froid = peu d'évaporation)
    
    float lat_moisture = 0.0;
    // ITCZ - Équateur : boost humidité
    lat_moisture += 0.25 * exp(-pow((lat - 0.0) / 0.12, 2.0));
    // Subtropicaux : forte réduction (déserts à ~30° = lat 0.33)
    lat_moisture -= 0.30 * exp(-pow((lat - 0.33) / 0.10, 2.0));
    // Latitudes moyennes : boost humidité (~55° = lat 0.61)
    lat_moisture += 0.15 * exp(-pow((lat - 0.61) / 0.12, 2.0));
    // Pôles : sec
    lat_moisture -= 0.20 * smoothstep(0.75, 1.0, lat);
    
    // =========================================================================
    // INFLUENCE DE LA GÉOGRAPHIE
    // =========================================================================
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    float water_height = geo.a;
    bool is_ocean = (water_height > 0.0 && height <= params.sea_level);
    
    // Les océans ont une humidité de base plus élevée (évaporation)
    float ocean_boost = is_ocean ? 0.10 : 0.0;
    
    // L'altitude réduit les précipitations (effet d'ombre pluviométrique simplifié)
    float altitude_above_sea = max(0.0, height - params.sea_level);
    float altitude_penalty = -0.08 * smoothstep(0.0, 5000.0, altitude_above_sea);
    
    // =========================================================================
    // ASSEMBLAGE ET NORMALISATION
    // =========================================================================
    
    // Le bruit brut est dans environ [-0.65, 0.65]
    // On le normalise vers [0, 1] avec un étirement agressif
    float raw = noise * 2.0;  // Étirer vers [-1.3, 1.3]
    float base = clamp(raw * 0.5 + 0.5, 0.0, 1.0);  // Vers [0, 1]
    
    // Appliquer une courbe de contraste sigmoïde pour pousser les valeurs
    // vers les extrêmes (0 et 1) au lieu de rester groupées au centre
    // Cela crée des zones franchement sèches et franchement humides
    float contrast_base = base;
    contrast_base = contrast_base * contrast_base * (3.0 - 2.0 * contrast_base); // smoothstep
    contrast_base = contrast_base * contrast_base * (3.0 - 2.0 * contrast_base); // double smoothstep = fort contraste
    
    // Ajouter les modifications latitudinales et géographiques
    float modified = contrast_base + lat_moisture + ocean_boost + altitude_penalty;
    modified = clamp(modified, 0.0, 1.0);
    
    // =========================================================================
    // APPLICATION DE avg_precipitation
    // =========================================================================
    // avg_precipitation contrôle la balance globale sec/humide.
    // On utilise une courbe de puissance :
    //   avg=0.0 → power = 6.0  → quasi tout à 0 (planète désertique)
    //   avg=0.3 → power = 2.4  → majorité sèche avec quelques zones humides
    //   avg=0.5 → power = 1.0  → distribution équilibrée
    //   avg=0.7 → power ≈ 0.42 → majorité humide
    //   avg=1.0 → power ≈ 0.17 → quasi tout à 1 (planète océanique/humide)
    
    float power = exp2((0.5 - params.avg_precipitation) * 5.0);
    float humidity = pow(modified, power);
    
    // Clamp de sécurité final
    humidity = clamp(humidity, 0.0, 1.0);
    
    // =========================================================================
    // ÉCRITURE
    // =========================================================================
    
    vec4 climate = imageLoad(climate_texture, pixel);
    imageStore(climate_texture, pixel, vec4(climate.r, humidity, 0.0, 0.0));
    imageStore(precipitation_colored, pixel, getPrecipitationColor(humidity));
}
