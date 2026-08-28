extends Node


const EXPECTED_WATER_COLORS := {
	Enum.TYPE_TERRAN: [[37, 82, 138], [69, 132, 210]],
	Enum.TYPE_TOXIC: [[65, 76, 45], [99, 108, 58]],
	Enum.TYPE_VOLCANIC: [[96, 42, 28], [184, 73, 27]],
	Enum.TYPE_DEAD: [[49, 61, 56], [76, 79, 66]],
}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	var solver := HydrologySolver.new()
	for planet_type in EXPECTED_WATER_COLORS:
		var expected: Array = EXPECTED_WATER_COLORS[planet_type]
		valid = valid and solver._saltwater_color(planet_type) == expected[0]
		valid = valid and solver._freshwater_color(planet_type) == expected[1]
		var export_colors: Dictionary = PlanetExporter.WATER_COLORS[planet_type]
		valid = valid and _color8_matches(export_colors["saltwater"], expected[0])
		valid = valid and _color8_matches(export_colors["freshwater"], expected[1])
		valid = valid and not Enum.get_biomes_for_gpu(planet_type).is_empty()
		valid = valid and not Enum.get_river_biomes_for_gpu(planet_type).is_empty()

	valid = valid and Enum.get_river_biomes_for_gpu(Enum.TYPE_NO_ATMOS).is_empty()
	valid = valid and Enum.get_river_biomes_for_gpu(Enum.TYPE_STERILE).is_empty()
	valid = valid and not _is_river_biome("Lac d'Acide")
	valid = valid and not _is_river_biome("Lac Irradié")
	valid = valid and not _is_river_biome("Marécage Luminescent")
	valid = valid and _biome_temperature_contains("Désert Extrême de Soufre", 460)
	valid = valid and _biome_temperature_contains("Mer de Lave en Fusion", 260)
	valid = valid and _biome_temperature_contains("Rivière de Lave", 260)
	valid = valid and solver._temperature_allows_surface_fluid(460.0, Enum.TYPE_TOXIC)
	valid = valid and solver._temperature_allows_surface_fluid(260.0, Enum.TYPE_VOLCANIC)
	valid = valid and not solver._temperature_allows_surface_fluid(260.0, Enum.TYPE_TERRAN)

	var final_shader := FileAccess.get_file_as_string("res://shader/compute/final_map.glsl")
	var ice_shader := FileAccess.get_file_as_string(
		"res://shader/compute/atmosphere_climat/ice_caps.glsl"
	)
	var water_shader := FileAccess.get_file_as_string(
		"res://shader/compute/water/hydrology_water_color.glsl"
	)
	valid = valid and final_shader.contains("if (atmosphere_type == 1u)")
	valid = valid and final_shader.contains("else if (atmosphere_type == 5u)")
	valid = valid and final_shader.contains("landCryosphereCoverage")
	valid = valid and final_shader.contains("localTerrainDetail")
	valid = valid and final_shader.contains("atmosphere_type <= 4u")
	valid = valid and final_shader.contains("temperature,\n    float humidity,\n    float relative_height")
	valid = valid and final_shader.contains("if (has_surface_ice && is_water)")
	valid = valid and ice_shader.contains("if (water.a <= 0.0)")
	valid = valid and ice_shader.contains("smoothstep(-11.0, 0.5, temperature)")
	valid = valid and ice_shader.contains("mix(0.86, 0.28, probability)")
	valid = valid and ice_shader.contains("probability / 0.9")
	valid = valid and not ice_shader.contains("sqrt(probability)")
	valid = valid and not ice_shader.contains("condensateSupply")
	valid = valid and not ice_shader.contains("height_retention")
	valid = valid and water_shader.contains("vec3(96.0, 42.0, 28.0)")

	print("[WorldTypePaletteContract] result=", "PASS" if valid else "FAIL")
	if not valid:
		push_error("World-type color and cryosphere contract failed")
	get_tree().quit(0 if valid else 1)


func _is_river_biome(name: String) -> bool:
	for biome_value in Enum.BIOMES:
		var biome: Biome = biome_value
		if biome.get_nom() == name:
			return biome.isRiver()
	return true


func _biome_temperature_contains(name: String, temperature: int) -> bool:
	for biome_value in Enum.BIOMES:
		var biome: Biome = biome_value
		if biome.get_nom() != name:
			continue
		var interval := biome.get_interval_temp()
		return temperature >= interval[0] and temperature <= interval[1]
	return false


func _color8_matches(color: Color, channels: Array) -> bool:
	return (
		color.r8 == int(channels[0])
		and color.g8 == int(channels[1])
		and color.b8 == int(channels[2])
	)
