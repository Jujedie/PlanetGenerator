#version 450

// Taille des groupes de threads (standard 8x8 pour les textures)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// --- UNIFORMS & TEXTURES ---

// Texture A : Géophysique (R=Hauteur, G=Eau, B=Sédiment, A=Dureté)
layout(set = 0, binding = 0, rgba32f) uniform image2D geo_map;

// Texture Flux : Stocke les flux sortants vers les 4 voisins (R=Gauche, G=Droite, B=Haut, A=Bas)
layout(set = 0, binding = 1, rgba32f) uniform image2D flux_map;

// Texture Velocity : Stocke la vitesse et la direction (R=VelX, G=VelY, B=N/A, A=N/A)
layout(set = 0, binding = 2, rgba32f) uniform image2D velocity_map;

// Paramètres de simulation
layout(push_constant) uniform Parameters {
    int step_mode;          // 0=Pluie, 1=Flux, 2=Eau, 3=Erosion
    float dt;               // Delta Time (ex: 0.05)
    float pipe_length;      // Distance entre pixels (virtuelle, ex: 1.0)
    float pipe_area;        // Section du tuyau (ex: 1.0)
    float gravity;          // Gravité (ex: 9.8)
    float rain_rate;        // Taux de pluie global
    float evaporation_rate; // Taux d'évaporation
    float sediment_capacity; // K_c
    float erosion_rate;      // K_s
    float deposition_rate;   // K_d
    ivec2 map_size;          // Taille de la texture en pixels
} params;

// --- FONCTIONS UTILITAIRES ---

// Gestion du bouclage horizontal (Cylindrique/Torique sur X uniquement)
ivec2 get_wrapped_uv(ivec2 uv) {
    // Bouclage X (Longitude)
    int x = (uv.x + params.map_size.x) % params.map_size.x;
    // Clamping Y (Latitude - pas de bouclage aux pôles pour éviter les artefacts)
    int y = clamp(uv.y, 0, params.map_size.y - 1);
    return ivec2(x, y);
}

// Lecture sécurisée
vec4 read_geo(ivec2 uv) {
    return imageLoad(geo_map, get_wrapped_uv(uv));
}

// Hauteur Totale = Roche + Eau + Sédiments
float get_total_height(vec4 geo) {
    return geo.r + geo.g + geo.b;
}

