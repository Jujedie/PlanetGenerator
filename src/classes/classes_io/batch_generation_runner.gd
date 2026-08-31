class_name BatchGenerationRunner
extends Node

## Milestone 7.6 — sequential batch generation / benchmark harness.
## Reuses the normal PlanetGenerator path so benchmark runs exercise the same
## backend and export/integrity code as an interactive generation.

signal batch_progress(completed: int, total: int, seed: int, status: String)
signal batch_completed(report: Dictionary)

var running: bool = false
var _base_params: Dictionary = {}
var _count: int = 0
var _seed_start: int = 0
var _completed: int = 0
var _output_root: String = ""
var _prefix: String = "Planet"
var _current: PlanetGenerator = null
var _current_started_usec: int = 0
var _cancel_requested: bool = false
var _runs: Array[Dictionary] = []


func start(
	base_params: Dictionary,
	count: int,
	seed_start: int,
	output_root: String,
	prefix: String = "Planet"
) -> bool:
	if running or count <= 0:
		return false

	running = true
	_cancel_requested = false
	_base_params = base_params.duplicate(true)
	_count = clampi(count, 1, 500)
	_seed_start = maxi(seed_start, 0)
	_completed = 0
	_output_root = output_root
	_prefix = prefix.strip_edges()
	if _prefix.is_empty():
		_prefix = "Planet"
	_runs.clear()
	DirAccess.make_dir_recursive_absolute(_output_root)
	call_deferred("_launch_next")
	return true


func cancel() -> void:
	if not running:
		return
	_cancel_requested = true
	if _current != null:
		_current.cancel_generation("batch_cancel")


func shutdown() -> void:
	_cancel_requested = true
	running = false
	if _current != null:
		_current.cleanup()
		_current = null


func _launch_next() -> void:
	if not running:
		return
	if _cancel_requested or _completed >= _count:
		_finish_batch(_cancel_requested)
		return

	var seed: int = _seed_start + _completed
	var params: Dictionary = _base_params.duplicate(true)
	params["seed"] = seed
	params["run_integrity_checks"] = true
	params["export_preset"] = ExportCatalog.PRESET_DEVELOPMENT

	var safe_prefix: String = _prefix.validate_filename()
	if safe_prefix.is_empty():
		safe_prefix = "Planet"
	var planet_name: String = "%s_%d" % [safe_prefix, seed]
	var run_dir: String = _output_root.path_join("seed_%d" % seed)
	DirAccess.make_dir_recursive_absolute(run_dir)

	_current = PlanetGenerator.new(planet_name, params, run_dir)
	_current.finished.connect(_on_current_finished.bind(seed, run_dir), CONNECT_ONE_SHOT)
	_current.generation_cancelled.connect(_on_current_cancelled.bind(seed), CONNECT_ONE_SHOT)
	_current.generation_progress.connect(_on_current_generation_progress.bind(seed))
	_current_started_usec = Time.get_ticks_usec()
	emit_signal("batch_progress", _completed, _count, seed, "generating")

	if not _current.generate_planet():
		_record_failure(seed, "generation_did_not_start")


func _on_current_generation_progress(
	phase: String,
	_completed_phase: int,
	_total_phase: int,
	seed: int
) -> void:
	if not running:
		return
	var status: String = "exporting" if phase == "export" else "generating"
	emit_signal("batch_progress", _completed, _count, seed, status)


func _on_current_finished(seed: int, run_dir: String) -> void:
	if not running or _current == null:
		return

	var elapsed_ms: float = float(Time.get_ticks_usec() - _current_started_usec) / 1000.0
	var perf: Dictionary = _current.last_performance_report.duplicate(true)
	var integrity: Dictionary = _read_json(run_dir.path_join("integrity_report.json"))
	var integrity_result: String = str(integrity.get("result", "UNKNOWN"))
	var ok: bool = integrity_result == "PASS"

	_runs.append({
		"seed": seed,
		"ok": ok,
		"elapsed_ms": elapsed_ms,
		"integrity": integrity_result,
		"integrity_summary": integrity.get("summary", {}),
		"peak_vram_bytes": int(perf.get("peak_vram_bytes", 0)),
		"peak_system_ram_bytes": int(perf.get("peak_system_ram_bytes", 0)),
		"gpu_simulation_wall_ms": float(perf.get("gpu_simulation_wall_ms", 0.0)),
		"output": run_dir,
	})

	_current.cleanup()
	_current = null
	_completed += 1
	emit_signal(
		"batch_progress",
		_completed,
		_count,
		seed,
		"complete" if ok else "integrity_fail"
	)
	call_deferred("_launch_next")


func _on_current_cancelled(reason: String, seed: int) -> void:
	if _current != null:
		_current.cleanup()
		_current = null

	if _cancel_requested or reason in ["batch_cancel", "user", "cleanup"]:
		_runs.append({"seed": seed, "ok": false, "cancelled": true, "reason": reason})
		_finish_batch(true)
		return

	_runs.append({"seed": seed, "ok": false, "reason": reason})
	_completed += 1
	emit_signal("batch_progress", _completed, _count, seed, "failed")
	call_deferred("_launch_next")


func _record_failure(seed: int, reason: String) -> void:
	if _current != null:
		_current.cleanup()
		_current = null
	_runs.append({"seed": seed, "ok": false, "reason": reason})
	_completed += 1
	emit_signal("batch_progress", _completed, _count, seed, "failed")
	call_deferred("_launch_next")


func _finish_batch(cancelled: bool) -> void:
	if not running:
		return
	running = false

	var total_ms: float = 0.0
	var peak_vram: int = 0
	var peak_ram: int = 0
	var succeeded: int = 0
	var integrity_pass: int = 0
	for run in _runs:
		total_ms += float(run.get("elapsed_ms", 0.0))
		peak_vram = maxi(peak_vram, int(run.get("peak_vram_bytes", 0)))
		peak_ram = maxi(peak_ram, int(run.get("peak_system_ram_bytes", 0)))
		if bool(run.get("ok", false)):
			succeeded += 1
		if str(run.get("integrity", "")) == "PASS":
			integrity_pass += 1

	var measured: int = maxi(_runs.size(), 1)
	var report: Dictionary = {
		"batch_version": 2,
		"cancelled": cancelled,
		"requested": _count,
		"completed": _runs.size(),
		"successful": succeeded,
		"failed": _runs.size() - succeeded,
		"integrity_pass": integrity_pass,
		"average_elapsed_ms": total_ms / float(measured),
		"peak_vram_bytes": peak_vram,
		"peak_system_ram_bytes": peak_ram,
		"runs": _runs.duplicate(true),
	}
	var report_path: String = _output_root.path_join("batch_report.json")
	var file: FileAccess = FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  ", true))
		file.close()
	report["report_path"] = report_path
	emit_signal("batch_completed", report)


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}
