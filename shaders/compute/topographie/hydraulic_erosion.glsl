#[compute]
#version 450

// Workgroup size
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// State textures
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_state;   // R: elevation, G: water, B: sediment, A: plate_id

// Uniform buffer
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    uint iteration;           // Numéro d'itération actuel
    float rain_amount;        // Quantité de pluie
    float evaporation_rate;   // Taux d'évaporation
    float sediment_capacity;  // Capacité de transport de sédiments
    float erosion_strength;   // Force d'érosion
    float deposition_strength;// Force de déposition
    float gravity;            // Gravité (pour vitesse d'écoulement)
    uvec2 resolution;
    float time;
} params;

// ============================================================================
// HASH FUNCTIONS
// ============================================================================

uint hash(uvec2 x) {
    x = ((x >> 16) ^ x) * 0x45d9f3bU;
    x = ((x >> 16) ^ x) * 0x45d9f3bU;
    x = (x >> 16) ^ x;
    return x.x ^ x.y ^ (params.seed + params.iteration);
}

float random(uvec2 v) {
    return float(hash(v)) / float(0xffffffffU);
}

// ============================================================================
// TERRAIN HELPERS
// ============================================================================

// Wrapping horizontal
ivec2 wrap_coords(ivec2 c) {
    c.x = (c.x + int(params.resolution.x)) % int(params.resolution.x);
    c.y = clamp(c.y, 0, int(params.resolution.y) - 1);
    return c;
}

// Lit l'élévation avec wrapping
float get_elevation(ivec2 coord) {
    coord = wrap_coords(coord);
    return imageLoad(geo_state, coord).r;
}

// Trouve la direction de la plus grande pente
vec2 calculate_gradient(ivec2 coord) {
    float h = get_elevation(coord);
    float h_right = get_elevation(coord + ivec2(1, 0));
    float h_left = get_elevation(coord + ivec2(-1, 0));
    float h_down = get_elevation(coord + ivec2(0, 1));
    float h_up = get_elevation(coord + ivec2(0, -1));
    
    return vec2(h_right - h_left, h_down - h_up) * 0.5;
}

// ============================================================================
// WATER FLOW SIMULATION
// ============================================================================

void simulate_water_flow(ivec2 coord) {
    vec4 geo = imageLoad(geo_state, coord);
    
    float elevation = geo.r;
    float water = geo.g;
    float sediment = geo.b;
    
    // Ajouter de la pluie
    water += params.rain_amount;
    
    // Calculer le gradient (direction de l'écoulement)
    vec2 gradient = calculate_gradient(coord);
    float slope = length(gradient);
    
    if (slope > 0.001 && water > 0.001) {
        // Direction d'écoulement normalisée
        vec2 flow_dir = -normalize(gradient);
        
        // Vitesse basée sur la pente et la gravité
        float velocity = sqrt(slope * params.gravity);
        
        // Capacité de transport de sédiments (dépend de la vitesse)
        float capacity = slope * velocity * water * params.sediment_capacity;
        
        // ÉROSION : Si on transporte moins que la capacité
        if (sediment < capacity) {
            float amount_to_erode = min(
                (capacity - sediment) * params.erosion_strength,
                water * 0.1 // Ne pas éroder plus que ce que l'eau peut transporter
            );
            
            elevation -= amount_to_erode;
            sediment += amount_to_erode;
        }
        // DÉPOSITION : Si on transporte trop
        else {
            float amount_to_deposit = (sediment - capacity) * params.deposition_strength;
            
            elevation += amount_to_deposit;
            sediment -= amount_to_deposit;
        }
        
        // Faire couler l'eau vers le voisin le plus bas
        ivec2 flow_target = coord + ivec2(round(flow_dir));
        flow_target = wrap_coords(flow_target);
        
        float target_elevation = get_elevation(flow_target);
        
        // Transférer l'eau si le voisin est plus bas
        if (target_elevation < elevation - 0.1) {
            float water_to_transfer = water * 0.5; // Transférer la moitié
            
            vec4 target_geo = imageLoad(geo_state, flow_target);
            target_geo.g += water_to_transfer;
            target_geo.b += sediment * 0.5; // Transférer la moitié des sédiments
            
            water -= water_to_transfer;
            sediment -= sediment * 0.5;
            
            imageStore(geo_state, flow_target, target_geo);
        }
    }
    
    // Évaporation
    water *= (1.0 - params.evaporation_rate);
    
    // Déposer les sédiments restants si l'eau s'évapore
    if (water < 0.01 && sediment > 0.0) {
        elevation += sediment;
        sediment = 0.0;
    }
    
    // Mettre à jour
    geo.r = elevation;
    geo.g = water;
    geo.b = sediment;
    
    imageStore(geo_state, coord, geo);
}

// ============================================================================
// MAIN COMPUTE SHADER
// ============================================================================

void main() {
    ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
    
    if (pixel_coord.x >= int(params.resolution.x) || pixel_coord.y >= int(params.resolution.y)) {
        return;
    }
    
    // Simuler l'écoulement de l'eau
    simulate_water_flow(pixel_coord);
}