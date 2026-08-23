#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform writeonly image2D height_out;
layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D plate_out;

layout(set = 1, binding = 0, std140) uniform Params {
    uint sample_width;
    uint sample_height;
    uint global_width;
    uint global_height;
    int origin_x;
    int origin_y;
    uint seed;
    uint planet_type;
    float sea_level;
    float terrain_scale;
    float planet_radius_km;
    float padding;
} params;

uint hash_u32(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}
uint hash_cell(ivec2 c, uint seed, uint channel) {
    uint value = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u;
    value ^= seed * 83492791u ^ channel * 2654435761u;
    return hash_u32(value);
}
float unit_noise(ivec2 c, uint seed, uint channel) {
    return float(hash_cell(c, seed, channel)) / 4294967295.0;
}
int wrap_x(int x, int w) { return (x % w + w) % w; }
float fade(float t) { return t * t * (3.0 - 2.0 * t); }
float smooth_noise(ivec2 global_cell, int scale, uint channel) {
    scale = max(scale, 1);
    int gw = int(params.global_width);
    int gh = int(params.global_height);
    int coarse_w = max(1, (gw + scale - 1) / scale);
    int coarse_h = max(1, (gh + scale - 1) / scale);
    int gx = int(floor(float(global_cell.x) / float(scale)));
    int gy = int(floor(float(global_cell.y) / float(scale)));
    float fx = float(global_cell.x % scale) / float(scale);
    float fy = float(global_cell.y % scale) / float(scale);
    fx = fade(fx); fy = fade(fy);
    ivec2 c00 = ivec2(wrap_x(gx, coarse_w), clamp(gy, 0, coarse_h - 1));
    ivec2 c10 = ivec2(wrap_x(gx + 1, coarse_w), clamp(gy, 0, coarse_h - 1));
    ivec2 c01 = ivec2(wrap_x(gx, coarse_w), clamp(gy + 1, 0, coarse_h - 1));
    ivec2 c11 = ivec2(wrap_x(gx + 1, coarse_w), clamp(gy + 1, 0, coarse_h - 1));
    float n00 = unit_noise(c00, params.seed, channel);
    float n10 = unit_noise(c10, params.seed, channel);
    float n01 = unit_noise(c01, params.seed, channel);
    float n11 = unit_noise(c11, params.seed, channel);
    return mix(mix(n00, n10, fx), mix(n01, n11, fx), fy);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= int(params.sample_width) || p.y >= int(params.sample_height)) return;
    int gx = wrap_x(params.origin_x + p.x, int(params.global_width));
    int gy = clamp(params.origin_y + p.y, 0, int(params.global_height) - 1);
    ivec2 g = ivec2(gx, gy);
    int continent_scale = max(int(params.global_width) / 6, 32);
    int macro_scale = max(int(params.global_width) / 12, 16);
    int ridge_scale = max(int(params.global_width) / 96, 4);
    int detail_scale = max(int(params.global_width) / 220, 2);
    float continent = smooth_noise(g, continent_scale, 10u);
    float macro = smooth_noise(g, macro_scale, 11u);
    float detail = smooth_noise(g, ridge_scale, 12u);
    float fine = smooth_noise(g, detail_scale, 13u);
    float ridge = pow(1.0 - abs(detail * 2.0 - 1.0), 3.0);
    float height = (continent - 0.505) * 9200.0;
    height += (macro - 0.5) * 2600.0;
    height += (ridge - 0.35) * 2100.0;
    height += (fine - 0.5) * 320.0;
    if (params.planet_type == 2u) {
        height += pow(smooth_noise(g, ridge_scale, 21u), 5.0) * 1800.0;
    } else if (params.planet_type == 3u) {
        height += (fine - 0.5) * 480.0;
    } else if (params.planet_type == 5u) {
        height *= 0.82;
    }
    float scale = max(params.terrain_scale, 0.05);
    imageStore(height_out, p, vec4(height * scale, 0.0, 0.0, 0.0));

    int plate_scale = max(int(params.global_width) / 32, 8);
    ivec2 coarse = ivec2(g.x / plate_scale, g.y / plate_scale);
    uint plate = hash_cell(coarse, params.seed, 44u) & 0x7fffffffu;
    imageStore(plate_out, p, uvec4(plate, 0u, 0u, 0u));
}
