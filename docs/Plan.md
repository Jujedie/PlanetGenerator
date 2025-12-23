# **Document de Mission Technique : Refonte du Générateur Planétaire (Godot 4.5 / Compute Shaders)**

## **1\. Introduction**

### **1.1 Objectif du Projet**

Le projet **PlanetGenerator** entre dans sa phase de refonte majeure ("Final-Upgrade"). L'objectif est de migrer l'intégralité du pipeline de génération, historiquement hybride et dépendant du CPU, vers une architecture **100% GPU** exploitant l'API RenderingDevice de Godot 4.5.

### **1.2 Changement de Paradigme**

Nous abandonnons la génération basée sur la superposition de bruits aléatoires simples (Perlin/Simplex) au profit d'une Génération par Simulation.  
Le terrain, le climat et la vie ne doivent plus être le fruit du hasard, mais la conséquence de systèmes physiques interagissant entre eux (Tectonique → Érosion → Climat → Biome).

### **1.3 Architecture Technique**

Le système repose sur deux piliers :

1. **L'Orchestrateur (CPU \- orchestrator.gd) :** Il ne manipule plus de pixels. Il gère le contexte GPU, alloue la mémoire (VRAM), et ordonne l'exécution des shaders (Dispatch).  
2. **Le Pipeline de Calcul (GPU \- GLSL) :** Une suite de Compute Shaders qui lisent et écrivent dans des **State Maps** (textures de données haute précision partagées).

## **2\. Description Détaillée des Cartes et Systèmes**

Chaque "Carte" ci-dessous correspond à une étape de simulation dans le pipeline GPU. Les données transitent d'une étape à l'autre sans repasser par le CPU.

### **2.1 Carte d’Élévation (Le Socle Géologique)**

Cette étape définit la topographie fondamentale via des processus géophysiques.

* **Tectonique des Plaques :**  
  * **Logic :** Remplacement du bruit simple par un diagramme de Voronoi vectoriel calculé sur GPU.  
  * **Simulation :** Chaque cellule (plaque) possède un vecteur de mouvement.  
    * *Convergence :* Les vecteurs s'affrontent → Soulèvement du terrain (Chaînes de montagnes, Plateaux).  
    * *Divergence :* Les vecteurs s'écartent → Affaissement (Rifts, Dorsales océaniques).  
  * **Friction :** Calculer un coefficient de friction aux frontières pour moduler l'intensité du relief.  
* **Orogenèse et Détail :**  
  * Injection de bruits fractals (Ridged Multifractal) *uniquement* dans les zones de friction tectonique pour simuler le plissement rocheux réaliste.  
  * Les plaines de plaques restent relativement plates.  
* **Érosion Hydraulique (Simulation Itérative) :**  
  * **Système :** Implémentation d'un système de particules fluides sur Compute Shader.  
  * **Cycle :** Pluie → Dissolution de la roche (R) → Transport de sédiments (B) → Dépôt dans les creux.  
  * **Résultat :** Formation naturelle de talwegs, de lits de rivières et de deltas. C'est cette étape qui donne son réalisme "usé" au terrain.

### **2.2 Carte des Eaux (Hydrologie)**

Gestion des masses d'eau liquides et de leur écoulement.

* **Océans et Lacs :**  
  * Définis par le niveau global de la mer (Sea Level) et l'accumulation locale d'eau issue de l'érosion.  
  * Les dépressions fermées remplies par l'érosion hydraulique deviennent des lacs dynamiques.  
* **Réseau Fluvial :**  
  * **Flux Map :** Analyse des vecteurs de flux générés par l'érosion.  
  * Les pixels où le débit d'eau cumulé dépasse un seuil deviennent des rivières.  
  * Le système doit assurer la continuité des rivières depuis les montagnes jusqu'aux embouchures (Océans ou Lacs).

### **2.3 Carte de Température (Thermodynamique)**

Simulation climatique basée sur la physique.

* **Modèle Énergétique :**  
  * **Latitude :** La température de base dépend de l'angle d'incidence solaire (Gradient Équateur-Pôles).  
  * **Altitude (Lapse Rate) :** Refroidissement adiabatique (ex: \-0.65°C / 100m). Les montagnes générées en 2.1 doivent refroidir l'air.  
  * **Inertie Thermique :** L'eau (Carte 2.2) modère les températures extrêmes.  
* **États de l'Eau (Banquise & Humidité) :**  
  * **Banquise :** Si Température \< Point de Congélation ET Présence d'Eau → Transformation en Glace (modification de l'Albedo).  
  * **Humidité :** Générée par évaporation au-dessus des océans chauds, transportée par les vents dominants.

### **2.4 Carte des Nuages (Atmosphère Dynamique)**

Système fluide pour une atmosphère vivante.

* **Simulation de Fluide :**  
  * Utilisation d'équations de Navier-Stokes simplifiées ou d'Automates Cellulaires sur GPU.  
  * **Advection :** La vapeur d'eau est déplacée par les vents (Carte Température/Pression).  
  * **Condensation :** Les nuages apparaissent là où l'air humide rencontre des fronts froids ou est forcé de monter par le relief (Effet orographique sur les montagnes).

### **2.5 Carte des Régions (Géographie Politique)**

Division du monde en zones logiques.

* **Voronoi Contraint :**  
  * Génération de territoires basée sur des points de germe (Capitales potentielles).  
  * **Coût de Propagation :** L'expansion des régions est bloquée ou ralentie par les obstacles géographiques issus des cartes précédentes (Océans, Hautes Montagnes).  
* **Macro-Zones :**  
  * Regroupement algorithmique de régions adjacentes pour former des ensembles continentaux ou des archipels cohérents.

