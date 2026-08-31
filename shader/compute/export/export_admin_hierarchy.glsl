#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D source_ids;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D department_out;
layout(set = 0, binding = 2, rgba8) uniform writeonly image2D level1_out;
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D level2_out;
layout(set = 0, binding = 4, rgba8) uniform writeonly image2D level3_out;

struct AdminColorRow {
    uint id;
    uint department_color;
    uint level1_color;
    uint level2_color;
    uint level3_color;
    uint padding0;
    uint padding1;
    uint padding2;
};

layout(set = 1, binding = 0, std430) readonly buffer ColorRows {
    AdminColorRow rows[];
} table;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint row_count;
    uint padding;
} params;

vec4 unpack_color(uint packed) {
    return vec4(
        float(packed & 255u),
        float((packed >> 8u) & 255u),
        float((packed >> 16u) & 255u),
        float((packed >> 24u) & 255u)
    ) / 255.0;
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= int(params.width) || pos.y >= int(params.height)) {
        return;
    }
    uint id = imageLoad(source_ids, pos).r;
    if (id == 0xffffffffu || params.row_count == 0u) {
        imageStore(department_out, pos, vec4(0.0));
        imageStore(level1_out, pos, vec4(0.0));
        imageStore(level2_out, pos, vec4(0.0));
        imageStore(level3_out, pos, vec4(0.0));
        return;
    }

    uint low = 0u;
    uint high = params.row_count;
    while (low < high) {
        uint middle = (low + high) >> 1u;
        uint candidate = table.rows[middle].id;
        if (candidate < id) {
            low = middle + 1u;
        } else {
            high = middle;
        }
    }
    if (low >= params.row_count || table.rows[low].id != id) {
        imageStore(department_out, pos, vec4(0.0));
        imageStore(level1_out, pos, vec4(0.0));
        imageStore(level2_out, pos, vec4(0.0));
        imageStore(level3_out, pos, vec4(0.0));
        return;
    }

    AdminColorRow row = table.rows[low];
    imageStore(department_out, pos, unpack_color(row.department_color));
    imageStore(level1_out, pos, unpack_color(row.level1_color));
    imageStore(level2_out, pos, unpack_color(row.level2_color));
    imageStore(level3_out, pos, unpack_color(row.level3_color));
}
