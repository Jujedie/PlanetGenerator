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

// === SET 2: PALETTE DE COULEURS DYNAMIQUE (SSBO) ===
// Construite depuis les biomes dans Enum.gd
// Chaque entrée = 16 bytes : float threshold, float r, float g, float b
struct PaletteEntry {
    float threshold;
    float r;
    float g;
    float b;
};

layout(set = 2, binding = 0, std430) readonly buffer ColorPalette {
    uint entry_count;
    uint _pad1;
    uint _pad2;
    uint _pad3;
    PaletteEntry entries[];
};

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

// Ridge Noise - crée des crêtes anguleuses au lieu de formes arrondies
// Utilisé pour briser la rondeur naturelle du fBm
float ridgedFbm(vec3 p, int octaves, float persistence, float lacunarity, uint seed_offset) {
    float value = 0.0;
    float amplitude = 1.0;
    float maxValue = 0.0;
    float weight = 1.0;
    
    for (int i = 0; i < octaves; i++) {
        float n = gradientNoise3D(p, seed_offset + uint(i) * 7919u);
        // Transformation ridge : abs() crée des crêtes, 1-abs donne des vallées pointues
        n = 1.0 - abs(n);
        n = n * n;  // Accentuer les crêtes
        n *= weight;
        weight = clamp(n, 0.0, 1.0);  // Les crêtes précédentes influencent les suivantes
        
        value += amplitude * n;
        maxValue += amplitude;
        amplitude *= persistence;
        p *= lacunarity;
    }
    
    return (value / maxValue) * 2.0 - 1.0;  // Normaliser vers [-1, 1]
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
// PALETTE COULEURS - Interpolation dynamique depuis SSBO
// ============================================================================
// Les couleurs sont construites depuis les biomes actifs du type de planète
// Interpolation linéaire entre les entrées de la palette

vec4 getPrecipitationColor(float p) {
    // Fallback si palette vide
    if (entry_count == 0u) return vec4(1.0, 0.0, 1.0, 1.0);  // Magenta = erreur
    
    // Sous le premier seuil → couleur du premier seuil
    if (p <= entries[0].threshold) {
        return vec4(entries[0].r, entries[0].g, entries[0].b, 1.0);
    }
    
    // Trouver le seuil précédent (pas d'interpolation, couleur fixe par palier)
    for (uint i = 0u; i < entry_count - 1u; i++) {
        if (p <= entries[i + 1u].threshold) {
            // Retourner la couleur du seuil précédent (entries[i])
            return vec4(entries[i].r, entries[i].g, entries[i].b, 1.0);
        }
    }
    
    // Au-dessus du dernier seuil → couleur du dernier seuil
    uint last = entry_count - 1u;
    return vec4(entries[last].r, entries[last].g, entries[last].b, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Sans atmosphère (3) ou Stérile (5) = sec, pas de précipitations
    if (params.atmosphere_type == 3u || params.atmosphere_type == 5u) {
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
    // DOMAIN WARPING - Distorsion des coordonnées pour briser les formes rondes
    // =========================================================================
    // Le domain warping déforme l'espace d'entrée du bruit, créant des
    // frontières irrégulières et des formes étirées au lieu de blobs ronds.
    
    float noise_base = 1.0 / params.cylinder_radius;
    float warp_scale = noise_base * 0.6;
    
    // Première passe de warping
    float warp_x = fbm(coords * warp_scale, 3, 0.5, 2.0, params.seed + 5000u);
    float warp_y = fbm(coords * warp_scale + vec3(5.2, 1.3, 2.8), 3, 0.5, 2.0, params.seed + 5100u);
    float warp_z = fbm(coords * warp_scale + vec3(2.7, 8.1, 4.3), 3, 0.5, 2.0, params.seed + 5200u);
    
    float warp_strength = 0.35 * params.cylinder_radius;
    vec3 warped_coords = coords + vec3(warp_x, warp_y, warp_z) * warp_strength;
    
    // =========================================================================
    // BRUIT STRUCTURÉ - 4 COUCHES avec domain warping et ridge noise
    // =========================================================================
    
    // --- COUCHE 1 : Continentale (grandes masses sec/humide, warpées) ---
    float continental = fbm(warped_coords * noise_base * 0.3, 5, 0.5, 2.0, params.seed + 1000u);
    
    // --- COUCHE 2 : Régionale (modulation moyenne, warpée) ---
    float regional = fbm(warped_coords * noise_base * 1.2, 4, 0.5, 2.0, params.seed + 2000u);
    
    // --- COUCHE 3 : Locale (détails fins, non warpée pour garder le detail) ---
    float local_detail = fbm(coords * noise_base * 4.0, 3, 0.5, 2.0, params.seed + 3000u);
    
    // --- COUCHE 4 : Ridge noise (contours anguleux, brise la rondeur) ---
    float ridge = ridgedFbm(warped_coords * noise_base * 1.5, 4, 0.5, 2.0, params.seed + 4000u);
    
    // Combinaison pondérée avec ridge noise pour casser la rondeur
    // Le ridge noise crée des frontières en crêtes au lieu de transitions lisses
    float noise = continental * 0.45 + regional * 0.20 + local_detail * 0.15 + ridge * 0.20;
    
    // =========================================================================
    // MODULATION LATITUDINALE - Cellules de Hadley simplifiées
    // =========================================================================
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
    float raw = noise * 2.0;
    float base = clamp(raw * 0.5 + 0.5, 0.0, 1.0);
    
    // UN SEUL smoothstep pour un contraste modéré (au lieu de double)
    // Le double smoothstep écrasait la distribution vers les extrêmes trop vite
    float contrast_base = base * base * (3.0 - 2.0 * base);
    
    // Ajouter les modifications latitudinales et géographiques
    float modified = contrast_base + lat_moisture + ocean_boost + altitude_penalty;
    modified = clamp(modified, 0.0, 1.0);
    
    // =========================================================================
    // APPLICATION DE avg_precipitation
    // =========================================================================
    // Amplification réduite (3.0 au lieu de 5.0) pour éviter que les extrêmes
    // ne soient atteints trop rapidement quand on s'éloigne de avg=0.5
    //   avg=0.0 → power = 8.0  → très sec mais pas totalement écrasé
    //   avg=0.3 → power = 1.74 → majorité sèche avec zones humides
    //   avg=0.5 → power = 1.0  → distribution équilibrée
    //   avg=0.7 → power ≈ 0.57 → majorité humide
    //   avg=1.0 → power ≈ 0.125 → très humide
    
    float power = exp2((0.5 - params.avg_precipitation) * 3.0);
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
