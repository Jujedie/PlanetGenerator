#[compute]
#version 450

// ============================================================================
// FINAL MAP SHADER - Combinaison des couches visuelles
// ============================================================================
// Ce shader génère la carte finale en combinant plusieurs couches :
// 1. biome_colored : Couleur distinctive du biome → CONVERTIE en végétation
// 2. river_flux : Rivières (couleur végétation correspondante)
// 3. geo_texture : Ombrage topographique (relief)
// 4. ice_caps : Banquise en overlay prioritaire
//
// Formule finale :
// color = biome_vegetation_color * (hillshade)
// if river: color = mix(color, river_veg_color, river_alpha)
// if banquise: color = banquise_color
//
// Entrées :
// - biome_colored (RGBA8) : Couleur distinctive des biomes (get_couleur())
// - river_flux (R32F) : Intensité du flux des rivières
// - geo_texture (RGBA32F) : R=height pour calcul ombrage
// - ice_caps (RGBA8) : Banquise (blanc/transparent)
//
// Sorties :
// - final_map (RGBA8) : Carte finale avec couleurs végétation réalistes
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba8) uniform readonly image2D biome_colored;
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D ice_caps;
layout(set = 0, binding = 4, rgba8) uniform writeonly image2D final_map;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform FinalMapParams {
    uint width;
    uint height;
    uint atmosphere_type;
    float river_threshold;      // Seuil de flux pour afficher une rivière (défaut: 5.0)
    float relief_strength;      // Force de l'ombrage topographique (défaut: 0.3)
    float sea_level;
    float min_elevation;        // Élévation minimale pour normalisation
    float max_elevation;        // Élévation maximale pour normalisation
} params;

// ============================================================================
// BIOME COLOR → VEGETATION COLOR MAPPING
// Chaque biome a une couleur distinctive (map) et une couleur végétation (réaliste)
// Ce système fait la correspondance par distance de couleur euclidienne
// ============================================================================

