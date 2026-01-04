# Pipeline Compute — Étape 4 : Biomes & Régions (classification + postprocess)

Cette étape remplace conceptuellement :
- `BiomeMapGenerator.gd`
- `RegionMapGenerator.gd`

## Objectif
- Classifier chaque pixel en biome (et éventuellement en région) en lisant les sorties précédentes.
- Fournir une sortie **utile au gameplay/rendu** sans readback.

## Contrainte projection : équirectangulaire
Toutes les décisions (voisinage, distances, croissance, JFA si utilisé) doivent respecter :
- texture `W x H` avec `H = W/2`
- wrap X obligatoire (longitude seamless)
- clamp Y (pôles)

## Référence legacy : biomes
`BiomeMapGenerator.gd` fait :
1) première passe : choix biome à partir de (elevation, precipitation, temperature, water, banquise, river)
2) lissage (2 passes) : vote majoritaire voisinage, en protégeant rivières et banquises
3) irrégularité de bord : remplacement pseudo-aléatoire sur les frontières
4) application couleur finale : mélange `elevation_color * biome_vegetation_color`

En GPU, on sépare :
- **BiomeID** (donnée) -> stable
- **Colorisation** -> rendu/export, pas forcément pendant classification

## Sorties VRAM recommandées
### BiomeMapTexture
- soit `R32_UINT` (id)
- soit `RGBA8` (id packé) si formats uint compliqués

### RegionMapTexture
- même logique (id)

### Alternative rapide (compat legacy)
- écrire directement une couleur RGBA8 en sortie.

> Pour un moteur “systémique”, préférer les IDs et un LUT (table) pour couleur/params.

## Données d’entrée
- GeoTexture : height + water
- ClimateTexture : temp + humidity
- IceMask (ou dérivable)
- RiverFluxTexture : flux -> détection rivières
- Paramètres : `atmosphere_type`

## 4.1 Biomes : classification type Whittaker
Le manifeste parle d’un “Diagramme de Whittaker”.
Implémentation pratique :
- Normaliser `temp` et `humidity` dans des axes
- Définir des seuils en fonction du type de planète
- Utiliser height/water pour overrides (ocean, coast, mountain…)

### Overrides prioritaires (ordre)
1) sans atmosphère : biomes “nus / régolithe / cratères” (si cratering actif)
2) banquise (ice==1)
3) eau (water>0) : océan / lac / côtier selon profondeur/pente
4) rivière (river_flux > threshold) : type rivière/fleuve (taille via flux)
5) sinon : biome terrestre via (temp, humidity, height)

### Remplacement de `Enum.getBiomeByNoise`
Le legacy ajoute un bruit pour casser les frontières.
En GPU :
- `noise_val = fbm(...)` ou hash
- utiliser ce bruit pour interpoler des frontières (ex. déplacer un seuil)

## 4.2 Post-process : lissage & irrégularité
### Lissage (majority vote)
- 2 passes sur `BiomeID`.
- Ne pas modifier si pixel est : rivière / banquise.
- Wrap X obligatoire.

Implémentation :
- Lire 8 voisins (ou 4) et compter les IDs.
- Choisir l’ID dominant si compte >= seuil.

### Irrégularité bord
- Si un pixel a des voisins d’ID différent -> c’est une bordure.
- Utiliser un bruit (hash(x,y)) pour décider de “basculer” vers un des IDs voisins.

## 4.3 Régions : approche GPU (recommandée)
Le legacy `RegionMapGenerator.gd` fait une croissance BFS avec tri par distance+random, ce qui est très CPU.

### Important : “régions” = territoires administratifs (pas biomes)
Ici, une région est un **découpage administratif** (territoire) :
- elle doit être **connectée** (un seul composant si possible),
- elle doit respecter des **contraintes terrain** (eau infranchissable, montagnes/rivières comme frontières naturelles),
- elle possède un **quota de points de territoire** (nombre de pixels/cases à posséder).

Objectif visuel : frontières plausibles (pas de lignes rectilignes), influencées par le relief et l’hydrologie.

