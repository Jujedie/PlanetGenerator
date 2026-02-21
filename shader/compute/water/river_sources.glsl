#[compute]
#version 450

// ============================================================================
// RIVER SOURCES SHADER - Initialisation distribuee du flux
// ============================================================================
// Remplace l'ancien systeme de sources discretes par grille.
// Chaque pixel terrestre contribue sa precipitation locale au reseau
// de drainage. Les rivieres emergent naturellement de l'accumulation
// du flux en aval - plus besoin de "sources" artificielles.
//
// Entrees :
// - geo_texture (RGBA32F) : R=height
// - climate_texture (RGBA32F) : R=temperature, G=precipitation
// - water_mask (R8UI) : Pour ne pas initialiser sur l'eau existante
//
// Sorties :
// - river_flux (R32F) : Flux initial = precipitation * scale
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 2, r8ui)    uniform readonly uimage2D water_mask;
layout(set = 0, binding = 3, r32f)    uniform writeonly image2D river_flux;

layout(set = 1, binding = 0, std140) uniform SourceParams {
    uint width;
    uint height;
    float sea_level;
    float precip_scale;  // Facteur d'echelle pour la precipitation (defaut: 1.0)
} params;

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x >= w || pixel.y >= h) return;

    // Pas de flux sur l'eau existante (oceans, lacs)
    uint water_type = imageLoad(water_mask, pixel).r;
    if (water_type > 0u) {
        imageStore(river_flux, pixel, vec4(0.0));
        return;
    }

    // Lire les donnees terrain et climat
    float height = imageLoad(geo_texture, pixel).r;
    float precipitation = imageLoad(climate_texture, pixel).g;

    // Pixels sous le niveau de la mer qui ne sont pas dans water_mask
    // (cas marginal) : pas de contribution
    if (height < params.sea_level) {
        imageStore(river_flux, pixel, vec4(0.0));
        return;
    }

    // Pas aux poles extremes (eviter artefacts de bord)
    if (pixel.y < 2 || pixel.y >= h - 2) {
        imageStore(river_flux, pixel, vec4(0.0));
        return;
    }

    // === CONTRIBUTION DISTRIBUEE ===
    // Chaque pixel terrestre contribue sa precipitation locale
    // Le flux initial represente la quantite d'eau de pluie locale
    float flux = max(precipitation, 0.0) * params.precip_scale;

    imageStore(river_flux, pixel, vec4(flux, 0.0, 0.0, 0.0));
}
