# ISSUE : Problèmes de Génération des Plaques Tectoniques

**Date** : 5 janvier 2026  
**Commit affecté** : 9dc6812  
**Statut** : 🔄 **CORRECTION v2** (5 janvier 2026)

---

## 🔄 CORRECTIONS v2 - Analyse approfondie des images

### Problèmes identifiés sur les images post-correction v1 :

| Symptôme Visuel | Cause Racine | Correction v2 |
|-----------------|--------------|---------------|
| **Bandes verticales** sur heightmap grise | `cy = float(pixel.y)` non normalisé → asymétrie d'échelle | `cy = (y/h - 0.5) * radius * 2` |
| **Compartiments/zones distinctes** | `plateElevation` ajouté directement sans transition | Interpolation douce avec `smoothstep` + valeurs réduites |
| **Plaques visibles sur topographie** | Influence plateElevation trop forte (-600 à +500m) | Réduit à (-200 à +200m) subtil |
| **Fréquences de bruit incorrectes** | `base_freq = 0.008` vs legacy `2.0/circ` ≈ 0.002 | Fréquences calculées depuis `cylinder_radius` |

---

## 📐 Correction 1 : Coordonnées Cylindriques (CRITIQUE)

### Avant (BOGUÉ) :
```glsl
float cx = cos(angle) * cylinder_radius;  // -163 à +163
float cz = sin(angle) * cylinder_radius;  // -163 à +163
float cy = float(pixel.y);                 // 0 à 512 ← ASYMÉTRIE !
```

Le bruit voit des coordonnées `(-163, 0→512, -163)` → **étirement vertical 3x** → bandes.

### Après (CORRIGÉ) :
```glsl
float cx = cos(angle) * cylinder_radius;
float cz = sin(angle) * cylinder_radius;
float cy = (float(pixel.y) / float(h) - 0.5) * cylinder_radius * 2.0;
// Maintenant cy va de -radius à +radius comme cx/cz
```

---

## 📐 Correction 2 : Transition Douce entre Plaques

### Avant :
```glsl
float plateElevation = getPlateBaseElevation(plateId, ...);  // Saut brutal
```

### Après :
```glsl
float plateElev1 = getPlateBaseElevation(plateId, ...);
float plateElev2 = getPlateBaseElevation(secondPlateId, ...);
float blendFactor = smoothstep(0.0, 0.3, borderStrength);
float plateElevation = mix(plateElev1, (plateElev1 + plateElev2) * 0.5, blendFactor);
```

---

## 📐 Correction 3 : Élévations de Plaques Réduites

| Type | Avant | Après |
|------|-------|-------|
| Océanique | -600 à -200m | -200 à -50m |
| Continental | +100 à +500m | +50 à +200m |

Le bruit fBm (±3500m) domine maintenant largement.

---

## 📐 Correction 4 : Fréquences de Bruit Legacy

```glsl
// Avant (arbitraire)
float base_freq = 0.008;

// Après (basé sur legacy)
float base_freq = 2.0 / params.cylinder_radius;      // ~0.004
float detail_freq = 1.504 / params.cylinder_radius;  // ~0.003
float tectonic_freq = 0.4 / params.cylinder_radius;  // ~0.0008
```

---

## 📐 Correction 5 : Facteur de Décroissance Exponentielle

```glsl
// Avant : facteur 80 pour distances UV
float borderStrength = exp(-borderDist * 80.0);

// Après : facteur 150 pour distances en RADIANS (geodesicDistance)
float borderStrength = exp(-borderDist * 150.0);
// + seuil relevé de 0.05 à 0.1
```

---

## 📋 Résumé des Symptômes (AVANT correction)

Les plaques tectoniques générées présentent plusieurs défauts majeurs qui compromettent le réalisme de la simulation :

1. **Bordures trop larges** : Les frontières de plaques occupent une portion excessive de la surface
2. **Remplissage intérieur** : Les bordures "envahissent" l'intérieur des plaques au lieu de rester localisées
3. **Visibilité sur carte grey** : Les frontières de plaques sont nettement visibles sur la heightmap grise, révélant un artefact non naturel
4. **Artefacts quadrilatéraux** : Présence de compartiments/grilles visibles dans la génération
5. **Frontières trop rectilignes** : Les bordures de plaques sont trop droites, donnant un aspect artificiel géométrique
6. **❌ CRITIQUE : Projection non équirectangulaire** : La map générée n'est **PAS** équirectangulaire - présence de discontinuités et d'artefacts de grille révélant un problème de projection cylindrique

