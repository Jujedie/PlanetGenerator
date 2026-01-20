   #[compute]
#version 450

// ============================================================================
// BIOME BORDER IRREGULARITY SHADER
// Adds natural irregularity to biome boundaries by randomly swapping
// border pixels with neighboring biomes based on high-frequency noise.
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0: TEXTURES ===
// Binding 0: biome texture (read/write in place)
layout(set = 0, binding = 0, rgba8) uniform image2D biome_colored;

// Binding 1: ice_caps (for banquise protection)
layout(set = 0, binding = 1, rgba8) uniform readonly image2D ice_caps;

// Binding 2: river_flux (for river protection)
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux_texture;

// === SET 1: PARAMETERS UBO ===
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    uint width;
    uint height;
    float river_threshold;
    float border_noise_frequency;  // ~25.0 / width for detail
    float swap_threshold;          // Noise value threshold to swap (default: 0.4)
    float padding1;
    float padding2;
};

// ============================================================================
// NEIGHBOR SAMPLING WITH WRAP X / CLAMP Y
// ============================================================================

ivec2 getNeighbor(ivec2 pos, int dx, int dy) {
    int nx = (pos.x + dx) % int(width);
    if (nx < 0) nx += int(width);
    int ny = clamp(pos.y + dy, 0, int(height) - 1);
    return ivec2(nx, ny);
}

// ============================================================================
// COLOR COMPARISON
// ============================================================================

bool colorEquals(vec4 a, vec4 b) {
    return abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01;
}

// ============================================================================
// SIMPLEX NOISE (high frequency detail)
// ============================================================================

vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x*34.0)+1.0)*x); }

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

float fbm_detail(vec2 p, float freq, uint s) {
    float value = 0.0;
    float amplitude = 1.0;
    float max_amp = 0.0;
    vec2 offset = vec2(float(s) * 0.71, float(s) * 0.83);
    
    // Increased octaves from 4 to 6 for more detail in border irregularity
    for (int i = 0; i < 6; i++) {
        value += amplitude * snoise((p + offset) * freq);
        max_amp += amplitude;
        amplitude *= 0.5;
        freq *= 2.0;
    }
    
    return value / max_amp;  // Returns [-1, 1]
}

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    
    if (pos.x >= int(width) || pos.y >= int(height)) {
        return;
    }
    
    // Check if this pixel is protected
    vec4 ice = imageLoad(ice_caps, pos);
    float river_flux = imageLoad(river_flux_texture, pos).r;
    
    bool is_banquise = ice.a > 0.0;
    bool is_river = river_flux > river_threshold;
    
    if (is_banquise || is_river) {
        return;  // Don't modify protected pixels
    }
    
    vec4 current_color = imageLoad(biome_colored, pos);
    
    // Check if this is a border pixel and collect neighbor biomes
    bool is_border = false;
    vec4 neighbor_biomes[8];
    uint num_neighbors = 0u;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            ivec2 n_pos = getNeighbor(pos, dx, dy);
            
            // Skip river neighbors
            float n_flux = imageLoad(river_flux_texture, n_pos).r;
            if (n_flux > river_threshold) continue;
            
            vec4 n_color = imageLoad(biome_colored, n_pos);
            
            if (!colorEquals(n_color, current_color)) {
                is_border = true;
                
                // Add to neighbor list if not already present
                bool found = false;
                for (uint i = 0u; i < num_neighbors; i++) {
                    if (colorEquals(neighbor_biomes[i], n_color)) {
                        found = true;
                        break;
                    }
                }
                
                if (!found && num_neighbors < 8u) {
                    neighbor_biomes[num_neighbors++] = n_color;
                }
            }
        }
    }
    
    // If it's a border and we have different neighbors, maybe swap
    if (is_border && num_neighbors > 0u) {
        float noise_val = fbm_detail(vec2(pos), border_noise_frequency, seed);
        
        // Swap if noise exceeds threshold (~30% of borders when threshold=0.4)
        if (noise_val > swap_threshold) {
            // Select neighbor based on noise
            float normalized = (noise_val + 1.0) * 0.5;  // [0, 1]
            uint index = uint(normalized * float(num_neighbors)) % num_neighbors;
            
            imageStore(biome_colored, pos, neighbor_biomes[index]);
        }
    }
}
