extends Node2D

# --- Core Variables ---
var planetGenerator: PlanetGenerator
var maps: Array[String]
var map_index: int = 0
var langue: String = "fr"
var _sfx_player: AudioStreamPlayer
var _generation_epoch: int = 0
var _is_exiting: bool = false

# --- Milestone 7 Local Zone UI ---
var _local_zone_panel: PanelContainer
var _local_zone_toggle_button: Button
var _local_zone_select_button: Button
var _local_zone_generate_button: Button
var _local_zone_export_button: Button
var _local_zone_back_button: Button
var _local_zone_resolution: OptionButton
var _local_zone_layer: OptionButton
var _local_zone_coord_label: Label
var _local_zone_status_label: Label
var _local_zone_selecting := false
var _local_zone_cell := Vector2i(-1, -1)
var _local_zone_result: Dictionary = {}
var _local_zone_previews: Dictionary = {}
var _local_zone_preview_mode := false

# --- Constants ---
const BASE_PATH_SLIDERS = "ImageFrame/Control General/Control_Parameters/SC Parameters/Parameters_tree"
const PRESETS_DIR = "user://presets/"
const SFX_GENERATION_DONE = "res://data/sound/Foley UI E.wav"

const CATEGORIES_PATHS = {
	"GENERAL" : BASE_PATH_SLIDERS+"/General_Categorie/MarginContainer/Parameters/",
	"EROSION" : BASE_PATH_SLIDERS+"/Erosion_Tectonic_Categorie/MarginContainer/Erosion_Tectonic_parameters/",
	"CRATER" : BASE_PATH_SLIDERS+"/Crater_Categorie/MarginContainer/Crater_parameters/",
	"EAU" : BASE_PATH_SLIDERS+"/Eau_Categorie/MarginContainer/Eaux_parameters/",
	"NUAGE" : BASE_PATH_SLIDERS+"/Nuages_Categorie/MarginContainer/nuage_parameters/",
	"REGION" : BASE_PATH_SLIDERS+"/Region_Categorie/MarginContainer/Region_parameters/",
	"OCEAN" : BASE_PATH_SLIDERS+"/Region_Ocean_Categorie/MarginContainer/Region_Ocean_parameters/",
	"RESSOURCES" : BASE_PATH_SLIDERS+"/Ressources_Categorie/MarginContainer/Ressources_parameters/",
}

const MAP_NAME_TO_KEY = {
	"topographie_map.png": "MAP_TOPOGRAPHIE",
	"topographie_map_grey.png": "MAP_TOPOGRAPHIE_GREY",
	"topology_map.png": "MAP_TOPOLOGY",
	"eaux_map.png": "MAP_EAUX",
	"plaques_map.png": "MAP_PLAQUES",
	"plaques_bordures_map.png": "MAP_PLAQUES_BORDURES",
	"clouds_map.png": "MAP_CLOUDS",
	"precipitation_map.png": "MAP_PRECIPITATION",
	"temperature_map.png": "MAP_TEMPERATURE",
	"water_map.png": "MAP_WATER",
	"river_map.png": "MAP_RIVERS",
	"river_type_map.png": "MAP_RIVER_TYPE",
	"ice_caps_map.png": "MAP_ICE",
	"biome_map.png": "MAP_BIOMES",
	"cartographic_map.png": "MAP_CARTHOGRAPHIC",
	"grid_overlay.png": "MAP_GRID_OVERLAY",
	"final_map.png": "MAP_FINAL",
	"departement_map.png": "MAP_DEPARTEMENT",
	"region_map.png": "MAP_REGIONS",
	"pays_map.png": "MAP_PAYS",
	"continent_map.png": "MAP_CONTINENTS",
	"departement_mer_map.png": "MAP_DEPARTEMENT_MER",
	"region_mer_map.png": "MAP_OCEAN_REGIONS",
	"bassin_map.png": "MAP_BASSIN",
	"ocean_map.png": "MAP_OCEAN",
	"preview.png": "MAP_PREVIEW",
	"petrole_map.png": "MAP_PETROLE",
	"ressource_map.png": "MAP_RESOURCES",
}

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready() -> void:
	# 1. Language Setup
	if OS.get_locale_language() != "fr":
		langue = "en"
	TranslationServer.set_locale(langue)

	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")

	# 2. Audio player for SFX
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.bus = "Master"
	_sfx_player.volume_db = 25.0
	add_child(_sfx_player)

	# 3. Ensure presets directory exists
	DirAccess.make_dir_recursive_absolute(PRESETS_DIR)

	# 4. UI Initialization
	maj_labels()
	_setup_local_zone_ui()

# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	# UI Gather Data
	var nom          = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit")
	var lblMapStatus = $"ImageFrame/LabelNomMap"
	var generation_params = _compile_generation_params()

	# Reset state
	maps      = []
	map_index = 0
	_reset_local_zone_ui_state()
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")

	# Le constructeur du nouveau générateur acquiert immédiatement le device
	# partagé et alloue ses textures. Libérer l'ancienne planète AVANT d'évaluer
	# PlanetGenerator.new() empêche le chevauchement de deux jeux de ressources.
	_release_planet_generator()

	# Initialize Generator
	planetGenerator = PlanetGenerator.new(
		nom.text, 
		generation_params,
		"user://temp/",
		lblMapStatus,
	)
	
	# Bind the current epoch so stale callbacks from a replaced generator can
	# never operate on the new one.
	var generation_epoch := _generation_epoch
	planetGenerator.finished.connect(
		_on_planetGenerator_finished.bind(generation_epoch),
		CONNECT_ONE_SHOT,
	)

	print("Génération de la planète : " + nom.text)

	var generation_started = planetGenerator.generate_planet()

	# Ne pas bloquer l'interface si l'initialisation GPU a tout de même échoué.
	_set_buttons_enabled(not generation_started)


