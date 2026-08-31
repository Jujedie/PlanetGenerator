extends Node

## Internal stateful runtime registered as an autoload by plugin.gd.
## Public game code should use the class_name PlanetGeneratorService facade.
## This node owns no UI and never exposes RenderingDevice RIDs.

signal job_started(job: PlanetGenerationJob)
signal job_completed(job: PlanetGenerationJob, result: PlanetGenerationResult)
signal job_failed(job: PlanetGenerationJob, error: Dictionary)
signal job_cancelled(job: PlanetGenerationJob, reason: String)

var _jobs: Dictionary = {}
var _backends: Dictionary = {}
var _job_counter: int = 0
var _shutting_down: bool = false


func get_api_version() -> int:
	return PGAddonInfo.API_VERSION


func get_version() -> String:
	return PGAddonInfo.VERSION


func get_capabilities() -> Dictionary:
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
		"runtime_query_fields": [
			"height_m",
			"surface_elevation_m",
			"temperature_c",
			"precipitation",
			"biome",
			"biome_id",
			"biome_name",
			"river_biome",
			"water_type",
			"region_id",
			"ocean_region_id",
		],
		"global_tile_access": true,
		"tiled_dataset_access": true,
		"runtime_profiles": [
			PlanetGenerationSpec.PROFILE_FULL,
			PlanetGenerationSpec.PROFILE_RUNTIME,
			PlanetGenerationSpec.PROFILE_SERVER,
			PlanetGenerationSpec.PROFILE_EDITOR,
		],
		# The current synchronized 3.1.0 core has no detailed 1 km² local-zone
		# generator. Do not advertise or emulate a different algorithm here.
		"detailed_local_zones": false,
		"network_service": false,
	}


func supports_detailed_local_zones() -> bool:
	return false


func get_template_names() -> Array[String]:
	var names: Array[String] = []
	for name_value in PGPlanetTemplates.ORDER:
		names.append(str(name_value))
	return names


func create_template(preset_name: String = "Earth-like") -> PlanetGenerationTemplate:
	return PlanetGenerationTemplate.from_preset(preset_name)


func create_spec(preset_name: String = "Earth-like") -> PlanetGenerationSpec:
	return PlanetGenerationSpec.from_template(create_template(preset_name))


## Starts an asynchronous generation and returns immediately with a job handle.
## Accepted request values: PlanetGenerationSpec, PlanetGenerationTemplate,
## Dictionary containing template parameter keys, or a preset/template file path.
## If exact_output is true, output_root is used as the final directory instead
## of receiving an automatically generated per-job child directory.
func generate_planet(request: Variant, output_root: String = "", exact_output: bool = false) -> PlanetGenerationJob:
	var job := PlanetGenerationJob.new()
	_job_counter += 1
	job.id = _make_job_id(_job_counter)
	_jobs[job.id] = job

	if _shutting_down:
		call_deferred("_deferred_fail_job", job.id, {
			"code": "service_shutting_down",
			"message": "PlanetGeneratorServiceRuntime is shutting down.",
		})
		return job

	var spec := _coerce_spec(request)
	if spec == null:
		call_deferred("_deferred_fail_job", job.id, {
			"code": "invalid_request",
			"message": "Expected PlanetGenerationSpec, PlanetGenerationTemplate, Dictionary, or preset/template file path String.",
		})
		return job
	if not output_root.is_empty():
		spec.output_root = output_root
	if exact_output:
		spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

	var compiled := spec.compile()
	if not bool(compiled.get("ok", false)):
		call_deferred("_deferred_fail_job", job.id, {
			"code": "invalid_spec",
			"message": "Generation specification validation failed.",
			"errors": compiled.get("errors", []),
			"warnings": compiled.get("warnings", []),
		})
		return job

	for warning_value in compiled.get("warnings", []):
		job.warnings.append(str(warning_value))
	var params: Dictionary = (compiled["params"] as Dictionary).duplicate(true)
	var root_resolution := _resolve_job_output_root(
		spec,
		str(params.get("planet_name", "planet")),
		int(params["seed"]),
		job.id
	)
	if not bool(root_resolution.get("ok", false)):
		call_deferred("_deferred_fail_job", job.id, {
			"code": str(root_resolution.get("code", "invalid_output_directory")),
			"message": str(root_resolution.get("message", "Invalid output directory.")),
			"path": str(root_resolution.get("path", spec.output_root)),
		})
		return job
	var root := str(root_resolution["path"])
	var mkdir_error := DirAccess.make_dir_recursive_absolute(root)
	if mkdir_error != OK:
		call_deferred("_deferred_fail_job", job.id, {
			"code": "output_directory_creation_failed",
			"message": "Could not create Planet Generator output directory.",
			"path": root,
			"error": mkdir_error,
		})
		return job
	params["addon_output_root"] = root
	params["addon_job_id"] = job.id

	var backend := PGPlanetGeneratorBackend.new(str(params["planet_name"]), params, root)
	_backends[job.id] = backend
	job._attach_backend(backend)
	backend.generation_progress.connect(_on_backend_progress.bind(job.id))
	backend.finished.connect(_on_backend_finished.bind(job.id, params, root))
	backend.generation_cancelled.connect(_on_backend_cancelled.bind(job.id))

	if not backend.generate_planet():
		_backends.erase(job.id)
		job._attach_backend(null)
		backend.cleanup()
		call_deferred("_deferred_fail_job", job.id, {
			"code": "generation_not_started",
			"message": "The backend rejected the generation request. Check RenderingDevice availability and resolution constraints.",
		})
		return job

	job._mark_running()
	emit_signal("job_started", job)
	return job


