extends Node

const TEST_RESOLUTION := Vector2i(384, 192)
const TEST_SEED := 2304640463


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var params := {
		"seed": TEST_SEED,
		"resolution": TEST_RESOLUTION,
		"planet_type": Enum.TYPE_TERRAN,
		"avg_temperature": 18.0,
		"global_humidity": 0.5,
		"sea_level": 0.0,
	}
	var gpu := GPUContext.new(TEST_RESOLUTION)
	if gpu == null or gpu.rd == null:
		push_error("Climate test could not create a RenderingDevice")
		get_tree().quit(1)
		return
	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if orchestrator == null or orchestrator.rd == null:
		push_error("Climate shaders could not initialize")
		gpu.cleanup()
		get_tree().quit(1)
		return

	var synthetic := _build_synthetic_geo()
	gpu.rd.texture_update(gpu.textures["geo"], 0, synthetic["geo"])
	orchestrator.run_pre_erosion_climate_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var climate := gpu.readback_texture_raw("climate")
	var temperature_color := gpu.readback_texture_raw("temperature_colored")
	var precipitation_color := gpu.readback_texture_raw("precipitation_colored")
	var stats := _analyze(climate, temperature_color, precipitation_color, synthetic["land_mask"])
	var preview_paths := _save_previews(temperature_color, precipitation_color)

	orchestrator.run_pre_erosion_climate_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var deterministic := (
		hash(climate) == hash(gpu.readback_texture_raw("climate"))
		and hash(temperature_color) == hash(gpu.readback_texture_raw("temperature_colored"))
		and hash(precipitation_color) == hash(gpu.readback_texture_raw("precipitation_colored"))
	)
	var valid := (
		bool(stats["finite"])
		and float(stats["equator_temperature"]) > float(stats["polar_temperature"]) + 24.0
		and float(stats["lowland_temperature"]) > float(stats["mountain_temperature"]) + 7.0
		and float(stats["ocean_precipitation"]) > float(stats["inland_precipitation"]) + 0.02
		and float(stats["windward_precipitation"]) > float(stats["lee_precipitation"]) + 0.01
		and float(stats["humidity_max"]) - float(stats["humidity_min"]) > 0.45
		and int(stats["temperature_color_count"]) > 180
		and int(stats["precipitation_color_count"]) > 180
		and float(stats["temperature_seam_delta"]) < 3.0
		and float(stats["precipitation_seam_delta"]) < 0.12
		and deterministic
	)
	print("[ClimateGeneration] stats=", stats)
	print("[ClimateGeneration] deterministic=", deterministic)
	print("[ClimateGeneration] temperature=", preview_paths["temperature"])
	print("[ClimateGeneration] precipitation=", preview_paths["precipitation"])
	if not valid:
		push_error("Upgraded climate generation contract failed")
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	get_tree().quit(0 if valid else 1)


func _build_synthetic_geo() -> Dictionary:
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var geo := PackedByteArray()
	var land_mask := PackedByteArray()
	geo.resize(pixel_count * 16)
	land_mask.resize(pixel_count)
	for y in range(TEST_RESOLUTION.y):
		var v := (float(y) + 0.5) / float(TEST_RESOLUTION.y)
		for x in range(TEST_RESOLUTION.x):
			var u := (float(x) + 0.5) / float(TEST_RESOLUTION.x)
			var west_coast := 0.18 + sin(v * TAU * 3.0) * 0.018
			var east_coast := 0.82 + sin(v * TAU * 2.0 + 1.2) * 0.016
			var is_land := u > west_coast and u < east_coast
			var ridge := 5200.0 * exp(-pow((u - 0.50) / 0.032, 2.0))
			var rolling_relief := 260.0 * sin(u * TAU * 5.0) * cos(v * TAU * 3.0)
			var elevation := 180.0 + maxf(rolling_relief, -120.0) + ridge if is_land else -1600.0
			var pixel_index := y * TEST_RESOLUTION.x + x
			var offset := pixel_index * 16
			geo.encode_float(offset, elevation)
			geo.encode_float(offset + 4, 0.0)
			geo.encode_float(offset + 8, 0.0)
			geo.encode_float(offset + 12, 0.0 if is_land else 1600.0)
			land_mask[pixel_index] = 1 if is_land else 0
	return {"geo": geo, "land_mask": land_mask}


