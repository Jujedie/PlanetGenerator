# Étape 0 - Implémentation : Génération Topographique de Base

## Vue d'ensemble

Cette étape génère la **heightmap de base** de la planète en utilisant un compute shader GPU.
Elle remplace conceptuellement `ElevationMapGenerator.gd` (legacy CPU).

## Fichiers créés/modifiés

### Nouveau fichier
- [shader/compute/topographie/base_elevation.glsl](../shader/compute/topographie/base_elevation.glsl) - Shader compute principal

### Fichiers modifiés
- [src/classes/classes_gpu/gpu_context.gd](../src/classes/classes_gpu/gpu_context.gd) - Ajout des IDs de textures
- [src/classes/classes_gpu/orchestrator.gd](../src/classes/classes_gpu/orchestrator.gd) - Phase de simulation topographique
- [src/classes/classes_io/exporter.gd](../src/classes/classes_io/exporter.gd) - Export avec palettes de couleurs

## Architecture

### GeoTexture (RGBA32F)
La texture principale contient 4 canaux :
- **R** : `height` - Élévation en mètres (float brut)
- **G** : `bedrock` - Résistance de la roche (0-1)
- **B** : `sediment` - Épaisseur de sédiments (0 au départ)
- **A** : `water_height` - Colonne d'eau si sous le niveau de la mer

### Paramètres d'entrée (UBO)
```glsl
layout(set = 1, binding = 0, std140) uniform GenerationParams {
    uint seed;                // Graine de génération
    uint width;               // Largeur texture
    uint height;              // Hauteur texture
    float elevation_modifier; // Multiplicateur altitude (terrain_scale)
    float sea_level;          // Niveau de la mer
    float padding1-3;         // Alignement std140
} params;
```

## Algorithme de génération

### 1. Coordonnées cylindriques (Seamless X)
Les coordonnées pixel sont converties en coordonnées 3D cylindriques pour garantir la continuité sur l'axe X (longitude) :
```glsl
vec3 getCylindricalCoords(ivec2 pixel, uint w, uint h) {
    float u = float(pixel.x) / float(w);  // longitude [0, 1]
    float v = float(pixel.y) / float(h);  // latitude [0, 1]
    float theta = u * 2.0 * PI;
    return vec3(cos(theta), sin(theta), v);
}
```

### 2. Relief principal (fBm)
Deux bruits fBm combinés pour le relief de base :
- 8 octaves, gain 0.75, lacunarité 2.0
- Résultat : élévation entre -3500m et +3500m (+ modifier)

### 3. Structures tectoniques
- **Chaînes de montagnes** : Bande autour de 0.5 d'un bruit simplex absolu → +2500m
- **Canyons/Rifts** : Même principe → -1500m

### 4. Détails additionnels
- Si élévation > 800m : ajout de détails montagneux (+5000m max)
- Si élévation < -800m : ajout de fosses (-5000m max)

### 5. Initialisation des autres canaux
- `bedrock` : basé sur l'altitude + bruit
- `sediment` : 0 (rempli par l'érosion dans l'étape suivante)
- `water_height` : max(0, sea_level - height)

## Export des cartes

L'exportateur génère 3 fichiers PNG :

1. **topographie_map.png** : Carte d'élévation avec palette colorée (`COULEURS_ELEVATIONS`)
2. **topographie_map_grey.png** : Carte d'élévation avec palette en niveaux de gris (`COULEURS_ELEVATIONS_GREY`)
3. **water_mask.png** : Masque des zones sous-marines

Ces fichiers sont le résultat final de l'étape 0 (topographie de base) avant l'érosion hydraulique.

## Utilisation

```gdscript
# Dans PlanetGenerator ou test
var gpu_context = GPUContext.new(Vector2i(2048, 1024))
var orchestrator = GPUOrchestrator.new(gpu_context, Vector2i(2048, 1024), params)

# Exécuter la simulation (appelle automatiquement run_base_elevation_phase)
orchestrator.run_simulation()

# Exporter les cartes
var exported = orchestrator.export_all_maps("user://output/")
```

## Prochaine étape

**Étape 1 : Érosion Hydraulique** (voir `compute_pipeline_step_02_erosion_hydrologie.md`)
- Simulation de pluie et flux d'eau
- Transport de sédiments
- Création des rivières et lacs
- Mise à jour des canaux `sediment` et `water_height`
