extends Node

## Small deterministic GPU smoke test for Milestone 1. This intentionally runs
## only the terrain, crust-age, preliminary climate, and erosion phases so it
## remains fast enough for development validation.

const TEST_RESOLUTION := Vector2i(128, 64)
const TEST_SEED := 2577655122
const GAS_TEST_SEED := 6700417

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var first := _generate_snapshot()
	if first.is_empty():
		_quit(1)
		return

	var second := _generate_snapshot()
	if second.is_empty():
		_quit(1)
		return

	var first_gas := _generate_gas_snapshot()
	if first_gas.is_empty():
		_quit(1)
		return

	var second_gas := _generate_gas_snapshot()
	if second_gas.is_empty():
		_quit(1)
		return

	var deterministic: bool = (
		first["crust_hash"] == second["crust_hash"]
		and first["eroded_geo_hash"] == second["eroded_geo_hash"]
		and first["cloud_hash"] == second["cloud_hash"]
	)
	var canyon_generation_disabled := float(first["max_erosion_delta_m"]) <= 0.0001
	var erosion_preserves_land := int(first["eroded_land_below_sea"]) == 0
	var tectonic_divider_safe := (
		int(first["tectonic_boundary_samples"]) > 0
		and float(first["tectonic_boundary_wall_fraction"]) < 0.20
		and float(first["tectonic_boundary_canyon_fraction"]) < 0.02
		and float(first["max_land_neighbor_step_m"]) < 2000.0
		and int(first["extreme_altitude_steps"]) == 0
	)
	var land_preserved := int(first["modified_land_pixels_by_subsidence"]) == 0
	var cloud_contract := (
		int(first["cloud_alpha_violations"]) == 0
		and int(first["cloud_clear_pixels"]) > 0
		and int(first["cloud_visible_pixels"]) > 0
		and bool(first["cloud_png_contract"])
	)
	var seam_merge_safe := _validate_seam_merge_contract()
	var physical_scale_safe := _validate_physical_scale_contract()
	var topology_export_safe := _validate_topology_export_contract()
	var gas_deterministic: bool = first_gas["final_hash"] == second_gas["final_hash"]
	# Since M7/M8, every export may also contain integrity/catalog/manifest/project
	# metadata.  The atmospheric-only contract is about generated map layers: a
	# gas giant must export final_map and no terrestrial map outputs.
	var gas_allowed_export_keys: Array[String] = [
		"final_map",
		"integrity_report",
		"catalog",
		"manifest",
		"project",
	]
	var gas_exported_keys: Array = first_gas["exported_keys"] as Array
	var gas_has_only_allowed_outputs := true
	for exported_key_value in gas_exported_keys:
		var exported_key: String = str(exported_key_value)
		if not gas_allowed_export_keys.has(exported_key):
			gas_has_only_allowed_outputs = false
			break
	var gas_export_contract: bool = (
		gas_exported_keys.has("final_map")
		and gas_has_only_allowed_outputs
		and first_gas["phase_names"].has("gas_giant")
		and first_gas["phase_names"].has("total_simulation")
		and first_gas["phase_names"].size() == 2
	)

	print("[Milestone1Smoke] crust_hash=", first["crust_hash"])
	print("[Milestone1Smoke] eroded_geo_hash=", first["eroded_geo_hash"])
	print("[Milestone1Smoke] max_erosion_delta_m=", first["max_erosion_delta_m"])
	print("[Milestone1Smoke] max_land_neighbor_step_m=", first["max_land_neighbor_step_m"])
	print("[Milestone1Smoke] extreme_altitude_steps=", first["extreme_altitude_steps"])
	print("[Milestone1Smoke] tectonic_boundary_wall_fraction=", first["tectonic_boundary_wall_fraction"])
	print("[Milestone1Smoke] tectonic_boundary_canyon_fraction=", first["tectonic_boundary_canyon_fraction"])
	print("[Milestone1Smoke] eroded_land_below_sea=", first["eroded_land_below_sea"])
	print("[Milestone1Smoke] modified_land_pixels_by_subsidence=", first["modified_land_pixels_by_subsidence"])
	print("[Milestone1Smoke] cloud_alpha_range=", first["cloud_min_alpha"], "..", first["cloud_max_alpha"])
	print("[Milestone1Smoke] cloud_clear_visible=", first["cloud_clear_pixels"], "/", first["cloud_visible_pixels"])
	print("[Milestone1Smoke] cloud_alpha_violations=", first["cloud_alpha_violations"])
	print("[Milestone1Smoke] cloud_png_rgba=", first["cloud_png_contract"])
	print("[Milestone1Smoke] seam_merge_safe=", seam_merge_safe)
	print("[Milestone1Smoke] physical_scale_safe=", physical_scale_safe)
	print("[Milestone1Smoke] topology_rgba_export=", topology_export_safe)
	print("[Milestone1Smoke] deterministic=", deterministic)
	print("[Milestone1Smoke] gas_final_hash=", first_gas["final_hash"])
	print("[Milestone1Smoke] gas_exported_keys=", first_gas["exported_keys"])
	print("[Milestone1Smoke] gas_near_black_fraction=", first_gas["near_black_fraction"])
	print("[Milestone1Smoke] gas_near_white_fraction=", first_gas["near_white_fraction"])
	print("[Milestone1Smoke] gas_deterministic=", gas_deterministic)
	print("[Milestone1Smoke] gas_atmospheric_only=", gas_export_contract)

	if not deterministic:
		push_error("Milestone 1 output is not deterministic for the fixed seed")
	if not canyon_generation_disabled:
		push_error("Canyon generation still modifies terrain height")
	if not erosion_preserves_land:
		push_error("Hydraulic erosion converted continental cells into ocean")
	if not tectonic_divider_safe:
		push_error("Tectonic boundary is still visible as a continuous artificial elevation divider")
	if not land_preserved:
		push_error("Oceanic subsidence modified cells that were land before crust-age finalization")
	if not cloud_contract:
		push_error("Cloud export is not a non-uniform RGBA texture with transparent clear sky")
	if not seam_merge_safe:
		push_error("Distinct administrative regions were merged across the horizontal seam")
	if not physical_scale_safe:
		push_error("Administrative hierarchy does not scale from physical planet surface")
	if not topology_export_safe:
		push_error("Topology export is not a transparent RGBA contour overlay")
	if not gas_deterministic:
		push_error("Gas-giant output is not deterministic for the fixed seed")
	if not gas_export_contract:
		push_error("Gas-giant generation/export produced terrestrial phases or outputs")

	var passed: bool = (
		deterministic
		and canyon_generation_disabled
		and erosion_preserves_land
		and tectonic_divider_safe
		and land_preserved
		and cloud_contract
		and seam_merge_safe
		and physical_scale_safe
		and topology_export_safe
		and gas_deterministic
		and gas_export_contract
	)
	_quit(0 if passed else 1)

