#[compute]
#version 450

// ============================================================================
// BIOME CLASSIFICATION SHADER
// Classifies each pixel into a biome based on climate and terrain data.
// Logic matching BiomeMapGenerator.gd + enum.gd getBiomeByNoise()
// Outputs: biome_colored texture with non-realistic colors (get_couleur())
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0) uniform texture2D geo_texture;
layout(set = 0, binding = 1) uniform sampler geo_sampler;
layout(set = 0, binding = 2) uniform texture2D climate_texture;
layout(set = 0, binding = 3) uniform sampler climate_sampler;
layout(set = 0, binding = 4, rgba8) uniform readonly image2D ice_caps;
layout(set = 0, binding = 5, r32f) uniform readonly image2D river_flux_texture;
layout(set = 0, binding = 6, rgba8) uniform writeonly image2D biome_colored;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    uint width;
    uint height;
    uint atmosphere_type;  // 0=default, 1=toxic, 2=volcanic, 3=no_atmo, 4=dead
    float river_threshold;
    float sea_level;
    float biome_noise_frequency;
    float padding;
};

// ============================================================================
// CONSTANTS
// ============================================================================

const float PI = 3.14159265359;
const int ALTITUDE_MAX = 25000;

// Maximum number of candidate biomes for selection
const int MAX_CANDIDATES = 16;

// ============================================================================
// NOISE FUNCTIONS - Matching FastNoiseLite FBM behavior
// ============================================================================

vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x*34.0)+1.0)*x); }

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// FBM matching FastNoiseLite with fractal_octaves=3, gain=0.4, lacunarity=2.0
float fbm_biome(vec2 p, float freq, uint s) {
    float value = 0.0;
    float amplitude = 1.0;
    float max_amp = 0.0;
    vec2 offset = vec2(float(s) * 0.31, float(s) * 0.47);
    
    for (int i = 0; i < 3; i++) {
        value += amplitude * snoise((p + offset) * freq);
        max_amp += amplitude;
        amplitude *= 0.4;
        freq *= 2.0;
    }
    
    return (value / max_amp + 1.0) * 0.5;  // Normalize to [0, 1]
}

// Detail noise for border irregularity - matching detail_noise from legacy
// frequency = 25.0 / width, octaves=4, gain=0.5, lacunarity=2.0
float fbm_detail(vec2 p, float freq, uint s) {
    float value = 0.0;
    float amplitude = 1.0;
    float max_amp = 0.0;
    vec2 offset = vec2(float(s) * 0.73, float(s) * 0.19);
    
    for (int i = 0; i < 4; i++) {
        value += amplitude * snoise((p + offset) * freq);
        max_amp += amplitude;
        amplitude *= 0.5;
        freq *= 2.0;
    }
    
    return (value / max_amp + 1.0) * 0.5;
}

// Additional noise for climate perturbation - creates irregular biome boundaries
float climate_perturb_noise(vec2 p, uint s) {
    vec2 offset = vec2(float(s) * 1.23, float(s) * 0.89);
    float freq = 12.0 / float(width);  // Medium scale perturbation
    
    float n1 = snoise((p + offset) * freq);
    float n2 = snoise((p + offset * 1.7) * freq * 2.3);
    
    return (n1 + n2 * 0.5) / 1.5;  // Returns [-1, 1]
}

// ============================================================================
// BIOME COLOR DEFINITIONS (get_couleur() from enum.gd)
// ============================================================================

