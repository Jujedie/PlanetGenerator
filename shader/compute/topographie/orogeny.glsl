#[compute]
#version 450

// Workgroup size
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// State textures
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_state;   // R: elevation, G: water, B: sediment, A: plate_id
layout(set = 0, binding = 1, rgba32f) readonly uniform image2D plate_data; // R: velocity_x, G: velocity_y, B: friction, A: type

// Uniform buffer
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    float detail_scale;        // Échelle du bruit fractal
    float mountain_intensity;  // Intensité des montagnes
    float erosion_factor;      // Facteur d'érosion naturelle
    uvec2 resolution;
    float time;
} params;

// ============================================================================
// HASH & NOISE FUNCTIONS
// ============================================================================

uint hash(uvec3 x) {
    x = ((x >> 16) ^ x) * 0x45d9f3bU;
    x = ((x >> 16) ^ x) * 0x45d9f3bU;
    x = (x >> 16) ^ x;
    return x.x ^ x.y ^ x.z ^ params.seed;
}

float noise3d(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Interpolation smoothstep
    f = f * f * (3.0 - 2.0 * f);
    
    // 8 coins du cube
    float c000 = float(hash(uvec3(i))) / float(0xffffffffU);
    float c100 = float(hash(uvec3(i + vec3(1, 0, 0)))) / float(0xffffffffU);
    float c010 = float(hash(uvec3(i + vec3(0, 1, 0)))) / float(0xffffffffU);
    float c110 = float(hash(uvec3(i + vec3(1, 1, 0)))) / float(0xffffffffU);
    float c001 = float(hash(uvec3(i + vec3(0, 0, 1)))) / float(0xffffffffU);
    float c101 = float(hash(uvec3(i + vec3(1, 0, 1)))) / float(0xffffffffU);
    float c011 = float(hash(uvec3(i + vec3(0, 1, 1)))) / float(0xffffffffU);
    float c111 = float(hash(uvec3(i + vec3(1, 1, 1)))) / float(0xffffffffU);
    
    // Interpolation trilinéaire
    float x00 = mix(c000, c100, f.x);
    float x10 = mix(c010, c110, f.x);
    float x01 = mix(c001, c101, f.x);
    float x11 = mix(c011, c111, f.x);
    
    float y0 = mix(x00, x10, f.y);
    float y1 = mix(x01, x11, f.y);
    
    return mix(y0, y1, f.z);
}

// Bruit fractal (FBM - Fractional Brownian Motion)
float fbm(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float max_value = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise3d(p * frequency);
        max_value += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return value / max_value;
}

// Ridged Multifractal (pour montagnes escarpées)
float ridged_multifractal(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float max_value = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        float n = noise3d(p * frequency);
        n = 1.0 - abs(n * 2.0 - 1.0); // Ridged: inverse et absolute
        n = n * n; // Sharpen peaks
        
        value += amplitude * n;
        max_value += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return value / max_value;
}

// ============================================================================
// COORDONNÉES CYLINDRIQUES (pour wrapping horizontal)
// ============================================================================

vec3 get_cylindrical_coords(vec2 pixel_coord) {
    float angle = (pixel_coord.x / float(params.resolution.x)) * 6.28318530718; // 2*PI
    float radius = 100.0; // Rayon arbitraire pour le bruit
    
    return vec3(
        cos(angle) * radius,
        pixel_coord.y,
        sin(angle) * radius
    );
}

// ============================================================================
// MAIN COMPUTE SHADER
// ============================================================================

void main() {
    ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel_coord.x >= int(params.resolution.x) || pixel_coord.y >= int(params.resolution.y)) {
        return;
    }
    
    // Lire l'état actuel
    vec4 geo = imageLoad(geo_state, pixel_coord);
    vec4 plate = imageLoad(plate_data, pixel_coord);
    
    float elevation = geo.r;
    float friction = plate.b;
    
    // Coordonnées cylindriques pour bruit continu
    vec3 coords = get_cylindrical_coords(vec2(pixel_coord)) * params.detail_scale;
    
    // Ajouter des détails UNIQUEMENT dans les zones de friction (frontières de plaques)
    if (friction > 0.1) {
        // Ridged multifractal pour montagnes escarpées
        float mountain_detail = ridged_multifractal(coords, 6);
        
        // FBM pour variations douces
        float gentle_detail = fbm(coords * 0.5, 4);
        
        // Combiner selon le coefficient de friction
        float detail = mix(gentle_detail, mountain_detail, friction);
        
        // Appliquer l'intensité
        elevation += detail * params.mountain_intensity * friction;
        
        // Érosion naturelle légère (lissage)
        elevation *= (1.0 - params.erosion_factor * 0.01);
    } else {
        // Plaines : juste un peu de variation douce
        float plain_detail = fbm(coords * 2.0, 3) * 50.0;
        elevation += plain_detail;
    }
    
    // Mettre à jour l'élévation
    geo.r = elevation;
    imageStore(geo_state, pixel_coord, geo);
}