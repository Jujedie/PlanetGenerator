class_name ReleaseCandidateRunner
extends Node

## Milestone 8 — hardware/runtime release-candidate acceptance runner.
##
## The normal application path is reused for every generated planet. This runner
## only schedules generations, exports, cleanup and measurements; it does not
## contain a second procedural generation implementation.

signal validation_progress(completed: int, total: int, stage: String, detail: String)
signal validation_completed(report: Dictionary)

const REPORT_VERSION := 1

var running := false
var _base_params: Dictionary = {}
var _options: Dictionary = {}
var _output_root := ""
var _jobs: Array[Dictionary] = []
var _job_index := 0
var _current: PlanetGenerator = null
var _current_job: Dictionary = {}
var _current_started_usec := 0
var _cancel_requested := false
var _results: Array[Dictionary] = []
var _memory_after_cleanup: Array[int] = []
var _determinism_hashes: Dictionary = {}


static func default_options() -> Dictionary:
	return {
		"stability_runs": ReleaseStabilityValidator.REQUIRED_STABILITY_RUNS,
		"seed_start": 810000,
		"validation_resolution": Vector2i(512, 256),
		"planet_types": ReleaseStabilityValidator.SUPPORTED_PLANET_TYPES.duplicate(),
		"cancellation_phases": ReleaseStabilityValidator.CANCELLATION_PHASES.duplicate(),
		"determinism_seed": 818181,
		"run_cancellation_recovery": true,
		# The maximum Venus-like tiled test is deliberately opt-in because it can
		# consume a very large amount of disk and wall-clock time. A 1.0 release
		# report is not complete until this gate is run on target hardware.
		"include_large_tiled_test": false,
		"large_planet_radius_km": PlanetGridContract.MAX_REFERENCE_RADIUS_KM,
		"large_dimensions": PlanetGridContract.MAX_LOGICAL_DIMENSIONS,
		"large_vram_limit_bytes": 5 * 1024 * 1024 * 1024,
		# Produced by tools/run_m8_regression_suite.py. Keeping this external
		# prevents tests that call get_tree().quit() from interfering with the
		# long-running 50-generation process.
		"regression_report_path": "",
	}


static func build_plan(options: Dictionary = {}) -> Array[Dictionary]:
	var merged := default_options()
	for key in options:
		merged[key] = options[key]
	var jobs: Array[Dictionary] = []
	var types: Array = merged.get("planet_types", ReleaseStabilityValidator.SUPPORTED_PLANET_TYPES)
	if types.is_empty():
		types = ReleaseStabilityValidator.SUPPORTED_PLANET_TYPES.duplicate()
	var stability_runs := maxi(int(merged.get("stability_runs", 50)), 0)
	var seed_start := int(merged.get("seed_start", 810000))
	for index in range(stability_runs):
		jobs.append({
			"kind": "stability",
			"seed": seed_start + index,
			"planet_type": int(types[index % types.size()]),
		})
	var deterministic_seed := int(merged.get("determinism_seed", 818181))
	jobs.append({"kind": "determinism_a", "seed": deterministic_seed, "planet_type": 0})
	jobs.append({"kind": "determinism_b", "seed": deterministic_seed, "planet_type": 0})
	for phase in merged.get("cancellation_phases", ReleaseStabilityValidator.CANCELLATION_PHASES):
		jobs.append({
			"kind": "cancel",
			"seed": deterministic_seed + 1000 + jobs.size(),
			"planet_type": 0,
			"cancel_after_phase": str(phase),
		})
		if bool(merged.get("run_cancellation_recovery", true)):
			jobs.append({
				"kind": "cancel_recovery",
				"seed": deterministic_seed + 2000 + jobs.size(),
				"planet_type": 0,
				"recovery_for": str(phase),
			})
	if bool(merged.get("include_large_tiled_test", false)):
		jobs.append({
			"kind": "large_tiled",
			"seed": deterministic_seed + 9000,
			"planet_type": 0,
		})
	return jobs


func start(base_params: Dictionary, output_root: String, options: Dictionary = {}) -> bool:
	if running:
		return false
	_base_params = base_params.duplicate(true)
	_options = default_options()
	for key in options:
		_options[key] = options[key]
	_output_root = output_root
	DirAccess.make_dir_recursive_absolute(_output_root)
	_jobs = build_plan(_options)
	_job_index = 0
	_results.clear()
	_memory_after_cleanup.clear()
	_determinism_hashes.clear()
	_cancel_requested = false
	running = true
	call_deferred("_launch_next")
	return true


