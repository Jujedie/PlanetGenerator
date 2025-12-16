extends Node2D

# ============================================================================
# MASTER UI CONTROLLER - MERGED VERSION
# Combines Full UI Logic with Phase 4 3D Visualization
# ============================================================================

# --- Core Variables ---
var planetGenerator: PlanetGenerator
var maps: Array[String]
var map_index: int = 0
var langue: String = "fr"

# --- 3D Visualization Variables ---
var planet_mesh_gen: PlanetMeshGenerator = null
var camera_3d: Camera3D = null
var viewport_3d: SubViewport = null
var light: DirectionalLight3D = null  # Added class member
var is_3d_mode: bool = false

# --- Constants ---
const MAP_NAME_TO_KEY = {
	"elevation_map.png": "MAP_ELEVATION",
	"elevation_map_alt.png": "MAP_ELEVATION_ALT",
	"nuage_map.png": "MAP_CLOUDS",
	"oil_map.png": "MAP_OIL",
	"ressource_map.png": "MAP_RESOURCES",
	"precipitation_map.png": "MAP_PRECIPITATION",
	"temperature_map.png": "MAP_TEMPERATURE",
	"water_map.png": "MAP_WATER",
	"river_map.png": "MAP_RIVERS",
	"biome_map.png": "MAP_BIOMES",
	"final_map.png": "MAP_FINAL",
	"region_map.png": "MAP_REGIONS",
	"preview.png": "MAP_PREVIEW"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready() -> void:
	# 1. Language Setup
	if OS.get_locale_language() != "fr":
		langue = "en"
	TranslationServer.set_locale(langue)

	# 2. UI Initialization
	maj_labels()
	
	# 3. 3D Viewport Setup (Phase 4 Integration)
	_setup_3d_viewport()
	_create_ui_hints()

	# Créer planet_mesh ici, mais ne pas l'attacher encore (sera fait après génération)
	planet_mesh_gen = PlanetMeshGenerator.new()
	add_child(planet_mesh_gen)
	planet_mesh_gen.generate_sphere(128)  # Générer la sphère une fois

func _setup_3d_viewport() -> void:
	"""
	Creates the 3D environment inside the existing container.
	"""
	var viewport_container = $Node2D/Control/SubViewportContainer
	var existing_viewport = viewport_container.get_child(0)
	
	# Create new 3D viewport (not added to container yet)
	viewport_3d = SubViewport.new()
	viewport_3d.size = existing_viewport.size
	viewport_3d.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport_3d.handle_input_locally = false
	
	# Create 3D World
	var world_3d = World3D.new()
	viewport_3d.world_3d = world_3d
	
	# Add Planet Mesh Generator node
	planet_mesh_gen = PlanetMeshGenerator.new()
	viewport_3d.add_child(planet_mesh_gen)
	planet_mesh_gen.generate_sphere(128)
	
	# Setup Camera
	camera_3d = Camera3D.new()
	viewport_3d.add_child(camera_3d)
	camera_3d.position = Vector3(0, 0, 2.5)
	camera_3d.fov = 45
	
	# Add Lighting
	light = DirectionalLight3D.new()  # Assigned to member
	viewport_3d.add_child(light)
	light.position = Vector3(2, 2, 2)
	light.light_energy = 1.2
	
	# Add Environment
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.1, 0.1, 0.1)
	
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	viewport_3d.add_child(world_env)

func _create_ui_hints() -> void:
	# Adds a small label explaining controls
	var hint_lbl = Label.new()
	hint_lbl.text = "[TAB] 2D/3D View | Mouse Drag to Rotate"
	hint_lbl.position = Vector2(20, 20)
	hint_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	$Node2D/Control.add_child(hint_lbl)

# ============================================================================
# 3D LOGIC & INPUT
# ============================================================================

func _process(delta: float) -> void:
	# Auto-rotate planet slowly if in 3D mode
	if is_3d_mode and planet_mesh_gen:
		planet_mesh_gen.rotate_y(delta * 0.1)

