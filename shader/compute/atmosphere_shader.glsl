#[compute]
#version 450

// Simulation atmosphérique: Advection + Diffusion + Coriolis + Formation Nuages

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba32f, set = 0, binding = 0) uniform readonly image2D atmospheric_state_in;
layout(rgba32f, set = 0, binding = 1) uniform readonly image2D geophysical_state;  // Pour orographic lift
layout(rgba32f, set = 0, binding = 2) uniform writeonly image2D atmospheric_state_out;

layout(push_constant) uniform Params {
    float solar_constant;      // Énergie solaire (1361 W/m²)
    float rotation_speed;      // Vitesse rotation (rad/s) pour Coriolis
    float diffusion_rate;      // Mélange thermique (0.01)
    float condensation_threshold; // Humidité -> Nuages (0.7)
    float delta_time;          // Pas temps (secondes)
} params;

const ivec2 RESOLUTION = ivec2(2048, 1024);
const float PI = 3.14159265359;

ivec2 wrap_coords(ivec2 coord) {
    coord.x = coord.x % RESOLUTION.x;
    if (coord.x < 0) coord.x += RESOLUTION.x;
    coord.y = clamp(coord.y, 0, RESOLUTION.y - 1);
    return coord;
}

// === CHAUFFAGE SOLAIRE (FONCTION LATITUDE) ===
float compute_solar_heating(float latitude) {
    // Latitude en radians (-PI/2 à PI/2)
    float lat_rad = (latitude - 0.5) * PI;
    
    // Formule: I = I₀ * cos(lat), max à l'équateur
    float intensity = params.solar_constant * max(0.0, cos(lat_rad));
    
    return intensity * params.delta_time * 0.001;  // Conversion Kelvin
}

// === FORCE DE CORIOLIS ===
vec2 apply_coriolis(vec2 velocity, float latitude) {
    float lat_rad = (latitude - 0.5) * PI;
    float f = 2.0 * params.rotation_speed * sin(lat_rad);  // Paramètre Coriolis
    
    // Déviation perpendiculaire à la vitesse
    vec2 coriolis_force = vec2(-velocity.y, velocity.x) * f * params.delta_time;
    
    return velocity + coriolis_force;
}

// === ADVECTION SEMI-LAGRANGIENNE ===
// Corrected: Removed the 'image2D' parameter. Accesses global variable directly.
vec4 advect(vec2 uv, vec2 velocity) {
    vec2 back_uv = uv - velocity * params.delta_time;
    
    // Wrapping horizontal
    back_uv.x = fract(back_uv.x);
    back_uv.y = clamp(back_uv.y, 0.0, 1.0);
    
    ivec2 back_pixel = ivec2(back_uv * vec2(RESOLUTION));
    return imageLoad(atmospheric_state_in, wrap_coords(back_pixel));
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, RESOLUTION))) return;
    
    vec2 uv = vec2(pixel) / vec2(RESOLUTION);
    float latitude = uv.y;
    
    // === LIRE ÉTAT ACTUEL ===
    vec4 atmo = imageLoad(atmospheric_state_in, pixel);
    float temperature = atmo.r;  // Kelvin
    float humidity = atmo.g;     // Ratio 0-1
    vec2 wind = atmo.ba;         // Vecteur vitesse (m/s normalisé)
    
    vec4 geo = imageLoad(geophysical_state, pixel);
    float elevation = geo.r;
    
    // === 1. CHAUFFAGE SOLAIRE ===
    temperature += compute_solar_heating(latitude);
    
    // === 2. DIFFUSION THERMIQUE (MOYENNE 3x3) ===
    float avg_temp = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 n = wrap_coords(pixel + ivec2(dx, dy));
            avg_temp += imageLoad(atmospheric_state_in, n).r;
        }
    }
    avg_temp /= 9.0;
    temperature = mix(temperature, avg_temp, params.diffusion_rate);
    
    // === 3. GÉNÉRATION DE VENT (GRADIENT PRESSION) ===
    // Pression ∝ Température (loi gaz parfaits simplifiée)
    vec2 pressure_grad = vec2(0.0);
    for (int i = -1; i <= 1; i += 2) {
        ivec2 px = wrap_coords(pixel + ivec2(i, 0));
        ivec2 py = wrap_coords(pixel + ivec2(0, i));
        pressure_grad.x += (imageLoad(atmospheric_state_in, px).r - temperature) * float(i);
        pressure_grad.y += (imageLoad(atmospheric_state_in, py).r - temperature) * float(i);
    }
    wind -= pressure_grad * 0.01;  // Vent suit gradient pression
    
    // === 4. CORIOLIS ===
    wind = apply_coriolis(wind, latitude);
    
    // === 5. ADVECTION HUMIDITÉ ===
    // Corrected call: removed the first argument
    vec4 advected = advect(uv, wind);
    humidity = advected.g;
    
    // === 6. OROGRAPHIC LIFT (RELIEF + VENT = PLUIE) ===
    // Calculer pente du relief
    float elev_east = imageLoad(geophysical_state, wrap_coords(pixel + ivec2(1, 0))).r;
    float slope = (elev_east - elevation) / 1000.0;  // Pente normalisée
    
    // Si vent monte (dot(wind, gradient) < 0), humidité se condense
    if (wind.x * slope < -0.01 && elevation > 0.0) {
        float lift_factor = abs(wind.x * slope);
        humidity = max(0.0, humidity - lift_factor * 0.5);  // Pluie
    }
    
    // === 7. CONDENSATION -> NUAGES ===
    float cloud_density = 0.0;
    if (humidity > params.condensation_threshold) {
        cloud_density = (humidity - params.condensation_threshold) / (1.0 - params.condensation_threshold);
        humidity = params.condensation_threshold;  // Saturation
    }
    
    // === 8. DISSIPATION VENT (FRICTION) ===
    wind *= 0.99;
    
    // === ÉCRIRE RÉSULTAT ===
    imageStore(atmospheric_state_out, pixel, vec4(
        clamp(temperature, 180.0, 330.0),  // R: Température
        clamp(humidity, 0.0, 1.0),          // G: Humidité
        wind.x,                             // B: Vent X
        wind.y                              // A: Vent Y (pas nuage ici, calculé séparément)
    ));
    
    // Note: Cloud density sera stocké dans une texture dédiée ou calculé en temps réel
}