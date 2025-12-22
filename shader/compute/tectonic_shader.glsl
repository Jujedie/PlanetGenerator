#[compute]
#version 450

// Jump Flooding Algorithm pour plaques tectoniques Voronoi
// Basé sur "Jump Flooding in GPU with Applications to Voronoi Diagram" (Rong & Tan, 2006)

layout(local_size_x = 16, local_size_y = 16) in;

// Textures
layout(rgba32f, set = 0, binding = 0) uniform readonly image2D input_seeds;  // Seeds initiales
layout(rgba32f, set = 0, binding = 1) uniform writeonly image2D output_plates;

// Push constants (paramètres CPU)
layout(push_constant) uniform Params {
    int step_size;      // Distance de jump (512 -> 256 -> 128... -> 1)
    int num_plates;     // Nombre de plaques (20-30 recommandé)
    float planet_radius;// Rayon planète pour métriques sphériques
    uint iteration;     // Itération actuelle (pour debug)
} params;

const float PI = 3.14159265359;
const ivec2 RESOLUTION = ivec2(2048, 1024);  // Équirectangulaire

// === WRAPPING HORIZONTAL SEAMLESS ===
ivec2 wrap_coords(ivec2 coord) {
    coord.x = coord.x % RESOLUTION.x;
    if (coord.x < 0) coord.x += RESOLUTION.x;
    coord.y = clamp(coord.y, 0, RESOLUTION.y - 1);  // Pas de wrap vertical
    return coord;
}

// === DISTANCE GÉODÉSIQUE (GREAT CIRCLE) ===
// Convertit UV équirectangulaire en coordonnées sphériques et calcule la vraie distance
float geodesic_distance(vec2 uv1, vec2 uv2) {
    vec2 duv = uv2 - uv1;
    
    // Correction du wrapping X (plus court chemin sur le cylindre)
    if (abs(duv.x) > 0.5) duv.x = 1.0 - abs(duv.x);
    
    // Latitude moyenne pour l'échelle métrique
    float avg_y = (uv1.y + uv2.y) * 0.5;
    float phi = (avg_y - 0.5) * PI;
    float scale_x = cos(phi);
    
    // Distance approximée (Pythagore corrigé)
    // Plus rapide que Great Circle (acos/sin) et suffisant pour Voronoi local
    vec2 dist_m = vec2(duv.x * scale_x, duv.y) * params.planet_radius * 2.0 * PI;
    
    return length(dist_m);
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, RESOLUTION))) return;
    
    vec2 uv = vec2(pixel) / vec2(RESOLUTION);
    
    // Lire la seed actuelle (R=PlateID, GB=Seed_UV_Position, A=unused)
    vec4 current = imageLoad(input_seeds, pixel);
    vec2 current_seed = current.gb;
    float current_dist = geodesic_distance(uv, current_seed);
    
    // Jump Flooding: examiner 8 voisins à distance step_size
    int step = params.step_size;
    vec2 best_seed = current_seed;
    float best_dist = current_dist;
    float best_id = current.r;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            ivec2 neighbor_coord = wrap_coords(pixel + ivec2(dx, dy) * step);
            vec4 neighbor = imageLoad(input_seeds, neighbor_coord);
            
            vec2 neighbor_seed = neighbor.gb;
            if (neighbor_seed == vec2(0.0)) continue;  // Pas de seed ici
            
            float dist = geodesic_distance(uv, neighbor_seed);
            if (dist < best_dist) {
                best_dist = dist;
                best_seed = neighbor_seed;
                best_id = neighbor.r;
            }
        }
    }
    
    // Écrire le résultat (R=PlateID, GB=Seed_UV, A=Distance)
    imageStore(output_plates, pixel, vec4(best_id, best_seed, best_dist));
}
