#[compute]
#version 450

// ============================================================================
// RIVER CLASSIFY SHADER - Classification des rivières en biomes
// ============================================================================
// Ce shader prend la carte de flux des rivières et assigne un biome rivière
// à chaque pixel qui dépasse le seuil de flux minimum.
//
// Classification par flux :
// - flux >= fleuve_threshold  → Fleuve (type 2)
// - flux >= riviere_threshold → Rivière (type 1)
// - flux >= affluent_threshold → Affluent (type 0)
// - flux < affluent_threshold → pas de rivière (0xFFFFFFFF)
//
// Le biome rivière est choisi parmi les biomes du SSBO rivière
// en fonction du type (affluent/rivière/fleuve) et de la température locale.
//
// Le meilleur biome est celui dont la plage de température contient la
// température locale. Si plusieurs correspondent, on prend le premier match.
//
// Entrées :
// - river_flux (R32F) : Flux accumulé
// - climate_texture (RGBA32F) : R=temperature
// - water_mask (R8UI) : Pour éviter de classifier sur l'eau existante
// - RiverBiomeLUT (SSBO) : Biomes rivière avec couleurs et plages de température
//
// Sorties :
// - river_biome_id (R32UI) : Index du biome rivière dans le SSBO (0xFFFFFFFF = pas de rivière)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, r32f)    uniform readonly image2D river_flux;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 3, r32ui)   uniform writeonly uimage2D river_biome_id;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform ClassifyParams {
    uint width;
    uint height;
    float affluent_threshold;   // Seuil flux min pour affluent (ex: 3.0)
    float riviere_threshold;    // Seuil flux min pour rivière (ex: 15.0)
    float fleuve_threshold;     // Seuil flux min pour fleuve (ex: 60.0)
    float padding1;
    float padding2;
    float padding3;
} params;

// === SET 2: RIVER BIOMES SSBO ===
// Structure alignée std430 (64 bytes par biome) - identique aux biomes normaux
struct RiverBiomeData {
    vec4 color;              // RGB + alpha (couleur végétation) - 16 bytes
    float temp_min;          // Température minimale (°C) - 4 bytes
    float temp_max;          // Température maximale (°C) - 4 bytes
    float humid_min;         // (non utilisé pour rivières) - 4 bytes
    float humid_max;         // (non utilisé pour rivières) - 4 bytes
    float elev_min;          // (non utilisé pour rivières) - 4 bytes
    float elev_max;          // (non utilisé pour rivières) - 4 bytes
    uint water_need;         // (non utilisé) - 4 bytes
    uint planet_type_mask;   // Bitmask des types de planètes valides - 4 bytes
    uint river_type;         // 0=Affluent, 1=Rivière, 2=Fleuve, 3=Lac, 4=Lac gelé, 5=Rivière glaciaire - 4 bytes
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
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    if (pos.x >= w || pos.y >= h) return;
    
    // Par défaut : pas de rivière
    uint biome_index = 0xFFFFFFFFu;
    
    // Pas de rivière sur l'eau existante
    uint water_type = imageLoad(water_mask, pos).r;
    if (water_type > 0u) {
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }
    
    // Lire le flux
    float flux = imageLoad(river_flux, pos).r;
    
    // Déterminer le type de rivière par seuil de flux
    // 0=Affluent, 1=Rivière, 2=Fleuve
    int river_type = -1;
    
    if (flux >= params.fleuve_threshold) {
        river_type = 2;  // Fleuve
    } else if (flux >= params.riviere_threshold) {
        river_type = 1;  // Rivière
    } else if (flux >= params.affluent_threshold) {
        river_type = 0;  // Affluent
    }
    
    if (river_type < 0) {
        // Pas assez de flux → pas de rivière
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }
    
    // Lire la température locale
    float temperature = imageLoad(climate_texture, pos).r;
    
    // Chercher le meilleur biome rivière correspondant
    // Priorité : match exact du type + température dans la plage
    uint best_match = 0xFFFFFFFFu;
    float best_score = -1e10;
    
    // Fallback : si aucun match exact de type, prendre n'importe quel biome rivière compatible
    uint fallback_match = 0xFFFFFFFFu;
    float fallback_score = -1e10;
    
    for (uint i = 0u; i < river_biome_count; i++) {
        RiverBiomeData b = river_biomes[i];
        
        // Vérifier la compatibilité de température
        if (temperature < b.temp_min || temperature > b.temp_max) continue;
        
        // Score basé sur la spécificité de la plage de température
        // Plus la plage est étroite, plus le score est élevé
        float range = b.temp_max - b.temp_min;
        float score = 1000.0 / max(range, 1.0);
        
        // Match exact du type de rivière
        if (b.river_type == uint(river_type)) {
            if (score > best_score) {
                best_score = score;
                best_match = i;
            }
        }
        
        // Fallback : n'importe quel type de rivière (pas lac)
        if (b.river_type <= 2u || b.river_type == 5u) {
            if (score > fallback_score) {
                fallback_score = score;
                fallback_match = i;
            }
        }
    }
    
    // Utiliser le meilleur match, sinon le fallback
    biome_index = (best_match != 0xFFFFFFFFu) ? best_match : fallback_match;
    
    imageStore(river_biome_id, pos, uvec4(biome_index));
}
