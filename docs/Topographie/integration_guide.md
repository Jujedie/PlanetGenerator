# Guide d'Intégration - Génération d'Élévation GPU

## 🎯 Objectif

Ce guide explique comment intégrer les nouveaux shaders de génération d'élévation dans votre projet Planet Generator existant.

## 📋 Prérequis

- Godot 4.5 (ou supérieur)
- GPU compatible Vulkan ou Metal
- Projet Planet Generator existant

## 🔨 Étapes d'intégration

### Étape 1 : Créer la structure des shaders

Créez les dossiers suivants dans votre projet :

```
res://
├── shaders/
│   └── compute/
│       ├── tectonic_plates.glsl
│       ├── orogeny.glsl
│       └── hydraulic_erosion.glsl
└── src/
    └── classes/
        └── classes_gpu/
            ├── gpu_context.gd
            ├── orchestrator.gd
            └── exporter.gd (dans classes_io)
```

### Étape 2 : Copier les fichiers shader

Copiez le contenu des trois shaders créés dans leurs fichiers respectifs.

**IMPORTANT** : Après avoir copié les fichiers, **redémarrez Godot** pour qu'il détecte les nouveaux shaders.

### Étape 3 : Vérifier l'import des shaders

Dans l'éditeur Godot :

1. Naviguez vers `res://shaders/compute/`
2. Pour chaque fichier `.glsl` :
   - Cliquez dessus
   - Dans l'onglet **Import**, vérifiez que le type est **"RDShaderFile"**
   - Si ce n'est pas le cas, sélectionnez "RDShaderFile" et cliquez "Reimport"

### Étape 4 : Mettre à jour orchestrator.gd

Remplacez la méthode `_compile_all_shaders()` par :

```gdscript
func _compile_all_shaders() -> bool:
	if not rd: return false
	print("[Orchestrator] 📦 Compilation des shaders et création des pipelines...")
	
	var shaders_to_load = [
		{"path": "res://shaders/compute/tectonic_plates.glsl", "name": "tectonic", "critical": true},
		{"path": "res://shaders/compute/orogeny.glsl", "name": "orogeny", "critical": true},
		{"path": "res://shaders/compute/hydraulic_erosion.glsl", "name": "erosion", "critical": true}
	]
	
	var all_critical_loaded = true
	
	for s in shaders_to_load:
		gpu.load_compute_shader(s["path"], s["name"])
		var shader_rid = gpu.shaders[s["name"]]
		
		if not shader_rid.is_valid():
			print("  ❌ Échec chargement shader: ", s["name"])
			if s["critical"]: all_critical_loaded = false
			continue
		
		var pipeline_rid = gpu.pipelines[s["name"]]
		print("    ✅ ", s["name"], " : Shader=", shader_rid, " | Pipeline=", pipeline_rid)
	
	return all_critical_loaded
```

### Étape 5 : Ajouter les uniform sets

Dans `_init_uniform_sets()`, ajoutez :

```gdscript
# === TECTONIC PLATES SHADER ===
if gpu.shaders["tectonic"].is_valid():
	print("  • Création uniform set: tectonic")
	var uniforms = [
		gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID.[0]]),
		gpu.create_texture_uniform(1, gpu.textures[GPUContext.TextureID.[1]])
	]
	gpu.uniform_sets["tectonic"] = rd.uniform_set_create(uniforms, gpu.shaders["tectonic"], 0)
	if not gpu.uniform_sets["tectonic"].is_valid():
		push_error("[Orchestrator] ❌ Failed to create tectonic uniform set")
	else:
		print("    ✅ tectonic uniform set créé")

# === OROGENY SHADER ===
if gpu.shaders["orogeny"].is_valid():
	print("  • Création uniform set: orogeny")
	var uniforms = [
		gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID.[0]]),
		gpu.create_texture_uniform(1, gpu.textures[GPUContext.TextureID.[1]])
	]
	gpu.uniform_sets["orogeny"] = rd.uniform_set_create(uniforms, gpu.shaders["orogeny"], 0)
	if not gpu.uniform_sets["orogeny"].is_valid():
		push_error("[Orchestrator] ❌ Failed to create orogeny uniform set")
	else:
		print("    ✅ orogeny uniform set créé")

# === EROSION SHADER ===
if gpu.shaders["erosion"].is_valid():
	print("  • Création uniform set: erosion")
	var uniforms = [
		gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID.[0]]),
	]
	gpu.uniform_sets["erosion"] = rd.uniform_set_create(uniforms, gpu.shaders["erosion"], 0)
	if not gpu.uniform_sets["erosion"].is_valid():
		push_error("[Orchestrator] ❌ Failed to create erosion uniform set")
	else:
		print("    ✅ erosion uniform set créé")
```

### Étape 6 : Ajouter les phases de simulation

Dans `run_simulation()`, remplacez le commentaire `# FOR EACH PHASE` par :

```gdscript
# ============================================================================
# PHASE 1: TECTONIC PLATES GENERATION
# ============================================================================
run_tectonic_phase(generation_params, w, h, _rids_to_free)

# ============================================================================
# PHASE 2: OROGENIC DETAIL INJECTION
# ============================================================================
run_orogeny_phase(generation_params, w, h, _rids_to_free)

# ============================================================================
# PHASE 3: HYDRAULIC EROSION (ITERATIVE)
# ============================================================================
run_erosion_phase(generation_params, w, h, _rids_to_free)
```