---

## 🔍 Analyse Technique des Causes

### 1. **Problème : Bordures Trop Larges**

#### Code actuel (ligne 334) :
```glsl
// Bordures ÉTROITES : smoothstep de 0 à 0.025 (était 0.15)
float borderStrength = 1.0 - smoothstep(0.0, 0.025, borderDist);
```

#### Cause :
Le paramètre `0.025` dans `smoothstep` définit la largeur de la zone de transition. En coordonnées UV normalisées [0,1], `0.025` représente **2,5% de la largeur totale** de la carte.

Pour une map de 2048 pixels de largeur :
- `0.025 * 2048 = 51.2 pixels` de largeur de bordure

Cette valeur est **beaucoup trop grande** pour une frontière tectonique réaliste.

#### Valeur recommandée :
```glsl
float borderStrength = 1.0 - smoothstep(0.0, 0.003, borderDist);
// 0.003 = ~6 pixels sur une map 2048x1024
```

---

### 2. **Problème : Remplissage Intérieur des Plaques**

#### Code actuel (lignes 384-404) :
```glsl
if (borderStrength > 0.01) {
    // Type de frontière basé sur les types de plaques
    if (!isOceanic && !isSecondOceanic) {
        tectonicUplift = borderStrength * 1500.0;  // ← TROP FORT
    }
    // ...
}
```

#### Causes multiples :

1. **Seuil trop bas** : `borderStrength > 0.01` active l'uplift tectonique même loin des vraies frontières
2. **Facteurs multiplicateurs trop élevés** : `1500.0`, `1000.0`, `800.0` créent des reliefs massifs
3. **Pas de décroissance exponentielle** : L'effet est linéaire au lieu de s'atténuer rapidement

#### Impact :
L'uplift tectonique "déborde" au-delà de la frontière réelle, créant un effet de "halo" autour des bordures qui remplit progressivement l'intérieur des plaques.

---

### 3. **Problème : Visibilité sur Carte Grey (Artefact Visible)**

#### Cause fondamentale :
Les bordures de plaques modifient **directement** la heightmap via `tectonicUplift`, qui s'ajoute à l'élévation finale :

```glsl
float elevation = plateElevation + noiseElevation + tectonicUplift + ...;
```

Cela crée un **biais systématique** : toutes les frontières de plaques deviennent des zones de haute altitude, indépendamment du contexte géologique local.

#### Problème conceptuel :
Dans la réalité, les plaques tectoniques ne créent pas **toujours** des montagnes aux frontières :
- Frontières convergentes (collision) → montagnes ✓
- Frontières divergentes (séparation) → rifts/dorsales ✗ (devrait abaisser)
- Frontières transformantes (glissement) → pas de relief notable ✗

Le code actuel ne différencie pas correctement ces cas, et applique presque toujours un uplift positif.

---

### 4. **Problème : Artefacts Quadrilatéraux / Compartiments**

#### Observation :
Des lignes droites ou motifs en grille apparaissent dans la génération, révélant une structure sous-jacente artificielle.

#### Cause probable : Absence de perturbation du Voronoi

Le code actuel utilise un **Voronoi pur** (ligne 306) :

```glsl
vec4 findClosestPlate(vec2 uv, uint seed) {
    // ...
    for (int i = 0; i < NUM_PLATES; i++) {
        vec2 center = getPlateCenter(i, seed);
        
        // Distance DIRECTE sans perturbation
        float dx = cyclicDistanceX(uv.x, center.x, 1.0);
        float dy = uv.y - center.y;
        float dist = sqrt(dx * dx + dy * dy);
        // ...
    }
}
```

#### Problème :
Un diagramme de Voronoi non perturbé produit naturellement des **segments rectilignes** entre les cellules. Ces segments sont mathématiquement parfaits (équidistance aux deux centres les plus proches), ce qui crée :
- Des frontières droites géométriques
- Des intersections à 120° (points triples) très régulières
- Un aspect "tuiles hexagonales" artificiel

#### Solution requise : **Domain Warping**
Perturber les coordonnées UV **avant** de calculer les distances Voronoi :

```glsl
// Ajouter un décalage basé sur du bruit
vec2 warpedUV = uv + fbm2D(uv * warp_frequency) * warp_amplitude;
// Puis calculer Voronoi sur warpedUV au lieu de uv
```

---

