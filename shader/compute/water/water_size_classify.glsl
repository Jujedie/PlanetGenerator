#[compute]
#version 450

// ============================================================================
// WATER SIZE CLASSIFY SHADER - Classification eau salée/douce par taille
// ============================================================================
// Après JFA, tous les pixels d'une même composante partagent le même seed.
// Ce shader :
// 1. Compte atomiquement le nombre de pixels par seed
// 2. Reclassifie : taille >= saltwater_min_size → eau salée, sinon eau douce
//
// Note: Ce shader est exécuté en 2 passes :
// - Passe 1 (pass_type=0) : Comptage des pixels par composante
// - Passe 2 (pass_type=1) : Classification basée sur les comptages
//
// Entrées :
// - water_component (RG32I) : Seeds finaux après JFA
// - water_mask (R8UI) : Masque d'eau initial
// - counter_buffer (SSBO) : Buffer de comptage atomique
//
// Sorties :
// - water_mask (R8UI) : 0=terre, 1=eau salée, 2=eau douce
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Composantes JFA (lecture seule après JFA)
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D water_component;

// Masque d'eau (lecture/écriture)
layout(set = 0, binding = 1, r8ui) uniform uimage2D water_mask;

// GeoTexture pour vérifier altitude (lacs d'altitude toujours eau douce)
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D geo_texture;

// SSBO pour comptage atomique des pixels par composante
// Indexé par: seed.y * width + seed.x
layout(set = 0, binding = 3, std430) buffer CounterBuffer {
    uint pixel_counts[];
} counters;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform ClassifyParams {
    uint width;              // Largeur texture
    uint height;             // Hauteur texture
    uint pass_type;          // 0=comptage, 1=classification
    uint saltwater_min_size; // Taille minimale pour eau salée (défaut: 150)
    float sea_level;         // Niveau de la mer (pour détecter lacs altitude)
    float padding1;
    float padding2;
    float padding3;
} params;

// ============================================================================
// CONSTANTES
// ============================================================================

const uint WATER_NONE = 0u;
const uint WATER_SALTWATER = 1u;
const uint WATER_FRESHWATER = 2u;

// ============================================================================
// MAIN
// ============================================================================

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    int w = int(params.width);
    int h = int(params.height);
    
    // Vérification des limites
    if (pixel.x >= w || pixel.y >= h) {
        return;
    }
    
    // Lire le masque actuel
    uint current_mask = imageLoad(water_mask, pixel).r;
    
    // Si ce n'est pas de l'eau, rien à faire
    if (current_mask == WATER_NONE) {
        return;
    }
    
    // Lire le seed de la composante
    ivec2 seed = imageLoad(water_component, pixel).xy;
    
    // Seed invalide = pas d'eau
    if (seed.x < 0 || seed.y < 0) {
        imageStore(water_mask, pixel, uvec4(WATER_NONE, 0u, 0u, 0u));
        return;
    }
    
    // Index dans le buffer de comptage
    uint seed_index = uint(seed.y * w + seed.x);
    
    // === PASSE 1 : COMPTAGE ===
    if (params.pass_type == 0u) {
        // Incrémenter le compteur pour cette composante
        atomicAdd(counters.pixel_counts[seed_index], 1u);
    }
    // === PASSE 2 : CLASSIFICATION ===
    else {
        // Lire le nombre de pixels dans cette composante
        uint component_size = counters.pixel_counts[seed_index];
        
        // Lire l'altitude pour détecter les lacs en altitude
        vec4 geo = imageLoad(geo_texture, pixel);
        float height = geo.r;
        
        // Règles de classification :
        // 1. Lacs en altitude (au-dessus du niveau mer) = TOUJOURS eau douce
        // 2. Taille >= saltwater_min_size = eau salée
        // 3. Sinon = eau douce
        
        uint final_type;
        
        if (height >= params.sea_level) {
            // Lac en altitude = toujours eau douce
            final_type = WATER_FRESHWATER;
        }
        else if (component_size >= params.saltwater_min_size) {
            // Grande masse d'eau sous niveau mer = eau salée
            final_type = WATER_SALTWATER;
        }
        else {
            // Petite masse d'eau = eau douce
            final_type = WATER_FRESHWATER;
        }
        
        // Écrire le type final
        imageStore(water_mask, pixel, uvec4(final_type, 0u, 0u, 0u));
    }
}
