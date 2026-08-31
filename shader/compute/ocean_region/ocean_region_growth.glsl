#[compute]
#version 450

// Ocean administrative label relaxation. Static depth/noise traversal costs
// are precomputed once in ocean_region_edge_cost.glsl.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D edge_cost_texture;
layout(set = 0, binding = 2, r32ui) uniform readonly uimage2D ocean_region_map_in;
layout(set = 0, binding = 3, r32f) uniform readonly image2D ocean_region_cost_in;
layout(set = 0, binding = 4, r32ui) uniform writeonly uimage2D ocean_region_map_out;
layout(set = 0, binding = 5, r32f) uniform writeonly image2D ocean_region_cost_out;

layout(set = 1, binding = 0, std430) buffer GrowthConvergence {
    uvec2 group_stats[];
} convergence;

shared uint workgroup_changed;
shared uint workgroup_unassigned;

layout(push_constant, std430) uniform GrowthParams {
    uint width;
    uint height;
    uint pass_index;
    uint seed;
    float sea_level;
    float cost_flat;
    float cost_deeper;
    float noise_strength;
    float mean_spacing_px;
    float padding2;
    float padding3;
    float padding4;
} params;

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

const ivec2 CARDINAL[4] = ivec2[4](
    ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
);

void main() {
    if (gl_LocalInvocationIndex == 0u) {
        workgroup_changed = 0u;
        workgroup_unassigned = 0u;
    }
    barrier();

    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    int w = int(params.width);
    int h = int(params.height);

    if (pixel.x < w && pixel.y < h) {
        vec4 edgeCosts = imageLoad(edge_cost_texture, pixel);
        if (edgeCosts.x < 0.0) {
            imageStore(ocean_region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
            imageStore(ocean_region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        } else {
            uint current_region = imageLoad(ocean_region_map_in, pixel).r;
            float current_cost = imageLoad(ocean_region_cost_in, pixel).r;
            uint best_region = current_region;
            float best_cost = current_cost;

            for (int i = 0; i < 4; i++) {
                int nx = wrapX(pixel.x + CARDINAL[i].x, w);
                int ny = clampY(pixel.y + CARDINAL[i].y, h);
                if (nx == pixel.x && ny == pixel.y) continue;
                ivec2 neighbor = ivec2(nx, ny);
                uint neighbor_region = imageLoad(ocean_region_map_in, neighbor).r;
                if (neighbor_region == 0xFFFFFFFFu) continue;
                float total_cost = imageLoad(ocean_region_cost_in, neighbor).r + edgeCosts[i];
                if (total_cost < best_cost) {
                    best_cost = total_cost;
                    best_region = neighbor_region;
                }
            }

            if (best_region != current_region || best_cost < current_cost) {
                atomicOr(workgroup_changed, 1u);
            }
            if (best_region == 0xFFFFFFFFu) {
                atomicAdd(workgroup_unassigned, 1u);
            }
            imageStore(ocean_region_map_out, pixel, uvec4(best_region, 0u, 0u, 0u));
            imageStore(ocean_region_cost_out, pixel, vec4(best_cost, 0.0, 0.0, 0.0));
        }
    }

    barrier();
    if (gl_LocalInvocationIndex == 0u) {
        uint groupIndex = gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x;
        convergence.group_stats[groupIndex] = uvec2(workgroup_changed, workgroup_unassigned);
    }
}
