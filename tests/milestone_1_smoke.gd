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
	var erosion_visible := float(first["max_erosion_delta_m"]) > 0.0001
	var erosion_preserves_land := int(first["eroded_land_below_sea"]) == 0
	var land_preserved := int(first["modified_land_pixels_by_subsidence"]) == 0
	var cloud_contract := (
		int(first["cloud_alpha_violations"]) == 0
		and int(first["cloud_max_density"]) > int(first["cloud_min_density"])
	)
	var seam_merge_safe := _validate_seam_merge_contract()
	var gas_deterministic: bool = first_gas["final_hash"] == second_gas["final_hash"]
	var gas_export_contract: bool = (
		first_gas["exported_keys"] == ["final_map"]
		and first_gas["phase_names"].has("gas_giant")
		and first_gas["phase_names"].has("total_simulation")
		and first_gas["phase_names"].size() == 2
	)

	print("[Milestone1Smoke] crust_hash=", first["crust_hash"])
	print("[Milestone1Smoke] eroded_geo_hash=", first["eroded_geo_hash"])
	print("[Milestone1Smoke] max_erosion_delta_m=", first["max_erosion_delta_m"])
	print("[Milestone1Smoke] eroded_land_below_sea=", first["eroded_land_below_sea"])
	print("[Milestone1Smoke] modified_land_pixels_by_subsidence=", first["modified_land_pixels_by_subsidence"])
	print("[Milestone1Smoke] cloud_density_range=", first["cloud_min_density"], "..", first["cloud_max_density"])
	print("[Milestone1Smoke] cloud_alpha_violations=", first["cloud_alpha_violations"])
	print("[Milestone1Smoke] seam_merge_safe=", seam_merge_safe)
	print("[Milestone1Smoke] deterministic=", deterministic)
	print("[Milestone1Smoke] gas_final_hash=", first_gas["final_hash"])
	print("[Milestone1Smoke] gas_exported_keys=", first_gas["exported_keys"])
	print("[Milestone1Smoke] gas_near_black_fraction=", first_gas["near_black_fraction"])
	print("[Milestone1Smoke] gas_near_white_fraction=", first_gas["near_white_fraction"])
	print("[Milestone1Smoke] gas_deterministic=", gas_deterministic)
	print("[Milestone1Smoke] gas_atmospheric_only=", gas_export_contract)

	if not deterministic:
		push_error("Milestone 1 output is not deterministic for the fixed seed")
	if not erosion_visible:
		push_error("Hydraulic erosion did not produce a measurable height change")
	if not erosion_preserves_land:
		push_error("Hydraulic erosion converted continental cells into ocean")
	if not land_preserved:
		push_error("Oceanic subsidence modified cells that were land before crust-age finalization")
	if not cloud_contract:
		push_error("Cloud export is uniform or does not use the opaque density-mask contract")
	if not seam_merge_safe:
		push_error("Distinct administrative regions were merged across the horizontal seam")
	if not gas_deterministic:
		push_error("Gas-giant output is not deterministic for the fixed seed")
	if not gas_export_contract:
		push_error("Gas-giant generation/export produced terrestrial phases or outputs")

	var passed: bool = (
		deterministic
		and erosion_visible
		and erosion_preserves_land
		and land_preserved
		and cloud_contract
		and seam_merge_safe
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

	var cloud_min_density := 255
	var cloud_max_density := 0
	var cloud_alpha_violations := 0
	for offset in range(0, cloud_data.size(), 4):
		cloud_min_density = mini(cloud_min_density, int(cloud_data[offset]))
		cloud_max_density = maxi(cloud_max_density, int(cloud_data[offset]))
		if int(cloud_data[offset + 3]) != 255:
			cloud_alpha_violations += 1

	var result := {
		"crust_hash": hash(crust_data),
		"eroded_geo_hash": hash(eroded_geo),
		"modified_land_pixels_by_subsidence": modified_land_pixels,
		"max_erosion_delta_m": max_erosion_delta,
		"eroded_land_below_sea": eroded_land_below_sea,
		"cloud_hash": hash(cloud_data),
		"cloud_min_density": cloud_min_density,
		"cloud_max_density": cloud_max_density,
		"cloud_alpha_violations": cloud_alpha_violations,
	}
	orchestrator.cleanup()
	return result

func _validate_seam_merge_contract() -> bool:
	var data := PackedByteArray()
	data.resize(8)
	data.encode_u32(0, 11)
	data.encode_u32(4, 22)
	return HierarchyBuilder.compute_merge_map(data, 2, 1).is_empty()

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
