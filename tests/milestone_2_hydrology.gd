extends Node

## Milestone 2 regression: the same physical inputs must produce the same
## drainage graph regardless of the obsolete river_iterations parameter.

const TEST_RESOLUTION := Vector2i(128, 64)
const TEST_SEED := 2577655122
const NEIGHBORS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0),                         Vector2i(1, 0),
	Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1),
]

var test_resolution := TEST_RESOLUTION
var full_scale_mode := false

func _ready() -> void:
	if OS.get_environment("PLANETGEN_M2_FULL") == "1":
		test_resolution = Vector2i(942, 471)
		full_scale_mode = true
	call_deferred("_run")

func _run() -> void:
	var short_iteration_case := _generate_snapshot(1)
	if short_iteration_case.is_empty():
		_quit(1)
		return

	var long_iteration_case := short_iteration_case
	if not full_scale_mode:
		long_iteration_case = _generate_snapshot(9999)
		if long_iteration_case.is_empty():
			_quit(1)
			return

	var stable: bool = (
		short_iteration_case["flow_hash"] == long_iteration_case["flow_hash"]
		and short_iteration_case["flux_hash"] == long_iteration_case["flux_hash"]
		and short_iteration_case["water_hash"] == long_iteration_case["water_hash"]
		and short_iteration_case["river_type_hash"] == long_iteration_case["river_type_hash"]
	)
	var stats: Dictionary = short_iteration_case["stats"]
	var conserved := float(stats.get("relative_mass_error", 1.0)) <= 0.0001
	var acyclic := int(stats.get("unresolved_land_cells", -1)) == 0
	var drains := int(stats.get("nonpolar_land_sinks", -1)) == 0
	var hierarchical := (
		int(short_iteration_case["downstream_flux_violations"]) == 0
		and int(short_iteration_case["downstream_type_violations"]) == 0
	)

	print("[Milestone2Hydrology] flow_hash=", short_iteration_case["flow_hash"])
	print("[Milestone2Hydrology] flux_hash=", short_iteration_case["flux_hash"])
	print("[Milestone2Hydrology] water_hash=", short_iteration_case["water_hash"])
	print("[Milestone2Hydrology] river_type_hash=", short_iteration_case["river_type_hash"])
	print("[Milestone2Hydrology] resolution=", test_resolution)
	print("[Milestone2Hydrology] stable_without_iterations=", stable)
	print("[Milestone2Hydrology] relative_mass_error=", stats.get("relative_mass_error"))
	print("[Milestone2Hydrology] unresolved_land_cells=", stats.get("unresolved_land_cells"))
	print("[Milestone2Hydrology] nonpolar_land_sinks=", stats.get("nonpolar_land_sinks"))
	print("[Milestone2Hydrology] seam_flow_links=", stats.get("seam_flow_links"))
	print("[Milestone2Hydrology] lake_components_retained=", stats.get("lake_components_retained"))
	print("[Milestone2Hydrology] lake_cells_removed=", stats.get("lake_cells_removed"))
	print("[Milestone2Hydrology] downstream_flux_violations=", short_iteration_case["downstream_flux_violations"])
	print("[Milestone2Hydrology] downstream_type_violations=", short_iteration_case["downstream_type_violations"])

	if not stable:
		push_error("Hydrology still depends on river_iterations")
	if not conserved:
		push_error("Hydrology does not conserve precipitation flux")
	if not acyclic:
		push_error("Hydrology contains a drainage cycle")
	if not drains:
		push_error("Hydrology contains invalid non-polar land sinks")
	if not hierarchical:
		push_error("Accumulated river flux decreases along a downstream land edge")

	_quit(0 if stable and conserved and acyclic and drains and hierarchical else 1)