func _release_planet_generator() -> void:
	# Invalidate both the signal callback and its deferred UI continuation
	# before releasing GPU state.
	_generation_epoch += 1
	if planetGenerator:
		planetGenerator.cleanup()
		planetGenerator = null


func _exit_tree() -> void:
	_is_exiting = true
	_release_planet_generator()
	GPUContext.shutdown_shared_device()

func _on_planetGenerator_finished(generation_epoch: int) -> void:
	call_deferred("_on_planetGenerator_finished_main", generation_epoch)

func _on_planetGenerator_finished_main(generation_epoch: int) -> void:
	if (
		_is_exiting
		or generation_epoch != _generation_epoch
		or not is_instance_valid(planetGenerator)
	):
		return

	# 1. Update 2D Maps (Standard Logic)
	maps = planetGenerator.getMaps()
	map_index = 0
	if maps.is_empty():
		push_warning("[Master] Generation completed without exportable maps")
		_set_buttons_enabled(true)
		return
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = tex
		update_map_label()
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

	# 2. Play completion sound
	var sfx = load(SFX_GENERATION_DONE)
	if sfx:
		_sfx_player.stream = sfx
		_sfx_player.play()

	# 3. Re-enable UI
	_set_buttons_enabled(true)

func _set_buttons_enabled(enabled: bool) -> void:
	$"ImageFrame/Control General/btnGenerer".disabled = !enabled
	$"ImageFrame/Control General/btnSauvegarder".disabled = !enabled
	$"ImageFrame/Control General/btnRandomiser".disabled  = !enabled
	$"ImageFrame/btnSuivant".disabled   = !enabled
	$"ImageFrame/btnPrecedent".disabled = !enabled

## Compile et normalise les paramètres de génération pour le GPU.
##
## Cette méthode transforme les entrées utilisateur (UI) en un dictionnaire de constantes physiques
## strictes utilisables par le [GPUOrchestrator].
## Elle calcule notamment la densité de l'atmosphère, la gravité de surface et le rayon planétaire.
##
## @return Dictionary: Un dictionnaire contenant 'seed', 'planet_radius', 'atmo_density', 'gravity', etc.
func _compile_generation_params() -> Dictionary:
	"""
	Compile all generation parameters into a single dictionary
	This is passed to the GPU orchestrator and shaders
	"""
	var _seed = get_node(BASE_PATH_SLIDERS+"/PanelSeed/seed/LineEdit").value
	if _seed == 0:
		randomize()
		_seed = randi()
	
	var planet_radius_km := float(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit").value)
	var canonical_resolution := PlanetGridContract.logical_dimensions(planet_radius_km)
	var typePlanete   = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Type_Param/LineEdit").get_selected_id()
	if typePlanete == -1:
		typePlanete = 0  # Default to Earth-like if none selected

	var generation_params = {
		"seed"              : _seed,
		# CPU-only PNG conversion policy. Zero selects the automatic worker
		# count; GPU generation always uses one controlled RenderingDevice queue.
		"export_worker_count": get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/LineEdit").value,

		# Planet properties
		"planet_radius"     : planet_radius_km,
		"planet_density"    : get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit").value,
		"planet_type"       : typePlanete, # 0: Earth-like, 1: Thin, 2: Thick
		# Canonical equal-area grid. Physical radius and sampling are separate
		# inputs; external callers may still provide an explicit low-resolution
		# override for previews/tests without changing planet_radius.
		"resolution"        : canonical_resolution,
		"global_dimensions" : canonical_resolution,
		"global_cell_area_km2": PlanetGridContract.effective_cell_area_km2(planet_radius_km, canonical_resolution),
		"tile_size"         : PlanetGridContract.DEFAULT_TILE_SIZE,
		"projection"        : PlanetGridContract.PROJECTION_ID,
		"tiled_global_generation": false,
		"vram_budget_bytes" : TiledGlobalGenerator.HARD_VRAM_BUDGET_BYTES,
		"export_cartographic_map": true,
		"export_grid_overlay": true,
		"cartography_palette_path": CartographicPalette.DEFAULT_PATH,
		"cartography_view": CartographicRenderer.VIEW_PLANET,
		"cartography_grid_alpha": 166,
		"avg_temperature"   : get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit").value,
		
		# Erosion and tectonics
		"terrain_scale"      : get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit").value, # 0
		"erosion_iterations" : get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit").value, # 100
		"erosion_rate"       : get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit").value, # 0.05
		"rain_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit").value, # 0.005
		"evap_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit").value, # 0.02
		"flow_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit").value, # 0.25
		"deposition_rate"    : get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit").value, # 0.05
		"capacity_multiplier": get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit").value, # 1.0
		"flux_iterations"    : get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit").value, # 10
		"base_flux"          : get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit").value, #1.0
		"propagation_rate"   : get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit").value, # 0.8
		"spreading_rate"    : get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit").value, # 50.0
		"max_crust_age"     : get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit").value, # 200.0
		"subsidence_coeff"  : get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit").value, # 2800.0

		# Craters
		"crater_density"     : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit").value, # 0.5
		"crater_max_radius"  : min(canonical_resolution.x, canonical_resolution.y) * 0.08,
		"crater_min_radius"  : min(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit").value, min(canonical_resolution.x, canonical_resolution.y) * 0.08),
		"crater_depth_ratio" : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit").value, # 0.25
		"crater_ejecta_extent": get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit").value, # 2.5
		"crater_ejecta_decay" : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit").value, # 3.0
		"crater_azimuth_var"  : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit").value, # 0.3

		# Clouds
		"cloud_coverage"    : get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit").value, # 0.5
		"cloud_density"     : get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit").value,  # 0.8

		# Ice caps
		"ice_probability" : get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit").value, # 0.9

		# Water bodies
		"ocean_ratio"       : get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit").value,  # Pourcentage couverture océanique 70.0
		"global_humidity"   : get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit").value, # 0.5
		"sea_level"         : get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit").value, # 0.0
		"saltwater_min_size" : get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value+1, # 1000
		"freshwater_max_size": get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value, # 999
		"lake_threshold"     : get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit").value, # 5.0

		"river_iterations"   : get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit").value, # 2000
		# Nouveau système de rivières : les seuils sont définis par défaut dans orchestrator.gd
		# river_affluent_threshold = 50.0, river_riviere_threshold = 200.0, river_fleuve_threshold = 800.0
		# river_precip_scale = 1.0 (utiliser River_Base_Flux_Param comme proxy si besoin)

		# Regions
		"nb_cases_regions" : get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit").value, # 50
		"region_cost_flat" : get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit").value, # 1.0
		"region_cost_hill" : get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit").value, # 2.0
		"region_cost_river": get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit").value, # 3.0
		"region_river_threshold" : get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit").value, # 1.0
		"region_budget_variation": get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit").value, # 0.5
		"region_noise_strength"  : get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit").value, # 0.5
		"region_iterations"	     : max(canonical_resolution.x, canonical_resolution.y) * 2,

		# Regions Ocean 
		"nb_cases_ocean_regions": get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit").value, # 100
		"ocean_cost_flat"   : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit").value, # 1.0
		"ocean_cost_deeper" : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit").value, # 2.0
		"ocean_noise_strength" : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit").value, # 0.5
		"ocean_iterations"	   : max(canonical_resolution.x, canonical_resolution.y) * 2,

		# Resources
		"petrole_probability"  : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit").value, # 0.025
		"petrole_deposit_size" : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit").value, # 200.0
		"global_richness"      : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit").value, # 1.0
	}
	
	print("[PlanetGenerator] Parameters compiled:")
	print("  Seed: ", generation_params["seed"])

	return generation_params


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
	var lbl = $"ImageFrame/LabelNomMap"
	lbl.text = get_map_display_name(maps[map_index])

