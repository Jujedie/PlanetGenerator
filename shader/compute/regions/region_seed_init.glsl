#[compute]
#version 450

/*
 * Region Seed Initialization Shader
 * ==================================
 * Place les capitales (seeds) des régions avec distribution Poisson-like.
 * Deux modes : terrestre (water_height == 0) ou océanique (water_height > 0).
 * 
 * Utilise un placement par grille + rejection sampling pour garantir
 * une distribution uniforme avec espacement minimum.
 * 
 * Entrées :
 *   - geo : GeoTexture (A=water_height pour filtrer terre/océan)
 * 
 * Sortie :
 *   - region_state : Texture d'état des régions (R=region_id, G=cost_acc, B=is_border, A=parent_id)
 *   - region_seeds : Positions et quotas des capitales
 */

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures d'entrée
layout(rgba32f, binding = 0) uniform readonly image2D geo;

// Textures de sortie
layout(rgba32f, binding = 1) uniform image2D region_state;
layout(rgba32f, binding = 2) uniform writeonly image2D region_seeds;

// Paramètres uniformes
layout(std140, binding = 3) uniform Params {
    int width;
    int height;
    int num_regions;        // Nombre de régions à créer
    int is_ocean_mode;      // 0 = terrestre, 1 = océanique
    uint seed;              // Graine aléatoire
    int min_region_size;    // Taille minimale en pixels
    int max_region_size;    // Taille maximale en pixels
    float padding;          // Réservé pour alignement
};

// === FONCTIONS UTILITAIRES ===

// Hash pour pseudo-random déterministe
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

vec2 hash22(vec2 p, uint s) {
    uvec2 q = uvec2(floatBitsToUint(p.x), floatBitsToUint(p.y));
    uint h1 = hash(q.x ^ hash(q.y) ^ s);
    uint h2 = hash(h1);
    return vec2(float(h1) / 4294967295.0, float(h2) / 4294967295.0);
}

// Wrap X pour projection équirectangulaire
int wrapX(int x) {
    return (x + width) % width;
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
    
    // Calculer la grille de placement des seeds
    // On divise la carte en cellules et place une seed par cellule (si valide)
    float cell_size = sqrt(float(width * height) / float(num_regions));
    int grid_cols = int(ceil(float(width) / cell_size));
    int grid_rows = int(ceil(float(height) / cell_size));
    
    int cell_x = int(float(pixel.x) / cell_size);
    int cell_y = int(float(pixel.y) / cell_size);
    int cell_id = cell_y * grid_cols + cell_x;
    
    // Calculer la position du seed dans cette cellule (jitter)
    vec2 cell_base = vec2(float(cell_x) * cell_size, float(cell_y) * cell_size);
    vec2 jitter = hash22(cell_base, seed) * 0.6 + 0.2;  // [0.2, 0.8] pour éviter les bords
    ivec2 seed_pos = ivec2(cell_base + jitter * cell_size);
    seed_pos.x = wrapX(seed_pos.x);
    seed_pos.y = clamp(seed_pos.y, 0, height - 1);
    
    // Vérifier si ce pixel est la position du seed de sa cellule
    bool is_seed_position = (pixel.x == seed_pos.x && pixel.y == seed_pos.y);
    
    // Lire les données géophysiques
    vec4 geo_data = imageLoad(geo, pixel);
    float water_height = geo_data.a;
    
    // Vérifier si le terrain correspond au mode (terre vs océan)
    bool valid_terrain = (is_ocean_mode == 0) ? (water_height <= 0.0) : (water_height > 0.0);
    
    // Initialiser l'état de la région pour ce pixel
    vec4 state = vec4(-1.0, 1e10, 0.0, -1.0);  // Non-assigné, coût infini
    
    if (is_seed_position && valid_terrain && cell_id < num_regions) {
        // Ce pixel est une capitale de région
        float region_id = float(cell_id);
        
        // Calculer le quota (taille cible) avec variation aléatoire
        float avg_size = float(width * height) / float(num_regions);
        if (is_ocean_mode == 0) {
            // Pour terrestre, réduire proportionnellement à l'eau
            avg_size *= 0.5;  // Approximation, sera ajusté dynamiquement
        }
        float size_variation = hash21(vec2(float(cell_id), float(seed))) * 0.5 + 0.75;  // [0.75, 1.25]
        float quota = clamp(avg_size * size_variation, float(min_region_size), float(max_region_size));
        
        // Écrire l'état : région assignée, coût = 0 (capitale)
        state = vec4(region_id, 0.0, 0.0, region_id);
        
        // Écrire les infos de seed dans la texture dédiée
        // R=pos_x, G=pos_y, B=quota, A=current_count (initialement 1)
        imageStore(region_seeds, ivec2(cell_id, 0), vec4(float(pixel.x), float(pixel.y), quota, 1.0));
    }
    
    // Stocker l'état initial
    imageStore(region_state, pixel, state);
}
