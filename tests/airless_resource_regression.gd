extends Node

const TEST_RESOLUTION := Vector2i(256, 128)
const TEST_SEED := 3957264121
const EXPORT_ROOT := "user://temp/airless_resource_regression"

func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var params := _parameters()
	var gpu := GPUContext.new(TEST_RESOLUTION)
	if not gpu or not gpu.rd:
		_quit_with_error("Could not create RenderingDevice")
		return
	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if not orchestrator or not orchestrator.rd:
		gpu.cleanup()
		_quit_with_error("Could not initialize GPUOrchestrator")
		return

	orchestrator.run_simulation()
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var water_mask := gpu.readback_texture_raw("water_mask")
	var flow_direction := gpu.readback_texture_raw("flow_direction")
	var river_type := gpu.readback_texture_raw("ocean_reachable")
	var river_biome := gpu.readback_texture_raw("river_biome_id")
	var river_flux := gpu.readback_texture_raw("river_flux")
	var water_colored := gpu.readback_texture_raw("water_colored")
	var region_map := gpu.readback_texture_raw("region_map")
	var petrole := gpu.readback_texture_raw("petrole")
	var resources := gpu.readback_texture_raw("resources")

	var hydrology_defaults_valid := (
		_all_bytes_equal(water_mask, 0)
		and _all_bytes_equal(flow_direction, 255)
		and _all_bytes_equal(river_type, 255)
		and _all_u32_equal(river_biome, 0xFFFFFFFF)
		and _all_float32_zero(river_flux)
		and _all_bytes_equal(water_colored, 0)
	)
	var all_land_assigned := _count_u32(region_map, 0xFFFFFFFF) == 0
	var petroleum_absent := _all_bytes_equal(petrole, 0)
	var morphology := _resource_morphology(resources, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var mineral_field_valid := (
		int(morphology.get("present_pixels", 0)) > pixel_count / 200
		and int(morphology.get("resource_ids", 0)) >= 4
		and float(morphology.get("boundary_fraction", 0.0)) > 0.08
	)

	var export_path := ProjectSettings.globalize_path(EXPORT_ROOT)
	_remove_tree(export_path)
	var exporter := PlanetExporter.new()
	var exported := exporter.export_maps(gpu, export_path, params)
	var export_contract_valid := (
		exported.has("final_map")
		and exported.has("region_colored")
		and exported.has("Régions terrestres")
		and exported.has("Pays")
		and exported.has("Continents")
		and exported.has("eaux_map")
		and exported.has("petrole_map")
	)
	for key in ["region_colored", "Régions terrestres", "Pays", "Continents"]:
		export_contract_valid = export_contract_valid and _image_alpha_contract(
			str(exported.get(key, "")), 255
		)
	export_contract_valid = export_contract_valid and _image_alpha_contract(
		str(exported.get("eaux_map", "")), 0
	)
	export_contract_valid = export_contract_valid and _image_alpha_contract(
		str(exported.get("petrole_map", "")), 0
	)
	var integrity_result := ""
	if exported.has("integrity_report"):
		var report_text := FileAccess.get_file_as_string(str(exported["integrity_report"]))
		var report = JSON.parse_string(report_text)
		if report is Dictionary:
			integrity_result = str(report.get("result", ""))
	export_contract_valid = export_contract_valid and integrity_result == "PASS"

	print("[AirlessResource] hydrology_defaults_valid=", hydrology_defaults_valid)
	print("[AirlessResource] all_land_assigned=", all_land_assigned)
	print("[AirlessResource] petroleum_absent=", petroleum_absent)
	print("[AirlessResource] morphology=", morphology)
	print("[AirlessResource] export_contract_valid=", export_contract_valid)
	print("[AirlessResource] output=", export_path)

	var passed := (
		hydrology_defaults_valid
		and all_land_assigned
		and petroleum_absent
		and mineral_field_valid
		and export_contract_valid
	)
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	get_tree().quit(0 if passed else 1)


func _parameters() -> Dictionary:
	return {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_NO_ATMOS,
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
		"export_preset": ExportCatalog.PRESET_COMPLETE,
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


func _all_u32_equal(data: PackedByteArray, expected: int) -> bool:
	if data.is_empty() or data.size() % 4 != 0:
		return false
	for value in data.to_int32_array():
		if int(value) != -1 and expected == 0xFFFFFFFF:
			return false
	return true


func _all_float32_zero(data: PackedByteArray) -> bool:
	if data.is_empty() or data.size() % 4 != 0:
		return false
	for value in data.to_float32_array():
		if not is_zero_approx(float(value)):
			return false
	return true


func _count_u32(data: PackedByteArray, target: int) -> int:
	var count := 0
	for value in data.to_int32_array():
		if target == 0xFFFFFFFF and int(value) == -1:
			count += 1
		elif int(value) == target:
			count += 1
	return count


func _resource_morphology(data: PackedByteArray, width: int, height: int) -> Dictionary:
	if data.size() != width * height * 4:
		return {}
	var present := 0
	var boundary := 0
	var ids: Dictionary = {}
	for y in range(height):
		for x in range(width):
			var index := y * width + x
			var offset := index * 4
			if int(data[offset + 3]) == 0:
				continue
			present += 1
			var resource_id := int(data[offset])
			ids[resource_id] = true
			var same_neighbors := 0
			for delta in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = posmod(x + int(delta.x), width)
				var ny: int = y + int(delta.y)
				if ny < 0 or ny >= height:
					continue
				var neighbor_offset: int = (ny * width + nx) * 4
				if (
					int(data[neighbor_offset + 3]) > 0
					and int(data[neighbor_offset]) == resource_id
				):
					same_neighbors += 1
			if same_neighbors < 4:
				boundary += 1
	return {
		"present_pixels": present,
		"resource_ids": ids.size(),
		"boundary_pixels": boundary,
		"boundary_fraction": float(boundary) / float(maxi(present, 1)),
	}


func _image_alpha_contract(path: String, expected_alpha: int) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var image := Image.new()
	if image.load(path) != OK:
		return false
	var rgba := image.get_data()
	for offset in range(3, rgba.size(), 4):
		if int(rgba[offset]) != expected_alpha:
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


func _quit_with_error(message: String) -> void:
	push_error(message)
	GPUContext.shutdown_shared_device()
	get_tree().quit(1)
