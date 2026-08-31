class_name ReleaseStabilityValidator
extends RefCounted

## Milestone 8 — release acceptance helpers.
##
## The validator is intentionally pure/read-only. It consumes finished project
## folders and runtime samples produced by ReleaseCandidateRunner and turns them
## into explicit PASS/FAIL/SKIP gates. It never repairs a generation.

const VALIDATOR_VERSION := 1
const REQUIRED_STABILITY_RUNS := 50
const SUPPORTED_PLANET_TYPES := [0, 1, 2, 3, 4, 5, 6]
const CANCELLATION_PHASES := [
	"base_elevation",
	"erosion",
	"final_climate",
	"water",
	"biomes",
	"land_regions",
	"resources",
	"final_map",
]
const REQUIRED_REGRESSION_SCENES := [
	"res://tests/milestone_1_smoke.tscn",
	"res://tests/milestone_2_hydrology.tscn",
	"res://tests/milestone_3_optimization.tscn",
	"res://tests/milestone_4_coordinates.tscn",
	"res://tests/milestone_5_tiling.tscn",
	"res://tests/milestone_5_full_tiling.tscn",
	"res://tests/milestone_6_cartography.tscn",
	"res://tests/milestone_7_integrity.tscn",
	"res://tests/milestone_7_1_planet_project.tscn",
	"res://tests/milestone_7_2_export_system.tscn",
	"res://tests/milestone_7_3_ui_progress.tscn",
	"res://tests/milestone_7_4_map_viewer.tscn",
	"res://tests/milestone_7_5_templates.tscn",
	"res://tests/milestone_7_6_batch.tscn",
	"res://tests/milestone_7_7_ui_polish.tscn",
	"res://tests/milestone_8_release_stabilization.tscn",
	"res://tests/milestone_8_1_optimization.tscn",
]

const NON_DETERMINISTIC_LAYER_KEYS := {
	"manifest": true,
	"project": true,
	"integrity_report": true,
	"catalog": true,
	"batch_report": true,
	"release_candidate_report": true,
}

static func validate_export_tree(project_directory: String) -> Dictionary:
	var checks: Array[Dictionary] = []
	var project := PlanetProject.load_project(project_directory)
	_add(checks, "project.load", "PASS" if bool(project.get("ok", false)) else "FAIL",
		"planet_project.json resolves every referenced layer." if bool(project.get("ok", false)) else str(project.get("reason", "project load failed")), {
			"missing_layers": project.get("missing_layers", []),
		})

	var integrity_path := project_directory.path_join("integrity_report.json")
	var integrity := _read_json(integrity_path)
	var integrity_result := str(integrity.get("result", "MISSING"))
	_add(checks, "integrity.result", "PASS" if integrity_result == "PASS" else "FAIL",
		"Global integrity report passes." if integrity_result == "PASS" else "Global integrity report is missing or failed.", {
			"result": integrity_result,
		})

	var manifest_path := project_directory.path_join("planet_manifest.json")
	var manifest := _read_json(manifest_path)
	_add(checks, "manifest.load", "PASS" if not manifest.is_empty() else "FAIL",
		"planet_manifest.json is readable." if not manifest.is_empty() else "planet_manifest.json is missing or invalid.")

	var expected_size := Vector2i.ZERO
	if manifest.has("grid"):
		var dimensions = manifest["grid"].get("dimensions", [])
		if dimensions is Array and dimensions.size() >= 2:
			expected_size = Vector2i(int(dimensions[0]), int(dimensions[1]))

	var layers: Dictionary = project.get("layers", {})
	var project_manifest: Dictionary = project.get("manifest", {})
	var project_layer_entries: Dictionary = project_manifest.get("layers", {})
	var corrupt_pngs: Array[String] = []
	var wrong_dimensions: Array[String] = []
	var empty_files: Array[String] = []
	var checksum_mismatches: Array[String] = []
	for key in layers:
		var path := str(layers[key])
		if not FileAccess.file_exists(path) or FileAccess.get_size(path) <= 0:
			empty_files.append(str(key))
			continue
		if project_layer_entries.has(key):
			var entry: Dictionary = project_layer_entries[key]
			var expected_hash := str(entry.get("sha256", ""))
			if not expected_hash.is_empty():
				# Release acceptance must always verify current on-disk bytes. Other
				# call sites may reuse the bounded checksum cache, but this gate
				# deliberately invalidates first so a coarse filesystem mtime can
				# never turn a same-size rewrite into a false PASS.
				FileChecksumCache.invalidate(path)
				if FileChecksumCache.sha256(path) != expected_hash:
					checksum_mismatches.append(str(key))
		if path.get_extension().to_lower() != "png":
			continue
		var image := Image.new()
		if image.load(path) != OK or image.is_empty():
			corrupt_pngs.append(str(key))
			continue
		if expected_size != Vector2i.ZERO and image.get_size() != expected_size:
			wrong_dimensions.append(str(key))
	_add(checks, "exports.files", "PASS" if empty_files.is_empty() else "FAIL",
		"Every referenced export is non-empty." if empty_files.is_empty() else "One or more referenced exports are empty/missing.", {
			"bad_layers": empty_files,
		})
	_add(checks, "exports.checksums", "PASS" if checksum_mismatches.is_empty() else "FAIL",
		"Every project layer matches its recorded SHA-256." if checksum_mismatches.is_empty() else "One or more exported files changed after the project manifest was written.", {
			"bad_layers": checksum_mismatches,
		})
	_add(checks, "exports.png_decode", "PASS" if corrupt_pngs.is_empty() else "FAIL",
		"Every referenced PNG decodes successfully." if corrupt_pngs.is_empty() else "One or more PNG exports cannot be decoded.", {
			"bad_layers": corrupt_pngs,
		})
	_add(checks, "exports.dimensions", "PASS" if wrong_dimensions.is_empty() else "FAIL",
		"Every global PNG matches the canonical grid dimensions." if wrong_dimensions.is_empty() else "One or more PNG exports have unexpected dimensions.", {
			"expected": [expected_size.x, expected_size.y],
			"bad_layers": wrong_dimensions,
		})
	return _finish(checks)


