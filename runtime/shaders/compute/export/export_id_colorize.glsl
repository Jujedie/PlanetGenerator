#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D id_map;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D colored_map;

// Sorted by id. packed_rgba = r | (g<<8) | (b<<16) | (a<<24).
layout(set = 1, binding = 0, std430) readonly buffer ColorPairs {
    uvec2 pairs[];
} table;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint pair_count;
    uint padding;
} params;

vec4 unpackColor(uint packed) {
    return vec4(
        float(packed & 255u),
        float((packed >> 8u) & 255u),
        float((packed >> 16u) & 255u),
        float((packed >> 24u) & 255u)
    ) / 255.0;
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) return;
    uint id = imageLoad(id_map, pos).r;
    if (id == 0xffffffffu || params.pair_count == 0u) {
        imageStore(colored_map, pos, vec4(0.0));
        return;
    }

    uint low = 0u;
    uint high = params.pair_count;
    while (low < high) {
        uint middle = (low + high) >> 1u;
        uint candidate = table.pairs[middle].x;
        if (candidate < id) low = middle + 1u;
        else high = middle;
    }
    if (low < params.pair_count && table.pairs[low].x == id) {
        imageStore(colored_map, pos, unpackColor(table.pairs[low].y));
    } else {
        imageStore(colored_map, pos, vec4(0.0));
    }
}
