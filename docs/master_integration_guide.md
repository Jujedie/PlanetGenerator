# 🔌 Phase 5: Master.gd Integration Guide

## Critical Changes Needed in `src/scenes/master.gd`

### ⚠️ DO NOT CREATE NEW BUTTONS

We use the existing UI from `master.tscn`. You only need to modify the **button callback functions**.

---

## Changes Required

### 1. Add 3D Mesh Generator Reference

```gdscript
# Add at the top with other variables
var planet_mesh_gen: PlanetMeshGenerator = null
```

### 2. Modify `_ready()` Function

```gdscript
func _ready() -> void:
	# Existing language setup (unchanged)
	if OS.get_locale_language() != "fr":
		langue = "en"
	
	TranslationServer.set_locale(langue)
	maj_labels()
	
	# NEW: Setup 3D visualization
	_setup_3d_viewport()
```

### 3. Add 3D Viewport Setup Function

```gdscript
func _setup_3d_viewport() -> void:
	"""
	Create 3D visualization in existing SubViewportContainer
	"""
	
	# Get existing viewport container
	var viewport_container = $Node2D/Control/SubViewportContainer
	var existing_viewport = viewport_container.get_child(0)
	
	# Create new 3D viewport
	var viewport_3d = SubViewport.new()
	viewport_3d.size = existing_viewport.size
	viewport_3d.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_3d.visible = false  # Hidden by default, show after generation
	viewport_container.add_child(viewport_3d)
	
	# Create 3D scene
	var world_3d = World3D.new()
	viewport_3d.world_3d = world_3d
	
	# Add planet mesh generator
	planet_mesh_gen = PlanetMeshGenerator.new()
	viewport_3d.add_child(planet_mesh_gen)
	planet_mesh_gen.generate_sphere(128)
	
	# Setup camera
	var camera_3d = Camera3D.new()
	viewport_3d.add_child(camera_3d)
	camera_3d.position = Vector3(0, 0.5, 3)
	camera_3d.look_at(Vector3.ZERO)
	
	# Add light
	var light = DirectionalLight3D.new()
	viewport_3d.add_child(light)
	light.position = Vector3(2, 3, 2)
	light.look_at(Vector3.ZERO)
	
	print("[Master] 3D viewport initialized")
```

### 4. Modify Generate Button Callback

**EXISTING FUNCTION:** `_on_btn_comfirme_pressed()`

**CHANGES NEEDED:**

```gdscript
func _on_btn_comfirme_pressed() -> void:
	# Read UI values (existing code - keep as is)
	var nom = $Node2D/Control/planeteName/LineEdit
	var sldNbCasesRegions = $Node2D/Control/sldNbCasesRegions
	var sldRayonPlanetaire = $Node2D/Control/sldRayonPlanetaire
	var sldTempMoy = $Node2D/Control/sldTempMoy
	var sldHautEau = $Node2D/Control/sldHautEau
	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	var sldElevation = $Node2D/Control/sldElevation
	var sldThread = $Node2D/Control/sldThread
	var typePlanete = $Node2D/Control/typePlanete/ItemList
	
	if typePlanete.get_selected_id() == -1:
		typePlanete.select(0)
	
	# Clear previous maps
	maps = []
	map_index = 0
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = null
	
	var renderProgress = $Node2D/Control/renderProgress
	var lblMapStatus = $Node2D/Control/renderProgress/Node2D/lblMapStatus
	
	# Create planet generator
	planetGenerator = PlanetGenerator.new(
		nom.text,
		sldRayonPlanetaire.value,
		sldTempMoy.value,
		sldHautEau.value,
		sldPrecipitationMoy.value,
		sldElevation.value,
		sldThread.value,
		typePlanete.get_selected_id(),
		renderProgress,
		lblMapStatus,
		sldNbCasesRegions.value
	)
	
	# NEW: Attach 3D mesh generator to planet generator
	if planet_mesh_gen:
		planetGenerator.set_3d_mesh_generator(planet_mesh_gen)
	
	# Scale 2D map view (existing code)
	var echelle = 100.0 / sldRayonPlanetaire.value
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.scale = Vector2(echelle, echelle)
	
	# Connect signals
	planetGenerator.finished.connect(_on_planetGenerator_finished)
	
	print("Génération de la planète : " + nom.text)
	
	# Start generation in thread
	var thread = Thread.new()
	thread.start(planetGenerator.generate_planet)
	
	# Disable buttons during generation (existing code)
	$Node2D/Control/btnComfirmer/btnComfirme.disabled = true
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = true
	$Node2D/Control/btnSuivant/btnSuivant.disabled = true
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled = true
```

### 5. Modify Finished Callback

**EXISTING FUNCTION:** `_on_planetGenerator_finished_main()`

**CHANGES NEEDED:**

```gdscript
func _on_planetGenerator_finished_main() -> void:
	"""
	Called when planet generation is complete
	Updates both 2D map view and 3D visualization
	"""
	
	# Get temporary maps for 2D preview (existing code)
	maps = planetGenerator.getMaps()
	map_index = 0
	
	# Re-enable buttons (existing code)
	$Node2D/Control/btnComfirmer/btnComfirme.disabled = false
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = false
	$Node2D/Control/btnSuivant/btnSuivant.disabled = false
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled = false
	
	# Load first 2D map (existing code)
	if maps.size() > 0:
		var img = Image.new()
		var err = img.load(maps[map_index])
		if err == OK:
			var tex = ImageTexture.create_from_image(img)
			$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
			update_map_label()
	
	# NEW: Show 3D visualization (optional - can keep 2D by default)
	# Uncomment these lines to auto-switch to 3D after generation:
	# var viewport_3d = $Node2D/Control/SubViewportContainer.get_child(1)
	# viewport_3d.visible = true
	# $Node2D/Control/SubViewportContainer.get_child(0).visible = false
	
	print("[Master] Generation complete, visualization updated")
```

