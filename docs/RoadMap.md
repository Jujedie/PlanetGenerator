# GEMINI.md - Manifeste Technique : PlanetGenerator Final-Upgrade

## 1. Vision du Projet
Le projet **PlanetGenerator Final-Upgrade** vise à remplacer l'ancienne génération procédurale basée sur le CPU (Legacy Generators) par une architecture **massivement parallèle sur GPU (Compute Shaders)** sous Godot 4.x.

L'objectif n'est pas seulement d'optimiser les performances, mais de changer de paradigme : passer d'une **génération par bruit** (Perlin/Simplex aléatoire) à une **génération par simulation** (processus géophysiques réalistes).

## 2. Objectifs Fondamentaux

### A. Réalisme Scientifique ("Hard Science")
Les cartes générées ne doivent pas être de simples textures de bruit. Elles doivent être le résultat de l'interaction de lois physiques :
* **Géologie :** Tectonique des plaques, dérive, collision et subduction.
* **Hydrologie :** Écoulement réaliste des fluides, érosion hydraulique, transport de sédiments.
* **Climatologie :** Circulation atmosphérique, influence de l'altitude sur la température, cycle de l'eau.
* **Topologie :** Les cartes doivent être **Seamless (Cycliques)** sur l'axe X (Longitude) pour permettre une projection planétaire cohérente.

### B. Parité Fonctionnelle avec le Legacy (Sorties Équivalentes)
Le nouveau système doit être capable de produire **toutes les données** que produisaient les générateurs CPU "Legacy", mais avec une qualité et une cohérence supérieures.
Le reste du jeu (gameplay, rendu) s'attend à recevoir des textures spécifiques (Hauteur, Humidité, Température, Biome). Le moteur GPU doit fournir ces outputs.

### C. Architecture GPU Consolidée (Pas de "1 Shader = 1 Map")
Contrairement à l'approche CPU modulaire (un script par type de carte), l'approche GPU doit être **intégrée et systémique**.
**Nous ne ferons pas un shader par carte.** Nous ferons des shaders de **simulation** qui génèrent plusieurs cartes en sortie simultanément via des `Texture2DArray` ou des canaux RGBA compressés.

---

## 3. Stratégie de Remplacement (Legacy vs GPU)

Voici comment les modules CPU disparates seront fusionnés en pipelines de simulation GPU cohérents :

| Générateur Legacy (CPU) | Système GPU (Compute Shaders) | Description de la Simulation |
| :--- | :--- | :--- |
| **ElevationMapGenerator** | **1. Tectonic & Orogeny Pipeline** | Simule le mouvement des plaques (Voronoi) et le soulèvement des montagnes aux zones de collision. Génère la *HeightMap* de base. |
| **RiverMapGenerator**<br>**WaterMapGenerator**<br>**Elevation (Erosion)** | **2. Hydraulic Erosion Pipeline** | Simule la pluie, le flux d'eau, l'érosion du terrain et le dépôt de sédiments. Génère la *HeightMap Finale*, la *WaterMask*, et la *RiverFluxMap*. |
| **TemperatureMapGenerator**<br>**PrecipitationMapGenerator**<br>**NuageMapGenerator**<br>**BanquiseMapGenerator** | **3. Atmosphere & Climate Pipeline** | Simule la thermodynamique globale. La température dépend de la latitude et de l'altitude (issue de l'étape 2). L'humidité est transportée par les vents. Génère *TempMap*, *WetnessMap*, *IceMask*. |
| **BiomeMapGenerator**<br>**RegionMapGenerator** | **4. Biosphere Classification** | Un shader léger qui lit les résultats précédents (Hauteur, Temp, Humidité) et applique un Diagramme de Whittaker pour classifier les pixels. Génère *BiomeMap* et *RegionMap*. |
| **RessourceMapGenerator**<br>**OilMapGenerator** | **5. Geological Resource Layer** | Déduit les ressources en fonction de l'historique géologique (ex: Pétrole là où l'eau a stagné longtemps, Charbon dans les zones de forêts denses anciennes). |

