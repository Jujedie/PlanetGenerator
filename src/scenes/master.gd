extends Node2D

# --- Core Variables ---
var planetGenerator: PlanetGenerator
var maps: Array[String]
var map_index: int = 0
var langue: String = "fr"
var _sfx_player: AudioStreamPlayer
var _generation_epoch: int = 0
var _is_exiting: bool = false
var _loaded_project: Dictionary = {}
var _load_planet_button: Button
var _generation_status_panel: Control
var _generation_phase_label: Label
var _generation_progress_bar: ProgressBar
var _generation_memory_label: Label
var _cancel_generation_button: Button
var _generation_started_usec: int = 0
var _generation_phase_key: String = "GEN_STATUS_READY"
var _generation_phase_fallback: String = ""
var _generation_memory_key: String = "GEN_STATUS_IDLE"
var _generation_memory_args: Dictionary = {}
var _viewer_panel: Control
var _viewer_title_label: Label
var _viewer_base_select: OptionButton
var _viewer_overlay_select: OptionButton
var _viewer_overlay_alpha: HSlider
var _viewer_overlay_alpha_label: Label
var _viewer_overlay_texture: TextureRect
var _viewer_crosshair: PlanetMapCrosshair
var _viewer_inspector_label: Label
var _viewer_zoom_label: Label
var _viewer_reset_button: Button
var _viewer_zoom: float = 1.0
var _viewer_pan_origin := Vector2.ZERO
var _viewer_dragging: bool = false
var _viewer_image_cache: Dictionary = {}
var _viewer_workspace: ReferenceViewerWorkspace
var _parameter_workspace: ParameterWorkspace
var _viewer_map_viewport: PanelContainer
var _viewer_map_frame: Control
var _viewer_map_texture: TextureRect
var _viewer_empty_label: Label
var _viewer_help_label: Label
var _viewer_base_title_label: Label
var _viewer_overlay_title_label: Label
var _viewer_overlay_percent_label: Label
var _viewer_status_dot: Label
var _viewer_parameters_button: Button
var _viewer_load_action: Button
var _viewer_save_action: Button
var _legacy_map_status_label: Label

# --- Constants ---
const BASE_PATH_SLIDERS = "ParameterWorkspaceLayer/ParameterWorkspace/ParametersHost/Control_Parameters/SC Parameters/Parameters_tree"
const PRESETS_DIR = "user://presets/"
const SFX_GENERATION_DONE = "res://data/sound/Foley UI E.wav"
const UI_AMBER := Color(0.92549, 0.619608, 0.0, 1.0)
const UI_MUTED := Color(0.39, 0.43, 0.44, 1.0)

const GENERATION_PHASE_TRANSLATION_KEYS := {
	"gpu_initialization": "GEN_PHASE_GPU_INITIALIZATION",
	"base_elevation": "GEN_PHASE_BASE_ELEVATION",
	"crust_age": "GEN_PHASE_CRUST_AGE",
	"cratering": "GEN_PHASE_CRATERING",
	"pre_erosion_climate": "GEN_PHASE_PRE_EROSION_CLIMATE",
	"erosion": "GEN_PHASE_EROSION",
	"final_climate": "GEN_PHASE_FINAL_CLIMATE",
	"water": "GEN_PHASE_WATER",
	"ice_caps": "GEN_PHASE_ICE_CAPS",
	"biomes": "GEN_PHASE_BIOMES",
	"land_regions": "GEN_PHASE_LAND_REGIONS",
	"ocean_regions": "GEN_PHASE_OCEAN_REGIONS",
	"resources": "GEN_PHASE_RESOURCES",
	"final_map": "GEN_PHASE_FINAL_MAP",
	"export": "GEN_PHASE_EXPORT",
	"complete": "GEN_PHASE_COMPLETE",
	"global_hydrology_context": "GEN_PHASE_GLOBAL_HYDROLOGY_CONTEXT",
	"terrain_tectonics": "GEN_PHASE_TERRAIN_TECTONICS",
	"climate": "GEN_PHASE_CLIMATE",
	"hydrology": "GEN_PHASE_HYDROLOGY",
	"classification": "GEN_PHASE_CLASSIFICATION",
}

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

	_ensure_legacy_map_status_label()
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")

	# 2. Audio player for SFX
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.bus = "Master"
	_sfx_player.volume_db = 25.0
	add_child(_sfx_player)

	# 3. Ensure presets directory exists
	DirAccess.make_dir_recursive_absolute(PRESETS_DIR)

	# 4. UI Initialization
	_setup_project_loader_ui()
	_setup_generation_status_ui()
	_setup_workspace_scenes()
	maj_labels()


