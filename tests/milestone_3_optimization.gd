extends Node

const TEST_RESOLUTION := Vector2i(128, 64)
const TEST_SEED := 2577655122
const CONSECUTIVE_GENERATIONS := 20

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var reference_final_hash := 0
	var deterministic := true
	var lifecycle_clean := true
	var compact_resource_format := true
	var dependency_only_sync := true
	var streamed_export := false
	var minimal_export_fast_path := false
	var minimal_retained_quality := false
	var automatic_workers := false
	var peak_vram_bytes := 0
	var maximum_post_export_vram_bytes := 0
	var maximum_sync_count := 0
	var minimum_queued_lists := 1 << 30
	var first_report: Dictionary = {}
	var first_export_metrics: Dictionary = {}
	var minimal_export_metrics: Dictionary = {}
	var ram_after_first_cleanup := 0
	var peak_ram_after_cleanup := 0

	for generation_index in range(CONSECUTIVE_GENERATIONS):
		var params := _parameters()
		var gpu := GPUContext.new(TEST_RESOLUTION)
		if not gpu or not gpu.rd:
			push_error("Milestone 3 could not create a RenderingDevice")
			_quit(1)
			return
		var orchestrator := GPUOrchestrator.new(
			gpu, TEST_RESOLUTION, params
		)
		if not orchestrator or not orchestrator.rd:
			push_error("Milestone 3 could not create GPUOrchestrator")
			gpu.cleanup()
			_quit(1)
			return

		orchestrator.run_simulation()
		var report := orchestrator.last_performance_report.duplicate(true)
		if generation_index == 0:
			first_report = report
		var final_data := gpu.readback_texture_raw("final_map")
		var final_hash := hash(final_data)
		if generation_index == 0:
			reference_final_hash = final_hash
		else:
			deterministic = deterministic and final_hash == reference_final_hash

		var current_vram := gpu.get_vram_usage_bytes()
		peak_vram_bytes = maxi(
			peak_vram_bytes, int(report.get("peak_vram_bytes", 0))
		)
		maximum_post_export_vram_bytes = maxi(
			maximum_post_export_vram_bytes, current_vram
		)
		var queued_lists := int(report.get("queued_compute_lists", 0))
		var sync_count := int(report.get("sync_count", 0))
		minimum_queued_lists = mini(minimum_queued_lists, queued_lists)
		maximum_sync_count = maxi(maximum_sync_count, sync_count)
		dependency_only_sync = dependency_only_sync and (
			queued_lists >= 20 and sync_count > 0 and sync_count * 4 < queued_lists
		)

		var lifecycle: Dictionary = report.get("lifecycle_release", {})
		lifecycle_clean = lifecycle_clean and (
			int(lifecycle.get("released_bytes", 0)) > 0
			and int(lifecycle.get("remaining_bytes", 0)) < int(report.get("peak_vram_bytes", 0))
			and gpu.uniform_sets.is_empty()
			and gpu.pipelines.is_empty()
			and gpu.shaders.is_empty()
			and not gpu.textures.has("geo_temp")
			and not gpu.textures.has("crust_age_temp")
		)

		if gpu.textures.has("resources"):
			compact_resource_format = compact_resource_format and (
				gpu.rd.texture_get_format(gpu.textures["resources"]).format
				== GPUContext.FORMAT_RGBA8UI
			)
		else:
			compact_resource_format = false

		if generation_index == 0:
			var export_dir := ProjectSettings.globalize_path(
				"user://milestone_3_stream_export"
			)
			var exporter := PlanetExporter.new()
			var exported := exporter.export_maps(gpu, export_dir, params)
			first_export_metrics = exporter.last_metrics.duplicate(true)
			streamed_export = (
				not exported.is_empty()
				and int(first_export_metrics.get(
					"peak_simultaneous_rgba32f_maps", 0
				)) <= 1
				and int(first_export_metrics.get("rgba32f_map_readbacks", 0)) >= 2
				and float(first_export_metrics.get("png_compression_ms", 0.0)) > 0.0
				and float(first_export_metrics.get("cpu_conversion_ms", 0.0)) > 0.0
			)
			automatic_workers = (
				str(first_export_metrics.get("worker_policy", "")) == "automatic"
				and int(first_export_metrics.get("worker_count", 0)) > 0
			)

			# The minimal preset must skip work before readback/compression while
			# retaining byte-identical versions of every map it promises to keep.
			var minimal_export_dir := ProjectSettings.globalize_path(
				"user://milestone_3_minimal_export"
			)
			var minimal_params := params.duplicate(true)
			minimal_params["export_preset"] = ExportCatalog.PRESET_MINIMAL
			var minimal_exporter := PlanetExporter.new()
			var minimal_exported := minimal_exporter.export_maps(
				gpu, minimal_export_dir, minimal_params
			)
			minimal_export_metrics = minimal_exporter.last_metrics.duplicate(true)
			var minimal_stage_plan: Dictionary = minimal_export_metrics.get(
				"stage_plan", {}
			)
			var minimal_keys_exact := true
			for exported_key_value in minimal_exported:
				var exported_key := str(exported_key_value)
				minimal_keys_exact = minimal_keys_exact and (
					exported_key in ExportCatalog.MINIMAL_KEYS
					or exported_key in ExportCatalog.ALWAYS_METADATA
				)
			for retained_key in ExportCatalog.MINIMAL_KEYS:
				minimal_keys_exact = minimal_keys_exact and minimal_exported.has(
					retained_key
				)
			minimal_export_fast_path = (
				minimal_keys_exact
				and not bool(minimal_stage_plan.get("plates", true))
				and not bool(minimal_stage_plan.get("topography", true))
				and not bool(minimal_stage_plan.get("climate", true))
				and not bool(minimal_stage_plan.get("administration", true))
				and not bool(minimal_stage_plan.get("grid", true))
				and not bool(minimal_stage_plan.get("resources", true))
				and int(minimal_export_metrics.get("rgba32f_map_readbacks", 0)) <= 1
				and int(minimal_export_metrics.get("readback_count", 0))
					< int(first_export_metrics.get("readback_count", 0))
				and int(minimal_export_metrics.get("png_jobs", 0))
					== ExportCatalog.MINIMAL_KEYS.size()
				and int(minimal_export_metrics.get("gpu_export_shaders_loaded", 0)) == 1
			)
			minimal_retained_quality = _retained_exports_match(
				exported, minimal_exported
			)
			_remove_tree(export_dir)
			_remove_tree(minimal_export_dir)

		orchestrator.cleanup()
		lifecycle_clean = lifecycle_clean and (
			gpu.textures.is_empty()
			and gpu.uniform_sets.is_empty()
			and gpu.pipelines.is_empty()
			and gpu.shaders.is_empty()
		)
		var current_ram := int(Performance.get_monitor(Performance.MEMORY_STATIC))
		if generation_index == 0:
			ram_after_first_cleanup = current_ram
		peak_ram_after_cleanup = maxi(peak_ram_after_cleanup, current_ram)

	print("[Milestone3] generations=", CONSECUTIVE_GENERATIONS)
	print("[Milestone3] deterministic=", deterministic,
		" final_hash=", reference_final_hash)
	print("[Milestone3] lifecycle_clean=", lifecycle_clean)
	print("[Milestone3] dependency_only_sync=", dependency_only_sync,
		" queued_lists_min=", minimum_queued_lists,
		" sync_count_max=", maximum_sync_count)
	print("[Milestone3] compact_resource_format=", compact_resource_format)
	print("[Milestone3] streamed_export=", streamed_export,
		" metrics=", first_export_metrics)
	print("[Milestone3] minimal_export_fast_path=", minimal_export_fast_path,
		" retained_quality=", minimal_retained_quality,
		" metrics=", minimal_export_metrics)
	print("[Milestone3] automatic_export_workers=", automatic_workers)
	print("[Milestone3] peak_vram_bytes=", peak_vram_bytes,
		" post_export_vram_bytes_max=", maximum_post_export_vram_bytes)
	print("[Milestone3] ram_after_first_cleanup=", ram_after_first_cleanup,
		" peak_ram_after_cleanup=", peak_ram_after_cleanup)
	print("[Milestone3] first_performance_report=", first_report)

	var passed := (
		deterministic
		and lifecycle_clean
		and dependency_only_sync
		and compact_resource_format
		and streamed_export
		and minimal_export_fast_path
		and minimal_retained_quality
		and automatic_workers
	)
	_quit(0 if passed else 1)

