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
var _viewer_dragging: bool = false
var _viewer_image_cache: Dictionary = {}
var _viewer_shell_layer: CanvasLayer
var _viewer_shell_root: Control
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
var _parameter_workspace
var _viewer_workspace
var _batch_runner: BatchGenerationRunner

# --- Constants ---
const PRESETS_DIR = "user://presets/"
const SFX_GENERATION_DONE = "res://data/sound/Foley UI E.wav"
const PARAMETER_WORKSPACE_SCENE := preload("res://data/scn/parameter_workspace.tscn")
const REFERENCE_VIEWER_WORKSPACE_SCENE := preload("res://data/scn/reference_viewer_workspace.tscn")
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
	if OS.get_locale_language() != "fr":
		langue = "en"
	TranslationServer.set_locale(langue)

	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.bus = "Master"
	_sfx_player.volume_db = 25.0
	add_child(_sfx_player)

	DirAccess.make_dir_recursive_absolute(PRESETS_DIR)

	_setup_parameter_workspace()
	_setup_batch_runner()
	_setup_reference_viewer_workspace()
	maj_labels()
	_show_viewer_workspace()


func _setup_parameter_workspace() -> void:
	_parameter_workspace = PARAMETER_WORKSPACE_SCENE.instantiate()
	add_child(_parameter_workspace)
	_parameter_workspace.visible = false
	_parameter_workspace.set_save_planet_enabled(false)
	_parameter_workspace.generate_requested.connect(_on_btn_comfirme_pressed)
	_parameter_workspace.save_planet_requested.connect(_on_btn_sauvegarder_pressed)
	_parameter_workspace.load_preset_requested.connect(load_preset)
	_parameter_workspace.save_preset_requested.connect(save_preset)
	_parameter_workspace.viewer_requested.connect(_show_viewer_workspace)
	_parameter_workspace.quit_requested.connect(_on_btn_quitter_pressed)
	_parameter_workspace.language_requested.connect(_change_lang)
	_parameter_workspace.batch_start_requested.connect(_on_batch_start_requested)
	_parameter_workspace.batch_cancel_requested.connect(_on_batch_cancel_requested)


func _setup_batch_runner() -> void:
	_batch_runner = BatchGenerationRunner.new()
	_batch_runner.name = "BatchGenerationRunner"
	add_child(_batch_runner)
	_batch_runner.batch_progress.connect(_on_batch_progress)
	_batch_runner.batch_completed.connect(_on_batch_completed)


func _setup_reference_viewer_workspace() -> void:
	_viewer_workspace = REFERENCE_VIEWER_WORKSPACE_SCENE.instantiate()
	add_child(_viewer_workspace)

	_viewer_shell_layer = _viewer_workspace
	_viewer_shell_root = _viewer_workspace.root
	_viewer_status_dot = _viewer_workspace.status_dot
	_generation_phase_label = _viewer_workspace.phase_label
	_generation_memory_label = _viewer_workspace.memory_label
	_generation_progress_bar = _viewer_workspace.progress_bar
	_cancel_generation_button = _viewer_workspace.cancel_button
	_viewer_parameters_button = _viewer_workspace.parameters_button
	_viewer_map_viewport = _viewer_workspace.map_viewport
	_viewer_map_frame = _viewer_workspace.map_canvas
	_viewer_map_texture = _viewer_workspace.map_texture
	_viewer_overlay_texture = _viewer_workspace.overlay_texture
	_viewer_crosshair = _viewer_workspace.crosshair
	_viewer_empty_label = _viewer_workspace.empty_label
	_viewer_load_action = _viewer_workspace.load_button
	_viewer_save_action = _viewer_workspace.save_button
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

	_viewer_parameters_button.pressed.connect(_show_parameters_workspace)
	_cancel_generation_button.pressed.connect(_on_cancel_generation_pressed)
	_viewer_load_action.pressed.connect(_on_load_planet_project_pressed)
	_viewer_save_action.pressed.connect(_on_btn_sauvegarder_pressed)
	_viewer_base_select.item_selected.connect(_on_viewer_base_selected)
	_viewer_overlay_select.item_selected.connect(_on_viewer_overlay_selected)
	_viewer_overlay_alpha.value_changed.connect(_on_viewer_overlay_alpha_changed)
	_viewer_reset_button.pressed.connect(_reset_viewer_transform)
	_viewer_map_viewport.gui_input.connect(_on_map_viewer_input)

	_refresh_generation_status_translation()
	_refresh_advanced_viewer_translation()
	_update_viewer_sources()
	_sync_reference_map()

