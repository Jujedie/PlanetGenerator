#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, r32f) uniform readonly image2D height_in;
layout(set = 0, binding = 1, r32f) uniform writeonly image2D height_out;
layout(set = 1, binding = 0, std140) uniform Params {
    uint width;
    uint height;
    uint iteration;
    uint total_iterations;
    float erosion_rate;
    float cell_size_km;
    float sea_level;
    float padding;
} params;

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width), h = int(params.height);
    if (p.x >= w || p.y >= h) return;
    float center = imageLoad(height_in, p).r;
    float lower_sum = 0.0;
    float weight = 0.0;
    const ivec2 N[8] = ivec2[8](
        ivec2(-1,-1), ivec2(0,-1), ivec2(1,-1), ivec2(-1,0),
        ivec2(1,0), ivec2(-1,1), ivec2(0,1), ivec2(1,1));
    for (int i=0; i<8; ++i) {
        ivec2 q = clamp(p + N[i], ivec2(0), ivec2(w-1,h-1));
        float nh = imageLoad(height_in, q).r;
        float drop = center - nh;
        if (drop > 0.0) {
            lower_sum += drop;
            weight += 1.0;
        }
    }
    float rate = clamp(params.erosion_rate, 0.0, 0.25);
    float erosion = weight > 0.0 ? (lower_sum / weight) * rate * 0.12 : 0.0;
    // Keep the pass conservative and deterministic. Halo width equals the
    // number of iterations, so the cropped core is independent of tile edges.
    float result = center - min(erosion, 8.0);
    imageStore(height_out, p, vec4(result,0,0,0));
}
