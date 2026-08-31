class_name PlanetGenerationSpec
extends Resource

## Runtime generation request. The template contains world parameters; this
## resource contains execution/output policy for the consuming game.

const PROFILE_FULL := "FULL"
const PROFILE_RUNTIME := "RUNTIME"
const PROFILE_SERVER := "SERVER"
const PROFILE_EDITOR := "EDITOR"

const OUTPUT_UNIQUE_SUBDIRECTORY := "unique_subdirectory"
const OUTPUT_EXACT_DIRECTORY := "exact_directory"

@export var template: PlanetGenerationTemplate
@export_enum("FULL", "RUNTIME", "SERVER", "EDITOR") var runtime_profile: String = PROFILE_RUNTIME
@export var output_root: String = PGAddonInfo.DEFAULT_OUTPUT_ROOT
@export_enum("unique_subdirectory", "exact_directory") var output_mode: String = OUTPUT_UNIQUE_SUBDIRECTORY
@export_enum("auto", "minimal", "standard", "complete", "development", "custom") var export_preset: String = "auto"
@export var export_enabled_keys: Array[String] = []
@export var run_integrity_checks: bool = true
@export var export_cartographic_map: bool = true
@export var export_grid_overlay: bool = true
@export var export_runtime_query_data: bool = true
@export var cartography_grid_alpha: int = 166
@export var experimental_tiled_generation: bool = false


static func from_template(value: PlanetGenerationTemplate) -> PlanetGenerationSpec:
	var result := PlanetGenerationSpec.new()
	result.template = value
	return result


## Loads either an addon JSON template or a standalone .planetGeneratorParam
## preset. Standalone UI export policy is preserved when present.
static func from_preset_file(path: String) -> PlanetGenerationSpec:
	var template_value: PlanetGenerationTemplate = null
	var extension := path.get_extension().to_lower()
	if extension in ["tres", "res"]:
		template_value = PlanetGenerationTemplate.load_resource(path)
	else:
		template_value = PlanetGenerationTemplate.load_json(path)
	if template_value == null:
		return null

	var result := from_template(template_value)
	if extension not in ["tres", "res"]:
		var payload := _read_json_dictionary(path)
		var raw_ui: Variant = payload.get("_ui", {})
		if raw_ui is Dictionary:
			var ui := raw_ui as Dictionary
			if ui.has("export_preset"):
				result.export_preset = str(ui["export_preset"])
	return result


func compile() -> Dictionary:
	if template == null:
		return {"ok": false, "errors": ["No PlanetGenerationTemplate is assigned."], "warnings": []}
	var validation := template.validation_report()
	if not bool(validation.get("ok", false)):
		return validation

	var ui := template.validated_values()
	var generation_seed := int(ui.get("seed", 0))
	if generation_seed == 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		generation_seed = rng.randi()

	var planet_radius_km := float(ui["planet_radius"])
	var canonical_resolution := PGPlanetGridContract.logical_dimensions(planet_radius_km)
	var planet_type := clampi(int(ui.get("planet_type", 0)), 0, 6)
	var selected_export_preset := _resolved_export_preset()
	var params := ui.duplicate(true)

	params["seed"] = generation_seed
	params["planet_name"] = str(ui.get("planet_name", "Generated Planet")).strip_edges()
	if str(params["planet_name"]).is_empty():
		params["planet_name"] = "Generated Planet"
	params["planet_radius"] = planet_radius_km
	params["planet_type"] = planet_type
	params["resolution"] = canonical_resolution
	params["global_dimensions"] = canonical_resolution
	params["global_cell_area_km2"] = PGPlanetGridContract.effective_cell_area_km2(
		planet_radius_km, canonical_resolution
	)
	params["tile_size"] = PGPlanetGridContract.DEFAULT_TILE_SIZE
	params["projection"] = PGPlanetGridContract.PROJECTION_ID
	params["tiled_global_generation"] = false
	params["experimental_tiled_generation"] = experimental_tiled_generation
	params["vram_budget_bytes"] = PGTiledGlobalGenerator.HARD_VRAM_BUDGET_BYTES
	params["export_cartographic_map"] = export_cartographic_map and runtime_profile != PROFILE_SERVER
	params["export_grid_overlay"] = export_grid_overlay and runtime_profile != PROFILE_SERVER
	params["export_runtime_query_data"] = export_runtime_query_data
	params["cartography_palette_path"] = PGCartographicPalette.DEFAULT_PATH
	params["cartography_view"] = PGCartographicRenderer.VIEW_PLANET
	params["cartography_grid_alpha"] = clampi(cartography_grid_alpha, 0, 255)
	params["run_integrity_checks"] = run_integrity_checks
	params["export_preset"] = selected_export_preset
	if selected_export_preset == PGExportCatalog.PRESET_CUSTOM:
		params["export_enabled_keys"] = export_enabled_keys.duplicate()

	params["saltwater_min_size"] = float(ui["freshwater_max_size"]) + 1.0
	params["region_iterations"] = maxi(canonical_resolution.x, canonical_resolution.y) * 2
	params["admin_country_enclave_cleanup"] = true
	params["admin_country_enclave_max_fraction"] = 0.30
	params["admin_country_enclave_dominance"] = 0.60
	params["admin_country_enclave_proximity_factor"] = 0.35
	params["ocean_iterations"] = maxi(canonical_resolution.x, canonical_resolution.y) * 2
	params["addon_api_version"] = PGAddonInfo.API_VERSION
	params["addon_version"] = PGAddonInfo.VERSION
	params["runtime_profile"] = runtime_profile

	var warnings: Array[String] = []
	for warning_value in validation.get("warnings", []):
		warnings.append(str(warning_value))
	if runtime_profile == PROFILE_SERVER and DisplayServer.get_name() == "headless":
		warnings.append("Headless generation still requires a platform/driver that can create a local RenderingDevice.")
	return {"ok": true, "params": params, "errors": [], "warnings": warnings}


func duplicate_spec() -> PlanetGenerationSpec:
	var result := PlanetGenerationSpec.new()
	result.template = template.duplicate_template() if template != null else null
	result.runtime_profile = runtime_profile
	result.output_root = output_root
	result.output_mode = output_mode
	result.export_preset = export_preset
	result.export_enabled_keys = export_enabled_keys.duplicate()
	result.run_integrity_checks = run_integrity_checks
	result.export_cartographic_map = export_cartographic_map
	result.export_grid_overlay = export_grid_overlay
	result.export_runtime_query_data = export_runtime_query_data
	result.cartography_grid_alpha = cartography_grid_alpha
	result.experimental_tiled_generation = experimental_tiled_generation
	return result


func _resolved_export_preset() -> String:
	if export_preset != "auto":
		return PGExportCatalog.normalize_preset(export_preset)
	match runtime_profile:
		PROFILE_FULL:
			return PGExportCatalog.PRESET_COMPLETE
		PROFILE_EDITOR:
			return PGExportCatalog.PRESET_DEVELOPMENT
		PROFILE_SERVER, PROFILE_RUNTIME:
			return PGExportCatalog.PRESET_MINIMAL
		_:
			return PGExportCatalog.PRESET_STANDARD


static func _read_json_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}
