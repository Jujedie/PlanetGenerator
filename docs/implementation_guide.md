# 🌍 GEO-COMPUTE INITIATIVE - Guide d'Implémentation

## PHASE 1 & 2 : Architecture GPU + Simulation Géophysique

### 📁 Structure du Projet

```
res://
├── shaders/
│   └── compute/
│       ├── tectonic_plates.glsl
│       ├── tectonic_plates.spv         # SPIR-V compilé
│       ├── orogeny.glsl
│       ├── orogeny.spv
│       ├── atmosphere_dynamics.glsl
│       └── atmosphere_dynamics.spv
├── src/
│   ├── GPUContext.gd
│   ├── GeoComputeOrchestrator.gd
│   └── enum.gd                          # CONSERVÉ (pour export)
└── autoload/
    └── GPUContext.tscn                  # Singleton Godot
```

---

## 🔧 ÉTAPE 1: Compilation des Shaders GLSL → SPIR-V

### Pourquoi SPIR-V ?
Godot 4 ne peut **pas** compiler du GLSL à la volée. Vous devez fournir du bytecode SPIR-V précompilé.

### Outils Requis

**Linux/macOS:**
```bash
# Installer glslc (partie du Vulkan SDK)
sudo apt install vulkan-tools   # Ubuntu/Debian
```