func _ensure_legacy_map_status_label() -> void:
	_legacy_map_status_label = get_node_or_null("ImageFrame/LabelNomMap") as Label
	if _legacy_map_status_label != null:
		return
	# The advanced viewer replaced the old map-name label in the authored scene,
	# but PlanetGenerator still expects a Label sink for textual phase updates.
	_legacy_map_status_label = Label.new()
	_legacy_map_status_label.name = "RuntimeMapStatus"
	_legacy_map_status_label.visible = false
	add_child(_legacy_map_status_label)


func _setup_workspace_scenes() -> void:
	_viewer_workspace = preload("res://data/scn/reference_viewer_workspace.tscn").instantiate() as ReferenceViewerWorkspace
	add_child(_viewer_workspace)
	_parameter_workspace = preload("res://data/scn/parameter_workspace.tscn").instantiate() as ParameterWorkspace
	add_child(_parameter_workspace)

	# Reuse the complete authored parameter tree instead of maintaining a second
	# copy. Existing signal connections survive the reparenting operation.
	var legacy_parameters := $"ImageFrame/Control General/Control_Parameters" as MarginContainer
	legacy_parameters.reparent(_parameter_workspace.parameters_host, false)
	legacy_parameters.visible = true
	$ImageFrame.visible = false

	_generation_status_panel = _viewer_workspace.header_panel
	_generation_phase_label = _viewer_workspace.phase_label
	_generation_memory_label = _viewer_workspace.memory_label
	_generation_progress_bar = _viewer_workspace.progress_bar
	_cancel_generation_button = _viewer_workspace.cancel_button
	_viewer_status_dot = _viewer_workspace.status_dot
	_viewer_panel = _viewer_workspace.viewer_panel
	_viewer_title_label = _viewer_workspace.viewer_title_label
	_viewer_base_title_label = _viewer_workspace.base_title_label
	_viewer_base_select = _viewer_workspace.base_select
	_viewer_overlay_title_label = _viewer_workspace.overlay_title_label
	_viewer_overlay_select = _viewer_workspace.overlay_select
	_viewer_overlay_alpha_label = _viewer_workspace.opacity_title_label
	_viewer_overlay_alpha = _viewer_workspace.opacity_slider
	_viewer_overlay_percent_label = _viewer_workspace.opacity_percent_label
	_viewer_zoom_label = _viewer_workspace.zoom_label
	_viewer_reset_button = _viewer_workspace.reset_button
	_viewer_inspector_label = _viewer_workspace.inspector_label
	_viewer_help_label = _viewer_workspace.help_label
	_viewer_map_viewport = _viewer_workspace.map_viewport
	_viewer_map_frame = _viewer_workspace.map_canvas
	_viewer_map_texture = _viewer_workspace.map_texture
	_viewer_overlay_texture = _viewer_workspace.overlay_texture
	_viewer_crosshair = _viewer_workspace.crosshair
	_viewer_empty_label = _viewer_workspace.empty_label
	_viewer_parameters_button = _viewer_workspace.parameters_button
	_viewer_load_action = _viewer_workspace.load_button
	_viewer_save_action = _viewer_workspace.save_button

	_viewer_parameters_button.pressed.connect(_show_parameters_workspace)
	_cancel_generation_button.pressed.connect(_on_cancel_generation_pressed)
	_viewer_load_action.pressed.connect(_on_load_planet_project_pressed)
	_viewer_save_action.pressed.connect(_on_btn_sauvegarder_pressed)
	_viewer_map_viewport.gui_input.connect(_on_map_viewer_input)
	_viewer_base_select.item_selected.connect(_on_viewer_base_selected)
	_viewer_overlay_select.item_selected.connect(_on_viewer_overlay_selected)
	_viewer_overlay_alpha.value_changed.connect(_on_viewer_overlay_alpha_changed)
	_viewer_reset_button.pressed.connect(_reset_viewer_transform)

	_parameter_workspace.viewer_button.pressed.connect(_show_viewer_workspace)
	_parameter_workspace.load_preset_button.pressed.connect(load_preset)
	_parameter_workspace.save_preset_button.pressed.connect(save_preset)
	_parameter_workspace.quit_button.pressed.connect(_on_btn_quitter_pressed)
	_parameter_workspace.french_button.pressed.connect(_on_btn_french_pressed)
	_parameter_workspace.english_button.pressed.connect(_on_btn_english_pressed)
	_parameter_workspace.german_button.pressed.connect(_on_btn_german_pressed)
	_parameter_workspace.generate_button.pressed.connect(_on_btn_comfirme_pressed)
	_parameter_workspace.random_button.pressed.connect(_on_btn_randomise_pressed)
	_parameter_workspace.save_planet_button.pressed.connect(_on_btn_sauvegarder_pressed)

	_viewer_workspace.visible = true
	_parameter_workspace.visible = false
	_viewer_pan_origin = Vector2.ZERO
	_refresh_generation_status_translation()
	_refresh_advanced_viewer_translation()
	_refresh_parameter_workspace_translation()
	_update_viewer_sources()
	_sync_reference_map()


