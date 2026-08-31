extends Node

const PREVIEW_WIDTH_PER_BIOME := 18
const PREVIEW_HEIGHT := 128


func _ready() -> void:
	if "--desert-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "desert")
	elif "--arid-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "arid")
	elif "--cold-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "cold")
	elif "--world-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "world")
	else:
		call_deferred("_run")


func _run_world_preview(profile: String) -> void:
	var resolution := Vector2i(752, 376)
	var is_desert_case := profile == "desert"
	var params := {
		"seed": 616988363 if is_desert_case else 3001918132,
		"resolution": resolution,
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": 43.0 if is_desert_case else (-7.0 if profile == "cold" else (34.0 if profile == "arid" else 21.0)),
		"global_humidity": 0.4 if is_desert_case else (0.42 if profile == "cold" else (0.18 if profile == "arid" else 0.5)),
		"avg_precipitation": 0.4 if is_desert_case else (0.42 if profile == "cold" else (0.18 if profile == "arid" else 0.5)),
		"sea_level": 0.0,
		"ocean_ratio": 43.0 if is_desert_case else 55.0,
		"terrain_scale": 150.0,
		"erosion_iterations": 32,
		"rain_rate": 0.005,
		"evap_rate": 0.02,
		"flow_rate": 0.25,
		"erosion_rate": 0.05,
		"deposition_rate": 0.05,
		"capacity_multiplier": 1.0,
		"flux_iterations": 10,
		"base_flux": 100.0,
		"propagation_rate": 0.8,
		"spreading_rate": 50.0,
		"max_crust_age": 200.0,
		"subsidence_coeff": 2800.0,
		"lake_threshold": 20.0,
		"freshwater_max_size": 1000,
		"saltwater_min_size": 1001,
		"river_affluent_threshold": 7.77,
		"river_riviere_threshold": 31.09,
		"river_fleuve_threshold": 124.36,
		"river_precip_scale": 1.0,
		"ice_probability": 0.9,
		"nb_cases_regions": 50,
		"nb_cases_ocean_regions": 100,
		"region_iterations": resolution.x,
		"ocean_iterations": resolution.x,
		"global_richness": 1.0,
	}
	var gpu := GPUContext.new(resolution)
	if gpu == null or gpu.rd == null:
		push_error("World palette preview could not create a RenderingDevice")
		_quit(1)
		return
	var orchestrator := GPUOrchestrator.new(gpu, resolution, params)
	if orchestrator == null or orchestrator.rd == null:
		push_error("World palette preview could not create the orchestrator")
		gpu.cleanup()
		_quit(1)
		return
	if is_desert_case:
		_run_surface_preview_pipeline(orchestrator, params, resolution)
		_print_surface_preview_stats(gpu, resolution)
	else:
		orchestrator.run_simulation()
	var final_path := _save_texture(
		gpu.readback_texture_raw("final_map"),
		resolution,
		"final_map_palette_%s.png" % profile
	)
	var biome_path := _save_texture(
		gpu.readback_texture_raw("biome_colored"),
		resolution,
		"final_map_palette_%s_biomes.png" % profile
	)
	var ice_path := _save_texture(
		gpu.readback_texture_raw("ice_caps"),
		resolution,
		"final_map_palette_%s_ice.png" % profile
	)
	var valid := (
		not final_path.is_empty()
		and not biome_path.is_empty()
		and not ice_path.is_empty()
	)
	print("[FinalMapPalette] world=", final_path)
	print("[FinalMapPalette] world_biomes=", biome_path)
	print("[FinalMapPalette] world_ice=", ice_path)
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	_quit(0 if valid else 1)


func _run_surface_preview_pipeline(
	orchestrator: GPUOrchestrator,
	params: Dictionary,
	resolution: Vector2i
) -> void:
	var width := resolution.x
	var height := resolution.y
	orchestrator.run_base_elevation_phase(params, width, height)
	orchestrator.run_crust_age_phase(params, width, height)
	orchestrator.run_cratering_phase(params, width, height)
	orchestrator.run_pre_erosion_climate_phase(params, width, height)
	orchestrator.run_erosion_phase(params, width, height)
	orchestrator.run_atmosphere_phase(params, width, height)
	orchestrator.run_water_phase(params, width, height)
	orchestrator.run_ice_caps_phase(params, width, height)
	orchestrator.run_biome_phase(params, width, height)
	orchestrator.run_final_map_phase(params, width, height)


