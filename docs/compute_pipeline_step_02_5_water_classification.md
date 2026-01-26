# Pipeline Compute — Étape 2.5 : Classification des Eaux (Rivières, Lacs, Mers, Océans)

Ce document décrit le système GPU de classification des masses d'eau dans le générateur de planètes.

## Objectif

Générer automatiquement une carte hydrographique complète avec :
- **Rivières** : tracées par descente de gradient depuis des sources en altitude
- **Affluents** : petits cours d'eau alimentant les rivières
- **Fleuves** : grands cours d'eau à fort débit
- **Lacs** : petites masses d'eau (en altitude ou isolées sous le niveau de la mer)
- **Mers** : masses d'eau moyennes sous le niveau de la mer
- **Océans** : grandes masses d'eau sous le niveau de la mer

## Architecture

### Textures GPU

| Texture | Format | Description |
|---------|--------|-------------|
| `water_sources` | R32UI | IDs des sources de rivières (0 = pas de source) |
| `water_paths` | R32F | Flux accumulé des rivières |
| `water_paths_temp` | R32F | Buffer ping-pong pour propagation |
| `water_types` | R32UI | Type d'eau (0-6, voir codes ci-dessous) |
| `water_jfa` | RG32I | Coordonnées seed pour JFA (composantes connexes) |
| `water_jfa_temp` | RG32I | Buffer ping-pong pour JFA |

### Codes des types d'eau

| Code | Type | Description |
|------|------|-------------|
| 0 | NONE | Terre (pas d'eau) |
| 1 | OCEAN | Grande masse sous niveau mer (>1% surface) |
| 2 | SEA | Masse moyenne sous niveau mer (0.1-1% surface) |
| 3 | LAKE | Petite masse d'eau ou lac en altitude |
| 4 | AFFLUENT | Cours d'eau à faible flux |
| 5 | RIVER | Cours d'eau à flux moyen |
| 6 | FLEUVE | Cours d'eau à fort flux |

## Pipeline de génération

### Passe 1 : Détection des sources (`river_sources.glsl`)

**Critères de sélection des sources :**
- Altitude > niveau_mer + min_altitude (100m par défaut)
- Précipitation > min_precipitation (0.3 par défaut)
- Distance minimale entre sources (grille de cellules)
- Pas aux pôles (évite les sources Y < 2 ou Y > height - 2)

**Algorithme :**
1. Diviser la carte en cellules de taille `cell_size`
2. Pour chaque cellule, un seul pixel peut être source (déterminé par hash)
3. Vérifier les critères d'éligibilité (altitude, précipitation)
4. Sélection probabiliste basée sur les précipitations

### Passe 2 : Propagation des rivières (`river_propagation.glsl`)

**Algorithme (itératif, ~200 passes) :**
1. Chaque pixel source émet un flux de base
2. Le flux se propage vers le voisin le plus bas (descente de gradient)
3. Les flux convergent quand plusieurs sources drainent vers le même point
4. La propagation s'arrête à l'océan (height < sea_level)

**Caractéristiques :**
- Wrapping X (équirectangulaire) : les rivières peuvent traverser le bord gauche/droite
- Clamp Y : pas de traversée aux pôles
- Méandres : légère perturbation aléatoire pour éviter les lignes droites

### Passe 3 : Classification initiale (`water_classification.glsl`)

**Règles de classification :**
1. **Rivières/Fleuves** : `flux > seuil` (priorité sur l'eau de surface)
   - Affluent : flux > 5
   - Rivière : flux > 50
   - Fleuve : flux > 200
2. **Eau de surface** : `height < sea_level` → temporairement "océan"
3. **Lacs en altitude** : `height >= sea_level AND water_height > 0.5`

### Passe 4 : JFA pour composantes connexes (`water_jfa.glsl`)

Le Jump Flooding Algorithm propage les IDs de composantes :
- Chaque pixel d'eau connaît le "seed" de sa composante (première eau rencontrée)
- Après log2(max(w,h)) passes, tous les pixels d'une même masse d'eau partagent le même seed

**Compatibilité :**
- Océan et Mer sont fusionnables (même masse sous la mer)
- Lacs restent séparés des océans/mers

### Passe 5 : Reclassification par taille (`water_finalize.glsl`)

**Seuils basés sur le nombre de pixels :**
- Océan : > 1% de la surface totale
- Mer : > 0.1% de la surface
- Lac : < 0.1% ou altitude >= sea_level

## Intégration

### Appel dans l'orchestrateur

```gdscript
# Dans run_simulation()
run_erosion_phase(generation_params, w, h)
run_water_classification_phase(generation_params, w, h)  # Nouveau
run_atmosphere_phase(generation_params, w, h)
```

### Paramètres configurables

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `min_altitude` | 100.0 | Altitude min des sources au-dessus de la mer |
| `min_precipitation` | 0.3 | Précipitation min pour source |
| `cell_size` | w/60 | Espacement min entre sources |
| `river_propagation_iterations` | 200 | Nombre de passes de propagation |
| `base_river_flux` | 10.0 | Flux initial par source |
| `flux_threshold_low` | 5.0 | Seuil affluent |
| `flux_threshold_mid` | 50.0 | Seuil rivière |
| `flux_threshold_high` | 200.0 | Seuil fleuve |

## Export

L'exporter génère trois cartes :

1. **`eaux_map.png`** : Carte colorée finale
   - Océan : bleu profond (#25528a)
   - Mer : bleu moyen
   - Lac : bleu clair (#4584d2)
   - Affluent : bleu très clair (#6BAAE5)
   - Rivière : bleu (#4A90D9)
   - Fleuve : bleu soutenu (#3E7FC4)

2. **`water_types.png`** : Niveaux de gris pour debug (0→noir, 6→blanc)

3. **`river_map.png`** : Flux des rivières (intensité logarithmique)

## Considérations physiques

### Lacs en altitude

Les lacs peuvent exister au-dessus du niveau de la mer si :
- Dépression topographique (cuvette)
- Eau accumulée par précipitations/rivières
- Pas d'exutoire (ou exutoire bouché)

Le système détecte ces lacs via `water_height > lake_min_water` dans GeoTexture.

### Équilibre hydrologique (futur)

Pour plus de réalisme, implémenter :
- `évaporation = f(température, surface)`
- `précipitation = f(climat local)`
- `lac_viable = (précipitation + flux_entrant) > évaporation`

## Dépendances

Ce système dépend de :
- **Étape 0** : GeoTexture (height) pour topographie
- **Étape 2** : river_flux (optionnel, peut être recalculé)
- **Étape 3** : ClimateTexture (precipitation) pour sources

## Notes techniques

- Les textures R32UI et RG32I nécessitent des formats spéciaux dans Vulkan
- Le JFA utilise un ping-pong pour éviter les race conditions
- Les compteurs atomiques (SSBO) sont utilisés pour compter les pixels par composante
