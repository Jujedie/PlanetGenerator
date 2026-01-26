# Pipeline Compute — Étape 6 : Cratering (impacts) — planètes sans atmosphère

Cette étape couvre le point explicitement mentionné dans le manifeste : **simuler des cratères d’impact** sur les planètes sans atmosphère.

## Objectif
- Ajouter des cratères réalistes à la heightmap (et éventuellement à la rugosité/bedrock).
- Produire un rendu “régolithe criblé de cratères” cohérent avec les biomes “sans atmosphère” dans `Enum`.
- Tout se fait **en VRAM** : on modifie `GeoTexture` directement.

## Quand l’exécuter
- Si `atmosphere_type == 3` (sans atmosphère) : exécuter **avant** biomes/régions.
- Si planète avec atmosphère : généralement non (ou très faible densité).

## Contrainte projection : équirectangulaire
Les cratères sont placés sur une texture `W x H` avec `H = W/2`.
- X wrap (longitude) : la distance doit être cyclique
- Y clamp (latitude)

## Sorties VRAM
Modifier `GeoTexture` :
- `R height` : dépression circulaire + rebord
- `G bedrock` : peut augmenter sur rebords (roche exposée)
- `B sediment` : peut être modifié (éjectas)

Option :
- `CraterMaskTexture` (R8) si on veut un contrôle artistique en rendu.

## Données d’entrée
- `GeoTexture` (height)
- `seed`
- paramètres : densité cratères, distribution tailles, profondeur, rebord

## Génération de cratères : stratégie GPU
Le point difficile est que “poser K cratères” implique des opérations globales. Approche recommandée :

### 6.1 Générer une liste de cratères (SSBO)
1) Sur CPU (orchestrateur) : générer une liste déterministe de `K` cratères à partir de la seed :
   - centre (x,y)
   - rayon R
   - profondeur D
   - hauteur rebord H
2) Uploader cette liste dans un SSBO `CraterBuffer`.

> C’est autorisé car on ne lit pas la texture : on écrit seulement des paramètres.

### 6.2 Appliquer les cratères (compute)
Pour chaque pixel, on accumule l’effet de quelques cratères voisins.

Approche brute force (simple) :
- Pour chaque pixel, itérer sur tous les cratères (O(W*H*K)) — trop coûteux si K grand.

Approche pratique (recommandée) : binning spatial
1) Construire une grille de bins (ex 64x32) : chaque bin contient les indices de cratères proches.
2) Un pixel ne teste que les cratères de son bin + bins voisins.

Forme de cratère (profil)
- `d = distance(p, center)` avec wrap X
- Si `d < R` :
  - bowl : `delta = -D * smoothstep(1, 0, d/R)`
  - rim : ajouter une gaussienne près de `d ~ R`
- Ajouter un champ d’éjectas :
  - `ejecta = E * exp(-k*(d/R - 1))` pour `d > R`

## Seamless X
La distance centre-pixel doit être cyclique sur X :
- `dx = abs(x - cx); dx = min(dx, width - dx)`

## Anti-lignes droites / rendu naturel
- Jitter léger du rayon/profondeur via un bruit déterministe (hash) par cratère.
- Variation azimutale : moduler la profondeur par un bruit en fonction de l’angle pour casser la symétrie parfaite.

## Validation
- Export debug de height pour vérifier :
  - cratères visibles
  - pas de couture sur X
  - amplitude plausible

---

Note : cette étape se combine bien avec les biomes “sans atmosphère” (régolithe / fosses d’impact) déjà présents dans `Enum`.