func cancel() -> void:
	if not running:
		return
	_cancel_requested = true
	if _current != null:
		_current.cancel_generation("release_runner_cancel")


func _launch_next() -> void:
	if not running:
		return
	if _cancel_requested:
		_finish(true)
		return
	if _job_index >= _jobs.size():
		_finish(false)
		return
	_current_job = _jobs[_job_index]
	var params := _params_for_job(_current_job)
	var name := "RC_%03d_%s" % [_job_index, str(_current_job.get("kind", "run"))]
	var run_dir := _output_root.path_join("%03d_%s" % [_job_index, str(_current_job.get("kind", "run"))])
	_current = PlanetGenerator.new(name, params, run_dir)
	_current.finished.connect(_on_generation_finished.bind(run_dir), CONNECT_ONE_SHOT)
	_current.generation_cancelled.connect(_on_generation_cancelled.bind(run_dir), CONNECT_ONE_SHOT)
	_current_started_usec = Time.get_ticks_usec()
	emit_signal("validation_progress", _job_index, _jobs.size(), str(_current_job.get("kind", "run")), str(_current_job))
	if not _current.generate_planet():
		_record_current_failure("generation did not start")


func _params_for_job(job: Dictionary) -> Dictionary:
	var params := _base_params.duplicate(true)
	var resolution: Vector2i = _options.get("validation_resolution", Vector2i(512, 256))
	params["seed"] = int(job.get("seed", 0))
	params["planet_type"] = int(job.get("planet_type", 0))
	params["resolution"] = resolution
	params["global_dimensions"] = resolution
	params["run_integrity_checks"] = true
	params["export_preset"] = ExportCatalog.PRESET_DEVELOPMENT
	params["release_test_cancel_after_phase"] = ""
	params["tiled_global_generation"] = false
	if str(job.get("kind", "")) == "cancel":
		params["release_test_cancel_after_phase"] = str(job.get("cancel_after_phase", ""))
	if str(job.get("kind", "")) == "large_tiled":
		var radius := float(_options.get("large_planet_radius_km", PlanetGridContract.MAX_REFERENCE_RADIUS_KM))
		var dimensions: Vector2i = _options.get("large_dimensions", PlanetGridContract.MAX_LOGICAL_DIMENSIONS)
		params["planet_radius"] = radius
		params["global_dimensions"] = dimensions
		params["resolution"] = dimensions
		params["tiled_global_generation"] = true
		params["vram_budget_bytes"] = int(_options.get("large_vram_limit_bytes", 5 * 1024 * 1024 * 1024))
	return params


func _on_generation_finished(run_dir: String) -> void:
	if _current == null:
		return
	var kind := str(_current_job.get("kind", ""))
	if kind == "cancel":
		_record_current_failure("cancellation checkpoint finished instead of cancelling")
		return
	var exported: Dictionary = {}
	var export_validation: Dictionary = {}
	if kind == "large_tiled":
		# The tiled generator already wrote its authoritative dataset under the
		# run directory. Do not duplicate hundreds of gigabytes merely to validate it.
		exported["tiled_dataset"] = run_dir.path_join("tiled_dataset")
		export_validation = _validate_tiled_run(run_dir)
	else:
		exported = _current.export_to_directory(run_dir)
		export_validation = ReleaseStabilityValidator.validate_export_tree(run_dir)
	var elapsed_ms := float(Time.get_ticks_usec() - _current_started_usec) / 1000.0
	var result := _base_result(elapsed_ms)
	result["export_validation"] = export_validation
	result["ok"] = str(export_validation.get("result", "FAIL")) == "PASS"
	if kind in ["determinism_a", "determinism_b"]:
		_determinism_hashes[kind] = ReleaseStabilityValidator.deterministic_layer_hashes(run_dir)
	result["exported_files"] = exported.size()
	_cleanup_and_continue(result)


func _on_generation_cancelled(reason: String, _run_dir: String) -> void:
	if _current == null:
		return
	var elapsed_ms := float(Time.get_ticks_usec() - _current_started_usec) / 1000.0
	var expected := str(_current_job.get("kind", "")) == "cancel"
	var result := _base_result(elapsed_ms)
	result["ok"] = expected
	result["expected_cancel"] = expected
	result["cancel_after_phase"] = str(_current_job.get("cancel_after_phase", ""))
	result["cancel_reason"] = reason if not reason.is_empty() else _current.last_cancel_reason
	_cleanup_and_continue(result)