func _quit(exit_code: int) -> void:
	# The application keeps this device alive between generations, but this
	# standalone test owns the process and must release it before exiting.
	GPUContext.shutdown_shared_device()
	get_tree().quit(exit_code)

func _generate_snapshot() -> Dictionary:
	var params := {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": 15.0,
		"global_humidity": 0.65,
		"sea_level": 0.0,
		"ocean_ratio": 55.0,
		"terrain_scale": 150.0,
		"erosion_iterations": 24,
		"rain_rate": 0.02,
		"evap_rate": 0.01,
		"flow_rate": 0.35,
		"erosion_rate": 0.15,
		"deposition_rate": 0.12,
		"capacity_multiplier": 2.5,
		"flux_iterations": 2,
		"base_flux": 1.0,
		"propagation_rate": 0.8,
		"spreading_rate": 50.0,
		"max_crust_age": 200.0,
		"subsidence_coeff": 2800.0,
	}

	var gpu := GPUContext.new(TEST_RESOLUTION)
	if not gpu or not gpu.rd:
		push_error("Milestone 1 smoke test could not create a RenderingDevice")
		return {}

	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if not orchestrator or not orchestrator.rd:
		push_error("Milestone 1 smoke test could not initialize GPUOrchestrator")
		if gpu:
			gpu.cleanup()
		return {}

	orchestrator.run_base_elevation_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var base_geo := gpu.readback_texture_raw("geo")
	var plate_data := gpu.readback_texture_raw("plates")

	orchestrator.run_crust_age_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var crust_geo := gpu.readback_texture_raw("geo")
	var crust_data := gpu.readback_texture_raw("crust_age")

	orchestrator.run_pre_erosion_climate_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	orchestrator.run_erosion_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var eroded_geo := gpu.readback_texture_raw("geo")
	orchestrator.run_atmosphere_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var cloud_data := gpu.readback_texture_raw("clouds")

	var modified_land_pixels := 0
	var max_erosion_delta := 0.0
	var eroded_land_below_sea := 0
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	for pixel_index in range(pixel_count):
		var offset := pixel_index * 16
		var base_height := base_geo.decode_float(offset)
		var crust_height := crust_geo.decode_float(offset)
		var eroded_height := eroded_geo.decode_float(offset)

		if base_height >= float(params["sea_level"]) and abs(crust_height - base_height) > 0.0001:
			modified_land_pixels += 1
		if crust_height >= float(params["sea_level"]) and eroded_height < float(params["sea_level"]):
			eroded_land_below_sea += 1
		max_erosion_delta = max(max_erosion_delta, abs(eroded_height - crust_height))

	var max_land_neighbor_step := 0.0
	var extreme_altitude_steps := 0
	for y in range(TEST_RESOLUTION.y):
		for x in range(TEST_RESOLUTION.x):
			var index := y * TEST_RESOLUTION.x + x
			var height := eroded_geo.decode_float(index * 16)
			if height < float(params["sea_level"]):
				continue
			for neighbor in [
				Vector2i((x + 1) % TEST_RESOLUTION.x, y),
				Vector2i(x, mini(y + 1, TEST_RESOLUTION.y - 1)),
			]:
				var neighbor_height := eroded_geo.decode_float(
					(neighbor.y * TEST_RESOLUTION.x + neighbor.x) * 16
				)
				if neighbor_height < float(params["sea_level"]):
					continue
				var step := absf(height - neighbor_height)
				max_land_neighbor_step = maxf(max_land_neighbor_step, step)
				if step > 3000.0:
					extreme_altitude_steps += 1

	var tectonic_boundary_samples := 0
	var tectonic_boundary_wall_pixels := 0
	var tectonic_boundary_land_samples := 0
	var tectonic_boundary_canyon_pixels := 0
	for y in range(1, TEST_RESOLUTION.y - 1):
		for x in range(TEST_RESOLUTION.x):
			var index := y * TEST_RESOLUTION.x + x
			var boundary_signal := absf(plate_data.decode_float(index * 16 + 12))
			if boundary_signal < 0.45:
				continue
			tectonic_boundary_samples += 1
			var center_height := base_geo.decode_float(index * 16)
			var minimum_height := INF
			var maximum_height := -INF
			for neighbor in [
				Vector2i(posmod(x - 1, TEST_RESOLUTION.x), y),
				Vector2i((x + 1) % TEST_RESOLUTION.x, y),
				Vector2i(x, y - 1), Vector2i(x, y + 1),
			]:
				var neighbor_height := base_geo.decode_float(
					(neighbor.y * TEST_RESOLUTION.x + neighbor.x) * 16
				)
				minimum_height = minf(minimum_height, neighbor_height)
				maximum_height = maxf(maximum_height, neighbor_height)
			if maximum_height - minimum_height > 2000.0:
				tectonic_boundary_wall_pixels += 1
			if center_height >= float(params["sea_level"]):
				tectonic_boundary_land_samples += 1
				if center_height + 800.0 < minimum_height:
					tectonic_boundary_canyon_pixels += 1
	var tectonic_boundary_wall_fraction := (
		float(tectonic_boundary_wall_pixels) / float(maxi(tectonic_boundary_samples, 1))
	)
	var tectonic_boundary_canyon_fraction := (
		float(tectonic_boundary_canyon_pixels) /
		float(maxi(tectonic_boundary_land_samples, 1))
	)

	var cloud_min_alpha := 255
	var cloud_max_alpha := 0
	var cloud_alpha_violations := 0
	var cloud_clear_pixels := 0
	var cloud_visible_pixels := 0
	for offset in range(0, cloud_data.size(), 4):
		var alpha := int(cloud_data[offset + 3])
		cloud_min_alpha = mini(cloud_min_alpha, alpha)
		cloud_max_alpha = maxi(cloud_max_alpha, alpha)
		if alpha == 0:
			cloud_clear_pixels += 1
			if cloud_data[offset] != 0 or cloud_data[offset + 1] != 0 or cloud_data[offset + 2] != 0:
				cloud_alpha_violations += 1
		else:
			cloud_visible_pixels += 1

	var cloud_image := Image.create_from_data(
		TEST_RESOLUTION.x, TEST_RESOLUTION.y, false, Image.FORMAT_RGBA8, cloud_data
	)
	var cloud_path := "user://milestone_1_cloud_contract.png"
	var cloud_png_contract := cloud_image != null and cloud_image.save_png(cloud_path) == OK
	if cloud_png_contract:
		var loaded_cloud := Image.new()
		cloud_png_contract = (
			loaded_cloud.load(cloud_path) == OK
			and loaded_cloud.get_format() == Image.FORMAT_RGBA8
			and loaded_cloud.get_width() == TEST_RESOLUTION.x
			and loaded_cloud.get_height() == TEST_RESOLUTION.y
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cloud_path))
	if cloud_max_alpha <= cloud_min_alpha:
		cloud_alpha_violations += 1

	var result := {
		"crust_hash": hash(crust_data),
		"eroded_geo_hash": hash(eroded_geo),
		"modified_land_pixels_by_subsidence": modified_land_pixels,
		"max_erosion_delta_m": max_erosion_delta,
		"eroded_land_below_sea": eroded_land_below_sea,
		"max_land_neighbor_step_m": max_land_neighbor_step,
		"extreme_altitude_steps": extreme_altitude_steps,
		"tectonic_boundary_samples": tectonic_boundary_samples,
		"tectonic_boundary_wall_fraction": tectonic_boundary_wall_fraction,
		"tectonic_boundary_canyon_fraction": tectonic_boundary_canyon_fraction,
		"cloud_hash": hash(cloud_data),
		"cloud_min_alpha": cloud_min_alpha,
		"cloud_max_alpha": cloud_max_alpha,
		"cloud_alpha_violations": cloud_alpha_violations,
		"cloud_clear_pixels": cloud_clear_pixels,
		"cloud_visible_pixels": cloud_visible_pixels,
		"cloud_png_contract": cloud_png_contract,
	}
	orchestrator.cleanup()
	return result

