extends Node

func _ready() -> void:
	var width := 8
	var height := 4
	var pixels := width * height
	var water := PackedByteArray(); water.resize(pixels)
	var land := PackedByteArray(); land.resize(pixels * 4)
	var sea := PackedByteArray(); sea.resize(pixels * 4)
	var flow := PackedByteArray(); flow.resize(pixels); flow.fill(255)
	var flux := PackedByteArray(); flux.resize(pixels * 4)
	for y in range(height):
		for x in range(width):
			var i := y * width + x
			var is_water := y >= 2
			water[i] = 1 if is_water else 0
			land.encode_u32(i * 4, 0xFFFFFFFF if is_water else (10 if x < 4 else 11))
			sea.encode_u32(i * 4, (20 if x < 4 else 21) if is_water else 0xFFFFFFFF)
			flux.encode_float(i * 4, 0.0)
	var report := PlanetIntegrityChecker.validate_snapshot({
		"water_mask": water,
		"region_map": land,
		"ocean_region_map": sea,
		"flow_direction": flow,
		"river_flux": flux,
	}, width, height, {
		"planet_type": 0,
		"nb_cases_regions": 8,
		"nb_cases_ocean_regions": 8,
	})
	assert(report["result"] == "PASS", JSON.stringify(report, "  "))

	# Local size floors must match DepartmentNormalizer rather than a stricter
	# global-only interpretation.
	var local_width := 6
	var local_height := 2
	var local_pixels := local_width * local_height
	var local_water := PackedByteArray(); local_water.resize(local_pixels); local_water.fill(0)
	var local_land := PackedByteArray(); local_land.resize(local_pixels * 4)
	var local_sea := PackedByteArray(); local_sea.resize(local_pixels * 4)
	for i in range(local_pixels):
		local_sea.encode_u32(i * 4, 0xFFFFFFFF)
		local_land.encode_u32(i * 4, 30 if (i % local_width) < 3 else 31)
	var local_flow := PackedByteArray(); local_flow.resize(local_pixels); local_flow.fill(255)
	var local_flux := PackedByteArray(); local_flux.resize(local_pixels * 4)
	var local_report := PlanetIntegrityChecker.validate_snapshot({
		"water_mask": local_water,
		"region_map": local_land,
		"ocean_region_map": local_sea,
		"flow_direction": local_flow,
		"river_flux": local_flux,
	}, local_width, local_height, {
		"planet_type": 3,
		"nb_cases_regions": 20,
	})
	assert(local_report["result"] == "PASS", JSON.stringify(local_report, "  "))

	# Reuse land id 10 as a disconnected island: wrap-aware topology must catch it.
	land.encode_u32((1 * width + 5) * 4, 10)
	land.encode_u32((1 * width + 4) * 4, 12)
	land.encode_u32((1 * width + 6) * 4, 12)
	land.encode_u32((0 * width + 5) * 4, 12)
	var bad := PlanetIntegrityChecker.validate_snapshot({
		"water_mask": water,
		"region_map": land,
		"ocean_region_map": sea,
		"flow_direction": flow,
		"river_flux": flux,
	}, width, height, {"planet_type": 0, "nb_cases_regions": 8, "nb_cases_ocean_regions": 8})
	assert(bad["result"] == "FAIL")
	print("Milestone 7 integrity regression: PASS")
	get_tree().quit()