func _on_btn_suivant_pressed() -> void:
	if _local_zone_preview_mode:
		_local_zone_preview_mode = false
	if maps.is_empty(): return 
	map_index = (map_index + 1) % maps.size()
	_load_current_map()

func _on_btn_precedant_pressed() -> void:
	if _local_zone_preview_mode:
		_local_zone_preview_mode = false
	if maps.is_empty(): return 
	map_index -= 1
	if map_index < 0: map_index = maps.size() - 1
	_load_current_map()

func _load_current_map() -> void:
	var img = Image.new()
	if img.load(maps[map_index]) == OK:
		var tex = ImageTexture.create_from_image(img)
		$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = tex
		update_map_label()

func _on_fold_button_pressed(cible : String) -> void:
	print("Node : ", get_node(cible))
	var margin_container = get_node(cible) as MarginContainer
	margin_container.visible = !margin_container.visible

# ============================================================================
# MILESTONE 7 — LOCAL ZONE UI
# ============================================================================

func _setup_local_zone_ui() -> void:
	var map_control := $"ImageFrame/ImageMenu/Control Images/Frame Map/Map" as TextureRect
	map_control.mouse_filter = Control.MOUSE_FILTER_STOP
	if not map_control.gui_input.is_connected(_on_global_map_gui_input):
		map_control.gui_input.connect(_on_global_map_gui_input)

	var layer := CanvasLayer.new()
	layer.name = "LocalZoneUILayer"
	layer.layer = 20
	add_child(layer)

	_local_zone_toggle_button = Button.new()
	_local_zone_toggle_button.name = "LocalZoneToggle"
	_local_zone_toggle_button.text = "LOCAL ZONE"
	_local_zone_toggle_button.position = Vector2(18, 18)
	_local_zone_toggle_button.pressed.connect(_on_local_zone_toggle_pressed)
	layer.add_child(_local_zone_toggle_button)

	_local_zone_panel = PanelContainer.new()
	_local_zone_panel.name = "LocalZonePanel"
	_local_zone_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_local_zone_panel.position = Vector2(18, 58)
	_local_zone_panel.custom_minimum_size = Vector2(300, 0)
	_local_zone_panel.visible = false
	layer.add_child(_local_zone_panel)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.045, 0.045, 0.94)
	panel_style.border_color = Color(0.93, 0.62, 0.0, 0.92)
	panel_style.set_border_width_all(1)
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_top_right = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	_local_zone_panel.add_theme_stylebox_override("panel", panel_style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 7)
	_local_zone_panel.add_child(root)

	var title := Label.new()
	title.text = "LOCAL ZONE — M7"
	title.add_theme_color_override("font_color", Color(0.93, 0.62, 0.0))
	title.add_theme_font_size_override("font_size", 20)
	root.add_child(title)

	var hint := Label.new()
	hint.text = "Select a 1 km² global cell, then generate detailed terrain."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 276
	root.add_child(hint)

	_local_zone_coord_label = Label.new()
	_local_zone_coord_label.text = "Cell: none"
	root.add_child(_local_zone_coord_label)

	_local_zone_select_button = Button.new()
	_local_zone_select_button.text = "SELECT ON GLOBAL MAP"
	_local_zone_select_button.pressed.connect(_on_local_zone_select_pressed)
	root.add_child(_local_zone_select_button)

	var resolution_row := HBoxContainer.new()
	root.add_child(resolution_row)
	var resolution_label := Label.new()
	resolution_label.text = "Resolution"
	resolution_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resolution_row.add_child(resolution_label)
	_local_zone_resolution = OptionButton.new()
	for value in [256, 512, 1024, 2048]:
		_local_zone_resolution.add_item("%d × %d" % [value, value], value)
	_local_zone_resolution.select(2)
	resolution_row.add_child(_local_zone_resolution)

	_local_zone_generate_button = Button.new()
	_local_zone_generate_button.text = "GENERATE LOCAL ZONE"
	_local_zone_generate_button.disabled = true
	_local_zone_generate_button.pressed.connect(_on_local_zone_generate_pressed)
	root.add_child(_local_zone_generate_button)

	var layer_row := HBoxContainer.new()
	root.add_child(layer_row)
	var layer_label := Label.new()
	layer_label.text = "Preview"
	layer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_row.add_child(layer_label)
	_local_zone_layer = OptionButton.new()
	for layer_name in [
		"height", "normals", "slope", "water", "flow", "soil", "soil_moisture",
		"soil_depth", "rock", "surface", "vegetation", "resources", "snow_ice",
		"spawn", "hazard",
	]:
		_local_zone_layer.add_item(layer_name.capitalize())
		_local_zone_layer.set_item_metadata(_local_zone_layer.item_count - 1, layer_name)
	_local_zone_layer.disabled = true
	_local_zone_layer.item_selected.connect(_on_local_zone_layer_selected)
	layer_row.add_child(_local_zone_layer)

	var buttons := HBoxContainer.new()
	root.add_child(buttons)
	_local_zone_export_button = Button.new()
	_local_zone_export_button.text = "EXPORT PNG"
	_local_zone_export_button.disabled = true
	_local_zone_export_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_zone_export_button.pressed.connect(_on_local_zone_export_pressed)
	buttons.add_child(_local_zone_export_button)
	_local_zone_back_button = Button.new()
	_local_zone_back_button.text = "GLOBAL MAP"
	_local_zone_back_button.disabled = true
	_local_zone_back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_zone_back_button.pressed.connect(_on_local_zone_back_pressed)
	buttons.add_child(_local_zone_back_button)

	_local_zone_status_label = Label.new()
	_local_zone_status_label.text = "Ready after planet generation."
	_local_zone_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_local_zone_status_label)


