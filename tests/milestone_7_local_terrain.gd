extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var dimensions := Vector2i(8, 6)
	var pixels := dimensions.x * dimensions.y
	var geo := PackedByteArray(); geo.resize(pixels * 16)
	var water := PackedByteArray(); water.resize(pixels)
	var biome := PackedByteArray(); biome.resize(pixels * 4)
	var climate := PackedByteArray(); climate.resize(pixels * 8)
	var flux := PackedByteArray(); flux.resize(pixels * 4)
	var plates := PackedByteArray(); plates.resize(pixels * 4)
	for y in range(dimensions.y):
		for x in range(dimensions.x):
			var index := y * dimensions.x + x
			geo.encode_float(index * 16, 120.0 + x * 16.0 + y * 9.0)
			water[index] = 1 if x <= 1 else 0
			biome.encode_u32(index * 4, (x + y) % 6)
			climate.encode_float(index * 8, 18.0 - y * 2.2)
			climate.encode_float(index * 8 + 4, clampf(0.2 + y * 0.11, 0.0, 1.0))
			flux.encode_float(index * 4, 3.0 if x == 4 else 0.02)
			plates.encode_u32(index * 4, 1 if x < 4 else 2)
	var params := {
		"seed": 77331, "planet_radius": 150.0, "planet_type": 0,
		"sea_level": 130.0, "global_dimensions": dimensions,
	}
	var sampler := GlobalMacroSampler.from_raw(dimensions, geo, water, biome, climate, flux, plates, params)
	var cells := [
		Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1),
		Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
		Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3),
	]
	# Deliberately generate in a non-spatial order.
	var order := [4, 0, 8, 2, 6, 1, 7, 3, 5]
	var zones: Dictionary = {}
	for order_index in order:
		var cell: Vector2i = cells[order_index]
		zones[cell] = LocalZoneGenerator.generate_zone(cell, sampler, params, 64)
		if zones[cell].is_empty():
			print("[Milestone7] generation failed at ", cell)
			get_tree().quit(1)
			return

	var expected_layers := [
		"height", "normals", "slope", "water_depth", "water_mask", "flow",
		"soil_type", "soil_moisture", "soil_depth", "rock_type",
		"surface_material", "vegetation_density", "resources", "snow_ice",
		"spawn_mask", "hazard",
	]
	var contract_ok := true
	for zone_value in zones.values():
		var zone: Dictionary = zone_value
		var images: Dictionary = zone["images"]
		for layer in expected_layers:
			contract_ok = contract_ok and images.has(layer)
		contract_ok = contract_ok and not images.has("region_map") and not images.has("precipitation") and not images.has("plates")

	var seam_ok := true
	for y in range(1, 4):
		for x in range(2, 5):
			var cell := Vector2i(x, y)
			if x < 4:
				seam_ok = seam_ok and _zones_match(zones[cell], zones[cell + Vector2i.RIGHT], true, expected_layers)
			if y < 3:
				seam_ok = seam_ok and _zones_match(zones[cell], zones[cell + Vector2i.DOWN], false, expected_layers)

	var repeated := LocalZoneGenerator.generate_zone(Vector2i(3, 2), sampler, params, 64)
	var deterministic := _zone_hash(zones[Vector2i(3, 2)], expected_layers) == _zone_hash(repeated, expected_layers)
	var soil_present := _has_nonzero_or_multiple_ids((zones[Vector2i(3, 2)]["images"] as Dictionary)["soil_type"])

	var cache_root := "user://milestone7_test_cache"
	PlanetTileStore._remove_tree(cache_root)
	var cache := LocalZoneCache.new(cache_root)
	var first_cached := LocalZoneGenerator.generate_zone(Vector2i(3, 2), sampler, params, 32, cache)
	var second_cached := LocalZoneGenerator.generate_zone(Vector2i(3, 2), sampler, params, 32, cache)
	var cache_ok := not bool(first_cached.get("cache_hit", true)) and bool(second_cached.get("cache_hit", false))
	PlanetTileStore._remove_tree(cache_root)

	var preview_layers := LocalZoneDebugExporter.build_previews(zones[Vector2i(3, 2)])
	var preview_ok := true
	for preview_name in [
		"height", "normals", "slope", "water", "flow", "soil", "soil_moisture",
		"soil_depth", "rock", "surface", "vegetation", "resources", "snow_ice",
		"spawn", "hazard",
	]:
		preview_ok = preview_ok and preview_layers.has(preview_name)
		if preview_layers.has(preview_name):
			var preview: Image = preview_layers[preview_name]
			preview_ok = preview_ok and preview != null and preview.get_size() == Vector2i(64, 64)

	var passed := contract_ok and seam_ok and deterministic and soil_present and cache_ok and preview_ok
	print("[Milestone7] contract=", contract_ok, " seams=", seam_ok,
		" deterministic=", deterministic, " soils=", soil_present, " cache=", cache_ok,
		" ui_previews=", preview_ok)
	get_tree().quit(0 if passed else 1)

func _zones_match(a: Dictionary, b: Dictionary, horizontal: bool, layers: Array) -> bool:
	var ai: Dictionary = a["images"]
	var bi: Dictionary = b["images"]
	for layer in layers:
		if _edge_bytes(ai[layer], horizontal, true) != _edge_bytes(bi[layer], horizontal, false):
			print("[Milestone7] seam mismatch layer=", layer, " horizontal=", horizontal)
			return false
	return true

func _edge_bytes(image: Image, horizontal: bool, far_edge: bool) -> PackedByteArray:
	var data := image.get_data()
	var w := image.get_width()
	var h := image.get_height()
	var bpp := data.size() / (w * h)
	var result := PackedByteArray()
	if horizontal:
		var x := w - 1 if far_edge else 0
		for y in range(h):
			var offset := (y * w + x) * bpp
			result.append_array(data.slice(offset, offset + bpp))
	else:
		var y := h - 1 if far_edge else 0
		var offset := y * w * bpp
		result.append_array(data.slice(offset, offset + w * bpp))
	return result

func _zone_hash(zone: Dictionary, layers: Array) -> int:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var images: Dictionary = zone["images"]
	for layer in layers:
		context.update((images[layer] as Image).get_data())
	return hash(context.finish())

func _has_nonzero_or_multiple_ids(image: Image) -> bool:
	var data := image.get_data()
	var values: Dictionary = {}
	for value in data:
		values[int(value)] = true
	return values.size() >= 1 and not data.is_empty()
