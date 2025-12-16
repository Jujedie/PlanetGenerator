#[compute]
#version 450

// ============================================================================
// HYDRAULIC EROSION COMPUTE SHADER - Virtual Pipes Model
// ============================================================================
// Conservation de masse + Flux basé sur les gradients + Érosion par vélocité
// Projection Équirectangulaire avec wrapping horizontal automatique
// ============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures principales
layout(rgba32f, set = 0, binding = 0) uniform image2D geo_state;     // R=Lithosphere, G=Water, B=Sediment, A=Hardness
layout(rgba32f, set = 0, binding = 1) uniform image2D atmo_state;    // R=Temp, G=Humidity, B=Pressure, A=Cloud
layout(rgba32f, set = 0, binding = 2) uniform image2D flux_map;      // R=FluxLeft, G=FluxRight, B=FluxTop, A=FluxBottom
layout(rgba32f, set = 0, binding = 3) uniform image2D velocity_map;  // R=VelX, G=VelY, B=Speed, A=Unused

// Paramètres de simulation
layout(set = 1, binding = 0) uniform Parameters {
    int step;                    // 0=Rain, 1=Flux, 2=Water, 3=Erosion
    float delta_time;            // Pas de temps physique (ex: 0.016)
    float pipe_area;             // Section du "tuyau virtuel" (ex: 1.0)
    float pipe_length;           // Longueur du tuyau (= taille pixel, ex: 1.0)
    float gravity;               // Constante gravitationnelle (ex: 9.81)
    float rain_rate;             // Taux de pluie (ex: 0.001)
    float evaporation_rate;      // Taux d'évaporation (ex: 0.0001)
    float sediment_capacity_k;   // Coefficient de transport (ex: 0.1)
    float erosion_rate;          // Taux d'érosion (ex: 0.01)
    float deposition_rate;       // Taux de déposition (ex: 0.01)
    float min_height_delta;      // Seuil minimal de hauteur (ex: 0.001)
} params;

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

// Récupération d'UV avec wrapping horizontal (seamless equirectangular)
ivec2 get_wrapped_coord(ivec2 coord, ivec2 size) {
    int x = coord.x;
    int y = coord.y;
    
    // Wrapping horizontal (gauche/droite se rejoignent)
    if (x < 0) x += size.x;
    else if (x >= size.x) x -= size.x;
    
    // Clamp vertical (pas de wrapping aux pôles)
    y = clamp(y, 0, size.y - 1);
    
    return ivec2(x, y);
}

// Hauteur totale pour les calculs physiques
float get_total_height(vec4 geo_data) {
    return geo_data.r + geo_data.g + geo_data.b; // Lithosphere + Water + Sediment
}

// ============================================================================
// STEP 0 : PRECIPITATION (Pluie)
// ============================================================================
void step_rain(ivec2 coord, ivec2 size) {
    vec4 geo = imageLoad(geo_state, coord);
    vec4 atmo = imageLoad(atmo_state, coord);
    
    // Ajout d'eau basé sur l'humidité atmosphérique
    float humidity = atmo.g;
    float rainfall = params.rain_rate * humidity * params.delta_time;
    
    geo.g += rainfall; // Augmente le volume d'eau (canal G)
    
    // Évaporation légère
    geo.g *= (1.0 - params.evaporation_rate * params.delta_time);
    geo.g = max(0.0, geo.g);
    
    imageStore(geo_state, coord, geo);
}

// ============================================================================
// STEP 1 : FLUX CALCULATION (Calcul des flux sortants)
// ============================================================================
void step_flux(ivec2 coord, ivec2 size) {
    vec4 geo_center = imageLoad(geo_state, coord);
    float h_center = get_total_height(geo_center);
    float water_center = geo_center.g;
    
    // Si pas d'eau, pas de flux
    if (water_center < params.min_height_delta) {
        imageStore(flux_map, coord, vec4(0.0));
        return;
    }
    
    // Récupérer les 4 voisins (avec wrapping)
    ivec2 left   = get_wrapped_coord(coord + ivec2(-1,  0), size);
    ivec2 right  = get_wrapped_coord(coord + ivec2( 1,  0), size);
    ivec2 top    = get_wrapped_coord(coord + ivec2( 0, -1), size);
    ivec2 bottom = get_wrapped_coord(coord + ivec2( 0,  1), size);
    
    vec4 geo_left   = imageLoad(geo_state, left);
    vec4 geo_right  = imageLoad(geo_state, right);
    vec4 geo_top    = imageLoad(geo_state, top);
    vec4 geo_bottom = imageLoad(geo_state, bottom);
    
    float h_left   = get_total_height(geo_left);
    float h_right  = get_total_height(geo_right);
    float h_top    = get_total_height(geo_top);
    float h_bottom = get_total_height(geo_bottom);
    
    // Flux précédents (pour stabilité)
    vec4 flux_prev = imageLoad(flux_map, coord);
    
    // Calcul des nouveaux flux (équation de continuité)
    // Flux = max(0, flux_prev + dt * A * g * (dh / L))
    float factor = params.delta_time * params.pipe_area * params.gravity / params.pipe_length;
    
    float flux_left   = max(0.0, flux_prev.r + factor * (h_center - h_left));
    float flux_right  = max(0.0, flux_prev.g + factor * (h_center - h_right));
    float flux_top    = max(0.0, flux_prev.b + factor * (h_center - h_top));
    float flux_bottom = max(0.0, flux_prev.a + factor * (h_center - h_bottom));
    
    // Normalisation si flux total > volume d'eau disponible
    float total_flux = flux_left + flux_right + flux_top + flux_bottom;
    if (total_flux > water_center) {
        float scale = water_center / (total_flux + 1e-6);
        flux_left   *= scale;
        flux_right  *= scale;
        flux_top    *= scale;
        flux_bottom *= scale;
    }
    
    imageStore(flux_map, coord, vec4(flux_left, flux_right, flux_top, flux_bottom));
}