// === DEFAULT TYPE (0) ===
const vec3 COL_OCEAN = vec3(0.145, 0.322, 0.541);
const vec3 VEG_OCEAN = vec3(0.275, 0.380, 0.506);
const vec3 COL_LAC = vec3(0.271, 0.518, 0.824);
const vec3 VEG_LAC = vec3(0.239, 0.333, 0.443);
const vec3 COL_ZONE_COTIERE = vec3(0.157, 0.376, 0.647);
const vec3 VEG_ZONE_COTIERE = vec3(0.267, 0.373, 0.494);
const vec3 COL_ZONE_HUMIDE = vec3(0.259, 0.361, 0.482);
const vec3 VEG_ZONE_HUMIDE = vec3(0.243, 0.341, 0.455);
const vec3 COL_RECIF = vec3(0.310, 0.541, 0.569);
const vec3 VEG_RECIF = vec3(0.259, 0.361, 0.482);
const vec3 COL_LAGUNE = vec3(0.227, 0.400, 0.420);
const vec3 VEG_LAGUNE = vec3(0.259, 0.361, 0.482);
const vec3 COL_DESERT_CRYO = vec3(0.867, 0.875, 0.890);
const vec3 VEG_DESERT_CRYO = vec3(0.851, 0.851, 0.851);
const vec3 COL_GLACIER = vec3(0.780, 0.804, 0.839);
const vec3 VEG_GLACIER = vec3(0.890, 0.890, 0.890);
const vec3 COL_DESERT_ARTIQUE = vec3(0.671, 0.698, 0.745);
const vec3 VEG_DESERT_ARTIQUE = vec3(0.922, 0.922, 0.922);
const vec3 COL_CALOTTE = vec3(0.580, 0.612, 0.663);
const vec3 VEG_CALOTTE = vec3(0.871, 0.871, 0.871);
const vec3 COL_TOUNDRA = vec3(0.796, 0.694, 0.373);
const vec3 VEG_TOUNDRA = vec3(0.302, 0.349, 0.231);
const vec3 COL_TOUNDRA_ALPINE = vec3(0.718, 0.620, 0.314);
const vec3 VEG_TOUNDRA_ALPINE = vec3(0.282, 0.325, 0.216);
const vec3 COL_TAIGA = vec3(0.278, 0.420, 0.243);
const vec3 VEG_TAIGA = vec3(0.227, 0.302, 0.220);
const vec3 COL_FORET_MONTAGNE = vec3(0.310, 0.541, 0.251);
const vec3 VEG_FORET_MONTAGNE = vec3(0.247, 0.325, 0.235);
const vec3 COL_FORET_TEMPEREE = vec3(0.396, 0.769, 0.306);
const vec3 VEG_FORET_TEMPEREE = vec3(0.263, 0.349, 0.251);
const vec3 COL_PRAIRIE = vec3(0.561, 0.878, 0.486);
const vec3 VEG_PRAIRIE = vec3(0.282, 0.373, 0.271);
const vec3 COL_MEDITERRANEE = vec3(0.290, 0.384, 0.278);
const vec3 VEG_MEDITERRANEE = vec3(0.325, 0.420, 0.310);
const vec3 COL_STEPPES_SECHES = vec3(0.624, 0.565, 0.459);
const vec3 VEG_STEPPES_SECHES = vec3(0.722, 0.624, 0.396);
const vec3 COL_STEPPES_TEMPEREES = vec3(0.514, 0.463, 0.373);
const vec3 VEG_STEPPES_TEMPEREES = vec3(0.349, 0.388, 0.286);
const vec3 COL_FORET_TROPICALE = vec3(0.106, 0.353, 0.129);
const vec3 VEG_FORET_TROPICALE = vec3(0.282, 0.373, 0.271);
const vec3 COL_SAVANE = vec3(0.635, 0.455, 0.259);
const vec3 VEG_SAVANE = vec3(0.722, 0.624, 0.396);
const vec3 COL_SAVANE_ARBRES = vec3(0.580, 0.420, 0.243);
const vec3 VEG_SAVANE_ARBRES = vec3(0.737, 0.643, 0.424);
const vec3 COL_DESERT_SEMI = vec3(0.745, 0.620, 0.361);
const vec3 VEG_DESERT_SEMI = vec3(0.737, 0.643, 0.424);
const vec3 COL_DESERT = vec3(0.580, 0.341, 0.141);
const vec3 VEG_DESERT = vec3(0.729, 0.635, 0.412);
const vec3 COL_DESERT_ARIDE = vec3(0.514, 0.286, 0.169);
const vec3 VEG_DESERT_ARIDE = vec3(0.722, 0.624, 0.396);
const vec3 COL_DESERT_MORT = vec3(0.431, 0.220, 0.145);
const vec3 VEG_DESERT_MORT = vec3(0.671, 0.596, 0.427);

// Rivers Default
const vec3 COL_RIVIERE = vec3(0.290, 0.565, 0.851);
const vec3 VEG_RIVIERE = vec3(0.247, 0.349, 0.471);
const vec3 COL_FLEUVE = vec3(0.243, 0.498, 0.769);
const vec3 VEG_FLEUVE = vec3(0.247, 0.349, 0.471);
const vec3 COL_AFFLUENT = vec3(0.420, 0.667, 0.898);
const vec3 VEG_AFFLUENT = vec3(0.243, 0.337, 0.459);
const vec3 COL_LAC_DOUCE = vec3(0.357, 0.639, 0.878);
const vec3 VEG_LAC_DOUCE = vec3(0.235, 0.329, 0.447);
const vec3 COL_LAC_GELE = vec3(0.659, 0.831, 0.902);
const vec3 VEG_LAC_GELE = vec3(0.322, 0.431, 0.565);
const vec3 COL_RIVIERE_GLACIAIRE = vec3(0.494, 0.784, 0.890);
const vec3 VEG_RIVIERE_GLACIAIRE = vec3(0.369, 0.475, 0.608);

