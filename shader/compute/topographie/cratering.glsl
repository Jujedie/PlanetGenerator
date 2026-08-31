#[compute]
#version 450

// ============================================================================
// PHYSICAL CRATERING SHADER
// ============================================================================
// Crater centres and radii are generated once in physical units by the CPU.
// The shader evaluates them in an equirectangular metric, so crater size no
// longer depends on texture resolution or on the overall map dimensions.
//
// Morphology includes:
// - physically fixed radius in kilometres
// - small-crater-heavy size distribution (built on CPU)
// - simple/complex crater transition controlled by surface gravity
// - continuous cavity + raised rim + ejecta blanket
// - central peaks only for genuinely complex craters
// - age/degradation variation (old craters are shallower and have weak ejecta)
// - rare mild ellipticity for grazing impacts
// - subtle non-circular rim degradation without stamped sinusoidal rings
// - uniform crater-centre distribution on the sphere
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform image2D geo_texture;

layout(set = 1, binding = 0, std140) uniform CrateringParams {
    uint seed;
    uint width;
    uint height;
    uint num_craters;
    float depth_ratio;
    float rim_height_ratio;
    float ejecta_extent;
    float ejecta_decay;
    float azimuth_variation;
    float meters_per_pixel_x;
    float meters_per_pixel_y;
    float complex_transition_diameter_km;
} params;

struct CraterData {
    // A: center_x_px, center_y_px, radius_km, degradation_age [0 fresh, 1 old]
    vec4 a;
    // B: minor/major axis ratio, rotation, rim phase, morphology random
    vec4 b;
    // C: cos(latitude) metric scale, reserved, reserved, reserved
    vec4 c;
};

layout(set = 1, binding = 1, std430) readonly buffer CraterBuffer {
    CraterData craters[];
} crater_buffer;

const float PI = 3.14159265359;
const float EPSILON = 1e-5;

float wrappedDeltaX(float x, float center_x, float width) {
    float dx = x - center_x;
    if (dx > width * 0.5) {
        dx -= width;
    } else if (dx < -width * 0.5) {
        dx += width;
    }
    return dx;
}

// Local tangent-plane metric for the equirectangular projection. The longitude
// scale shrinks by cos(latitude), which keeps the crater physically circular on
// the sphere even though it appears horizontally stretched near map poles.
vec2 physicalOffsetMeters(vec2 pixel, CraterData crater) {
    float dx_px = wrappedDeltaX(pixel.x, crater.a.x, float(params.width));
    float dy_px = pixel.y - crater.a.y;
    float longitude_scale = crater.c.x;
    return vec2(
        dx_px * params.meters_per_pixel_x * longitude_scale,
        dy_px * params.meters_per_pixel_y
    );
}

vec2 rotateIntoCraterFrame(vec2 offset_m, float rotation) {
    float c = cos(rotation);
    float s = sin(rotation);
    return vec2(
        c * offset_m.x + s * offset_m.y,
        -s * offset_m.x + c * offset_m.y
    );
}

