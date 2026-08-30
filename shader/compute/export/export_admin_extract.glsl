#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D source_ids;
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D land_ids;
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

struct AdminStat {
    uint id;
    uint count;
    int sum_cos;
    int sum_sin;
    uint sum_y;
    uint first_rank;
    uint flags;
    uint padding;
};

layout(set = 1, binding = 0, std430) buffer StatHash {
    uvec2 entries[];
} stat_hash;
layout(set = 1, binding = 1, std430) buffer Stats {
    AdminStat entries[];
} stats;
layout(set = 1, binding = 2, std430) buffer EdgeHash {
    uvec2 entries[];
} edge_hash;
layout(set = 1, binding = 3, std430) buffer Edges {
    uvec2 entries[];
} edges;
layout(set = 1, binding = 4, std430) buffer ContactHash {
    uvec2 entries[];
} contact_hash;
layout(set = 1, binding = 5, std430) buffer Contacts {
    uvec2 entries[];
} contacts;
layout(set = 1, binding = 6, std430) buffer Counters {
    uint values[];
} counters;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint stat_hash_capacity;
    uint stat_capacity;
    uint edge_hash_capacity;
    uint edge_capacity;
    uint contact_hash_capacity;
    uint contact_capacity;
    uint maritime;
    uint moment_scale;
    uint padding0;
    uint padding1;
} params;

const uint INVALID_ID = 0xffffffffu;
const uint PENDING_INDEX = 0xffffffffu;
const uint FAILED_INDEX = 0xfffffffeu;
const uint OVERFLOW_STATS = 1u;
const uint OVERFLOW_EDGES = 2u;
const uint OVERFLOW_CONTACTS = 4u;
const uint FLAG_SALTWATER = 1u;

uint mix_u32(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    value ^= value >> 16u;
    return value;
}

uint pair_hash(uint a, uint b) {
    return mix_u32(a ^ (mix_u32(b) + 0x9e3779b9u + (a << 6u) + (a >> 2u)));
}

uint find_or_create_stat(uint id) {
    if (params.stat_hash_capacity == 0u || params.stat_capacity == 0u) {
        atomicOr(counters.values[3], OVERFLOW_STATS);
        return INVALID_ID;
    }
    uint mask = params.stat_hash_capacity - 1u;
    uint slot = mix_u32(id) & mask;
    for (uint probe = 0u; probe < 128u; ++probe) {
        uint previous = atomicCompSwap(stat_hash.entries[slot].x, INVALID_ID, id);
        if (previous == INVALID_ID) {
            uint compact_index = atomicAdd(counters.values[0], 1u);
            if (compact_index >= params.stat_capacity) {
                atomicOr(counters.values[3], OVERFLOW_STATS);
                atomicExchange(stat_hash.entries[slot].y, FAILED_INDEX);
                return INVALID_ID;
            }
            // The compact stats buffer is zero-filled before dispatch. Only the
            // ID needs publishing here; all counters/moments can immediately use
            // atomic operations without racing per-entry initialization.
            stats.entries[compact_index].id = id;
            memoryBarrierBuffer();
            atomicExchange(stat_hash.entries[slot].y, compact_index);
            return compact_index;
        }
        if (previous == id) {
            uint compact_index = stat_hash.entries[slot].y;
            for (uint wait_index = 0u; wait_index < 256u && compact_index == PENDING_INDEX; ++wait_index) {
                memoryBarrierBuffer();
                compact_index = stat_hash.entries[slot].y;
            }
            if (compact_index < params.stat_capacity) {
                return compact_index;
            }
            atomicOr(counters.values[3], OVERFLOW_STATS);
            return INVALID_ID;
        }
        slot = (slot + 1u) & mask;
    }
    atomicOr(counters.values[3], OVERFLOW_STATS);
    return INVALID_ID;
}