Et ajoutez les trois méthodes `run_tectonic_phase`, `run_orogeny_phase` et `run_erosion_phase` (voir le code complet dans l'artifact orchestrator.gd).

### Étape 7 : Mettre à jour exporter.gd

Dans `_export_elevation_map()`, remplacez :

```gdscript
var elevation = -1 # Placeholder
```

par :

```gdscript
var elevation = pixel.r  # geo_state: R = elevation
```

## 🧪 Tester l'intégration

### Test rapide

1. Lancez le projet
2. Dans l'UI, configurez :
   - Nombre de régions : 30
   - Rayon planétaire : 128
   - Élévation additionnelle : 5000
3. Cliquez sur "Générer"

### Vérifier les logs

La console devrait afficher :

```
[Orchestrator] 🌍 DÉMARRAGE SIMULATION COMPLÈTE
  Seed: XXXXX
  Température: XX.X°C
  Résolution de la simulation : 128x64

[Orchestrator] ═══ PHASE 1: TECTONIC PLATES GENERATION ═══
  • Dispatch: 8x4 groupes (8192 threads)
  • Plaques tectoniques: 30
  ✅ Tectonique des plaques terminée

[Orchestrator] ═══ PHASE 2: OROGENIC DETAIL INJECTION ═══
  • Dispatch: 8x4 groupes
  • Intensité montagneuse: 5000.0m
  ✅ Détails orographiques ajoutés

[Orchestrator] ═══ PHASE 3: HYDRAULIC EROSION (ITERATIVE) ═══
  • Itérations: 100
  • Quantité de pluie: 0.005
    Itération 0/100
    Itération 20/100
    ...
  ✅ Érosion hydraulique terminée (100 cycles)

[Exporter] Starting map export to: user://temp/
[Exporter] Reading texture for map type: geo
  ✓ Saved: elevation_map.png
  ✓ Saved: elevation_map_alt.png
```

### Vérifier les exports

Ouvrez `user://temp/` (cliquez sur "Ouvrir le dossier du projet" dans Godot) et vérifiez la présence de :
- `elevation_map.png`
- `elevation_map_alt.png`

## 🔍 Débogage courant

### Erreur : "Shader not found"

**Cause** : Le chemin vers les shaders est incorrect

**Solution** :
```gdscript
# Vérifier que le chemin est exact
print(FileAccess.file_exists("res://shaders/compute/tectonic_plates.glsl"))
# Doit afficher : true
```

### Erreur : "Failed to create uniform set"

**Cause** : Les textures ne sont pas créées ou les bindings sont incorrects

**Solution** :
```gdscript
# Dans _init_textures(), vérifier les logs :
print("Texture GEOPHYSICAL_STATE: ", gpu.textures[GPUContext.TextureID.[0]])
# Doit afficher un RID valide : RID(XXXXX)
```

### Avertissement : "Pipeline not ready"

**Cause** : Le shader n'a pas été compilé

**Solution** :
1. Redémarrer Godot
2. Vérifier l'import du shader (voir Étape 3)
3. Vérifier les erreurs de compilation GLSL dans la console

### Carte vide ou uniforme

**Cause** : Les paramètres ne sont pas transmis correctement

**Solution** :
```gdscript
# Dans run_tectonic_phase, ajouter un print :
print("Params: num_plates=", num_plates, " terrain_scale=", terrain_scale)
```

## 📊 Performance

### Temps de génération attendus

Pour une résolution de **512x256** :

| Phase | Temps (GPU Mid-range) | Temps (GPU High-end) |
|-------|----------------------|---------------------|
| Tectonique | 5-10ms | 1-3ms |
| Orogenèse | 5-10ms | 1-3ms |
| Érosion (100 iter.) | 500-1000ms | 100-300ms |
| **TOTAL** | ~0.5-1s | ~0.1-0.3s |

### Optimisation

Pour accélérer la génération :
- Réduire `erosion_iterations` à 50
- Réduire la résolution à 256x128 pour les tests
- Désactiver temporairement l'érosion (commenter `run_erosion_phase`)

## ✅ Validation finale

Votre intégration est réussie si :

1. ✅ Aucune erreur dans la console
2. ✅ Les 3 phases s'exécutent sans crash
3. ✅ `elevation_map.png` contient un terrain varié (montagnes, plaines)
4. ✅ `elevation_map_alt.png` montre les mêmes formes en niveaux de gris
5. ✅ Le terrain montre des plaques tectoniques distinctes
6. ✅ Les montagnes apparaissent aux frontières des plaques

## 🎉 Prochaines étapes

Une fois l'intégration validée, vous pouvez :

1. Expérimenter avec les paramètres (nombre de plaques, intensité d'érosion)
2. Implémenter les cartes suivantes (Eaux, Température, etc.)
3. Ajouter un mode de visualisation 3D du terrain généré

---

**Support** : En cas de problème, vérifiez d'abord la console Godot pour les messages d'erreur spécifiques. La plupart des problèmes sont dus à des chemins incorrects ou à des shaders non importés.