func _refresh_parameter_workspace_translation() -> void:
	if _parameter_workspace == null:
		return
	_parameter_workspace.preview_title_label.text = tr("VIEWER_PREVIEW")
	_parameter_workspace.parameter_title_label.text = tr("PARAMETRES").to_upper()
	_parameter_workspace.viewer_button.text = tr("MAP_VIEWER_TITLE").to_upper()
	_parameter_workspace.load_preset_button.text = tr("LOAD_PRESET")
	_parameter_workspace.save_preset_button.text = tr("SAVE_PRESET")
	_parameter_workspace.quit_button.text = tr("LEAVE")
	_parameter_workspace.generate_button.text = tr("GENERER")
	_parameter_workspace.random_button.text = tr("RANDOMISE")
	_parameter_workspace.save_planet_button.text = tr("SAUVEGARDER")
	_parameter_workspace.preview_empty_label.text = "%s\n%s" % [tr("VIEWER_EMPTY_TITLE"), tr("VIEWER_EMPTY_HINT")]




func _show_parameters_workspace() -> void:
	_viewer_workspace.visible = false
	_parameter_workspace.visible = true
	_parameter_workspace.set_preview_texture(_viewer_map_texture.texture)


func _show_viewer_workspace() -> void:
	_viewer_workspace.visible = true
	_parameter_workspace.visible = false
	_sync_reference_map()


func _sync_reference_map() -> void:
	if _viewer_map_texture == null:
		return
	var has_map := not maps.is_empty() and map_index >= 0 and map_index < maps.size()
	_viewer_empty_label.visible = not has_map
	_viewer_map_frame.visible = has_map
	_viewer_save_action.disabled = not has_map
	_parameter_workspace.set_preview_texture(null)
	if not has_map:
		_viewer_map_texture.texture = null
		_viewer_overlay_texture.texture = null
		return
	var image := _viewer_load_image(maps[map_index])
	if image != null:
		var texture := ImageTexture.create_from_image(image)
		_viewer_map_texture.texture = texture
		_parameter_workspace.set_preview_texture(texture)


func _set_map_texture(texture: Texture2D) -> void:
	var legacy_map := $"ImageFrame/ImageMenu/Control Images/Frame Map/Map" as TextureRect
	legacy_map.texture = texture
	if _viewer_map_texture != null:
		_viewer_map_texture.texture = texture
		_viewer_map_frame.visible = texture != null
		_viewer_empty_label.visible = texture == null
		_viewer_save_action.disabled = texture == null
	if _parameter_workspace != null:
		_parameter_workspace.set_preview_texture(texture)