vec2 craterProfile(vec2 pixel, CraterData crater) {
    float radius_m = max(crater.a.z * 1000.0, 1.0);
    float age = clamp(crater.a.w, 0.0, 1.0);
    float freshness = 1.0 - age;

    vec2 physical_offset = physicalOffsetMeters(pixel, crater);
    float conservative_distance = length(physical_offset);
    if (conservative_distance > radius_m * params.ejecta_extent) {
        return vec2(0.0);
    }

    vec2 local = rotateIntoCraterFrame(physical_offset, crater.b.y);
    float axis_ratio = clamp(crater.b.x, 0.72, 1.0);
    local.y /= axis_ratio;

    float angle = atan(local.y, local.x);
    float normalized = length(local) / radius_m;

    // Fresh craters remain almost circular. Older rims acquire a few percent
    // of low-frequency degradation, avoiding the perfectly stamped look.
    float rim_irregularity = params.azimuth_variation * mix(0.015, 0.065, age);
    float shape_wave =
        sin(angle * 2.0 + crater.b.z) * 0.50 +
        sin(angle * 3.0 - crater.b.z * 0.73) * 0.30 +
        sin(angle * 5.0 + crater.b.z * 1.31) * 0.20;
    float effective_radius_scale = max(0.88, 1.0 + rim_irregularity * shape_wave);
    float x = normalized / effective_radius_scale;

    if (x > params.ejecta_extent) {
        return vec2(0.0);
    }

    float diameter_km = crater.a.z * 2.0;
    float transition_km = max(params.complex_transition_diameter_km, 0.1);
    float complex_factor = smoothstep(transition_km * 0.85, transition_km * 1.35, diameter_km);

    // Complex craters are shallower relative to radius. Age and random impact
    // variability then reduce the preserved relief further.
    float random_depth = mix(0.86, 1.14, crater.b.w);
    float effective_depth_ratio = params.depth_ratio * mix(1.0, 0.56, complex_factor);
    float depth_m = radius_m * effective_depth_ratio * random_depth * mix(1.0, 0.48, age);
    float rim_height_m = depth_m * params.rim_height_ratio * mix(1.0, 0.28, age);

    float delta_height = 0.0;
    float delta_bedrock = 0.0;

    // One continuous rim, evaluated on both sides of x=1. Fresh rims are sharp;
    // old rims broaden and collapse.
    float rim_width = mix(0.055, 0.145, age);
    float rim = exp(-pow((x - 1.0) / max(rim_width, EPSILON), 2.0));
    delta_height += rim_height_m * rim;

    if (x < 1.0) {
        // Simple crater: rounded excavation bowl with steepening wall.
        float simple_cavity = -depth_m * pow(max(1.0 - x * x, 0.0), 1.18);

        // Complex crater: broad flatter floor and terraced inner wall. Blend is
        // gravity-dependent via the physical transition diameter.
        float complex_floor = -depth_m * 0.72 * (1.0 - smoothstep(0.42, 1.0, x));
        float terrace = complex_factor * depth_m * 0.055 * freshness *
            exp(-pow((x - 0.68) / 0.075, 2.0));
        float cavity = mix(simple_cavity, complex_floor, complex_factor) + terrace;

        // Degraded craters collect infill, especially near their floor.
        float infill = depth_m * 0.16 * age * age * (1.0 - smoothstep(0.15, 0.78, x));
        delta_height += cavity + infill;

        // Central peaks are restricted to complex craters and are progressively
        // subdued by degradation. On low-gravity small bodies the transition is
        // large, so ordinary craters correctly remain simple bowls.
        float peak_width = mix(0.10, 0.17, clamp(complex_factor, 0.0, 1.0));
        float peak = depth_m * mix(0.18, 0.30, crater.b.w) * complex_factor *
            mix(1.0, 0.45, age) * exp(-pow(x / peak_width, 2.0));
        delta_height += peak;

        // Bedrock exposure belongs on the excavated wall, not uniformly across
        // the entire crater floor.
        float wall_band = smoothstep(0.28, 0.62, x) * (1.0 - smoothstep(0.82, 0.98, x));
        delta_bedrock = 0.30 * wall_band * mix(1.0, 0.42, age);
    } else {
        // Thin ejecta blanket. It decays approximately as r^-3 and fades with
        // crater age, so old craters do not retain conspicuous radial rings.
        float ejecta_span = max(params.ejecta_extent - 1.0, 0.05);
        float ejecta_t = clamp((x - 1.0) / ejecta_span, 0.0, 1.0);
        float radial_decay = pow(max(x, 1.0), -3.0);
        float terminal_fade = 1.0 - smoothstep(0.72, 1.0, ejecta_t);
        float age_strength = freshness * freshness;

        // Low-amplitude, non-uniform ray texture only on relatively fresh ejecta.
        float ray_mix = sin(angle * 7.0 + crater.b.z) * sin(angle * 11.0 - crater.b.z * 0.61);
        float ray_factor = 1.0 + 0.12 * freshness * ray_mix;
        float ejecta = rim_height_m * 0.34 * age_strength * radial_decay * terminal_fade * ray_factor;
        ejecta *= exp(-params.ejecta_decay * ejecta_t * 0.35);
        delta_height += ejecta;

        delta_bedrock = 0.035 * age_strength * terminal_fade;
    }

    return vec2(delta_height, delta_bedrock);
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }

    vec4 geo = imageLoad(geo_texture, pixel);
    vec2 pixel_position = vec2(pixel) + vec2(0.5);

    float total_delta_height = 0.0;
    float exposed_bedrock = 0.0;

    for (uint i = 0u; i < params.num_craters; ++i) {
        vec2 delta = craterProfile(pixel_position, crater_buffer.craters[i]);
        total_delta_height += delta.x;
        exposed_bedrock = max(exposed_bedrock, delta.y);
    }

    geo.r += total_delta_height;
    geo.g = clamp(geo.g + exposed_bedrock, 0.0, 1.0);
    imageStore(geo_texture, pixel, geo);
}