func _base_result(elapsed_ms: float) -> Dictionary:
	var performance: Dictionary = {}
	var export_metrics: Dictionary = {}
	if _current != null:
		# PlanetGenerator releases its live orchestrator before emitting finished.
		# M8 therefore consumes the cached lifecycle snapshot, not live GPU objects.
		performance = _current.last_performance_report.duplicate(true)
		if performance.is_empty() and _current.tiled_pipeline != null:
			performance = _current.tiled_pipeline.last_report.duplicate(true)
		export_metrics = _current.last_export_metrics.duplicate(true)
	return {
		"index": _job_index,
		"kind": str(_current_job.get("kind", "")),
		"seed": int(_current_job.get("seed", 0)),
		"planet_type": int(_current_job.get("planet_type", 0)),
		"elapsed_ms": elapsed_ms,
		"performance": performance,
		"export_metrics": export_metrics,
	}


func _record_current_failure(reason: String) -> void:
	var elapsed_ms := float(Time.get_ticks_usec() - _current_started_usec) / 1000.0
	var result := _base_result(elapsed_ms)
	result["ok"] = false
	result["reason"] = reason
	_cleanup_and_continue(result)


func _cleanup_and_continue(result: Dictionary) -> void:
	if _current != null:
		_current.cleanup()
		_current = null
	_results.append(result)
	# Sampling after cleanup is what catches retained generation-owned memory.
	_memory_after_cleanup.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	_job_index += 1
	call_deferred("_launch_next")