GPU recommandé : croissance multi-sources **dépendante du terrain** (avec quotas)

Un Voronoi/JFA “pur” donne des frontières trop géométriques et ne gère pas naturellement les quotas. À la place, utiliser une **croissance par coût** (type multi-source flood fill) guidée par une “fonction de coût terrain”.

#### 4.3.1 Fonction de coût terrain (cost field)
Définir un coût de traversée pour passer d’un pixel à un voisin (4 ou 8 voisins) :
- Eau : coût infini (infranchissable) si on veut des régions terrestres.
- Pente forte : coût élevé (les frontières suivent les crêtes).
- Rivières / grands flux : coût élevé (frontière naturelle) ou au contraire coût faible si on veut que les routes suivent les vallées (choisir une convention).
- Bruit faible (domain warp) : micro-variations pour casser toute géométrie.

Exemple (conceptuel) :
- `cost = base + k_slope * slope + k_river * river_barrier + k_noise * (0.5 + 0.5*noise(p'))`

#### 4.3.2 Données nécessaires
- `RegionSeedBuffer` (SSBO) : K capitals (x,y) + `target_area` (quota de pixels) + paramètres.
- `RegionStateTexture` : par pixel :
  - `region_id`
  - `accumulated_cost` (distance/coût depuis la capitale)
- `RegionCounters` (SSBO) : aire actuelle par région (atomics).

#### 4.3.3 Initialisation
1) Choisir K capitales **sur terre** (Poisson disk ou rejet si water).
2) Initialiser :
   - si pixel == capitale : `region_id = i`, `cost = 0`
   - sinon : `region_id = -1`, `cost = +INF`
3) Mettre les compteurs : `RegionCounters[i] = 1`

#### 4.3.4 Croissance itérative (passes GPU)
On fait N itérations (jusqu’à remplissage). Chaque itération :
1) Pour chaque pixel non assigné (ou assignable), regarder les voisins.
2) Proposer une “prise de territoire” depuis le voisin dont :
   - le `cost_voisin + edge_cost` est minimal
   - ET la région candidate n’a pas atteint son quota : `RegionCounters[id] < target_area`
3) Si une région gagne le pixel :
   - écrire `region_id` et `cost`
   - `atomicAdd(RegionCounters[id], 1)`

##### Gestion des conflits (plusieurs pixels réclament la même région)
L’ordre exact est non déterministe sur GPU. Pour stabiliser :
- Ajouter un tie-break déterministe : `hash(pixel, seed)`
- Ou exécuter en 2 phases :
  - phase propose (écrit candidate)
  - phase commit (valide selon quotas)

#### 4.3.5 Anti-lignes droites (très important)
Pour éviter des frontières “droites” :
- Appliquer **domain warping** dans le calcul du coût : utiliser `p'` au lieu de `p`.
- Ajouter un bruit faible au coût (ci-dessus) pour irrégularité.
- Ajouter un post-process léger (comme biomes) :
  - sur les pixels frontière uniquement, permettre des swaps locaux si le swap réduit le coût ou suit une barrière (rivière/crête).

#### 4.3.6 Garantir des régions connectées
La croissance par coût tend à produire des territoires connectés si :
- l’initialisation ne place qu’une capitale par “île” (composant terrestre), ou
- on interdit le franchissement de l’eau.

Si le monde a beaucoup d’îles :
- soit autoriser une région “archipel” (plusieurs composants),
- soit détecter les composantes terrestres (option : passe de label-components) et y placer des capitales.

Avantages :
- Frontières influencées par relief/hydrologie (plus réalistes)
- Quotas de territoire possibles (objectif “nombre de points”)
- Seamless X gérable via wrap sur X

## Validation
- Export debug : BiomeID en fausses couleurs.
- Vérifier :
  - rivières préservées
  - banquise préservée
  - frontières non trop “pixelisées” après irrégularité

---

Prochaine étape : **Étape 5 (Ressources & Oil)**.
