#[compute]
#version 450

// ============================================================================
// CRUST AGE FINALIZATION
// ============================================================================
//
// Ce shader est exécuté APRÈS le JFA pour convertir les distances en âge réel
// et calculer la subsidence thermique.
//
// FORMAT D'ENTRÉE (après JFA):
// - R = seed_x
// - G = seed_y  
// - B = distance² (en pixels²)
// - A = valid flag
//
// FORMAT DE SORTIE:
// - R = distance (km)
// - G = age (Ma)
// - B = subsidence (m)
// - A = valid flag
//
// La subsidence suit le modèle de refroidissement de la lithosphère:
// subsidence = 2800 * sqrt(age / 100)  [en mètres, pour age en Ma]
//
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// ============================================================================
// BINDINGS
// ============================================================================

// Set 0: Textures
layout(set = 0, binding = 0, rgba32f) uniform readonly  image2D plates_texture;
layout(set = 0, binding = 1, rgba32f) uniform           image2D crust_age_texture;
layout(set = 0, binding = 2, rgba32f) uniform           image2D geo_texture;

// Set 1: Paramètres
layout(set = 1, binding = 0) uniform Params {
    uint width;
    uint height;
    float spreading_rate;    // km/Ma (typiquement 20-80)
    float planet_radius;     // km (Terre = 6371)
    float max_age;           // Ma (typiquement 200 Ma max pour croûte océanique)
    float subsidence_coeff;  // Coefficient de subsidence (2500-3000)
    float padding1;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float NO_SEED = -1.0;
const float PI = 3.14159265359;

// ============================================================================
// MAIN SHADER
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Bounds check
    if (pixel.x >= int(params.width) || pixel.y >= int(params.height)) {
        return;
    }
    
    // Lire les données JFA
    vec4 jfa_data = imageLoad(crust_age_texture, pixel);
    float seed_x = jfa_data.r;
    float seed_y = jfa_data.g;
    float dist_sq = jfa_data.b;
    float valid = jfa_data.a;
    
    // Si pas de seed trouvé, ce n'est pas de la croûte océanique propagée
    if (seed_x == NO_SEED || valid < 0.5) {
        // Pas de croûte océanique active - marquer comme continental
        vec4 result = vec4(
            -1.0,            // R: pas de distance
            -1.0,            // G: âge invalide (continental)
            0.0,             // B: pas de subsidence
            0.0              // A: invalide
        );
        imageStore(crust_age_texture, pixel, result);
        return;
    }
    
    // === CALCUL DE LA DISTANCE EN KM ===
    
    // Distance en pixels (racine carrée de dist_sq)
    float dist_pixels = sqrt(dist_sq);
    
    // Convertir la distance en pixels vers km
    // En équirectangulaire:
    // - X: circumference / width = (2πR) / width
    // - Y: half-circumference / height = (πR) / height
    float pixel_to_km_x = (2.0 * PI * params.planet_radius) / float(params.width);
    float pixel_to_km_y = (PI * params.planet_radius) / float(params.height);
    
    // Utiliser une moyenne (approximation simple)
    // Une meilleure approche tiendrait compte de la latitude
    float pixel_to_km = (pixel_to_km_x + pixel_to_km_y) * 0.5;
    
    float dist_km = dist_pixels * pixel_to_km;
    
    // === CALCUL DE L'ÂGE ===
    
    // Âge = distance / taux d'expansion
    // spreading_rate est en km/Ma (kilomètres par million d'années)
    // Pour une dorsale symétrique, chaque côté s'éloigne à spreading_rate/2
    // Donc age = distance / (spreading_rate / 2) = 2 * distance / spreading_rate
    float age_ma = (2.0 * dist_km) / params.spreading_rate;
    
    // Plafonner l'âge (la croûte océanique ne dépasse pas ~200 Ma avant subduction)
    age_ma = min(age_ma, params.max_age);
    
    // === CALCUL DE LA SUBSIDENCE THERMIQUE ===
    
    // Modèle de Parsons & Sclater (1977):
    // La subsidence représente l'enfoncement du plancher océanique
    // par rapport à la crête (dorsale) due au refroidissement
    //
    // depth(t) = depth_ridge + c * sqrt(t)
    // où c ≈ 350 m/Ma^0.5 (empirique)
    
    float subsidence = 0.0;
    if (age_ma > 0.0) {
        // Modèle racine carrée simplifié
        // subsidence = coeff * sqrt(age / 100) pour normaliser
        subsidence = params.subsidence_coeff * sqrt(age_ma / 100.0);
        
        // Plafond de subsidence (~3400m pour croûte de 125 Ma)
        float max_subsidence = params.subsidence_coeff * sqrt(1.25);
        subsidence = min(subsidence, max_subsidence);
    }
    
    // === ÉCRITURE DU RÉSULTAT ===
    
    vec4 result = vec4(
        dist_km,         // R: distance en km
        age_ma,          // G: âge en Ma
        subsidence,      // B: subsidence en mètres
        1.0              // A: marqueur de validité
    );
    imageStore(crust_age_texture, pixel, result);
    
    // === APPLIQUER LA SUBSIDENCE À LA GEO_TEXTURE ===
    
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;
    
    // Ne modifier que les pixels océaniques (élévation négative ou proche de 0)
    // et avec un âge valide
    if (height < 500.0 && age_ma > 0.0) {
        // Appliquer la subsidence (enfoncement)
        height -= subsidence;
        
        // Mettre à jour la colonne d'eau si nécessaire
        float sea_level = 0.0;  // On suppose sea_level = 0 pour simplifier
        if (height < sea_level) {
            geo.a = sea_level - height;  // Colonne d'eau
        }
        
        geo.r = height;
        imageStore(geo_texture, pixel, geo);
    }
}
