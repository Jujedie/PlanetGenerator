#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8ui) uniform readonly uimage2D resources_map;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D output_map;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint resource_id;
    uint color_r;
    uint color_g;
    uint color_b;
    uint padding0;
    uint padding1;
} params;

uint mulByte(uint a, uint b) {
    return (a * b + 127u) / 255u;
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) return;
    uvec4 resource_sample = imageLoad(resources_map, pos);
    if (resource_sample.a == 0u || resource_sample.r != params.resource_id) {
        imageStore(output_map, pos, vec4(0.0));
        return;
    }
    uint intensity = resource_sample.g;
    uvec4 rgba = uvec4(
        mulByte(params.color_r, intensity),
        mulByte(params.color_g, intensity),
        mulByte(params.color_b, intensity),
        resource_sample.a
    );
    imageStore(output_map, pos, vec4(rgba) / 255.0);
}