func _generate_snapshot(obsolete_river_iterations: int) -> Dictionary:
	var params := {
		"seed": TEST_SEED,
		"resolution": test_resolution,
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": 15.0,
		"global_humidity": 0.65,
		"sea_level": 0.0,
		"ocean_ratio": 55.0,
		"terrain_scale": 150.0,
		"erosion_iterations": 12,
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
		"freshwater_min_size": 32,
		"saltwater_min_size": 1000,
		"river_precip_scale": 1.0,
		"river_iterations": obsolete_river_iterations,
	}

	var gpu := GPUContext.new(test_resolution)
	if not gpu or not gpu.rd:
		push_error("Milestone 2 test could not create a RenderingDevice")
		return {}

	var orchestrator := GPUOrchestrator.new(gpu, test_resolution, params)
	if not orchestrator or not orchestrator.rd:
		push_error("Milestone 2 test could not initialize GPUOrchestrator")
		gpu.cleanup()
		return {}

	orchestrator.run_base_elevation_phase(params, test_resolution.x, test_resolution.y)
	orchestrator.run_crust_age_phase(params, test_resolution.x, test_resolution.y)
	orchestrator.run_pre_erosion_climate_phase(params, test_resolution.x, test_resolution.y)
	orchestrator.run_erosion_phase(params, test_resolution.x, test_resolution.y)
	orchestrator.run_atmosphere_phase(params, test_resolution.x, test_resolution.y)
	orchestrator.run_water_phase(params, test_resolution.x, test_resolution.y)

	var flow_data := gpu.readback_texture_raw("flow_direction")
	var flux_data := gpu.readback_texture_raw("river_flux")
	var water_data := gpu.readback_texture_raw("water_mask")
	var river_type_data := gpu.readback_texture_raw("ocean_reachable")
	var result := {
		"flow_hash": hash(flow_data),
		"flux_hash": hash(flux_data),
		"water_hash": hash(water_data),
		"river_type_hash": hash(river_type_data),
		"stats": orchestrator.last_hydrology_stats.duplicate(),
		"downstream_flux_violations": _count_downstream_flux_violations(
			flow_data,
			flux_data,
			water_data,
		),
		"downstream_type_violations": _count_downstream_type_violations(
			flow_data,
			water_data,
			river_type_data,
		),
	}
	orchestrator.cleanup()
	return result

func _count_downstream_flux_violations(
	flow_data: PackedByteArray,
	flux_data: PackedByteArray,
	water_data: PackedByteArray,
) -> int:
	var violations := 0
	for index in range(test_resolution.x * test_resolution.y):
		if water_data[index] != 0:
			continue
		var direction := int(flow_data[index])
		if direction < 0 or direction >= NEIGHBORS.size():
			continue

		var x := index % test_resolution.x
		var y := index / test_resolution.x
		var offset := NEIGHBORS[direction]
		var target_x := posmod(x + offset.x, test_resolution.x)
		var target_y := clampi(y + offset.y, 0, test_resolution.y - 1)
		var target := target_y * test_resolution.x + target_x
		if water_data[target] != 0 or target_y < 2 or target_y >= test_resolution.y - 2:
			continue

		var current_flux := flux_data.decode_float(index * 4)
		var downstream_flux := flux_data.decode_float(target * 4)
		if downstream_flux + 0.0001 < current_flux:
			violations += 1

	return violations

func _count_downstream_type_violations(
	flow_data: PackedByteArray,
	water_data: PackedByteArray,
	river_type_data: PackedByteArray,
) -> int:
	var violations := 0
	for index in range(test_resolution.x * test_resolution.y):
		if water_data[index] != 0:
			continue
		var current_type := int(river_type_data[index])
		var direction := int(flow_data[index])
		if current_type == 255 or direction < 0 or direction >= NEIGHBORS.size():
			continue

		var x := index % test_resolution.x
		var y := index / test_resolution.x
		var offset := NEIGHBORS[direction]
		var target_x := posmod(x + offset.x, test_resolution.x)
		var target_y := clampi(y + offset.y, 0, test_resolution.y - 1)
		var target := target_y * test_resolution.x + target_x
		if water_data[target] != 0 or target_y < 2 or target_y >= test_resolution.y - 2:
			continue

		var downstream_type := int(river_type_data[target])
		if downstream_type == 255 or downstream_type < current_type:
			violations += 1

	return violations

func _quit(exit_code: int) -> void:
	GPUContext.shutdown_shared_device()
	get_tree().quit(exit_code)