func _validate_tiled_run(run_dir: String) -> Dictionary:
	var manifest_path := run_dir.path_join("tiled_dataset").path_join("tiled_planet_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		# Keep compatibility with a caller that points directly at the dataset root.
		manifest_path = run_dir.path_join("tiled_planet_manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return {
			"result": "FAIL",
			"checks": [{
				"id": "large_tiled.manifest",
				"status": "FAIL",
				"message": "tiled_planet_manifest.json is missing.",
			}],
		}

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary:
		return {
			"result": "FAIL",
			"checks": [{
				"id": "large_tiled.manifest",
				"status": "FAIL",
				"message": "Tiled dataset manifest cannot be parsed.",
			}],
		}
	var manifest: Dictionary = parsed
	var checks: Array[Dictionary] = []
	checks.append({
		"id": "large_tiled.manifest",
		"status": "PASS",
		"message": "Completed tiled dataset manifest is readable.",
	})

	var expected_dimensions: Vector2i = _options.get("large_dimensions", PlanetGridContract.MAX_LOGICAL_DIMENSIONS)
	var grid: Dictionary = manifest.get("grid", {})
	var dimensions_value = grid.get("dimensions", [])
	var dimensions_ok = dimensions_value is Array and dimensions_value.size() >= 2
	if dimensions_ok:
		dimensions_ok = int(dimensions_value[0]) == expected_dimensions.x and int(dimensions_value[1]) == expected_dimensions.y
	checks.append({
		"id": "large_tiled.dimensions",
		"status": "PASS" if dimensions_ok else "FAIL",
		"expected": [expected_dimensions.x, expected_dimensions.y],
		"observed": dimensions_value,
	})

	var runtime: Dictionary = manifest.get("runtime", {})
	var budget_limit := int(_options.get("large_vram_limit_bytes", 5 * 1024 * 1024 * 1024))
	var estimated_peak := int(runtime.get("estimated_peak_active_vram_bytes", -1))
	var budget_ok := bool(runtime.get("within_hard_budget", false)) and estimated_peak >= 0 and estimated_peak <= budget_limit
	checks.append({
		"id": "large_tiled.vram_budget",
		"status": "PASS" if budget_ok else "FAIL",
		"estimated_peak_active_vram_bytes": estimated_peak,
		"limit_bytes": budget_limit,
	})

	var no_monolithic_texture := not bool(runtime.get("full_resolution_texture_allocated", true))
	checks.append({
		"id": "large_tiled.no_full_resolution_texture",
		"status": "PASS" if no_monolithic_texture else "FAIL",
	})

	var tile_checksums: Dictionary = manifest.get("tile_checksums", {})
	var checksum_ok := not tile_checksums.is_empty()
	checks.append({
		"id": "large_tiled.tile_checksums",
		"status": "PASS" if checksum_ok else "FAIL",
		"count": tile_checksums.size(),
	})

	var hydrology: Dictionary = manifest.get("global_hydrology", {})
	var hydrology_ok := not hydrology.is_empty()
	checks.append({
		"id": "large_tiled.global_hydrology",
		"status": "PASS" if hydrology_ok else "FAIL",
		"report": hydrology,
	})

	var ok := true
	for check in checks:
		if str(check.get("status", "FAIL")) != "PASS":
			ok = false
	return {
		"result": "PASS" if ok else "FAIL",
		"manifest": manifest_path,
		"checks": checks,
	}


func _finish(cancelled: bool) -> void:
	if not running:
		return
	running = false
	var required_stability := int(_options.get("stability_runs", ReleaseStabilityValidator.REQUIRED_STABILITY_RUNS))
	var stability_runs := 0
	var stability_pass := 0
	var observed_types: Dictionary = {}
	var cancellation_expected := 0
	var cancellation_pass := 0
	var recovery_expected := 0
	var recovery_pass := 0
	var large_tiled: Dictionary = {"status": "SKIP", "reason": "not requested on this hardware run"}
	for run in _results:
		var kind := str(run.get("kind", ""))
		match kind:
			"stability":
				stability_runs += 1
				observed_types[int(run.get("planet_type", -1))] = true
				if bool(run.get("ok", false)): stability_pass += 1
			"cancel":
				cancellation_expected += 1
				if bool(run.get("ok", false)): cancellation_pass += 1
			"cancel_recovery":
				recovery_expected += 1
				if bool(run.get("ok", false)): recovery_pass += 1
			"large_tiled":
				large_tiled = {
					"status": "PASS" if bool(run.get("ok", false)) else "FAIL",
					"run": run,
				}
	var all_types := true
	for planet_type in _options.get("planet_types", ReleaseStabilityValidator.SUPPORTED_PLANET_TYPES):
		if not observed_types.has(int(planet_type)):
			all_types = false
	var determinism := ReleaseStabilityValidator.compare_hash_sets(
		_determinism_hashes.get("determinism_a", {}),
		_determinism_hashes.get("determinism_b", {})
	)
	var memory := ReleaseStabilityValidator.evaluate_memory_series(_memory_after_cleanup)
	var package := ReleaseStabilityValidator.validate_package_resources()
	var regression_assets := ReleaseStabilityValidator.required_regression_scenes_present()
	var regression_execution := ReleaseStabilityValidator.validate_regression_report(
		str(_options.get("regression_report_path", ""))
	)
	var stability_ok := stability_runs == required_stability and stability_pass == required_stability
	var cancellation_ok: bool = cancellation_expected == _options.get("cancellation_phases", []).size() and cancellation_pass == cancellation_expected
	var recovery_ok := not bool(_options.get("run_cancellation_recovery", true)) or (recovery_expected == cancellation_expected and recovery_pass == recovery_expected)
	var hardware_gate_required := not bool(_options.get("include_large_tiled_test", false))
	var regression_gate_required := str(regression_execution.get("status", "SKIP")) == "SKIP"
	var local_ok: bool = (
		stability_ok
		and all_types
		and bool(determinism.get("ok", false))
		and cancellation_ok
		and recovery_ok
		and bool(memory.get("ok", false))
		and bool(package.get("ok", false))
		and bool(regression_assets.get("ok", false))
		and (regression_gate_required or bool(regression_execution.get("ok", false)))
	)
	if bool(_options.get("include_large_tiled_test", false)):
		local_ok = local_ok and str(large_tiled.get("status", "FAIL")) == "PASS"
	var external_gate_pending := hardware_gate_required or regression_gate_required
	var report := {
		"release_report_version": REPORT_VERSION,
		"cancelled": cancelled,
		"result": "FAIL" if cancelled or not local_ok else ("PASS_WITH_EXTERNAL_GATES" if external_gate_pending else "PASS"),
		"stability": {
			"required": required_stability,
			"completed": stability_runs,
			"passed": stability_pass,
			"all_planet_types_covered": all_types,
			"observed_planet_types": observed_types.keys(),
		},
		"determinism": determinism,
		"determinism_hashes": _determinism_hashes.duplicate(true),
		"cancellation": {
			"required": cancellation_expected,
			"passed": cancellation_pass,
			"recovery_required": recovery_expected,
			"recovery_passed": recovery_pass,
		},
		"memory_after_cleanup": memory,
		"package": package,
		"regression_assets": regression_assets,
		"regression_execution": regression_execution,
		"large_tiled": large_tiled,
		"hardware_gate_pending": hardware_gate_required,
		"regression_gate_pending": regression_gate_required,
		"runs": _results,
		"environment": {
			"godot_version": Engine.get_version_info(),
			"os": OS.get_name(),
			"processor_count": OS.get_processor_count(),
			"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		},
	}
	var path := _output_root.path_join("release_candidate_report.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  ", true))
		file.close()
	report["report_path"] = path
	emit_signal("validation_completed", report)