func _print_surface_preview_stats(gpu: GPUContext, resolution: Vector2i) -> void:
	var geo := gpu.readback_texture_raw("geo")
	var climate := gpu.readback_texture_raw("climate")
	var water_mask := gpu.readback_texture_raw("water_mask")
	var biome_ids := gpu.readback_texture_raw("biome_id")
	var biomes: Array = Enum.get_biomes_for_gpu(Enum.TYPE_TERRAN)
	var elevations: Array[float] = []
	var humidities: Array[float] = []
	var biome_counts: Dictionary = {}
	for pixel_index in range(resolution.x * resolution.y):
		if water_mask[pixel_index] != 0:
			continue
		elevations.append(geo.decode_float(pixel_index * 16))
		humidities.append(climate.decode_float(pixel_index * 16 + 4))
		var biome_id := int(biome_ids.decode_u32(pixel_index * 4))
		if biome_id >= 0 and biome_id < biomes.size():
			var biome_name: String = (biomes[biome_id] as Biome).get_nom()
			biome_counts[biome_name] = int(biome_counts.get(biome_name, 0)) + 1
	elevations.sort()
	humidities.sort()
	print("[FinalMapPalette] land_elevation_quantiles=", _quantiles(elevations))
	print("[FinalMapPalette] land_humidity_quantiles=", _quantiles(humidities))
	print("[FinalMapPalette] biome_counts=", biome_counts)


