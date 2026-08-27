extends Node

const PREVIEW_WIDTH_PER_BIOME := 18
const PREVIEW_HEIGHT := 128


func _ready() -> void:
	if "--arid-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "arid")
	elif "--cold-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "cold")
	elif "--world-preview" in OS.get_cmdline_user_args():
		call_deferred("_run_world_preview", "world")
	else:
		call_deferred("_run")


func _run_world_preview(profile: String) -> void:
	var resolution := Vector2i(752, 376)
	var params := {
		"seed": 3001918132,
		"resolution": resolution,
		"planet_type": Enum.TYPE_TERRAN,
		"planet_radius": 150.0,
		"planet_density": 5.51,
		"avg_temperature": -7.0 if profile == "cold" else (34.0 if profile == "arid" else 21.0),
		"global_humidity": 0.42 if profile == "cold" else (0.18 if profile == "arid" else 0.5),
		"avg_precipitation": 0.42 if profile == "cold" else (0.18 if profile == "arid" else 0.5),
		"sea_level": 0.0,
		"ocean_ratio": 55.0,
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
	var valid := not final_path.is_empty() and not biome_path.is_empty()
	print("[FinalMapPalette] world=", final_path)
	print("[FinalMapPalette] world_biomes=", biome_path)
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	_quit(0 if valid else 1)


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
	var biome_color := PackedByteArray()
	var biome_id := PackedByteArray()
	var river_flux := PackedByteArray()
	var river_biome_id := PackedByteArray()
	var water := PackedByteArray()
	var ice := PackedByteArray()
	geo.resize(pixel_count * 16)
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
			geo.encode_float(float_offset, -1200.0 if water_pixel else elevation)
			geo.encode_float(float_offset + 4, 0.0)
			geo.encode_float(float_offset + 8, 0.0)
			geo.encode_float(float_offset + 12, 1200.0 if water_pixel else 0.0)
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
	if rendered_colors.size() < 24:
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
		and sulfur.r > 0.70 and sulfur.g > 0.60 and sulfur.b < 0.40
		and magma.r > magma.g * 2.0
		and _luminance(lunar_highland) > _luminance(lunar_mare) + 0.30
		and minf(salt.r, minf(salt.g, salt.b)) > 0.70
		and sterile_ice.b > sterile_ice.r
	)


func _validate_final_map_shader() -> bool:
	var shader := FileAccess.get_file_as_string("res://shader/compute/final_map.glsl")
	return (
		shader.contains("calculateTopoShading")
		and not shader.contains("contourKind")
		and not shader.contains("MINOR_INTERVAL")
		and not shader.contains("MAJOR_INTERVAL")
	)


func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


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
