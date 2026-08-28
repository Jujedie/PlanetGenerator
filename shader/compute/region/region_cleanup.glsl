#[compute]
#version 450

// Final 4-connected land coverage repair. Set 1 mirrors growth convergence so
// the CPU can prove that the final GPU map is complete before normalization.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r8ui) uniform readonly uimage2D water_mask;
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D region_map_in;
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D region_map_out;
layout(set = 0, binding = 3, r32f) uniform writeonly image2D region_cost_out;

layout(set = 1, binding = 0, std430) buffer CleanupConvergence {
    uvec2 group_stats[]; // x=changed, y=unassigned active cells
} convergence;

shared uint workgroup_changed;
shared uint workgroup_unassigned;

layout(push_constant, std430) uniform CleanupParams {
    uint width;
    uint height;
    uint seed;
    float sea_level;
} params;

int wrapX(int x, int w) {
    return (x % w + w) % w;
}

int clampY(int y, int h) {
    return clamp(y, 0, h - 1);
}

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x85ebca6bu;
    x ^= x >> 13u;
    x *= 0xc2b2ae35u;
    x ^= x >> 16u;
    return x;
}

const ivec2 NEIGHBORS[4] = ivec2[4](
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
    bool in_bounds = pixel.x < w && pixel.y < h;

    if (in_bounds) {
        uint water_type = imageLoad(water_mask, pixel).r;
        if (water_type > 0u) {
            imageStore(region_map_out, pixel, uvec4(0xFFFFFFFFu, 0u, 0u, 0u));
            imageStore(region_cost_out, pixel, vec4(1e30, 0.0, 0.0, 0.0));
        } else {
            uint current_region = imageLoad(region_map_in, pixel).r;
            uint assigned_region = current_region;

            if (current_region == 0xFFFFFFFFu) {
                for (int i = 0; i < 4; i++) {
                    int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
                    int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
                    ivec2 neighbor_pos = ivec2(nx, ny);
                    if (imageLoad(water_mask, neighbor_pos).r > 0u) continue;
                    uint neighbor_region = imageLoad(region_map_in, neighbor_pos).r;
                    if (neighbor_region != 0xFFFFFFFFu &&
                            (assigned_region == 0xFFFFFFFFu || neighbor_region < assigned_region)) {
                        assigned_region = neighbor_region;
                    }
                }

                if (assigned_region == 0xFFFFFFFFu) {
                    uint linear = uint(pixel.y * w + pixel.x);
                    uint my_hash = hash(linear ^ params.seed);
                    bool local_minimum = true;
                    for (int i = 0; i < 4; i++) {
                        int nx = wrapX(pixel.x + NEIGHBORS[i].x, w);
                        int ny = clampY(pixel.y + NEIGHBORS[i].y, h);
                        ivec2 neighbor_pos = ivec2(nx, ny);
                        if (imageLoad(water_mask, neighbor_pos).r > 0u) continue;
                        uint neighbor_linear = uint(ny * w + nx);
                        uint neighbor_hash = hash(neighbor_linear ^ params.seed);
                        if (neighbor_hash < my_hash ||
                                (neighbor_hash == my_hash && neighbor_linear < linear)) {
                            local_minimum = false;
                        }
                    }
                    if (local_minimum) assigned_region = linear;
                }
            }

            if (assigned_region != current_region) atomicOr(workgroup_changed, 1u);
            if (assigned_region == 0xFFFFFFFFu) atomicAdd(workgroup_unassigned, 1u);
            imageStore(region_map_out, pixel, uvec4(assigned_region, 0u, 0u, 0u));
            imageStore(region_cost_out, pixel, vec4(0.0, 0.0, 0.0, 0.0));
        }
    }

    barrier();
    if (gl_LocalInvocationIndex == 0u) {
        uint groups_x = (params.width + gl_WorkGroupSize.x - 1u) / gl_WorkGroupSize.x;
        uint group_index = gl_WorkGroupID.y * groups_x + gl_WorkGroupID.x;
        convergence.group_stats[group_index] = uvec2(workgroup_changed, workgroup_unassigned);
    }
}