func _validate_seam_merge_contract() -> bool:
	var data := PackedByteArray()
	data.resize(8)
	data.encode_u32(0, 11)
	data.encode_u32(4, 22)
	return HierarchyBuilder.compute_merge_map(data, 2, 1).is_empty()

func _validate_physical_scale_contract() -> bool:
	var observed_land := HierarchyBuilder.compute_land_hierarchy_targets(2909, {
		"planet_radius": 150.0,
		"ocean_ratio": 55.0,
	})
	var reference_land := HierarchyBuilder.compute_land_hierarchy_targets(12367, {
		"planet_radius": 150.0,
		"ocean_ratio": 55.0,
	})
	var small := HierarchyBuilder.compute_physical_targets({
		"planet_radius": 150.0,
		"ocean_ratio": 55.0,
		"nb_cases_regions": 50,
	}, false)
	var large := HierarchyBuilder.compute_physical_targets({
		"planet_radius": 1500.0,
		"ocean_ratio": 55.0,
		"nb_cases_regions": 50,
	}, false)
	var small_country_area := float(small["surface_km2"]) / float(small["middle"])
	var large_country_area := float(large["surface_km2"]) / float(large["middle"])
	return (
		# Deux résolutions produisant des nombres différents de départements
		# locaux doivent conserver exactement la même échelle supérieure.
		int(observed_land["regions"]) == int(reference_land["regions"])
		and int(observed_land["middle"]) == int(reference_land["middle"])
		and int(observed_land["top"]) == int(reference_land["top"])
		and int(observed_land["regions"]) == int(small["regions"])
		and int(observed_land["middle"]) == int(small["middle"])
		and int(observed_land["top"]) == int(small["top"])
		and int(small["departments"]) > int(small["regions"])
		and int(small["regions"]) > int(small["middle"])
		and int(small["middle"]) > int(small["top"])
		and int(large["departments"]) > int(small["departments"])
		and int(large["regions"]) > int(small["regions"])
		and int(large["departments"]) > int(large["regions"])
		and int(large["regions"]) > int(large["middle"])
		and int(large["middle"]) > int(large["top"])
		and int(large["top"]) > int(small["top"])
		and large_country_area > small_country_area
	)


