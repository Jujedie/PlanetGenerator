#[compute]
#version 450

// ============================================================================
// GAS GIANT FINAL MAP — composition finale après advection fluide
// ============================================================================
// Lit le colorant après N itérations d'advection (gas_giant_advect.glsl) et
// le champ de vélocité (pour détecter les tempêtes via la vorticité), puis
// applique la modulation climatique et l'assombrissement polaire.
//
// Toute la "forme" fluide (bandes déformées, filaments, tourbillons) vient
// déjà du colorant advecté -- cette passe ne fait plus que l'habillage
// final (structure turbulente + éclairage).
//
// Entrées :
// - dye_texture (RGBA32F)      : colorant advecté (gas_giant_advect.glsl)
// - velocity_texture (RGBA32F) : R=vx, G=vy, B=vorticité locale
// - climate_texture (RGBA32F)  : réservée pour compatibilité de binding ;
//                                les géantes ne lancent plus les cartes de
//                                climat terrestre
//
// Sortie :
// - final_map (RGBA8) : Carte finale colorée
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D dye_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D velocity_texture;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D climate_texture;
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D final_map;

layout(set = 1, binding = 0, std140) uniform FinalParams {
    uint width;
    uint height;
    uint seed;
    float cylinder_radius;
    float avg_temperature;
    float padding1;
    float padding2;
    float padding3;
} params;

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    return x;
}

// ============================================================================
// COULEURS DE TEMPÊTE PAR SCHÉMA
// ============================================================================
// Doit rester synchronisé avec la sélection de schéma faite dans
// gas_giant_dye_init.glsl (même formule de hash sur le même seed).

const vec3 SPOT_0 = vec3(0.75, 0.35, 0.18);
const vec3 SPOT_1 = vec3(0.10, 0.20, 0.50);
const vec3 SPOT_2 = vec3(0.65, 0.55, 0.30);
const vec3 SPOT_3 = vec3(0.20, 0.50, 0.48);
const vec3 SPOT_4 = vec3(0.50, 0.18, 0.10);
const vec3 SPOT_5 = vec3(0.35, 0.22, 0.55);

vec3 getSpotColor(uint scheme) {
    switch (scheme) {
        case 0u: return SPOT_0;
        case 1u: return SPOT_1;
        case 2u: return SPOT_2;
        case 3u: return SPOT_3;
        case 4u: return SPOT_4;
        case 5u: return SPOT_5;
        default: return SPOT_0;
    }
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);
    if (pos.x >= w || pos.y >= h) return;

    float v = float(pos.y) / float(h);
    float lat = (v - 0.5) * 2.0;
    float abs_lat = abs(lat);

    vec4 dye = imageLoad(dye_texture, pos);
    vec3 base_color = dye.rgb;

    // === Turbulence des sommets nuageux ===
    // La vorticité est moyennée sur les voisins. Elle n'est plus peinte avec
    // une couleur sombre : les maxima du curl-noise sont des filaments, pas des
    // tempêtes ovales, et leur teinte foncée créait les taches verticales.
    float vC = imageLoad(velocity_texture, pos).b;
    float vN = imageLoad(velocity_texture, ivec2(pos.x, max(pos.y - 1, 0))).b;
    float vS = imageLoad(velocity_texture, ivec2(pos.x, min(pos.y + 1, h - 1))).b;
    float vE = imageLoad(velocity_texture, ivec2((pos.x + 1) % w, pos.y)).b;
    float vW = imageLoad(velocity_texture, ivec2((pos.x - 1 + w) % w, pos.y)).b;
    float vorticity_avg = (vC + vN + vS + vE + vW) / 5.0;

    float vortex_strength = smoothstep(0.60, 1.05, vorticity_avg);

    const uint NUM_SCHEMES = 6u;
    uint scheme_hash = hash(params.seed + 77777u);
    uint scheme_a = scheme_hash % NUM_SCHEMES;
    vec3 spot_tint = getSpotColor(scheme_a);
    float base_luminance = dot(base_color, vec3(0.2126, 0.7152, 0.0722));
    vec3 soft_storm_tint = mix(vec3(base_luminance), spot_tint, 0.20);
    base_color = mix(base_color, soft_storm_tint, vortex_strength * 0.12);
    base_color *= mix(1.0, 1.035, vortex_strength);

    // === Assombrissement aux pôles ===
    float polar_darkening = 1.0 - pow(abs_lat, 3.0) * 0.25;
    base_color *= polar_darkening;

    // === Compression des hautes lumières ===
    // Préserver des zones claires sans autoriser de grandes surfaces à 1.0.
    // Le plafond de luminance et celui des canaux rendent toutes les palettes
    // sûres, y compris après advection et turbulence.
    float luminance = dot(base_color, vec3(0.2126, 0.7152, 0.0722));
    base_color *= min(1.0, 0.80 / max(luminance, 0.001));
    float peak = max(base_color.r, max(base_color.g, base_color.b));
    base_color *= min(1.0, 0.90 / max(peak, 0.001));
    base_color = clamp(base_color, vec3(0.015), vec3(0.90));

    imageStore(final_map, pos, vec4(base_color, 1.0));
}
