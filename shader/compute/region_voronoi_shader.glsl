#[compute]
#version 450

// ============================================================================
// REGION VORONOI SHADER - Political/Geographical Regions
// ============================================================================
// Génère des régions en calculant le diagramme de Voronoi
// Chaque pixel est assigné à la seed la plus proche
// ============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Texture Géophysique (R/W) - On stocke l'ID de région dans le canal B (Sediment)
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_map;

// Buffer de seeds (positions des centres de régions)
layout(set = 1, binding = 1, std430) readonly buffer SeedBuffer {
    vec2 seeds[];
};

// Wrap horizontal pour continuité cylindrique
vec2 wrap_distance(vec2 pos, vec2 seed, ivec2 image_size) {
    float dx = pos.x - seed.x;
    float dy = pos.y - seed.y;
    
    // Wrap horizontal (carte cylindrique)
    if (abs(dx) > float(image_size.x) * 0.5) {
        dx = dx > 0.0 ? dx - float(image_size.x) : dx + float(image_size.x);
    }
    
    return vec2(dx, dy);
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = imageSize(geo_map);
    
    if (pixel_coords.x >= image_size.x || pixel_coords.y >= image_size.y) {
        return;
    }
    
    vec2 pos = vec2(pixel_coords);
    
    // Trouver la seed la plus proche
    float min_distance = 999999.0;
    int closest_region = 0;
    
    for (int i = 0; i < seeds.length(); i++) {
        vec2 offset = wrap_distance(pos, seeds[i], image_size);
        float dist = length(offset);
        
        if (dist < min_distance) {
            min_distance = dist;
            closest_region = i;
        }
    }
    
    // Lire l'état actuel
    vec4 geo_state = imageLoad(geo_map, pixel_coords);
    
    // Stocker l'ID de région dans le canal B (normalisé 0-1)
    float region_id_normalized = float(closest_region) / float(seeds.length());
    geo_state.b = region_id_normalized;
    
    // Écrire le résultat
    imageStore(geo_map, pixel_coords, geo_state);
}