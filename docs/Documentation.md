# PlanetGenerator — Documentation Utilisateur

> **PlanetGenerator Final-Upgrade** est un générateur procédural de planètes basé sur des simulations géophysiques GPU (Godot 4 / Vulkan).  
> Chaque planète est le résultat de l'interaction de lois physiques : tectonique, érosion hydraulique, climatologie et classification biomatique.

---

## Table des matières

1. [Vue d'ensemble de la pipeline](#1-vue-densemble-de-la-pipeline)
2. [Types de planètes](#2-types-de-planètes)
3. [Paramètres de génération](#3-paramètres-de-génération)
   - [Général](#31-général)
   - [Érosion & Tectonique](#32-érosion--tectonique)
   - [Cratères](#33-cratères)
   - [Eau & Hydrologie](#34-eau--hydrologie)
   - [Nuages](#35-nuages)
   - [Régions terrestres](#36-régions-terrestres)
   - [Régions océaniques](#37-régions-océaniques)
   - [Ressources](#38-ressources)
4. [Système de Température](#4-système-de-température)
5. [Système de Précipitations](#5-système-de-précipitations)
6. [Classification des Biomes](#6-classification-des-biomes)
   - [Planète Terrienne (Type 0)](#61-planète-terrienne-type-0)
   - [Planète Toxique (Type 1)](#62-planète-toxique-type-1)
   - [Planète Volcanique (Type 2)](#63-planète-volcanique-type-2)
   - [Sans Atmosphère (Type 3)](#64-sans-atmosphère-type-3)
   - [Planète Morte (Type 4)](#65-planète-morte-type-4)
   - [Planète Stérile (Type 5)](#66-planète-stérile-type-5)
7. [Cartes générées](#7-cartes-générées)
8. [Système de Ressources](#8-système-de-ressources)

---

## 1. Vue d'ensemble de la pipeline

La génération d'une planète suit un pipeline séquentiel en 5 étapes, chaque étape alimentant la suivante :

```
[1] Tectonique & Orogenèse
        ↓  (HeightMap brute + plaques)
[2] Érosion Hydraulique
        ↓  (HeightMap finale + WaterMask + RiverFlux)
[3] Atmosphère & Climat
        ↓  (Température + Précipitations + Calottes glaciaires + Nuages)
[4] Classification Biomatique (Whittaker)
        ↓  (BiomeMap + Régions + Régions Océaniques)
[5] Couche de Ressources Géologiques
        ↓  (Pétrole + Ressources minières)
```

Toutes les cartes sont des textures en **projection équirectangulaire** (seamless sur l'axe X/longitude).

---

## 2. Types de planètes

Le type de planète est le paramètre le plus déterminant : il contrôle quels biomes peuvent apparaître, et modifie le comportement des shaders climatiques.

| ID | Nom | Description | Eau liquide | Atmosphère |
|----|-----|-------------|:-----------:|:----------:|
| 0 | **Terrienne** | Planète Terre-like avec océans, forêts, déserts | ✅ Oui | ✅ Oui |
| 1 | **Toxique** | Atmosphère acide (type Vénus), champignons, soufre | ⚠️ Acide | ✅ Dense |
| 2 | **Volcanique** | Magma actif, cendres, geysers (type Io) | ❌ Lave | ✅ Volcanique |
| 3 | **Sans Atmosphère** | Désert lunaire, régolithe, cratères (type Lune/Mercure) | ❌ Non | ❌ Non |
| 4 | **Morte / Irradiée** | Post-apocalyptique, wasteland, radiation (type Fallout) | ⚠️ Polluée | ⚠️ Résiduelle |
| 5 | **Stérile** | Roche nue, planète géologique morte (type Mars passif) | ❌ Non | ❌ Non |

> **Note :** Les types 3 (Sans Atmosphère) et 5 (Stérile) désactivent l'érosion hydraulique et les systèmes d'humidité/précipitations.

---

## 3. Paramètres de génération

### 3.1 Général

| Paramètre | Valeur par défaut | Plage | Rôle |
|-----------|:-----------------:|-------|------|
| **Seed** | 0 (aléatoire) | 0–1 000 000 000 000 | Graine de génération. `0` = aléatoire à chaque lancement. Une même seed produit toujours la même planète. |
| **Nom de la planète** | *(libre)* | Texte | Nom affiché dans l'interface et les exports. |
| **Type de planète** | Terrienne (0) | 0–5 | Sélectionne le profil de biomes, les shaders climatiques actifs et le rendu final. |
| **Rayon planétaire** | 150 km | 150–1500 km | Détermine la résolution de la carte (`2π × rayon` pixels de large). Un rayon plus grand génère une texture plus grande et une planète plus détaillée. |
| **Densité planétaire** | 5.51 g/cm³ | 0.5–10 g/cm³ | Densité de la planète (Terre ≈ 5.51 g/cm³). Influence le calcul de la gravité de surface, qui modifie la rétention atmosphérique. |
| **Température moyenne** | Variable | -200 à +200 °C | Point d'ancrage de la température globale à l'équateur. Toutes les températures locales sont calculées relativement à cette valeur. |
| **Nombre de threads** | Automatique | 1–16 | Nombre de threads CPU utilisés pour la post-processing (transfert des données GPU). N'affecte pas la vitesse du GPU. |

---

### 3.2 Érosion & Tectonique

Ces paramètres contrôlent la simulation géologique qui sculpte le relief.

#### Tectonique des plaques

| Paramètre | Défaut | Rôle |
|-----------|--------|------|
| **Échelle de terrain** (`terrain_scale`) | 0 | Facteur multiplicateur de la hauteur globale du terrain. Une valeur élevée produit un relief plus prononcé (montagnes plus hautes). |
| **Âge max de croûte** (`max_crust_age`) | 200 Myr | Âge maximal de la croûte océanique en millions d'années. Une croûte plus vieille est plus dense et tend à s'enfoncer (subduction), créant des fosses océaniques. |
| **Coefficient de subsidence** (`subsidence_coeff`) | 2800 | Contrôle la vitesse d'enfoncement de la croûte océanique. Une valeur forte crée des bassins océaniques plus profonds. |
| **Taux de propagation** (`propagation_rate`) | 0.8 | Vitesse à laquelle les dorsal médio-océaniques créent de la nouvelle croûte. |
| **Taux d'expansion** (`spreading_rate`) | 50.0 | Largeur des zones de divergence des plaques. Un taux élevé crée de larges dorsales océaniques peu profondes. |

#### Érosion hydraulique

| Paramètre | Défaut | Rôle |
|-----------|--------|------|
| **Itérations d'érosion** (`erosion_iterations`) | 100 | Nombre de passes de simulation d'érosion. Plus d'itérations = terrain plus érodé et réaliste. Impact fort sur le temps de génération. |
| **Taux d'érosion** (`erosion_rate`) | 0.05 | Quantité de roche arrachée par unité d'eau en mouvement. Une valeur élevée creuse des canyons profonds rapidement. |
| **Taux de pluie** (`rain_rate`) | 0.005 | Quantité d'eau ajoutée à chaque itération. Un taux élevé génère plus de flux d'eau et une érosion plus intense. |
| **Taux d'évaporation** (`evap_rate`) | 0.02 | Vitesse de perte d'eau sur les surfaces. Un taux d'évaporation élevé favorise les zones arides. |
| **Taux de flux** (`flow_rate`) | 0.25 | Vitesse de déplacement de l'eau sur la pente. Un flux rapide creuse des chenaux plus étroits et profonds. |
| **Taux de dépôt** (`deposition_rate`) | 0.05 | Quantité de sédiments déposés dans les zones plates. Un dépôt élevé crée de larges plaines alluviales. |
| **Multiplicateur de capacité** (`capacity_multiplier`) | 1.0 | Quantité de sédiments qu'un flux peut transporter. Une valeur élevée = plus d'érosion dans les pentes raides. |

#### Accumulation de flux

| Paramètre | Défaut | Rôle |
|-----------|--------|------|
| **Itérations de flux** (`flux_iterations`) | 10 | Nombre d'itérations pour accumuler les flux orientés vers l'aval (calcul des rivières). |
| **Flux de base** (`base_flux`) | 1.0 | Quantité d'eau de départ par cellule pour le calcul de l'accumulation. Affecte la densité du réseau hydrographique. |

---

### 3.3 Cratères

Ces paramètres s'appliquent principalement aux planètes **Sans Atmosphère** (Type 3) et **Stérile** (Type 5), où l'atmosphère ne protège pas des impacts météoritiques.

| Paramètre | Défaut | Plage | Rôle |
|-----------|--------|-------|------|
| **Densité de cratères** (`crater_density`) | 0.5 | 0.0–1.0 | Nombre de cratères générés. `0` = aucun cratère, `1` = surface saturée. |
| **Rayon minimal** (`crater_min_radius`) | *(calculé)* | 1–∞ km | Taille du plus petit cratère possible. Les micro-météorites créent de nombreux petits cratères. |
| **Ratio de profondeur** (`crater_depth_ratio`) | 0.25 | 0.0–1.0 | Rapport profondeur/rayon du cratère. `0.25` = un cratère de 100 km a 25 km de profondeur (réaliste). |
| **Étendue éjectée** (`crater_ejecta_extent`) | 2.5 | 1.0–5.0 | Rayon des débris éjectés autour du cratère, en multiples du rayon de ce dernier. |
| **Décroissance éjectée** (`crater_ejecta_decay`) | 3.0 | 1.0–10.0 | Vitesse à laquelle la quantité de débris diminue avec la distance au cratère. Un taux élevé concentre les éjectas près du bord. |
| **Variation d'azimut** (`crater_azimuth_var`) | 0.3 | 0.0–1.0 | Irrégularité angulaire des éjectas. `0` = cercle parfait, `1` = distribution très asymétrique (impact oblique). |

---

### 3.4 Eau & Hydrologie

| Paramètre | Défaut | Plage | Rôle |
|-----------|--------|-------|------|
| **Ratio océanique** (`ocean_ratio`) | 70% | 0–100% | Pourcentage de surface couverte par les océans salés. `70%` correspond à la Terre. |
| **Niveau de la mer** (`sea_level`) | 0 m | illimité | Décalage vertical du niveau de la mer en mètres. Un niveau positif inonde les plaines côtières ; un niveau négatif expose les fonds marins. |
| **Humidité globale** (`global_humidity`) | 50% | 0–100% | Humidité de base de l'atmosphère. Amplifie ou réduit les précipitations sur toute la planète. |
| **Probabilité de glace** (`ice_probability`) | 90% | 0–100% | Probabilité qu'une région polaire froide se couvre de glace. `100%` = calottes polaires permanentes garanties. |
| **Taille max eau douce** (`freshwater_max_size`) | 999 km² | > 0 | Seuil de surface au-dessus duquel un plan d'eau est considéré comme un océan (eau salée). En dessous = lac d'eau douce. |
| **Seuil de lac** (`lake_threshold`) | 5.0 | > 0 | Accumulation de flux minimale pour qu'une dépression crée un lac plutôt qu'une simple flaque. |
| **Itérations de rivières** (`river_iterations`) | 2000 | > 0 | Nombre de pas de simulation du tracé des rivières. Plus d'itérations = réseau fluvial plus long et ramifié. |
| **Seuil d'affluent** (`river_affluent_threshold`) | 50.0 | > 0 | Accumulation de flux minimale pour qu'un ruisseau soit dessiné comme affluent sur la carte. |
| **Seuil de rivière** (`river_threshold`) | 200.0 | > 0 | Accumulation minimale pour une rivière principale. |
| **Seuil de fleuve** (`river_fleuve_threshold`) | 800.0 | > 0 | Accumulation minimale pour un grand fleuve (dessiné plus épais sur la carte). |

---

### 3.5 Nuages

| Paramètre | Défaut | Plage | Rôle |
|-----------|--------|-------|------|
| **Couverture nuageuse** (`cloud_coverage`) | 50% | 0–100% | Fraction de la surface couverte par des nuages. `100%` = planète totalement voilée (type Vénus). |
| **Densité nuageuse** (`cloud_density`) | 80% | 0–100% | Opacité des nuages sur la carte de prévisualisation finale. N'affecte pas la simulation climatique, uniquement le rendu visuel. |

---

### 3.6 Régions terrestres

La carte des régions divise la surface terrestre en territoires distincts (analogue à des États ou provinces géologiques) en utilisant un algorithme de Voronoï pondéré.

| Paramètre | Défaut | Rôle |
|-----------|--------|------|
| **Nombre de régions** (`nb_cases_regions`) | 50 | Nombre de régions terrestres générées. Un grand nombre crée des territoires plus petits et plus variés. |
| **Coût terrain plat** (`region_cost_flat`) | 1.0 | Résistance à la traversée d'une zone plate. Un coût faible étend facilement les régions sur les plaines. |
| **Coût terrain vallonné** (`region_cost_hill`) | 2.0 | Résistance à la traversée d'une zone montagneuse. Un coût élevé fait des montagnes des frontières naturelles. |
| **Coût rivière** (`region_cost_river`) | 3.0 | Résistance à la traversée d'une rivière. Un coût très élevé fait des rivières des frontières quasi-infranchissables. |
| **Seuil rivière** (`region_river_threshold`) | 1.0 | Flux minimal d'une rivière pour qu'elle soit considérée comme frontière géographique. |
| **Variation de budget** (`region_budget_variation`) | 0.5 | Variabilité de la taille entre les régions. `0` = régions égales, `1` = grandes disparités de taille. |
| **Force du bruit** (`region_noise_strength`) | 0.5 | Irrégularité des frontières. `0` = frontières géométriques nettes, `1` = frontières organiques très fracturées. |

---

### 3.7 Régions océaniques

Fonctionne de manière identique aux régions terrestres, mais pour les zones sous-marines.

| Paramètre | Défaut | Rôle |
|-----------|--------|------|
| **Nombre de régions océaniques** (`nb_cases_ocean_regions`) | 100 | Nombre de régions sous-marines. |
| **Coût fond plat** (`ocean_cost_flat`) | 1.0 | Résistance à traverser une zone de profondeur uniforme. |
| **Coût fond profond** (`ocean_cost_deeper`) | 2.0 | Résistance à traverser une zone plus profonde (fosses, abysses). Fait des dorsales et fosses des frontières naturelles. |
| **Force du bruit océanique** (`ocean_noise_strength`) | 0.5 | Irrégularité des frontières sous-marines. |

---

### 3.8 Ressources

| Paramètre | Défaut | Plage | Rôle |
|-----------|--------|-------|------|
| **Probabilité pétrole** (`petrole_probability`) | 2.5% | 0–100% | Chance qu'une zone sédimentaire génère un gisement pétrolier. Le pétrole se forme historiquement là où l'eau a stagné avec de la matière organique. |
| **Taille dépôt pétrole** (`petrole_deposit_size`) | 200 km² | > 0 | Surface moyenne d'un gisement pétrolier. |
| **Richesse globale** (`global_richness`) | 1.0 | 0.0–∞ | Multiplicateur global de l'abondance de toutes les ressources minérales. `2.0` = deux fois plus de ressources, `0.5` = planète pauvre. |

---

## 4. Système de Température

La température est calculée en trois passes successives pour chaque pixel de la carte :

### 4.1 Gradient latitudinal
La température de base dépend de la latitude (distance à l'équateur) :
- **Équateur** : `avg_temperature + 8°C` (bonus solaire)
- **Pôles** : `avg_temperature - 35°C` (refroidissement polaire)

### 4.2 Gradient altitudinal (taux adiabatique)
Chaque 1000 mètres d'altitude modifie la température de :
- **Au-dessus du niveau de la mer** : **−6.5 °C/km** *(taux adiabatique réaliste)*
- **Sous le niveau de la mer** : **+2.0 °C/km** (les profondeurs océaniques restent fraîches)

### 4.3 Atténuation océanique
Les zones océaniques bénéficient d'une inertie thermique plus forte (facteur 0.8), réduisant les extrêmes thermiques près des côtes.

### 4.4 Bruit fBm régional
Un bruit fractal ajoute des variations régionales naturelles (anomalies thermiques : courants chauds, zones continentales sèches).

### Palette de couleurs Température

| Plage (°C) | Couleur | Description |
|:-----------:|---------|-------------|
| ≤ −200 | 🔵 Bleu électrique | Cryogène extrême |
| −150 | 🟣 Violet foncé | Azote liquide |
| −50 | 🔵 Bleu-violet | Intense froid polaire |
| −15 à 0 | 🔵 Bleu gris | Froid tempéré |
| +5 à +20 | 🟢 Vert | Tempéré (habitable) |
| +25 à +30 | 🟡 Jaune-or | Chaud tropical |
| +35 à +50 | 🟠 Orange | Très chaud, aride |
| +50 à +100 | 🔴 Rouge | Extrême chaleur |
| +150 à +200 | 🩷 Rose-rouge | Incandescent |

---

## 5. Système de Précipitations

Les précipitations sont exprimées en valeur normalisée **[0.0 – 1.0]** :
- `0.0` = désert absolu (aucune pluie)
- `1.0` = saturation maximale (forêt tropicale ou océan permanent)

### 5.1 Zones climatiques (cellules de Hadley)
La simulation reproduit les grandes cellules atmosphériques :

| Latitude | Type climatique | Précipitations attendues |
|----------|----------------|:------------------------:|
| 0° (Équateur) | Zone de convergence intertropicale (ZCIT) | 0.7 – 1.0 |
| ±15° – 30° | Zones subtropicales (Hadley descendant) | 0.0 – 0.3 |
| ±45° – 60° | Zones tempérées (fronts actifs) | 0.4 – 0.8 |
| ±75° – 90° (Pôles) | Déserts polaires (air très sec) | 0.0 – 0.25 |

### 5.2 Influence de l'altitude
- En dessous du niveau de la mer : humidité relative += boost océanique
- Au-dessus de 2000 m : ombre pluviométrique côté sous-le-vent des montagnes

### 5.3 Paramètre de contrôle
Le paramètre **Humidité globale** (`global_humidity`) décale linéairement l'ensemble de la distribution de précipitations :
- `0%` : planète globalement aride (type Mars)
- `50%` : planète terrestre équilibrée
- `100%` : planète saturée d'humidité (type monde-océan)

### Palette de couleurs Précipitations

| Valeur | Couleur | Description |
|:------:|---------|-------------|
| 0.0 | 🟣 Magenta vif | Désert absolu |
| 0.1 – 0.2 | 🟣 Violet foncé | Très aride |
| 0.3 – 0.4 | 🔵 Bleu-violet | Semi-aride |
| 0.5 | 🔵 Bleu moyen | Modéré |
| 0.6 – 0.7 | 🔵 Bleu vif | Humide |
| 0.8 – 0.9 | 🔵 Bleu royal | Très humide |
| 1.0 | 🔵 Bleu clair | Saturé |

---

## 6. Classification des Biomes

Les biomes sont déterminés par le **Diagramme de Whittaker** :  
chaque pixel est classé selon sa **température (°C)**, son **humidité (0–1)** et son **élévation (m)**.

Le shader sélectionne le biome dont le centre de plage est le plus proche des valeurs climatiques du pixel (score de proximité). Un bruit Simplex léger rend les frontières organiques.

---

### 6.1 Planète Terrienne (Type 0)

#### Océans & Bathymétrie

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Abysses** | −21 à +100°C | 0.0 – 1.0 | < −6000 m | Fosses abyssales, fond marin ultra-profond |
| **Plaine Abyssale** | −21 à +100°C | 0.0 – 1.0 | −6000 à −2000 m | Fond océanique profond plat |
| **Océan Profond** | −21 à +100°C | 0.0 – 1.0 | −2000 à −200 m | Océan intermédiaire |
| **Plateau Continental** | −21 à +100°C | 0.0 – 1.0 | −200 à 0 m | Socle continental immergé |

#### Côtes & Eaux peu profondes

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Récif Corallien** | +24 à +35°C | 0.0 – 1.0 | −50 à 0 m | Eaux chaudes tropicales peu profondes |
| **Lagon Tropical** | +24 à +35°C | 0.0 – 1.0 | −20 à 0 m | Baie fermée chaude et peu profonde |
| **Fjord Glacé** | −20 à +5°C | 0.0 – 1.0 | −200 à 0 m | Bras de mer froid d'origine glaciaire |
| **Littoral / Plage** | +10 à +35°C | 0.0 – 1.0 | −50 à +5 m | Zone côtière sableuse (eau salée) |
| **Mangrove (Salée)** | +25 à +40°C | 0.6 – 1.0 | −20 à +5 m | Forêt de palétuvier littorale tropicale |
| **Delta Fluvial** | +15 à +35°C | 0.7 – 1.0 | −50 à +5 m | Embouchure de rivière, eaux mélangées |

#### Terres — Climats froids & polaires

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Calotte Glaciaire** | < −15°C | 0.4 – 1.0 | Toute | Glace permanente, très froid + humide |
| **Désert Polaire** | < −15°C | 0.0 – 0.4 | Toute | Froid extrême mais sec (type Antarctique) |
| **Toundra** | −15 à 0°C | 0.0 – 0.25 | < 2500 m | Sol gelé en permanence, végétation rase |
| **Toundra Alpine** | −30 à 0°C | 0.0 – 0.25 | > 2500 m | Toundra en altitude |
| **Taïga (Forêt Boréale)** | −15 à +15°C | 0.25 – 1.0 | Toute | Forêt de conifères froide |
| **Prairie Alpine (Alpage)** | −5 à +15°C | 0.0 – 0.25 | 1500–25000 m | Prairies d'altitude sèches |
| **Forêt de montagne** | −15 à +15°C | 0.25 – 1.0 | 800–25000 m | Forêt froide en altitude |

#### Terres — Climats tempérés

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Forêt Tempérée (Décidue)** | +5 à +25°C | 0.3 – 0.8 | Toute | Feuillus à feuilles caduques |
| **Forêt de Séquoias** | +5 à +25°C | 0.5 – 0.8 | Toute | Conifères géants, humidité modérée-forte |
| **Forêt Humide (Rainforest)** | +5 à +30°C | 0.5 – 1.0 | Toute | Forêt pluviale dense |
| **Prairie Verdoyante** | +10 à +25°C | 0.3 – 0.6 | Toute | Prairies tempérées, type Europe |
| **Maquis Méditerranéen** | +30 à +45°C | 0.4 – 0.7 | Toute | Garrigue chaleureuse, été sec |
| **Steppes sèches** | −5 à +20°C | 0.0 – 0.3 | Toute | Herbes rases, peu de pluie |
| **Steppes tempérées** | −5 à +20°C | 0.3 – 0.5 | Toute | Prairies mi-sèches, type Kazakhstan |
| **Marécage Tempéré** | +5 à +100°C | 0.7 – 1.0 | Toute | Zone humide à eau douce |

#### Terres — Climats chauds & arides

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Jungle Tropicale** | +18 à +45°C | 0.7 – 1.0 | Toute | Forêt équatoriale dense et chaude |
| **Savane** | +18 à +45°C | 0.2 – 0.3 | Toute | Herbes hautes, arbres épars, saisons marquées |
| **Brousse (Bush)** | +18 à +45°C | 0.3 – 0.5 | Toute | Végétation arbustive clairsemée |
| **Désert semi-aride** | +15 à +50°C | 0.0 – 0.3 | Toute | Transition désert/steppe |
| **Désert de Sable** | +22 à +55°C | 0.0 – 0.2 | Toute | Erg, dunes de sable, chaleur extrême |
| **Désert Rocheux (Badlands)** | +15 à +70°C | 0.0 – 0.2 | Toute | Roche nue érodée, ravines |
| **Désert Extrême** | +45 à +200°C | 0.0 – 1.0 | Toute | Chaleur létale absolue |

#### Eaux douces intérieures

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Oasis** | 0 à +100°C | 0.0 – 0.3 | Toute | Eau douce en zone désertique |
| **Cénote (Gouffre)** | +20 à +100°C | 0.5 – 0.8 | < 0 m | Gouffre calcaire rempli d'eau douce |
| **Bayou (Marais Chaud)** | +25 à +100°C | 0.8 – 1.0 | Toute | Marais chaud eau douce, type Louisiane |
| **Rivière** | 0 à +100°C | 0.0 – 1.0 | Toute | Cours d'eau (tracé par river_map) |
| **Lac d'eau douce** | 0 à +100°C | 0.0 – 1.0 | Toute | Étendue d'eau intérieure |
| **Lac gelé** | −50 à 0°C | 0.0 – 1.0 | Toute | Lac recouvert de glace |
| **Rivière glaciaire** | −50 à 0°C | 0.0 – 1.0 | Toute | Flux d'eau glaciaire |

---

### 6.2 Planète Toxique (Type 1)

*Atmosphère dense et acide, analogue à Vénus ou une planète industrialisée polluée.*

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Océan Acide** | +10 à +80°C | 0.0 – 1.0 | < −500 m | Mer d'acide sulfurique / chlorhydrique |
| **Lagon de Boue Toxique** | +20 à +60°C | 0.0 – 1.0 | −500 à 0 m | Boues acides peu profondes |
| **Désert de Soufre** | −50 à +60°C | 0.0 – 0.2 | Toute | Dépôts soufrés secs |
| **Désert Extrême de Soufre** | +50 à +200°C | 0.0 – 1.0 | Toute | Soufre fondu, chaleur extrême |
| **Forêt Fongique** | +20 à +50°C | 0.5 – 1.0 | Toute | Champignons géants, spores toxiques |
| **Plaines de Spores** | 0 à +20°C | 0.5 – 1.0 | Toute | Prairies basses de spores |
| **Marécages Acides** | +20 à +60°C | 0.7 – 1.0 | Toute | Marais d'acide et boues |
| **Glacier Vert (Méthane)** | −200 à −50°C | 0.0 – 1.0 | Toute | Glace de méthane/ammoniac |
| **Plaines Venteuses Toxiques** | 0 à +50°C | 0.0 – 0.5 | Toute | Plaines balayées par des vents chargés de gaz |
| **Cratères Acides** | −50 à 0°C | 0.2 – 1.0 | Toute | Cratères remplis de liquide acide |
| **Rivière Acide** | −50 à +80°C | 0.0 – 1.0 | Toute | Cours d'eau acide |
| **Lac d'Acide** | −50 à +90°C | 0.0 – 1.0 | Toute | Lac d'acide stagnant |

---

### 6.3 Planète Volcanique (Type 2)

*Surface en fusion partielle, analogue à Io (lune de Jupiter) ou Mustafar.*

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Océan de Magma** | +800 à +2000°C | 0.0 – 1.0 | < −1000 m | Mer de roche fondue |
| **Mer de Lave en Fusion** | +600 à +1500°C | 0.0 – 1.0 | −1000 à 0 m | Coulées de lave peu profondes |
| **Croûte Basaltique Refroidie** | +100 à +400°C | 0.0 – 1.0 | −200 à +100 m | Lave solidifiée, surface vitrifiée |
| **Glace Volcanique** | −200 à 0°C | 0.0 – 1.0 | > 0 m | Calotte glaciaire sur terrain volcanique froid |
| **Toundra Volcanique** | 0 à +50°C | 0.3 – 1.0 | > 0 m | Zone froide avec activité géothermique |
| **Plaines de Cendres** | +20 à +200°C | 0.0 – 0.4 | 0 à +2000 m | Retombées de cendres, terrain mou |
| **Champs de Geysers** | +100 à +300°C | 0.4 – 1.0 | 500 à 1500 m | Geysers actifs et champs hydrothermaux |
| **Volcan Actif (Sommet)** | +200 à +1000°C | 0.0 – 1.0 | > 2000 m | Cône volcanique en éruption |
| **Obsidienne** | +50 à +200°C | 0.0 – 1.0 | 1000 à 3000 m | Verre volcanique noir solidifié |
| **Désert de Soufre Jaune** | +50 à +150°C | 0.0 – 0.3 | 500 à 2500 m | Dépôts de soufre émis par les volcans |
| **Caldeira Fumante** | +300 à +800°C | 0.0 – 0.5 | Toute | Cratère volcanique principal en activité |
| **Rivière de Lave** | +100 à +1500°C | 0.0 – 1.0 | Toute | Coulée de lave en flux |
| **Lac de Lave** | +100 à +1200°C | 0.0 – 1.0 | Toute | Lac de lave stagnante dans une caldeira |

---

### 6.4 Sans Atmosphère (Type 3)

*Surface exposée au vide spatial, analogue à la Lune ou Mercure. Pas d'eau liquide ni d'érosion.*

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Mare (Mer Lunaire)** | −200 à +200°C | 0.0 – 1.0 | < −1000 m | Ancienne plaine basaltique (mare lunaire) |
| **Régolithe Gris** | −200 à +200°C | 0.0 – 1.0 | −1000 à +1000 m | Sol pulvérisé par les impacts millénaires |
| **Cratère d'Impact** | −200 à +200°C | 0.0 – 1.0 | −2000 à −500 m | Dépression créée par un météorite |
| **Hauts Plateaux Lunaires** | −200 à +200°C | 0.0 – 1.0 | > 1000 m | Remparts surélevés et terrains anciens |
| **Glace de Cratère Polaire** | < −150°C | 0.0 – 1.0 | −2000 à 0 m | Glace d'eau permanente dans les cratères polaires ombragés |

---

### 6.5 Planète Morte (Type 4)

*Planète post-apocalyptique, irradiée ou en fin de vie biologique.*

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Océan Mort (Gris)** | −21 à +40°C | 0.0 – 1.0 | < −200 m | Mer polluée, eau stagnante et sombre |
| **Marécage Luminescent** | +10 à +30°C | 0.6 – 1.0 | −200 à +50 m | Marais pollué et radioactif, lueur verdâtre |
| **Terres Désolées (Wasteland)** | −20 à +50°C | 0.0 – 0.4 | 0 à 2000 m | Terrain nu et désolé |
| **Désert de Sel** | 0 à +60°C | 0.0 – 0.2 | −500 à +500 m | Ancienne mer asséchée, croûte de sel |
| **Forêt Morte (Arbres Noirs)** | −10 à +40°C | 0.3 – 0.7 | 0 à 1500 m | Squelettes d'arbres calcinés |
| **Cratère Nucléaire** | −50 à +100°C | 0.0 – 1.0 | −500 à +500 m | Zone d'impact/explosion nucléaire, vitrifiée |
| **Plaines de Cendres Grises** | −30 à +30°C | 0.0 – 0.3 | 0 à 3000 m | Cendres issues d'une extinction massive |
| **Désert Radioactif** | +30 à +200°C | 0.0 – 0.4 | Toute | Zone de forte radioactivité, sol orange |
| **Montagnes Mortes** | −200 à +200°C | 0.0 – 1.0 | > 3000 m | Reliefs pierreux sans vie |
| **Rivière de Boue** | −21 à +50°C | 0.0 – 1.0 | Toute | Cours d'eau de boue et de déchets |
| **Rivière Polluée** | −21 à +50°C | 0.0 – 1.0 | Toute | Cours d'eau chimiquement contaminé |
| **Lac Irradié** | −21 à +50°C | 0.0 – 1.0 | Toute | Étendue d'eau radioactive |

---

### 6.6 Planète Stérile (Type 5)

*Planète rocheuse géologiquement morte, sans eau ni atmosphère significative (type Mars passif).*

| Biome | Température | Humidité | Élévation | Description |
|-------|:-----------:|:--------:|:---------:|-------------|
| **Désert Stérile** | +50 à +200°C | 0.0 – 1.0 | −500 à +500 m | Terrain cuisant nu |
| **Plaine Rocheuse** | −50 à +50°C | 0.0 – 1.0 | −500 à +500 m | Plaine de roche nue |
| **Montagnes Rocheuses** | −200 à +200°C | 0.0 – 1.0 | > 1000 m | Chaînes de montagne rocheuses |
| **Vallées Profondes** | −200 à +200°C | 0.0 – 1.0 | < −500 m | Canyons et vallées d'érosion ancienne |
| **Désert de Pierre** | −150 à 0°C | 0.0 – 1.0 | Toute | Désert de pierres et galets |
| **Glaciers Stériles** | < −50°C | 0.0 – 1.0 | > 0 m | Calottes de CO₂ ou d'eau gelée |
| **Plateaux Érodés** | −200 à +200°C | 0.0 – 1.0 | 500 à 1000 m | Mesas et plateaux de roche érodée |
| **Cratères Secs** | +50 à +150°C | 0.0 – 1.0 | Toute | Impacts anciens, sans eau ni végétation |

---

## 7. Cartes générées

| Nom de fichier | Clé interne | Description |
|----------------|-------------|-------------|
| `topographie_map.png` | `MAP_TOPOGRAPHIE` | Carte d'élévation colorée selon `COULEURS_ELEVATIONS` |
| `topographie_map_grey.png` | `MAP_TOPOGRAPHIE_GREY` | Carte d'élévation en niveaux de gris (plus sombre = plus bas) |
| `eaux_map.png` | `MAP_EAUX` | Masque eau : blanc = océan, noir = terre |
| `plaques_map.png` | `MAP_PLAQUES` | Coloration des plaques tectoniques |
| `plaques_bordures_map.png` | `MAP_PLAQUES_BORDURES` | Frontières de plaques tectoniques |
| `temperature_map.png` | `MAP_TEMPERATURE` *(via preview)* | Carte de température, palette violette-verte-rouge |
| `precipitation_map.png` | `MAP_PRECIPITATION` | Carte de précipitations, palette magenta-bleue |
| `clouds_map.png` | `MAP_CLOUDS` | Distribution des nuages |
| `ice_caps_map.png` | `MAP_ICE` | Calottes glaciaires et zones de glace |
| `water_map.png` | `MAP_WATER` | Eau de surface (lacs, mers, rivières) |
| `river_map.png` | `MAP_RIVERS` | Réseau hydrographique (rivières et fleuves) |
| `biome_map.png` | `MAP_BIOMES` | Classification biomatique colorée |
| `region_map.png` | `MAP_REGIONS` | Régions terrestres (Voronoï pondéré) |
| `ocean_region_map.png` | `MAP_OCEAN_REGIONS` | Régions sous-marines |
| `petrole_map.png` | `MAP_PETROLE` | Gisements pétroliers |
| `ressource_map.png` | `MAP_RESOURCES` | Toutes les ressources minérales |
| `final_map.png` | `MAP_FINAL` | Rendu final composite avec végétation réaliste |
| `preview.png` | `MAP_PREVIEW` | Aperçu rapide pour l'interface |

---

## 8. Système de Ressources

Les ressources minérales sont générées selon leur abondance réelle dans la croûte terrestre. La génération est indépendante biome par biome.

### Catégorie 1 — Ultra-abondants (> 2% de la croûte)

| Ressource | Probabilité relative | Taille moy. gisement |
|-----------|:--------------------:|:-------------------:|
| Silicium | 27.7% | 1000 km² |
| Aluminium | 8.1% | 800 km² |
| Fer | 5.0% | 700 km² |
| Calcium | 3.6% | 650 km² |
| Magnésium | 2.1% | 550 km² |
| Potassium | 2.0% | 500 km² |

### Catégorie 2 — Très communs (0.1% – 1%)

| Ressource | Probabilité relative | Taille moy. gisement |
|-----------|:--------------------:|:-------------------:|
| Titane | 0.56% | 450 km² |
| Phosphate | 0.1% | 400 km² |
| Manganèse | 0.1% | 380 km² |
| Soufre | 0.1% | 400 km² |
| Charbon | 0.08% | 700 km² |
| Calcaire | 0.08% | 700 km² |

### Catégorie 3 — Communs (100 – 500 ppm)

Baryum, Strontium, Zirconium, Vanadium, Chrome, Nickel, Zinc, Cuivre, Sel, Fluorine  
*(probabilités : 0.01% – 0.04%, gisements de 150 à 280 km²)*

### Catégorie 4 — Modérément rares (10 – 50 ppm)

Cobalt, Lithium, Niobium, Plomb  
*(probabilités : ~0.002%, gisements de 80 à 100 km²)*

> Le multiplicateur **Richesse globale** (`global_richness`) s'applique à toutes les catégories uniformément.  
> Les **gisements pétroliers** sont générés séparément avec les paramètres `petrole_probability` et `petrole_deposit_size`.

---

*Documentation générée pour PlanetGenerator Final-Upgrade — Godot 4.x / Vulkan Compute Shaders*  
*Dernière mise à jour : février 2026*