func _refresh_advanced_viewer_translation() -> void:
	if _viewer_panel == null:
		return
	_viewer_title_label.text = tr("MAP_VIEWER_TITLE")
	if _viewer_base_title_label != null:
		_viewer_base_title_label.text = tr("MAP_VIEWER_BASE")
	if _viewer_overlay_title_label != null:
		_viewer_overlay_title_label.text = tr("MAP_VIEWER_OVERLAY")
	_viewer_base_select.tooltip_text = tr("MAP_VIEWER_BASE_TOOLTIP")
	_viewer_overlay_select.tooltip_text = tr("MAP_VIEWER_OVERLAY_TOOLTIP")
	_viewer_overlay_alpha_label.text = tr("MAP_VIEWER_OVERLAY_OPACITY")
	_viewer_reset_button.text = tr("MAP_VIEWER_RESET")
	_viewer_zoom_label.text = tr("MAP_VIEWER_ZOOM").format({"percent": int(round(_viewer_zoom * 100.0))})
	_viewer_overlay_alpha.tooltip_text = "%s: %d%%" % [tr("MAP_VIEWER_OVERLAY_OPACITY"), int(round(_viewer_overlay_alpha.value * 100.0))]
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".tooltip_text = tr("MAP_VIEWER_INSPECT_HINT")
	if _viewer_empty_label != null:
		_viewer_empty_label.text = "%s\n%s" % [tr("VIEWER_EMPTY_TITLE"), tr("VIEWER_EMPTY_HINT")]
	if _viewer_help_label != null:
		_viewer_help_label.text = tr("VIEWER_HELP")
	if _viewer_parameters_button != null:
		_viewer_parameters_button.text = tr("PARAMETRES").to_upper()
	if _viewer_load_action != null:
		_viewer_load_action.text = "▰  " + tr("LOAD_PLANET").to_upper()
	if _viewer_save_action != null:
		_viewer_save_action.text = tr("SAUVEGARDER").to_upper()
	if _cancel_generation_button != null:
		_cancel_generation_button.text = tr("GEN_CANCEL").to_upper()
	if not _viewer_crosshair.has_point:
		_viewer_inspector_label.visible = true
		_viewer_inspector_label.text = tr("MAP_VIEWER_INSPECT_HINT")
	_update_viewer_sources()


func _update_viewer_sources() -> void:
	if _viewer_base_select == null:
		return
	var selected_base := clampi(map_index, 0, maxi(maps.size() - 1, 0))
	var selected_overlay_path := ""
	if _viewer_overlay_select != null and _viewer_overlay_select.selected >= 0:
		selected_overlay_path = str(_viewer_overlay_select.get_item_metadata(_viewer_overlay_select.selected))
	_viewer_base_select.clear()
	_viewer_overlay_select.clear()
	_viewer_overlay_select.add_item(tr("MAP_VIEWER_NO_OVERLAY"))
	_viewer_overlay_select.set_item_metadata(0, "")
	var overlay_selection := 0
	for i in range(maps.size()):
		var path := maps[i]
		_viewer_base_select.add_item(get_map_display_name(path))
		_viewer_base_select.set_item_metadata(_viewer_base_select.item_count - 1, i)
		var file_name := path.get_file()
		if file_name in ["grid_overlay.png", "topology_map.png", "river_map.png", "plaques_bordures_map.png"]:
			_viewer_overlay_select.add_item(get_map_display_name(path))
			_viewer_overlay_select.set_item_metadata(_viewer_overlay_select.item_count - 1, path)
			if path == selected_overlay_path:
				overlay_selection = _viewer_overlay_select.item_count - 1
	if not maps.is_empty():
		_viewer_base_select.select(selected_base)
	_viewer_overlay_select.select(overlay_selection)


func _on_viewer_base_selected(index: int) -> void:
	if index < 0 or index >= _viewer_base_select.item_count:
		return
	map_index = int(_viewer_base_select.get_item_metadata(index))
	_load_current_map()


func _on_viewer_overlay_selected(index: int) -> void:
	if index < 0 or index >= _viewer_overlay_select.item_count:
		return
	var path := str(_viewer_overlay_select.get_item_metadata(index))
	if path.is_empty():
		_viewer_overlay_texture.texture = null
		return
	var image := _viewer_load_image(path)
	if image != null:
		_viewer_overlay_texture.texture = ImageTexture.create_from_image(image)