func _show_parameters_workspace() -> void:
	if _viewer_workspace != null:
		_viewer_workspace.visible = false
	if _parameter_workspace != null:
		_parameter_workspace.visible = true


func _show_viewer_workspace() -> void:
	if _parameter_workspace != null:
		_parameter_workspace.visible = false
	if _viewer_workspace != null:
		_viewer_workspace.visible = true
	_sync_reference_map()


func _sync_reference_map() -> void:
	if _viewer_map_texture == null:
		return
	var has_map := not maps.is_empty() and map_index >= 0 and map_index < maps.size()
	_viewer_empty_label.visible = not has_map
	_viewer_map_frame.visible = has_map
	_viewer_save_action.disabled = not has_map
	if not has_map:
		_viewer_map_texture.texture = null
		_viewer_overlay_texture.texture = null
		return
	var image := _viewer_load_image(maps[map_index])
	if image != null:
		_viewer_map_texture.texture = ImageTexture.create_from_image(image)


func _set_map_texture(texture: Texture2D) -> void:
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
		var display_name := get_map_display_name(path)
		_viewer_base_select.add_item(display_name)
		_viewer_base_select.set_item_metadata(_viewer_base_select.item_count - 1, i)
		# Any exported map can be used as an overlay. This is deliberately kept
		# symmetrical with the base selector so newly exported layers become
		# overlay-capable automatically without another hard-coded allow-list.
		_viewer_overlay_select.add_item(display_name)
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
	frame.pivot_offset = frame.size * 0.5
	frame.scale = Vector2.ONE * _viewer_zoom
	_viewer_zoom_label.text = tr("MAP_VIEWER_ZOOM").format({"percent": int(round(_viewer_zoom * 100.0))})


func _reset_viewer_transform() -> void:
	_viewer_zoom = 1.0
	var frame := _viewer_map_frame
	frame.scale = Vector2.ONE
	frame.position = Vector2.ZERO
	_viewer_zoom_label.text = tr("MAP_VIEWER_ZOOM").format({"percent": 100})
	_viewer_crosshair.clear_point()
	_viewer_inspector_label.visible = true
	_viewer_inspector_label.text = tr("MAP_VIEWER_INSPECT_HINT")


func _inspect_map_point(local_point: Vector2) -> void:
	if maps.is_empty():
		return
	var map_control := _viewer_map_texture
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
	_show_viewer_workspace()


func _show_map_path(path: String) -> bool:
	var image := Image.new()
	if image.load(path) != OK:
		push_warning("[Master] Cannot load map: " + path)
		return false
	_set_map_texture(ImageTexture.create_from_image(image))
	return true


# ============================================================================
# BATCH / BENCHMARK
# ============================================================================

func _on_batch_start_requested(count: int, first_seed: int) -> void:
	if _batch_runner == null or _batch_runner.running:
		return

	_release_planet_generator()
	var params: Dictionary = _compile_generation_params()
	var planet_name: String = str(_parameter_workspace.get_value("planet_name")).strip_edges()
	if planet_name.is_empty():
		planet_name = "Planet"
	var safe_name: String = planet_name.validate_filename()
	if safe_name.is_empty():
		safe_name = "Planet"
	var batch_root: String = "user://batch/%s_%d" % [
		safe_name,
		int(Time.get_unix_time_from_system()),
	]

	if _batch_runner.start(params, count, first_seed, batch_root, safe_name):
		_parameter_workspace.set_batch_running(true)
		_parameter_workspace.set_batch_status("BATCH_STARTING")
		_set_buttons_enabled(false)
	else:
		_parameter_workspace.set_batch_status("BATCH_START_FAILED")


func _on_batch_cancel_requested() -> void:
	if _batch_runner == null or not _batch_runner.running:
		return
	_batch_runner.cancel()
	_parameter_workspace.set_batch_status("BATCH_CANCELLING")


