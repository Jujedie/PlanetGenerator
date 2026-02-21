#[compute]
#version 450

// ============================================================================
// RIVER OCEAN CONNECT SHADER - Verification de connectivite a l'OCEAN
// ============================================================================
// Propage un drapeau "connecte a l'ocean" en remontant le graphe de drainage.
// Seules les rivieres qui atteignent effectivement l'EAU SALEE (ocean/mer)
// seront conservees dans la classification finale.
//
// APPROCHE : Propagation amont iterative
// - Initialisation : les pixels d'eau SALEE (water_mask==1) sont marques "connectes"
// - Les lacs d'eau douce propagent la connectivite de facon bidirectionnelle :
//   si un voisin quelconque est connecte, le lac l'est aussi (pass-through)
// - Les pixels terrestres suivent la propagation aval classique
// - Apres convergence, les bassins versants atteignant l'ocean sont marques
//
// Resultat : les rivieres traversant des lacs avant d'atteindre la mer sont
// conservees, mais les rivieres se terminant a un lac isole sont filtrees.
//
// Ce shader est execute en ping-pong pendant N iterations.
//
// Entrees :
// - flow_direction (R8UI) : Directions D8 (0-7, 255=puits)
// - water_mask (R8UI) : Plans d'eau existants
// - connect_input (R8UI) : Etat connectivite actuel (ping)
//
// Sorties :
// - connect_output (R8UI) : Etat connectivite mis a jour (pong)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, r8ui)  uniform readonly uimage2D flow_direction;
layout(set = 0, binding = 1, r8ui)  uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r8ui)  uniform readonly uimage2D connect_input;
layout(set = 0, binding = 3, r8ui)  uniform writeonly uimage2D connect_output;

layout(set = 1, binding = 0, std140) uniform ConnectParams {
    uint width;
    uint height;
    uint pass_index;
    uint padding;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

const uint DIR_SINK = 255u;

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

    // Seuls les pixels d'eau SALEE (ocean) seedent la connectivite
    // water_mask: 0=terre, 1=saltwater/ocean, 2=freshwater/lac
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type == 1u) {
        imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
        return;
    }

    // Lacs d'eau douce : propagation bidirectionnelle (pass-through)
    // Un lac est connecte si N'IMPORTE quel voisin est connecte ou est eau salee.
    // Cela permet a la connectivite de "traverser" les lacs vers l'interieur,
    // mais un lac isole (sans voisin connecte) reste non-connecte.
    if (water_type == 2u) {
        uint current_state = imageLoad(connect_input, pixel).r;
        if (current_state > 0u) {
            imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
            return;
        }
        for (int i = 0; i < 8; i++) {
            int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
            int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
            ivec2 nb = ivec2(nx, ny);
            // Voisin eau salee -> connecte
            uint n_water = imageLoad(water_mask, nb).r;
            if (n_water == 1u) {
                imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
                return;
            }
            // Voisin deja marque connecte -> connecte
            uint n_state = imageLoad(connect_input, nb).r;
            if (n_state > 0u) {
                imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
                return;
            }
        }
        imageStore(connect_output, pixel, uvec4(0u, 0u, 0u, 0u));
        return;
    }

    // Depressions terrestres (DIR_SINK) = lacs virtuels -> toujours connectes
    // Une depression sans exutoire formerait naturellement un lac
    uint my_dir_check = imageLoad(flow_direction, pixel).r;
    if (my_dir_check >= 8u) {
        imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
        return;
    }

    // Si deja connecte dans la passe precedente, rester connecte
    uint current_state = imageLoad(connect_input, pixel).r;
    if (current_state > 0u) {
        imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
        return;
    }

    // Verifier si notre voisin en aval (flow_direction) est connecte
    uint my_dir = imageLoad(flow_direction, pixel).r;

    if (my_dir < 8u) {
        int nx = wrapX(pixel.x + NEIGHBORS[my_dir].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[my_dir].y, h);
        ivec2 downstream = ivec2(nx, ny);

        // Si le voisin en aval est de l'eau SALEE -> connecte directement
        // Si le voisin en aval est un lac connecte -> connecte aussi
        uint down_water = imageLoad(water_mask, downstream).r;
        if (down_water == 1u) {
            imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
            return;
        }

        // Si le voisin en aval est deja marque connecte -> nous aussi
        // (couvre: terre connectee, lac connecte via pass-through)
        uint down_state = imageLoad(connect_input, downstream).r;
        if (down_state > 0u) {
            imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
            return;
        }
    }

    // Pas encore connecte
    imageStore(connect_output, pixel, uvec4(0u, 0u, 0u, 0u));
}
