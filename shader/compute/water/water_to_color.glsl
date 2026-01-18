#[compute]
#version 450

// ============================================================================
// WATER TO COLOR SHADER - Classification visuelle eau salée/douce
// ============================================================================
// Ce shader colore les masses d'eau en fonction de leur taille :
// - Toute l'eau est d'abord colorée en bleu océan (eau salée)
// - Ensuite, les petites zones (< freshwater_max_size) sont recolorées en bleu lac
//
// Utilise un système de flood-fill GPU via JFA déjà effectué :
// - water_component contient le seed de chaque composante connexe
// - On compte les pixels par composante et on reclassifie
//
// Entrées :
// - water_mask (R8UI) : 0=terre, 1=eau potentielle
// - water_component (RG32I) : Seeds JFA pour composantes connexes
// - geo_texture (RGBA32F) : Pour vérifier altitude (lacs d'altitude)
// - counter_buffer (SSBO) : Comptage par composante
//
// Sorties :
// - water_colored (RGBA8) : Couleur visuelle des eaux
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === BINDINGS ===

// Composantes JFA (lecture seule après JFA)
layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D water_component;

// Masque d'eau (lecture seule - 0=terre, 1=eau)
layout(set = 0, binding = 1, r8ui) uniform readonly uimage2D water_mask;

// GeoTexture pour vérifier altitude (lacs d'altitude toujours eau douce)
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D geo_texture;

// Sortie : carte colorée des eaux
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D water_colored;

// SSBO pour comptage atomique des pixels par composante
// Indexé par: seed.y * width + seed.x
layout(set = 0, binding = 4, std430) buffer CounterBuffer {
    uint pixel_counts[];
} counters;

// Uniform Buffer : Paramètres
layout(set = 1, binding = 0, std140) uniform WaterColorParams {
    uint width;                  // Largeur texture
    uint height;                 // Hauteur texture
    uint pass_type;              // 0=comptage, 1=coloration
    uint freshwater_max_size;    // Taille maximale pour eau douce (défaut: 500)
    float sea_level;             // Niveau de la mer
    uint atmosphere_type;        // Type d'atmosphère (0=default, 1=toxic, 2=volcanic, 3=no_atmo, 4=dead)
    float padding1;
    float padding2;
} params;

// ============================================================================
// COULEURS D'EAU (correspondant à enum.gd)
// ============================================================================

// Default type (0)
const vec4 COL_OCEAN = vec4(0.145, 0.322, 0.541, 1.0);         // 0x25528a - Eau salée
const vec4 COL_LAC = vec4(0.271, 0.518, 0.824, 1.0);           // 0x4584d2 - Eau douce

// Toxic type (1)
const vec4 COL_OCEAN_TOXIC = vec4(0.196, 0.608, 0.514, 1.0);   // 0x329b83
const vec4 COL_LAC_TOXIC = vec4(0.282, 0.839, 0.231, 1.0);     // 0x48d63b

// Volcanic type (2)
const vec4 COL_LAVE = vec4(0.839, 0.588, 0.090, 1.0);          // 0xd69617
const vec4 COL_MAGMA = vec4(0.718, 0.286, 0.055, 1.0);         // 0xb7490e

// Dead type (4)
const vec4 COL_OCEAN_MORT = vec4(0.286, 0.475, 0.290, 1.0);    // 0x49794a
const vec4 COL_LAC_MORT = vec4(0.380, 0.624, 0.388, 1.0);      // 0x619f63

// Transparent (pas d'eau)
const vec4 COL_TRANSPARENT = vec4(0.0, 0.0, 0.0, 0.0);

// ============================================================================
// FONCTIONS UTILITAIRES
// ============================================================================

vec4 getSaltwaterColor(uint atmo) {
    if (atmo == 0u) return COL_OCEAN;
    if (atmo == 1u) return COL_OCEAN_TOXIC;
    if (atmo == 2u) return COL_LAVE;
    if (atmo == 4u) return COL_OCEAN_MORT;
    return COL_OCEAN;
}

vec4 getFreshwaterColor(uint atmo) {
    if (atmo == 0u) return COL_LAC;
    if (atmo == 1u) return COL_LAC_TOXIC;
    if (atmo == 2u) return COL_MAGMA;
    if (atmo == 4u) return COL_LAC_MORT;
    return COL_LAC;
}

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
    
    // Lire le masque d'eau
    uint water_type = imageLoad(water_mask, pixel).r;
    
    // Si ce n'est pas de l'eau, pixel transparent
    if (water_type == 0u) {
        if (params.pass_type == 1u) {
            imageStore(water_colored, pixel, COL_TRANSPARENT);
        }
        return;
    }
    
    // Lire le seed de la composante
    ivec2 seed = imageLoad(water_component, pixel).xy;
    
    // Seed invalide = pas d'eau (ne devrait pas arriver)
    if (seed.x < 0 || seed.y < 0) {
        if (params.pass_type == 1u) {
            imageStore(water_colored, pixel, COL_TRANSPARENT);
        }
        return;
    }
    
    // Index dans le buffer de comptage
    uint seed_index = uint(seed.y * w + seed.x);
    
    // === PASSE 1 : COMPTAGE ===
    if (params.pass_type == 0u) {
        // Incrémenter le compteur pour cette composante
        atomicAdd(counters.pixel_counts[seed_index], 1u);
    }
    // === PASSE 2 : COLORATION ===
    else {
        // Lire le nombre de pixels dans cette composante
        uint component_size = counters.pixel_counts[seed_index];
        
        // Lire l'altitude pour détecter les lacs en altitude
        vec4 geo = imageLoad(geo_texture, pixel);
        float height_val = geo.r;
        
        // Règles de classification :
        // 1. Lacs en altitude (au-dessus du niveau mer) = TOUJOURS eau douce
        // 2. Taille > freshwater_max_size = eau salée (océans/mers)
        // 3. Taille <= freshwater_max_size = eau douce (lacs)
        
        vec4 final_color;
        
        if (height_val >= params.sea_level) {
            // Lac en altitude = TOUJOURS eau douce
            final_color = getFreshwaterColor(params.atmosphere_type);
        }
        else if (component_size > params.freshwater_max_size) {
            // Grande masse d'eau = océan/mer (eau salée)
            final_color = getSaltwaterColor(params.atmosphere_type);
        }
        else {
            // Petite masse d'eau = lac (eau douce)
            final_color = getFreshwaterColor(params.atmosphere_type);
        }
        
        imageStore(water_colored, pixel, final_color);
    }
}