func _validate_topology_export_contract() -> bool:
	const WIDTH := 96
	const HEIGHT := 48
	var geo := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBAF)
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var nx := (float(x) - float(WIDTH) * 0.5) / (float(WIDTH) * 0.32)
			var ny := (float(y) - float(HEIGHT) * 0.5) / (float(HEIGHT) * 0.38)
			var radial_height := 6200.0 * (1.0 - sqrt(nx * nx + ny * ny))
			var relief := 420.0 * sin(float(x) * 0.31) * cos(float(y) * 0.27)
			var elevation := radial_height + relief
			geo.set_pixel(x, y, Color(elevation, 0.5, 0.0, 80.0 if elevation < 0.0 else 0.0))

	var export_dir := ProjectSettings.globalize_path("user://milestone_1_topology")
	DirAccess.make_dir_recursive_absolute(export_dir)
	var exporter := PlanetExporter.new()
	exporter.params = {
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"sea_level": 0.0,
		"topology_smoothing_km": 8.0,
		"topology_contour_interval_m": 250.0,
		"topology_major_interval_m": 1000.0,
	}
	var exported := exporter._export_topographie_maps(geo, export_dir, WIDTH, HEIGHT)
	var topology_path := str(exported.get("topology_map", ""))
	var topology := Image.new()
	var loaded := not topology_path.is_empty() and topology.load(topology_path) == OK
	var transparent_pixels := 0
	var visible_pixels := 0
	var partial_alpha_pixels := 0
	if loaded:
		for y in range(topology.get_height()):
			for x in range(topology.get_width()):
				var alpha := topology.get_pixel(x, y).a
				if alpha <= 0.001:
					transparent_pixels += 1
				else:
					visible_pixels += 1
					if alpha < 0.999:
						partial_alpha_pixels += 1

	var ocean := Enum.getElevationColor(-3000, false)
	var lowland := Enum.getElevationColor(100, false)
	var upland := Enum.getElevationColor(2500, false)
	var peak := Enum.getElevationColor(7000, false)
	var palette_contract := (
		ocean.b > ocean.r
		and lowland.g > lowland.r and lowland.g > lowland.b
		# La palette topographique restaurée reste gris-vert jusque sur les
		# hauts plateaux ; le test ne doit plus imposer l'ancienne dominante ocre.
		and upland.g > upland.r
		and minf(peak.r, minf(peak.g, peak.b)) > 0.80
	)
	var result := (
		loaded
		and topology.get_format() == Image.FORMAT_RGBA8
		and topology.get_size() == Vector2i(WIDTH, HEIGHT)
		and transparent_pixels > 0
		and visible_pixels > 0
		and partial_alpha_pixels > 0
		and palette_contract
	)
	for filepath in exported.values():
		DirAccess.remove_absolute(str(filepath))
	DirAccess.remove_absolute(export_dir)
	return result