**Windows:**
Télécharger le [LunarG Vulkan SDK](https://vulkan.lunarg.com/)

### Commandes de Compilation

Depuis le dossier `res://shaders/compute/`:

```bash
# Tectonique
glslc -fshader-stage=compute tectonic_plates.glsl -o tectonic_plates.spv

# Orogénèse
glslc -fshader-stage=compute orogeny.glsl -o orogeny.spv

# Atmosphère
glslc -fshader-stage=compute atmosphere_dynamics.glsl -o atmosphere_dynamics.spv
```

**⚠️ IMPORTANT:** Vérifiez que les `.spv` sont bien dans le même dossier que les `.glsl`.

---

## 🚀 ÉTAPE 2: Configuration Godot

### 2.1 Créer le Singleton

1. Dans Godot, créer une scène `GPUContext.tscn`
2. Attacher le script `GPUContext.gd`
3. **Project Settings → Autoload:**
   - Path: `res://autoload/GPUContext.tscn`
   - Name: `GPUContext`
   - Enable: ✅

### 2.2 Scène de Test

Créer `res://scenes/TestSimulation.tscn`:

```gdscript
extends Node

var orchestrator: GeoComputeOrchestrator

func _ready():
    orchestrator = GeoComputeOrchestrator.new()
    add_child(orchestrator)
    
    # Attendre 1 frame pour l'initialisation GPU
    await get_tree().process_frame
    
    # Lancer simulation
    _run_full_simulation()

func _run_full_simulation():
    print("🌍 DÉBUT SIMULATION")
    
    # Phase 1: Tectonique (100M années)
    orchestrator.execute_tectonic_simulation()
    
    # Phase 2: Atmosphère (1000 steps = ~1 mois simulé)
    orchestrator.execute_atmospheric_simulation(1000)
    
    # Export
    orchestrator.export_all_maps("user://planet_output/")
    
    print("✅ SIMULATION TERMINÉE")
```

---

## 📊 ÉTAPE 3: Surveillance GPU (Debug)

### Activer la Console Vulkan

**Project Settings → Rendering → Vulkan:**
- Validation Layers: `ON`
- GPU Validation: `ON`

### Vérifier l'Utilisation Mémoire

```gdscript
# Dans GPUContext.gd, ajouter:
func get_vram_usage() -> String:
    var total_bytes = 0
    for tex_id in textures:
        total_bytes += 2048 * 1024 * 16  # RGBAF32 = 16 bytes/pixel
    
    return "VRAM: %.2f MB" % (total_bytes / 1024.0 / 1024.0)
```

---

## 🎯 RÉSULTATS ATTENDUS (Phase 1 & 2)

Après exécution, vous devriez obtenir:

### Console Output:
```
✓ GPUContext initialisé: 2048x1024
✓ Textures GPU créées (4x 32768 KB)
✓ Shader compilé: tectonic_plates
✓ Shader compilé: orogeny
✓ Shader compilé: atmosphere_dynamics
✓ 25 plaques initialisées

=== PHASE TECTONIQUE ===
  Cycle 0 / 10000 (0.0M ans)
  Cycle 100 / 10000 (1.0M ans)
  ...
✓ Tectonique terminée: 100.0M ans

=== PHASE ATMOSPHÉRIQUE ===
  Step 0 / 1000
  Step 100 / 1000
  ...
✓ Atmosphère simulée: 1000 steps

=== EXPORT CARTES ===
✓ Export terminé: user://planet_output/
```

### Fichiers Générés (Phase 3):
- `geophysical_raw.png` (2048x1024, RGBAF32)
- `atmospheric_raw.png` (2048x1024, RGBAF32)

---

## 🔬 VALIDATION TECHNIQUE

### Test 1: Seamless Wrapping
```gdscript
# Vérifier que le bord gauche = bord droit
var img = gpu.readback_texture(GPUContext.TextureID.GEOPHYSICAL_STATE)
var left_pixel = img.get_pixel(0, 512)
var right_pixel = img.get_pixel(2047, 512)
var diff = left_pixel.distance_to(right_pixel)
print("Seamless diff: ", diff)  # Devrait être < 0.01
```

### Test 2: Plaques Voronoi
```gdscript
# Compter le nombre de plaques distinctes
var plate_img = gpu.readback_texture(GPUContext.TextureID.PLATE_DATA)
var plate_ids = {}
for y in range(1024):
    for x in range(2048):
        var id = int(plate_img.get_pixel(x, y).r)
        plate_ids[id] = true

print("Plaques détectées: ", plate_ids.size())  # Devrait être ~25
```

### Test 3: Conservation Énergie (Atmosphère)
```gdscript
# L'énergie thermique totale doit rester stable
var total_energy_before = 0.0
var total_energy_after = 0.0

# ... calculs avant/après simulation ...

var conservation_error = abs(total_energy_after - total_energy_before) / total_energy_before
print("Erreur conservation: %.2f%%" % (conservation_error * 100))
# Acceptable < 5%
```

---

## ⚠️ PROBLÈMES COURANTS

### Erreur: "Shader not found"
- ✅ Vérifier que les `.spv` sont dans `res://shaders/compute/`
- ✅ Relancer Godot (les `.spv` doivent être importés)

### Erreur: "Invalid uniform set"
- ✅ Vérifier que les `binding` dans GLSL correspondent au code GDScript
- ✅ S'assurer que `create_uniform_set()` est appelé avant `dispatch_compute()`

### Performance: Simulation trop lente
- ✅ Réduire `num_steps` dans `execute_atmospheric_simulation()`
- ✅ Augmenter `time_step_years` (sauter des cycles)
- ✅ Utiliser GPU dédié (pas intégré Intel)

---

## 🎓 PRINCIPES SCIENTIFIQUES IMPLÉMENTÉS

### Tectonique des Plaques
- **Jump Flooding Algorithm** (Rong & Tan, 2006): Voronoi sur GPU en O(log n)
- **Distance Géodésique**: Formule Haversine pour sphères
- **Orogénèse**: Convergence → uplift, Divergence → subsidence

### Atmosphère
- **Advection Semi-Lagrangienne**: Transport fluide stable (Stam, 1999)
- **Diffusion**: Lissage thermique (Laplacien discret)
- **Force de Coriolis**: `f = 2Ω sin(φ)` pour déviation vent
- **Orographic Lift**: Humidité × Pente → Précipitation

---

## 📚 PROCHAINES ÉTAPES (Phase 3)

1. **Érosion Hydraulique**: Implémentation "Virtual Pipes"
2. **Export Cartes**: Conversion RGBAF32 → PNG avec couleurs `enum.gd`
3. **Visualisation 3D**: Shader planet.gdshader avec LOD

---

## 🆘 SUPPORT

Pour toute question sur cette implémentation:
1. Vérifier les logs console Godot
2. Activer validation Vulkan pour erreurs GPU
3. Comparer vos résultats avec les tests de validation

**Status Phase 1 & 2:** ✅ **READY FOR TESTING**
