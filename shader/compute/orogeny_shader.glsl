#version 450

// Calcul des forces tectoniques: Convergence -> Montagnes, Divergence -> Rifts

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba32f, set = 0, binding = 0) uniform readonly image2D plate_data;      // PlateID + Vecteurs
layout(rgba32f, set = 0, binding = 1) uniform image2D geophysical_state;  // R=Lithosphère (modifié)

layout(push_constant) uniform Params {
    float mountain_strength;  // Multiplicateur convergence (ex: 50.0)
    float rift_strength;      // Multiplicateur divergence (ex: -30.0)
    float erosion_factor;     // Atténuation altitude extrême (0.98)
    float delta_time;         // Pas de simulation (années)
} params;

const ivec2 RESOLUTION = ivec2(2048, 1024);
const float PI = 3.14159265359;

ivec2 wrap_coords(ivec2 coord) {
    coord.x = coord.x % RESOLUTION.x;
    if (coord.x < 0) coord.x += RESOLUTION.x;
    coord.y = clamp(coord.y, 0, RESOLUTION.y - 1);
    return coord;
}

// === CALCUL VECTEUR VITESSE PLAQUE ===
// Basé sur rotation simple + bruit pour variabilité
vec2 compute_plate_velocity(float plate_id, vec2 uv) {
    // Chaque plaque a une rotation pseudo-aléatoire
    float angle = fract(sin(plate_id * 78.233) * 43758.5453) * 2.0 * PI;
    float speed = 0.001 * params.delta_time;  // ~1cm/an en coordonnées normalisées
    
    // Vecteur tangentiel à la surface
    vec2 velocity = vec2(cos(angle), sin(angle)) * speed;
    
    // Ajuster selon latitude (Coriolis simplifié)
    float lat_factor = cos((uv.y - 0.5) * PI);
    velocity.x *= lat_factor;
    
    return velocity;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, RESOLUTION))) return;
    
    vec2 uv = vec2(pixel) / vec2(RESOLUTION);
    
    // Lire données plaques
    vec4 plate = imageLoad(plate_data, pixel);
    float plate_id = plate.r;
    vec2 plate_vec = compute_plate_velocity(plate_id, uv);
    
    // Lire état géophysique actuel
    vec4 geo = imageLoad(geophysical_state, pixel);
    float lithosphere = geo.r;  // Hauteur actuelle
    
    // === CALCUL STRESS AVEC VOISINS ===
    float total_stress = 0.0;
    int neighbor_count = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            ivec2 n_coord = wrap_coords(pixel + ivec2(dx, dy));
            vec4 n_plate = imageLoad(plate_data, n_coord);
            
            if (n_plate.r != plate_id) {  // Frontière entre plaques
                vec2 n_vec = compute_plate_velocity(n_plate.r, vec2(n_coord) / vec2(RESOLUTION));
                
                // Produit scalaire: < 0 = Convergence, > 0 = Divergence
                float stress = dot(normalize(plate_vec), normalize(n_vec));
                total_stress += stress;
                neighbor_count++;
            }
        }
    }
    
    if (neighbor_count == 0) {
        // Intérieur de plaque: érosion légère
        lithosphere *= params.erosion_factor;
    } else {
        float avg_stress = total_stress / float(neighbor_count);
        
        if (avg_stress < -0.3) {
            // CONVERGENCE FORTE: Orogénèse (Montagnes)
            float uplift = params.mountain_strength * (-avg_stress - 0.3) * params.delta_time;
            lithosphere += uplift;
        } else if (avg_stress > 0.3) {
            // DIVERGENCE FORTE: Rifting
            float subsidence = params.rift_strength * (avg_stress - 0.3) * params.delta_time;
            lithosphere += subsidence;
        }
        
        // Limiter altitude extrême (isostasie simplifiée)
        lithosphere = clamp(lithosphere, -12000.0, 8800.0);
    }
    
    // Écrire résultat
    geo.r = lithosphere;
    imageStore(geophysical_state, pixel, geo);
}