// === DEFAULT TYPE (0) - Non-river biomes ===
const vec4 COL_BANQUISE = vec4(0.749, 0.745, 0.733, 1.0);           // 0xbfbebb
const vec4 COL_OCEAN = vec4(0.145, 0.322, 0.541, 1.0);              // 0x25528a
const vec4 COL_LAC = vec4(0.271, 0.518, 0.824, 1.0);                // 0x4584d2
const vec4 COL_ZONE_COTIERE = vec4(0.157, 0.376, 0.647, 1.0);       // 0x2860a5
const vec4 COL_ZONE_HUMIDE = vec4(0.259, 0.361, 0.482, 1.0);        // 0x425c7b
const vec4 COL_RECIF = vec4(0.310, 0.541, 0.569, 1.0);              // 0x4f8a91
const vec4 COL_LAGUNE = vec4(0.227, 0.400, 0.420, 1.0);             // 0x3a666b
const vec4 COL_DESERT_CRYO = vec4(0.867, 0.875, 0.890, 1.0);        // 0xdddfe3
const vec4 COL_GLACIER = vec4(0.780, 0.804, 0.839, 1.0);            // 0xc7cdd6
const vec4 COL_DESERT_ARTIQUE = vec4(0.671, 0.698, 0.745, 1.0);     // 0xabb2be
const vec4 COL_CALOTTE = vec4(0.580, 0.612, 0.663, 1.0);            // 0x949ca9
const vec4 COL_TOUNDRA = vec4(0.796, 0.694, 0.373, 1.0);            // 0xcbb15f
const vec4 COL_TOUNDRA_ALPINE = vec4(0.718, 0.620, 0.314, 1.0);     // 0xb79e50
const vec4 COL_TAIGA = vec4(0.278, 0.420, 0.243, 1.0);              // 0x476b3e
const vec4 COL_FORET_MONTAGNE = vec4(0.310, 0.541, 0.251, 1.0);     // 0x4f8a40
const vec4 COL_FORET_TEMPEREE = vec4(0.396, 0.769, 0.306, 1.0);     // 0x65c44e
const vec4 COL_PRAIRIE = vec4(0.561, 0.878, 0.486, 1.0);            // 0x8fe07c
const vec4 COL_MEDITERRANEE = vec4(0.290, 0.384, 0.278, 1.0);       // 0x4a6247
const vec4 COL_STEPPES_SECHES = vec4(0.624, 0.565, 0.459, 1.0);     // 0x9f9075
const vec4 COL_STEPPES_TEMPEREES = vec4(0.514, 0.463, 0.373, 1.0);  // 0x83765f
const vec4 COL_FORET_TROPICALE = vec4(0.106, 0.353, 0.129, 1.0);    // 0x1b5a21
const vec4 COL_SAVANE = vec4(0.635, 0.455, 0.259, 1.0);             // 0xa27442
const vec4 COL_SAVANE_ARBRES = vec4(0.580, 0.420, 0.243, 1.0);      // 0x946b3e
const vec4 COL_DESERT_SEMI = vec4(0.745, 0.620, 0.361, 1.0);        // 0xbe9e5c
const vec4 COL_DESERT = vec4(0.580, 0.341, 0.141, 1.0);             // 0x945724
const vec4 COL_DESERT_ARIDE = vec4(0.514, 0.286, 0.169, 1.0);       // 0x83492b
const vec4 COL_DESERT_MORT = vec4(0.431, 0.220, 0.145, 1.0);        // 0x6e3825

// === DEFAULT TYPE (0) - River biomes ===
const vec4 COL_RIVIERE = vec4(0.290, 0.565, 0.851, 1.0);            // 0x4A90D9
const vec4 COL_FLEUVE = vec4(0.243, 0.498, 0.769, 1.0);             // 0x3E7FC4
const vec4 COL_AFFLUENT = vec4(0.420, 0.667, 0.898, 1.0);           // 0x6BAAE5
const vec4 COL_LAC_DOUCE = vec4(0.357, 0.639, 0.878, 1.0);          // 0x5BA3E0
const vec4 COL_LAC_GELE = vec4(0.659, 0.831, 0.902, 1.0);           // 0xA8D4E6
const vec4 COL_RIVIERE_GLACIAIRE = vec4(0.494, 0.784, 0.890, 1.0);  // 0x7EC8E3

// === TOXIC TYPE (1) ===
const vec4 COL_BANQUISE_TOXIC = vec4(0.282, 0.839, 0.231, 1.0);     // 0x48d63b
const vec4 COL_OCEAN_TOXIC = vec4(0.196, 0.608, 0.514, 1.0);        // 0x329b83
const vec4 COL_MARECAGE_ACIDE = vec4(0.208, 0.608, 0.227, 1.0);     // 0x359b3a
const vec4 COL_DESERT_SOUFRE = vec4(0.471, 0.553, 0.161, 1.0);      // 0x788d29
const vec4 COL_GLACIER_TOXIC = vec4(0.678, 0.796, 0.271, 1.0);      // 0xadcb45
const vec4 COL_TOUNDRA_TOXIC = vec4(0.514, 0.580, 0.294, 1.0);      // 0x83944b
const vec4 COL_FORET_FONGIQUE = vec4(0.192, 0.459, 0.212, 1.0);     // 0x317536
const vec4 COL_PLAINE_TOXIC = vec4(0.216, 0.553, 0.243, 1.0);       // 0x378d3e
const vec4 COL_SOLFATARE = vec4(0.239, 0.459, 0.259, 1.0);          // 0x3d7542
// Toxic rivers
const vec4 COL_RIVIERE_ACIDE = vec4(0.357, 0.769, 0.353, 1.0);      // 0x5BC45A
const vec4 COL_FLEUVE_TOXIC = vec4(0.282, 0.722, 0.278, 1.0);       // 0x48B847
const vec4 COL_LAC_ACIDE = vec4(0.431, 0.851, 0.427, 1.0);          // 0x6ED96D
const vec4 COL_LAC_TOXIC_GELE = vec4(0.722, 0.902, 0.718, 1.0);     // 0xB8E6B7

