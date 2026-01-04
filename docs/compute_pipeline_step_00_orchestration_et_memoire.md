# Pipeline Compute — Étape 0 : Orchestration & Mémoire (Godot 4 / RenderingDevice)

Ce document sert de **cahier des charges exécutable** pour une autre IA : il décrit comment orchestrer une pipeline de génération planétaire en **compute shaders** dans Godot 4, en **enchaînant les résultats directement en VRAM** (textures/storage buffers) sans « lire chaque pixel » sur CPU.

## Objectif
- Remplacer progressivement les générateurs CPU du dossier `src/legacy_generators/` par une pipeline GPU décrite dans le manifeste (RoadMap/GEMINI).
- Les sorties doivent rester **compatibles** avec le reste du projet (export PNG via `exporter.gd` possible), mais **la génération** doit rester en VRAM.

## Ancrage dans le projet existant
- Contexte bas niveau GPU : `src/classes/classes_gpu/gpu_context.gd`.
- Orchestrateur : `src/classes/classes_gpu/orchestrator.gd`.
- Readback/export (uniquement pour sauvegarde/PNG) : `src/classes/classes_io/exporter.gd`.

## Principe clé : “zéro readback pendant la simulation”
Pendant la simulation, **ne pas appeler** `RenderingDevice.texture_get_data()` (sauf export final). À la place :
- Chaque compute shader **écrit** dans des textures `TEXTURE_USAGE_STORAGE_BIT`.
- Les étapes suivantes **lisent** ces mêmes textures via bindings (`image2D` / `sampler2D`) ou buffers.
- Le rendu/preview (2D/3D) utilise directement les **RID** de textures GPU comme input de matériaux/shaders de rendu.

## Contrainte globale : toutes les maps sont équirectangulaires (2:1)
Toutes les textures de simulation doivent être en **projection équirectangulaire** :
- largeur `W` = circonférence (longitude)
- hauteur `H = W/2` (latitude)
- X est **cyclique** (seamless) : `x = (x + W) % W`
- Y ne wrap pas : `y ∈ [0, H-1]`

### Conversion pixel -> (lon, lat)
- longitude : `lon = (x / W) * 2π` (ou normalisée `u = x/(W-1)`)
- latitude : `lat = (y / (H-1)) * π - π/2` (ou normalisée `v = y/(H-1)`)

### Distances et voisinage
- Distance en X (cyclique) : `dx = min(abs(x1-x2), W-abs(x1-x2))`
- Voisins : wrap X, clamp Y.

### Remarque importante
Les compute shaders doivent **toujours** utiliser ces conventions (notamment pour Voronoi/JFA, cratères, flux, etc.), sinon on obtient des coutures visibles et/ou une planète incohérente.

## Recommandation de layout mémoire (aligné avec le manifeste)
Le manifeste propose du « texture packing » pour minimiser les transferts.

### 0.1 GeoTexture (RGBA32F)
Un état géophysique “dense” :
- `R` : height (mètres, ou hauteur normalisée)
- `G` : bedrock (résistance / dureté)
- `B` : sediment (épaisseur de sédiments)
- `A` : water height (colonne d’eau)

> Variante pratique : conserver `height` en mètres (float), et ne convertir en couleurs (palettes `Enum`) qu’au moment de l’export ou du rendu.

### 0.2 ClimateTexture (RGBA16F ou RGBA32F au début)
- `R` : température (°C ou normalisée)
- `G` : humidité (0..1) ou précipitations (0..1)
- `B` : vent X
- `A` : vent Y

### 0.3 Textures additionnelles (optionnelles mais utiles)
- `RiverFluxTexture` (R32F) : débit/flux accumulé, utile pour biomes/rivières.
- `PlateTexture` (RGBA32F) : id/seed/velocity/age ou autre packing.
- `TempBuffer` : ping-pong (double buffer) pour les passes itératives.

> Dans le code actuel, `GPUContext` a déjà `TEMP_BUFFER`. Utiliser ce slot comme ping-pong est cohérent.

## Conception des ressources dans `GPUContext`
### 1) Créer des textures storage + sampling
Le code existant crée des textures RGBA32F avec :
- `TEXTURE_USAGE_STORAGE_BIT`
- `TEXTURE_USAGE_SAMPLING_BIT`
- `TEXTURE_USAGE_CAN_COPY_FROM_BIT`
- `TEXTURE_USAGE_CAN_UPDATE_BIT`

