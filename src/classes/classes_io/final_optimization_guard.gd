class_name FinalOptimizationGuard
extends RefCounted

## Milestone 8.1 — compares an M8 baseline report with an optimized report.
## Optimization is accepted only if deterministic output hashes still match and
## the optimized run does not regress the measured release workload beyond the
## configured tolerance.

const GUARD_VERSION := 1

static func compare_reports(baseline: Dictionary, optimized: Dictionary,
		performance_regression_tolerance: float = 0.05) -> Dictionary:
	var checks: Array[Dictionary] = []
	var base_hashes: Dictionary = baseline.get("determinism_hashes", {}).get("determinism_a", {})
	var opt_hashes: Dictionary = optimized.get("determinism_hashes", {}).get("determinism_a", {})
	var hashes := ReleaseStabilityValidator.compare_hash_sets(base_hashes, opt_hashes)
	_add(checks, "authoritative_hashes", "PASS" if bool(hashes.get("ok", false)) else "FAIL", hashes)

	var baseline_release_ok := str(baseline.get("result", "FAIL")) in ["PASS", "PASS_WITH_EXTERNAL_GATES"]
	var optimized_release_ok := str(optimized.get("result", "FAIL")) in ["PASS", "PASS_WITH_EXTERNAL_GATES"]
	_add(checks, "release_gates", "PASS" if baseline_release_ok and optimized_release_ok else "FAIL", {
		"baseline": str(baseline.get("result", "MISSING")),
		"optimized": str(optimized.get("result", "MISSING")),
	})

	var base_perf := _aggregate_stability_performance(baseline)
	var opt_perf := _aggregate_stability_performance(optimized)
	var performance := _compare_performance(base_perf, opt_perf, performance_regression_tolerance)
	_add(checks, "performance", str(performance.get("status", "FAIL")), performance)

	var failures := 0
	for check in checks:
		if str(check.get("status", "FAIL")) == "FAIL":
			failures += 1
	return {
		"optimization_guard_version": GUARD_VERSION,
		"result": "PASS" if failures == 0 else "FAIL",
		"failures": failures,
		"checks": checks,
		"baseline_performance": base_perf,
		"optimized_performance": opt_perf,
		"checksum_cache": FileChecksumCache.metrics(),
	}

static func load_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

static func save_report(path: String, report: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(report, "  ", true))
	file.close()
	return true

static func _aggregate_stability_performance(report: Dictionary) -> Dictionary:
	var elapsed: Array[float] = []
	var sync_ms: Array[float] = []
	var readback_ms: Array[float] = []
	var export_ms: Array[float] = []
	var peak_vram := 0
	var peak_ram := 0
	for run_value in report.get("runs", []):
		if not run_value is Dictionary:
			continue
		var run: Dictionary = run_value
		if str(run.get("kind", "")) != "stability" or not bool(run.get("ok", false)):
			continue
		elapsed.append(float(run.get("elapsed_ms", 0.0)))
		var perf: Dictionary = run.get("performance", {})
		var export: Dictionary = run.get("export_metrics", {})
		sync_ms.append(float(perf.get("sync_time_ms", 0.0)))
		readback_ms.append(float(perf.get("readback_time_ms", 0.0)))
		export_ms.append(float(export.get("total_export_ms", 0.0)))
		peak_vram = maxi(peak_vram, int(perf.get("peak_vram_bytes", 0)))
		peak_ram = maxi(peak_ram, int(perf.get("peak_system_ram_bytes", 0)))
	return {
		"runs": elapsed.size(),
		"median_elapsed_ms": _median_float(elapsed),
		"median_sync_ms": _median_float(sync_ms),
		"median_readback_ms": _median_float(readback_ms),
		"median_export_ms": _median_float(export_ms),
		"peak_vram_bytes": peak_vram,
		"peak_system_ram_bytes": peak_ram,
	}

static func _compare_performance(baseline: Dictionary, optimized: Dictionary,
		tolerance: float) -> Dictionary:
	if int(baseline.get("runs", 0)) <= 0 or int(optimized.get("runs", 0)) <= 0:
		return {"status": "SKIP", "reason": "release reports contain no successful stability runs"}
	var metrics := ["median_elapsed_ms", "median_sync_ms", "median_readback_ms", "median_export_ms"]
	var regressions: Array[Dictionary] = []
	var changes: Dictionary = {}
	for metric in metrics:
		var before := float(baseline.get(metric, 0.0))
		var after := float(optimized.get(metric, 0.0))
		if before <= 0.0:
			continue
		var change := (after - before) / before
		changes[metric] = change
		if change > tolerance:
			regressions.append({"metric": metric, "fraction": change, "before": before, "after": after})
	var vram_before := int(baseline.get("peak_vram_bytes", 0))
	var vram_after := int(optimized.get("peak_vram_bytes", 0))
	if vram_before > 0 and vram_after > int(round(float(vram_before) * (1.0 + tolerance))):
		regressions.append({"metric": "peak_vram_bytes", "before": vram_before, "after": vram_after})
	var ram_before := int(baseline.get("peak_system_ram_bytes", 0))
	var ram_after := int(optimized.get("peak_system_ram_bytes", 0))
	if ram_before > 0 and ram_after > int(round(float(ram_before) * (1.0 + tolerance))):
		regressions.append({"metric": "peak_system_ram_bytes", "before": ram_before, "after": ram_after})
	return {
		"status": "PASS" if regressions.is_empty() else "FAIL",
		"tolerance_fraction": tolerance,
		"changes": changes,
		"regressions": regressions,
	}

static func _median_float(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return float(sorted[middle])
	return (float(sorted[middle - 1]) + float(sorted[middle])) * 0.5

static func _add(checks: Array[Dictionary], check_id: String, status: String, detail: Dictionary) -> void:
	checks.append({"id": check_id, "status": status, "detail": detail})