### **2.6 Carte des Ressources (Gameplay)**

Distribution stratégique des richesses.

* **Logique en Couches (Layers) :** Une carte distincte (ou canal) par type de ressource.  
* **Ressources de Surface (Bio) :** Dépendent du couple Biome/Humidité (Bois, Gibier, Céréales).  
* **Ressources Minérales :** Dépendent de la géologie (2.1). Fer/Charbon dans les montagnes, Or dans les lits de rivières (résultat de l'érosion).  
* **Liquides (Pétrole/Eau) :**  
  * Pétrole : Anciens bassins sédimentaires (basse altitude, forte accumulation sédimentaire historique).  
  * Nappes Phréatiques : Zones de perméabilité géologique.

### **2.7 Carte des Biomes (Synthèse Écologique)**

Classification finale du vivant.

* **Diagramme de Whittaker :**  
  * Le shader utilise la Température (2.3) et l'Humidité (2.3) comme coordonnées pour lire une table de correspondance (LUT).  
  * Associe chaque pixel à un ID de biome (Désert, Toundra, Jungle, Forêt tempérée, etc.).  
* **Cohérence Systémique :**  
  * Intègre les modificateurs : Un biome "Forêt" ne peut pas exister sur un glacier ou sous l'océan.

### **2.8 Carte Finale et Preview**

Assemblage visuel pour l'utilisateur.

* **Rendu Composite :**  
  * Combinaison de l'Albedo (couleur des biomes), de la Rugosité (Eau vs Terre), des Normales (Relief) et de la couche Nuageuse.  
* **Coupe (Slice View) :**  
  * Génération d'une texture 2D représentant une tranche transversale de la planète (Altitude \+ Couches atmosphériques) pour valider la cohérence physique (ex: vérifier que la neige est bien au sommet des montagnes).

### **2.9 Gestion de la Cohérence et Types Planétaires**

Le pipeline de génération est conditionnel. L'orchestrateur configure des **Flags** (Uniforms Booléens) basés sur le type de planète demandé par l'utilisateur, activant ou désactivant des étapes spécifiques pour garantir la cohérence scientifique.

* **Planètes sans Atmosphère (Lunes, Planètes Naines) :**  
  * **Flags :** HAS\_ATMOSPHERE \= false, HAS\_LIQUID\_WATER \= false (généralement).  
  * **Modification Topographie :**  
    * Désactivation de l'Érosion Hydraulique (pas de pluie).  
    * **Activation du Shader de Cratérisation :** Simulation d'impacts de météores. Le shader génère des cratères de tailles variées (Distribution en loi de puissance), creusant le relief (GEO\_STATE.r) et créant un anneau d'éjectas surélevé.  
  * **Modification Climat :**  
    * Désactivation des shaders Nuages et Précipitations.  
    * Température définie uniquement par l'insolation brute (contraste Jour/Nuit extrême non lissé).  
* **Planètes sans Biosphère (Toxiques, Volcaniques, Glacées) :**  
  * **Flags :** HAS\_BIOSPHERE \= false.  
  * **Modification Ressources :**  
    * Interdiction stricte de générer des ressources fossiles ou organiques (Pétrole, Charbon, Humus).  
    * Remplacement par des ressources minérales abiotiques (Soufre, Silicates, Isotopes radioactifs).  
  * **Modification Biomes :**  
    * Utilisation d'une LUT de biomes alternative ("Barren LUT") : Roche nue, Glace, Désert de sel, Lave.  
* **Planètes Océan :**  
  * **Flags :** SEA\_LEVEL très élevé.  
  * **Conséquence :** Le shader de Régions (2.5) doit adapter sa logique pour créer des territoires maritimes ou des archipels, plutôt que des frontières terrestres classiques.

## **3\. Architecture de l'Orchestrateur et Flux de Données**

### **3.1 Rôle de l'Orchestrateur**

L'orchestrateur (orchestrator.gd) est le "cerveau" CPU qui pilote le GPU. Il ne traite pas les données, il gère le pipeline.

1. **Initialisation du Contexte :** Création du RenderingDevice et chargement des shaders compilés (SPIR-V).  
2. **Configuration des Flags :** Envoi des uniformes de configuration (PlanetType, HasAtmosphere, HasBiosphere) au GPU.  
3. **Allocation VRAM :** Création des textures de stockage (Storage Images).  
4. **Pipeline Dispatch Conditionnel :**  
   * Tectonics.glsl (Toujours actif)  
   * Craters.glsl (SI \!HasAtmosphere OU ThinAtmosphere)  
   * Erosion.glsl (SI HasAtmosphere ET HasLiquidWater)  
   * Atmosphere.glsl (SI HasAtmosphere)  
   * Resource\_Bio.glsl (SI HasBiosphere)...  
5. **Export/Visualisation :** Récupération de la texture finale.

### **3.2 Partage de Données (Texture Packing)**

Pour optimiser les lectures/écritures, les données sont groupées dans des textures formats RGBA32F (Haute Précision).

* *Note : Ces textures remplacent les anciens objets "Map" individuels.*  
* **Geophysical State :** Contient Élévation, Eau, Sédiments, ID Plaque.  
* **Atmospheric State :** Contient Température, Humidité, Vent, Nuages.  
* **Meta State :** Contient Biome ID, Region ID, Ressources.

## **4\. Conclusion**

Cette refonte technique vise à créer un simulateur de monde cohérent. En déportant la charge de calcul sur les Compute Shaders, nous pouvons simuler des phénomènes complexes (érosion, fluides) en temps réel ou quasi-réel, ce qui était impossible avec l'ancienne architecture CPU. La clé du succès réside dans la gestion rigoureuse des échanges de données entre les shaders via les State Maps unifiées.