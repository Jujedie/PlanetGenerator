#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D water_colored;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint atmosphere_type;
    uint padding;
} params;

vec3 saltColor(uint atmosphereType) {
    if (atmosphereType == 1u) return vec3(83.0, 105.0, 39.0) / 255.0;
    if (atmosphereType == 2u) return vec3(135.0, 38.0, 10.0) / 255.0;
    if (atmosphereType == 4u) return vec3(49.0, 61.0, 56.0) / 255.0;
    return vec3(37.0, 82.0, 138.0) / 255.0;
}

vec3 freshColor(uint atmosphereType) {
    if (atmosphereType == 1u) return vec3(139.0, 157.0, 44.0) / 255.0;
    if (atmosphereType == 2u) return vec3(232.0, 76.0, 12.0) / 255.0;
    if (atmosphereType == 4u) return vec3(101.0, 91.0, 52.0) / 255.0;
    return vec3(69.0, 132.0, 210.0) / 255.0;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) return;
    uint waterType = imageLoad(water_mask, pixel).r;
    if (waterType == 0u) {
        imageStore(water_colored, pixel, vec4(0.0));
    } else if (waterType == 1u) {
        imageStore(water_colored, pixel, vec4(saltColor(params.atmosphere_type), 1.0));
    } else {
        imageStore(water_colored, pixel, vec4(freshColor(params.atmosphere_type), 1.0));
    }
}
