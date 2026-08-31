extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var dimensions := Vector2i(16, 8)
	var count := dimensions.x * dimensions.y
	var geo := PackedByteArray()
	geo.resize(count * 16)
	var water := PackedByteArray()
	water.resize(count)
	var biome := PackedByteArray()
	biome.resize(count * 4)
	for y in range(dimensions.y):
		for x in range(dimensions.x):
			var index := y * dimensions.x + x
			var height := float(x - 8) * 150.0 + float(y - 4) * 20.0
			geo.encode_float(index * 16, height)
			water[index] = 1 if x < 5 else 0
			biome.encode_u32(index * 4, int((x + y) % 7))

	var geo_before := geo.duplicate()
	var water_before := water.duplicate()
	var palette := CartographicPalette.load_palette()
	var first := CartographicRenderer.render_full_map(
		geo, water, biome, dimensions, 150.0, 0.0, palette,
		{"view": CartographicRenderer.VIEW_PLANET}
	)
	var deterministic := false
	var unchanged := geo == geo_before and water == water_before
	if not first.is_empty():
		var first_image: Image = first["image"]
		var second := CartographicRenderer.render_full_map(
			geo, water, biome, dimensions, 150.0, 0.0, palette,
			{"view": CartographicRenderer.VIEW_PLANET}
		)
		var second_image: Image = second["image"]
		deterministic = hash(first_image.get_data()) == hash(second_image.get_data())

	var changed_palette := CartographicPalette.new()
	changed_palette._set_fallback_stops()
	changed_palette.saltwater = Color8(180, 60, 60)
	var alternative := CartographicRenderer.render_full_map(
		geo, water, biome, dimensions, 150.0, 0.0, changed_palette,
		{"view": CartographicRenderer.VIEW_PLANET}
	)
	var palette_independent := false
	if not first.is_empty() and not alternative.is_empty():
		var first_alt_image: Image = first["image"]
		var alternative_image: Image = alternative["image"]
		palette_independent = hash(first_alt_image.get_data()) != hash(alternative_image.get_data())
		palette_independent = palette_independent and geo == geo_before and water == water_before

	var intervals_ok := (
		CartographicRenderer.contour_intervals(CartographicRenderer.VIEW_PLANET) == Vector2(250.0, 1000.0)
		and CartographicRenderer.contour_intervals(CartographicRenderer.VIEW_REGIONAL) == Vector2(50.0, 250.0)
		and CartographicRenderer.contour_intervals(CartographicRenderer.VIEW_LOCAL) == Vector2(5.0, 25.0)
	)
	var overlay := CartographicRenderer.render_grid_overlay(dimensions, palette, {
		"view": CartographicRenderer.VIEW_PLANET,
		"alpha": 166,
	})
	var overlay_ok := false
	if not overlay.is_empty():
		var overlay_image: Image = overlay["image"]
		var overlay_bytes := overlay_image.get_data()
		var non_transparent := 0
		var opaque_background := false
		for i in range(3, overlay_bytes.size(), 4):
			if overlay_bytes[i] != 0:
				non_transparent += 1
			if overlay_bytes[i] == 255 and overlay_bytes[i - 3] == 0 and overlay_bytes[i - 2] == 0 and overlay_bytes[i - 1] == 0:
				opaque_background = true
		overlay_ok = non_transparent > 0 and not opaque_background
	var passed := unchanged and deterministic and palette_independent and intervals_ok and overlay_ok
	print("[Milestone6] raw_unchanged=", unchanged, " deterministic=", deterministic,
		" palette_only_changes_render=", palette_independent, " contours=", intervals_ok,
		" overlay=", overlay_ok)
	get_tree().quit(0 if passed else 1)
