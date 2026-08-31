extends Node

## Addon regression for the standalone 3.1.0 dry-world changes.
##
## This intentionally exercises the addon-internal generation core because it
## validates behavior below the public service layer: disabled hydrology must be
## initialized deterministically, land administration must still cover the
## planet, petroleum must remain absent, and mineral resources must not collapse
## back to round stamp-like deposits.

const TEST_RESOLUTION := Vector2i(256, 128)
const TEST_SEED := 3957264121
const OUTPUT_ROOT := "user://planet_generator/upstream_3_1_airless_test"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[Planet Generator Addon] upstream 3.1 airless/resource regression: START")
	var generation_params := _parameters()
	var gpu := PGGPUContext.new(TEST_RESOLUTION)
	if gpu == null or gpu.rd == null:
		_fail_and_quit("Could not create local RenderingDevice")
		return

	var orchestrator := PGGPUOrchestrator.new(gpu, TEST_RESOLUTION, generation_params)
	if orchestrator == null or orchestrator.rd == null:
		gpu.cleanup()
		_fail_and_quit("Could not initialize PGGPUOrchestrator")
		return

	orchestrator.run_simulation()
	var pixels := TEST_RESOLUTION.x * TEST_RESOLUTION.y

	var water_mask := gpu.readback_texture_raw("water_mask")
	var flow_direction := gpu.readback_texture_raw("flow_direction")
	var river_type := gpu.readback_texture_raw("ocean_reachable")
	var river_biome := gpu.readback_texture_raw("river_biome_id")
	var river_flux := gpu.readback_texture_raw("river_flux")
	var water_colored := gpu.readback_texture_raw("water_colored")
	var region_map := gpu.readback_texture_raw("region_map")
	var petroleum := gpu.readback_texture_raw("petrole")
	var resources := gpu.readback_texture_raw("resources")

	var hydrology_ok := (
		_all_bytes_equal(water_mask, 0)
		and _all_bytes_equal(flow_direction, 255)
		and _all_bytes_equal(river_type, 255)
		and _all_u32_sentinel(river_biome)
		and _all_float32_zero(river_flux)
		and _all_bytes_equal(water_colored, 0)
	)
	var administration_ok := _count_u32_sentinel(region_map) == 0
	var petroleum_ok := _all_bytes_equal(petroleum, 0)

	var morphology := _measure_resource_morphology(
		resources, TEST_RESOLUTION.x, TEST_RESOLUTION.y
	)
	var morphology_ok := (
		int(morphology.get("present_pixels", 0)) > pixels / 200
		and int(morphology.get("resource_ids", 0)) >= 4
		and float(morphology.get("boundary_fraction", 0.0)) > 0.08
	)

	var output_dir := ProjectSettings.globalize_path(OUTPUT_ROOT)
	_remove_tree(output_dir)
	var exporter := PGPlanetExporter.new()
	var exported := exporter.export_maps(gpu, output_dir, generation_params)

	var export_ok := true
	for key in [
		"final_map", "region_colored", "Régions terrestres",
		"Pays", "Continents", "eaux_map", "petrole_map",
	]:
		export_ok = export_ok and exported.has(key)
	export_ok = export_ok and _alpha_is(str(exported.get("eaux_map", "")), 0)
	export_ok = export_ok and _alpha_is(str(exported.get("petrole_map", "")), 0)
	for key in ["region_colored", "Régions terrestres", "Pays", "Continents"]:
		export_ok = export_ok and _alpha_is(str(exported.get(key, "")), 255)

	var integrity_ok := false
	var integrity_path := str(exported.get("integrity_report", ""))
	if FileAccess.file_exists(integrity_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(integrity_path))
		if parsed is Dictionary:
			integrity_ok = str(parsed.get("result", "")) == "PASS"

	print("[Planet Generator Addon] disabled hydrology: ", hydrology_ok)
	print("[Planet Generator Addon] all land administratively assigned: ", administration_ok)
	print("[Planet Generator Addon] petroleum absent: ", petroleum_ok)
	print("[Planet Generator Addon] resource morphology: ", morphology)
	print("[Planet Generator Addon] export contract: ", export_ok)
	print("[Planet Generator Addon] integrity: ", integrity_ok)
	print("[Planet Generator Addon] output: ", output_dir)

	var passed := hydrology_ok and administration_ok and petroleum_ok and morphology_ok and export_ok and integrity_ok
	orchestrator.cleanup()
	PGGPUContext.shutdown_shared_device()

	if passed:
		print("[Planet Generator Addon] upstream 3.1 airless/resource regression: PASS")
		get_tree().quit(0)
	else:
		push_error("[Planet Generator Addon] upstream 3.1 airless/resource regression: FAIL")
		get_tree().quit(1)