void insert_pair(uint a, uint b, bool contact_pair) {
    if (a == INVALID_ID || b == INVALID_ID) {
        return;
    }
    if (!contact_pair && a == b) {
        return;
    }
    uint lo = contact_pair ? a : min(a, b);
    uint hi = contact_pair ? b : max(a, b);
    uint hash_capacity = contact_pair ? params.contact_hash_capacity : params.edge_hash_capacity;
    uint compact_capacity = contact_pair ? params.contact_capacity : params.edge_capacity;
    if (hash_capacity == 0u || compact_capacity == 0u) {
        atomicOr(counters.values[3], contact_pair ? OVERFLOW_CONTACTS : OVERFLOW_EDGES);
        return;
    }
    uint mask = hash_capacity - 1u;
    uint slot = pair_hash(lo, hi) & mask;
    for (uint probe = 0u; probe < 128u; ++probe) {
        uint previous = contact_pair
            ? atomicCompSwap(contact_hash.entries[slot].x, INVALID_ID, lo)
            : atomicCompSwap(edge_hash.entries[slot].x, INVALID_ID, lo);
        if (previous == INVALID_ID) {
            if (contact_pair) {
                contact_hash.entries[slot].y = hi;
                memoryBarrierBuffer();
                uint compact_index = atomicAdd(counters.values[2], 1u);
                if (compact_index >= compact_capacity) {
                    atomicOr(counters.values[3], OVERFLOW_CONTACTS);
                    return;
                }
                contacts.entries[compact_index] = uvec2(lo, hi);
            } else {
                edge_hash.entries[slot].y = hi;
                memoryBarrierBuffer();
                uint compact_index = atomicAdd(counters.values[1], 1u);
                if (compact_index >= compact_capacity) {
                    atomicOr(counters.values[3], OVERFLOW_EDGES);
                    return;
                }
                edges.entries[compact_index] = uvec2(lo, hi);
            }
            return;
        }
        if (previous == lo) {
            uint existing_hi = contact_pair
                ? contact_hash.entries[slot].y
                : edge_hash.entries[slot].y;
            if (existing_hi == hi) {
                return;
            }
            // A second invocation can observe the claimed first word before the
            // claimant has published the second word. A duplicate compact pair
            // is harmless, but waiting briefly avoids nearly all such cases.
            for (uint wait_index = 0u; wait_index < 8u && existing_hi == INVALID_ID; ++wait_index) {
                memoryBarrierBuffer();
                existing_hi = contact_pair
                    ? contact_hash.entries[slot].y
                    : edge_hash.entries[slot].y;
            }
            if (existing_hi == hi) {
                return;
            }
        }
        slot = (slot + 1u) & mask;
    }
    atomicOr(counters.values[3], contact_pair ? OVERFLOW_CONTACTS : OVERFLOW_EDGES);
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) {
        return;
    }
    uint id = imageLoad(source_ids, pos).r;
    if (id == INVALID_ID) {
        return;
    }

    uint compact_index = find_or_create_stat(id);
    if (compact_index == INVALID_ID) {
        return;
    }

    uint pixel_index = uint(pos.y) * params.width + uint(pos.x);
    float angle = 6.28318530717958647692 * (float(pos.x) + 0.5) / max(float(params.width), 1.0);
    int scale = int(max(params.moment_scale, 1u));
    int cosine_fixed = int(round(cos(angle) * float(scale)));
    int sine_fixed = int(round(sin(angle) * float(scale)));
    atomicAdd(stats.entries[compact_index].count, 1u);
    atomicAdd(stats.entries[compact_index].sum_cos, cosine_fixed);
    atomicAdd(stats.entries[compact_index].sum_sin, sine_fixed);
    atomicAdd(stats.entries[compact_index].sum_y, uint(pos.y));
    atomicMax(stats.entries[compact_index].first_rank, INVALID_ID - pixel_index);

    if (params.maritime != 0u && imageLoad(water_mask, pos).r == 1u) {
        atomicOr(stats.entries[compact_index].flags, FLAG_SALTWATER);
    }

    ivec2 right = ivec2(pos.x + 1, pos.y);
    if (right.x >= int(params.width)) {
        right.x = 0;
    }
    uint right_id = imageLoad(source_ids, right).r;
    if (right_id != INVALID_ID && right_id != id) {
        insert_pair(id, right_id, false);
    }
    if (pos.y + 1 < int(params.height)) {
        uint down_id = imageLoad(source_ids, ivec2(pos.x, pos.y + 1)).r;
        if (down_id != INVALID_ID && down_id != id) {
            insert_pair(id, down_id, false);
        }
    }

    if (params.maritime == 0u) {
        return;
    }

    // Match HierarchyBuilder's compatibility contact band exactly: Manhattan
    // radius two, horizontal planet wrap, clipped latitude.
    for (int dy = -2; dy <= 2; ++dy) {
        int ny = pos.y + dy;
        if (ny < 0 || ny >= int(params.height)) {
            continue;
        }
        for (int dx = -2; dx <= 2; ++dx) {
            if (abs(dx) + abs(dy) > 2) {
                continue;
            }
            int nx = pos.x + dx;
            nx %= int(params.width);
            if (nx < 0) {
                nx += int(params.width);
            }
            uint land_id = imageLoad(land_ids, ivec2(nx, ny)).r;
            if (land_id != INVALID_ID) {
                insert_pair(id, land_id, true);
            }
        }
    }
}