// === TOXIC TYPE (1) ===
const vec3 COL_BANQUISE_TOXIC = vec3(0.282, 0.839, 0.231);
const vec3 VEG_BANQUISE_TOXIC = vec3(0.690, 0.745, 0.671);
const vec3 COL_OCEAN_TOXIC = vec3(0.196, 0.608, 0.514);
const vec3 VEG_OCEAN_TOXIC = vec3(0.231, 0.431, 0.380);
const vec3 COL_MARECAGE_ACIDE = vec3(0.208, 0.608, 0.227);
const vec3 VEG_MARECAGE_ACIDE = vec3(0.208, 0.392, 0.345);
const vec3 COL_DESERT_SOUFRE = vec3(0.471, 0.553, 0.161);
const vec3 VEG_DESERT_SOUFRE = vec3(0.518, 0.553, 0.388);
const vec3 COL_GLACIER_TOXIC = vec3(0.678, 0.796, 0.271);
const vec3 VEG_GLACIER_TOXIC = vec3(0.765, 0.796, 0.659);
const vec3 COL_TOUNDRA_TOXIC = vec3(0.514, 0.580, 0.294);
const vec3 VEG_TOUNDRA_TOXIC = vec3(0.557, 0.596, 0.431);
const vec3 COL_FORET_FONGIQUE = vec3(0.192, 0.459, 0.212);
const vec3 VEG_FORET_FONGIQUE = vec3(0.349, 0.459, 0.357);
const vec3 COL_PLAINE_TOXIC = vec3(0.216, 0.553, 0.243);
const vec3 VEG_PLAINE_TOXIC = vec3(0.404, 0.541, 0.416);
const vec3 COL_SOLFATARE = vec3(0.239, 0.459, 0.259);
const vec3 VEG_SOLFATARE = vec3(0.376, 0.431, 0.380);

// Toxic rivers
const vec3 COL_RIVIERE_ACIDE = vec3(0.357, 0.769, 0.353);
const vec3 VEG_RIVIERE_ACIDE = vec3(0.239, 0.333, 0.235);
const vec3 COL_FLEUVE_TOXIC = vec3(0.282, 0.722, 0.278);
const vec3 VEG_FLEUVE_TOXIC = vec3(0.224, 0.306, 0.220);
const vec3 COL_LAC_ACIDE = vec3(0.431, 0.851, 0.427);
const vec3 VEG_LAC_ACIDE = vec3(0.259, 0.357, 0.255);
const vec3 COL_LAC_TOXIC_GELE = vec3(0.722, 0.902, 0.718);
const vec3 VEG_LAC_TOXIC_GELE = vec3(0.290, 0.392, 0.282);

// === VOLCANIC TYPE (2) ===
const vec3 COL_LAVE_REFROIDIE = vec3(0.718, 0.420, 0.055);
const vec3 VEG_LAVE_REFROIDIE = vec3(0.231, 0.192, 0.169);
const vec3 COL_CHAMPS_LAVE = vec3(0.839, 0.588, 0.090);
const vec3 VEG_CHAMPS_LAVE = vec3(0.769, 0.259, 0.090);
const vec3 COL_LAC_MAGMA = vec3(0.718, 0.286, 0.055);
const vec3 VEG_LAC_MAGMA = vec3(0.702, 0.216, 0.055);
const vec3 COL_DESERT_CENDRES = vec3(0.867, 0.490, 0.075);
const vec3 VEG_DESERT_CENDRES = vec3(0.298, 0.196, 0.161);
const vec3 COL_PLAINE_ROCHES = vec3(0.812, 0.455, 0.063);
const vec3 VEG_PLAINE_ROCHES = vec3(0.298, 0.255, 0.243);
const vec3 COL_MONTAGNE_VOLCANIQUE = vec3(0.608, 0.388, 0.149);
const vec3 VEG_MONTAGNE_VOLCANIQUE = vec3(0.231, 0.208, 0.200);
const vec3 COL_PLAINE_VOLCANIQUE = vec3(0.596, 0.329, 0.039);
const vec3 VEG_PLAINE_VOLCANIQUE = vec3(0.325, 0.290, 0.278);
const vec3 COL_TERRASSE_MINERALE = vec3(0.580, 0.333, 0.067);
const vec3 VEG_TERRASSE_MINERALE = vec3(0.255, 0.227, 0.220);
const vec3 COL_VOLCAN_ACTIF = vec3(0.365, 0.267, 0.157);
const vec3 VEG_VOLCAN_ACTIF = vec3(0.392, 0.176, 0.102);
const vec3 COL_FUMEROLLE = vec3(0.282, 0.220, 0.145);
const vec3 VEG_FUMEROLLE = vec3(0.176, 0.169, 0.165);

