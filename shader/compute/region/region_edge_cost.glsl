#[compute]
#version 450

// Precompute the four static land traversal costs once per administrative
// phase. Growth then only performs dynamic label/cost relaxation.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_texture;
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 2, r32f) uniform readonly image2D river_flux;
layout(set = 0, binding = 3, rgba32f) uniform writeonly image2D edge_cost_out;

layout(push_constant, std430) uniform EdgeParams {
    uint width;
    uint height;
    uint seed;
    float river_threshold;
    float cost_flat;
    float cost_uphill;
    float cost_river;
    float noise_strength;
    float mean_spacing_px;
    float padding0;
    float padding1;
    float padding2;
} params;

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x85ebca6bu;
    x ^= x >> 13u;
    x *= 0xc2b2ae35u;
    x ^= x >> 16u;
    return x;
}

float hashToFloat(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

float fade(float t) {
    return t * t * (3.0 - 2.0 * t);
}

float valueNoise3D(vec3 p, uint seedOffset) {
    vec3 base = floor(p);
    vec3 f = fract(p);
    vec3 u = vec3(fade(f.x), fade(f.y), fade(f.z));
    ivec3 i = ivec3(base + vec3(10000.0));
    float values[8];
    int index = 0;
    for (int dz = 0; dz <= 1; dz++) {
        for (int dy = 0; dy <= 1; dy++) {
            for (int dx = 0; dx <= 1; dx++) {
                uint hx = uint(i.x + dx);
                uint hy = uint(i.y + dy);
                uint hz = uint(i.z + dz);
                values[index++] = hashToFloat(hash(hx ^ hash(hy ^ hash(hz + seedOffset))));
            }
        }
    }
    float x00 = mix(values[0], values[1], u.x);
    float x10 = mix(values[2], values[3], u.x);
    float x01 = mix(values[4], values[5], u.x);
    float x11 = mix(values[6], values[7], u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
}

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

vec3 organicNoisePoint(ivec2 pixel, int w, int h) {
    const float TAU = 6.28318530718;
    float angle = (float(pixel.x) + 0.5) / float(w) * TAU;
    float latitude = ((float(pixel.y) + 0.5) / float(h) - 0.5) * 3.14159265359;
    float featureCount = max(float(w) / max(params.mean_spacing_px, 2.0) * 0.42, 1.0);
    return vec3(cos(angle), latitude, sin(angle)) * featureCount;
}

const ivec2 CARDINAL[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
);

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);
    if (pixel.x >= w || pixel.y >= h) return;

    // Negative X is an unambiguous inactive sentinel because legal traversal
    // costs are clamped to >= 0.01.
    if (imageLoad(water_mask, pixel).r > 0u) {
        imageStore(edge_cost_out, pixel, vec4(-1.0));
        return;
    }

    float baseCost = max(params.cost_flat, 0.05);
    vec3 grainPoint = organicNoisePoint(pixel, w, h) * 1.75;
    float grain = valueNoise3D(grainPoint, params.seed + 911u);
    float grainStrength = clamp(params.noise_strength, 0.0, 1.0) * 0.38;
    baseCost *= mix(1.0 - grainStrength, 1.0 + grainStrength, grain);

    float hereHeight = imageLoad(geo_texture, pixel).r;
    float hereRiverFlux = imageLoad(river_flux, pixel).r;
    vec4 costs = vec4(1e30);
    for (int i = 0; i < 4; i++) {
        int nx = wrapX(pixel.x + CARDINAL[i].x, w);
        int ny = clampY(pixel.y + CARDINAL[i].y, h);
        ivec2 neighbor = ivec2(nx, ny);
        if (imageLoad(water_mask, neighbor).r > 0u) continue;

        float cost = baseCost;
        float neighborHeight = imageLoad(geo_texture, neighbor).r;
        float reliefBarrier = min(abs(hereHeight - neighborHeight) / 450.0, 3.0);
        cost += reliefBarrier * max(params.cost_uphill - params.cost_flat, 0.0);
        float riverFlux = max(hereRiverFlux, imageLoad(river_flux, neighbor).r);
        if (riverFlux > params.river_threshold) {
            cost += max(params.cost_river, 0.0);
        }
        costs[i] = max(cost, 0.01);
    }
    imageStore(edge_cost_out, pixel, costs);
}
