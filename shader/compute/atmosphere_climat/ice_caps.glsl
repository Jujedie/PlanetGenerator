#[compute]
#version 450

// ============================================================================
// SEA-ICE SHADER - Étape 3.4 : Banquise et glace flottante
// ============================================================================
// Génère une concentration de banquise basée sur :
// - Température locale lissée (climate.R)
// - Masses de glace déformées à plusieurs échelles
// - Floes dans la zone marginale et chenaux sombres dans le pack
//
// Cette texture reste strictement maritime : un pixel terrestre est toujours
// transparent. La neige et le givre terrestres sont calculés séparément par
// final_map.glsl à partir du climat et du relief.
//
// Entrées :
// - climate_texture (R=temperature)
// - water_colored (A>0 pour les surfaces liquides)
//
// Sorties :
// - ice_caps_texture : RGBA8 (couleur de banquise, alpha=concentration)
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
// isolé de découper la lisière de la banquise en confettis. Le voisinage reste
// fin en pixels, comme avant f37ffbb, afin qu'un export 4K/8K révèle davantage
// de détail au lieu de fusionner la glace en grands blocs.
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

// La substance gelée et son point de transition dépendent du type de monde.
// Les mers volcaniques sont du magma : elles ne produisent jamais de banquise.
float localColdness(float temperature) {
    if (params.atmosphere_type == 1u) {
        return 1.0 - smoothstep(-55.0, -38.0, temperature); // condensats toxiques
    }
    if (params.atmosphere_type == 2u) {
        return 0.0;
    }
    if (params.atmosphere_type == 3u) {
        return 1.0 - smoothstep(-155.0, -112.0, temperature); // glace de piège froid
    }
    if (params.atmosphere_type == 5u) {
        float water_frost = 1.0 - smoothstep(-58.0, -38.0, temperature);
        float carbon_frost = 1.0 - smoothstep(-105.0, -78.0, temperature);
        return max(water_frost * 0.72, carbon_frost);
    }
    // Conserver la courbe Terran/morte du commit précédent. La transition
    // progressive jusqu'à -11 °C empêche toute la zone froide admissible de
    // devenir instantanément un pack compact.
    return 1.0 - smoothstep(-11.0, 0.5, temperature);
}

