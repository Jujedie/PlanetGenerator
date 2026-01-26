# Pipeline Compute — Étape 3 : Atmosphère & Climat (température, humidité, vents, nuages, banquises)

Cette étape remplace conceptuellement :
- `TemperatureMapGenerator.gd`
- `PrecipitationMapGenerator.gd`
- `NuageMapGenerator.gd`
- `BanquiseMapGenerator.gd`

## Objectif
Produire un état climatique cohérent, dépendant de :
- latitude
- altitude (height)
- présence d’eau
- circulation simplifiée (vents)

## Contrainte projection : équirectangulaire
La latitude doit être calculée depuis Y sur une texture `W x H` avec `H = W/2` :
- `v = y/(H-1)`
- `lat = v*π - π/2`

Rappel : X est cyclique (seamless), Y ne l’est pas.

## Référence legacy : ce qu’on doit retrouver
### Température (`TemperatureMapGenerator.gd`)
- Base latitudinale : plus chaud à l’équateur, froid aux pôles.
- Correction altitude : ~ -6.5°C/km au-dessus de la mer.
- Océan amortit : `temp = 0.8*temp + 0.2*avg_temperature`.

### Précipitations (`PrecipitationMapGenerator.gd`)
- Combinaison de bruits + légère influence latitude.

### Nuages (`NuageMapGenerator.gd`)
- Pas de nuages si `atmosphere_type == 2` (volcanique) ou `== 3` (sans atmosphère).
- Formes cellulaires + shape noise + détail.

### Banquises (`BanquiseMapGenerator.gd`)
- Glace uniquement sur l’eau.
- Si `temp < 0` -> forte probabilité de glace.

## Sorties VRAM
Écrire dans `ClimateTexture` :
- `R = temperature`
- `G = humidity` (ou precipitation)
- `B = wind_x`
- `A = wind_y`

Option :
- `IceMaskTexture` (R8/R16F) ou simplement une valeur dérivée dans un canal (ex ClimateTexture alpha si vent stocké ailleurs).
- `CloudMaskTexture` (R8) si nécessaire.

## Données d’entrée
- `GeoTexture` (height + water)
- `avg_temperature`, `avg_precipitation`
- `atmosphere_type`
- seed

## Sous-passes recommandées
### Pass 3.1 — Champs de vent (simplifié)
Objectif : avoir un champ `(wind_x, wind_y)` stable, même approximatif.
- Dépendre de latitude : cellules de Hadley simplifiées.
- Ex :
  - lat proche équateur -> vents d’est/ouest
  - lat moyenne -> sens inversé

On peut ajouter un bruit faible pour variabilité.

### Pass 3.2 — Température
Pour chaque pixel :
1) `lat_norm = abs(y/(H-1) - 0.5) * 2`
2) `base_temp = avg_temp + equator_offset*(1-lat_norm) - pole_offset*pow(lat_norm, 1.5)`
3) `altitude_temp` selon legacy :
   - si land : `-6.5 * max(0, height-sea)/1000`
   - si sous mer : légère hausse (legacy : +2°C/km)
4) atténuation eau

### Pass 3.3 — Humidité / précipitations
Version MVP : reproduire legacy (bruits + latitude) en GPU.
Version “simulation” (plus tard) : advection d’humidité le long du champ de vent + condensation sur relief.

Recommandation pragmatique :
- Démarrer avec legacy-like : `humidity = f(noise_main, noise_detail, noise_cells, latitude)`.
- Ensuite, améliorer en “orographic precipitation” :
  - augmenter précip sur pentes au vent
  - diminuer sous le vent (rain shadow)

### Pass 3.4 — Nuages (si atmosphère)
Sortie : `cloud_mask` (0/1).
- Reprendre exactement la logique de `NuageMapGenerator.gd` :
  - cell noise -> formes rondes
  - shape noise -> masse
  - detail -> bords

### Pass 3.5 — Banquises
- `ice = (water>0 && temp<0) ? prob : 0`
En GPU : éviter le vrai random par pixel ; utiliser un bruit déterministe (hash) :
- `rand = hash(x,y,seed)`
- `ice = (rand < 0.9) ? 1 : 0`

## Bindings GLSL (exemple)
- `binding 0` : GeoTexture (readonly)
- `binding 1` : ClimateTexture (writeonly)
- `binding 2` : CloudMask (writeonly) (option)
- `binding 3` : IceMask (writeonly) (option)

## Skips selon type de planète
- `atmosphere_type == 3` :
  - température peut exister (radiation) mais legacy utilise surtout “pas d’eau/nuages”.
  - nuages = 0 ; humidité = 0 ; banquise = 0.
- `atmosphere_type == 2` (volcanique) :
  - nuages = 0 dans legacy (à conserver).

## Validation
- Export debug : temp/humidity.
- Vérifier gradient latitude.
- Vérifier refroidissement altitude.

---

Prochaine étape : **Étape 4 (Biomes & Régions)**.
