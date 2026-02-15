#[compute]
#version 450

// ============================================================================
// RIVER OCEAN CONNECT SHADER - Verification de connectivite a l'ocean
// ============================================================================
// Propage un drapeau "connecte a l'ocean" en remontant le graphe de drainage.
// Seules les rivieres qui atteignent effectivement un plan d'eau (ocean, lac)
// seront conservees dans la classification finale.
//
// APPROCHE : Propagation amont iterative
// - Initialisation : tous les pixels d'eau sont marques "connectes"
// - Chaque iteration : un pixel terrestre est marque "connecte" si son
//   voisin en aval (selon flow_direction) est deja connecte
// - Apres convergence, tous les pixels du bassin versant qui atteignent
//   l'ocean sont marques
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

    // Les pixels d'eau sont toujours "connectes" (ce sont les destinations)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
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

        // Si le voisin en aval est un plan d'eau -> connecte
        uint down_water = imageLoad(water_mask, downstream).r;
        if (down_water > 0u) {
            imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
            return;
        }

        // Si le voisin en aval est deja marque connecte -> nous aussi
        uint down_state = imageLoad(connect_input, downstream).r;
        if (down_state > 0u) {
            imageStore(connect_output, pixel, uvec4(1u, 0u, 0u, 0u));
            return;
        }
    }

    // Pas encore connecte
    imageStore(connect_output, pixel, uvec4(0u, 0u, 0u, 0u));
}
