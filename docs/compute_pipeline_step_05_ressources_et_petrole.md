# Pipeline Compute — Étape 5 : Ressources & couche géologique (incl. pétrole)

Cette étape remplace conceptuellement :
- `RessourceMapGenerator.gd`
- `OilMapGenerator.gd`

## Objectif
- Générer des couches “ressources” cohérentes (ou au moins compatibles) en lisant l’historique géologique.
- Produire une ou plusieurs textures d’IDs de ressources.

## Référence legacy : invariants
### Ressources (`RessourceMapGenerator.gd`)
- Choix aléatoire d’un type de ressource via `Enum.getRessourceByProbabilite()`.
- Croissance en “cluster” : marche aléatoire autour de cases déjà posées.
- Skip sur l’eau.

### Pétrole (`OilMapGenerator.gd`)
- Probabilité calculée via 3 bruits : basin, deposit(cellular), fault
- Modulation par altitude/eau (meilleur proche niveau mer et sous faible profondeur)
- Si pas d’atmosphère : la map devient (dans legacy) un masque trivial.

## Sorties VRAM
- `ResourceMapTexture` : ID ressource (uint/rgba8)
- `OilMaskTexture` : 0/1

## Données d’entrée
- GeoTexture : height, water, sediment
- ClimateTexture : optionnel
- RiverFluxTexture : optionnel
- Atmosphere type

## Portage GPU — Ressources (clusters)
Le pattern CPU “croissance” est difficile en GPU tel quel.

Approches GPU possibles (du plus simple au plus “simulation”) :

### A) Poisson / grid seeding + cellular growth (recommandé)
1) Pass seeds : pour chaque pixel, décider (hash) si c’est un “seed” de ressource (en fonction de probabilités globales).
2) Pass growth : itérer N fois :
   - un pixel vide adopte la ressource d’un voisin si (hash + règle) passe.
3) Masquer l’eau : si `water>0`, forcer 0.

Résultat : clusters “naturels” et contrôlables.

#### Anti-lignes rectilignes (important)
Pour éviter des frontières de gisements trop “géométriques”, injecter de la variabilité spatiale :
- Utiliser un **domain warp** pour déformer les coordonnées des bruits (`p' = p + warp(...)`).
- Utiliser des bruits adaptés :
   - `cellular` pour bassins / patches
   - `ridged` pour veines/minéralisations
   - (option) `curl noise` pour des structures filamenteuses (veines) sans lignes droites
- Utiliser un coût ou seuil dépendant du terrain :
   - sédiments élevés -> favorise certaines ressources
   - proximité rivières/flux -> favorise alluvions, etc.

### B) Distance field / Voronoi ressources
- Générer K centres de gisements.
- Propager via JFA pour obtenir la zone d’influence.

## Portage GPU — Pétrole
Celui-ci est **directement portable** (bruits + facteurs).

### Facteurs
- `basin_value` : bruit fBm simple
- `deposit_value` : bruit cellulaire
- `fault_bonus` : bande autour de 0.5 sur un bruit simplex abs (à faire sur coordonnées **déformées**)
- `elevation_factor` : dépend de (is_water, depth/altitude)

#### Anti-lignes rectilignes (faults)
Un “fault” basé sur un seul bruit peut générer des bandes trop régulières.
Recommandation :
- calculer `fault_bonus` avec un bruit en domain warp : `fault_noise(p')`
- moduler l’épaisseur de faille par un second bruit : `band_width = mix(w1, w2, noise2(p'))`

Puis :
- `oil_probability = basin*0.4 + deposit*0.3 + fault_bonus`
- `oil_probability *= elevation_factor`
- `oil_mask = oil_probability > threshold`

### Planètes sans atmosphère
Le legacy met une sortie “triviale”. À définir selon design :
- soit pas de pétrole
- soit masque constant (mais peu logique)

Recommandation :
- `atmosphere_type == 3` -> pas de pétrole (mask=0)

## Validation
- Vérifier l’absence de ressources sur l’eau.
- Vérifier corrélation pétrole avec bassins et zones proches niveau mer.

---

Complément recommandé : ajouter une étape “Cratering” pour les planètes sans atmosphère (cf manifeste). Voir un futur document si besoin.