func _analyze(
	climate: PackedByteArray,
	temperature_color: PackedByteArray,
	precipitation_color: PackedByteArray,
	land_mask: PackedByteArray
) -> Dictionary:
	var finite := true
	var humidity_min := INF
	var humidity_max := -INF
	var equator_temperature: Array[float] = []
	var polar_temperature: Array[float] = []
	var mountain_temperature: Array[float] = []
	var lowland_temperature: Array[float] = []
	var ocean_precipitation: Array[float] = []
	var inland_precipitation: Array[float] = []
	var windward_precipitation: Array[float] = []
	var lee_precipitation: Array[float] = []
	var temperature_colors: Dictionary = {}
	var precipitation_colors: Dictionary = {}
	var temperature_seam_delta := 0.0
	var precipitation_seam_delta := 0.0
	for y in range(TEST_RESOLUTION.y):
		var v := (float(y) + 0.5) / float(TEST_RESOLUTION.y)
		var latitude := absf(v * 2.0 - 1.0)
		for x in range(TEST_RESOLUTION.x):
			var u := (float(x) + 0.5) / float(TEST_RESOLUTION.x)
			var pixel_index := y * TEST_RESOLUTION.x + x
			var climate_offset := pixel_index * 16
			var color_offset := pixel_index * 4
			var temperature := climate.decode_float(climate_offset)
			var humidity := climate.decode_float(climate_offset + 4)
			var wind_x := climate.decode_float(climate_offset + 8)
			var wind_y := climate.decode_float(climate_offset + 12)
			finite = finite and is_finite(temperature) and is_finite(humidity) and is_finite(wind_x) and is_finite(wind_y)
			humidity_min = minf(humidity_min, humidity)
			humidity_max = maxf(humidity_max, humidity)
			if latitude < 0.08:
				equator_temperature.append(temperature)
			if latitude > 0.90:
				polar_temperature.append(temperature)
			if latitude > 0.35 and latitude < 0.60 and u > 0.485 and u < 0.515:
				mountain_temperature.append(temperature)
			if latitude > 0.35 and latitude < 0.60 and u > 0.30 and u < 0.38:
				lowland_temperature.append(temperature)
			if latitude > 0.25 and latitude < 0.62:
				if land_mask[pixel_index] == 0:
					ocean_precipitation.append(humidity)
				elif u > 0.34 and u < 0.42:
					inland_precipitation.append(humidity)
			if v > 0.18 and v < 0.34:
				if u > 0.43 and u < 0.48:
					windward_precipitation.append(humidity)
				elif u > 0.52 and u < 0.59:
					lee_precipitation.append(humidity)
			temperature_colors[_rgba_key(temperature_color, color_offset)] = true
			precipitation_colors[_rgba_key(precipitation_color, color_offset)] = true
		var left_temperature := climate.decode_float(y * TEST_RESOLUTION.x * 16)
		var right_temperature := climate.decode_float((y * TEST_RESOLUTION.x + TEST_RESOLUTION.x - 1) * 16)
		temperature_seam_delta += absf(left_temperature - right_temperature)
		var left_precipitation := climate.decode_float(y * TEST_RESOLUTION.x * 16 + 4)
		var right_precipitation := climate.decode_float((y * TEST_RESOLUTION.x + TEST_RESOLUTION.x - 1) * 16 + 4)
		precipitation_seam_delta += absf(left_precipitation - right_precipitation)
	return {
		"finite": finite,
		"humidity_min": humidity_min,
		"humidity_max": humidity_max,
		"equator_temperature": _mean(equator_temperature),
		"polar_temperature": _mean(polar_temperature),
		"mountain_temperature": _mean(mountain_temperature),
		"lowland_temperature": _mean(lowland_temperature),
		"ocean_precipitation": _mean(ocean_precipitation),
		"inland_precipitation": _mean(inland_precipitation),
		"windward_precipitation": _mean(windward_precipitation),
		"lee_precipitation": _mean(lee_precipitation),
		"temperature_color_count": temperature_colors.size(),
		"precipitation_color_count": precipitation_colors.size(),
		"temperature_seam_delta": temperature_seam_delta / float(TEST_RESOLUTION.y),
		"precipitation_seam_delta": precipitation_seam_delta / float(TEST_RESOLUTION.y),
	}


func _rgba_key(data: PackedByteArray, offset: int) -> int:
	return int(data[offset]) | (int(data[offset + 1]) << 8) | (int(data[offset + 2]) << 16)


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _save_previews(temperature: PackedByteArray, precipitation: PackedByteArray) -> Dictionary:
	DirAccess.make_dir_recursive_absolute("user://temp")
	var temperature_image := Image.create_from_data(
		TEST_RESOLUTION.x, TEST_RESOLUTION.y, false, Image.FORMAT_RGBA8, temperature
	)
	var precipitation_image := Image.create_from_data(
		TEST_RESOLUTION.x, TEST_RESOLUTION.y, false, Image.FORMAT_RGBA8, precipitation
	)
	var temperature_path := "user://temp/temperature_upgrade_smoke.png"
	var precipitation_path := "user://temp/precipitation_upgrade_smoke.png"
	temperature_image.save_png(temperature_path)
	precipitation_image.save_png(precipitation_path)
	return {
		"temperature": ProjectSettings.globalize_path(temperature_path),
		"precipitation": ProjectSettings.globalize_path(precipitation_path),
	}