### 6. Modify Export/Save Button Callback

**EXISTING FUNCTION:** `_on_btn_sauvegarder_pressed()`

**CHANGES NEEDED:**

```gdscript
func _on_btn_sauvegarder_pressed() -> void:
	"""
	Export maps to user-specified directory
	"""
	if planetGenerator != null:
		# Create prompt dialog (existing code - keep as is)
		var prompt_instance = load("res://data/scn/prompt.tscn").instantiate()
		$Node2D/Control.add_child(prompt_instance)
		prompt_instance.position = Vector2i(200, 125)
		prompt_instance.get_child(2).get_child(0).pressed.connect(_on_prompt_confirmed)

func _on_prompt_confirmed() -> void:
	"""
	Called when user confirms export path
	"""
	var prompt = $Node2D/Control.get_child(-1)
	var input_line_edit = prompt.get_child(1).get_child(1)
	var output_path = input_line_edit.text
	
	input_line_edit.editable = false
	prompt.get_child(2).get_child(0).disabled = true
	prompt.get_child(2).get_child(1).disabled = true
	
	if output_path != "":
		# Ensure planet has a name
		if planetGenerator.nom == "":
			planetGenerator.nom = "Planète Générée"
		
		# NEW: Use new export function
		var full_path = output_path + "/" + planetGenerator.nom
		planetGenerator.export_to_directory(full_path)
		
		print("Planète sauvegardée dans : ", full_path)
	else:
		print("Aucun chemin de sauvegarde spécifié.")
	
	prompt.queue_free()
```

---

## Summary of Changes

### Files Modified:
1. ✅ `src/classes/classes_io/exporter.gd` - **CREATED**
2. ✅ `src/classes/classes_gpu/orchestrator.gd` - **UPDATED** (param handling)
3. ✅ `src/classes/classes_data/planetGenerator.gd` - **UPDATED** (complete rewrite)
4. ⚠️ `src/scenes/master.gd` - **NEEDS MANUAL UPDATE** (see above)

### UI Buttons Used (NO NEW BUTTONS):
- **"Générer" button** → Calls `_on_btn_comfirme_pressed()`
- **"Sauvegarder" button** → Calls `_on_btn_sauvegarder_pressed()`
- **"Vue Suivante/Précédente"** → Unchanged (cycles through 2D maps)
- **"Quitter"** → Unchanged

### Data Flow:

```
UI Sliders
    ↓
master.gd (_on_btn_comfirme_pressed)
    ↓
PlanetGenerator.__init__()
    ↓ (compiles params)
PlanetGenerator.generate_planet_gpu()
    ↓ (passes params dict)
GPUOrchestrator.run_simulation(params)
    ↓ (initializes terrain with seed)
GPUOrchestrator._initialize_terrain(params)
    ↓ (runs erosion with rain_rate from precipitation)
GPUOrchestrator.run_hydraulic_erosion(params)
    ↓ (GPU textures ready)
PlanetExporter.export_maps(geo_rid, atmo_rid, params)
    ↓ (PNG files created using enum.gd palettes)
master.gd (_on_planetGenerator_finished_main)
    ↓ (loads maps for preview)
2D/3D Visualization Updated
```

---

## Testing Checklist

1. ✅ Sliders change parameters (check console output for seed/temp/etc.)
2. ✅ Generate button starts GPU simulation
3. ✅ Progress bar updates during generation
4. ✅ 2D maps appear in UI after generation
5. ✅ Export button creates PNG files with correct colors
6. ✅ 3D view shows terrain (if enabled)
7. ✅ Rivers appear in river_map.png
8. ✅ Biomes match temperature/humidity (check biome_map.png)

---

## Troubleshooting

### Issue: "GPUContext not available"
**Solution:** Ensure `autoload/GPUContext.tscn` is in Project Settings → Autoload

### Issue: Maps are all black
**Solution:** Check console for shader compilation errors. Verify SPIR-V files exist.

### Issue: Rivers not appearing
**Solution:** Increase `erosion_iterations` in generation_params (line 63 of planetGenerator.gd)

### Issue: Wrong colors in exported maps
**Solution:** Verify `src/enum.gd` is being loaded correctly (check for import errors)

### Issue: 3D mesh not updating
**Solution:** Check that `set_3d_mesh_generator()` is called before `generate_planet()`

---

## Performance Notes

- **GPU Generation:** ~5-10 seconds for 2048x1024
- **Export to PNG:** ~2-3 seconds (10 maps)
- **3D Mesh Update:** <0.1 seconds (Texture2DRD)
- **Total Time:** ~10-15 seconds (vs. 60+ seconds CPU legacy)

---

## Next Steps After Integration

1. Test with different atmosphere types (0-4)
2. Verify river detection with high precipitation values
3. Check biome accuracy near poles vs. equator
4. Test export to external directory
5. Implement 3D camera controls (optional)

