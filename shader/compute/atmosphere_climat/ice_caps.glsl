#[compute]
#version 450

// ============================================================================
// ICE CAPS SHADER - Étape 3.4 : Génération des Banquises et Glaciers
// ============================================================================
// Génère une concentration de glace de mer basée sur :
// - Température locale lissée (climate.R)
// - Masses de banquise déformées à plusieurs échelles
// - Floes dans la zone marginale et chenaux sombres dans le pack
// - Léger ancrage côtier, sans jamais déposer de glace sur terre
//
// Entrées :
// - geo_texture (R=height, A=water_height)
// - climate_texture (R=temperature)
//
// Sorties :
// - ice_caps_texture : RGBA8 (bleu ivoire, alpha=concentration)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D ice_caps_texture;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D water_colored;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform IceParams {
    uint seed;
    uint width;
    uint height;
    float ice_probability;  // Probabilité de glace si conditions remplies (0.9 par défaut)
    uint atmosphere_type;
    float sea_level;        // Niveau de la mer (m) - seul critère fiable pour eau
    float padding2;
    float padding3;
} params;

// ============================================================================
// FONCTIONS UTILITAIRES - Hash déterministe
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

uint hash2D(uint x, uint y, uint seed) {
    return hash(x ^ hash(y ^ hash(seed)));
}

float rand(uint h) {
    return float(h) / 4294967295.0;
}

// ============================================================================
// FONCTIONS FBM - Bruit cohérent pour glace naturelle
// ============================================================================

// Value Noise 3D
float valueNoise3D(vec3 p, uint seed_offset) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    vec3 u = f * f * (3.0 - 2.0 * f);
    
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

// FBM multi-octaves
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

// Conversion coordonnées cylindriques
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h) {
    float PI = 3.14159265359;
    float TAU = 6.28318530718;
    float cylinder_radius = float(w) / TAU;
    
    float angle = (float(pixel.x) / float(w)) * TAU;
    float cx = cos(angle) * cylinder_radius;
    float cz = sin(angle) * cylinder_radius;
    // CORRIGÉ : facteur PI au lieu de 2.0 pour isotropie du bruit
    float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * PI;
    
    return vec3(cx, cy, cz);
}

ivec2 wrappedPixel(ivec2 pixel) {
    int w = int(params.width);
    int h = int(params.height);
    int wrapped_x = ((pixel.x % w) + w) % w;
    return ivec2(wrapped_x, clamp(pixel.y, 0, h - 1));
}

// Le champ climatique contient volontairement des variations régionales.
// Une petite convolution en croix empêche cependant un pixel chaud/froid
// isolé de découper la lisière de la banquise en confettis.
float smoothedTemperature(ivec2 pixel) {
    float center = imageLoad(climate_texture, wrappedPixel(pixel)).r;
    float north = imageLoad(climate_texture, wrappedPixel(pixel + ivec2(0, -1))).r;
    float south = imageLoad(climate_texture, wrappedPixel(pixel + ivec2(0, 1))).r;
    float west = imageLoad(climate_texture, wrappedPixel(pixel + ivec2(-1, 0))).r;
    float east = imageLoad(climate_texture, wrappedPixel(pixel + ivec2(1, 0))).r;
    return center * 0.50 + (north + south + west + east) * 0.125;
}

