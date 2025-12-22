#[compute]
#version 450

// ============================================================================
// HYDRAULIC EROSION COMPUTE SHADER - Cylindrical Equirectangular Corrected
// ============================================================================
// Shader d'érosion hydraulique corrigeant la distorsion polaire de la projection
// équirectangulaire (Lat/Lon). Les distances et surfaces sont calculées dynamiquement.
// Modèle: Virtual Pipes (Conservation de masse).
// ============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// --- TEXTURES D'ÉTAT ---
layout(rgba32f, set = 0, binding = 0) uniform image2D geo_state;     // R=Height (Bedrock), G=Water, B=Sediment, A=Hardness
layout(rgba32f, set = 0, binding = 1) uniform image2D atmo_state;    // R=Temp, G=Humid, B=Press, A=Cloud
layout(rgba32f, set = 0, binding = 2) uniform image2D flux_map;      // R=FluxLeft, G=FluxRight, B=FluxTop, A=FluxBottom
layout(rgba32f, set = 0, binding = 3) uniform image2D velocity_map;  // R=VelX, G=VelY, B=Speed

// --- PARAMÈTRES DE SIMULATION ---
// Mise à jour selon Spec_Correction_Projection_Cylindrique.md
layout(set = 1, binding = 0) uniform Parameters {
    int step;                    // 0=Rain, 1=Flux, 2=Water/Velocity, 3=Erosion
    float delta_time;            // Pas de temps (dt)
    float planet_radius;         // Rayon R en mètres (ex: 6371000.0)
    float gravity;               // Gravité g (m/s^2)
    float rain_intensity;        // Intensité pluie (m/s)
    float Kc;                    // Capacité de transport sédimentaire
    float Ks;                    // Taux d'érosion (dissolution)
    float Kd;                    // Taux de déposition
    float Ke;                    // Taux d'évaporation
} params;

const float PI = 3.14159265359;

// Fonction utilitaire pour le wrapping horizontal (Cylindre)
ivec2 wrap_coords(ivec2 coord, ivec2 size) {
    coord.x = coord.x % size.x;
    if (coord.x < 0) coord.x += size.x;
    coord.y = clamp(coord.y, 0, size.y - 1); // Clamp aux pôles (pas de wrapping Y)
    return coord;
}