func _quantiles(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	var last := values.size() - 1
	return {
		"min": values[0],
		"p10": values[roundi(last * 0.10)],
		"p25": values[roundi(last * 0.25)],
		"p50": values[roundi(last * 0.50)],
		"p75": values[roundi(last * 0.75)],
		"p90": values[roundi(last * 0.90)],
		"max": values[last],
	}


func _run() -> void:
	var terran_biomes: Array = Enum.get_biomes_for_gpu(Enum.TYPE_TERRAN)
	var resolution := Vector2i(terran_biomes.size() * PREVIEW_WIDTH_PER_BIOME, PREVIEW_HEIGHT)
	var gpu := GPUContext.new(resolution)
	if gpu == null or gpu.rd == null:
		push_error("Final-map palette test could not create a RenderingDevice")
		_quit(1)
		return
	var orchestrator := GPUOrchestrator.new(gpu, resolution, {
		"planet_type": Enum.TYPE_TERRAN,
		"sea_level": 0.0,
	})
	if (
		orchestrator == null
		or orchestrator.rd == null
		or not gpu.pipelines.has("final_map")
		or not (gpu.pipelines["final_map"] as RID).is_valid()
	):
		push_error("Final-map shader did not compile")
		gpu.cleanup()
		_quit(1)
		return

	gpu.initialize_erosion_textures()
	gpu.initialize_water_textures()
	gpu.initialize_climate_textures()
	gpu.initialize_biome_textures()
	gpu.initialize_final_map_textures()
	var inputs := _build_inputs(terran_biomes, resolution)
	gpu.rd.texture_update(gpu.textures["geo"], 0, inputs["geo"])
	gpu.rd.texture_update(gpu.textures["climate"], 0, inputs["climate"])
	gpu.rd.texture_update(gpu.textures["biome_colored"], 0, inputs["biome_color"])
	gpu.rd.texture_update(gpu.textures["biome_id"], 0, inputs["biome_id"])
	gpu.rd.texture_update(gpu.textures["river_flux"], 0, inputs["river_flux"])
	gpu.rd.texture_update(gpu.textures["river_biome_id"], 0, inputs["river_biome_id"])
	gpu.rd.texture_update(gpu.textures["water_colored"], 0, inputs["water"])
	gpu.rd.texture_update(gpu.textures["ice_caps"], 0, inputs["ice"])

	orchestrator._run_final_map_shader(
		{"planet_type": Enum.TYPE_TERRAN, "sea_level": 0.0},
		resolution.x,
		resolution.y
	)
	var final_data := gpu.readback_texture_raw("final_map")
	var preview_path := _save_preview(final_data, resolution)
	var valid := (
		_validate_palette(terran_biomes, final_data, resolution)
		and _validate_final_map_shader()
	)
	print("[FinalMapPalette] biomes=", terran_biomes.size())
	print("[FinalMapPalette] preview=", preview_path)
	print("Final map palette regression: ", "PASS" if valid else "FAIL")
	if not valid:
		push_error("Final-map biome palette contract failed")
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	_quit(0 if valid else 1)


func _build_inputs(biomes: Array, resolution: Vector2i) -> Dictionary:
	var pixel_count := resolution.x * resolution.y
	var geo := PackedByteArray()
	var climate := PackedByteArray()
	var biome_color := PackedByteArray()
	var biome_id := PackedByteArray()
	var river_flux := PackedByteArray()
	var river_biome_id := PackedByteArray()
	var water := PackedByteArray()
	var ice := PackedByteArray()
	geo.resize(pixel_count * 16)
	climate.resize(pixel_count * 16)
	biome_color.resize(pixel_count * 4)
	biome_id.resize(pixel_count * 4)
	river_flux.resize(pixel_count * 4)
	river_biome_id.resize(pixel_count * 4)
	water.resize(pixel_count * 4)
	ice.resize(pixel_count * 4)
	ice.fill(0)
	for y in range(resolution.y):
		var height_ratio := float(y) / float(maxi(resolution.y - 1, 1))
		var elevation := lerpf(40.0, 5200.0, height_ratio)
		for x in range(resolution.x):
			var biome_index := mini(x / PREVIEW_WIDTH_PER_BIOME, biomes.size() - 1)
			var biome: Biome = biomes[biome_index]
			var pixel_index := y * resolution.x + x
			var float_offset := pixel_index * 16
			var byte_offset := pixel_index * 4
			var water_pixel := biome.get_water_need()
			var temperature_range := biome.get_interval_temp()
			var humidity_range := biome.get_interval_precipitation()
			var sea_temperature := clampf(
				(float(temperature_range[0]) + float(temperature_range[1])) * 0.5,
				-20.0,
				40.0
			)
			var local_temperature := sea_temperature - maxf(elevation, 0.0) * 0.0065
			var humidity := clampf(
				(float(humidity_range[0]) + float(humidity_range[1])) * 0.5,
				0.0,
				1.0
			)
			# Trois colonnes internes forcent la même forte humidité sur tous les
			# biomes terrestres. Elles vérifient qu'un désert humide ne devient pas
			# visuellement une forêt, tout en autorisant un léger green-up.
			var local_x := x % PREVIEW_WIDTH_PER_BIOME
			if not water_pixel and local_x >= 12 and local_x <= 14:
				humidity = 0.82
			geo.encode_float(float_offset, -1200.0 if water_pixel else elevation)
			geo.encode_float(float_offset + 4, 0.0)
			geo.encode_float(float_offset + 8, 0.0)
			geo.encode_float(float_offset + 12, 1200.0 if water_pixel else 0.0)
			climate.encode_float(float_offset, local_temperature)
			climate.encode_float(float_offset + 4, humidity)
			climate.encode_float(float_offset + 8, 0.0)
			climate.encode_float(float_offset + 12, 0.0)
			_encode_color(biome_color, byte_offset, biome.get_couleur())
			biome_id.encode_u32(byte_offset, biome_index)
			river_flux.encode_float(byte_offset, 0.0)
			river_biome_id.encode_u32(byte_offset, 0xFFFFFFFF)
			_encode_color(
				water,
				byte_offset,
				Color(biome.get_couleur_vegetation(), 1.0) if water_pixel else Color.TRANSPARENT
			)
	return {
		"geo": geo,
		"climate": climate,
		"biome_color": biome_color,
		"biome_id": biome_id,
		"river_flux": river_flux,
		"river_biome_id": river_biome_id,
		"water": water,
		"ice": ice,
	}


func _encode_color(data: PackedByteArray, offset: int, color: Color) -> void:
	data[offset] = int(round(color.r * 255.0))
	data[offset + 1] = int(round(color.g * 255.0))
	data[offset + 2] = int(round(color.b * 255.0))
	data[offset + 3] = int(round(color.a * 255.0))


func _validate_palette(biomes: Array, final_data: PackedByteArray, resolution: Vector2i) -> bool:
	if final_data.size() != resolution.x * resolution.y * 4:
		return false
	var palette_colors := {}
	for biome_value in Enum.BIOMES:
		var biome: Biome = biome_value
		var color := biome.get_couleur_vegetation()
		if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b):
			return false
		if color.a < 0.999 or maxf(color.r, maxf(color.g, color.b)) < 0.08:
			return false
		palette_colors[color.to_html(false)] = true
	if palette_colors.size() != Enum.BIOMES.size():
		return false
	var rendered_colors := {}
	for biome_index in range(biomes.size()):
		var x := biome_index * PREVIEW_WIDTH_PER_BIOME + PREVIEW_WIDTH_PER_BIOME / 2
		var y := PREVIEW_HEIGHT / 2
		var offset := (y * resolution.x + x) * 4
		var rendered := Color8(
			final_data[offset],
			final_data[offset + 1],
			final_data[offset + 2],
			final_data[offset + 3]
		)
		rendered_colors[rendered.to_html(false)] = true
	print("[FinalMapPalette] rendered_midpoint_colors=", rendered_colors.size())
	if rendered_colors.size() < 24:
		return false
	var temperate_index := _biome_index(biomes, "Forêt Tempérée (Décidue)")
	if temperate_index < 0:
		return false
	var sample_x := (
		temperate_index * PREVIEW_WIDTH_PER_BIOME + PREVIEW_WIDTH_PER_BIOME / 2
	)
	var lowland := _rendered_color(final_data, resolution, sample_x, 10)
	var summit := _rendered_color(
		final_data,
		resolution,
		sample_x,
		PREVIEW_HEIGHT - 5
	)
	print("[FinalMapPalette] temperate_lowland=", lowland, " summit=", summit)
	if minf(summit.r, minf(summit.g, summit.b)) < 0.78:
		return false
	if _luminance(summit) < _luminance(lowland) + 0.24:
		return false
	var wet_probe_offset := 13
	var wet_probe_y := 10
	var sand_index := _biome_index(biomes, "Désert de Sable")
	var badlands_index := _biome_index(biomes, "Désert Rocheux (Badlands)")
	var rainforest_index := _biome_index(biomes, "Forêt Humide (Rainforest)")
	if sand_index < 0 or badlands_index < 0 or rainforest_index < 0:
		return false
	var wet_sand := _rendered_color(
		final_data, resolution,
		sand_index * PREVIEW_WIDTH_PER_BIOME + wet_probe_offset,
		wet_probe_y
	)
	var wet_badlands := _rendered_color(
		final_data, resolution,
		badlands_index * PREVIEW_WIDTH_PER_BIOME + wet_probe_offset,
		wet_probe_y
	)
	var wet_rainforest := _rendered_color(
		final_data, resolution,
		rainforest_index * PREVIEW_WIDTH_PER_BIOME + wet_probe_offset,
		wet_probe_y
	)
	print(
		"[FinalMapPalette] wet_sand=", wet_sand,
		" wet_badlands=", wet_badlands,
		" wet_rainforest=", wet_rainforest
	)
	# Une condition humide peut reverdir les sols, mais les déserts doivent
	# conserver une signature minérale plus chaude que la forêt. Exiger R > G
	# recréait précisément l'aplat catégoriel que la composition physique évite.
	if wet_sand.r - wet_sand.b < 0.06 or wet_badlands.r - wet_badlands.b < 0.06:
		return false
	if wet_rainforest.g <= wet_rainforest.r * 1.15:
		return false
	var sand := _biome_color("Désert de Sable")
	var badlands := _biome_color("Désert Rocheux (Badlands)")
	var ice_cap := _biome_color("Calotte Glaciaire")
	var taiga := _biome_color("Taïga (Forêt Boréale)")
	var rainforest := _biome_color("Forêt Humide (Rainforest)")
	var sulfur := _biome_color("Désert de Soufre")
	var magma := _biome_color("Océan de Magma")
	var lunar_mare := _biome_color("Mare (Mer Lunaire - Basalte)")
	var lunar_highland := _biome_color("Hauts Plateaux Lunaires")
	var salt := _biome_color("Désert de Sel")
	var sterile_ice := _biome_color("Glaciers Stériles")
	return (
		sand.r > 0.78 and sand.g > 0.62 and sand.b < 0.55
		and badlands.r > badlands.g * 1.35
		and ice_cap.r > 0.85 and ice_cap.b >= ice_cap.r
		and taiga.g > taiga.r * 1.30
		and rainforest.g > rainforest.r * 1.45
		and sulfur.r > 0.48 and sulfur.g > 0.42 and sulfur.b < 0.40
		and sulfur.r > sulfur.g
		and magma.r > magma.g * 2.0
		and _luminance(lunar_highland) > _luminance(lunar_mare) + 0.30
		and minf(salt.r, minf(salt.g, salt.b)) > 0.70
		and sterile_ice.b > sterile_ice.r
	)


