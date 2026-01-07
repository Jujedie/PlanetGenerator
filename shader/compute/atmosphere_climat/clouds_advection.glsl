#[compute]
#version 450

// ============================================================================
// CLOUDS ADVECTION SHADER - Étape 3.3b : Transport Semi-Lagrangien
// ============================================================================
// Transporte la densité de vapeur le long du champ de vent.
// Utilise un schéma semi-lagrangien avec interpolation bilinéaire.
// Gère le wrap cylindrique (seamless X, clamp Y).
//
// Entrées :
// - vapor_texture : densité de vapeur courante
// - climate_texture.BA : champ de vent (wind_x, wind_y)
//
// Sorties :
// - vapor_temp_texture : densité de vapeur advectée (ping-pong)
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Texture d'entrée : VaporTexture courante (lecture)
layout(set = 0, binding = 0, r32f) uniform readonly image2D vapor_texture;

// Texture de sortie : VaporTempTexture (ping-pong, écriture)
layout(set = 0, binding = 1, r32f) uniform writeonly image2D vapor_temp_texture;

// Texture d'entrée : ClimateTexture pour le vent (lecture)
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D climate_texture;

// Uniform Buffer
layout(set = 1, binding = 0, std140) uniform AdvectionParams {
    uint width;
    uint height;
    float dt;               // Pas de temps (0.1 - 1.0)
    float dissipation;      // Facteur de dissipation (0.99 - 1.0)
    uint iteration;         // Numéro d'itération courant
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// INTERPOLATION BILINÉAIRE AVEC WRAP CYLINDRIQUE
// ============================================================================

// Wrap X (cyclique), Clamp Y
ivec2 wrapCoords(ivec2 p, int w, int h) {
    // Wrap X : modulo positif
    int x = p.x;
    while (x < 0) x += w;
    x = x % w;
    
    // Clamp Y
    int y = clamp(p.y, 0, h - 1);
    
    return ivec2(x, y);
}

// Lecture avec wrap
float sampleVapor(ivec2 p) {
    ivec2 wrapped = wrapCoords(p, int(params.width), int(params.height));
    return imageLoad(vapor_texture, wrapped).r;
}

// Interpolation bilinéaire avec wrap
float bilinearSample(vec2 pos) {
    // Position fractionnaire
    vec2 p = pos - 0.5; // Centrer sur le pixel
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    
    // Échantillonner les 4 voisins
    float v00 = sampleVapor(i);
    float v10 = sampleVapor(i + ivec2(1, 0));
    float v01 = sampleVapor(i + ivec2(0, 1));
    float v11 = sampleVapor(i + ivec2(1, 1));
    
    // Interpolation bilinéaire
    float v0 = mix(v00, v10, f.x);
    float v1 = mix(v01, v11, f.x);
    return mix(v0, v1, f.y);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire le champ de vent
    vec4 climate = imageLoad(climate_texture, pixel);
    vec2 wind = vec2(climate.b, climate.a);
    
    // === Schéma Semi-Lagrangien ===
    // Tracer en arrière pour trouver la position source
    vec2 pos = vec2(pixel) + 0.5; // Centrer sur le pixel
    vec2 prev_pos = pos - wind * params.dt;
    
    // Échantillonner la vapeur à la position source (avec interpolation)
    float advected_vapor = bilinearSample(prev_pos);
    
    // Appliquer la dissipation (légère perte de vapeur)
    advected_vapor *= params.dissipation;
    
    // Écrire le résultat
    imageStore(vapor_temp_texture, pixel, vec4(advected_vapor, 0.0, 0.0, 0.0));
}