// --- MAIN ---

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    if (uv.x >= params.map_size.x || uv.y >= params.map_size.y) return;

    // --- ÉTAPE 0 : PLUIE (Rainfall) ---
    // Ajoute de l'eau uniformément ou basé sur une map de précipitation (ici simplifié)
    if (params.step_mode == 0) {
        vec4 geo = imageLoad(geo_map, uv);
        // Ajout simple : geo.g += params.rain_rate * params.dt; 
        // Note: Dans l'implémentation complète, on lirait ici la texture "Atmosphere" (G=Humidité)
        // Pour l'instant, on simule une pluie uniforme pour tester l'écoulement
        geo.g += params.rain_rate * params.dt;
        imageStore(geo_map, uv, geo);
    }

    // --- ÉTAPE 1 : CALCUL DES FLUX (Flux Computation) ---
    // Calcule combien d'eau veut sortir vers les voisins
    else if (params.step_mode == 1) {
        vec4 geo = imageLoad(geo_map, uv);
        float h_total = get_total_height(geo);
        vec4 flux = imageLoad(flux_map, uv); // Flux précédent

        // Voisins : Gauche, Droite, Haut, Bas
        ivec2 n_uvs[4];
        n_uvs[0] = uv + ivec2(-1, 0); // Gauche
        n_uvs[1] = uv + ivec2(1, 0);  // Droite
        n_uvs[2] = uv + ivec2(0, 1);  // Haut (Attention Godot Y est inversé parfois, ici Y+ = Bas visuel)
        n_uvs[3] = uv + ivec2(0, -1); // Bas

        float h_diffs[4];
        for(int i=0; i<4; i++) {
            vec4 n_geo = read_geo(n_uvs[i]);
            float n_h_total = get_total_height(n_geo);
            h_diffs[i] = h_total - n_h_total; // Positif si on est plus haut
        }

        // Formule Pipe Model : F_new = max(0, F_old + dt * g * (dh/l) * A)
        // Note: On divise par l (pipe_length)
        float flux_factor = params.dt * params.gravity * params.pipe_area / params.pipe_length;
        
        vec4 new_flux;
        new_flux.x = max(0.0, flux.x + flux_factor * h_diffs[0]); // Gauche
        new_flux.y = max(0.0, flux.y + flux_factor * h_diffs[1]); // Droite
        new_flux.z = max(0.0, flux.z + flux_factor * h_diffs[2]); // Haut
        new_flux.w = max(0.0, flux.w + flux_factor * h_diffs[3]); // Bas

        // Scaling (K) : On ne peut pas faire sortir plus d'eau qu'on en a
        float total_outflow = new_flux.x + new_flux.y + new_flux.z + new_flux.w;
        float current_water = geo.g; // Volume d'eau actuel (en hauteur)
        
        // K = min(1, Water / (TotalFlux * dt))
        float k = 1.0;
        if (total_outflow * params.dt > current_water) {
            k = current_water / (total_outflow * params.dt + 0.0001);
        }
        
        new_flux *= k;

        // Limites du monde (Pôles) : Pas de flux vers l'extérieur en Y
        if (uv.y == 0) new_flux.w = 0.0; // Pas de flux vers le bas (Y-1)
        if (uv.y == params.map_size.y - 1) new_flux.z = 0.0; // Pas de flux vers le haut (Y+1)

        imageStore(flux_map, uv, new_flux);
    }

    // --- ÉTAPE 2 : MISE À JOUR DE L'EAU (Water Update) ---
    // Change le niveau d'eau en fonction des entrées et sorties
    else if (params.step_mode == 2) {
        vec4 geo = imageLoad(geo_map, uv);
        vec4 flux_out = imageLoad(flux_map, uv);

        // Somme des flux sortants
        float total_out = flux_out.x + flux_out.y + flux_out.z + flux_out.w;

        // Somme des flux entrants (ceux que les voisins nous envoient)
        float total_in = 0.0;
        
        // Entrée depuis Gauche (C'est le flux Droite du voisin de gauche)
        total_in += imageLoad(flux_map, get_wrapped_uv(uv + ivec2(-1, 0))).y;
        // Entrée depuis Droite (C'est le flux Gauche du voisin de droite)
        total_in += imageLoad(flux_map, get_wrapped_uv(uv + ivec2(1, 0))).x;
        // Entrée depuis Haut (C'est le flux Bas du voisin du haut)
        total_in += imageLoad(flux_map, get_wrapped_uv(uv + ivec2(0, 1))).w;
        // Entrée depuis Bas (C'est le flux Haut du voisin du bas)
        total_in += imageLoad(flux_map, get_wrapped_uv(uv + ivec2(0, -1))).z;

        // Changement de volume : dV = dt * (In - Out)
        float volume_change = params.dt * (total_in - total_out);
        
        // Mise à jour de la hauteur d'eau
        geo.g = max(0.0, geo.g + volume_change);

        // Évaporation simple
        geo.g *= (1.0 - params.evaporation_rate * params.dt);

        imageStore(geo_map, uv, geo);
        
        // --- Calcul de vitesse (Velocity Field) pour l'érosion ---
        // Vitesse approximée par la moyenne des flux traversant la cellule
        float avg_flux_x = (imageLoad(flux_map, get_wrapped_uv(uv + ivec2(-1, 0))).y - flux_out.x + flux_out.y - imageLoad(flux_map, get_wrapped_uv(uv + ivec2(1, 0))).x) * 0.5;
        float avg_flux_y = (imageLoad(flux_map, get_wrapped_uv(uv + ivec2(0, -1))).z - flux_out.w + flux_out.z - imageLoad(flux_map, get_wrapped_uv(uv + ivec2(0, 1))).w) * 0.5;
        
        // Reconstruction vecteur vitesse
        vec2 velocity = vec2(avg_flux_x, avg_flux_y);
        imageStore(velocity_map, uv, vec4(velocity, 0.0, 0.0));
    }

    // --- ÉTAPE 3 : ÉROSION & DÉPÔT (Erosion/Deposition) ---
    else if (params.step_mode == 3) {
        vec4 geo = imageLoad(geo_map, uv);
        vec2 vel = imageLoad(velocity_map, uv).xy;
        float speed = length(vel);
        
        // Capacité de transport de sédiments (C) = Kc * speed
        // On peut ajouter l'angle de pente (tilt) pour plus de réalisme
        float capacity = params.sediment_capacity * speed;

        float current_sediment = geo.b; // Canal Bleu = Sédiments suspendus ou déposés
        
        // On distingue ici "Sédiment Suspendu" vs "Sédiment au Sol".
        // Dans ce modèle simplifié "Packed", B représente le sédiment accumulé au sol (Sable).
        // L'érosion transforme R (Roche) en B (Sable).
        
        if (capacity > current_sediment) {
            // EROSION : L'eau peut porter plus que ce qu'il y a. Elle attaque la roche.
            float erode_amount = params.erosion_rate * (capacity - current_sediment) * params.dt;
            // On ne peut pas éroder plus que ce qu'il y a
            erode_amount = min(erode_amount, geo.r); // Erode la roche
            
            geo.r -= erode_amount; // Enlève de la roche
            geo.b += erode_amount; // Transforme en sédiment (déplacement local)
        } else {
            // DÉPÔT : L'eau est saturée, elle dépose le sédiment.
            float deposit_amount = params.deposition_rate * (current_sediment - capacity) * params.dt;
            // On ne dépose pas de la roche (R), mais on accumule du sédiment (B)
            // Dans ce modèle simple, B sert de buffer.
            // Si on voulait simuler le transport, il faudrait advecter le sédiment (étape supplémentaire).
            // Ici, on fait un lissage local : le sédiment s'accumule là où c'est lent.
        }

        imageStore(geo_map, uv, geo);
    }
}