// Fraction de terre dans un voisinage 5x5. Dans les mers froides, une faible
// bonification stabilise la glace côtière sans créer de calotte continentale.
float coastalProximity(ivec2 pixel) {
    float land_samples = 0.0;
    float sample_count = 0.0;
    for (int oy = -2; oy <= 2; oy += 2) {
        for (int ox = -2; ox <= 2; ox += 2) {
            if (ox == 0 && oy == 0) {
                continue;
            }
            vec4 water = imageLoad(water_colored, wrappedPixel(pixel + ivec2(ox, oy)));
            land_samples += water.a <= 0.0 ? 1.0 : 0.0;
            sample_count += 1.0;
        }
    }
    return land_samples / max(sample_count, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Couleurs de sortie
    vec4 no_ice_color = vec4(0.0, 0.0, 0.0, 0.0); // Transparent = pas de glace
    
    // Lisser la température avant la décision de gel.
    float temperature = smoothedTemperature(pixel);
    
    // === Condition 1 : Présence d'eau (banquise = glace flottante uniquement) ===
    // On vérifie directement water_colored (source de vérité pour l'eau visible).
    // Ni geo.a (résidus d'érosion) ni sea_level seul ne suffisent.
    vec4 water = imageLoad(water_colored, pixel);
    if (water.a <= 0.0) {
        // Pas d'eau visible sur ce pixel = pas de banquise
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    float probability = clamp(params.ice_probability, 0.0, 1.0);
    if (probability <= 0.001 || temperature > 0.5) {
        // Le paramètre peut désactiver complètement la glace. Une petite
        // tolérance thermique conserve une lisière douce près du point de gel.
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === FBM Noise pour variations naturelles ===
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height);
    float cylinder_radius = float(params.width) / 6.28318530718;
    
    vec3 domain = coords / max(cylinder_radius, 1.0);

    // Domain warping : les deux champs très larges déforment la lisière sans
    // casser la continuité horizontale de la projection cylindrique.
    float warp_x = fbm(domain * 1.35, 3, 0.55, 2.03, params.seed + 17011u);
    float warp_z = fbm(domain * 1.35, 3, 0.55, 2.03, params.seed + 29021u);
    vec3 warped = domain + vec3(warp_x * 0.30, warp_z * 0.12, warp_z * 0.30);

    float macro_noise = fbm(warped * 2.25, 5, 0.55, 2.02, params.seed + 99991u);
    float floe_noise = fbm(warped * 7.5, 4, 0.56, 2.05, params.seed + 130003u);
    float surface_noise = fbm(warped * 18.0, 3, 0.52, 2.10, params.seed + 170003u);
    float lead_noise = fbm(
        warped * 7.8 + vec3(floe_noise * 0.22),
        4,
        0.56,
        2.03,
        params.seed + 210011u
    );
    float polynya_noise = fbm(
        warped * 4.6 + vec3(macro_noise * 0.16),
        4,
        0.55,
        2.05,
        params.seed + 260003u
    );

    // De 0.5 °C à -11 °C : nouvelle glace -> pack compact. Le réglage de
    // probabilité déplace le seuil de formation au lieu d'ajouter des pixels
    // aléatoires, ce qui garantit des masses cohérentes à toute résolution.
    float coldness = 1.0 - smoothstep(-11.0, 0.5, temperature);
    float coast_boost = coastalProximity(pixel) * coldness * 0.09;
    float formation = coldness + macro_noise * 0.20 + floe_noise * 0.065 + coast_boost;
    float formation_threshold = mix(0.86, 0.28, probability);
    float coverage = smoothstep(
        formation_threshold - 0.22,
        formation_threshold + 0.20,
        formation
    );

    // La marge devient un archipel de grands floes. Le cœur du pack reste
    // continu, puis des lignes de niveau très fines ouvrent des chenaux.
    float floe_mask = smoothstep(-0.22, 0.20, floe_noise + coverage * 0.48);
    float core_lock = smoothstep(0.58, 0.88, coverage);
    float pack_variation = clamp(0.76 + floe_noise * 0.13 + surface_noise * 0.06, 0.52, 0.96);
    float concentration = coverage * mix(floe_mask * 0.82, pack_variation, core_lock);
    float lead_ridge = 1.0 - smoothstep(0.040, 0.185, abs(lead_noise + surface_noise * 0.055));
    float polynya_ridge = 1.0 - smoothstep(0.018, 0.090, abs(polynya_noise - 0.08));
    float lead_strength = lead_ridge * mix(0.86, 0.62, coldness) * smoothstep(0.16, 0.72, coverage);
    float polynya_strength = polynya_ridge * mix(0.78, 0.48, coldness) * smoothstep(0.32, 0.88, coverage);
    concentration *= (1.0 - lead_strength) * (1.0 - polynya_strength);

    if (concentration <= 0.10) {
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }

    // Alpha = concentration réelle. Le shader de carte finale peut ainsi
    // afficher des bords translucides et des chenaux au lieu d'un masque dur.
    float ice_alpha = smoothstep(0.10, 0.90, concentration);
    ice_alpha *= mix(0.52, 0.92, clamp(coldness * 0.50 + concentration * 0.50, 0.0, 1.0));
    if (ice_alpha < 0.025) {
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }

    const vec3 YOUNG_ICE = vec3(0.42, 0.59, 0.65);
    const vec3 PACK_ICE = vec3(0.88, 0.91, 0.86);
    float ice_age = clamp(coldness * 0.56 + concentration * 0.32 + surface_noise * 0.08, 0.0, 1.0);
    float albedo_texture = 0.86 + (surface_noise * 0.5 + 0.5) * 0.15;
    vec3 ice_color = mix(YOUNG_ICE, PACK_ICE, ice_age) * albedo_texture;
    ice_color = mix(ice_color, vec3(0.30, 0.46, 0.54), lead_ridge * 0.26 + polynya_ridge * 0.18);
    ice_color = clamp(ice_color, 0.0, 1.0);
    imageStore(ice_caps_texture, pixel, vec4(ice_color, ice_alpha));
}