func _input(event: InputEvent) -> void:
	# 1. Toggle 3D Mode
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		toggle_3d_mode()
	
	if not is_3d_mode or not camera_3d:
		return
		
	# 2. Zoom Controls
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_3d.position.z = max(1.2, camera_3d.position.z - 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_3d.position.z = min(5.0, camera_3d.position.z + 0.1)
	
	# 3. Rotate Camera (Orbit)
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var sensitivity = 0.005
		camera_3d.rotate_y(-event.relative.x * sensitivity)
		
		# Vertical clamp
		var new_x_rot = camera_3d.rotation.x - event.relative.y * sensitivity
		camera_3d.rotation.x = clamp(new_x_rot, -PI/2 + 0.1, PI/2 - 0.1)

func toggle_3d_mode() -> void:
	is_3d_mode = !is_3d_mode
	
	var viewport_container = $Node2D/Control/SubViewportContainer
	var viewport_2d = viewport_container.get_child(0) if viewport_container.get_child_count() > 0 else null
	
	if is_3d_mode:
		if viewport_2d:
			viewport_container.remove_child(viewport_2d)
		viewport_container.add_child(viewport_3d)
		viewport_3d.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		# Added look_at calls after adding to tree
		if camera_3d:
			camera_3d.look_at_from_position(camera_3d.position, Vector3.ZERO)
		if light:
			light.look_at_from_position(light.position, Vector3.ZERO)
	else:
		viewport_container.remove_child(viewport_3d)
		if viewport_2d:
			viewport_container.add_child(viewport_2d)
		viewport_3d.render_target_update_mode = SubViewport.UPDATE_DISABLED

# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	# UI Gather Data
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

	# Reset state
	maps = []
	map_index = 0
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = null

	var renderProgress = $Node2D/Control/renderProgress
	var lblMapStatus = $Node2D/Control/renderProgress/Node2D/lblMapStatus

	# Initialize Generator
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

	# Attacher le générateur de mesh 3D après création de planetGenerator
	planetGenerator.set_3d_mesh_generator(planet_mesh_gen)

	var echelle = 100.0 / sldRayonPlanetaire.value
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.scale = Vector2(echelle, echelle)
	
	# Connect Signal
	planetGenerator.finished.connect(_on_planetGenerator_finished)

	print("Génération de la planète : " + nom.text)

	# Start Thread
	var thread = Thread.new()
	thread.start(planetGenerator.generate_planet)

	# Disable UI
	_set_buttons_enabled(false)

func _on_planetGenerator_finished() -> void:
	call_deferred("_on_planetGenerator_finished_main")

func _on_planetGenerator_finished_main() -> void:
	# 1. Update 2D Maps (Standard Logic)
	maps = planetGenerator.getMaps()
	map_index = 0
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
		update_map_label()
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

	# 2. Update 3D Visualization (New Logic)
	_update_3d_visualization()

	# 3. Re-enable UI
	_set_buttons_enabled(true)

func _update_3d_visualization() -> void:
	if not planet_mesh_gen or not planetGenerator:
		return
		
	# Retrieve GPU Texture RIDs directly (No CPU readback needed)
	var texture_rids = planetGenerator.get_gpu_texture_rids()
	
	if not texture_rids.is_empty():
		planet_mesh_gen.update_maps(
			texture_rids.get("geo", RID()),
			texture_rids.get("atmo", RID())
		)
		print("[Master] 3D Planet updated with GPU textures")

func _set_buttons_enabled(enabled: bool) -> void:
	$Node2D/Control/btnComfirmer/btnComfirme.disabled = !enabled
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = !enabled
	$Node2D/Control/btnSuivant/btnSuivant.disabled = !enabled
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled = !enabled

# ============================================================================
# UI NAVIGATION & HELPERS
# ============================================================================

func get_map_display_name(file_path: String) -> String:
	var file_name = file_path.get_file()
	if MAP_NAME_TO_KEY.has(file_name):
		return tr(MAP_NAME_TO_KEY[file_name])
	return file_name

func update_map_label() -> void:
	if maps.is_empty():
		return
	var lbl = $Node2D/Control/renderProgress/Node2D/lblMapStatus
	lbl.text = get_map_display_name(maps[map_index])

func _on_btn_suivant_pressed() -> void:
	if maps.is_empty(): return 
	map_index = (map_index + 1) % maps.size()
	_load_current_map()

func _on_btn_precedant_pressed() -> void:
	if maps.is_empty(): return 
	map_index -= 1
	if map_index < 0: map_index = maps.size() - 1
	_load_current_map()

func _load_current_map() -> void:
	var img = Image.new()
	if img.load(maps[map_index]) == OK:
		var tex = ImageTexture.create_from_image(img)
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
		update_map_label()

# ============================================================================
# SLIDER CALLBACKS
# ============================================================================

func _on_sld_rayon_planetaire_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = tr("RAYON_PLANET").format({"val": str(value)})

func _on_sld_temp_moy_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = tr("AVG_TEMP").format({"val": str(value)})

func _on_sld_haut_eau_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = tr("WATER_ELEVATION").format({"val": str(value)})

func _on_sld_precipitation_moy_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	var value_str = str(value)
	if len(value_str) != 4: value_str += "0"
	label.text = tr("AVG_PRECIPITATION").format({"val": value_str})

func _on_sld_percent_eau_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldPercentEau/Node2D/Label
	var value_str = str(value)
	if len(value_str) != 4: value_str += "0"
	label.text = tr("WATER_ELEVATION").format({"val": value_str})

func _on_sld_elevation_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = tr("BONUS_ELEVATION").format({"val": str(value)})

func _on_sld_thread_value_changed(value: float) -> void:    
	var label = $Node2D/Control/sldThread/Node2D/Label
	label.text = tr("THREAD_NUMBER").format({"val": str(value)})

func _on_sld_nb_cases_regions_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldNbCasesRegions/Node2D/Label
	label.text = tr("NB_CASE_REGION").format({"val": str(value)})

func maj_labels() -> void:
	_on_sld_rayon_planetaire_value_changed($Node2D/Control/sldRayonPlanetaire.value)
	_on_sld_temp_moy_value_changed($Node2D/Control/sldTempMoy.value)
	_on_sld_haut_eau_value_changed($Node2D/Control/sldHautEau.value)
	_on_sld_precipitation_moy_value_changed($Node2D/Control/sldPrecipitationMoy.value)
	_on_sld_elevation_value_changed($Node2D/Control/sldElevation.value)
	_on_sld_thread_value_changed($Node2D/Control/sldThread.value)
	_on_sld_nb_cases_regions_value_changed($Node2D/Control/sldNbCasesRegions.value)

# ============================================================================
# LANGUAGE & SYSTEM
# ============================================================================

func _on_btn_french_pressed() -> void: _change_lang("fr")
func _on_btn_english_pressed() -> void: _change_lang("en")
func _on_btn_german_pressed() -> void: _change_lang("de")
func _on_btn_russian_pressed() -> void: _change_lang("ru")

func _change_lang(code: String) -> void:
	if langue == code: return
	langue = code
	TranslationServer.set_locale(langue)
	maj_labels()
	update_map_label()

func _on_btn_quitter_pressed() -> void:
	get_tree().quit()

# ============================================================================
# SAVE & RANDOMIZATION
# ============================================================================

func _on_btn_sauvegarder_pressed() -> void:
	if planetGenerator != null :
		var prompt_instance = load("res://data/scn/prompt.tscn").instantiate()
		$Node2D/Control.add_child(prompt_instance)
		prompt_instance.position = Vector2i(200, 125)
		prompt_instance.get_child(2).get_child(0).pressed.connect(_on_prompt_confirmed)

func _on_prompt_confirmed() -> void:
	var prompt = $Node2D/Control.get_child(-1)
	var input_line_edit = prompt.get_child(1).get_child(1)
	var input = input_line_edit.text
	input_line_edit.editable = false
	prompt.get_child(2).get_child(0).disabled = true
	prompt.get_child(2).get_child(1).disabled = true
	if input != "":
		if planetGenerator.nom == "":
			planetGenerator.nom = "Planète Générée"
		planetGenerator.cheminSauvegarde = input + "/" + planetGenerator.nom 
		planetGenerator.save_maps()
		print("Planète sauvegardée dans : ", planetGenerator.cheminSauvegarde)
	else:
		print("Aucun chemin de sauvegarde spécifié.")
	prompt.queue_free()

func _on_btn_randomise_pressed() -> void:
	randomize()
	
	# Name
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "b", "c", "d"]
	var random_name = prefixes[randi() % prefixes.size()] + "-" + str(randi() % 999 + 1)
	if randf() > 0.5: random_name += " " + suffixes[randi() % suffixes.size()]
	$Node2D/Control/planeteName/LineEdit.text = random_name
	
	# Sliders
	_randomize_slider($Node2D/Control/sldNbCasesRegions, true)
	_randomize_slider($Node2D/Control/sldRayonPlanetaire, true)
	_randomize_slider($Node2D/Control/sldTempMoy, true)
	_randomize_slider($Node2D/Control/sldHautEau, true)
	_randomize_slider($Node2D/Control/sldPrecipitationMoy, false)
	_randomize_slider($Node2D/Control/sldElevation, true)
	
	# Type
	var typePlanete = $Node2D/Control/typePlanete/ItemList
	typePlanete.select(randi() % typePlanete.item_count)
	
	maj_labels()

func _randomize_slider(slider: Slider, is_int: bool) -> void:
	if is_int:
		slider.value = randi_range(int(slider.min_value / slider.step), int(slider.max_value / slider.step)) * int(slider.step)
	else:
		slider.value = randf_range(slider.min_value, slider.max_value)
