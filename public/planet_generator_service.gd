class_name PlanetGeneratorService
extends RefCounted

## Public static facade for Planet Generator.
##
## This is a real globally registered Godot class (`class_name`), so it is
## visible to the script editor, autocomplete and documentation just like the
## other public API types.
##
## Stateful generation is owned by the internal autoload
## `PlanetGeneratorServiceRuntime`, registered automatically by plugin.gd.
## Keeping the public class separate from the autoload avoids a global-name
## collision between `class_name PlanetGeneratorService` and an autoload with
## the same identifier.

const RUNTIME_AUTOLOAD_NAME := "PlanetGeneratorServiceRuntime"


## Returns true when the plugin runtime autoload is available in the current
## SceneTree. Generation/cancellation requires it; template and result helpers
## do not.
static func is_runtime_available() -> bool:
	return _runtime() != null


## Returns the internal runtime Node. This is mainly useful when a game wants
## to connect to the service-level signals:
##
##     var runtime := PlanetGeneratorService.get_runtime()
##     runtime.job_started.connect(_on_job_started)
##
## Prefer the static facade methods for normal API calls.
static func get_runtime() -> Node:
	return _runtime()


static func get_api_version() -> int:
	return PGAddonInfo.API_VERSION


static func get_version() -> String:
	return PGAddonInfo.VERSION


static func get_capabilities() -> Dictionary:
	var runtime := _runtime()
	if runtime != null:
		return runtime.get_capabilities()
	return {
		"planet_generation": true,
		"async_jobs": true,
		"progress_signals": true,
		"cancellation": true,
		"serializable_templates": true,
		"standalone_preset_import": true,
		"exact_output_directory": true,
		"runtime_layer_access": true,
		"typed_cell_queries": true,
		"runtime_query_data": true,
		"direct_path_cell_query": true,
		"global_tile_access": true,
		"tiled_dataset_access": true,
		"runtime_profiles": [
			PlanetGenerationSpec.PROFILE_FULL,
			PlanetGenerationSpec.PROFILE_RUNTIME,
			PlanetGenerationSpec.PROFILE_SERVER,
			PlanetGenerationSpec.PROFILE_EDITOR,
		],
		"detailed_local_zones": false,
		"network_service": false,
		"runtime_available": false,
	}


static func supports_detailed_local_zones() -> bool:
	return false


static func get_template_names() -> Array[String]:
	var names: Array[String] = []
	for name_value in PGPlanetTemplates.ORDER:
		names.append(str(name_value))
	return names


static func create_template(preset_name: String = "Earth-like") -> PlanetGenerationTemplate:
	return PlanetGenerationTemplate.from_preset(preset_name)


static func create_spec(preset_name: String = "Earth-like") -> PlanetGenerationSpec:
	return PlanetGenerationSpec.from_template(create_template(preset_name))


## Starts an asynchronous generation. The editor plugin must be enabled so the
## internal PlanetGeneratorServiceRuntime autoload exists.
##
## Accepted request values: PlanetGenerationSpec, PlanetGenerationTemplate,
## Dictionary containing template parameter keys, or a preset/template path.
static func generate_planet(request: Variant, output_root: String = "", exact_output: bool = false) -> PlanetGenerationJob:
	var runtime := _runtime()
	if runtime != null:
		return runtime.generate_planet(request, output_root, exact_output)
	return _runtime_missing_job()


static func get_job(job_id: String) -> PlanetGenerationJob:
	var runtime := _runtime()
	if runtime == null:
		return null
	return runtime.get_job(job_id)


static func cancel_job(job_id: String, reason: String = "user") -> bool:
	var runtime := _runtime()
	if runtime == null:
		return false
	return runtime.cancel_job(job_id, reason)


static func cancel_all(reason: String = "service_shutdown") -> void:
	var runtime := _runtime()
	if runtime != null:
		runtime.cancel_all(reason)


## Loads addon templates (.json/.tres/.res) and standalone
## `.planetGeneratorParam` files.
static func load_preset(path: String) -> PlanetGenerationSpec:
	return PlanetGenerationSpec.from_preset_file(path)


## Opens a generated Planet Generator project without regenerating it.
static func load_planet(path_or_directory: String) -> PlanetGenerationResult:
	return PlanetGenerationResult.load_existing(path_or_directory)


## Convenience one-off cell query by generated-planet path.
static func query_planet_cell(path_or_directory: String, global_cell: Vector2i,
		include_river_biome: bool = true) -> Dictionary:
	var planet := load_planet(path_or_directory)
	if planet == null:
		return {
			"available": false,
			"runtime_data_available": false,
			"cell": global_cell,
			"error": "planet_project_not_found_or_invalid",
		}
	var data := planet.get_cell_data(global_cell, include_river_biome)
	planet.clear_caches()
	return data


static func shutdown() -> void:
	var runtime := _runtime()
	if runtime != null:
		runtime.shutdown()


static func _runtime() -> Node:
	var main_loop := Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree := main_loop as SceneTree
	if tree.root == null:
		return null
	return tree.root.get_node_or_null(RUNTIME_AUTOLOAD_NAME)


static func _runtime_missing_job() -> PlanetGenerationJob:
	var job := PlanetGenerationJob.new()
	job.id = "runtime_missing"
	job._fail({
		"code": "planet_generator_runtime_missing",
		"message": "PlanetGeneratorServiceRuntime is not loaded. Enable the Planet Generator plugin in Project > Project Settings > Plugins.",
	})
	push_error("[Planet Generator] PlanetGeneratorServiceRuntime is not loaded. Enable the Planet Generator plugin.")
	return job
