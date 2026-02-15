#[compute]
#version 450

// ============================================================================
// RIVER CLASSIFY SHADER - Classification des rivieres en biomes
// ============================================================================
// Ce shader prend la carte de flux des rivieres et assigne un biome riviere
// a chaque pixel qui depasse le seuil de flux minimum.
//
// AMELIORATIONS par rapport a l'ancienne version :
// 1. Filtrage par connectivite ocean (ocean_reachable)
// 2. Expansion de largeur : les grands fleuves sont visuellement plus larges
// 3. Seuils ajustes pour le nouveau modele d'accumulation distribuee
//
// Classification par flux :
// - flux >= fleuve_threshold  -> Fleuve (type 2)
// - flux >= riviere_threshold -> Riviere (type 1)
// - flux >= affluent_threshold -> Affluent (type 0)
// - flux < affluent_threshold -> pas de riviere (0xFFFFFFFF)
//
// Expansion de largeur :
// - Fleuves : pixels adjacents avec flux >= affluent_threshold heritent
// - Rivieres : mecanisme similaire a moindre echelle
//
// Entrees :
// - river_flux (R32F) : Flux accumule
// - climate_texture (RGBA32F) : R=temperature
// - water_mask (R8UI) : Pour eviter de classifier sur l'eau existante
// - ocean_reachable (R8UI) : Connectivite a l'ocean
// - RiverBiomeLUT (SSBO) : Biomes riviere avec couleurs et plages de temperature
//
// Sorties :
// - river_biome_id (R32UI) : Index du biome riviere (0xFFFFFFFF = pas de riviere)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
layout(set = 0, binding = 0, r32f)    uniform readonly image2D river_flux;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 3, r8ui)    uniform readonly uimage2D ocean_reachable;
layout(set = 0, binding = 4, r32ui)   uniform writeonly uimage2D river_biome_id;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0, std140) uniform ClassifyParams {
    uint width;
    uint height;
    float affluent_threshold;   // Seuil flux min pour affluent (ex: 50.0)
    float riviere_threshold;    // Seuil flux min pour riviere (ex: 200.0)
    float fleuve_threshold;     // Seuil flux min pour fleuve (ex: 800.0)
    float padding1;
    float padding2;
    float padding3;
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

/// Trouve le meilleur biome riviere correspondant au type et a la temperature
uint findBestRiverBiome(int river_type, float temperature) {
    uint best_match = 0xFFFFFFFFu;
    float best_score = -1e10;
    uint fallback_match = 0xFFFFFFFFu;
    float fallback_score = -1e10;

    for (uint i = 0u; i < river_biome_count; i++) {
        RiverBiomeData b = river_biomes[i];

        // Verifier la compatibilite de temperature
        if (temperature < b.temp_min || temperature > b.temp_max) continue;

        // Score base sur la specificite de la plage de temperature
        float range = b.temp_max - b.temp_min;
        float score = 1000.0 / max(range, 1.0);

        // Match exact du type de riviere
        if (b.river_type == uint(river_type)) {
            if (score > best_score) {
                best_score = score;
                best_match = i;
            }
        }

        // Fallback : n'importe quel type de riviere (pas lac)
        if (b.river_type <= 2u || b.river_type == 5u) {
            if (score > fallback_score) {
                fallback_score = score;
                fallback_match = i;
            }
        }
    }

    return (best_match != 0xFFFFFFFFu) ? best_match : fallback_match;
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

    // Pas de riviere sur l'eau existante
    uint water_type = imageLoad(water_mask, pos).r;
    if (water_type > 0u) {
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }

    // === VERIFICATION CONNECTIVITE OCEAN ===
    // Seules les rivieres atteignant un plan d'eau sont conservees
    uint reachable = imageLoad(ocean_reachable, pos).r;
    if (reachable == 0u) {
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }

    // Lire le flux de ce pixel
    float flux = imageLoad(river_flux, pos).r;

    // === EXPANSION DE LARGEUR ===
    // Verifier si un voisin a un flux tres eleve (fleuve/riviere)
    // Si oui, ce pixel peut heriter d'une classification elargie
    float max_neighbor_flux = 0.0;
    for (int i = 0; i < 8; i++) {
        int nx = wrapX(pos.x + NEIGHBORS[i].x, w);
        int ny = clampY(pos.y + NEIGHBORS[i].y, h);
        ivec2 np = ivec2(nx, ny);

        uint nw = imageLoad(water_mask, np).r;
        if (nw > 0u) continue;

        float nf = imageLoad(river_flux, np).r;
        max_neighbor_flux = max(max_neighbor_flux, nf);
    }

    // Determiner le type de riviere
    // Le pixel propre definit le type de base
    // L'expansion de largeur peut promouvoir le type
    int river_type = -1;

    if (flux >= params.fleuve_threshold) {
        river_type = 2;  // Fleuve
    } else if (flux >= params.riviere_threshold) {
        river_type = 1;  // Riviere
    } else if (flux >= params.affluent_threshold) {
        river_type = 0;  // Affluent
    }
    // Expansion : si un voisin est un fleuve et nous avons au moins un peu de flux
    else if (max_neighbor_flux >= params.fleuve_threshold && flux >= params.affluent_threshold * 0.3) {
        river_type = 2;  // Herite de la largeur du fleuve
    }
    // Expansion : si un voisin est une riviere et nous avons du flux
    else if (max_neighbor_flux >= params.riviere_threshold && flux >= params.affluent_threshold * 0.5) {
        river_type = 1;  // Herite de la largeur de la riviere
    }

    if (river_type < 0) {
        imageStore(river_biome_id, pos, uvec4(biome_index));
        return;
    }

    // Lire la temperature locale
    float temperature = imageLoad(climate_texture, pos).r;

    // Chercher le meilleur biome riviere correspondant
    biome_index = findBestRiverBiome(river_type, temperature);

    imageStore(river_biome_id, pos, uvec4(biome_index));
}