static func deterministic_layer_hashes(project_directory: String) -> Dictionary:
	var project_path := project_directory.path_join(PlanetProject.FILE_NAME)
	var manifest := _read_json(project_path)
	var hashes: Dictionary = {}
	if manifest.is_empty():
		return hashes
	var layers: Dictionary = manifest.get("layers", {})
	var names := layers.keys()
	names.sort()
	for key_value in names:
		var key := str(key_value)
		if NON_DETERMINISTIC_LAYER_KEYS.has(key):
			continue
		var entry = layers[key_value]
		if not entry is Dictionary:
			continue
		var hash := str(entry.get("sha256", ""))
		if not hash.is_empty():
			hashes[key] = hash
	return hashes


static func compare_hash_sets(first: Dictionary, second: Dictionary) -> Dictionary:
	var all_keys: Dictionary = {}
	for key in first:
		all_keys[str(key)] = true
	for key in second:
		all_keys[str(key)] = true
	var missing_first: Array[String] = []
	var missing_second: Array[String] = []
	var mismatches: Array[Dictionary] = []
	var keys := all_keys.keys()
	keys.sort()
	for key_value in keys:
		var key := str(key_value)
		if not first.has(key):
			missing_first.append(key)
			continue
		if not second.has(key):
			missing_second.append(key)
			continue
		if str(first[key]) != str(second[key]):
			mismatches.append({
				"layer": key,
				"first": str(first[key]),
				"second": str(second[key]),
			})
	var ok := missing_first.is_empty() and missing_second.is_empty() and mismatches.is_empty() and not keys.is_empty()
	return {
		"ok": ok,
		"status": "PASS" if ok else "FAIL",
		"layer_count": keys.size(),
		"missing_first": missing_first,
		"missing_second": missing_second,
		"mismatches": mismatches,
	}


static func evaluate_memory_series(samples: Array, warmup_runs: int = 5,
		minimum_allowance_bytes: int = 64 * 1024 * 1024,
		fractional_allowance: float = 0.10) -> Dictionary:
	var values: Array[int] = []
	for value in samples:
		values.append(maxi(int(value), 0))
	if values.size() < 2:
		return {
			"ok": false,
			"status": "SKIP",
			"reason": "not enough memory samples",
			"samples": values.size(),
		}
	var start := mini(maxi(warmup_runs, 0), values.size() - 1)
	var stable: Array[int] = []
	for index in range(start, values.size()):
		stable.append(values[index])
	var baseline := _median(stable.slice(0, mini(5, stable.size())))
	var tail_start := maxi(stable.size() - mini(5, stable.size()), 0)
	var tail := _median(stable.slice(tail_start, stable.size()))
	var allowance := maxi(minimum_allowance_bytes, int(round(float(maxi(baseline, 1)) * fractional_allowance)))
	var drift := tail - baseline
	var ok := drift <= allowance
	return {
		"ok": ok,
		"status": "PASS" if ok else "FAIL",
		"samples": values.size(),
		"warmup_ignored": start,
		"baseline_median_bytes": baseline,
		"tail_median_bytes": tail,
		"drift_bytes": drift,
		"allowed_drift_bytes": allowance,
	}


