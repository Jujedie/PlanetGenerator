class_name CartographicPalette
extends RefCounted

const DEFAULT_PATH := "res://data/cartography/default_palette.json"

var name := "Military Topographic"
var version := 1
var terrain_stops: Array = []
var saltwater := Color8(37, 88, 143)
var freshwater := Color8(61, 120, 174)
var coastline := Color8(23, 32, 25)
var minor_contour := Color8(43, 49, 40)
var major_contour := Color8(17, 22, 16)
var grid := Color8(213, 210, 189)
var marker := Color8(241, 227, 162)
var hillshade_strength := 0.24
var biome_modulation_strength := 0.08

static func load_palette(path: String = DEFAULT_PATH) -> CartographicPalette:
	var palette := CartographicPalette.new()
	if not FileAccess.file_exists(path):
		palette._set_fallback_stops()
		return palette
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		palette._set_fallback_stops()
		return palette
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		palette._set_fallback_stops()
		return palette
	palette.name = str(parsed.get("name", palette.name))
	palette.version = int(parsed.get("version", palette.version))
	palette.saltwater = _hex_color(str(parsed.get("saltwater", "25588f")))
	palette.freshwater = _hex_color(str(parsed.get("freshwater", "3d78ae")))
	palette.coastline = _hex_color(str(parsed.get("coastline", "172019")))
	palette.minor_contour = _hex_color(str(parsed.get("minor_contour", "2b3128")))
	palette.major_contour = _hex_color(str(parsed.get("major_contour", "111610")))
	palette.grid = _hex_color(str(parsed.get("grid", "d5d2bd")))
	palette.marker = _hex_color(str(parsed.get("marker", "f1e3a2")))
	palette.hillshade_strength = clampf(float(parsed.get("hillshade_strength", 0.24)), 0.0, 1.0)
	palette.biome_modulation_strength = clampf(float(parsed.get("biome_modulation_strength", 0.08)), 0.0, 0.5)
	for stop_value in parsed.get("terrain", []):
		if stop_value is Array and stop_value.size() >= 2:
			palette.terrain_stops.append([float(stop_value[0]), _hex_color(str(stop_value[1]))])
	palette.terrain_stops.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	if palette.terrain_stops.is_empty():
		palette._set_fallback_stops()
	return palette

func color_for_elevation(height_m: float) -> Color:
	if terrain_stops.is_empty():
		_set_fallback_stops()
	if height_m <= float(terrain_stops[0][0]):
		return terrain_stops[0][1]
	if height_m >= float(terrain_stops[-1][0]):
		return terrain_stops[-1][1]
	for index in range(1, terrain_stops.size()):
		var upper: Array = terrain_stops[index]
		if height_m <= float(upper[0]):
			var lower: Array = terrain_stops[index - 1]
			var span := maxf(float(upper[0]) - float(lower[0]), 0.000001)
			var t := clampf((height_m - float(lower[0])) / span, 0.0, 1.0)
			return (lower[1] as Color).lerp(upper[1], t)
	return terrain_stops[-1][1]

func _set_fallback_stops() -> void:
	terrain_stops = [
		[-9000.0, Color8(23, 48, 71)], [0.0, Color8(111, 130, 82)],
		[1500.0, Color8(154, 128, 100)], [5000.0, Color8(177, 170, 162)],
		[8000.0, Color8(230, 228, 223)],
	]

static func _hex_color(value: String) -> Color:
	var clean := value.strip_edges().trim_prefix("#")
	if clean.length() == 6:
		clean += "ff"
	return Color.from_string("#" + clean, Color.MAGENTA)
