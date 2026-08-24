class_name LocalZoneDebugExporter
extends RefCounted

## Optional PNG previews for inspecting M7 authoritative local layers. These
## files are visualization only and are never read back by the generator.

static func build_previews(zone: Dictionary) -> Dictionary:
	var images: Dictionary = zone.get("images", {})
	if images.is_empty():
		return {}
	return {
		"height": _height_preview(images.get("height")),
		"normals": _rgba_preview(images.get("normals")),
		"slope": _float_range_preview(images.get("slope"), Color8(35, 42, 38), Color8(229, 170, 58)),
		"water": _water_preview(images.get("water_mask"), images.get("water_depth")),
		"flow": _rgba_preview(images.get("flow")),
		"soil": _id_preview(images.get("soil_type"), _soil_colors()),
		"soil_moisture": _scalar_preview(images.get("soil_moisture"), Color8(142, 102, 58), Color8(48, 116, 177)),
		"soil_depth": _float_range_preview(images.get("soil_depth"), Color8(71, 62, 52), Color8(194, 159, 101)),
		"rock": _id_preview(images.get("rock_type"), _rock_colors()),
		"surface": _id_preview(images.get("surface_material"), _surface_colors()),
		"vegetation": _scalar_preview(images.get("vegetation_density"), Color8(35, 46, 31), Color8(75, 164, 62)),
		"resources": _rgba_preview(images.get("resources")),
		"snow_ice": _scalar_preview(images.get("snow_ice"), Color8(25, 35, 48), Color8(230, 242, 250)),
		"spawn": _scalar_preview(images.get("spawn_mask"), Color8(52, 43, 38), Color8(95, 190, 92)),
		"hazard": _scalar_preview(images.get("hazard"), Color8(36, 45, 31), Color8(211, 74, 54)),
	}

static func export_previews(zone: Dictionary, output_dir: String) -> Dictionary:
	var previews := build_previews(zone)
	if previews.is_empty():
		return {}
	DirAccess.make_dir_recursive_absolute(output_dir)
	var result: Dictionary = {}
	for name in previews.keys():
		var image: Image = previews[name]
		if image == null or image.is_empty():
			continue
		var path := output_dir.path_join("local_%s.png" % name)
		if image.save_png(path) == OK:
			result[name] = path
	return result

static func _height_preview(source_value) -> Image:
	if not source_value is Image:
		return null
	var source: Image = source_value
	var w := source.get_width()
	var h := source.get_height()
	var minimum := INF
	var maximum := -INF
	for y in range(h):
		for x in range(w):
			var value := source.get_pixel(x, y).r
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
	var output := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var span := maxf(maximum - minimum, 0.000001)
	for y in range(h):
		for x in range(w):
			var t := clampf((source.get_pixel(x, y).r - minimum) / span, 0.0, 1.0)
			output.set_pixel(x, y, Color(t, t, t, 1.0))
	return output

static func _water_preview(mask_value, depth_value) -> Image:
	if not mask_value is Image or not depth_value is Image:
		return null
	var mask: Image = mask_value
	var depth: Image = depth_value
	var output := Image.create(mask.get_width(), mask.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(mask.get_height()):
		for x in range(mask.get_width()):
			var kind := roundi(mask.get_pixel(x, y).r * 255.0)
			var d := depth.get_pixel(x, y).r
			var color := Color8(30, 34, 28)
			if kind == 1:
				color = Color8(32, 86, 143).darkened(clampf(d / 30.0, 0.0, 0.35))
			elif kind == 2:
				color = Color8(62, 126, 183)
			elif kind == 3:
				color = Color8(57, 151, 202)
			output.set_pixel(x, y, color)
	return output

static func _id_preview(source_value, colors: Array[Color]) -> Image:
	if not source_value is Image:
		return null
	var source: Image = source_value
	var output := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(source.get_height()):
		for x in range(source.get_width()):
			var id := clampi(roundi(source.get_pixel(x, y).r * 255.0), 0, colors.size() - 1)
			output.set_pixel(x, y, colors[id])
	return output

static func _scalar_preview(source_value, low: Color, high: Color) -> Image:
	if not source_value is Image:
		return null
	var source: Image = source_value
	var output := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(source.get_height()):
		for x in range(source.get_width()):
			output.set_pixel(x, y, low.lerp(high, source.get_pixel(x, y).r))
	return output

static func _float_range_preview(source_value, low: Color, high: Color) -> Image:
	if not source_value is Image:
		return null
	var source: Image = source_value
	var minimum := INF
	var maximum := -INF
	for y in range(source.get_height()):
		for x in range(source.get_width()):
			var value := source.get_pixel(x, y).r
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
	var span := maxf(maximum - minimum, 0.000001)
	var output := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(source.get_height()):
		for x in range(source.get_width()):
			var t := clampf((source.get_pixel(x, y).r - minimum) / span, 0.0, 1.0)
			output.set_pixel(x, y, low.lerp(high, t))
	return output

static func _rgba_preview(source_value) -> Image:
	if not source_value is Image:
		return null
	var source: Image = source_value
	var output := source.duplicate()
	if output.get_format() != Image.FORMAT_RGBA8:
		output.convert(Image.FORMAT_RGBA8)
	return output

static func _soil_colors() -> Array[Color]:
	return [
		Color8(91, 91, 86), Color8(126, 117, 101), Color8(207, 185, 126),
		Color8(113, 83, 55), Color8(143, 99, 76), Color8(125, 107, 76),
		Color8(75, 63, 43), Color8(83, 69, 59), Color8(157, 146, 126), Color8(219, 211, 176),
	]

static func _rock_colors() -> Array[Color]:
	return [
		Color8(92, 91, 86), Color8(120, 106, 90), Color8(82, 87, 91),
		Color8(100, 91, 103), Color8(80, 68, 62), Color8(157, 146, 126),
	]

static func _surface_colors() -> Array[Color]:
	return [
		Color8(92, 94, 89), Color8(132, 124, 108), Color8(217, 194, 132),
		Color8(120, 88, 58), Color8(83, 66, 48), Color8(83, 133, 63),
		Color8(65, 83, 47), Color8(72, 65, 44), Color8(218, 210, 176),
		Color8(230, 235, 237), Color8(195, 220, 235), Color8(63, 137, 185), Color8(31, 82, 136),
	]
