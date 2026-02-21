#[compute]
#version 450

// ============================================================================
// RIVER PROPAGATION SHADER - Accumulation hydrologique conservatrice
// ============================================================================
// Simule l'accumulation du flux d'eau en suivant les directions D8
// pre-calculees. Chaque pixel collecte le flux de tous ses voisins
// qui drainent vers lui (backward-collect) et ajoute sa propre
// precipitation locale.
//
// APPROCHE : Collecte en amont avec conservation de masse
// - Utilise les directions D8 pre-calculees (plus de recalcul par passe)
// - Transfert a 100% (pas de decroissance artificielle)
// - Chaque pixel re-injecte sa precipitation a chaque passe (steady-state)
// - Convergence en O(longueur_plus_long_cours_d_eau) iterations
//
// Ce shader est execute en ping-pong (flux_input -> flux_output) pendant
// N iterations (N >= max(width, height)).
//
// Entrees :
// - flow_direction (R8UI) : Directions D8 pre-calculees (0-7, 255=puits)
// - water_mask (R8UI) : Pour absorber le flux a l'embouchure
// - climate_texture (RGBA32F) : G=precipitation (re-injection locale)
// - flux_input (R32F) : Flux actuel (ping)
//
// Sorties :
// - flux_output (R32F) : Flux mis a jour (pong)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, r8ui)    uniform readonly uimage2D flow_direction;
layout(set = 0, binding = 1, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 3, r32f)    uniform readonly image2D flux_input;
layout(set = 0, binding = 4, r32f)    uniform writeonly image2D flux_output;

layout(set = 1, binding = 0, std140) uniform PropagationParams {
    uint width;
    uint height;
    uint pass_index;
    float sea_level;
    float precip_scale;    // Meme facteur que river_sources
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

// 8 voisins (Moore neighborhood) - ordre identique a flow_direction
const ivec2 NEIGHBORS[8] = ivec2[8](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0),               ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

// Index du voisin oppose (si voisin[i] est NW, oppose est SE = index 7)
const int OPPOSITE[8] = int[8](7, 6, 5, 4, 3, 2, 1, 0);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

/// Wrap X pour projection equirectangulaire (cylindrique)
int wrapX(int x, int w) {
    return ((x % w) + w) % w;
}

/// Clamp Y pour les poles
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

    // Exclure les rangees polaires (pas de flux, coherent avec river_sources)
    if (pixel.y < 2 || pixel.y >= h - 2) {
        imageStore(flux_output, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        return;
    }

    // === PIXEL SUR L'EAU : absorbe le flux (embouchure) ===
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        // Conserver le flux accumule (pour debug/visualisation)
        float current = imageLoad(flux_input, pixel).r;
        imageStore(flux_output, pixel, vec4(current, 0.0, 0.0, 0.0));
        return;
    }

    // === RE-INJECTION DE LA PRECIPITATION LOCALE ===
    // Modele steady-state : chaque pixel contribue sa pluie a chaque iteration
    float precipitation = imageLoad(climate_texture, pixel).g;
    float new_flux = max(precipitation, 0.0) * params.precip_scale;

    // === COLLECTE DU FLUX EN AMONT ===
    // Pour chaque voisin, verifier si sa direction D8 pointe vers nous
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);

        // Pas de flux depuis l'eau
        uint n_water = imageLoad(water_mask, neighbor).r;
        if (n_water > 0u) continue;

        // Flux du voisin
        float n_flux = imageLoad(flux_input, neighbor).r;
        if (n_flux < 0.0001) continue;

        // Direction D8 du voisin (pre-calculee)
        uint n_dir = imageLoad(flow_direction, neighbor).r;

        // Le voisin i draine vers nous si sa direction D8 est l'oppose de i
        // (voisin au NW a direction=7 (SE) pointe vers nous si nous sommes en SE)
        if (n_dir == uint(OPPOSITE[i])) {
            // Transfert a 100% : conservation de masse
            new_flux += n_flux;
        }
    }

    // Plafond de securite pour eviter les valeurs infinies
    // (peut arriver si des cycles residuels existent dans le graphe de drainage)
    new_flux = min(new_flux, 1000000.0);

    imageStore(flux_output, pixel, vec4(new_flux, 0.0, 0.0, 0.0));
}