// === VOLCANIC TYPE (2) ===
const vec4 COL_LAVE_REFROIDIE = vec4(0.718, 0.420, 0.055, 1.0);     // 0xb76b0e
const vec4 COL_CHAMPS_LAVE = vec4(0.839, 0.588, 0.090, 1.0);        // 0xd69617
const vec4 COL_LAC_MAGMA = vec4(0.718, 0.286, 0.055, 1.0);          // 0xb7490e
const vec4 COL_DESERT_CENDRES = vec4(0.867, 0.490, 0.075, 1.0);     // 0xdd7d13
const vec4 COL_PLAINE_ROCHES = vec4(0.812, 0.455, 0.063, 1.0);      // 0xcf7410
const vec4 COL_MONTAGNE_VOLCANIQUE = vec4(0.608, 0.388, 0.149, 1.0);// 0x9b6326
const vec4 COL_PLAINE_VOLCANIQUE = vec4(0.596, 0.329, 0.039, 1.0);  // 0x98540a
const vec4 COL_TERRASSE_MINERALE = vec4(0.580, 0.333, 0.067, 1.0);  // 0x945511
const vec4 COL_VOLCAN_ACTIF = vec4(0.365, 0.267, 0.157, 1.0);       // 0x5d4428
const vec4 COL_FUMEROLLE = vec4(0.282, 0.220, 0.145, 1.0);          // 0x483825
// Volcanic rivers
const vec4 COL_RIVIERE_LAVE = vec4(1.0, 0.420, 0.102, 1.0);         // 0xFF6B1A
const vec4 COL_FLEUVE_MAGMA = vec4(0.910, 0.353, 0.059, 1.0);       // 0xE85A0F
const vec4 COL_LAVE_SOLIDIFIEE = vec4(0.627, 0.322, 0.176, 1.0);    // 0xA0522D
const vec4 COL_BASSIN_REFROIDI = vec4(0.545, 0.271, 0.075, 1.0);    // 0x8B4513

// === DEAD TYPE (4) ===
const vec4 COL_BANQUISE_MORTE = vec4(0.851, 0.820, 0.800, 1.0);     // 0xd9d1cc
const vec4 COL_MARECAGE_LUMINESCENT = vec4(0.380, 0.624, 0.388, 1.0);// 0x619f63
const vec4 COL_OCEAN_MORT = vec4(0.286, 0.475, 0.290, 1.0);         // 0x49794a
const vec4 COL_DESERT_SEL = vec4(0.851, 0.796, 0.627, 1.0);         // 0xd9cba0
const vec4 COL_PLAINE_CENDRES = vec4(0.161, 0.157, 0.149, 1.0);     // 0x292826
const vec4 COL_CRATERE_NUCLEAIRE = vec4(0.204, 0.200, 0.192, 1.0);  // 0x343331
const vec4 COL_TERRE_DESOLEE = vec4(0.502, 0.475, 0.412, 1.0);      // 0x807969
const vec4 COL_FORET_MUTANTE = vec4(0.525, 0.439, 0.282, 1.0);      // 0x867048
const vec4 COL_PLAINE_POUSSIERE = vec4(0.663, 0.549, 0.349, 1.0);   // 0xa98c59
// Dead rivers
const vec4 COL_RIVIERE_STAGNANTE = vec4(0.353, 0.478, 0.357, 1.0);  // 0x5A7A5B
const vec4 COL_FLEUVE_POLLUE = vec4(0.290, 0.416, 0.294, 1.0);      // 0x4A6A4B
const vec4 COL_LAC_IRRADIE = vec4(0.420, 0.545, 0.424, 1.0);        // 0x6B8B6C
const vec4 COL_LAC_BOUE = vec4(0.545, 0.451, 0.333, 1.0);           // 0x8B7355