// Volcanic rivers
const vec3 COL_RIVIERE_LAVE = vec3(1.0, 0.420, 0.102);
const vec3 VEG_RIVIERE_LAVE = vec3(0.831, 0.353, 0.082);
const vec3 COL_FLEUVE_MAGMA = vec3(0.910, 0.353, 0.059);
const vec3 VEG_FLEUVE_MAGMA = vec3(0.769, 0.294, 0.051);
const vec3 COL_LAVE_SOLIDIFIEE = vec3(0.627, 0.322, 0.176);
const vec3 VEG_LAVE_SOLIDIFIEE = vec3(0.502, 0.251, 0.125);
const vec3 COL_BASSIN_REFROIDI = vec3(0.545, 0.271, 0.075);
const vec3 VEG_BASSIN_REFROIDI = vec3(0.420, 0.208, 0.063);

// === DEAD TYPE (4) ===
const vec3 COL_MARECAGE_LUMINESCENT = vec3(0.380, 0.624, 0.388);
const vec3 VEG_MARECAGE_LUMINESCENT = vec3(0.298, 0.431, 0.302);
const vec3 COL_OCEAN_MORT = vec3(0.286, 0.475, 0.290);
const vec3 VEG_OCEAN_MORT = vec3(0.216, 0.310, 0.220);
const vec3 COL_DESERT_SEL = vec3(0.851, 0.796, 0.627);
const vec3 VEG_DESERT_SEL = vec3(0.769, 0.722, 0.576);
const vec3 COL_PLAINE_CENDRES = vec3(0.161, 0.157, 0.149);
const vec3 VEG_PLAINE_CENDRES = vec3(0.325, 0.314, 0.294);
const vec3 COL_CRATERE_NUCLEAIRE = vec3(0.204, 0.200, 0.192);
const vec3 VEG_CRATERE_NUCLEAIRE = vec3(0.282, 0.275, 0.255);
const vec3 COL_TERRE_DESOLEE = vec3(0.502, 0.475, 0.412);
const vec3 VEG_TERRE_DESOLEE = vec3(0.337, 0.329, 0.310);
const vec3 COL_FORET_MUTANTE = vec3(0.525, 0.439, 0.282);
const vec3 VEG_FORET_MUTANTE = vec3(0.486, 0.424, 0.302);
const vec3 COL_PLAINE_POUSSIERE = vec3(0.663, 0.549, 0.349);
const vec3 VEG_PLAINE_POUSSIERE = vec3(0.541, 0.463, 0.314);

// Dead rivers
const vec3 COL_RIVIERE_STAGNANTE = vec3(0.353, 0.478, 0.357);
const vec3 VEG_RIVIERE_STAGNANTE = vec3(0.239, 0.333, 0.235);
const vec3 COL_FLEUVE_POLLUE = vec3(0.290, 0.416, 0.294);
const vec3 VEG_FLEUVE_POLLUE = vec3(0.224, 0.306, 0.220);
const vec3 COL_LAC_IRRADIE = vec3(0.420, 0.545, 0.424);
const vec3 VEG_LAC_IRRADIE = vec3(0.259, 0.357, 0.255);
const vec3 COL_LAC_BOUE = vec3(0.545, 0.451, 0.333);
const vec3 VEG_LAC_BOUE = vec3(0.290, 0.392, 0.282);