func _on_local_zone_toggle_pressed() -> void:
	_local_zone_panel.visible = not _local_zone_panel.visible
	_local_zone_toggle_button.text = "CLOSE LOCAL ZONE" if _local_zone_panel.visible else "LOCAL ZONE"


func _reset_local_zone_ui_state() -> void:
	_local_zone_selecting = false
	_local_zone_cell = Vector2i(-1, -1)
	_local_zone_result = {}
	_local_zone_previews = {}
	_local_zone_preview_mode = false
	if is_instance_valid(_local_zone_coord_label):
		_local_zone_coord_label.text = "Cell: none"
	if is_instance_valid(_local_zone_generate_button):
		_local_zone_generate_button.disabled = true
	if is_instance_valid(_local_zone_layer):
		_local_zone_layer.disabled = true
	if is_instance_valid(_local_zone_export_button):
		_local_zone_export_button.disabled = true
	if is_instance_valid(_local_zone_back_button):
		_local_zone_back_button.disabled = true
	if is_instance_valid(_local_zone_select_button):
		_local_zone_select_button.text = "SELECT ON GLOBAL MAP"
	if is_instance_valid(_local_zone_status_label):
		_local_zone_status_label.text = "Ready after planet generation."


func _on_local_zone_select_pressed() -> void:
	if planetGenerator == null or maps.is_empty():
		_local_zone_status_label.text = "Generate a planet first."
		return
	if _local_zone_preview_mode:
		_on_local_zone_back_pressed()
	_local_zone_selecting = not _local_zone_selecting
	_local_zone_select_button.text = "CANCEL SELECTION" if _local_zone_selecting else "SELECT ON GLOBAL MAP"
	_local_zone_status_label.text = (
		"Click anywhere on the displayed global map."
		if _local_zone_selecting else "Selection cancelled."
	)


func _on_global_map_gui_input(event: InputEvent) -> void:
	if not _local_zone_selecting or planetGenerator == null:
		return
	if not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	var map_control := $"ImageFrame/ImageMenu/Control Images/Frame Map/Map" as TextureRect
	if map_control.texture == null or map_control.size.x <= 0.0 or map_control.size.y <= 0.0:
		return
	var uv := Vector2(
		clampf(mouse_event.position.x / map_control.size.x, 0.0, 0.999999),
		clampf(mouse_event.position.y / map_control.size.y, 0.0, 0.999999)
	)
	var dimensions: Vector2i = planetGenerator.generation_params.get(
		"global_dimensions", planetGenerator.generation_params.get("resolution", Vector2i(1, 1))
	)
	_local_zone_cell = Vector2i(
		clampi(floori(uv.x * dimensions.x), 0, dimensions.x - 1),
		clampi(floori(uv.y * dimensions.y), 0, dimensions.y - 1)
	)
	var world := PlanetGridContract.global_cell_to_world(_local_zone_cell, dimensions)
	_local_zone_coord_label.text = "Cell: %d, %d   Lon: %.2f°   Lat: %.2f°" % [
		_local_zone_cell.x, _local_zone_cell.y, rad_to_deg(world.x), rad_to_deg(world.y)
	]
	_local_zone_generate_button.disabled = false
	_local_zone_selecting = false
	_local_zone_select_button.text = "SELECT ANOTHER CELL"
	_local_zone_status_label.text = "Selected 1 km² zone. Choose resolution and generate."
	get_viewport().set_input_as_handled()