func _generate_gas_snapshot() -> Dictionary:
	var params := {
		"seed": GAS_TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_GAZEUZE,
		"planet_radius": 69911.0,
		"avg_temperature": -110.0,
		"gas_giant_num_bands": 12,
		"gas_giant_advection_iterations": 12,
		"gas_giant_reference_width": 1024.0,
		"gas_giant_jet_strength": 4.0,
		"gas_giant_eddy_strength": 2.5,
		"gas_giant_advection_dt": 1.4,
		"gas_giant_target_sharpen": 1.18,
	}

	var gpu := GPUContext.new(TEST_RESOLUTION)
	if not gpu or not gpu.rd:
		push_error("Gas-giant smoke test could not create a RenderingDevice")
		return {}

	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if not orchestrator or not orchestrator.rd:
		push_error("Gas-giant smoke test could not initialize GPUOrchestrator")
		gpu.cleanup()
		return {}

	orchestrator.run_simulation()
	var final_data := gpu.readback_texture_raw("final_map")
	var near_black_pixels := 0
	var near_white_pixels := 0
	for offset in range(0, final_data.size(), 4):
		var red := int(final_data[offset])
		var green := int(final_data[offset + 1])
		var blue := int(final_data[offset + 2])
		if max(red, max(green, blue)) <= 4:
			near_black_pixels += 1
		if min(red, min(green, blue)) >= 251:
			near_white_pixels += 1

	var export_dir := "user://milestone_1_smoke_gas"
	var exporter := PlanetExporter.new()
	var exported_files := exporter.export_maps(gpu, export_dir, params)
	var exported_keys := exported_files.keys()
	var phase_names := orchestrator.last_phase_timings_ms.keys()
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var result := {
		"final_hash": hash(final_data),
		"exported_keys": exported_keys,
		"phase_names": phase_names,
		"near_black_fraction": float(near_black_pixels) / float(pixel_count),
		"near_white_fraction": float(near_white_pixels) / float(pixel_count),
	}

	for exported_path in exported_files.values():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(str(exported_path)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(export_dir))
	orchestrator.cleanup()
	return result
