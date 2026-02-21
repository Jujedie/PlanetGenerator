#[compute]
#version 450

// ============================================================================
// RIVER CLASSIFY SHADER - Attribution de biomes aux rivieres
// ============================================================================
// Lit le type de riviere promu (apres river_type_promote) et assigne
// le biome riviere correspondant en fonction du type et de la temperature.
//
// Types d'entree :
// - 0 = Affluent, 1 = Riviere, 2 = Fleuve, 255 = pas de riviere
//
// Entrees :
// - river_type (R8UI) : Type promu (apres promotion du chenal principal)
// - climate_texture (RGBA32F) : R=temperature
// - RiverBiomeLUT (SSBO) : Biomes riviere avec couleurs et plages de temperature
//
// Sorties :
// - river_biome_id (R32UI) : Index du biome riviere (0xFFFFFFFF = pas de riviere)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, r8ui)    uniform readonly uimage2D river_type;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, r32ui)   uniform writeonly uimage2D river_biome_id;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform ClassifyParams {
    uint width;
    uint height;
    uint padding1;
    uint padding2;
} params;

// === SET 2: RIVER BIOMES SSBO ===
struct RiverBiomeData {
    vec4 color;              // RGB + alpha (couleur vegetation) - 16 bytes
    float temp_min;          // Temperature minimale (deg C) - 4 bytes
    float temp_max;          // Temperature maximale (deg C) - 4 bytes
    float humid_min;         // (non utilise pour rivieres) - 4 bytes
    float humid_max;         // (non utilise pour rivieres) - 4 bytes
    float elev_min;          // (non utilise pour rivieres) - 4 bytes
    float elev_max;          // (non utilise pour rivieres) - 4 bytes
    uint water_need;         // (non utilise) - 4 bytes
    uint planet_type_mask;   // Bitmask des types de planetes valides - 4 bytes
    uint river_type;         // 0=Affluent, 1=Riviere, 2=Fleuve, 3=Lac, 4=Lac gele, 5=Riviere glaciaire - 4 bytes
    uint padding1;           // - 4 bytes
    uint padding2;           // - 4 bytes
    uint padding3;           // - 4 bytes
    // Total: 64 bytes
};

layout(set = 2, binding = 0, std430) readonly buffer RiverBiomeLUT {
    uint river_biome_count;
    uint header_padding1;
    uint header_padding2;
    uint header_padding3;
    RiverBiomeData river_biomes[];
};

// ============================================================================
// CONSTANTES
// ============================================================================

const uint TYPE_NONE = 255u;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Trouve le meilleur biome riviere correspondant au type et a la temperature.
/// Retourne 0xFFFFFFFF si AUCUN biome ne correspond (= pas de riviere affichee).
///
/// Priorite :
/// 1) Match exact du type de riviere + temperature compatible
/// 2) Fallback vers types courants (<=2) compatibles en temperature
/// 3) Fallback vers n'importe quel biome compatible en temperature
///    (Riviere glaciaire, Lac gele, Riviere de Lave, etc.)
/// Si aucun biome ne correspond en temperature → pas de riviere.
uint findBestRiverBiome(int rtype, float temperature) {
    uint best_match = 0xFFFFFFFFu;
    float best_score = -1e10;
    uint fallback_match = 0xFFFFFFFFu;
    float fallback_score = -1e10;
    uint any_match = 0xFFFFFFFFu;
    float any_score = -1e10;

    for (uint i = 0u; i < river_biome_count; i++) {
        RiverBiomeData b = river_biomes[i];

        // Verifier la compatibilite de temperature - STRICT
        // Si la temperature locale n'est pas dans la plage du biome, on passe
        if (temperature < b.temp_min || temperature > b.temp_max) continue;

        // Score base sur la specificite de la plage de temperature
        // Plus la plage est etroite, plus le biome est specifique et prioritaire
        float range = b.temp_max - b.temp_min;
        float score = 1000.0 / max(range, 1.0);

        // Priorite 1 : Match exact du type de riviere
        if (b.river_type == uint(rtype)) {
            if (score > best_score) {
                best_score = score;
                best_match = i;
            }
        }

        // Priorite 2 : Fallback vers types courants (Affluent/Riviere/Fleuve)
        if (b.river_type <= 2u) {
            if (score > fallback_score) {
                fallback_score = score;
                fallback_match = i;
            }
        }

        // Priorite 3 : N'importe quel biome compatible en temperature
        // Necessaire pour les biomes speciaux comme Riviere glaciaire (type=5),
        // Lac gele (type=4), Riviere de Lave (type=1 mais plage extreme), etc.
        // quand le type exact et le fallback courant ne couvrent pas la temperature
        if (score > any_score) {
            any_score = score;
            any_match = i;
        }
    }

    if (best_match != 0xFFFFFFFFu) return best_match;
    if (fallback_match != 0xFFFFFFFFu) return fallback_match;
    return any_match;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pos.x >= w || pos.y >= h) return;

    // Par defaut : pas de riviere
    uint biome_index = 0xFFFFFFFFu;

    // Lire le type promu
    uint rtype = imageLoad(river_type, pos).r;

    // Pas de riviere → ecrire directement
    if (rtype == TYPE_NONE) {
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }

    // Lire la temperature locale
    float temperature = imageLoad(climate_texture, pos).r;

    // Chercher le meilleur biome riviere correspondant
    biome_index = findBestRiverBiome(int(rtype), temperature);

    imageStore(river_biome_id, pos, uvec4(biome_index));
}