### 5. **Problème : Frontières Trop Rectilignes**

#### Cause :
Identique au problème #4 - absence de domain warping.

#### Impact visuel :
Les plaques ressemblent à des **polygones découpés à la règle** plutôt qu'à des formations géologiques naturelles. Les frontières réelles des plaques terrestres sont :
- Sinueuses (ex : dorsale médio-atlantique)
- Fractales (détails à plusieurs échelles)
- Uniques (chaque frontière a sa propre "signature")

#### Comparaison avec version legacy :

**Legacy CPU (ElevationMapGenerator.gd)** :
- Utilisait des bruits de bande (`abs(noise) > 0.45 && < 0.55`) pour créer des structures linéaires **organiques**
- Les "ridges" tectoniques étaient créés par perturbation de bruit, pas par géométrie Voronoi

**Version GPU actuelle** :
- Voronoi géométrique pur → lignes droites
- Pas de perturbation → frontières régulières
- Pas d'unicité → toutes les frontières se ressemblent

---

### 6. **Problème CRITIQUE : Projection Non Équirectangulaire**

#### Observation visuelle :
Sur l'image fournie (heightmap grey), on observe clairement :
- **Des lignes verticales** régulières qui divisent la carte en colonnes
- **Des compartiments rectangulaires** visibles, créant un effet de "grille"
- **Des discontinuités** aux bords gauche/droite (wrap X défaillant)
- **Des déformations** qui ne correspondent pas à une projection équirectangulaire valide

#### Cause identifiée : Incohérence entre Voronoi UV et coordonnées cylindriques

Le shader utilise **DEUX systèmes de coordonnées différents** :

1. **Pour le Voronoi (plaques)** : coordonnées UV normalisées [0,1] × [0,1]
```glsl
vec2 uv = vec2(float(pixel.x) / float(params.width), 
               float(pixel.y) / float(params.height));
vec4 plateInfo = findClosestPlate(uv, params.seed);
```

2. **Pour le bruit (relief)** : coordonnées cylindriques 3D
```glsl
vec3 coords = getCylindricalCoords(pixel, params.width, params.height, params.cylinder_radius);
float noise1 = fbm(coords * base_freq, ...);
```

#### Problème conceptuel :
Le Voronoi en UV cartésien **ne respecte pas la géométrie sphérique** :
- Distance euclidienne 2D ≠ distance géodésique sur une sphère
- Le wrap cyclique sur X est approximatif (`cyclicDistanceX`)
- Les pôles (y=0 et y=height) ne sont pas traités correctement
- Résultat : **discontinuités visibles** et artefacts de projection

#### Impact :
- La map n'est **pas seamless** (couture visible au wrap X)
- Les plaques ne "collent" pas correctement sur une sphère 3D
- Incohérence entre le relief (correct) et les plaques (incorrect)
- **Impossible à mapper proprement sur une planète 3D**

#### Solution requise : Voronoi en coordonnées sphériques

Au lieu de calculer le Voronoi en UV plat, il faut :

```glsl
// Convertir UV en coordonnées sphériques (lon, lat)
float lon = uv.x * TAU;  // [0, 2π]
float lat = (uv.y - 0.5) * PI;  // [-π/2, π/2]

// Convertir en vecteur 3D sur la sphère unitaire
vec3 pointOnSphere = vec3(
    cos(lat) * cos(lon),
    sin(lat),
    cos(lat) * sin(lon)
);

// Pour chaque centre de plaque, convertir aussi en 3D
vec3 plateCenter3D = sphericalToCartesian(getPlateCenter(i, seed));

// Distance GÉODÉSIQUE (arc de grand cercle)
float geodesicDist = acos(dot(pointOnSphere, plateCenter3D));
```

