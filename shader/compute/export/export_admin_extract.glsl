#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D source_ids;
layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D land_ids;
layout(set = 0, binding = 2, r8ui) uniform readonly uimage2D water_mask;

// Sparse lock-free stat hash. key stores raw_id + 1, so zero is always empty.
// All remaining members can be accumulated atomically as soon as the key CAS
// succeeds; no invocation ever waits for a different workgroup to publish a
// compact index.
struct AdminStat {
    uint key;
    uint count;
    int sum_cos;
    int sum_sin;
    uint sum_y;
    uint first_rank;
    uint flags;
    uint padding;
};

layout(set = 1, binding = 0, std430) buffer StatHash {
    AdminStat entries[];
} stat_hash;
layout(set = 1, binding = 1, std430) buffer EdgeHash {
    uvec2 entries[];
} edge_hash;
layout(set = 1, binding = 2, std430) buffer Edges {
    uvec2 entries[];
} edges;
layout(set = 1, binding = 3, std430) buffer ContactHash {
    uvec2 entries[];
} contact_hash;
layout(set = 1, binding = 4, std430) buffer Contacts {
    uvec2 entries[];
} contacts;
layout(set = 1, binding = 5, std430) buffer Counters {
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
const uint EMPTY_SLOT = 0u;
const uint OVERFLOW_STATS = 1u;
const uint OVERFLOW_EDGES = 2u;
const uint OVERFLOW_CONTACTS = 4u;
const uint FLAG_SALTWATER = 1u;
const uint MAX_PROBES = 256u;

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
    uint encoded = id + 1u;
    uint mask = params.stat_hash_capacity - 1u;
    uint slot = mix_u32(id) & mask;
    for (uint probe = 0u; probe < MAX_PROBES; ++probe) {
        uint state = atomicCompSwap(stat_hash.entries[slot].key, EMPTY_SLOT, encoded);
        if (state == EMPTY_SLOT) {
            uint ordinal = atomicAdd(counters.values[0], 1u);
            if (ordinal >= params.stat_capacity) {
                atomicOr(counters.values[3], OVERFLOW_STATS);
            }
            return slot;
        }
        if (state == encoded) {
            return slot;
        }
        slot = (slot + 1u) & mask;
    }
    atomicOr(counters.values[3], OVERFLOW_STATS);
    return INVALID_ID;
}

// Lock-free exact pair insertion.
//
// x and y store raw_id + 1 (zero means empty). Claiming x does not reserve the
// slot: another invocation with the same first id is allowed to atomically set
// y. If that y belongs to a different pair, the current invocation simply
// continues probing. The invocation that changes y from zero is the unique
// creator and appends exactly one compact pair. There is no LOCKED state and no
// scheduler-dependent spin loop between workgroups.
void insert_edge(uint a, uint b) {
    if (a == INVALID_ID || b == INVALID_ID || a == b) {
        return;
    }
    uint lo = min(a, b);
    uint hi = max(a, b);
    uint key_lo = lo + 1u;
    uint key_hi = hi + 1u;
    if (params.edge_hash_capacity == 0u || params.edge_capacity == 0u) {
        atomicOr(counters.values[3], OVERFLOW_EDGES);
        return;
    }
    uint mask = params.edge_hash_capacity - 1u;
    uint slot = pair_hash(lo, hi) & mask;
    for (uint probe = 0u; probe < MAX_PROBES; ++probe) {
        uint state_lo = atomicCompSwap(edge_hash.entries[slot].x, EMPTY_SLOT, key_lo);
        if (state_lo == EMPTY_SLOT || state_lo == key_lo) {
            uint state_hi = atomicCompSwap(edge_hash.entries[slot].y, EMPTY_SLOT, key_hi);
            if (state_hi == EMPTY_SLOT || state_hi == key_hi) {
                if (state_hi == EMPTY_SLOT) {
                    uint compact_index = atomicAdd(counters.values[1], 1u);
                    if (compact_index >= params.edge_capacity) {
                        atomicOr(counters.values[3], OVERFLOW_EDGES);
                        return;
                    }
                    edges.entries[compact_index] = uvec2(lo, hi);
                }
                return;
            }
        }
        slot = (slot + 1u) & mask;
    }
    atomicOr(counters.values[3], OVERFLOW_EDGES);
}

void insert_contact(uint sea_id, uint land_id) {
    if (sea_id == INVALID_ID || land_id == INVALID_ID) {
        return;
    }
    uint key_sea = sea_id + 1u;
    uint key_land = land_id + 1u;
    if (params.contact_hash_capacity == 0u || params.contact_capacity == 0u) {
        atomicOr(counters.values[3], OVERFLOW_CONTACTS);
        return;
    }
    uint mask = params.contact_hash_capacity - 1u;
    uint slot = pair_hash(sea_id, land_id) & mask;
    for (uint probe = 0u; probe < MAX_PROBES; ++probe) {
        uint state_sea = atomicCompSwap(contact_hash.entries[slot].x, EMPTY_SLOT, key_sea);
        if (state_sea == EMPTY_SLOT || state_sea == key_sea) {
            uint state_land = atomicCompSwap(contact_hash.entries[slot].y, EMPTY_SLOT, key_land);
            if (state_land == EMPTY_SLOT || state_land == key_land) {
                if (state_land == EMPTY_SLOT) {
                    uint compact_index = atomicAdd(counters.values[2], 1u);
                    if (compact_index >= params.contact_capacity) {
                        atomicOr(counters.values[3], OVERFLOW_CONTACTS);
                        return;
                    }
                    contacts.entries[compact_index] = uvec2(sea_id, land_id);
                }
                return;
            }
        }
        slot = (slot + 1u) & mask;
    }
    atomicOr(counters.values[3], OVERFLOW_CONTACTS);
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

    uint stat_slot = find_or_create_stat(id);
    if (stat_slot == INVALID_ID) {
        return;
    }

    uint pixel_index = uint(pos.y) * params.width + uint(pos.x);
    float angle = 6.28318530717958647692 * (float(pos.x) + 0.5) / max(float(params.width), 1.0);
    int scale = int(max(params.moment_scale, 1u));
    int cosine_fixed = int(round(cos(angle) * float(scale)));
    int sine_fixed = int(round(sin(angle) * float(scale)));
    atomicAdd(stat_hash.entries[stat_slot].count, 1u);
    atomicAdd(stat_hash.entries[stat_slot].sum_cos, cosine_fixed);
    atomicAdd(stat_hash.entries[stat_slot].sum_sin, sine_fixed);
    atomicAdd(stat_hash.entries[stat_slot].sum_y, uint(pos.y));
    atomicMax(stat_hash.entries[stat_slot].first_rank, INVALID_ID - pixel_index);

    if (params.maritime != 0u && imageLoad(water_mask, pos).r == 1u) {
        atomicOr(stat_hash.entries[stat_slot].flags, FLAG_SALTWATER);
    }

    ivec2 right = ivec2(pos.x + 1, pos.y);
    if (right.x >= int(params.width)) {
        right.x = 0;
    }
    uint right_id = imageLoad(source_ids, right).r;
    if (right_id != INVALID_ID && right_id != id) {
        insert_edge(id, right_id);
    }
    if (pos.y + 1 < int(params.height)) {
        uint down_id = imageLoad(source_ids, ivec2(pos.x, pos.y + 1)).r;
        if (down_id != INVALID_ID && down_id != id) {
            insert_edge(id, down_id);
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
                insert_contact(id, land_id);
            }
        }
    }
}
