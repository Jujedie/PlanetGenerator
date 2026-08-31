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
    float subsidence_coeff;  // Subsidence à 100 Ma, en mètres
    float sea_level;
    float padding2;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const float NO_SEED = -1.0;
const float PI = 3.14159265359;

// ============================================================================
// FONCTIONS DE BRUIT POUR RELIEF OCÉANIQUE
// ============================================================================

// Hash simple pour bruit
uint hashOcean(uint x) {
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    x *= 0xc2b2ae35u;
    x ^= x >> 16;
    return x;
}

float randOcean(uint h) {
    return float(h) / 4294967295.0;
}

// Modulo positif pour l'axe périodique. Le bruit bathymétrique est évalué
// dans un domaine [0, period_x) où la cellule suivant period_x - 1 est la
// cellule 0. Cela ferme réellement le bruit à la couture longitudinale au lieu
// de seulement wrapper les lectures de textures après coup.
int positiveModulo(int value, int modulus) {
    int result = value % modulus;
    return result < 0 ? result + modulus : result;
}

// Bruit de valeur 2D périodique sur X et non périodique sur Y. Pour les
// cellules qui ne touchent pas la couture, les mêmes indices/hash que
// l'ancienne version sont conservés ; seule l'interpolation de fermeture relie
// la dernière cellule longitudinale à la première.
float oceanNoise2DPeriodic(vec2 p, uint seed, int period_x) {
    ivec2 cell = ivec2(floor(p));
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    int safe_period_x = max(period_x, 1);
    int wrapped_x0 = positiveModulo(cell.x, safe_period_x);
    int wrapped_x1 = positiveModulo(cell.x + 1, safe_period_x);

    uint ix0 = uint(wrapped_x0 + 1000);
    uint ix1 = uint(wrapped_x1 + 1000);
    uint iy0 = uint(cell.y + 1000);
    uint iy1 = uint(cell.y + 1001);

    float a = randOcean(hashOcean(ix0 + seed) ^ hashOcean(iy0));
    float b = randOcean(hashOcean(ix1 + seed) ^ hashOcean(iy0));
    float c = randOcean(hashOcean(ix0 + seed) ^ hashOcean(iy1));
    float d = randOcean(hashOcean(ix1 + seed) ^ hashOcean(iy1));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 2.0 - 1.0;
}

// fBm bathymétrique périodique. La période double avec la fréquence de chaque
// octave afin que toutes les octaves se referment exactement à la même
// longitude. Le champ reste déterministe et conserve la fréquence historique
// de 15 cellules sur la circonférence à l'octave de base.
float oceanFbmPeriodic(vec2 p, int octaves, uint seed, int period_x) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float total = 0.0;
    int octave_period_x = max(period_x, 1);

    for (int i = 0; i < octaves; i++) {
        value += amplitude * oceanNoise2DPeriodic(
            p * frequency,
            seed + uint(i) * 1000u,
            octave_period_x
        );
        total += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
        octave_period_x *= 2;
    }

    return value / total;
}

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
    float safe_spreading_rate = max(params.spreading_rate, 0.001);
    float safe_max_age = max(params.max_age, 0.0);
    float safe_subsidence_coeff = max(params.subsidence_coeff, 0.0);
    float age_ma = (2.0 * dist_km) / safe_spreading_rate;
    
    // Plafonner l'âge (la croûte océanique ne dépasse pas ~200 Ma avant subduction)
    age_ma = min(age_ma, safe_max_age);
    
    // === CALCUL DE LA SUBSIDENCE THERMIQUE ===
    
    // Le paramètre utilisateur représente la subsidence à 100 Ma. L'ancienne
    // implémentation ignorait complètement ce paramètre et imposait 365*sqrt(t).
    
    float subsidence = 0.0;
    if (age_ma > 0.0) {
        subsidence = safe_subsidence_coeff * sqrt(age_ma / 100.0);

        // Utiliser le même modèle paramétré pour le plafond, au lieu d'une
        // seconde constante indépendante de l'interface.
        float max_subsidence = safe_subsidence_coeff * sqrt(safe_max_age / 100.0);
        subsidence = min(subsidence, max_subsidence);
    }
    
    // Charger la croûte locale avant d'écrire le résultat. Les cellules
    // émergées restent explicitement continentales dans la carte d'âge.
    vec4 geo = imageLoad(geo_texture, pixel);
    float height = geo.r;

    if (height >= params.sea_level) {
        imageStore(crust_age_texture, pixel, vec4(-1.0, -1.0, 0.0, 0.0));
        return;
    }

    // === ÉCRITURE DU RÉSULTAT OCÉANIQUE ===
    vec4 result = vec4(
        dist_km,         // R: distance en km
        age_ma,          // G: âge en Ma
        subsidence,      // B: subsidence en mètres
        1.0              // A: marqueur de validité
    );
    imageStore(crust_age_texture, pixel, result);

    // === APPLIQUER LA SUBSIDENCE À LA GEO_TEXTURE ===
    
    // La subsidence océanique ne doit jamais convertir une plaine continentale
    // basse en fond marin. Elle ne s'applique qu'aux cellules déjà immergées.
    if (height < params.sea_level && age_ma > 0.0 && age_ma <= params.max_age) {
        // La subsidence REMPLACE l'élévation de base pour les zones océaniques
        // Référence: dorsale à -2600m, puis subsidence ajoute de la profondeur
        float ridge_depth = params.sea_level - 2600.0;
        
        // === TRANSITION GRADUELLE PLATEAU CONTINENTAL ===
        // shelf_factor: 0 = océan profond, 1 = terre émergée
        float shelf_factor = smoothstep(params.sea_level - 200.0, params.sea_level, height);
        
        // Calcul de la profondeur totale selon le modèle de refroidissement.
        float ocean_depth = ridge_depth - subsidence;

        // Mélanger avec la hauteur existante pour lisser la transition. La
        // confiance dans l'âge croît progressivement loin de la dorsale.
        float age_factor = smoothstep(0.0, 50.0, age_ma);
        float blend_factor = age_factor * 0.62 * (1.0 - shelf_factor * 0.75);
        height = mix(height, ocean_depth, blend_factor);

        // Conserver un plateau continental peu profond près du niveau marin.
        if (height > params.sea_level - 250.0 && height < params.sea_level - 20.0) {
            float shelf_target = params.sea_level - 100.0;
            float coastal_blend = smoothstep(params.sea_level - 250.0, params.sea_level - 80.0, height);
            height = mix(height, shelf_target, coastal_blend * 0.4);
        }

        // Relief bathymétrique uniquement sur le plancher océanique profond.
        if (height < params.sea_level - 500.0) {
            vec2 ocean_uv = vec2(float(pixel.x) / float(params.width),
                                 float(pixel.y) / float(params.height));
            // 15.0 est un nombre entier de cellules longitudinales. La même
            // valeur définit donc aussi la période exacte du bruit sur X.
            float ocean_relief = oceanFbmPeriodic(ocean_uv * 15.0, 4, 12345u, 15);
            height += ocean_relief * 300.0;

            // Le canal A est maintenant un signal divergent localisé.
            float boundary_signal = imageLoad(plates_texture, pixel).a;
            if (boundary_signal < -0.3) {
                height += 220.0 * clamp((-boundary_signal - 0.3) / 0.7, 0.0, 1.0);
            }
        }
        
        // Mettre à jour la colonne d'eau
        if (height < params.sea_level) {
            geo.a = params.sea_level - height;
        }
        
        geo.r = height;
        imageStore(geo_texture, pixel, geo);
    }
}