// ============================================================================
// STEP 2 : WATER UPDATE & VELOCITY (Mise à jour de l'eau et calcul de vitesse)
// ============================================================================
void step_water(ivec2 coord, ivec2 size) {
    vec4 geo = imageLoad(geo_state, coord);
    vec4 flux_out = imageLoad(flux_map, coord);
    
    // Récupérer les flux entrants des voisins
    ivec2 left   = get_wrapped_coord(coord + ivec2(-1,  0), size);
    ivec2 right  = get_wrapped_coord(coord + ivec2( 1,  0), size);
    ivec2 top    = get_wrapped_coord(coord + ivec2( 0, -1), size);
    ivec2 bottom = get_wrapped_coord(coord + ivec2( 0,  1), size);
    
    vec4 flux_left   = imageLoad(flux_map, left);
    vec4 flux_right  = imageLoad(flux_map, right);
    vec4 flux_top    = imageLoad(flux_map, top);
    vec4 flux_bottom = imageLoad(flux_map, bottom);
    
    // Flux entrants = flux sortants des voisins vers ce pixel
    float flux_in = flux_right.r + flux_left.g + flux_bottom.b + flux_top.a;
    float flux_out_total = flux_out.r + flux_out.g + flux_out.b + flux_out.a;
    
    // Mise à jour du volume d'eau (conservation de masse)
    float delta_water = (flux_in - flux_out_total) * params.delta_time;
    geo.g += delta_water;
    geo.g = max(0.0, geo.g);
    
    // Calcul du vecteur vitesse (basé sur les flux nets)
    float vel_x = (flux_out.g - flux_out.r + flux_left.g - flux_right.r) * 0.5;
    float vel_y = (flux_out.a - flux_out.b + flux_top.a - flux_bottom.b) * 0.5;
    float speed = length(vec2(vel_x, vel_y));
    
    imageStore(geo_state, coord, geo);
    imageStore(velocity_map, coord, vec4(vel_x, vel_y, speed, 0.0));
}

// ============================================================================
// STEP 3 : EROSION/DEPOSITION (Transport de sédiments)
// ============================================================================
void step_erosion(ivec2 coord, ivec2 size) {
    vec4 geo = imageLoad(geo_state, coord);
    vec4 vel = imageLoad(velocity_map, coord);
    
    float water = geo.g;
    float speed = vel.b;
    float hardness = geo.a; // Résistance à l'érosion (0.5 par défaut)
    
    // Pas d'érosion sans eau ou sans vitesse
    if (water < params.min_height_delta || speed < 0.001) {
        return;
    }
    
    // Calcul du gradient de terrain (pour la pente locale)
    ivec2 left  = get_wrapped_coord(coord + ivec2(-1, 0), size);
    ivec2 right = get_wrapped_coord(coord + ivec2(1, 0), size);
    float h_left  = imageLoad(geo_state, left).r;
    float h_right = imageLoad(geo_state, right).r;
    float slope = abs(h_right - h_left) / (2.0 * params.pipe_length);
    
    // Capacité de transport (Sediment Transport Capacity)
    float capacity = params.sediment_capacity_k * speed * slope;
    
    float sediment_current = geo.b;
    float sediment_diff = capacity - sediment_current;
    
    if (sediment_diff > 0.0) {
        // ÉROSION : L'eau peut transporter plus de sédiments
        float erosion_amount = params.erosion_rate * sediment_diff * params.delta_time;
        erosion_amount *= (1.0 - hardness); // Plus dur = moins d'érosion
        erosion_amount = min(erosion_amount, geo.r * 0.1); // Max 10% du terrain par step
        
        geo.r -= erosion_amount; // Réduction de la lithosphère
        geo.b += erosion_amount; // Augmentation des sédiments
    } else {
        // DÉPOSITION : L'eau transporte trop de sédiments
        float deposition_amount = params.deposition_rate * (-sediment_diff) * params.delta_time;
        deposition_amount = min(deposition_amount, geo.b); // Ne peut pas déposer plus que disponible
        
        geo.b -= deposition_amount; // Réduction des sédiments
        geo.r += deposition_amount * 0.5; // Une partie se reconsolide en roche
        // Le reste reste en sédiment (effet de couche sédimentaire)
    }
    
    geo.r = max(0.0, geo.r);
    geo.b = max(0.0, geo.b);
    
    imageStore(geo_state, coord, geo);
}

// ============================================================================
// MAIN : Dispatch en fonction de l'étape
// ============================================================================
void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(geo_state);
    
    if (coord.x >= size.x || coord.y >= size.y) return;
    
    switch (params.step) {
        case 0: step_rain(coord, size); break;
        case 1: step_flux(coord, size); break;
        case 2: step_water(coord, size); break;
        case 3: step_erosion(coord, size); break;
    }
}