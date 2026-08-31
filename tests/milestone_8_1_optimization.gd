extends Node

func _ready() -> void:
	var temp_dir := "user://m81_test"
	DirAccess.make_dir_recursive_absolute(temp_dir)
	var temp_file := temp_dir.path_join("checksum.txt")
	var file := FileAccess.open(temp_file, FileAccess.WRITE)
	assert(file != null)
	file.store_string("planet-generator")
	file.close()

	FileChecksumCache.clear()
	FileChecksumCache.reset_metrics()
	var first := FileChecksumCache.sha256(temp_file)
	var second := FileChecksumCache.sha256(temp_file)
	assert(not first.is_empty())
	assert(first == second)
	var cache_metrics := FileChecksumCache.metrics()
	assert(int(cache_metrics.get("misses", 0)) == 1)
	assert(int(cache_metrics.get("hits", 0)) >= 1)

	# A rewrite must invalidate/recompute the checksum even if the path is reused.
	FileChecksumCache.invalidate(temp_file)
	file = FileAccess.open(temp_file, FileAccess.WRITE)
	file.store_string("planet-generator-optimized")
	file.close()
	var third := FileChecksumCache.sha256(temp_file)
	assert(third != first)

	var base_hashes := {"height": "a", "water": "b"}
	var base_report := _synthetic_report(base_hashes, 100.0, 20.0)
	var optimized_report := _synthetic_report(base_hashes, 90.0, 15.0)
	var guard := FinalOptimizationGuard.compare_reports(base_report, optimized_report)
	assert(str(guard.get("result", "FAIL")) == "PASS")

	var changed_report := _synthetic_report({"height": "changed", "water": "b"}, 90.0, 15.0)
	guard = FinalOptimizationGuard.compare_reports(base_report, changed_report)
	assert(str(guard.get("result", "PASS")) == "FAIL")

	DirAccess.remove_absolute(temp_file)
	DirAccess.remove_absolute(temp_dir)
	print("Milestone 8.1 final optimization contract: PASS")
	get_tree().quit()

func _synthetic_report(hashes: Dictionary, elapsed_ms: float, export_ms: float) -> Dictionary:
	return {
		"result": "PASS_WITH_EXTERNAL_GATES",
		"determinism_hashes": {"determinism_a": hashes},
		"runs": [{
			"kind": "stability",
			"ok": true,
			"elapsed_ms": elapsed_ms,
			"performance": {
				"sync_time_ms": 10.0,
				"readback_time_ms": 5.0,
				"peak_vram_bytes": 1024,
				"peak_system_ram_bytes": 2048,
			},
			"export_metrics": {"total_export_ms": export_ms},
		}],
	}
