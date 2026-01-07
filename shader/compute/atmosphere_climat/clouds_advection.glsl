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

// Lecture vent avec wrap
vec2 sampleWind(ivec2 p) {
    ivec2 wrapped = wrapCoords(p, int(params.width), int(params.height));
    vec4 climate = imageLoad(climate_texture, wrapped);
    return vec2(climate.b, climate.a);
}

// ============================================================================
// VORTICITÉ ET TURBULENCE
// ============================================================================

// Calcule la vorticité (rotation locale du champ de vent)
float computeVorticity(ivec2 pixel) {
    int w = int(params.width);
    int h = int(params.height);
    
    // Différences finies centrées pour le rotationnel
    vec2 windR = sampleWind(pixel + ivec2(1, 0));
    vec2 windL = sampleWind(pixel - ivec2(1, 0));
    vec2 windU = sampleWind(pixel + ivec2(0, 1));
    vec2 windD = sampleWind(pixel - ivec2(0, 1));
    
    // Vorticité = dv/dx - du/dy (composante Z du rotationnel 2D)
    float dvdx = (windR.y - windL.y) * 0.5;
    float dudy = (windU.x - windD.x) * 0.5;
    
    return dvdx - dudy;
}

// Calcule le gradient de la magnitude de vorticité pour le confinement
vec2 computeVorticityGradient(ivec2 pixel) {
    int w = int(params.width);
    int h = int(params.height);
    
    // Magnitude de vorticité aux voisins
    float vortR = abs(computeVorticity(wrapCoords(pixel + ivec2(1, 0), w, h)));
    float vortL = abs(computeVorticity(wrapCoords(pixel - ivec2(1, 0), w, h)));
    float vortU = abs(computeVorticity(wrapCoords(pixel + ivec2(0, 1), w, h)));
    float vortD = abs(computeVorticity(wrapCoords(pixel - ivec2(0, 1), w, h)));
    
    return vec2(
        (vortR - vortL) * 0.5,
        (vortU - vortD) * 0.5
    );
}

// Hash pour turbulence déterministe
uint turbHash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire le champ de vent et la vapeur courante
    vec4 climate = imageLoad(climate_texture, pixel);
    vec2 wind = vec2(climate.b, climate.a);
    float current_vapor = imageLoad(vapor_texture, pixel).r;
    
    // === 1. ADVECTION SEMI-LAGRANGIENNE ===
    vec2 pos = vec2(pixel) + 0.5;
    vec2 prev_pos = pos - wind * params.dt;
    float advected_vapor = bilinearSample(prev_pos);
    
    // === 2. CONFINEMENT DE VORTICITÉ (Vorticity Confinement) ===
    // Cette technique amplifie les rotations pour créer et maintenir
    // des cyclones, anticyclones et structures tourbillonnaires
    float vorticity = computeVorticity(pixel);
    vec2 vort_grad = computeVorticityGradient(pixel);
    float grad_len = length(vort_grad);
    
    vec2 vorticity_force = vec2(0.0);
    if (grad_len > 0.0001) {
        // Force perpendiculaire au gradient de vorticité
        // Cela pousse le fluide vers les zones de haute vorticité
        vec2 N = vort_grad / grad_len;
        // Coefficient de confinement (3.0-5.0 pour cyclones visibles)
        float confinement_strength = 4.0;
        vorticity_force = vec2(N.y, -N.x) * vorticity * confinement_strength;
    }
    
    // === 3. TURBULENCE STOCHASTIQUE ===
    // Ajoute du bruit cohérent qui varie lentement dans le temps
    uint h = turbHash(uint(pixel.x) * 374761393u + uint(pixel.y) * 668265263u);
    h ^= turbHash(params.iteration * 1274126177u);
    h = turbHash(h);
    float angle = float(h) / 4294967295.0 * 6.28318530718;
    // Turbulence proportionnelle à la vapeur (plus de mouvement où il y a des nuages)
    float turb_strength = current_vapor * 0.5;
    vec2 turbulence = vec2(cos(angle), sin(angle)) * turb_strength;
    
    // === 4. DIFFUSION LÉGÈRE ===
    // Moyenne avec les voisins pour lisser les gradients trop abrupts
    float neighbor_avg = (
        sampleVapor(pixel + ivec2(1, 0)) +
        sampleVapor(pixel - ivec2(1, 0)) +
        sampleVapor(pixel + ivec2(0, 1)) +
        sampleVapor(pixel - ivec2(0, 1))
    ) * 0.25;
    float diffusion = mix(advected_vapor, neighbor_avg, 0.02);
    
    // === 5. ADVECTION CORRIGÉE AVEC FORCES ===
    vec2 total_velocity = wind + (vorticity_force + turbulence) * params.dt;
    vec2 corrected_pos = pos - total_velocity * params.dt;
    float final_vapor = bilinearSample(corrected_pos);
    
    // Mélanger avec diffusion
    final_vapor = mix(final_vapor, diffusion, 0.1);
    
    // === 6. DISSIPATION ===
    final_vapor *= params.dissipation;
    
    // Écrire le résultat
    imageStore(vapor_temp_texture, pixel, vec4(final_vapor, 0.0, 0.0, 0.0));
}