// === NO ATMOSPHERE TYPE (3) ===
const vec3 COL_DESERT_ROCHEUX = vec3(0.459, 0.451, 0.435);
const vec3 VEG_DESERT_ROCHEUX = vec3(0.310, 0.302, 0.290);
const vec3 COL_REGOLITHE = vec3(0.404, 0.400, 0.384);
const vec3 VEG_REGOLITHE = vec3(0.290, 0.282, 0.271);
const vec3 COL_FOSSE_IMPACT = vec3(0.365, 0.361, 0.349);
const vec3 VEG_FOSSE_IMPACT = vec3(0.278, 0.271, 0.263);

// Banquise colors
const vec3 COL_BANQUISE = vec3(0.749, 0.745, 0.733);
const vec3 VEG_BANQUISE = vec3(0.749, 0.745, 0.733);
const vec3 COL_BANQUISE_MORTE = vec3(0.851, 0.820, 0.800);
const vec3 VEG_BANQUISE_MORTE = vec3(0.851, 0.820, 0.800);

// ============================================================================
// BIOME TO VEGETATION MAPPING FUNCTION
// Uses distance-based matching to convert biome colors to vegetation colors
// ============================================================================

// Helper: squared distance between colors (faster than sqrt)
float colorDistSq(vec3 a, vec3 b) {
    vec3 d = a - b;
    return dot(d, d);
}

// Tolerance for color matching (squared)
const float COLOR_TOLERANCE_SQ = 0.001;