func _on_local_zone_generate_pressed() -> void:
	if planetGenerator == null or _local_zone_cell.x < 0:
		return
	var resolution := _local_zone_resolution.get_selected_id()
	if resolution <= 0:
		resolution = 1024
	_local_zone_status_label.text = "Generating %d × %d local terrain…" % [resolution, resolution]
	_local_zone_generate_button.disabled = true
	_local_zone_select_button.disabled = true
	# M7 is deterministic and cache-backed. This call is CPU-heavy at 1024²;
	# keep it on the main thread because the monolithic macro sampler may need
	# RenderingDevice readback during sampler construction.
	_local_zone_result = planetGenerator.generate_local_zone(_local_zone_cell, resolution, true)
	_local_zone_select_button.disabled = false
	_local_zone_generate_button.disabled = false
	if _local_zone_result.is_empty():
		_local_zone_status_label.text = "Local generation failed; check global authoritative layers."
		return
	_local_zone_previews = LocalZoneDebugExporter.build_previews(_local_zone_result)
	if _local_zone_previews.is_empty():
		_local_zone_status_label.text = "Zone generated, but previews could not be built."
		return
	_local_zone_layer.disabled = false
	_local_zone_export_button.disabled = false
	_local_zone_back_button.disabled = false
	_local_zone_preview_mode = true
	_local_zone_status_label.text = "Local terrain ready%s." % (
		" (cache hit)" if bool(_local_zone_result.get("cache_hit", false)) else ""
	)
	_show_local_zone_layer(str(_local_zone_layer.get_item_metadata(_local_zone_layer.selected)))


func _on_local_zone_layer_selected(index: int) -> void:
	if index < 0 or index >= _local_zone_layer.item_count:
		return
	_show_local_zone_layer(str(_local_zone_layer.get_item_metadata(index)))


func _show_local_zone_layer(layer_name: String) -> void:
	if not _local_zone_previews.has(layer_name):
		return
	var image: Image = _local_zone_previews[layer_name]
	if image == null or image.is_empty():
		return
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = ImageTexture.create_from_image(image)
	$"ImageFrame/LabelNomMap".text = "LOCAL — %s — CELL %d,%d" % [
		layer_name.to_upper(), _local_zone_cell.x, _local_zone_cell.y
	]
	_local_zone_preview_mode = true


func _on_local_zone_export_pressed() -> void:
	if planetGenerator == null or _local_zone_result.is_empty():
		return
	var output_dir := "user://temp/local_zone_%d_%d/" % [_local_zone_cell.x, _local_zone_cell.y]
	var exported := planetGenerator.export_local_zone_previews(_local_zone_result, output_dir)
	if exported.is_empty():
		_local_zone_status_label.text = "PNG export failed."
	else:
		_local_zone_status_label.text = "Exported %d previews → %s" % [exported.size(), output_dir]


func _on_local_zone_back_pressed() -> void:
	_local_zone_preview_mode = false
	if not maps.is_empty():
		_load_current_map()
	_local_zone_status_label.text = "Global map restored; local zone remains cached."


# ============================================================================
# SLIDER CALLBACKS
# ============================================================================

func _set_slider_label(slider_label: Label, tr_key: String, value, unit: String = "") -> void:
	print("Setting slider label for ", tr_key, " to value: ", str(value) + unit)
	slider_label.text = tr(tr_key).format({"val": str(value) + unit})


func _on_range_change_terrain_scale(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/Label"), "TERRAIN_SCALE", get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit").value, " m")
func _on_range_change_thread_number(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/Label"), "THREAD_NUMBER", get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/LineEdit").value)
func _on_range_change_ocean_ratio(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/Label"), "OCEAN_RATIO", get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit").value, "%")
func _on_range_change_planet_radius(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/Label"), "PLANET_RADIUS", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit").value, " km")
func _on_range_change_planet_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/Label"), "PLANET_DENSITY", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit").value, " g/cm³")
func _on_range_change_planet_temperature_avg(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/Label"), "PLANET_TEMPERATURE_AVG", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit").value, " °C")

func _on_range_change_erosion_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/Label"), "EROSION_ITERATIONS", get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit").value)
func _on_range_change_erosion_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/Label"), "EROSION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit").value)
func _on_range_change_rain_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/Label"), "RAIN_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit").value)
func _on_range_change_evap_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/Label"), "EVAP_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit").value)
func _on_range_change_flow_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/Label"), "FLOW_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit").value)

func _on_range_change_deposition_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/Label"), "DEPOSITION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit").value)
func _on_range_change_capacity_multiplier(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/Label"), "CAPACITY_MULTIPLIER", get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit").value)
func _on_range_change_flux_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/Label"), "FLUX_ITERATIONS", get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit").value)
func _on_range_change_base_flux(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/Label"), "BASE_FLUX", get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit").value)
func _on_range_change_propagation_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/Label"), "PROPAGATION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit").value)
func _on_range_change_spreading_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/Label"), "SPREADING_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit").value)
func _on_range_change_max_crust_age(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/Label"), "MAX_CRUST_AGE", get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit").value, " Myr")
func _on_range_change_subsidence_coefficient(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/Label"), "SUBSIDENCE_COEFFICIENT", get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit").value, " m/Myr")


func _on_range_change_crater_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/Label"), "CRATER_DENSITY", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit").value)
func _on_range_change_crater_min_radius(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/Label"), "CRATER_MIN_RADIUS", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit").value, " km")
func _on_range_change_crater_depth_ratio(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/Label"), "CRATER_DEPTH_RATIO", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit").value)
func _on_range_change_crater_ejecta_extent(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/Label"), "CRATER_EJECTA_EXTENT", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit").value)
func _on_range_change_crater_ejecta_decay(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/Label"), "CRATER_EJECTA_DECAY", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit").value)
func _on_range_change_crater_azimuth_var(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/Label"), "CRATER_AZIMUTH_VAR", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit").value)