Conserver cette approche pour le moment, puis spécialiser les formats une fois stable.

### 2) Séparer “image” vs “sampler”
Dans `GPUContext`, `create_texture_uniform()` crée un uniform de type `UNIFORM_TYPE_IMAGE` (storage image) — parfait pour `layout(rgba32f) uniform image2D`.

Pour **sampler2D** (lecture filtrée), prévoir un helper dédié :
- `UNIFORM_TYPE_SAMPLER_WITH_TEXTURE` + création d’un sampler.

Règle pratique :
- Écriture -> `image2D`.
- Lecture brute sans filtrage -> `imageLoad()` sur une image bindée en `readonly`.
- Lecture filtrée / mipmapping (rare en compute) -> sampler.

## Standardisation GLSL : bindings et conventions
Fixer une convention stable pour limiter les bugs.

### Exemple de set 0 (état global)
- `binding 0` : GeoTexture (read/write)
- `binding 1` : ClimateTexture (read/write)
- `binding 2` : TempBuffer (read/write) — ping-pong
- `binding 3` : PlateTexture (read/write)

### UBO : paramètres globaux
Mettre les paramètres dans un `uniform` buffer (std140), ex :
- seed
- width/height
- sea_level
- gravity
- atm_type
- nb_plaques
- coefficients (érosion, pluie, evaporation…)

Important : **stabilité des layouts** (std140/std430). Ne pas changer l’ordre/alignement sans mise à jour coordonnée côté GDScript.

## Orchestration : comment chaîner les étapes en VRAM
### 0.4 Compilation et pipelines
- Compiler chaque compute shader en SPIR-V (`load().get_spirv()`), déjà implémenté par `GPUContext.load_compute_shader()`.
- Créer un pipeline compute via `rd.compute_pipeline_create(shader_rid)` (déjà fait).

### 0.5 Uniform sets
Créer un `uniform_set` par shader avec les mêmes bindings que dans le GLSL.

### 0.6 Dispatch
Le dispatch existant (`dispatch_compute`) :
- begin compute list
- bind pipeline
- bind uniform set
- dispatch
- end
- submit
- sync

Pour la version “non bloquante” :
- Remplacer les `sync()` fréquents par une stratégie “batch” (soumettre plusieurs passes, puis synchroniser 1 fois), ou utiliser un mécanisme de polling selon les APIs disponibles.

## Barrières mémoire (conceptuelles)
Dans Vulkan, on aurait des barriers explicites. Dans Godot `RenderingDevice`, le pattern courant est :
- séparer les passes (compute lists)
- `rd.submit()` entre les passes
- `rd.sync()` uniquement quand on doit absolument attendre (export, UI qui doit afficher le résultat final immédiatement, etc.)

Objectif : **pas de `sync()` à chaque pass** en production.

## Validation progressive (très important)
Pour éviter les bugs “silencieux” GPU :
1. Démarrer avec une étape simple qui écrit un gradient dans GeoTexture.
2. Faire un export via `exporter.gd` pour vérifier les valeurs.
3. Ajouter ensuite une vraie étape (tectonique), etc.

## Mapping “Legacy -> GPU” (rappel)
Les scripts legacy à répliquer conceptuellement :
- `ElevationMapGenerator.gd` : relief (bruits + tectonic ridges/canyons)
- `WaterMapGenerator.gd` : masque eau selon `water_elevation`
- `RiverMapGenerator.gd` : rivières/lacs (long, mais on en extrait des invariants)
- `TemperatureMapGenerator.gd` : latitude + altitude
- `PrecipitationMapGenerator.gd` : bruit + influence latitude
- `NuageMapGenerator.gd` : nuages (atmosphère)
- `BanquiseMapGenerator.gd` : glace (temp < 0 sur eau)
- `BiomeMapGenerator.gd` : classification + postprocess (lissage / irrégularité)
- `RegionMapGenerator.gd` : régions (plutôt Voronoi/JFA en GPU)
- `RessourceMapGenerator.gd`, `OilMapGenerator.gd` : gisements

## Sorties attendues (côté projet)
Le “reste du jeu” s’attend à :
- height/elevation (au moins pour rendu)
- humidité/précipitations
- température
- biome/region

Sur GPU : les sorties doivent être des textures RID conservées en mémoire, réutilisables par :
- shader de rendu (preview)
- exporter (readback final uniquement)

---

Prochaine étape : implémenter **Étape 1 (Tectonic & Orogeny)**.