// === NO ATMOSPHERE TYPE (3) ===
const vec4 COL_DESERT_ROCHEUX = vec4(0.459, 0.451, 0.435, 1.0);     // 0x75736f
const vec4 COL_REGOLITHE = vec4(0.404, 0.400, 0.384, 1.0);          // 0x676662
const vec4 COL_FOSSE_IMPACT = vec4(0.365, 0.361, 0.349, 1.0);       // 0x5d5c59

// Fallback color (magenta for errors)
const vec4 COL_FALLBACK = vec4(1.0, 0.0, 1.0, 1.0);

// ============================================================================
// RIVER BIOME CLASSIFICATION
// Matching enum.gd getRiverBiome() and getRiverBiomeBySize()
// ============================================================================

vec4 classifyRiverBiome(int temp, float flux, float max_flux, uint atmo) {
    // Normalize flux for size classification
    float flux_ratio = flux / max(max_flux, 0.001);
    
    if (atmo == 0u) {  // Default
        if (temp < -30) return COL_RIVIERE_GLACIAIRE;
        if (temp < 0) return COL_LAC_GELE;
        // Size-based selection
        if (flux_ratio > 0.7) return COL_FLEUVE;
        if (flux_ratio > 0.3) return COL_RIVIERE;
        return COL_AFFLUENT;
    }
    else if (atmo == 1u) {  // Toxic
        if (temp < 0) return COL_LAC_TOXIC_GELE;
        if (flux_ratio > 0.5) return COL_FLEUVE_TOXIC;
        return COL_RIVIERE_ACIDE;
    }
    else if (atmo == 2u) {  // Volcanic
        if (temp < 30) return COL_LAVE_SOLIDIFIEE;
        if (temp < 50) return COL_BASSIN_REFROIDI;
        if (flux_ratio > 0.5) return COL_FLEUVE_MAGMA;
        return COL_RIVIERE_LAVE;
    }
    else if (atmo == 4u) {  // Dead
        if (flux_ratio > 0.5) return COL_FLEUVE_POLLUE;
        return COL_RIVIERE_STAGNANTE;
    }
    return COL_RIVIERE;  // Fallback
}

// ============================================================================
// BANQUISE BIOME
// Matching enum.gd getBanquiseBiome()
// ============================================================================

vec4 getBanquiseColor(uint atmo) {
    if (atmo == 0u) return COL_BANQUISE;
    if (atmo == 1u) return COL_BANQUISE_TOXIC;
    if (atmo == 2u) return COL_LAVE_REFROIDIE;
    if (atmo == 3u) return COL_BANQUISE_MORTE;  // No atmo uses dead banquise
    if (atmo == 4u) return COL_BANQUISE_MORTE;
    return COL_BANQUISE;
}

// ============================================================================
// BIOME CLASSIFICATION
// Matching enum.gd getBiomeByNoise() logic with noise perturbation
// for more natural, irregular biome boundaries
// ============================================================================