func _on_range_change_ice_probability(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/Label"), "ICE_PROBABILITY", get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit").value, "%")
func _on_range_change_global_humidity(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/Label"), "GLOBAL_HUMIDITY", get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit").value, "%")
func _on_range_change_sea_level(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/Label"), "SEA_LEVEL", get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit").value, " m")
func _on_range_change_freshwater_max_size(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/Label"), "FRESHWATER_MAX_SIZE", get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value, " km²")
func _on_range_change_lake_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/Label"), "LAKE_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit").value)
func _on_range_change_river_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/Label"), "RIVER_ITERATIONS", get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit").value)
func _on_range_change_river_affluent_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/Label"), "RIVER_AFFLUENT_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/LineEdit").value)
func _on_range_change_river_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/Label"), "RIVER_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/LineEdit").value)
func _on_range_change_river_fleuve_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/Label"), "RIVER_FLEUVE_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/LineEdit").value)

func _on_range_change_cloud_coverage(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/Label"), "CLOUD_COVERAGE", get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit").value, "%")
func _on_range_change_cloud_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/Label"), "CLOUD_DENSITY", get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit").value, "%")


func _on_range_change_nb_cases_regions(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/Label"), "NB_CASES_REGIONS", get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit").value)
func _on_range_change_region_cost_flat(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/Label"), "REGION_COST_FLAT", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit").value)
func _on_range_change_region_cost_hill(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/Label"), "REGION_COST_HILL", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit").value)
func _on_range_change_region_cost_river(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/Label"), "REGION_COST_RIVER", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit").value)
func _on_range_change_region_river_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/Label"), "REGION_RIVER_THRESHOLD", get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit").value)
func _on_range_change_region_budget_variation(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/Label"), "REGION_BUDGET_VARIATION", get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit").value)
func _on_range_change_region_noise_strength(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/Label"), "REGION_NOISE_STRENGTH", get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit").value)


func _on_range_change_nb_cases_ocean_regions(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/Label"), "NB_CASES_OCEAN_REGIONS", get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit").value)
func _on_range_change_ocean_cost_flat(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/Label"), "OCEAN_COST_FLAT", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit").value)
func _on_range_change_ocean_cost_deeper(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/Label"), "OCEAN_COST_DEEPER", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit").value)
func _on_range_change_ocean_noise_strength(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/Label"), "OCEAN_NOISE_STRENGTH", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit").value)
func _on_range_change_petrole_probability(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/Label"), "PETROLE_PROBABILITY", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit").value, "%")
func _on_range_change_petrole_deposit_size(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/Label"), "PETROLE_DEPOSIT_SIZE", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit").value, " km²")
func _on_range_change_global_richness(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/Label"), "GLOBAL_RICHNESS", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit").value)

func maj_labels() -> void:
	# TODO : REPLACE THE NODE PATH WITH CORRECT ONES
	_on_range_change_thread_number()
	_on_range_change_planet_radius()
	_on_range_change_planet_density()
	_on_range_change_planet_temperature_avg()

	_on_range_change_terrain_scale()
	_on_range_change_erosion_iterations()
	_on_range_change_erosion_rate()
	_on_range_change_rain_rate()
	_on_range_change_evap_rate()
	_on_range_change_flow_rate()
	_on_range_change_deposition_rate()
	_on_range_change_capacity_multiplier()
	_on_range_change_flux_iterations()
	_on_range_change_base_flux()
	_on_range_change_propagation_rate()
	_on_range_change_spreading_rate()
	_on_range_change_max_crust_age()
	_on_range_change_subsidence_coefficient()
	
	_on_range_change_crater_density()
	_on_range_change_crater_min_radius()
	_on_range_change_crater_depth_ratio()
	_on_range_change_crater_ejecta_extent()
	_on_range_change_crater_ejecta_decay()
	_on_range_change_crater_azimuth_var()

	_on_range_change_ocean_ratio()
	_on_range_change_ice_probability()
	_on_range_change_global_humidity()
	_on_range_change_sea_level()
	_on_range_change_freshwater_max_size()
	_on_range_change_lake_threshold()
	_on_range_change_river_iterations()
	_on_range_change_river_affluent_threshold()
	_on_range_change_river_threshold()
	_on_range_change_river_fleuve_threshold()

	_on_range_change_cloud_coverage()
	_on_range_change_cloud_density()
	_on_range_change_nb_cases_regions()
	_on_range_change_region_cost_flat()
	_on_range_change_region_cost_hill()
	_on_range_change_region_cost_river()
	_on_range_change_region_river_threshold()
	_on_range_change_region_budget_variation()
	_on_range_change_region_noise_strength()

	_on_range_change_nb_cases_ocean_regions()
	_on_range_change_ocean_cost_flat()
	_on_range_change_ocean_cost_deeper()
	_on_range_change_ocean_noise_strength()

	_on_range_change_petrole_probability()
	_on_range_change_petrole_deposit_size()
	_on_range_change_global_richness()
	
# ============================================================================
# LANGUAGE & SYSTEM
# ============================================================================

func _on_btn_french_pressed() -> void: _change_lang("fr")
func _on_btn_english_pressed() -> void: _change_lang("en")
func _on_btn_german_pressed() -> void: _change_lang("de")

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
	var file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.title = tr("Select Export Directory")
	file_dialog.min_size = Vector2i(600, 400)
	add_child(file_dialog)
	file_dialog.popup_centered()
	file_dialog.dir_selected.connect(func(dir_path):
		if planetGenerator != null:
			if planetGenerator.nom == "":
				planetGenerator.nom = "Planète Générée"
			planetGenerator.cheminSauvegarde = dir_path + "/" + planetGenerator.nom
			planetGenerator.save_maps()
			print("Planète sauvegardée dans : ", planetGenerator.cheminSauvegarde)
		else:
			print("Aucun générateur de planète actif.")
		file_dialog.queue_free())