func _parameters() -> Dictionary:
	return {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": PGPlanetData.TYPE_NO_ATMOS,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": 3.0,
		"global_humidity": 0.5,
		"avg_precipitation": 0.5,
		"sea_level": 0.0,
		"ocean_ratio": 55.0,
		"terrain_scale": 150.0,
		"erosion_iterations": 8,
		"rain_rate": 0.005,
		"evap_rate": 0.02,
		"flow_rate": 0.25,
		"erosion_rate": 0.05,
		"deposition_rate": 0.05,
		"capacity_multiplier": 1.0,
		"flux_iterations": 2,
		"spreading_rate": 50.0,
		"max_crust_age": 200.0,
		"subsidence_coeff": 2800.0,
		"crater_density": 0.5,
		"crater_min_radius": 3.0,
		"crater_max_radius": 24.0,
		"crater_depth_ratio": 0.25,
		"crater_ejecta_extent": 2.5,
		"crater_ejecta_decay": 3.0,
		"crater_azimuth_var": 0.3,
		"nb_cases_regions": 50,
		"region_iterations": TEST_RESOLUTION.x,
		"region_noise_strength": 0.5,
		"global_richness": 1.0,
		"petrole_probability": 0.025,
		"petrole_deposit_size": 200.0,
		"export_preset": PGExportCatalog.PRESET_COMPLETE,
		"export_cartographic_map": true,
		"export_grid_overlay": true,
		"run_integrity_checks": true,
		"export_worker_count": 0,
	}


func _all_bytes_equal(data: PackedByteArray, expected: int) -> bool:
	if data.is_empty():
		return false
	for value in data:
		if int(value) != expected:
			return false
	return true


func _all_u32_sentinel(data: PackedByteArray) -> bool:
	if data.is_empty() or data.size() % 4 != 0:
		return false
	for value in data.to_int32_array():
		if int(value) != -1:
			return false
	return true


func _all_float32_zero(data: PackedByteArray) -> bool:
	if data.is_empty() or data.size() % 4 != 0:
		return false
	for value in data.to_float32_array():
		if not is_zero_approx(float(value)):
			return false
	return true


func _count_u32_sentinel(data: PackedByteArray) -> int:
	if data.is_empty() or data.size() % 4 != 0:
		return -1
	var count := 0
	for value in data.to_int32_array():
		if int(value) == -1:
			count += 1
	return count


func _measure_resource_morphology(data: PackedByteArray, width: int, height: int) -> Dictionary:
	if data.size() != width * height * 4:
		return {}
	var present := 0
	var boundary := 0
	var ids: Dictionary = {}
	var neighbors := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
	for y in range(height):
		for x in range(width):
			var offset := (y * width + x) * 4
			if int(data[offset + 3]) == 0:
				continue
			present += 1
			var resource_id := int(data[offset])
			ids[resource_id] = true
			var same := 0
			for delta in neighbors:
				var nx := posmod(x + delta.x, width)
				var ny := y + delta.y
				if ny < 0 or ny >= height:
					continue
				var neighbor_offset := (ny * width + nx) * 4
				if int(data[neighbor_offset + 3]) > 0 and int(data[neighbor_offset]) == resource_id:
					same += 1
			if same < 4:
				boundary += 1
	return {
		"present_pixels": present,
		"resource_ids": ids.size(),
		"boundary_pixels": boundary,
		"boundary_fraction": float(boundary) / float(maxi(present, 1)),
	}


func _alpha_is(path: String, expected: int) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var image := Image.new()
	if image.load(path) != OK:
		return false
	var rgba := image.get_data()
	for offset in range(3, rgba.size(), 4):
		if int(rgba[offset]) != expected:
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


func _fail_and_quit(message: String) -> void:
	push_error("[Planet Generator Addon] " + message)
	PGGPUContext.shutdown_shared_device()
	get_tree().quit(1)
