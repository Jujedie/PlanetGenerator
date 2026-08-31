#[compute]
#version 450

// ============================================================================
// BIOME SMOOTH SHADER
// ============================================================================
// Supprime seulement les pixels réellement isolés. Les écotones organiques
// viennent du classifieur ; un vote majoritaire agressif les arrondirait.
//
// Technique : 
// 1. Vote conservateur dans un kernel 3x3
// 2. Préservation des transitions eau/terre
// 3. Préservation des frontières cohérentes, même irrégulières
// ============================================================================

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// === SET 0 : TEXTURES ===
layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D biome_id_in;        // ID biome en entrée
layout(set = 0, binding = 1, rgba8) uniform readonly image2D biome_colored_in;    // Couleur en entrée
layout(set = 0, binding = 2, r32ui) uniform writeonly uimage2D biome_id_out;      // ID biome en sortie
layout(set = 0, binding = 3, rgba8) uniform writeonly image2D biome_colored_out;  // Couleur en sortie
layout(set = 0, binding = 4, r8ui) uniform readonly uimage2D water_mask;          // Pour préserver transitions eau/terre

// === SET 1 : PARAMÈTRES ===
layout(set = 1, binding = 0, std140) uniform SmoothParams {
    uint width;
    uint height;
    uint pass_index;         // 0 ou 1 pour ping-pong
    uint seed;
    float border_noise;      // Force du bruit aux bordures (0-1)
    float padding1;
    float padding2;
    float padding3;
};

// === SET 2 : SSBO BIOMES DATA (pour récupérer les couleurs) ===
struct BiomeData {
    vec4 color;
    float temp_min;
    float temp_max;
    float humid_min;
    float humid_max;
    float elev_min;
    float elev_max;
    uint water_need;
    uint planet_type_mask;
};

layout(set = 2, binding = 0, std430) readonly buffer BiomeLUT {
    uint biome_count;
    uint padding_a;
    uint padding_b;
    uint padding_c;
    BiomeData biomes[];
};

// === BRUIT SIMPLEX ===
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x*34.0)+1.0)*x); }

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Wrap horizontal pour coordonnées cylindriques
ivec2 wrap_coords(ivec2 pos) {
    // Wrap horizontal (longitude)
    if (pos.x < 0) pos.x += int(width);
    if (pos.x >= int(width)) pos.x -= int(width);
    
    // Clamp vertical (latitude)
    pos.y = clamp(pos.y, 0, int(height) - 1);
    
    return pos;
}

// === MAIN ===
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    
    // Vérification des limites
    if (pixel.x >= int(width) || pixel.y >= int(height)) {
        return;
    }
    
    // Lire le type d'eau au pixel central
    uint center_water = imageLoad(water_mask, pixel).r;
    uint center_biome = imageLoad(biome_id_in, pixel).r;
    vec4 center_color = imageLoad(biome_colored_in, pixel);
    
    // Comptage des votes pour chaque biome voisin
    // On utilise un tableau de comptage simple (max 256 biomes)
    uint vote_counts[16];  // Limité à 16 biomes les plus proches
    uint vote_biomes[16];
    vec4 vote_colors[16];
    uint num_unique = 0u;
    
    // Parcourir le voisinage 3x3
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 neighbor_pos = wrap_coords(pixel + ivec2(dx, dy));
            
            uint neighbor_water = imageLoad(water_mask, neighbor_pos).r;
            
            // Préserver les transitions eau/terre : ignorer les voisins de type d'eau différent
            // Sauf si les deux sont de l'eau (salée/douce peuvent se mélanger)
            bool center_is_water = (center_water > 0u);
            bool neighbor_is_water = (neighbor_water > 0u);
            
            if (center_is_water != neighbor_is_water) {
                continue;  // Ignorer ce voisin
            }
            
            uint neighbor_biome = imageLoad(biome_id_in, neighbor_pos).r;
            vec4 neighbor_color = imageLoad(biome_colored_in, neighbor_pos);
            
            // Chercher si ce biome est déjà dans notre liste
            bool found = false;
            for (uint i = 0u; i < num_unique; i++) {
                if (vote_biomes[i] == neighbor_biome) {
                    vote_counts[i]++;
                    found = true;
                    break;
                }
            }
            
            // Sinon, ajouter comme nouveau biome
            if (!found && num_unique < 16u) {
                vote_biomes[num_unique] = neighbor_biome;
                vote_colors[num_unique] = neighbor_color;
                vote_counts[num_unique] = 1u;
                num_unique++;
            }
        }
    }
    
    // Trouver le biome avec le plus de votes et mesurer le soutien local du
    // biome central. Une frontière 5/4 est valide : seuls les îlots 1-2 pixels
    // entourés par une super-majorité doivent disparaître.
    uint best_biome = center_biome;
    vec4 best_color = center_color;
    uint max_votes = 0u;
    uint center_votes = 0u;
    
    for (uint i = 0u; i < num_unique; i++) {
        if (vote_counts[i] > max_votes) {
            max_votes = vote_counts[i];
            best_biome = vote_biomes[i];
            best_color = vote_colors[i];
        }
        if (vote_biomes[i] == center_biome) {
            center_votes = vote_counts[i];
        }
    }

    uint required_majority = pass_index == 0u ? 6u : 7u;
    uint maximum_center_support = pass_index == 0u ? 2u : 1u;
    if (
        best_biome != center_biome
        && (max_votes < required_majority || center_votes > maximum_center_support)
    ) {
        best_biome = center_biome;
        best_color = center_color;
    } else if (best_biome == center_biome) {
        // Conserver la couleur exacte du centre au lieu de celle d'un voisin.
        best_color = center_color;
    }
    
    // Écrire les résultats
    imageStore(biome_id_out, pixel, uvec4(best_biome, 0u, 0u, 0u));
    imageStore(biome_colored_out, pixel, best_color);
}