vec4 classifyBiome(int elevation, float precipitation, int temperature, 
                   bool is_water, uint atmo, float noise_val, float perturb_noise) {
    
    // Apply noise perturbation to climate values for more natural boundaries
    // This creates gradual transitions instead of hard rectangular lines
    float temp_perturb = perturb_noise * 8.0;  // +/- 4 degrees
    float precip_perturb = perturb_noise * 0.2;  // +/- 0.1
    float elev_perturb = perturb_noise * 150.0;  // +/- 75m
    
    int temp = temperature + int(temp_perturb);
    float precip = clamp(precipitation + precip_perturb, 0.0, 1.0);
    int elev = elevation + int(elev_perturb);
    
    // Candidate biomes and count
    vec4 candidates[MAX_CANDIDATES];
    int count = 0;
    
    // ========== TYPE 0: DEFAULT ==========
    if (atmo == 0u) {
        if (is_water) {
            // Aquatic biomes matching enum.gd
            if (temp >= -21 && temp <= 100 && elev >= -1000 && elev <= 0) {
                candidates[count++] = COL_ZONE_COTIERE;
            }
            if (temp >= 5 && temp <= 100 && elev >= -20 && elev <= 20) {
                candidates[count++] = COL_ZONE_HUMIDE;
            }
            if (temp >= 20 && temp <= 35 && elev >= -500 && elev <= 0) {
                candidates[count++] = COL_RECIF;
            }
            if (temp >= 10 && temp <= 100 && elev >= -10 && elev <= 500) {
                candidates[count++] = COL_LAGUNE;
            }
            // Default water: Ocean or Lac based on depth
            if (elev < -50) {
                candidates[count++] = COL_OCEAN;
            } else {
                candidates[count++] = COL_LAC;
            }
        } else {
            // Terrestrial biomes matching enum.gd exactly
            if (temp >= -273 && temp <= -150) {
                candidates[count++] = COL_DESERT_CRYO;
            }
            if (temp >= -150 && temp <= -10) {
                candidates[count++] = COL_GLACIER;
            }
            if (temp >= -150 && temp <= -20) {
                candidates[count++] = COL_DESERT_ARTIQUE;
            }
            if (temp >= -100 && temp <= -20) {
                candidates[count++] = COL_CALOTTE;
            }
            if (temp >= -20 && temp <= 4 && elev < 300) {
                candidates[count++] = COL_TOUNDRA;
            }
            if (temp >= -20 && temp <= 4 && elev >= 300) {
                candidates[count++] = COL_TOUNDRA_ALPINE;
            }
            if (temp >= 0 && temp <= 10) {
                candidates[count++] = COL_TAIGA;
            }
            if (temp >= -15 && temp <= 20 && elev >= 300) {
                candidates[count++] = COL_FORET_MONTAGNE;
            }
            if (temp >= 5 && temp <= 25) {
                candidates[count++] = COL_FORET_TEMPEREE;
                candidates[count++] = COL_PRAIRIE;
                candidates[count++] = COL_STEPPES_TEMPEREES;
            }
            if (temp >= 15 && temp <= 25) {
                candidates[count++] = COL_MEDITERRANEE;
            }
            if (temp >= 15 && temp <= 25 && precip >= 0.5) {
                candidates[count++] = COL_FORET_TROPICALE;
            }
            if (temp >= 26 && temp <= 40 && precip <= 0.35) {
                candidates[count++] = COL_STEPPES_SECHES;
            }
            if (temp >= 20 && temp <= 35 && precip <= 0.35) {
                candidates[count++] = COL_SAVANE;
            }
            if (temp >= 20 && temp <= 25 && precip > 0.35) {
                candidates[count++] = COL_SAVANE_ARBRES;
            }
            if (temp >= 26 && temp <= 50) {
                candidates[count++] = COL_DESERT_SEMI;
            }
            if (temp >= 35 && temp <= 60) {
                candidates[count++] = COL_DESERT;
            }
            if (temp >= 35 && temp <= 70) {
                candidates[count++] = COL_DESERT_ARIDE;
            }
            if (temp >= 70 && temp <= 200) {
                candidates[count++] = COL_DESERT_MORT;
            }
        }
    }
    // ========== TYPE 1: TOXIC ==========
    else if (atmo == 1u) {
        if (is_water) {
            if (temp >= -21 && temp <= 100) {
                candidates[count++] = COL_OCEAN_TOXIC;
            }
            if (temp >= 5 && temp <= 100 && elev >= -20) {
                candidates[count++] = COL_MARECAGE_ACIDE;
            }
        } else {
            if (temp >= -273 && temp <= -150) {
                candidates[count++] = COL_GLACIER_TOXIC;
            }
            if (temp >= -150 && temp <= 0) {
                candidates[count++] = COL_TOUNDRA_TOXIC;
            }
            if (temp >= -273 && temp <= 50 && precip <= 0.35) {
                candidates[count++] = COL_DESERT_SOUFRE;
            }
            if (temp >= 0 && temp <= 35) {
                candidates[count++] = COL_FORET_FONGIQUE;
            }
            if (temp >= 5 && temp <= 35) {
                candidates[count++] = COL_PLAINE_TOXIC;
            }
            if (temp >= 36 && temp <= 200) {
                candidates[count++] = COL_SOLFATARE;
            }
        }
    }
    // ========== TYPE 2: VOLCANIC ==========
    else if (atmo == 2u) {
        if (is_water) {
            if (temp >= -273 && temp <= 0) {
                candidates[count++] = COL_LAVE_REFROIDIE;
            }
            if (temp >= -21 && temp <= 100) {
                candidates[count++] = COL_CHAMPS_LAVE;
            }
            if (temp >= 0 && temp <= 100) {
                candidates[count++] = COL_LAC_MAGMA;
            }
        } else {
            if (temp >= -273 && temp <= 50 && precip <= 0.35) {
                candidates[count++] = COL_DESERT_CENDRES;
            }
            if (temp >= -273 && temp <= 200) {
                candidates[count++] = COL_PLAINE_ROCHES;
            }
            if (temp >= -20 && temp <= 50) {
                candidates[count++] = COL_MONTAGNE_VOLCANIQUE;
            }
            if (temp >= 5 && temp <= 35) {
                candidates[count++] = COL_PLAINE_VOLCANIQUE;
            }
            if (temp >= 20 && temp <= 35) {
                candidates[count++] = COL_TERRASSE_MINERALE;
            }
            if (temp >= 45 && temp <= 200) {
                candidates[count++] = COL_VOLCAN_ACTIF;
            }
            if (temp >= 70 && temp <= 200) {
                candidates[count++] = COL_FUMEROLLE;
            }
        }
    }
    // ========== TYPE 3: NO ATMOSPHERE ==========
    else if (atmo == 3u) {
        if (precip <= 0.1) {
            candidates[count++] = COL_DESERT_ROCHEUX;
        }
        candidates[count++] = COL_REGOLITHE;
        candidates[count++] = COL_FOSSE_IMPACT;
    }
    // ========== TYPE 4: DEAD ==========
    else if (atmo == 4u) {
        if (is_water) {
            if (temp >= 0 && temp <= 100 && elev >= -100) {
                candidates[count++] = COL_MARECAGE_LUMINESCENT;
            }
            if (temp >= -21 && temp <= 100) {
                candidates[count++] = COL_OCEAN_MORT;
            }
        } else {
            if (temp >= -273 && temp <= 50) {
                candidates[count++] = COL_DESERT_SEL;
            }
            if (temp >= 0 && temp <= 35) {
                candidates[count++] = COL_PLAINE_CENDRES;
            }
            if (temp >= 5 && temp <= 35) {
                candidates[count++] = COL_CRATERE_NUCLEAIRE;
            }
            if (temp >= 20 && temp <= 35) {
                candidates[count++] = COL_TERRE_DESOLEE;
            }
            if (temp >= 45 && temp <= 200) {
                candidates[count++] = COL_FORET_MUTANTE;
            }
            if (temp >= 70 && temp <= 200) {
                candidates[count++] = COL_PLAINE_POUSSIERE;
            }
        }
    }
    
    // Select biome using noise (matching getBiomeByNoise logic)
    if (count == 0) {
        return COL_FALLBACK;
    }
    
    // Use noise_val to select among candidates
    int index = int(noise_val * float(count)) % count;
    return candidates[index];
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    if (pos.x >= int(width) || pos.y >= int(height)) {
        return;
    }
    
    // Sample textures with seamless wrapping
    vec2 uv = (vec2(pos) + 0.5) / vec2(float(width), float(height));
    
    vec4 geo = texture(sampler2D(geo_texture, geo_sampler), uv);
    vec4 climate = texture(sampler2D(climate_texture, climate_sampler), uv);
    vec4 ice = imageLoad(ice_caps, pos);
    float river_flux = imageLoad(river_flux_texture, pos).r;
    
    // Extract values from textures
    float height_val = geo.r;
    float water_height = geo.a;
    float temperature = climate.r;
    float precipitation = climate.g;
    
    int elevation = int(round(height_val));
    int temp_int = int(round(temperature));
    bool is_water = water_height > 0.0;
    bool is_banquise = ice.a > 0.0;
    bool is_river = river_flux > river_threshold;
    
    // Generate noise values matching FastNoiseLite behavior
    vec2 world_pos = vec2(pos);
    
    // Main biome selection noise (frequency = 4.0 / width)
    float biome_noise = fbm_biome(world_pos, biome_noise_frequency, seed);
    
    // Climate perturbation noise for irregular boundaries
    float perturb_noise = climate_perturb_noise(world_pos, seed + 1u);
    
    vec4 biome_color;
    
    // Priority 1: Banquise (ice caps)
    if (is_banquise) {
        biome_color = getBanquiseColor(atmosphere_type);
    }
    // Priority 2: Rivers - write river biome colors directly into biome map
    // This matches legacy behavior where river_map colors are copied to biome_map
    else if (is_river) {
        // Estimate max flux for size classification
        float estimated_max_flux = river_threshold * 100.0;
        biome_color = classifyRiverBiome(temp_int, river_flux, estimated_max_flux, atmosphere_type);
    }
    // Priority 3: Regular biome classification
    else {
        biome_color = classifyBiome(elevation, precipitation, temp_int, is_water, 
                                     atmosphere_type, biome_noise, perturb_noise);
    }
    
    imageStore(biome_colored, pos, biome_color);
}