func _validate_final_map_shader() -> bool:
	var shader := FileAccess.get_file_as_string("res://shader/compute/final_map.glsl")
	var precipitation_shader := FileAccess.get_file_as_string(
		"res://shader/compute/atmosphere_climat/precipitation.glsl"
	)
	var orchestrator_script := FileAccess.get_file_as_string(
		"res://src/classes/classes_gpu/orchestrator.gd"
	)
	return (
		shader.contains("calculateTopoShading")
		and shader.contains("climate_texture")
		and shader.contains("smoothedBiomeMaterial")
		and shader.contains("smoothed_land_humidity")
		and shader.contains("humidity_sample_step = sample_step * 3")
		and shader.contains("mix(fallback_humidity, filtered_humidity, 0.94)")
		and shader.contains("landColorDither")
		and precipitation_shader.contains("local_detail * 0.012")
		and orchestrator_script.contains(
			"lerpf(river_threshold, major_river_threshold, 0.35)"
		)
		and shader.contains("biomeVegetationCapacity")
		and shader.contains("ephemeral_greenup")
		and shader.contains("BIOME_TINT_STRENGTH = 0.07")
		and shader.contains("mountain_snow")
		and not shader.contains("contourKind")
		and not shader.contains("MINOR_INTERVAL")
		and not shader.contains("MAJOR_INTERVAL")
	)