Cela garantit :
- ✅ Seamless naturel (la sphère n'a pas de bord)
- ✅ Pas de déformation aux pôles
- ✅ Distances correctes partout
- ✅ Compatible avec projection équirectangulaire

#### Alternative plus simple (compromis) :
Si le Voronoi sphérique est trop coûteux, au minimum :
1. Utiliser le **même système de coordonnées** pour plaques ET bruit (cylindrique)
2. Implémenter un wrap X **correct** dans `findClosestPlate`
3. Traiter les pôles spécifiquement (y=0 et y=height)

---

## 🛠️ Solutions Proposées

### Solution 1 : Réduire drastiquement la largeur des bordures

```glsl
// AVANT
float borderStrength = 1.0 - smoothstep(0.0, 0.025, borderDist);

// APRÈS
float borderStrength = 1.0 - smoothstep(0.0, 0.002, borderDist);
// Bordure de ~4 pixels sur map 2048x1024
```

---

### Solution 2 : Implémenter Domain Warping pour Voronoi organique

```glsl
// Fonction de bruit 2D pour la perturbation
vec2 noise2D(vec2 p, uint seed) {
    // Retourne vec2 de bruit entre [-1, 1]
    // (implémenter avec hash + interpolation)
}

// Perturbation multi-octave
vec2 domainWarp(vec2 uv, uint seed) {
    vec2 offset = vec2(0.0);
    float amplitude = 0.08;  // Amplitude de déformation
    float frequency = 5.0;   // Fréquence de base
    
    // 3 octaves pour des bordures organiques
    for (int i = 0; i < 3; i++) {
        offset += noise2D(uv * frequency, seed + uint(i) * 1000u) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return uv + offset;
}

// Utilisation dans findClosestPlate
vec4 findClosestPlate(vec2 uv, uint seed) {
    // PERTURBER LES COORDONNÉES AVANT VORONOI
    vec2 warpedUV = domainWarp(uv, seed);
    
    // Puis calcul Voronoi normal sur warpedUV
    for (int i = 0; i < NUM_PLATES; i++) {
        vec2 center = getPlateCenter(i, seed);
        float dx = cyclicDistanceX(warpedUV.x, center.x, 1.0);
        float dy = warpedUV.y - center.y;
        // ...
    }
}
```

---🔥 BLOQUANT** : Corriger projection équirectangulaire (Voronoi sphérique ou cylindrique cohérent) → Résout discontinuités et artefacts de grille
2. **URGENT** : Réduire `smoothstep(0.0, 0.002, ...)` → Résout bordures larges
3. **CRITIQUE** : Implémenter domain warping → Résout aspect rectiligne
4. **IMPORTANTE** : Décroissance exponentielle → Résout remplissage intérieur
5. **MOYENNE** : Différenciation convergence/divergence → Améliore réalisme
6``glsl
// Calculer le type de mouvement des plaques
vec2 vel1 = getPlateVelocity(plateId, seed);
vec2 vel2 = getPlateVelocity(secondPlateId, seed);

// Direction de la frontière
vec2 borderNormal = normalize(center1 - center2);

// Projection des vélocités sur la normale
float convergence = dot(vel1 - vel2, borderNormal);

if (convergence > 0.1) {
    // CONVERGENCE → montagnes
    tectonicUplift = borderStrength * 800.0;
} else if (convergence < -0.1) {
    // DIVERGENCE → rift/dorsale (abaissement)
    tectonicUplift = -borderStrength * 400.0;
} else {
    // TRANSFORMANTE → pas d'effet vertical
    tectonicUplift = 0.0;
}
```

---

### Solution 4 : Décroissance exponentielle de l'effet tectonique

```glsl
// AVANT (linéaire)
if (borderStrength > 0.01) {
    tectonicUplift = borderStrength * 1500.0;
}

// APRÈS (exponentielle)
float tectonicFactor = exp(-borderDist * 50.0);  // Décroissance rapide
tectonicFactor = clamp(tectonicFactor, 0.0, 1.0);

if (tectonicFactor > 0.05) {  // Seuil plus strict
    tectonicUplift = tectonicFactor * tectonicFactor * 600.0;  // x² pour accentuer la décroissance
}
```

---

### Solution 5 : Modulation par bruit pour unicité

Ajouter une perturbation **locale** à l'effet tectonique pour éviter que toutes les frontières se ressemblent :

```glsl
// Bruit local le long de la frontière
float localNoise = fbm(vec3(uv * 20.0, float(plateId + secondPlateId)), 4, 0.6, 2.0, seed);
float modulation = 0.5 + 0.5 * localNoise;  // [0, 1]

tectonicUplift *= modulation;  // Variabilité locale
```

---

## 📊 Paramètres Recommandés (Valeurs Cibles)

| Paramètre | Valeur Actuelle | Valeur Recommandée | Impact |
|-----------|----------------|-------------------|--------|
| `borderWidth` (smoothstep) | 0.025 | **0.002** | Frontières 12× plus fines |
| `tectonicUplift` (continent-continent) | 1500.0 | **600.0** | Relief moins exagéré |
| `borderStrength` threshold | 0.01 | **0.05** | Zone d'effet plus restreinte |
| Domain warp amplitude | 0.0 (absent) | **0.08** | Frontières organiques |
| Domain warp octaves | 0 | **3** | Détails multi-échelle |

---

## 🎯 Priorité d'Implémentation

1. **URGENT** : Réduire `smoothstep(0.0, 0.002, ...)` → Résout bordures larges
2. **CRITIQUE** : Implémenter domain warping → Résout aspect rectiligne
3. **IMPORTANTE** : Décroissance exponentielle → Résout remplissage intérieur
4. **MOYENNE** : Différenciation convergence/divergence → Améliore réalisme
5. **BASSE** : Modulation par bruit local → Peaufinage esthétique

---

## 🧪 Tests de Validation

Une fois les corrections appliquées, valider avec ces critères :
**✅ Map équirectangulaire valide** : Seamless parfait sur X (bord gauche = bord droit)
- [ ] **✅ Pas de lignes verticales/grille** : Aucun artefact de compartimentage visible
- [ ] **✅ Wrap X fonctionnel** : Les plaques traversent correctement la couture X=0/X=width
- [ ] Largeur de bordure ≤ 5 pixels sur map 2048×1024
- [ ] Frontières invisibles sur heightmap grey (ou quasi-invisibles)
- [ ] Frontières sinueuses, non rectilignes
- [ ] Pas d'artefacts quadrilatéraux visibles
- [ ] Variabilité : chaque frontière est unique
- [ ] Relief tectonique localisé aux bordures, pas d'effet "halo"
- [ ] **✅ Compatible projection 3D** : La map peut être appliquée sur une sphère 3D sans déformation
- [ ] Relief tectonique localisé aux bordures, pas d'effet "halo"

---

## 📝 Notes Supplémentaires

### Pourquoi le legacy fonctionnait mieux ?

- **Utilisation cohérente des coordonnées cylindriques** pour TOUT le bruit

Le Voronoi a été introduit pour la **simulation physique** (frottement, vélocités), mais :
1. Il doit être calculé en **coordonnées sphériques** (pas UV plat)
2. Il doit être **caché visuellement** via domain warping
3. Il doit utiliser le **même référentiel** que le bruit (cylindrique/sphérique)
- Perturbation naturelle inhérente au bruit fBm
- Pas de géométrie explicite → pas de lignes droites

Le Voronoi a été introduit pour la **simulation physique** (frottement, vélocités), mais il faut le **cacher visuellement** via domain warping.

### Compromis performance vs qualité

Domain warping ajoute ~10-15% de coût GPU (3 octaves de bruit 2D). C'est acceptable pour la qualité gagnée. Si nécessaire :
- Réduire à 2 octaves (moins de détails fins)
- Utiliser un LUT pré-calculé pour le bruit de warp

---

## 🚨 Diagnostic Final : Problème Root Cause

Le problème **le plus critique** est la **projection non équirectangulaire**. Tous les autres problèmes (bordures larges, lignes droites, artefacts) sont des **symptômes** de cette cause racine :

```
CAUSE ROOT ──► Voronoi UV plat (2D cartésien)
              └─► Incohérence avec bruit cylindrique (3D)
                  ├─► Discontinuités au wrap X
                  ├─► Artefacts de grille/compartiments
                  ├─► Frontières rectilignes exacerbées
                  └─► Map non mappable sur sphère 3D
```

**Sans corriger la projection, les autres fixes (domain warping, bordures fines) ne résoudront que partiellement les problèmes visuels.**

---

**Conclusion** : Les problèmes actuels sont **tous corrigeables** mais nécessitent une refonte du calcul Voronoi :

1. **Priorité absolue** : Implémenter Voronoi en coordonnées sphériques/cylindriques cohérentes
2. **Ensuite** : Ajouter domain warping pour l'aspect organique
3. **Enfin** : Ajuster les paramètres (bordures, uplift, décroissance)

L'ordre d'implémentation est crucial - corriger la projection **avant** d'optimiser les détails esthétique

- Stefan Gustavson, "Simplex noise demystified" (2005)
- Inigo Quilez, "Domain Warping" https://iquilezles.org/articles/warp/
- "Plate Tectonics" (USGS) - Observations des frontières réelles

---

**Conclusion** : Les problèmes actuels sont **tous corrigeables** et proviennent d'une implémentation trop directe du Voronoi géométrique. L'ajout de domain warping et l'ajustement des paramètres résoudra l'ensemble des symptômes observés.
