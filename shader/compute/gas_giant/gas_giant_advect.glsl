#[compute]
#version 450

// ============================================================================
// GAS GIANT ADVECT — advection semi-lagrangienne du colorant
// ============================================================================
// A chaque passe, chaque pixel "remonte" le champ de vélocité pour aller
// chercher la couleur qui s'écoulait vers lui (méthode semi-lagrangienne,
// standard en simulation fluide temps réel). Répété sur N passes, cela étire
// progressivement le colorant en filaments/tourbillons cohérents avec le
// champ de vélocité -- un vrai écoulement, pas un simple warp statique.
//
// Exécuté en ping-pong (dye_input -> dye_output) pendant N itérations,
// pilotées par l'orchestrateur (voir run_gas_giant_phase).
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D velocity_texture;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D dye_input;
layout(set = 0, binding = 2, rgba32f) uniform writeonly image2D dye_output;

layout(set = 1, binding = 0, std140) uniform AdvectParams {
    uint width;
    uint height;
    uint pass_index;
    float dt;         // pas d'advection (en pixels par itération)
    float sharpen;     // contre le flou de l'interpolation bilinéaire répétée (1.0 = neutre)
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

int wrapX(int x, int w) { return ((x % w) + w) % w; }
int clampY(int y, int h) { return clamp(y, 0, h - 1); }

// Échantillonnage bilinéaire manuel du colorant d'entrée (les images de
// stockage n'ont pas de filtrage matériel), avec wrap horizontal (longitude)
// et clamp vertical (pôles).
vec4 sampleDyeBilinear(vec2 pos, int w, int h) {
    float fx = floor(pos.x);
    float fy = floor(pos.y);
    float tx = pos.x - fx;
    float ty = pos.y - fy;

    int x0 = wrapX(int(fx), w);
    int x1 = wrapX(int(fx) + 1, w);
    int y0 = clampY(int(fy), h);
    int y1 = clampY(int(fy) + 1, h);

    vec4 c00 = imageLoad(dye_input, ivec2(x0, y0));
    vec4 c10 = imageLoad(dye_input, ivec2(x1, y0));
    vec4 c01 = imageLoad(dye_input, ivec2(x0, y1));
    vec4 c11 = imageLoad(dye_input, ivec2(x1, y1));

    vec4 top = mix(c00, c10, tx);
    vec4 bot = mix(c01, c11, tx);
    return mix(top, bot, ty);
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);
    if (pos.x >= w || pos.y >= h) return;

    vec4 vel = imageLoad(velocity_texture, pos);
    vec2 velocity = vel.rg;

    // Position remontée dans le champ de vélocité (backward trace)
    vec2 prev_pos = vec2(pos) - velocity * params.dt;

    vec4 advected = sampleDyeBilinear(prev_pos, w, h);

    // Léger regain de contraste pour compenser le flou introduit par
    // l'interpolation bilinéaire répétée sur de nombreuses itérations
    // (sinon les filaments finissent dilués en gris uniforme au bout
    // de quelques dizaines de passes).
    vec3 color = (advected.rgb - vec3(0.5)) * params.sharpen + vec3(0.5);
    color = clamp(color, 0.0, 1.0);

    imageStore(dye_output, pos, vec4(color, advected.a));
}
