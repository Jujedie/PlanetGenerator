#[compute]
#version 450

// Worlds without a liquid-surface phase still expose these textures to later
// biome, administration, final-map and export shaders. RenderingDevice texture
// allocation does not initialize VRAM, so establish the complete disabled
// hydrology contract in one GPU pass instead of uploading large CPU buffers.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r8ui) uniform writeonly uimage2D water_mask;
layout(set = 0, binding = 1, r8ui) uniform writeonly uimage2D flow_direction;
layout(set = 0, binding = 2, r8ui) uniform writeonly uimage2D river_type;
layout(set = 0, binding = 3, r32ui) uniform writeonly uimage2D river_biome_id;
layout(set = 0, binding = 4, r32f) uniform writeonly image2D river_flux;
layout(set = 0, binding = 5, rgba8) uniform writeonly image2D water_colored;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dimensions = imageSize(water_mask);
    if (pos.x >= dimensions.x || pos.y >= dimensions.y) return;

    imageStore(water_mask, pos, uvec4(0u));
    imageStore(flow_direction, pos, uvec4(255u));
    imageStore(river_type, pos, uvec4(255u));
    imageStore(river_biome_id, pos, uvec4(0xffffffffu));
    imageStore(river_flux, pos, vec4(0.0));
    imageStore(water_colored, pos, vec4(0.0));
}
