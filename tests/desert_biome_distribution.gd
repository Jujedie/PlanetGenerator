extends Node

const TEST_RESOLUTION := Vector2i(512, 256)
const TEST_SEED := 616988363


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var params := {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_TERRAN,
		"sea_level": 0.0,
	}
	var gpu := GPUContext.new(TEST_RESOLUTION)
	if gpu == null or gpu.rd == null:
		push_error("Desert biome test could not create a RenderingDevice")
		get_tree().quit(1)
		return
	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if orchestrator == null or orchestrator.rd == null:
		push_error("Desert biome shaders could not initialize")
		gpu.cleanup()
		get_tree().quit(1)
		return

	gpu.initialize_erosion_textures()
	gpu.initialize_water_textures()
	gpu.initialize_climate_textures()
	var inputs := _build_climate_matrix()
	gpu.rd.texture_update(gpu.textures["geo"], 0, inputs["geo"])
	gpu.rd.texture_update(gpu.textures["climate"], 0, inputs["climate"])
	gpu.rd.texture_update(gpu.textures["water_mask"], 0, inputs["water_mask"])
	gpu.rd.texture_update(gpu.textures["river_flux"], 0, inputs["river_flux"])
	orchestrator.run_biome_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)

	var biome_ids := gpu.readback_texture_raw("biome_id")
	var biome_colors := gpu.readback_texture_raw("biome_colored")
	var stats := _analyze(biome_ids, inputs["climate"])
	var preview_path := _save_preview(biome_colors)
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var valid := (
		int(stats.get("Désert semi-aride", 0)) > pixel_count / 100
		and int(stats.get("Désert de Sable", 0)) > pixel_count / 100
		and int(stats.get("Désert Rocheux (Badlands)", 0)) > pixel_count / 100
		and int(stats.get("Désert Extrême", 0)) > pixel_count / 500
		and int(stats.get("Savane", 0)) > pixel_count / 100
		and int(stats.get("cold_biome_violations", 0)) == 0
		and int(stats.get("extreme_humid_violations", 0)) == 0
		and int(stats.get("extreme_cool_violations", 0)) == 0
	)
	print("[DesertBiomeDistribution] stats=", stats)
	print("[DesertBiomeDistribution] preview=", preview_path)
	if not valid:
		push_error("Earth-like arid biome distribution contract failed")
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	get_tree().quit(0 if valid else 1)


func _build_climate_matrix() -> Dictionary:
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var geo := PackedByteArray()
	var climate := PackedByteArray()
	var water_mask := PackedByteArray()
	var river_flux := PackedByteArray()
	geo.resize(pixel_count * 16)
	climate.resize(pixel_count * 16)
	water_mask.resize(pixel_count)
	river_flux.resize(pixel_count * 4)
	water_mask.fill(0)
	river_flux.fill(0)
	for y in range(TEST_RESOLUTION.y):
		var temperature := lerpf(14.0, 72.0, float(y) / float(TEST_RESOLUTION.y - 1))
		for x in range(TEST_RESOLUTION.x):
			var humidity := lerpf(0.0, 0.78, float(x) / float(TEST_RESOLUTION.x - 1))
			var terrain_cell := (x / 32 + y / 32) % 2
			var elevation := 320.0 if terrain_cell == 0 else 1750.0
			elevation += sin(float(x) * 0.071) * 90.0 + cos(float(y) * 0.093) * 70.0
			var offset := (y * TEST_RESOLUTION.x + x) * 16
			geo.encode_float(offset, elevation)
			geo.encode_float(offset + 4, elevation - 100.0)
			geo.encode_float(offset + 8, 40.0)
			geo.encode_float(offset + 12, 0.0)
			climate.encode_float(offset, temperature)
			climate.encode_float(offset + 4, humidity)
			climate.encode_float(offset + 8, 0.0)
			climate.encode_float(offset + 12, 0.0)
	return {
		"geo": geo,
		"climate": climate,
		"water_mask": water_mask,
		"river_flux": river_flux,
	}


func _analyze(biome_ids: PackedByteArray, climate: PackedByteArray) -> Dictionary:
	var biomes: Array = Enum.get_biomes_for_gpu(Enum.TYPE_TERRAN)
	var stats: Dictionary = {
		"cold_biome_violations": 0,
		"extreme_humid_violations": 0,
		"extreme_cool_violations": 0,
	}
	for biome_value in biomes:
		stats[(biome_value as Biome).get_nom()] = 0
	var extreme_id := _biome_index(biomes, "Désert Extrême")
	for pixel_index in range(TEST_RESOLUTION.x * TEST_RESOLUTION.y):
		var biome_id := int(biome_ids.decode_u32(pixel_index * 4))
		if biome_id < 0 or biome_id >= biomes.size():
			continue
		var biome_name: String = (biomes[biome_id] as Biome).get_nom()
		stats[biome_name] = int(stats.get(biome_name, 0)) + 1
		if biome_name in ["Calotte Glaciaire", "Désert Polaire", "Toundra", "Toundra Alpine"]:
			stats["cold_biome_violations"] += 1
		if biome_id == extreme_id:
			var humidity := climate.decode_float(pixel_index * 16 + 4)
			var temperature := climate.decode_float(pixel_index * 16)
			# Includes ample tolerance for classifier microclimate noise and the
			# two one-pixel smoothing passes.
			if humidity > 0.40:
				stats["extreme_humid_violations"] += 1
			if temperature < 50.0:
				stats["extreme_cool_violations"] += 1
	return stats


func _biome_index(biomes: Array, name: String) -> int:
	for index in range(biomes.size()):
		if (biomes[index] as Biome).get_nom() == name:
			return index
	return -1


func _save_preview(data: PackedByteArray) -> String:
	if data.size() != TEST_RESOLUTION.x * TEST_RESOLUTION.y * 4:
		return ""
	DirAccess.make_dir_recursive_absolute("user://temp")
	var image := Image.create_from_data(
		TEST_RESOLUTION.x,
		TEST_RESOLUTION.y,
		false,
		Image.FORMAT_RGBA8,
		data
	)
	var path := "user://temp/desert_biome_distribution.png"
	return ProjectSettings.globalize_path(path) if image.save_png(path) == OK else ""
