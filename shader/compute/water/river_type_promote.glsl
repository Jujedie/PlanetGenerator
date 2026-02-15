#[compute]
#version 450

// ============================================================================
// RIVER TYPE PROMOTE SHADER - Promotion de type le long du chenal principal
// ============================================================================
// Propage le type de riviere EN AMONT le long du chenal principal.
// A chaque confluence, le pixel avec le flux le plus eleve (chenal principal)
// herite du type de son voisin en aval. Les affluents gardent leur type.
//
// Resultat apres convergence :
// - Le chenal principal d'un fleuve est entierement classifie "fleuve"
// - Les tributaires majeurs sont classifies "riviere"
// - Les petits tributaires restent "affluent"
//
// Ce shader est execute en ping-pong pendant N iterations.
//
// Entrees :
// - river_type_in (R8UI) : Type actuel (ping)
// - river_flux (R32F) : Flux pour identifier le chenal principal
// - flow_direction (R8UI) : Directions D8 (0-7, 255=puits)
//
// Sorties :
// - river_type_out (R8UI) : Type promu (pong)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, r8ui)  uniform readonly uimage2D river_type_in;
layout(set = 0, binding = 1, r8ui)  uniform writeonly uimage2D river_type_out;
layout(set = 0, binding = 2, r32f)  uniform readonly image2D river_flux;
layout(set = 0, binding = 3, r8ui)  uniform readonly uimage2D flow_direction;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform PromoteParams {
    uint width;
    uint height;
    uint padding1;
    uint padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint TYPE_FLEUVE = 2u;
const uint TYPE_NONE   = 255u;
const uint DIR_SINK    = 255u;

const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

int wrapX(int x, int w) {
    return ((x % w) + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) return;

    uint my_type = imageLoad(river_type_in, pixel).r;

    // Pas une riviere ou deja le type maximum → passer
    if (my_type == TYPE_NONE || my_type == TYPE_FLEUVE) {
        imageStore(river_type_out, pixel, uvec4(my_type));
        return;
    }

    // Trouver le pixel en aval
    uint my_dir = imageLoad(flow_direction, pixel).r;
    if (my_dir >= 8u) {
        // Puits (bord de l'eau, pole) → garder le type
        imageStore(river_type_out, pixel, uvec4(my_type));
        return;
    }

    int dnx = wrapX(pixel.x + NEIGHBORS[my_dir].x, w);
    int dny = clampY(pixel.y + NEIGHBORS[my_dir].y, h);
    ivec2 downstream = ivec2(dnx, dny);

    uint down_type = imageLoad(river_type_in, downstream).r;

    // Le pixel en aval a un type egal ou inferieur → pas de promotion
    if (down_type == TYPE_NONE || down_type <= my_type) {
        imageStore(river_type_out, pixel, uvec4(my_type));
        return;
    }

    // === VERIFICATION CHENAL PRINCIPAL ===
    // On est promu seulement si on est le contributeur avec le flux
    // le plus eleve parmi tous ceux qui drainent vers notre aval.
    // Cela garantit que seul le chenal principal herite du type superieur,
    // et les tributaires gardent leur type d'origine.
    float my_flux = imageLoad(river_flux, pixel).r;
    bool is_main_channel = true;

    for (int i = 0; i < 8; i++) {
        int cnx = wrapX(downstream.x + NEIGHBORS[i].x, w);
        int cny = clampY(downstream.y + NEIGHBORS[i].y, h);
        ivec2 candidate = ivec2(cnx, cny);

        // Ignorer soi-meme
        if (candidate.x == pixel.x && candidate.y == pixel.y) continue;

        // Est-ce que ce candidat draine aussi vers notre aval ?
        uint c_dir = imageLoad(flow_direction, candidate).r;
        if (c_dir >= 8u) continue;

        int cdnx = wrapX(candidate.x + NEIGHBORS[c_dir].x, w);
        int cdny = clampY(candidate.y + NEIGHBORS[c_dir].y, h);

        if (cdnx == downstream.x && cdny == downstream.y) {
            // Ce candidat draine aussi vers downstream
            float c_flux = imageLoad(river_flux, candidate).r;
            if (c_flux > my_flux) {
                is_main_channel = false;
                break;
            }
        }
    }

    if (is_main_channel) {
        // Promouvoir au type du pixel en aval (chenal principal)
        imageStore(river_type_out, pixel, uvec4(down_type));
    } else {
        // Tributaire → garder le type d'origine
        imageStore(river_type_out, pixel, uvec4(my_type));
    }
}