func _on_random_seed_pressed() -> void:
	var generation_seed = randi()
	get_node(BASE_PATH_SLIDERS+"/PanelSeed/seed/LineEdit").value = generation_seed

func _on_random_name_pressed() -> void:
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", 
	"Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", 
	"Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega",
	"Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra",
	"Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]

	var random_name = prefixes[randi() % prefixes.size()] + "-" + str(randi() % 999 + 1)

	if randf() > 0.5: random_name += " " + suffixes[randi() % suffixes.size()]

	get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit").text = random_name

func _on_btn_randomise_pressed() -> void:
	randomize()
	
	# Name
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", 
	"Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", 
	"Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega",
	"Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra",
	"Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]
	var random_name = prefixes[randi() % prefixes.size()] + "-" + str(randi() % 999 + 1)
	if randf() > 0.5: random_name += " " + suffixes[randi() % suffixes.size()]
	get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit").text = random_name
	
	# Sliders
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit"))
	# Keep the export worker policy automatic when randomizing planet physics.
	
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit"))
	
	# Type
	var typePlanete = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Type_Param/LineEdit")
	typePlanete.select(randi() % typePlanete.item_count)
	
	_on_random_seed_pressed()

	maj_labels()

func _randomize_slider(slider: Slider) -> void:
	var max_nb_steps = int((slider.max_value - slider.min_value) / slider.step)
	var random_step = randi() % (max_nb_steps + 1)
	slider.value = slider.min_value + float(random_step) * slider.step


# ============================================================================
# PRESET SAVE / LOAD SYSTEM
# ============================================================================

## Mapping des clés de paramètre → chemins relatifs des sliders/contrôles dans l'UI.
## Utilisé pour sérialiser et désérialiser les presets.
const PARAM_SLIDER_MAP = {
	# General
	"planet_name"        : "GENERAL:Planet_Name_Param/HBoxContainer/LineEdit",
	"seed"               : "SEED:PanelSeed/seed/LineEdit",
	"export_worker_count": "GENERAL:Thread_Number_Param/LineEdit",
	"planet_radius"      : "GENERAL:Planet_Radius_Param/LineEdit",
	"planet_density"     : "GENERAL:Planet_Density_Param/LineEdit",
	"planet_type"        : "GENERAL:Planet_Type_Param/LineEdit",
	"avg_temperature"    : "GENERAL:Planet_Temperature_Param/LineEdit",
	# Erosion
	"terrain_scale"      : "EROSION:Terrain_Scale_Param/LineEdit",
	"erosion_iterations" : "EROSION:Erosions_Iterations_Param/LineEdit",
	"erosion_rate"       : "EROSION:Erosion_Rate_Param/LineEdit",
	"rain_rate"          : "EROSION:Rain_Rate_Param/LineEdit",
	"evap_rate"          : "EROSION:Evap_Rate_Param/LineEdit",
	"flow_rate"          : "EROSION:Flow_Rate_Param/LineEdit",
	"deposition_rate"    : "EROSION:Deposition_Rate_Param/LineEdit",
	"capacity_multiplier": "EROSION:Capacity_Multiplier_Param/LineEdit",
	"flux_iterations"    : "EROSION:Flux_Iterations_Param/LineEdit",
	"base_flux"          : "EROSION:Base_Flux_Param/LineEdit",
	"propagation_rate"   : "EROSION:Propagation_Rate_Param/LineEdit",
	"spreading_rate"     : "EROSION:Spreading_Rate_Param/LineEdit",
	"max_crust_age"      : "EROSION:Max_Crust_Age_Param/LineEdit",
	"subsidence_coeff"   : "EROSION:Subsidence_Coeff_Param/LineEdit",
	# Craters
	"crater_density"     : "CRATER:Crater_Density_Param/LineEdit",
	"crater_min_radius"  : "CRATER:Crater_Min_Radius_Param/LineEdit",
	"crater_depth_ratio" : "CRATER:Crater_Depth_Ratio_Param/LineEdit",
	"crater_ejecta_extent": "CRATER:Crater_Ejecta_Extent_Param/LineEdit",
	"crater_ejecta_decay": "CRATER:Crater_Ejecta_Decay_Param/LineEdit",
	"crater_azimuth_var" : "CRATER:Crater_Azimuth_Var_Param/LineEdit",
	# Water
	"ocean_ratio"        : "EAU:Ocean_Ratio_Param/LineEdit",
	"ice_probability"    : "EAU:Ice_Probability_Param/LineEdit",
	"global_humidity"    : "EAU:Global_Humidity_Param/LineEdit",
	"sea_level"          : "EAU:Sea_Level_Param/LineEdit",
	"freshwater_max_size": "EAU:Freshwater_Max_Size_Param/LineEdit",
	"lake_threshold"     : "EAU:Lake_Threshold_Param/LineEdit",
	"river_iterations"   : "EAU:River_Iterations_Param/LineEdit",
	# Clouds
	"cloud_coverage"     : "NUAGE:Cloud_Coverage_Param/LineEdit",
	"cloud_density"      : "NUAGE:Cloud_Density_Param/LineEdit",
	# Regions
	"nb_cases_regions"   : "REGION:Nb_Cases_Regions_Param/LineEdit",
	"region_cost_flat"   : "REGION:Region_Cost_Flat_Param/LineEdit",
	"region_cost_hill"   : "REGION:Region_Cost_Hill_Param/LineEdit",
	"region_cost_river"  : "REGION:Region_Cost_River_Param/LineEdit",
	"region_river_threshold": "REGION:Region_River_Threshold_Param/LineEdit",
	"region_budget_variation": "REGION:Region_Budget_Variation_Param/LineEdit",
	"region_noise_strength"  : "REGION:Region_Noise_Strength_Param/LineEdit",
	# Ocean Regions
	"nb_cases_ocean_regions"  : "OCEAN:Nb_Cases_Ocean_Regions_Param/LineEdit",
	"ocean_cost_flat"    : "OCEAN:Ocean_Cost_Flat_Param/LineEdit",
	"ocean_cost_deeper"  : "OCEAN:Ocean_Cost_Deeper_Param/LineEdit",
	"ocean_noise_strength": "OCEAN:Ocean_Noise_Strength_Param/LineEdit",
	# Resources
	"petrole_probability"  : "RESSOURCES:Petrole_Probability_Param/LineEdit",
	"petrole_deposit_size" : "RESSOURCES:Petrole_Deposit_Size_Param/LineEdit",
	"global_richness"      : "RESSOURCES:Global_Richness_Param/LineEdit",
}