void seaIcePalette(
    out vec3 young_ice,
    out vec3 old_ice,
    out vec3 fracture_color
) {
    young_ice = vec3(0.42, 0.59, 0.65);
    old_ice = vec3(0.88, 0.92, 0.91);
    fracture_color = vec3(0.30, 0.46, 0.54);
    if (params.atmosphere_type == 1u) {
        young_ice = vec3(0.48, 0.61, 0.42);
        old_ice = vec3(0.80, 0.87, 0.72);
        fracture_color = vec3(0.27, 0.38, 0.20);
    } else if (params.atmosphere_type == 3u) {
        young_ice = vec3(0.49, 0.61, 0.67);
        old_ice = vec3(0.79, 0.86, 0.89);
        fracture_color = vec3(0.30, 0.39, 0.44);
    } else if (params.atmosphere_type == 4u) {
        young_ice = vec3(0.44, 0.50, 0.47);
        old_ice = vec3(0.75, 0.78, 0.71);
        fracture_color = vec3(0.27, 0.31, 0.28);
    } else if (params.atmosphere_type == 5u) {
        young_ice = vec3(0.57, 0.59, 0.58);
        old_ice = vec3(0.84, 0.85, 0.84);
        fracture_color = vec3(0.38, 0.34, 0.32);
    }
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
    
    // Un masque de banquise ne doit jamais déborder sur la terre. Ce test est
    // volontairement effectué avant toute logique climatique ou bruitée.
    vec4 water = imageLoad(water_colored, pixel);
    if (water.a <= 0.0) {
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }

    // Lisser le champ thermique avant la décision de gel.
    float temperature = smoothedTemperature(pixel);
    
    float probability = clamp(params.ice_probability, 0.0, 1.0);
    float coldness = localColdness(temperature);
    if (probability <= 0.001 || coldness <= 0.001) {
        imageStore(ice_caps_texture, pixel, no_ice_color);
        return;
    }
    
    // === FBM Noise pour variations naturelles ===
    vec3 coords = getCylindricalCoords(pixel, params.width, params.height);
    float cylinder_radius = float(params.width) / 6.28318530718;
    
    vec3 domain = coords / max(cylinder_radius, 1.0);

    // La taille des floes doit diminuer lorsque la carte gagne des pixels.
    // 752x376 est la résolution d'aperçu de référence ; au-delà, la fréquence
    // augmente avec la racine de l'échelle pour ajouter du détail sans faire
    // disparaître la structure climatique générale de la calotte.
    float resolution_ratio = max(
        float(params.width) / 752.0,
        float(params.height) / 376.0
    );
    float detail_scale = resolution_ratio < 1.0
        ? resolution_ratio * 0.88
        : sqrt(resolution_ratio);
    detail_scale = clamp(detail_scale, 0.35, 3.25);

    // Domain warping : les deux champs très larges déforment la lisière sans
    // casser la continuité horizontale de la projection cylindrique.
    float warp_x = fbm(domain * 1.35, 3, 0.55, 2.03, params.seed + 17011u);
    float warp_z = fbm(domain * 1.35, 3, 0.55, 2.03, params.seed + 29021u);
    vec3 warped = domain + vec3(warp_x * 0.30, warp_z * 0.12, warp_z * 0.30);

    float macro_noise = fbm(warped * 3.6, 5, 0.55, 2.02, params.seed + 99991u);
    float floe_noise = fbm(warped * (20.0 * detail_scale), 4, 0.56, 2.05, params.seed + 130003u);
    float micro_floe_noise = fbm(
        warped * (42.0 * detail_scale),
        3,
        0.54,
        2.08,
        params.seed + 150007u
    );
    float surface_noise = fbm(warped * (52.0 * detail_scale), 3, 0.52, 2.10, params.seed + 170003u);
    float lead_noise = fbm(
        warped * (22.0 * detail_scale) + vec3(floe_noise * 0.22),
        4,
        0.56,
        2.03,
        params.seed + 210011u
    );
    float polynya_noise = fbm(
        warped * (12.0 * detail_scale) + vec3(macro_noise * 0.16),
        4,
        0.55,
        2.05,
        params.seed + 260003u
    );

    // La banquise dépend de la température de l'eau ; la proximité des
    // côtes aide seulement sa stabilisation et ne peut créer de glace terrestre.
    float coast_boost = coastalProximity(pixel) * coldness * 0.09;
    float formation = coldness
        + macro_noise * 0.20
        + floe_noise * 0.050
        + micro_floe_noise * 0.025
        + coast_boost;
    // Le paramètre agit linéairement, comme avant la régression. sqrt()
    // surévaluait fortement les petites et moyennes probabilités.
    float formation_threshold = mix(0.86, 0.28, probability);
    float coverage = smoothstep(
        formation_threshold - 0.22,
        formation_threshold + 0.20,
        formation
    );

    // La marge devient un archipel de petits floes. Un second champ plus fin
    // brise les gros polygones sans réduire la concentration du cœur polaire.
    float floe_structure = floe_noise * 0.72 + micro_floe_noise * 0.28;
    float floe_mask = smoothstep(-0.18, 0.15, floe_structure + coverage * 0.42);
    float core_lock = smoothstep(0.58, 0.88, coverage);
    float pack_variation = clamp(
        0.74 + floe_noise * 0.10 + micro_floe_noise * 0.08 + surface_noise * 0.05,
        0.50,
        0.95
    );
    float concentration = coverage * mix(floe_mask * 0.82, pack_variation, core_lock);
    // 0.9 est la valeur de référence historique : son rendu reste inchangé.
    // En dessous, le paramètre contrôle aussi la concentration du pack au
    // lieu de ne déplacer que sa lisière, ce qui le rend visuellement effectif.
    concentration *= clamp(probability / 0.9, 0.0, 1.0);
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

    vec3 young_ice;
    vec3 pack_ice;
    vec3 fracture_color;
    seaIcePalette(young_ice, pack_ice, fracture_color);
    float ice_age = clamp(coldness * 0.56 + concentration * 0.32 + surface_noise * 0.08, 0.0, 1.0);
    float albedo_texture = 0.86 + (surface_noise * 0.5 + 0.5) * 0.15;
    vec3 ice_color = mix(young_ice, pack_ice, ice_age) * albedo_texture;
    ice_color = mix(ice_color, fracture_color, lead_ridge * 0.26 + polynya_ridge * 0.18);
    ice_color = clamp(ice_color, 0.0, 1.0);
    imageStore(ice_caps_texture, pixel, vec4(ice_color, ice_alpha));
}
