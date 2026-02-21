#[compute]
#version 450

// ============================================================================
// RIVER TYPE ASSIGN SHADER - Classification initiale des types de riviere
// ============================================================================
// Assigne un type initial a chaque pixel terrestre en fonction de son flux :
//   0 = Affluent  (flux >= affluent_threshold)
//   1 = Riviere   (flux >= riviere_threshold)
//   2 = Fleuve    (flux >= fleuve_threshold)
// 255 = Pas de riviere
//
// Ce type initial sera ensuite promu par river_type_promote pour creer
// des entites fluviales coherentes (le chenal principal herite du type aval).
//
// Entrees :
// - river_flux (R32F) : Flux accumule
// - water_mask (R8UI) : 0=terre, >0=eau
//
// Sorties :
// - river_type_out (R8UI) : Type initial (0/1/2/255)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, r32f)  uniform readonly image2D river_flux;
layout(set = 0, binding = 1, r8ui)  uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r8ui)  uniform writeonly uimage2D river_type_out;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform TypeAssignParams {
    uint width;
    uint height;
    float affluent_threshold;
    float riviere_threshold;
    float fleuve_threshold;
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint TYPE_AFFLUENT = 0u;
const uint TYPE_RIVIERE  = 1u;
const uint TYPE_FLEUVE   = 2u;
const uint TYPE_NONE     = 255u;

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pos.x >= w || pos.y >= h) return;

    // Exclure les rangees polaires
    if (pos.y < 2 || pos.y >= h - 2) {
        imageStore(river_type_out, pos, uvec4(TYPE_NONE));
        return;
    }

    // Pas de riviere sur l'eau existante
    uint water_type = imageLoad(water_mask, pos).r;
    if (water_type > 0u) {
        imageStore(river_type_out, pos, uvec4(TYPE_NONE));
        return;
    }

    // Lire le flux
    float flux = imageLoad(river_flux, pos).r;

    // Classifier par flux
    uint river_type = TYPE_NONE;
    if (flux >= params.fleuve_threshold) {
        river_type = TYPE_FLEUVE;
    } else if (flux >= params.riviere_threshold) {
        river_type = TYPE_RIVIERE;
    } else if (flux >= params.affluent_threshold) {
        river_type = TYPE_AFFLUENT;
    }

    imageStore(river_type_out, pos, uvec4(river_type));
}