void main() {
    ivec2 size = imageSize(geo_state);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    
    // Hors limites
    if (coord.x >= size.x || coord.y >= size.y) return;

    // ========================================================================
    // 1. CALCUL MÉTRIQUE (CORRECTION PROJECTION)
    // ========================================================================
    // Latitude normalisée (-PI/2 à +PI/2)
    float normalized_y = float(coord.y) / float(size.y);
    float phi = (normalized_y - 0.5) * PI;
    
    // Facteur d'échelle métrique en X (compression aux pôles)
    // max(0.00001) évite la division par zéro aux pôles exacts
    float metric_x = max(0.00001, cos(phi));
    
    // Dimensions physiques de la cellule actuelle (en mètres)
    // dist_x varie avec la latitude, dist_y est constant
    float dist_x = params.planet_radius * (2.0 * PI / float(size.x)) * metric_x;
    float dist_y = params.planet_radius * (PI / float(size.y));
    
    // Surface physique de la cellule (m²)
    float cell_area = dist_x * dist_y;

    // Chargement de l'état géologique
    vec4 geo = imageLoad(geo_state, coord);
    float terrain_h = geo.r;
    float water_h = geo.g;
    float sediment = geo.b;
    float hardness = geo.a;

    // ========================================================================
    // 2. ÉTAPES DE SIMULATION
    // ========================================================================
    switch (params.step) {
        
        // --- ÉTAPE 0 : PRÉCIPITATIONS & ÉVAPORATION ---
        case 0: {
            // Ajout d'eau (Pluie)
            // Note: On ajoute une hauteur d'eau. La volume total ajouté dépend de cell_area.
            float rain_amount = params.rain_intensity * params.delta_time;
            
            // Évaporation (proportionnelle à la surface et au temps)
            // L'eau s'évapore plus vite s'il fait chaud (optionnel: utiliser atmo.r)
            float evaporation = water_h * params.Ke * params.delta_time;
            
            water_h = max(0.0, water_h + rain_amount - evaporation);
            
            geo.g = water_h;
            imageStore(geo_state, coord, geo);
            break;
        }

        // --- ÉTAPE 1 : CALCUL DES FLUX (OUTFLOW) ---
        case 1: {
            float total_height = terrain_h + water_h;
            
            // Voisins (gauche, droite, haut, bas)
            ivec2 L = wrap_coords(coord + ivec2(-1, 0), size);
            ivec2 R = wrap_coords(coord + ivec2( 1, 0), size);
            ivec2 T = wrap_coords(coord + ivec2( 0,-1), size);
            ivec2 B = wrap_coords(coord + ivec2( 0, 1), size);
            
            vec4 gL = imageLoad(geo_state, L);
            vec4 gR = imageLoad(geo_state, R);
            vec4 gT = imageLoad(geo_state, T);
            vec4 gB = imageLoad(geo_state, B);
            
            // Différences de hauteur hydrostatique (Delta H)
            float dH_L = total_height - (gL.r + gL.g);
            float dH_R = total_height - (gR.r + gR.g);
            float dH_T = total_height - (gT.r + gT.g);
            float dH_B = total_height - (gB.r + gB.g);
            
            // Chargement du flux précédent
            vec4 flux = imageLoad(flux_map, coord);
            
            // Sections transversales des "tuyaux" (Pipe Cross-section Area)
            // Flux Gauche/Droite passe par l'interface verticale (hauteur = dist_y)
            float pipe_area_horiz = dist_y * water_h; 
            // Flux Haut/Bas passe par l'interface horizontale (largeur = dist_x)
            float pipe_area_vert  = dist_x * water_h;
            
            // Mise à jour des flux (Formule physique Pipe Model)
            // F_new = max(0, F_old + dt * A * g * (dH / Length))
            // Length est la distance entre centres : dist_x pour L/R, dist_y pour T/B.
            
            float nF_L = max(0.0, flux.r + params.delta_time * pipe_area_horiz * params.gravity * dH_L / dist_x);
            float nF_R = max(0.0, flux.g + params.delta_time * pipe_area_horiz * params.gravity * dH_R / dist_x);
            float nF_T = max(0.0, flux.b + params.delta_time * pipe_area_vert  * params.gravity * dH_T / dist_y);
            float nF_B = max(0.0, flux.a + params.delta_time * pipe_area_vert  * params.gravity * dH_B / dist_y);
            
            // Scaling facteur K pour empêcher le volume sortant de dépasser le volume d'eau total
            float total_out_flux = nF_L + nF_R + nF_T + nF_B;
            float total_out_vol = total_out_flux * params.delta_time;
            float current_vol = water_h * cell_area;
            
            float K = 1.0;
            if (total_out_vol > current_vol) {
                K = current_vol / max(0.0001, total_out_vol);
            }
            
            // Sauvegarde des flux mis à l'échelle
            imageStore(flux_map, coord, vec4(nF_L, nF_R, nF_T, nF_B) * K);
            break;
        }

        // --- ÉTAPE 2 : MISE À JOUR EAU & VÉLOCITÉ ---
        case 2: {
            // Flux entrants (provenant des voisins)
            ivec2 L = wrap_coords(coord + ivec2(-1, 0), size);
            ivec2 R = wrap_coords(coord + ivec2( 1, 0), size);
            ivec2 T = wrap_coords(coord + ivec2( 0,-1), size);
            ivec2 B = wrap_coords(coord + ivec2( 0, 1), size);
            
            // Flux entrant depuis la DROITE du voisin GAUCHE, etc.
            float f_in_L = imageLoad(flux_map, L).g; 
            float f_in_R = imageLoad(flux_map, R).r;
            float f_in_T = imageLoad(flux_map, T).a;
            float f_in_B = imageLoad(flux_map, B).b;
            float total_inflow = f_in_L + f_in_R + f_in_T + f_in_B;
            
            // Flux sortants actuels
            vec4 current_flux = imageLoad(flux_map, coord);
            float total_outflow = current_flux.r + current_flux.g + current_flux.b + current_flux.a;
            
            // Changement de volume net
            float dV = params.delta_time * (total_inflow - total_outflow);
            
            // Mise à jour hauteur d'eau (Volume / Aire)
            // CRITIQUE : L'aire 'cell_area' est petite aux pôles, ce qui compense les petites distances de flux
            float dH = dV / max(0.0001, cell_area);
            geo.g = max(0.0, geo.g + dH);
            imageStore(geo_state, coord, geo);
            
            // -- Calcul Vélocité pour Érosion --
            // V = NetFlux / CrossSection
            // Flux net moyen traversant la cellule
            float flux_net_x = (f_in_L - current_flux.r + current_flux.g - f_in_R) * 0.5;
            float flux_net_y = (f_in_T - current_flux.b + current_flux.a - f_in_B) * 0.5;
            
            // Aire transversale moyenne
            float cs_x = dist_y * geo.g; // Aire plan YZ
            float cs_y = dist_x * geo.g; // Aire plan XZ
            
            float vel_x = flux_net_x / max(0.0001, cs_x);
            float vel_y = flux_net_y / max(0.0001, cs_y);
            
            // Stockage vélocité (R=X, G=Y, B=Magnitude)
            imageStore(velocity_map, coord, vec4(vel_x, vel_y, length(vec2(vel_x, vel_y)), 0.0));
            break;
        }

        // --- ÉTAPE 3 : ÉROSION & DÉPOSITION ---
        case 3: {
            vec4 vel_data = imageLoad(velocity_map, coord);
            float speed = vel_data.b;
            
            // Capacité de transport de sédiment (C)
            // C = Kc * vitesse (modèle simplifié linéaire)
            // On peut ajouter l'angle de pente (sin alpha) pour plus de réalisme
            float capacity = params.Kc * speed;
            
            // Si sédiments < capacité => Érosion
            if (sediment < capacity) {
                float erode = params.Ks * (capacity - sediment) * params.delta_time;
                // Modulateur de dureté du sol
                erode *= (1.0 - hardness);
                // On ne peut pas éroder plus que ce qu'il y a
                // Ici on prend du bedrock (geo.r)
                erode = min(erode, geo.r);
                
                geo.r -= erode;
                geo.b += erode; // Ajout au stock sédimentaire
            
            // Si sédiments > capacité => Déposition
            } else {
                float deposit = params.Kd * (sediment - capacity) * params.delta_time;
                deposit = min(deposit, geo.b);
                
                geo.b -= deposit;
                geo.r += deposit; // Le sédiment redevient du sol (ou reste en couche sédimentaire selon design)
            }
            
            imageStore(geo_state, coord, geo);
            break;
        }
    }
}