func _parameters() -> Dictionary:
	return {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": 15.0,
		"global_humidity": 0.65,
		"avg_precipitation": 0.65,
		"sea_level": 0.0,
		"ocean_ratio": 55.0,
		"terrain_scale": 150.0,
		"erosion_iterations": 8,
		"rain_rate": 0.02,
		"evap_rate": 0.01,
		"flow_rate": 0.35,
		"erosion_rate": 0.15,
		"deposition_rate": 0.12,
		"capacity_multiplier": 2.5,
		"flux_iterations": 2,
		"spreading_rate": 50.0,
		"max_crust_age": 200.0,
		"subsidence_coeff": 2800.0,
		"lake_threshold": 5.0,
		"freshwater_min_size": 8,
		"saltwater_min_size": 64,
		"river_precip_scale": 1.0,
		"nb_cases_regions": 24,
		"nb_cases_ocean_regions": 48,
		"region_iterations": TEST_RESOLUTION.x,
		"ocean_iterations": TEST_RESOLUTION.x,
		"global_richness": 1.0,
		"export_worker_count": 0,
	}

func _retained_exports_match(standard_export: Dictionary,
		minimal_export: Dictionary) -> bool:
	for retained_key in ExportCatalog.MINIMAL_KEYS:
		if not standard_export.has(retained_key) or not minimal_export.has(retained_key):
			return false
		var standard_path := str(standard_export[retained_key])
		var minimal_path := str(minimal_export[retained_key])
		var standard_hash := FileChecksumCache.sha256(standard_path)
		var minimal_hash := FileChecksumCache.sha256(minimal_path)
		if standard_hash.is_empty() or standard_hash != minimal_hash:
			push_error("Minimal export changed retained map '%s'" % retained_key)
			return false
	return true

func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)

func _quit(exit_code: int) -> void:
	GPUContext.shutdown_shared_device()
	get_tree().quit(exit_code)
