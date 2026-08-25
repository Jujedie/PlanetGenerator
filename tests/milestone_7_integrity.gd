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
