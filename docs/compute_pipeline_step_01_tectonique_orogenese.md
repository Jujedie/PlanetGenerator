# Pipeline Compute — Étape 1 : Tectonique & Orogenèse (base heightmap + water init)

Cette étape remplace conceptuellement `ElevationMapGenerator.gd` et prépare les données pour l’érosion/hydrologie.

## Objectif
- Générer une **heightmap de base** cohérente (seamless X), plus réaliste que du simple bruit.
- Initialiser (ou préparer) des champs utiles aux étapes suivantes :
  - `bedrock` (résistance)
  - `sediment` (0 au départ)
  - `water height` (selon mer/océan initial)
  - éventuellement : `plate id`, `plate velocity`, `uplift`

## Référence legacy : invariants à conserver
Dans `ElevationMapGenerator.gd`, le relief est fait par :
- 2 bruits Perlin/fBm -> relief général
- un bruit additionnel appliqué uniquement si altitude > 800 ou < -800
- “tectonic ridges/canyons” : bande autour d’une valeur (0.5) d’un bruit simplex absolu

On ne recopie pas nécessairement les mêmes bruits, mais on conserve :
- relief multiscale
- structures linéaires (chaînes / canyons)
- seamless X (via coordonnées cylindriques / wrap)

## Contrainte projection : équirectangulaire
La map est une texture **2:1** (équirectangulaire) : `W x H` avec `H = W/2`.
- X = longitude (wrap)
- Y = latitude (pas de wrap)

Toute génération de bruit / distances / Voronoi doit donc :
- wrapper X (`(x+W)%W`)
- utiliser une distance cyclique sur X (`min(dx, W-dx)`)

## Sorties VRAM
Écrire dans `GeoTexture` (RGBA32F) :
- `R = height`
- `G = bedrock`
- `B = sediment`
- `A = water height`

Option : écrire aussi dans `PlateTexture` (RGBA32F) :
- `R = plate_id (float)`
- `G,B = velocity (vx, vy)`
- `A = plate_age`

## Données d’entrée
- `seed`
- `nb_plaques`
- `sea_level` (ou `water_elevation`)
- paramètres relief (amplitudes, fréquences)
- type de planète (ex `atmosphere_type`) :
  - sans atmosphère -> on peut préparer une heightmap plus “cratérisée” plus tard

## Stratégie GPU conseillée (réaliste + stable)
### A) Génération des plaques (Voronoi)
1. Générer N seeds de plaques (positions + vitesse) dans un buffer (SSBO) ou dans `PlateTexture`.
2. Pour chaque pixel, trouver la plaque la plus proche via distance cyclique X :
   - `dx = abs(x - seed.x); dx = min(dx, width - dx)`
3. Stocker `plate_id` et distance au bord.

#### Anti-lignes droites (important)
Un Voronoi “pur” produit des frontières trop géométriques (segments quasi rectilignes) et donne un aspect artificiel.

Recommandation : **Voronoi déformé (domain-warped Voronoi)**.
- Avant de calculer la distance aux seeds, déformer l’espace :
  - `p' = p + warp_amp * vec2(fbm(p*k1), fbm(p*k2))`
- Utiliser `p'` pour la distance aux seeds et/ou pour le calcul de `borderDist`.

Effet : frontières courbes, plus “géologiques”, et résultats uniques sans “lignes de règle”.

> Si N est petit (ex 32–128), un brute-force par pixel est acceptable.

### B) Orogenèse (relief aux frontières)
- Calculer un “uplift” basé sur :
  - proximité d’une frontière (différence de plate_id avec voisins)
  - collision (dot product des vitesses vers la frontière)
- Ajouter uplift à `height` et augmenter `bedrock`.

#### Anti-lignes droites (important)
Même avec Voronoi déformé, l’uplift peut encore dessiner des bandes trop régulières.
Ajouter une modulation **anisotrope** par bruit :
- `uplift *= (0.7 + 0.3 * ridged_fbm(p' * k))`
- Option : “failles” via une bande autour de 0.5 (comme legacy) mais après warping :
  - `fault = 1 - smoothstep(0, w, abs(noise(p') - 0.5))`
  - `uplift += fault * fault_amp`

### C) Bruit multi-échelle (détails)
- Ajouter un fBm simple (simplex/perlin) pour détails.
- Option : simuler les “bandes tectoniques” de legacy :
  - si `abs(noise - 0.5) < band_width` -> +montagnes ou -canyons

#### Recommandation bruit “réaliste”
Pour éviter un rendu “Perlin classique”, utiliser une combinaison :
- `ridged multifractal` pour les crêtes (montagnes)
- `fbm` doux pour variations continentales
- `domain warp` léger pour casser les répétitions

### D) Initialisation mer/eau
- Si `height <= sea_level` : `water_height = sea_level - height` (ou 1.0)
- Sinon `water_height = 0`

## Conventions GLSL (exemple)
### Workgroup
- `layout(local_size_x = 16, local_size_y = 16, local_size_z = 1)`

### Bindings
- `binding 0` : `layout(rgba32f) uniform image2D geo;`
- `binding 3` : `layout(rgba32f) uniform image2D plates;` (option)
- `binding UBO` : paramètres

## Pseudocode shader (niveau algorithmique)
1. `ivec2 p = ivec2(gl_GlobalInvocationID.xy);`
2. if out of bounds -> return
3. coords = (x, y) en espace cylindrique / normalisé
4. p' = domain_warp(p)
5. id, borderDist = voronoi(p')
5. height = baseNoise(coords)
6. uplift = boundaryUplift(id, borderDist, neighbor_ids)
7. height += uplift
8. bedrock = clamp( baseRock + uplift*k , 0..1)
9. sediment = 0
10. water = max(0, sea_level - height)
11. imageStore(geo, p, vec4(height, bedrock, sediment, water))

## Seamless X : rappel
Toute distance/voisinage doit “wrap” sur X :
- sampling voisin : `nx = (x + dx + width) % width`
- distance : `min(abs(dx), width - abs(dx))`

## Validation
- Exporter temporairement `height` en PNG via `exporter.gd` (readback unique) pour vérifier :
  - continuité X
  - relief plausible
  - mer cohérente avec `sea_level`

---

Prochaine étape : **Étape 2 (Érosion/Hydrologie)**.
