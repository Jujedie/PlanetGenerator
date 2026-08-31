#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D elevation_colored;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D elevation_grey;
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D water_overlay;

// entries[0..color_count-1] = vec4(threshold, r, g, b)
// entries[grey_offset..grey_offset+grey_count-1] = same for greyscale.
layout(set = 1, binding = 0, std430) readonly buffer ElevationPalette {
    vec4 entries[];
} palette;

layout(push_constant, std430) uniform ExportParams {
    uint width;
    uint height;
    float sea_level;
    uint has_water;
    uint color_count;
    uint grey_offset;
    uint grey_count;
    uint padding;
} params;

int roundLikeGDScript(float value) {
    return value >= 0.0 ? int(floor(value + 0.5)) : int(ceil(value - 0.5));
}

vec3 paletteColor(int elevation, uint offset, uint count) {
    if (count == 0u) return vec3(0.0);
    int first_threshold = int(palette.entries[offset].x);
    int last_threshold = int(palette.entries[offset + count - 1u].x);
    if (elevation <= first_threshold) return palette.entries[offset].yzw;
    if (elevation >= last_threshold) return palette.entries[offset + count - 1u].yzw;

    uint low = 1u;
    uint high = count - 1u;
    while (low < high) {
        uint middle = (low + high) >> 1u;
        if (elevation <= int(palette.entries[offset + middle].x)) high = middle;
        else low = middle + 1u;
    }
    vec4 upper = palette.entries[offset + low];
    vec4 lower = palette.entries[offset + low - 1u];
    int lower_height = int(lower.x);
    int upper_height = int(upper.x);
    float span = float(max(upper_height - lower_height, 1));
    float blend = clamp(float(elevation - lower_height) / span, 0.0, 1.0);
    return mix(lower.yzw, upper.yzw, blend);
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) return;

    vec4 geo = imageLoad(geo_texture, pos);
    int relative_elevation = roundLikeGDScript(geo.r - params.sea_level);
    vec3 colored = paletteColor(relative_elevation, 0u, params.color_count);
    vec3 grey = paletteColor(relative_elevation, params.grey_offset, params.grey_count);
    imageStore(elevation_colored, pos, vec4(colored, 1.0));
    imageStore(elevation_grey, pos, vec4(grey, 1.0));
    if (params.has_water != 0u && geo.a > 0.0) {
        imageStore(water_overlay, pos, vec4(0.2, 0.4, 0.8, 1.0));
    } else {
        imageStore(water_overlay, pos, vec4(0.0));
    }
}