func _on_viewer_overlay_alpha_changed(value: float) -> void:
	_viewer_overlay_texture.modulate.a = clampf(value, 0.0, 1.0)
	if _viewer_overlay_percent_label != null:
		_viewer_overlay_percent_label.text = "%d%%" % int(round(value * 100.0))
	_viewer_overlay_alpha.tooltip_text = "%s: %d%%" % [
		tr("MAP_VIEWER_OVERLAY_OPACITY"), int(round(value * 100.0))
	]


func _viewer_load_image(path: String) -> Image:
	if _viewer_image_cache.has(path):
		return _viewer_image_cache[path]
	var image := Image.new()
	if image.load(path) != OK:
		return null
	_viewer_image_cache[path] = image
	return image


func _on_map_viewer_input(event: InputEvent) -> void:
	var frame := _viewer_map_frame
	if frame == null:
		frame = $"ImageFrame/ImageMenu/Control Images/Frame Map" as Control
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_set_viewer_zoom(_viewer_zoom * 1.15)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_set_viewer_zoom(_viewer_zoom / 1.15)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_viewer_dragging = event.pressed
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var local_point: Vector2 = (event.position - frame.position) / frame.scale
			_inspect_map_point(local_point)
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseMotion and _viewer_dragging:
		frame.position += event.relative
		get_viewport().set_input_as_handled()


func _set_viewer_zoom(value: float) -> void:
	_viewer_zoom = clampf(value, 1.0, 8.0)
	var frame := _viewer_map_frame
	if frame == null:
		frame = $"ImageFrame/ImageMenu/Control Images/Frame Map" as Control
	frame.pivot_offset = frame.size * 0.5
	frame.scale = Vector2.ONE * _viewer_zoom
	_viewer_zoom_label.text = tr("MAP_VIEWER_ZOOM").format({"percent": int(round(_viewer_zoom * 100.0))})


func _reset_viewer_transform() -> void:
	_viewer_zoom = 1.0
	var frame := _viewer_map_frame
	if frame == null:
		frame = $"ImageFrame/ImageMenu/Control Images/Frame Map" as Control
	frame.scale = Vector2.ONE
	frame.position = Vector2.ZERO if _viewer_map_frame != null else _viewer_pan_origin
	_viewer_zoom_label.text = tr("MAP_VIEWER_ZOOM").format({"percent": 100})
	_viewer_crosshair.clear_point()
	_viewer_inspector_label.visible = true
	_viewer_inspector_label.text = tr("MAP_VIEWER_INSPECT_HINT")


func _inspect_map_point(local_point: Vector2) -> void:
	if maps.is_empty():
		return
	var map_control := _viewer_map_texture
	if map_control == null:
		map_control = $"ImageFrame/ImageMenu/Control Images/Frame Map/Map" as TextureRect
	if map_control.size.x <= 0.0 or map_control.size.y <= 0.0:
		return
	var image := _viewer_load_image(maps[map_index])
	if image == null:
		return
	var uv := Vector2(
		clampf(local_point.x / map_control.size.x, 0.0, 0.999999),
		clampf(local_point.y / map_control.size.y, 0.0, 0.999999)
	)
	var cell := Vector2i(
		int(floor(uv.x * image.get_width())),
		int(floor(uv.y * image.get_height()))
	)
	var lon_lat := PlanetGridContract.global_cell_to_world(cell, image.get_size())
	var color := image.get_pixelv(cell)
	_viewer_crosshair.set_point(local_point)
	_viewer_inspector_label.visible = true
	_viewer_inspector_label.text = tr("MAP_VIEWER_INSPECT_VALUE").format({
		"x": cell.x, "y": cell.y,
		"lon": "%.3f" % rad_to_deg(lon_lat.x),
		"lat": "%.3f" % rad_to_deg(lon_lat.y),
		"r": "%.3f" % color.r, "g": "%.3f" % color.g,
		"b": "%.3f" % color.b, "a": "%.3f" % color.a,
	})