// Convert biome color to vegetation color using direct matching
vec3 biomeToVegetation(vec3 biome) {
    // DEFAULT (0)
    if (colorDistSq(biome, COL_OCEAN) < COLOR_TOLERANCE_SQ) return VEG_OCEAN;
    if (colorDistSq(biome, COL_LAC) < COLOR_TOLERANCE_SQ) return VEG_LAC;
    if (colorDistSq(biome, COL_ZONE_COTIERE) < COLOR_TOLERANCE_SQ) return VEG_ZONE_COTIERE;
    if (colorDistSq(biome, COL_ZONE_HUMIDE) < COLOR_TOLERANCE_SQ) return VEG_ZONE_HUMIDE;
    if (colorDistSq(biome, COL_RECIF) < COLOR_TOLERANCE_SQ) return VEG_RECIF;
    if (colorDistSq(biome, COL_LAGUNE) < COLOR_TOLERANCE_SQ) return VEG_LAGUNE;
    if (colorDistSq(biome, COL_DESERT_CRYO) < COLOR_TOLERANCE_SQ) return VEG_DESERT_CRYO;
    if (colorDistSq(biome, COL_GLACIER) < COLOR_TOLERANCE_SQ) return VEG_GLACIER;
    if (colorDistSq(biome, COL_DESERT_ARTIQUE) < COLOR_TOLERANCE_SQ) return VEG_DESERT_ARTIQUE;
    if (colorDistSq(biome, COL_CALOTTE) < COLOR_TOLERANCE_SQ) return VEG_CALOTTE;
    if (colorDistSq(biome, COL_TOUNDRA) < COLOR_TOLERANCE_SQ) return VEG_TOUNDRA;
    if (colorDistSq(biome, COL_TOUNDRA_ALPINE) < COLOR_TOLERANCE_SQ) return VEG_TOUNDRA_ALPINE;
    if (colorDistSq(biome, COL_TAIGA) < COLOR_TOLERANCE_SQ) return VEG_TAIGA;
    if (colorDistSq(biome, COL_FORET_MONTAGNE) < COLOR_TOLERANCE_SQ) return VEG_FORET_MONTAGNE;
    if (colorDistSq(biome, COL_FORET_TEMPEREE) < COLOR_TOLERANCE_SQ) return VEG_FORET_TEMPEREE;
    if (colorDistSq(biome, COL_PRAIRIE) < COLOR_TOLERANCE_SQ) return VEG_PRAIRIE;
    if (colorDistSq(biome, COL_MEDITERRANEE) < COLOR_TOLERANCE_SQ) return VEG_MEDITERRANEE;
    if (colorDistSq(biome, COL_STEPPES_SECHES) < COLOR_TOLERANCE_SQ) return VEG_STEPPES_SECHES;
    if (colorDistSq(biome, COL_STEPPES_TEMPEREES) < COLOR_TOLERANCE_SQ) return VEG_STEPPES_TEMPEREES;
    if (colorDistSq(biome, COL_FORET_TROPICALE) < COLOR_TOLERANCE_SQ) return VEG_FORET_TROPICALE;
    if (colorDistSq(biome, COL_SAVANE) < COLOR_TOLERANCE_SQ) return VEG_SAVANE;
    if (colorDistSq(biome, COL_SAVANE_ARBRES) < COLOR_TOLERANCE_SQ) return VEG_SAVANE_ARBRES;
    if (colorDistSq(biome, COL_DESERT_SEMI) < COLOR_TOLERANCE_SQ) return VEG_DESERT_SEMI;
    if (colorDistSq(biome, COL_DESERT) < COLOR_TOLERANCE_SQ) return VEG_DESERT;
    if (colorDistSq(biome, COL_DESERT_ARIDE) < COLOR_TOLERANCE_SQ) return VEG_DESERT_ARIDE;
    if (colorDistSq(biome, COL_DESERT_MORT) < COLOR_TOLERANCE_SQ) return VEG_DESERT_MORT;
    
    // Rivers Default
    if (colorDistSq(biome, COL_RIVIERE) < COLOR_TOLERANCE_SQ) return VEG_RIVIERE;
    if (colorDistSq(biome, COL_FLEUVE) < COLOR_TOLERANCE_SQ) return VEG_FLEUVE;
    if (colorDistSq(biome, COL_AFFLUENT) < COLOR_TOLERANCE_SQ) return VEG_AFFLUENT;
    if (colorDistSq(biome, COL_LAC_DOUCE) < COLOR_TOLERANCE_SQ) return VEG_LAC_DOUCE;
    if (colorDistSq(biome, COL_LAC_GELE) < COLOR_TOLERANCE_SQ) return VEG_LAC_GELE;
    if (colorDistSq(biome, COL_RIVIERE_GLACIAIRE) < COLOR_TOLERANCE_SQ) return VEG_RIVIERE_GLACIAIRE;
    
    // TOXIC (1)
    if (colorDistSq(biome, COL_BANQUISE_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_BANQUISE_TOXIC;
    if (colorDistSq(biome, COL_OCEAN_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_OCEAN_TOXIC;
    if (colorDistSq(biome, COL_MARECAGE_ACIDE) < COLOR_TOLERANCE_SQ) return VEG_MARECAGE_ACIDE;
    if (colorDistSq(biome, COL_DESERT_SOUFRE) < COLOR_TOLERANCE_SQ) return VEG_DESERT_SOUFRE;
    if (colorDistSq(biome, COL_GLACIER_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_GLACIER_TOXIC;
    if (colorDistSq(biome, COL_TOUNDRA_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_TOUNDRA_TOXIC;
    if (colorDistSq(biome, COL_FORET_FONGIQUE) < COLOR_TOLERANCE_SQ) return VEG_FORET_FONGIQUE;
    if (colorDistSq(biome, COL_PLAINE_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_PLAINE_TOXIC;
    if (colorDistSq(biome, COL_SOLFATARE) < COLOR_TOLERANCE_SQ) return VEG_SOLFATARE;
    if (colorDistSq(biome, COL_RIVIERE_ACIDE) < COLOR_TOLERANCE_SQ) return VEG_RIVIERE_ACIDE;
    if (colorDistSq(biome, COL_FLEUVE_TOXIC) < COLOR_TOLERANCE_SQ) return VEG_FLEUVE_TOXIC;
    if (colorDistSq(biome, COL_LAC_ACIDE) < COLOR_TOLERANCE_SQ) return VEG_LAC_ACIDE;
    if (colorDistSq(biome, COL_LAC_TOXIC_GELE) < COLOR_TOLERANCE_SQ) return VEG_LAC_TOXIC_GELE;
    
    // VOLCANIC (2)
    if (colorDistSq(biome, COL_LAVE_REFROIDIE) < COLOR_TOLERANCE_SQ) return VEG_LAVE_REFROIDIE;
    if (colorDistSq(biome, COL_CHAMPS_LAVE) < COLOR_TOLERANCE_SQ) return VEG_CHAMPS_LAVE;
    if (colorDistSq(biome, COL_LAC_MAGMA) < COLOR_TOLERANCE_SQ) return VEG_LAC_MAGMA;
    if (colorDistSq(biome, COL_DESERT_CENDRES) < COLOR_TOLERANCE_SQ) return VEG_DESERT_CENDRES;
    if (colorDistSq(biome, COL_PLAINE_ROCHES) < COLOR_TOLERANCE_SQ) return VEG_PLAINE_ROCHES;
    if (colorDistSq(biome, COL_MONTAGNE_VOLCANIQUE) < COLOR_TOLERANCE_SQ) return VEG_MONTAGNE_VOLCANIQUE;
    if (colorDistSq(biome, COL_PLAINE_VOLCANIQUE) < COLOR_TOLERANCE_SQ) return VEG_PLAINE_VOLCANIQUE;
    if (colorDistSq(biome, COL_TERRASSE_MINERALE) < COLOR_TOLERANCE_SQ) return VEG_TERRASSE_MINERALE;
    if (colorDistSq(biome, COL_VOLCAN_ACTIF) < COLOR_TOLERANCE_SQ) return VEG_VOLCAN_ACTIF;
    if (colorDistSq(biome, COL_FUMEROLLE) < COLOR_TOLERANCE_SQ) return VEG_FUMEROLLE;
    if (colorDistSq(biome, COL_RIVIERE_LAVE) < COLOR_TOLERANCE_SQ) return VEG_RIVIERE_LAVE;
    if (colorDistSq(biome, COL_FLEUVE_MAGMA) < COLOR_TOLERANCE_SQ) return VEG_FLEUVE_MAGMA;
    if (colorDistSq(biome, COL_LAVE_SOLIDIFIEE) < COLOR_TOLERANCE_SQ) return VEG_LAVE_SOLIDIFIEE;
    if (colorDistSq(biome, COL_BASSIN_REFROIDI) < COLOR_TOLERANCE_SQ) return VEG_BASSIN_REFROIDI;
    
    // DEAD (4)
    if (colorDistSq(biome, COL_MARECAGE_LUMINESCENT) < COLOR_TOLERANCE_SQ) return VEG_MARECAGE_LUMINESCENT;
    if (colorDistSq(biome, COL_OCEAN_MORT) < COLOR_TOLERANCE_SQ) return VEG_OCEAN_MORT;
    if (colorDistSq(biome, COL_DESERT_SEL) < COLOR_TOLERANCE_SQ) return VEG_DESERT_SEL;
    if (colorDistSq(biome, COL_PLAINE_CENDRES) < COLOR_TOLERANCE_SQ) return VEG_PLAINE_CENDRES;
    if (colorDistSq(biome, COL_CRATERE_NUCLEAIRE) < COLOR_TOLERANCE_SQ) return VEG_CRATERE_NUCLEAIRE;
    if (colorDistSq(biome, COL_TERRE_DESOLEE) < COLOR_TOLERANCE_SQ) return VEG_TERRE_DESOLEE;
    if (colorDistSq(biome, COL_FORET_MUTANTE) < COLOR_TOLERANCE_SQ) return VEG_FORET_MUTANTE;
    if (colorDistSq(biome, COL_PLAINE_POUSSIERE) < COLOR_TOLERANCE_SQ) return VEG_PLAINE_POUSSIERE;
    if (colorDistSq(biome, COL_RIVIERE_STAGNANTE) < COLOR_TOLERANCE_SQ) return VEG_RIVIERE_STAGNANTE;
    if (colorDistSq(biome, COL_FLEUVE_POLLUE) < COLOR_TOLERANCE_SQ) return VEG_FLEUVE_POLLUE;
    if (colorDistSq(biome, COL_LAC_IRRADIE) < COLOR_TOLERANCE_SQ) return VEG_LAC_IRRADIE;
    if (colorDistSq(biome, COL_LAC_BOUE) < COLOR_TOLERANCE_SQ) return VEG_LAC_BOUE;
    
    // NO ATMOSPHERE (3)
    if (colorDistSq(biome, COL_DESERT_ROCHEUX) < COLOR_TOLERANCE_SQ) return VEG_DESERT_ROCHEUX;
    if (colorDistSq(biome, COL_REGOLITHE) < COLOR_TOLERANCE_SQ) return VEG_REGOLITHE;
    if (colorDistSq(biome, COL_FOSSE_IMPACT) < COLOR_TOLERANCE_SQ) return VEG_FOSSE_IMPACT;
    
    // Banquise
    if (colorDistSq(biome, COL_BANQUISE) < COLOR_TOLERANCE_SQ) return VEG_BANQUISE;
    if (colorDistSq(biome, COL_BANQUISE_MORTE) < COLOR_TOLERANCE_SQ) return VEG_BANQUISE_MORTE;
    
    // Fallback: return original color if no match (shouldn't happen)
    return biome;
}

// ============================================================================
// BANQUISE COLOR BY ATMOSPHERE
// ============================================================================

vec3 getBanquiseColor(uint atmo) {
    if (atmo == 0u) return VEG_BANQUISE;
    if (atmo == 1u) return VEG_BANQUISE_TOXIC;
    if (atmo == 2u) return VEG_LAVE_REFROIDIE;  // Volcanic banquise is cooled lava
    if (atmo == 3u) return VEG_BANQUISE_MORTE;
    if (atmo == 4u) return VEG_BANQUISE_MORTE;
    return VEG_BANQUISE;
}

// ============================================================================
// HILLSHADE CALCULATION
// ============================================================================

float calculateTopoShading(ivec2 pos, int w, int h) {
    ivec2 left = ivec2((pos.x - 1 + w) % w, pos.y);
    ivec2 right = ivec2((pos.x + 1) % w, pos.y);
    ivec2 up = ivec2(pos.x, max(pos.y - 1, 0));
    ivec2 down = ivec2(pos.x, min(pos.y + 1, h - 1));
    
    float h_left = imageLoad(geo_texture, left).r;
    float h_right = imageLoad(geo_texture, right).r;
    float h_up = imageLoad(geo_texture, up).r;
    float h_down = imageLoad(geo_texture, down).r;
    
    float dx = (h_right - h_left) * 0.5;
    float dy = (h_down - h_up) * 0.5;
    
    vec3 light_dir = normalize(vec3(-1.0, -1.0, 1.0));
    vec3 normal = normalize(vec3(-dx, -dy, 1.0));
    float shade = dot(normal, light_dir);
    
    return clamp((shade + 1.0) * 0.5, 0.0, 1.0);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pos.x >= w || pos.y >= h) {
        return;
    }
    
    // === READ TEXTURES ===
    vec4 biome = imageLoad(biome_colored, pos);
    float flux = imageLoad(river_flux, pos).r;
    vec4 ice = imageLoad(ice_caps, pos);
    
    bool is_banquise = ice.a > 0.0;
    bool is_river = flux > params.river_threshold;
    
    // === STEP 1: Convert biome color to vegetation color ===
    vec3 color = biomeToVegetation(biome.rgb);
    
    // === STEP 2: Apply hillshade (topographic shading) ===
    float shading = calculateTopoShading(pos, w, h);
    float shade_factor = mix(1.0 - params.relief_strength, 1.0, shading);
    color *= shade_factor;
    
    // === STEP 3: Rivers (already in vegetation color from biome) ===
    // Rivers are already colored by biome_classify, just apply shading
    // The biomeToVegetation handles river colors too
    
    // === STEP 4: Banquise overlay (highest priority) ===
    if (is_banquise) {
        vec3 banquise_color = getBanquiseColor(params.atmosphere_type);
        color = banquise_color;
    }
    
    // === OUTPUT ===
    imageStore(final_map, pos, vec4(color, 1.0));
}