---

## 4. Pipeline Technique (Godot 4 & Vulkan)

### Orchestrateur (`orchestrator.gd`)
Le chef d'orchestre GDScript qui ne fait aucun calcul lourd. Son rôle est de :
1.  Préparer les **Uniform Buffers** (Paramètres de simulation : gravité, niveau de la mer, nombre de plaques).
2.  Gérer les **Storage Buffers** et **Textures** (Mémoire VRAM partagée entre les shaders).
3.  Lancer les **Compute Lists** (Dispatch) dans le bon ordre.
4.  Gérer les **Barrières de Mémoire** pour éviter que l'érosion ne commence avant que la tectonique ne soit finie.

### Structure des Données (Optimisation)
Pour réduire les transferts mémoire, nous utiliserons le "Texture Packing".
* **GeoTexture (RGBA Float32) :**
    * R : Height (Hauteur)
    * G : Bedrock (Roche dure)
    * B : Sediment (Sédiments meubles)
    * A : Water Height (Hauteur d'eau)
* **ClimateTexture (RGBA Float16) :**
    * R : Temperature
    * G : Humidity/Precipitation
    * B : Wind X
    * A : Wind Y

### Contraintes Critiques
1.  **Seamless X :** Tous les calculs de distance (Voronoi, Bruit, Érosion) doivent utiliser une fonction de distance cyclique (`min(dx, width - dx)`).
2.  **LOD (Level of Detail) :** Le système doit être capable de générer une basse résolution pour la vue orbitale et une haute résolution pour la vue locale (future implémentation).
3.  **Non-Bloquant :** L'orchestrateur doit utiliser `RenderingDevice` de manière asynchrone pour ne pas geler l'interface du jeu pendant la génération.
4.  **Performance :** Dans un temps futur, envisager l'implémentation de techniques d'optimisation GPU avancées (telles que le culling spatial ou les compute shaders multi-pass) pour améliorer les performances sur des résolutions élevées.
---

## 5. État Actuel et Prochaines Étapes

Le projet a migré avec succès les bases de l'infrastructure GPU.
* ❌ **Intégration des types de planètes :** Actuellement, aucune différenciation entre planètes terrestres, gazeuses ou océaniques n'est implémentée. Cela doit être ajouté pour permettre des variations dans les simulations géophysiques.
Par exemples il ne devrait pas y avoir d'érosion hydraulique sur une planète gazeuse ou sans atmosphère.
De même des cratères d'impact devraient être simulés sur des planètes sans atmosphère.
* ✅ **Infrastructure :** `orchestrator.gd` et `gpu_context.gd` fonctionnels.
* 🚧 **Tectonique :** Peaufiner l'implémentation de base Voronoi (à raffiner pour le réalisme des failles, aussi créer la map water).
* 🚧 **Érosion :** Peaufiner la simulation hydraulique fonctionnelle (UBO corrigés).
* 🚧 **Cratering :** À implémenter pour simuler les impacts sur les planètes sans atmosphère.
* 🚧 **Hydrologie :** Intégration partielle, nécessite des ajustements pour le transport des sédiments, rivières fleuves, fleuves affluents, lacs etc..
* 🚧 **Atmosphère :** Shader existant mais doit être connecté aux données d'élévation réelles.
* ❌ **Température & Précipitations :** À intégrer dans le pipeline Atmosphère.
* ❌ **Banquises :** À implémenter dans le pipeline température.
* ❌ **Biomes & Ressources :** À implémenter en tant que shaders de post-traitement.
* ❌ **Régions :** À implémenter en tant que shaders de post-traitement.
* ❌ **Preview 2D View :** Implémentation dans exporter.gd.
* ❌ **Rendu Final :** Implémentation dans exporter.gd.


**Note au développeur (Toi) :**
Toute modification du code doit prioriser la stabilité des buffers GPU (attention aux alignements std140/std430) et la cohérence physique des résultats.