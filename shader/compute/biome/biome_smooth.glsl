#[compute]
#version 450

// ============================================================================
// BIOME SMOOTHING SHADER
// Applies majority voting to smooth biome boundaries.
// Uses ping-pong between biome_colored and biome_temp.
// Protects rivers and banquise from modification.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
// Binding 0: source biome texture (read)
layout(set = 0, binding = 0, rgba8) uniform readonly image2D biome_source;

// Binding 1: destination biome texture (write)
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D biome_dest;

// Binding 2: ice_caps (for banquise protection)
layout(set = 0, binding = 2, rgba8) uniform readonly image2D ice_caps;

// Binding 3: river_flux (for river protection)
layout(set = 0, binding = 3, r32f) uniform readonly image2D river_flux_texture;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    uint width;
    uint height;
    float river_threshold;
    uint majority_threshold;  // Minimum neighbor count to change (default: 5)
    float padding1;
    float padding2;
    float padding3;
};

// ============================================================================
// NEIGHBOR SAMPLING WITH WRAP X / CLAMP Y
// ============================================================================

ivec2 getNeighbor(ivec2 pos, int dx, int dy) {
    int nx = (pos.x + dx) % int(width);
    if (nx < 0) nx += int(width);  // Handle negative wrap
    int ny = clamp(pos.y + dy, 0, int(height) - 1);
    return ivec2(nx, ny);
}

// ============================================================================
// COLOR COMPARISON
// ============================================================================

// Compare two colors for equality (with small epsilon for floating point)
bool colorEquals(vec4 a, vec4 b) {
    return abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01;
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    if (pos.x >= int(width) || pos.y >= int(height)) {
        return;
    }
    
    // Check if this pixel is protected (river or banquise)
    vec4 ice = imageLoad(ice_caps, pos);
    float river_flux = imageLoad(river_flux_texture, pos).r;
    
    bool is_banquise = ice.a > 0.0;
    bool is_river = river_flux > river_threshold;
    
    vec4 current_color = imageLoad(biome_source, pos);
    
    // If protected, just copy
    if (is_banquise || is_river) {
        imageStore(biome_dest, pos, current_color);
        return;
    }
    
    // Collect neighbor colors and count occurrences
    // We use a simple approach: store up to 8 unique colors with counts
    vec4 unique_colors[8];
    uint color_counts[8];
    uint num_unique = 0u;
    
    // Initialize
    for (int i = 0; i < 8; i++) {
        color_counts[i] = 0u;
    }
    
    // Sample 8 neighbors
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            ivec2 n_pos = getNeighbor(pos, dx, dy);
            
            // Check if neighbor is a river (skip river colors in voting)
            float n_flux = imageLoad(river_flux_texture, n_pos).r;
            if (n_flux > river_threshold) continue;
            
            vec4 n_color = imageLoad(biome_source, n_pos);
            
            // Find or add this color
            bool found = false;
            for (uint i = 0u; i < num_unique; i++) {
                if (colorEquals(unique_colors[i], n_color)) {
                    color_counts[i]++;
                    found = true;
                    break;
                }
            }
            
            if (!found && num_unique < 8u) {
                unique_colors[num_unique] = n_color;
                color_counts[num_unique] = 1u;
                num_unique++;
            }
        }
    }
    
    // Find the most common color
    uint max_count = 0u;
    vec4 best_color = current_color;
    
    for (uint i = 0u; i < num_unique; i++) {
        if (color_counts[i] > max_count) {
            max_count = color_counts[i];
            best_color = unique_colors[i];
        }
    }
    
    // Apply majority voting if threshold is met
    vec4 final_color = current_color;
    if (max_count >= majority_threshold) {
        final_color = best_color;
    }
    
    imageStore(biome_dest, pos, final_color);
}
