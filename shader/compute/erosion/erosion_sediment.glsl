#[compute]
#version 450

// Passe de conservation de l'état hydrologique.
//
// L'incision et le dépôt sont volontairement désactivés : cette passe conserve
// le ping-pong geo_temp -> geo nécessaire à la pluie et à l'écoulement, sans
// modifier hauteur, roche ou sédiments. La génération de rivières et le calcul
// de flux restent actifs, mais aucun canyon ne peut être creusé.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D geo_input;
layout(set = 0, binding = 1, rgba32f) uniform writeonly image2D geo_output;
layout(set = 0, binding = 2, r32f) uniform readonly image2D flux_texture;

// Structure conservée pour rester compatible avec l'orchestrateur et les
// uniform sets existants.
layout(set = 1, binding = 0, std140) uniform SedimentParams {
    uint width;
    uint height;
    float erosion_rate;
    float deposition_rate;
    float capacity_multiplier;
    float min_slope;
    float sea_level;
    float bedrock_hardness;
    float pixel_size_x_m;
    float pixel_size_y_m;
    float max_erosion_per_pass_m;
    float channel_flux_threshold;
} params;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    imageStore(geo_output, pixel, imageLoad(geo_input, pixel));
}
