#[compute]
#version 450

// Workgroup size (16x16 threads per group)
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// State textures
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_state;      // R: elevation, G: water, B: sediment, A: plate_id
layout(set = 0, binding = 1, rgba32f) uniform image2D plate_data;     // R: velocity_x, G: velocity_y, B: friction, A: type

// Uniform buffer with generation parameters
layout(set = 1, binding = 0) uniform Params {
    uint seed;
    uint num_plates;
    float plate_strength;
    float friction_coefficient;
    float convergence_uplift;    // Soulèvement aux zones de convergence
    float divergence_subsidence; // Affaissement aux zones de divergence
    uvec2 resolution;
    float time;
} params;

// ============================================================================
// HASH FUNCTIONS - Pour génération pseudo-aléatoire déterministe
// ============================================================================

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

uint hash(uvec2 v) {
    return hash(v.x ^ hash(v.y) ^ params.seed);
}

float random(uvec2 v) {
    return float(hash(v)) / float(0xffffffffU);
}

vec2 random2(uvec2 v) {
    uint h = hash(v);
    return vec2(
        float(h & 0xffffU) / float(0xffffU),
        float(h >> 16) / float(0xffffU)
    );
}

// ============================================================================
// VORONOI FUNCTIONS - Diagramme de Voronoi pour les plaques
// ============================================================================

// Génère la position d'une plaque tectonique
vec2 get_plate_position(uint plate_id) {
    uvec2 seed_coord = uvec2(plate_id * 73856093U, plate_id * 19349663U);
    vec2 rand = random2(seed_coord);
    return rand * vec2(params.resolution);
}

// Génère le vecteur de mouvement d'une plaque
vec2 get_plate_velocity(uint plate_id) {
    uvec2 seed_coord = uvec2(plate_id * 83492791U, plate_id * 77825731U);
    vec2 rand = random2(seed_coord);
    // Convertir en vecteur directionnel
    float angle = rand.x * 6.28318530718; // 2*PI
    float speed = rand.y * params.plate_strength;
    return vec2(cos(angle), sin(angle)) * speed;
}

// Trouve la plaque la plus proche et calcule la distance
void find_nearest_plates(vec2 pos, out uint nearest_id, out uint second_nearest_id, 
                        out float nearest_dist, out float second_dist) {
    nearest_dist = 1e10;
    second_dist = 1e10;
    nearest_id = 0;
    second_nearest_id = 0;
    
    for (uint i = 0; i < params.num_plates; i++) {
        vec2 plate_pos = get_plate_position(i);
        
        // Distance avec wrapping horizontal (cylindrique)
        vec2 diff = pos - plate_pos;
        diff.x = min(abs(diff.x), float(params.resolution.x) - abs(diff.x));
        float dist = length(diff);
        
        if (dist < nearest_dist) {
            second_dist = nearest_dist;
            second_nearest_id = nearest_id;
            nearest_dist = dist;
            nearest_id = i;
        } else if (dist < second_dist) {
            second_dist = dist;
            second_nearest_id = i;
        }
    }
}

// ============================================================================
// TECTONIC CALCULATIONS - Calculs des interactions tectoniques
// ============================================================================

float calculate_tectonic_elevation(vec2 pos, uint plate_id, float dist_to_boundary) {
    vec2 plate_pos = get_plate_position(plate_id);
    vec2 plate_vel = get_plate_velocity(plate_id);
    
    // Base elevation from plate position (simulation de croûte continentale/océanique)
    float base_elevation = (random(uvec2(plate_id * 12345U, plate_id * 67890U)) - 0.5) * 2000.0;
    
    // Si proche d'une frontière de plaque
    if (dist_to_boundary < 100.0) {
        // Calculer la friction entre plaques voisines
        uint second_plate;
        float second_dist;
        uint dummy1, dummy2;
        float dummy3;
        find_nearest_plates(pos, dummy1, second_plate, dummy3, second_dist);
        
        vec2 other_vel = get_plate_velocity(second_plate);
        vec2 relative_vel = plate_vel - other_vel;
        
        // Direction vers la frontière
        vec2 to_boundary = normalize(pos - plate_pos);
        
        // Composante de convergence/divergence
        float convergence = dot(relative_vel, to_boundary);
        
        // Zone de transition douce (0 au centre de la plaque, 1 à la frontière)
        float boundary_factor = smoothstep(100.0, 0.0, dist_to_boundary);
        
        if (convergence > 0.0) {
            // CONVERGENCE : Soulèvement (montagnes)
            base_elevation += convergence * params.convergence_uplift * boundary_factor;
        } else {
            // DIVERGENCE : Affaissement (rifts, dorsales)
            base_elevation += convergence * params.divergence_subsidence * boundary_factor;
        }
        
        // Stocker le coefficient de friction pour l'orogenèse
        return base_elevation;
    }
    
    return base_elevation;
}

// ============================================================================
// MAIN COMPUTE SHADER
// ============================================================================

void main() {
    ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérifier les limites
    if (pixel_coord.x >= int(params.resolution.x) || pixel_coord.y >= int(params.resolution.y)) {
        return;
    }
    
    vec2 pos = vec2(pixel_coord);
    
    // Trouver les plaques les plus proches
    uint nearest_plate, second_plate;
    float nearest_dist, second_dist;
    find_nearest_plates(pos, nearest_plate, second_plate, nearest_dist, second_dist);
    
    // Distance à la frontière de plaque (zone de friction)
    float dist_to_boundary = second_dist - nearest_dist;
    
    // Calculer l'élévation tectonique
    float elevation = calculate_tectonic_elevation(pos, nearest_plate, dist_to_boundary);
    
    // Calculer les données de plaque
    vec2 plate_velocity = get_plate_velocity(nearest_plate);
    float friction = 0.0;
    
    if (dist_to_boundary < 100.0) {
        // Zone de friction élevée près des frontières
        friction = smoothstep(100.0, 0.0, dist_to_boundary) * params.friction_coefficient;
    }
    
    // Type de plaque (0 = océanique, 1 = continentale)
    float plate_type = elevation > 0.0 ? 1.0 : 0.0;
    
    // Écrire dans les textures
    vec4 geo = vec4(elevation, 0.0, 0.0, float(nearest_plate));
    vec4 plate = vec4(plate_velocity.x, plate_velocity.y, friction, plate_type);
    
    imageStore(geo_state, pixel_coord, geo);
    imageStore(plate_data, pixel_coord, plate);
}