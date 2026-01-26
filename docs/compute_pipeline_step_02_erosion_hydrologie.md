# Pipeline Compute — Étape 2 : Érosion hydraulique & hydrologie (height finale + flux)

Cette étape remplace conceptuellement :
- l’érosion implicite que le legacy n’a pas vraiment (mais qu’il simule indirectement via rivières),
- et prépare des cartes nécessaires aux biomes (eau, rivières).

## Objectif
À partir de `GeoTexture` (height/bedrock/sediment/water) issu de l’étape 1 :
- Simuler un cycle hydrologique simplifié : pluie -> ruissellement -> transport sédiment -> dépôt.
- Produire :
  - `height` mise à jour (érosion)
  - `sediment` mis à jour
  - `water_height` mis à jour
  - une carte de flux (débit) pour détecter rivières/fleuves

## Référence legacy : invariants à conserver
Dans `RiverMapGenerator.gd`, même si l’algo est CPU/heuristique, les invariants utiles sont :
- Les sources apparaissent plutôt en altitude, non-océan, pas trop froid, avec précipitations.
- Les rivières suivent globalement le gradient descendant et finissent à l’océan, sinon lacs.

En GPU, on ne “trace” pas des chemins CPU ; on produit un **champ de flux** par accumulation de drainage.

## Sorties VRAM
- Mise à jour `GeoTexture` :
  - `R height` modifié
  - `B sediment` modifié
  - `A water_height` modifié
- `RiverFluxTexture` (R32F) : flux accumulé (0..+)
- Option : `WaterMask` dérivé (mais peut être déduit : `water_height > 0`)

## Contraintes de pipeline
- Cette étape est itérative (plusieurs passes). Pour éviter les hazards :
  - utiliser un **ping-pong** : lire GeoTexture A, écrire GeoTexture B, puis swap.
  - le slot `TEMP_BUFFER` de `GPUContext` peut servir.

## Contrainte projection : équirectangulaire
Le voisinage pour l’écoulement doit respecter la projection équirectangulaire :
- X wrap (longitude seamless)
- Y clamp (pôles)

En pratique :
- pour tout accès voisin : `nx = (x + dx + W) % W`, `ny = clamp(y + dy, 0, H-1)`
- pour toute distance longitudinale : `dx = min(abs(dx), W-abs(dx))`

## Décomposition en sous-passes (recommandé)
### Pass 2.1 — Pluie + évaporation (simple)
- Ajouter une quantité d’eau sur chaque pixel selon :
  - humidité/precip (si déjà calculée) ou un bruit “pluie” au début
  - ou un profil latitudinal
- Appliquer evaporation : `water *= (1 - evap_rate)`

### Pass 2.2 — Flux local (écoulement)
Calculer combien d’eau s’écoule vers les voisins (8-neighborhood) selon :
- `surface = height + water_height`
- répartir vers les voisins plus bas

Implémentation GPU typique :
- soit “push” (chaque cellule distribue) -> besoin d’atomiques
- soit “pull” (chaque cellule collecte) -> plus simple (mais attention conservation)

Recommandation :
- Faire un **pull** : pour un pixel P, regarder les voisins N ; si `surface(N) > surface(P)` alors une fraction coule de N vers P.

### Pass 2.3 — Transport sédiment
- Capacité de transport : fonction de la vitesse d’écoulement et de la pente.
- Si `sediment > capacity` -> dépôt
- Sinon -> érosion (enlever un peu de height, ajouter à sediment)

### Pass 2.4 — Accumulation de drainage (flux)
But : obtenir une “river flux map”. Deux options :
1) Approximation rapide (K passes) : diffusion/accumulation locale de l’eau.
2) Algorithme de drainage “steepest descent” : chaque pixel choisit un outflow neighbor, puis on accumule en aval via plusieurs passes (plus complexe).

Pour un premier MVP GPU stable :
- Utiliser une accumulation itérative :
  - initial flux = water_outflow
  - itérer quelques pas en “pull” (collecte depuis upstream)

## Bindings GLSL recommandés
- `binding 0` : GeoTexture input (readonly image)
- `binding 1` : GeoTexture output (writeonly image) ou TempBuffer
- `binding 2` : RiverFluxTexture (rw)
- UBO : params érosion

## Paramètres UBO (exemples)
- `rain_rate`, `evap_rate`
- `flow_rate`
- `sediment_capacity_k`
- `erosion_rate`, `deposition_rate`
- `iterations`

## Planètes sans atmosphère / gazeuses
Le manifeste précise :
- pas d’érosion hydraulique si planète gazeuse / sans atmosphère.

Donc, dans l’orchestrateur :
- si `atmosphere_type == 3` (sans atmosphère) : **skipper** cette étape.
- si planète gazeuse : skipper (à définir par un flag “planet_type”).

## Validation
- Vérifier la conservation (grossière) : height ne doit pas exploser.
- Visualiser `water_height` et `river_flux` via export (readback unique) pour debug.

---

Prochaine étape : **Étape 3 (Atmosphere & Climate)**.
