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
		"ice_probability": 0.9,
		"sea_level": 0.0,
	}
	var gpu := GPUContext.new(TEST_RESOLUTION)
	if gpu == null or gpu.rd == null:
		push_error("Ice-cap test could not create a RenderingDevice")
		get_tree().quit(1)
		return
	var orchestrator := GPUOrchestrator.new(gpu, TEST_RESOLUTION, params)
	if (
		orchestrator == null
		or orchestrator.rd == null
		or not gpu.shaders.has("ice_caps")
		or not (gpu.shaders["ice_caps"] as RID).is_valid()
	):
		push_error("Ice-cap shader did not compile")
		gpu.cleanup()
		get_tree().quit(1)
		return

	gpu.initialize_final_map_textures()
	var inputs := _build_synthetic_inputs()
	gpu.rd.texture_update(gpu.textures["geo"], 0, inputs["geo"])
	gpu.rd.texture_update(gpu.textures["climate"], 0, inputs["climate"])
	gpu.rd.texture_update(gpu.textures["water_colored"], 0, inputs["water"])
	orchestrator.run_ice_caps_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var ice_data := gpu.readback_texture_raw("ice_caps")
	var stats := _analyze_ice(ice_data, inputs["land_mask"])
	var preview_paths := _save_previews(ice_data)
	var disabled_params := params.duplicate()
	disabled_params["ice_probability"] = 0.0
	orchestrator.run_ice_caps_phase(disabled_params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var disabled_data := gpu.readback_texture_raw("ice_caps")
	var disabled_visible := _count_visible_pixels(disabled_data)
	orchestrator.run_ice_caps_phase(params, TEST_RESOLUTION.x, TEST_RESOLUTION.y)
	var repeated_data := gpu.readback_texture_raw("ice_caps")
	var deterministic := hash(ice_data) == hash(repeated_data)

	var valid := (
		ice_data.size() == TEST_RESOLUTION.x * TEST_RESOLUTION.y * 4
		and int(stats["visible_pixels"]) > 500
		and int(stats["dense_pixels"]) > 100
		and int(stats["partial_alpha_pixels"]) > int(stats["visible_pixels"]) / 10
		and int(stats["alpha_levels"]) >= 24
		and int(stats["land_violations"]) == 0
		and int(stats["warm_belt_violations"]) == 0
		and int(stats["north_visible"]) > 0
		and int(stats["south_visible"]) > 0
		and float(stats["seam_mean_alpha_delta"]) < 20.0
		and disabled_visible == 0
		and deterministic
	)
	print("[IceCapsGeneration] stats=", stats)
	print("[IceCapsGeneration] disabled_visible=", disabled_visible)
	print("[IceCapsGeneration] deterministic=", deterministic)
	print("[IceCapsGeneration] raw=", preview_paths["raw"])
	print("[IceCapsGeneration] preview=", preview_paths["preview"])
	if not valid:
		push_error("Upgraded ice-cap concentration contract failed")
	orchestrator.cleanup()
	GPUContext.shutdown_shared_device()
	get_tree().quit(0 if valid else 1)


func _build_synthetic_inputs() -> Dictionary:
	var pixel_count := TEST_RESOLUTION.x * TEST_RESOLUTION.y
	var geo := PackedByteArray()
	var climate := PackedByteArray()
	var water := PackedByteArray()
	var land_mask := PackedByteArray()
	geo.resize(pixel_count * 16)
	climate.resize(pixel_count * 16)
	water.resize(pixel_count * 4)
	land_mask.resize(pixel_count)
	for y in range(TEST_RESOLUTION.y):
		var v := (float(y) + 0.5) / float(TEST_RESOLUTION.y)
		var latitude := absf(v * 2.0 - 1.0)
		for x in range(TEST_RESOLUTION.x):
			var u := (float(x) + 0.5) / float(TEST_RESOLUTION.x)
			var continent_a := _inside_warped_ellipse(u, v, Vector2(0.26, 0.20), Vector2(0.17, 0.12), 17.0)
			var continent_b := _inside_warped_ellipse(u, v, Vector2(0.72, 0.79), Vector2(0.20, 0.11), 31.0)
			var island := _inside_warped_ellipse(u, v, Vector2(0.54, 0.50), Vector2(0.08, 0.17), 47.0)
			var is_land := continent_a or continent_b or island
			var pixel_index := y * TEST_RESOLUTION.x + x
			var float_offset := pixel_index * 16
			var byte_offset := pixel_index * 4
			var temperature := (
				20.0
				- 49.0 * pow(latitude, 1.35)
				+ sin(u * TAU * 3.0 + v * 4.0) * latitude * 1.8
			)
			geo.encode_float(float_offset, 220.0 if is_land else -1200.0)
			geo.encode_float(float_offset + 4, 0.0)
			geo.encode_float(float_offset + 8, 0.0)
			geo.encode_float(float_offset + 12, 0.0 if is_land else 1200.0)
			climate.encode_float(float_offset, temperature)
			climate.encode_float(float_offset + 4, 0.55)
			climate.encode_float(float_offset + 8, 0.0)
			climate.encode_float(float_offset + 12, 0.0)
			water[byte_offset] = 48
			water[byte_offset + 1] = 92
			water[byte_offset + 2] = 126
			water[byte_offset + 3] = 0 if is_land else 255
			land_mask[pixel_index] = 1 if is_land else 0
	return {
		"geo": geo,
		"climate": climate,
		"water": water,
		"land_mask": land_mask,
	}


func _inside_warped_ellipse(
	u: float,
	v: float,
	center: Vector2,
	radius: Vector2,
	phase: float
) -> bool:
	var warped_u := u + sin(v * TAU * 5.0 + phase) * 0.012
	var warped_v := v + sin(u * TAU * 7.0 + phase * 0.7) * 0.010
	var delta := Vector2(
		(warped_u - center.x) / radius.x,
		(warped_v - center.y) / radius.y
	)
	return delta.length_squared() < 1.0


func _analyze_ice(ice_data: PackedByteArray, land_mask: PackedByteArray) -> Dictionary:
	var visible_pixels := 0
	var dense_pixels := 0
	var partial_alpha_pixels := 0
	var land_violations := 0
	var warm_belt_violations := 0
	var north_visible := 0
	var south_visible := 0
	var seam_alpha_delta := 0.0
	var alpha_values: Dictionary = {}
	for y in range(TEST_RESOLUTION.y):
		var latitude := absf(((float(y) + 0.5) / float(TEST_RESOLUTION.y)) * 2.0 - 1.0)
		for x in range(TEST_RESOLUTION.x):
			var pixel_index := y * TEST_RESOLUTION.x + x
			var alpha := int(ice_data[pixel_index * 4 + 3])
			if alpha <= 0:
				continue
			visible_pixels += 1
			alpha_values[alpha] = true
			if alpha >= 180:
				dense_pixels += 1
			elif alpha < 180:
				partial_alpha_pixels += 1
			if land_mask[pixel_index] != 0:
				land_violations += 1
			if latitude < 0.45:
				warm_belt_violations += 1
			if y < TEST_RESOLUTION.y / 2:
				north_visible += 1
			else:
				south_visible += 1
		var left_alpha := int(ice_data[(y * TEST_RESOLUTION.x) * 4 + 3])
		var right_alpha := int(ice_data[(y * TEST_RESOLUTION.x + TEST_RESOLUTION.x - 1) * 4 + 3])
		seam_alpha_delta += absf(float(left_alpha - right_alpha))
	return {
		"visible_pixels": visible_pixels,
		"dense_pixels": dense_pixels,
		"partial_alpha_pixels": partial_alpha_pixels,
		"alpha_levels": alpha_values.size(),
		"land_violations": land_violations,
		"warm_belt_violations": warm_belt_violations,
		"north_visible": north_visible,
		"south_visible": south_visible,
		"seam_mean_alpha_delta": seam_alpha_delta / float(TEST_RESOLUTION.y),
	}


func _count_visible_pixels(data: PackedByteArray) -> int:
	var count := 0
	for offset in range(3, data.size(), 4):
		if data[offset] > 0:
			count += 1
	return count


func _save_previews(ice_data: PackedByteArray) -> Dictionary:
	DirAccess.make_dir_recursive_absolute("user://temp")
	var ice := Image.create_from_data(
		TEST_RESOLUTION.x,
		TEST_RESOLUTION.y,
		false,
		Image.FORMAT_RGBA8,
		ice_data
	)
	var raw_path := "user://temp/ice_caps_upgrade_smoke.png"
	ice.save_png(raw_path)
	var preview := Image.create(TEST_RESOLUTION.x, TEST_RESOLUTION.y, false, Image.FORMAT_RGBA8)
	var ocean := Color(0.055, 0.12, 0.17, 1.0)
	for y in range(TEST_RESOLUTION.y):
		for x in range(TEST_RESOLUTION.x):
			var ice_pixel := ice.get_pixel(x, y)
			preview.set_pixel(x, y, ocean.lerp(Color(ice_pixel.r, ice_pixel.g, ice_pixel.b, 1.0), ice_pixel.a))
	var preview_path := "user://temp/ice_caps_upgrade_preview.png"
	preview.save_png(preview_path)
	return {
		"raw": ProjectSettings.globalize_path(raw_path),
		"preview": ProjectSettings.globalize_path(preview_path),
	}