func get_job(job_id: String) -> PlanetGenerationJob:
	return _jobs.get(job_id) as PlanetGenerationJob


func cancel_job(job_id: String, reason: String = "user") -> bool:
	var job := get_job(job_id)
	if job == null or job.is_done():
		return false
	job.cancel(reason)
	return true


func cancel_all(reason: String = "service_shutdown") -> void:
	for job_value in _jobs.values():
		var job := job_value as PlanetGenerationJob
		if job != null and not job.is_done():
			job.cancel(reason)


## Loads either an addon template (.json/.tres/.res) or a standalone
## .planetGeneratorParam preset into a generation specification.
func load_preset(path: String) -> PlanetGenerationSpec:
	return PlanetGenerationSpec.from_preset_file(path)


func load_planet(path_or_directory: String) -> PlanetGenerationResult:
	return PlanetGenerationResult.load_existing(path_or_directory)


## Convenience helper for one-off queries by generated-planet path. For many
## queries, call load_planet() once and reuse the returned PlanetGenerationResult
## so its runtime-data file handles remain cached.
func query_planet_cell(path_or_directory: String, global_cell: Vector2i,
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


func shutdown() -> void:
	if _shutting_down:
		return
	_shutting_down = true
	cancel_all("service_shutdown")
	PGGPUGenerationWorker.shutdown()
	for backend_value in _backends.values():
		var backend := backend_value as PGPlanetGeneratorBackend
		if backend != null:
			backend.cleanup()
	_backends.clear()
	_shutting_down = false


func _exit_tree() -> void:
	shutdown()


func _coerce_spec(request: Variant) -> PlanetGenerationSpec:
	if request is PlanetGenerationSpec:
		return (request as PlanetGenerationSpec).duplicate_spec()
	if request is PlanetGenerationTemplate:
		return PlanetGenerationSpec.from_template((request as PlanetGenerationTemplate).duplicate_template())
	if request is Dictionary:
		var template := PlanetGenerationTemplate.defaults()
		template.apply_dictionary(request as Dictionary, false)
		return PlanetGenerationSpec.from_template(template)
	if request is String:
		return load_preset(str(request))
	return null


func _on_backend_progress(phase: String, completed_count: int, total_count: int, job_id: String) -> void:
	var job := get_job(job_id)
	if job != null:
		job._update_progress(phase, completed_count, total_count)


func _on_backend_finished(job_id: String, params: Dictionary, root: String) -> void:
	var job := get_job(job_id)
	var backend := _backends.get(job_id) as PGPlanetGeneratorBackend
	if job == null or backend == null:
		return
	var result := PlanetGenerationResult.from_generation(
		job_id,
		root,
		params,
		backend.last_exported_files,
		backend.last_performance_report,
		backend.last_export_metrics,
		job.warnings
	)
	_backends.erase(job_id)
	backend.cleanup()
	job._complete(result)
	emit_signal("job_completed", job, result)


func _on_backend_cancelled(reason: String, job_id: String) -> void:
	var job := get_job(job_id)
	var backend := _backends.get(job_id) as PGPlanetGeneratorBackend
	_backends.erase(job_id)
	if backend != null:
		backend.cleanup()
	if job == null:
		return
	if reason in ["user", "cleanup", "service_shutdown"] or job.state == PlanetGenerationJob.State.CANCELLING:
		job._cancelled(reason)
		emit_signal("job_cancelled", job, reason)
	else:
		var failure := {
			"code": reason,
			"message": "Planet generation failed: %s" % reason,
		}
		job._fail(failure)
		emit_signal("job_failed", job, failure)


func _deferred_fail_job(job_id: String, failure: Dictionary) -> void:
	var job := get_job(job_id)
	if job == null or job.is_done():
		return
	job._fail(failure)
	emit_signal("job_failed", job, failure)


func _resolve_job_output_root(spec: PlanetGenerationSpec, planet_name: String, seed: int, job_id: String) -> Dictionary:
	var base := spec.output_root.strip_edges()
	if base.is_empty():
		base = PGAddonInfo.DEFAULT_OUTPUT_ROOT

	if spec.output_mode == PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY:
		var exact := base.simplify_path()
		if _is_dangerous_exact_output(exact):
			return {
				"ok": false,
				"code": "unsafe_exact_output_directory",
				"message": "Refusing to use a project/user/filesystem root as an exact output directory.",
				"path": exact,
			}
		if DirAccess.dir_exists_absolute(exact) and not _directory_is_empty(exact) and not _is_known_planet_generator_output(exact):
			return {
				"ok": false,
				"code": "exact_output_directory_not_owned",
				"message": "Exact output directory is not empty and is not an existing Planet Generator output. Choose an empty directory or a previous Planet Generator output directory.",
				"path": exact,
			}
		return {"ok": true, "path": exact}

	var folder := "%s_%d_%s" % [_slug(planet_name), seed, job_id]
	return {"ok": true, "path": base.path_join(folder)}


func _is_dangerous_exact_output(path: String) -> bool:
	var normalized := path.strip_edges().replace("\\", "/").simplify_path()
	if normalized.is_empty() or normalized in [".", "/", "res://", "user://"]:
		return true
	if normalized.length() == 3 and normalized.substr(1, 2) == ":/":
		return true
	var globalized := ProjectSettings.globalize_path(normalized).replace("\\", "/").simplify_path()
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/").simplify_path()
	var user_root := ProjectSettings.globalize_path("user://").replace("\\", "/").simplify_path()
	return globalized == project_root or globalized == user_root


func _directory_is_empty(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return true
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry not in [".", ".."]:
			directory.list_dir_end()
			return false
		entry = directory.get_next()
	directory.list_dir_end()
	return true


func _is_known_planet_generator_output(path: String) -> bool:
	for marker in ["planet_project.json", "planet_manifest.json", "export_catalog.json", "tiled_planet_manifest.json"]:
		if FileAccess.file_exists(path.path_join(marker)):
			return true
	return false


func _make_job_id(counter: int) -> String:
	return "%x_%04d" % [Time.get_ticks_usec(), counter]


static func _slug(value: String) -> String:
	var result := value.strip_edges().to_lower()
	var allowed := "abcdefghijklmnopqrstuvwxyz0123456789-_"
	var cleaned := ""
	for index in range(result.length()):
		var character := result.substr(index, 1)
		cleaned += character if allowed.contains(character) else "_"
	while cleaned.contains("__"):
		cleaned = cleaned.replace("__", "_")
	cleaned = cleaned.trim_prefix("_").trim_suffix("_")
	return cleaned if not cleaned.is_empty() else "planet"