## Résout le chemin complet d'un contrôle UI à partir de la forme "CATEGORY:relative_path"
func _resolve_param_path(mapping: String) -> String:
	if mapping.begins_with("SEED:"):
		return BASE_PATH_SLIDERS + "/" + mapping.substr(5)
	var parts = mapping.split(":", true, 1)
	if parts.size() != 2:
		push_error("[Preset] Invalid mapping: ", mapping)
		return ""
	var category = parts[0]
	var relative = parts[1]
	if not CATEGORIES_PATHS.has(category):
		push_error("[Preset] Unknown category: ", category)
		return ""
	return CATEGORIES_PATHS[category] + relative

## Collecte tous les paramètres UI dans un Dictionary sérialisable.
func _collect_preset_data() -> Dictionary:
	var data: Dictionary = {}
	data["_meta"] = {
		"version": 1,
		"date": Time.get_datetime_string_from_system(),
	}

	for key in PARAM_SLIDER_MAP:
		var path = _resolve_param_path(PARAM_SLIDER_MAP[key])
		if path.is_empty():
			continue
		var node = get_node_or_null(path)
		if node == null:
			push_warning("[Preset] Node introuvable: ", path)
			continue

		if key == "planet_name":
			data[key] = node.text
		elif key == "planet_type":
			data[key] = node.get_selected_id()
		else:
			data[key] = node.value
	return data

## Écrit les données preset dans un fichier.
func _write_preset_to_file(file_path: String, data: Dictionary) -> bool:
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("[Preset] Impossible d'écrire: ", file_path, " - ", FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	print("[Preset] ✅ Sauvegardé: ", file_path)
	return true

## Ouvre un FileDialog pour sauvegarder les paramètres actuels en .planetGeneratorParam.
func save_preset() -> void:
	var file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.title = "Sauvegarder le preset"
	file_dialog.min_size = Vector2i(700, 500)
	file_dialog.filters = PackedStringArray(["*.planetGeneratorParam ; Planet Generator Preset"])
	add_child(file_dialog)
	file_dialog.popup_centered()
	file_dialog.file_selected.connect(func(path: String):
		# Assurer l'extension correcte
		if not path.ends_with(".planetGeneratorParam"):
			path += ".planetGeneratorParam"
		var data = _collect_preset_data()
		data["_meta"]["name"] = path.get_file().get_basename()
		_write_preset_to_file(path, data)
		file_dialog.queue_free())
	file_dialog.canceled.connect(func():
		file_dialog.queue_free())

## Ouvre un FileDialog pour charger un preset .planetGeneratorParam.
func load_preset() -> void:
	var file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.title = "Charger un preset"
	file_dialog.min_size = Vector2i(700, 500)
	file_dialog.filters = PackedStringArray(["*.planetGeneratorParam ; Planet Generator Preset"])
	add_child(file_dialog)
	file_dialog.popup_centered()
	file_dialog.file_selected.connect(func(path: String):
		_load_preset_from_path(path)
		file_dialog.queue_free())
	file_dialog.canceled.connect(func():
		file_dialog.queue_free())

## Charge un preset depuis un chemin absolu et applique ses valeurs à l'UI.
func _load_preset_from_path(file_path: String) -> bool:
	if not FileAccess.file_exists(file_path):
		push_error("[Preset] Fichier introuvable: ", file_path)
		return false

	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("[Preset] Impossible de lire: ", file_path)
		return false

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_err = json.parse(json_text)
	if parse_err != OK:
		push_error("[Preset] JSON invalide: ", json.get_error_message())
		return false

	var data: Dictionary = json.data
	if not data is Dictionary:
		push_error("[Preset] Format invalide")
		return false

	for key in PARAM_SLIDER_MAP:
		if not data.has(key):
			continue
		var path = _resolve_param_path(PARAM_SLIDER_MAP[key])
		if path.is_empty():
			continue
		var node = get_node_or_null(path)
		if node == null:
			push_warning("[Preset] Node introuvable: ", path)
			continue

		if key == "planet_name":
			node.text = str(data[key])
		elif key == "planet_type":
			var type_id = int(data[key])
			for i in range(node.item_count):
				if node.get_item_id(i) == type_id:
					node.select(i)
					break
		else:
			node.value = float(data[key])

	maj_labels()
	print("[Preset] ✅ Chargé: ", file_path.get_file())
	return true

## Supprime un preset par chemin absolu.
func delete_preset(file_path: String) -> bool:
	if not FileAccess.file_exists(file_path):
		push_error("[Preset] Fichier introuvable: ", file_path)
		return false
	var err = DirAccess.remove_absolute(file_path)
	if err != OK:
		push_error("[Preset] Impossible de supprimer: ", file_path)
		return false
	print("[Preset] 🗑️ Supprimé: ", file_path.get_file())
	return true