func _setup_generation_status_ui() -> void:
	_generation_status_panel = $"ImageFrame/ImageMenu/Control Images/GenerationStatusPanel"
	_generation_phase_label = $"ImageFrame/ImageMenu/Control Images/GenerationStatusPanel/VBoxContainer/Header/PhaseLabel"
	_generation_progress_bar = $"ImageFrame/ImageMenu/Control Images/GenerationStatusPanel/VBoxContainer/GenerationProgressBar"
	_generation_memory_label = $"ImageFrame/ImageMenu/Control Images/GenerationStatusPanel/VBoxContainer/Header/MemoryLabel"
	_cancel_generation_button = $"ImageFrame/ImageMenu/Control Images/GenerationStatusPanel/VBoxContainer/Header/CancelGenerationButton"
	_set_generation_phase_text("GEN_STATUS_READY")
	_generation_progress_bar.min_value = 0
	_generation_progress_bar.max_value = 100
	_generation_progress_bar.value = 0
	_generation_progress_bar.show_percentage = true
	_set_generation_memory_text("GEN_STATUS_IDLE")
	_generation_memory_label.tooltip_text = tr("GEN_STATUS_MEMORY_TOOLTIP")
	_cancel_generation_button.disabled = true
	if not _cancel_generation_button.pressed.is_connected(_on_cancel_generation_pressed):
		_cancel_generation_button.pressed.connect(_on_cancel_generation_pressed)

func _set_generation_phase_text(key: String, fallback: String = "") -> void:
	_generation_phase_key = key
	_generation_phase_fallback = fallback
	if key.is_empty():
		_generation_phase_label.text = fallback
	else:
		var translated := tr(key)
		_generation_phase_label.text = fallback if translated == key and not fallback.is_empty() else translated
	if _viewer_status_dot != null:
		if key == "GEN_STATUS_COMPLETE":
			_viewer_status_dot.add_theme_color_override("font_color", Color(0.16, 0.75, 0.2, 1.0))
		elif key in ["GEN_STATUS_CANCELLED", "GEN_STATUS_UNAVAILABLE"]:
			_viewer_status_dot.add_theme_color_override("font_color", Color(0.82, 0.18, 0.16, 1.0))
		elif key == "GEN_STATUS_READY":
			_viewer_status_dot.add_theme_color_override("font_color", UI_MUTED)
		else:
			_viewer_status_dot.add_theme_color_override("font_color", UI_AMBER)


func _set_generation_memory_text(key: String, args: Dictionary = {}) -> void:
	_generation_memory_key = key
	_generation_memory_args = args.duplicate(true)
	var translated := tr(key)
	_generation_memory_label.text = translated.format(args) if not args.is_empty() else translated


func _refresh_generation_status_translation() -> void:
	_set_generation_phase_text(_generation_phase_key, _generation_phase_fallback)
	_set_generation_memory_text(_generation_memory_key, _generation_memory_args)
	_generation_memory_label.tooltip_text = tr("GEN_STATUS_MEMORY_TOOLTIP")
	if _cancel_generation_button != null:
		_cancel_generation_button.text = tr("GEN_CANCEL").to_upper()


func _show_generation_status(params: Dictionary) -> void:
	_show_viewer_workspace()
	_generation_started_usec = Time.get_ticks_usec()
	_generation_progress_bar.value = 0
	_set_generation_phase_text("GEN_STATUS_PREPARING")
	var dims: Vector2i = params.get("global_dimensions", params.get("resolution", Vector2i.ZERO))
	# Deliberately conservative UI estimate: several authoritative fields plus
	# working textures coexist in the monolithic path.
	var estimate := int(dims.x) * int(dims.y) * 64
	_set_generation_memory_text("GEN_STATUS_MEMORY", {"width": dims.x, "height": dims.y, "gib": "%.2f" % (float(estimate) / 1073741824.0)})
	_cancel_generation_button.disabled = false

func _on_generation_progress(phase: String, completed: int, total: int) -> void:
	var safe_total := maxi(total, 1)
	var phase_key := str(GENERATION_PHASE_TRANSLATION_KEYS.get(phase, ""))
	_set_generation_phase_text(phase_key, phase.replace("_", " ").capitalize())
	_generation_progress_bar.value = clampf(float(completed) * 100.0 / float(safe_total), 0.0, 98.0)