static func validate_package_resources() -> Dictionary:
	var required := [
		"res://project.godot",
		"res://export_presets.cfg",
		CartographicPalette.DEFAULT_PATH,
		"res://data/scn/master.tscn",
	]
	var missing: Array[String] = []
	for path in required:
		if not FileAccess.file_exists(str(path)):
			missing.append(str(path))
	var shader_dir := DirAccess.open("res://shader/compute")
	var shader_count := 0
	var empty_shaders: Array[String] = []
	if shader_dir != null:
		shader_count = _scan_shader_tree("res://shader/compute", empty_shaders)
	else:
		missing.append("res://shader/compute")
	var ok := missing.is_empty() and empty_shaders.is_empty() and shader_count > 0
	return {
		"ok": ok,
		"status": "PASS" if ok else "FAIL",
		"required_missing": missing,
		"shader_count": shader_count,
		"empty_shaders": empty_shaders,
	}


static func required_regression_scenes_present() -> Dictionary:
	var missing: Array[String] = []
	for path in REQUIRED_REGRESSION_SCENES:
		if not FileAccess.file_exists(path):
			missing.append(path)
	return {
		"ok": missing.is_empty(),
		"status": "PASS" if missing.is_empty() else "FAIL",
		"required": REQUIRED_REGRESSION_SCENES.size(),
		"missing": missing,
	}


static func validate_regression_report(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {
			"ok": false,
			"status": "SKIP",
			"reason": "regression execution report not supplied",
		}
	var report := _read_json(path)
	if report.is_empty():
		return {"ok": false, "status": "FAIL", "reason": "invalid regression report"}
	var tests: Array = report.get("tests", [])
	var passed := 0
	var observed: Dictionary = {}
	for test_value in tests:
		if not test_value is Dictionary:
			continue
		var test: Dictionary = test_value
		var scene := str(test.get("scene", ""))
		observed[scene] = true
		if bool(test.get("ok", false)):
			passed += 1
	var missing: Array[String] = []
	for scene in REQUIRED_REGRESSION_SCENES:
		if not observed.has(scene):
			missing.append(scene)
	var ok := str(report.get("result", "FAIL")) == "PASS" and missing.is_empty() and passed == REQUIRED_REGRESSION_SCENES.size()
	return {
		"ok": ok,
		"status": "PASS" if ok else "FAIL",
		"path": path,
		"passed": passed,
		"required": REQUIRED_REGRESSION_SCENES.size(),
		"missing": missing,
	}


static func _scan_shader_tree(path: String, empty_shaders: Array[String]) -> int:
	var directory := DirAccess.open(path)
	if directory == null:
		return 0
	var count := 0
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				count += _scan_shader_tree(child, empty_shaders)
			elif entry.ends_with(".glsl"):
				count += 1
				if FileAccess.get_size(child) <= 0:
					empty_shaders.append(child)
		entry = directory.get_next()
	directory.list_dir_end()
	return count


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return int(sorted[middle])
	return int((int(sorted[middle - 1]) + int(sorted[middle])) / 2)


static func _add(checks: Array[Dictionary], check_id: String, status: String,
		message: String, detail: Dictionary = {}) -> void:
	checks.append({
		"id": check_id,
		"status": status,
		"message": message,
		"detail": detail,
	})


static func _finish(checks: Array[Dictionary]) -> Dictionary:
	var failures := 0
	var skipped := 0
	for check in checks:
		match str(check.get("status", "FAIL")):
			"FAIL": failures += 1
			"SKIP": skipped += 1
	return {
		"validator_version": VALIDATOR_VERSION,
		"result": "PASS" if failures == 0 else "FAIL",
		"failures": failures,
		"skipped": skipped,
		"checks": checks,
	}
