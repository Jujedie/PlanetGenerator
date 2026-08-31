#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) uniform readonly image2D final_source;
layout(set = 0, binding = 1, rgba8) uniform readonly image2D water_colored;
layout(set = 0, binding = 2, rgba8) uniform readonly image2D ice_caps;
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D final_export;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    float darkening_factor;
    uint padding;
} params;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) return;
    vec4 source = imageLoad(final_source, pos);
    vec4 water = imageLoad(water_colored, pos);
    vec4 ice = imageLoad(ice_caps, pos);
    // CPU export used alpha > 0 for water and byte alpha > 6 for sea ice.
    bool is_water = water.a > 0.0;
    bool is_ice = ice.a > (6.0 / 255.0);
    if (is_water && !is_ice) {
        // Quantize explicitly to the same RGBA8 byte model as the former CPU
        // Image.get_pixel()/set_pixel() pass instead of relying on driver UNORM
        // conversion details.
        source.rgb = floor(
            source.rgb * params.darkening_factor * 255.0 + vec3(0.5)
        ) / 255.0;
    }
    imageStore(final_export, pos, source);
}