func _on_cancel_generation_pressed() -> void:
	if planetGenerator != null:
		_cancel_generation_button.disabled = true
		_set_generation_phase_text("GEN_STATUS_CANCELLING")
		planetGenerator.cancel_generation("user")

func _on_generation_cancelled(reason: String) -> void:
	_set_generation_phase_text("GEN_STATUS_CANCELLED")
	_generation_progress_bar.value = 0
	_set_generation_memory_text("GEN_STATUS_CANCELLED_REASON", {"reason": reason})
	_cancel_generation_button.disabled = true
	_set_buttons_enabled(true)
	_legacy_map_status_label.text = "Generation cancelled (%s)" % reason

func _setup_project_loader_ui() -> void:
	_load_planet_button = $"ImageFrame/Control General/btnLoadPlanetProject"
	_load_planet_button.focus_mode = Control.FOCUS_NONE
	if not _load_planet_button.pressed.is_connected(_on_load_planet_project_pressed):
		_load_planet_button.pressed.connect(_on_load_planet_project_pressed)


func _on_load_planet_project_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = tr("LOAD_PLANET_DIALOG_TITLE")
	dialog.filters = PackedStringArray(["planet_project.json ; Planet Generator Project"])
	dialog.min_size = Vector2i(700, 450)
	add_child(dialog)
	dialog.file_selected.connect(func(path: String):
		_load_planet_project(path)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _load_planet_project(path: String) -> void:
	var project := PlanetProject.load_project(path)
	if not bool(project.get("ok", false)):
		push_error("[Master] Cannot load planet project: %s" % project.get("reason", "unknown"))
		return
	_release_planet_generator()
	_loaded_project = project
	maps = project.get("maps", [])
	map_index = 0
	_viewer_image_cache.clear()
	_update_viewer_sources()
	if maps.is_empty():
		push_warning("[Master] Project contains no displayable PNG maps")
		return
	_show_map_path(maps[0])
	var manifest: Dictionary = project.get("manifest", {})
	_legacy_map_status_label.text = "%s — loaded project" % manifest.get("planet_name", "Planet")
	_show_viewer_workspace()


func _show_map_path(path: String) -> bool:
	var image := Image.new()
	if image.load(path) != OK:
		push_warning("[Master] Cannot load map: " + path)
		return false
	_set_map_texture(ImageTexture.create_from_image(image))
	update_map_label()
	return true


# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	_loaded_project = {}
	# UI Gather Data
	var nom          = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit")
	var lblMapStatus := _legacy_map_status_label
	var generation_params = _compile_generation_params()

	# Reset state
	maps      = []
	map_index = 0
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")
	_sync_reference_map()

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
	planetGenerator.generation_progress.connect(_on_generation_progress)
	planetGenerator.generation_cancelled.connect(_on_generation_cancelled, CONNECT_ONE_SHOT)

	print("Génération de la planète : " + nom.text)
	_show_generation_status(generation_params)

	var generation_started = planetGenerator.generate_planet()

	# Ne pas bloquer l'interface si l'initialisation GPU a tout de même échoué.
	_set_buttons_enabled(not generation_started)
	if not generation_started:
		_set_generation_phase_text("GEN_STATUS_UNAVAILABLE")
		_set_generation_memory_text("GEN_STATUS_GPU_START_FAILED")
		_cancel_generation_button.disabled = true


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
	# Drain all GPU cleanup jobs and destroy the shared local RenderingDevice on
	# its owning background thread. Blocking here is safe because the app exits.
	GPUGenerationWorker.shutdown()

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
	_viewer_image_cache.clear()
	_update_viewer_sources()
	if maps.is_empty():
		push_warning("[Master] Generation completed without exportable maps")
		_set_buttons_enabled(true)
		return
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		_set_map_texture(tex)
		update_map_label()
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

	_generation_progress_bar.value = 100
	_set_generation_phase_text("GEN_STATUS_COMPLETE")
	var elapsed_s := float(Time.get_ticks_usec() - _generation_started_usec) / 1000000.0
	_set_generation_memory_text("GEN_STATUS_COMPLETED_IN", {"seconds": "%.2f" % elapsed_s})
	_cancel_generation_button.disabled = true

	# 2. Play completion sound
	var sfx = load(SFX_GENERATION_DONE)
	if sfx:
		_sfx_player.stream = sfx
		_sfx_player.play()

	# 3. Re-enable UI
	_set_buttons_enabled(true)

func _set_buttons_enabled(enabled: bool) -> void:
	for node_path in [
		"ImageFrame/Control General/btnGenerer",
		"ImageFrame/Control General/btnSauvegarder",
		"ImageFrame/Control General/btnRandomiser",
		"ImageFrame/btnSuivant",
		"ImageFrame/btnPrecedent",
	]:
		var button := get_node_or_null(node_path) as BaseButton
		if button != null:
			button.disabled = not enabled
	if _viewer_load_action != null:
		_viewer_load_action.disabled = not enabled
	if _viewer_parameters_button != null:
		_viewer_parameters_button.disabled = not enabled
	if _viewer_save_action != null:
		_viewer_save_action.disabled = not enabled or maps.is_empty()
	if _parameter_workspace != null:
		_parameter_workspace.generate_button.disabled = not enabled
		_parameter_workspace.random_button.disabled = not enabled
		_parameter_workspace.load_preset_button.disabled = not enabled
		_parameter_workspace.save_preset_button.disabled = not enabled
		_parameter_workspace.save_planet_button.disabled = not enabled or maps.is_empty()

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
		"run_integrity_checks": true,
		# M7.2 export presentation policy. Simulation data is unaffected.
		"export_preset": ExportCatalog.PRESET_STANDARD,
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

		# Country enclave cleanup. These remain advanced/non-UI parameters for now:
		# small detached or enclosed country fragments can be absorbed by a strongly
		# dominant neighbouring country, while remote islands remain untouched.
		"admin_country_enclave_cleanup": true,
		"admin_country_enclave_max_fraction": 0.30,
		"admin_country_enclave_dominance": 0.60,
		"admin_country_enclave_proximity_factor": 0.35,

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
	var file_name := file_path.get_file()
	if MAP_NAME_TO_KEY.has(file_name):
		return tr(MAP_NAME_TO_KEY[file_name])

	# Resource maps are numerous and M7.2 stores them below maps/resources/.
	# Derive their localization key from the stable file identifier instead of
	# maintaining a second 116-entry filename table in the UI. This also keeps
	# compatibility with the legacy `ressource/` export directory.
	var resource_key := _resource_map_translation_key(file_path)
	if not resource_key.is_empty():
		var translated := tr(resource_key)
		if translated != resource_key:
			return translated

	return file_name


func _resource_map_translation_key(file_path: String) -> String:
	var normalized := file_path.replace("\\", "/")
	var lower_path := normalized.to_lower()
	var parent_dir := normalized.get_base_dir().get_file().to_lower()
	var is_resource_path := (
		parent_dir in ["ressource", "resources"]
		or "/ressource/" in lower_path
		or "/resources/" in lower_path
	)
	if not is_resource_path:
		return ""
	var stem := normalized.get_file().get_basename()
	if not stem.ends_with("_map"):
		return ""
	stem = stem.trim_suffix("_map")
	if stem.is_empty():
		return ""
	return "RESOURCE_" + stem.to_upper()

func update_map_label() -> void:
	if maps.is_empty():
		return
	_legacy_map_status_label.text = get_map_display_name(maps[map_index])

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
		_set_map_texture(tex)
		update_map_label()
		if _viewer_base_select != null and _viewer_base_select.item_count == maps.size():
			_viewer_base_select.select(map_index)

func _on_fold_button_pressed(cible : String) -> void:
	print("Node : ", get_node(cible))
	var margin_container = get_node(cible) as MarginContainer
	margin_container.visible = !margin_container.visible

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
	_refresh_generation_status_translation()
	_refresh_advanced_viewer_translation()
	_refresh_parameter_workspace_translation()
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