func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func _biome_index(biomes: Array, name: String) -> int:
	for index in range(biomes.size()):
		if (biomes[index] as Biome).get_nom() == name:
			return index
	return -1


func _rendered_color(
	data: PackedByteArray,
	resolution: Vector2i,
	x: int,
	y: int
) -> Color:
	var offset := (y * resolution.x + x) * 4
	return Color8(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])


func _biome_color(name: String) -> Color:
	for biome_value in Enum.BIOMES:
		var biome: Biome = biome_value
		if biome.get_nom() == name:
			return biome.get_couleur_vegetation()
	return Color.MAGENTA


func _save_preview(data: PackedByteArray, resolution: Vector2i) -> String:
	return _save_texture(data, resolution, "final_map_palette_preview.png")


func _save_texture(data: PackedByteArray, resolution: Vector2i, filename: String) -> String:
	if data.size() != resolution.x * resolution.y * 4:
		return ""
	DirAccess.make_dir_recursive_absolute("user://temp")
	var image := Image.create_from_data(
		resolution.x,
		resolution.y,
		false,
		Image.FORMAT_RGBA8,
		data
	)
	var path := "user://temp/" + filename
	return ProjectSettings.globalize_path(path) if image.save_png(path) == OK else ""


func _quit(code: int) -> void:
	get_tree().quit(code)
