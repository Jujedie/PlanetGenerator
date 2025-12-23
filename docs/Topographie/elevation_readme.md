# Génération de Carte d'Élévation - GPU Pipeline

## 📋 Vue d'ensemble

Cette implémentation réalise la **Section 2.1 du Plan Technique** : Génération de la carte d'élévation par simulation géophysique sur GPU.

### Changements majeurs

Au lieu d'utiliser des bruits simples (Perlin/Simplex), le système simule maintenant :
1. **Tectonique des plaques** (Voronoi vectoriel avec mouvements)
2. **Orogenèse** (Formation de montagnes par friction aux frontières)
3. **Érosion hydraulique** (Simulation de pluie, transport de sédiments)

## 🗂️ Fichiers créés/modifiés

### Nouveaux Shaders (à placer dans `res://shaders/compute/`)

1. **`tectonic_plates.glsl`** - Génération des plaques tectoniques
   - Diagramme de Voronoi avec wrapping cylindrique
   - Calcul des vecteurs de mouvement par plaque
   - Détection des zones de convergence/divergence
   - Génération de l'élévation de base

2. **`orogeny.glsl`** - Ajout de détails orographiques
   - Ridged Multifractal pour montagnes escarpées
   - FBM pour variations douces
   - Application uniquement aux zones de friction

3. **`hydraulic_erosion.glsl`** - Érosion par l'eau
   - Simulation de flux d'eau avec gravité
   - Érosion et transport de sédiments
   - Déposition dans les zones plates
   - Évaporation

### Fichiers modifiés

- **`orchestrator.gd`** : Ajout des phases de génération d'élévation
- **`exporter.gd`** : Export correct avec palette Enum.gd
- **`gpu_context.gd`** : (Déjà fonctionnel, aucune modification nécessaire)

## 🚀 Installation

### 1. Créer le dossier des shaders

```
res://
└── shaders/
    └── compute/
        ├── tectonic_plates.glsl
        ├── orogeny.glsl
        └── hydraulic_erosion.glsl
```

### 2. Importer les shaders dans Godot

Les fichiers `.glsl` doivent être reconnus par Godot comme des **RDShaderFile**.

**Vérification** : Dans l'inspecteur, les fichiers doivent avoir l'icône d'un shader et non d'un fichier texte.

Si ce n'est pas le cas :
1. Clic droit sur le fichier → "Reimport"
2. Dans l'onglet Import, sélectionner **"RDShaderFile"**
3. Cliquer sur "Reimport"

### 3. Tester la génération

Lancez le projet et cliquez sur **"Générer"**. La console devrait afficher :

```
[Orchestrator] 🌍 DÉMARRAGE SIMULATION COMPLÈTE
[Orchestrator] ═══ PHASE 1: TECTONIC PLATES GENERATION ═══
  ✅ Tectonique des plaques terminée
[Orchestrator] ═══ PHASE 2: OROGENIC DETAIL INJECTION ═══
  ✅ Détails orographiques ajoutés
[Orchestrator] ═══ PHASE 3: HYDRAULIC EROSION (ITERATIVE) ═══
  ✅ Érosion hydraulique terminée (100 cycles)
```

### 4. Vérifier les exports

Les fichiers suivants doivent être créés dans `user://temp/` :
- `elevation_map.png` (couleurs réalistes)
- `elevation_map_alt.png` (niveaux de gris)

## 📊 Paramètres de génération

Ces paramètres sont configurables depuis l'UI et affectent la génération :

| Paramètre | Effet | Valeur recommandée |
|-----------|-------|-------------------|
| `nb_cases_regions` | Nombre de plaques tectoniques | 20-50 |
| `terrain_scale` | Intensité du relief | 5000-10000 |
| `global_humidity` | Quantité de pluie (érosion) | 0.3-0.7 |
| `erosion_iterations` | Précision de l'érosion | 100-500 |
| `seed` | Graine aléatoire | Toute valeur |

## 🔧 Architecture technique

### État GPU (Textures)

Le système utilise deux textures principales :

#### `GEOPHYSICAL_STATE` (geo_state)
- **R** : Élévation en mètres (-25000 à +25000)
- **G** : Quantité d'eau (pour simulation d'érosion)
- **B** : Sédiments transportés
- **A** : ID de la plaque tectonique

#### `PLATE_DATA` (plate_data)
- **R** : Vitesse X de la plaque
- **G** : Vitesse Y de la plaque
- **B** : Coefficient de friction (0-1)
- **A** : Type de plaque (0=océanique, 1=continentale)

### Pipeline de génération

```
┌─────────────────┐
│ Initialisation  │  Création des textures vides
└────────┬────────┘
         │
┌────────▼────────┐
│   Tectonique    │  Génération Voronoi + Vecteurs de mouvement
│     (1 pass)    │  → Élévation de base + Zones de friction
└────────┬────────┘
         │
┌────────▼────────┐
│   Orogenèse     │  Ajout de bruit fractal dans zones de friction
│     (1 pass)    │  → Montagnes escarpées
└────────┬────────┘
         │
┌────────▼────────┐
│    Érosion      │  Simulation itérative de pluie
│  (100+ passes)  │  → Érosion + Dépôt de sédiments
└────────┬────────┘
         │
┌────────▼────────┐
│     Export      │  Conversion GPU → PNG avec palette Enum.gd
└─────────────────┘
```

## 🐛 Débogage

### Problème : Shaders non compilés

**Symptôme** : `❌ Failed to create [shader_name] uniform set`

**Solution** :
1. Vérifier que les fichiers `.glsl` sont bien importés comme RDShaderFile
2. Vérifier les erreurs de compilation dans la console
3. S'assurer que la syntaxe GLSL 450 est respectée

### Problème : Carte uniforme (pas de relief)

**Symptôme** : L'élévation semble plate ou uniforme

**Solutions** :
- Augmenter `terrain_scale` dans l'UI
- Vérifier que `num_plates` > 10
- S'assurer que les paramètres sont bien transmis aux shaders

### Problème : Crash lors du dispatch

**Symptôme** : Godot crash pendant la génération

**Solutions** :
- Réduire `erosion_iterations` (commencer par 50)
- Vérifier la résolution (doit être < 2048x1024 pour tests)
- S'assurer que la VRAM est suffisante

## 📈 Prochaines étapes

Une fois cette section validée, les prochaines cartes seront générées :

1. **Carte des Eaux** (2.2) - Océans, lacs, rivières
2. **Carte de Température** (2.3) - Climat basé sur latitude/altitude
3. **Carte des Nuages** (2.4) - Atmosphère dynamique
4. **Carte des Régions** (2.5) - Voronoi contraint
5. **Carte des Ressources** (2.6) - Distribution stratégique
6. **Carte des Biomes** (2.7) - Classification écologique

Chacune utilisera les données générées précédemment pour assurer la cohérence.

## 🎓 Références techniques

- **Voronoi GPU** : [GPU Gems 2, Chapter 23](https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-23-gpu-implementation-voronoi-diagram)
- **Érosion Hydraulique** : [Large Scale Terrain Generation](https://www.johansson.jp/vqm/gpu-generated-terrain-erosion-procedural-generation/)
- **Ridged Multifractal** : [Texturing & Modeling: A Procedural Approach](https://www.amazon.com/Texturing-Modeling-Third-Procedural-Approach/dp/1558608486)

---

**Note** : Cette implémentation respecte l'architecture définie dans `Plan.md` section 2.1 et utilise exclusivement les Compute Shaders pour une génération 100% GPU.