func _on_batch_progress(completed: int, total: int, seed: int, status: String) -> void:
	if _parameter_workspace != null:
		_parameter_workspace.set_batch_progress(completed, total, seed, status)


func _on_batch_completed(report: Dictionary) -> void:
	if _parameter_workspace != null:
		_parameter_workspace.set_batch_running(false)
		_parameter_workspace.set_batch_completed(report)
	_set_buttons_enabled(true)


# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	_loaded_project = {}
	var planet_name := str(_parameter_workspace.get_value("planet_name"))
	var generation_params = _compile_generation_params()

	# Reset state
	maps      = []
	map_index = 0
	_set_map_texture(null)
	_sync_reference_map()

	# Le constructeur du nouveau générateur acquiert immédiatement le device
	# partagé et alloue ses textures. Libérer l'ancienne planète AVANT d'évaluer
	# PlanetGenerator.new() empêche le chevauchement de deux jeux de ressources.
	_release_planet_generator()

	# Initialize Generator
	planetGenerator = PlanetGenerator.new(
		planet_name,
		generation_params,
		"user://temp/",
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

	print("Génération de la planète : " + planet_name)
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
	if _parameter_workspace != null:
		_parameter_workspace.set_save_planet_enabled(false)


func _exit_tree() -> void:
	_is_exiting = true
	if _batch_runner != null:
		_batch_runner.shutdown()
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
	if _parameter_workspace != null:
		_parameter_workspace.set_actions_enabled(enabled)
		_parameter_workspace.set_save_planet_enabled(enabled and planetGenerator != null and not maps.is_empty())
	if _viewer_load_action != null:
		_viewer_load_action.disabled = not enabled
	if _viewer_parameters_button != null:
		_viewer_parameters_button.disabled = not enabled
	if _viewer_save_action != null:
		_viewer_save_action.disabled = not enabled or maps.is_empty()


## Compile et normalise les paramètres de génération pour le GPU.
##
## Cette méthode transforme les entrées utilisateur (UI) en un dictionnaire de constantes physiques
## strictes utilisables par le [GPUOrchestrator].
## Elle calcule notamment la densité de l'atmosphère, la gravité de surface et le rayon planétaire.
##
## @return Dictionary: Un dictionnaire contenant 'seed', 'planet_radius', 'atmo_density', 'gravity', etc.
func _compile_generation_params() -> Dictionary:
	var ui = _parameter_workspace.get_values()
	var generation_seed := int(ui.get("seed", 0))
	if generation_seed == 0:
		randomize()
		generation_seed = randi()

	var planet_radius_km := float(ui["planet_radius"])
	var canonical_resolution := PlanetGridContract.logical_dimensions(planet_radius_km)
	var planet_type := int(ui.get("planet_type", 0))
	if planet_type < 0:
		planet_type = 0

	var generation_params := {
		"seed": generation_seed,
		"export_worker_count": ui["export_worker_count"],
		"planet_radius": planet_radius_km,
		"planet_density": ui["planet_density"],
		"planet_type": planet_type,
		"resolution": canonical_resolution,
		"global_dimensions": canonical_resolution,
		"global_cell_area_km2": PlanetGridContract.effective_cell_area_km2(planet_radius_km, canonical_resolution),
		"tile_size": PlanetGridContract.DEFAULT_TILE_SIZE,
		"projection": PlanetGridContract.PROJECTION_ID,
		"tiled_global_generation": false,
		"vram_budget_bytes": TiledGlobalGenerator.HARD_VRAM_BUDGET_BYTES,
		"export_cartographic_map": true,
		"export_grid_overlay": true,
		"cartography_palette_path": CartographicPalette.DEFAULT_PATH,
		"cartography_view": CartographicRenderer.VIEW_PLANET,
		"cartography_grid_alpha": 166,
		"run_integrity_checks": true,
		"export_preset": ExportCatalog.PRESET_STANDARD,
		"avg_temperature": ui["avg_temperature"],

		"terrain_scale": ui["terrain_scale"],
		"erosion_iterations": ui["erosion_iterations"],
		"erosion_rate": ui["erosion_rate"],
		"rain_rate": ui["rain_rate"],
		"evap_rate": ui["evap_rate"],
		"flow_rate": ui["flow_rate"],
		"deposition_rate": ui["deposition_rate"],
		"capacity_multiplier": ui["capacity_multiplier"],
		"flux_iterations": ui["flux_iterations"],
		"base_flux": ui["base_flux"],
		"propagation_rate": ui["propagation_rate"],
		"spreading_rate": ui["spreading_rate"],
		"max_crust_age": ui["max_crust_age"],
		"subsidence_coeff": ui["subsidence_coeff"],

		"crater_density": ui["crater_density"],
		"crater_max_radius": min(canonical_resolution.x, canonical_resolution.y) * 0.08,
		"crater_min_radius": min(float(ui["crater_min_radius"]), min(canonical_resolution.x, canonical_resolution.y) * 0.08),
		"crater_depth_ratio": ui["crater_depth_ratio"],
		"crater_ejecta_extent": ui["crater_ejecta_extent"],
		"crater_ejecta_decay": ui["crater_ejecta_decay"],
		"crater_azimuth_var": ui["crater_azimuth_var"],

		"cloud_coverage": ui["cloud_coverage"],
		"cloud_density": ui["cloud_density"],
		"ice_probability": ui["ice_probability"],

		"ocean_ratio": ui["ocean_ratio"],
		"global_humidity": ui["global_humidity"],
		"sea_level": ui["sea_level"],
		"saltwater_min_size": float(ui["freshwater_max_size"]) + 1.0,
		"freshwater_max_size": ui["freshwater_max_size"],
		"lake_threshold": ui["lake_threshold"],

		"nb_cases_regions": ui["nb_cases_regions"],
		"region_cost_flat": ui["region_cost_flat"],
		"region_cost_hill": ui["region_cost_hill"],
		"region_cost_river": ui["region_cost_river"],
		"region_river_threshold": ui["region_river_threshold"],
		"region_budget_variation": ui["region_budget_variation"],
		"region_noise_strength": ui["region_noise_strength"],
		"region_iterations": max(canonical_resolution.x, canonical_resolution.y) * 2,

		"admin_country_enclave_cleanup": true,
		"admin_country_enclave_max_fraction": 0.30,
		"admin_country_enclave_dominance": 0.60,
		"admin_country_enclave_proximity_factor": 0.35,

		"nb_cases_ocean_regions": ui["nb_cases_ocean_regions"],
		"ocean_cost_flat": ui["ocean_cost_flat"],
		"ocean_cost_deeper": ui["ocean_cost_deeper"],
		"ocean_noise_strength": ui["ocean_noise_strength"],
		"ocean_iterations": max(canonical_resolution.x, canonical_resolution.y) * 2,

		"petrole_probability": ui["petrole_probability"],
		"petrole_deposit_size": ui["petrole_deposit_size"],
		"global_richness": ui["global_richness"],
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

func _load_current_map() -> void:
	var img = Image.new()
	if img.load(maps[map_index]) == OK:
		var tex = ImageTexture.create_from_image(img)
		_set_map_texture(tex)
	if _viewer_base_select != null and _viewer_base_select.item_count == maps.size():
		_viewer_base_select.select(map_index)

func maj_labels() -> void:
	if _parameter_workspace != null:
		_parameter_workspace.refresh_translations()
	_refresh_generation_status_translation()
	_refresh_advanced_viewer_translation()


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
	if _parameter_workspace != null:
		_parameter_workspace.randomize_seed()


func _on_random_name_pressed() -> void:
	if _parameter_workspace != null:
		_parameter_workspace.randomize_name()


func _on_btn_randomise_pressed() -> void:
	if _parameter_workspace != null:
		_parameter_workspace.randomize_parameters()


# ============================================================================
# PRESET SAVE / LOAD SYSTEM
# ============================================================================

## Collecte les paramètres dynamiques dans un dictionnaire sérialisable.
func _collect_preset_data() -> Dictionary:
	var data = _parameter_workspace.get_values() if _parameter_workspace != null else {}
	data["_meta"] = {
		"version": 2,
		"date": Time.get_datetime_string_from_system(),
	}
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
	if not (data is Dictionary):
		push_error("[Preset] Format invalide")
		return false

	if _parameter_workspace != null:
		_parameter_workspace.apply_values(data)
	maj_labels()
	print("[Preset] ✅ Chargé: ", file_path.get_file())
	return true
