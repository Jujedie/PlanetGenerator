class_name PGRuntimeDataWriter
extends RefCounted

## Persists a compact, query-oriented subset of the authoritative monolithic
## GPU state. These files are intentionally not presentation maps: they keep
## exact scalar/categorical values so a host game can query generated cells
## after the RenderingDevice resources have been released.

const VERSION := 1
const DIRECTORY_NAME := "runtime_data"
const MANIFEST_FILE := "runtime_data_manifest.json"
const NO_DATA_U32 := 0xFFFFFFFF

var _output_root: String = ""
var _data_root: String = ""
var _dimensions: Vector2i = Vector2i.ZERO
var _params: Dictionary = {}
var _layers: Dictionary = {}
var _started: bool = false


func begin(output_root: String, dimensions: Vector2i, generation_params: Dictionary) -> bool:
	_output_root = output_root.simplify_path()
	_data_root = _output_root.path_join(DIRECTORY_NAME)
	_dimensions = dimensions
	_params = generation_params.duplicate(true)
	_layers.clear()
	_started = false
	if _output_root.is_empty() or dimensions.x <= 0 or dimensions.y <= 0:
		return false
	remove_existing(_output_root)
	var err := DirAccess.make_dir_recursive_absolute(_data_root)
	if err != OK and not DirAccess.dir_exists_absolute(_data_root):
		push_error("[PGRuntimeDataWriter] Unable to create runtime data directory: " + _data_root)
		return false
	_started = true
	return true


func write_height_from_geo(geo_rgba32f: PackedByteArray) -> bool:
	if not _started:
		return false
	var pixel_count := _dimensions.x * _dimensions.y
	if geo_rgba32f.size() != pixel_count * 16:
		push_warning("[PGRuntimeDataWriter] Invalid geo payload; height runtime layer skipped")
		return false
	var output := PackedByteArray()
	output.resize(pixel_count * 4)
	for index in range(pixel_count):
		output.encode_float(index * 4, geo_rgba32f.decode_float(index * 16))
	return _write_layer(
		"surface_elevation_m",
		"surface_elevation.r32f",
		output,
		4,
		"R32F metres in generator elevation datum"
	)


func write_climate_from_rgba32f(climate_rgba32f: PackedByteArray) -> bool:
	if not _started:
		return false
	var pixel_count := _dimensions.x * _dimensions.y
	if climate_rgba32f.size() != pixel_count * 16:
		push_warning("[PGRuntimeDataWriter] Invalid climate payload; climate runtime layers skipped")
		return false
	var temperature := PackedByteArray()
	var precipitation := PackedByteArray()
	temperature.resize(pixel_count * 4)
	precipitation.resize(pixel_count * 4)
	for index in range(pixel_count):
		var source_offset := index * 16
		temperature.encode_float(index * 4, climate_rgba32f.decode_float(source_offset))
		precipitation.encode_float(index * 4, climate_rgba32f.decode_float(source_offset + 4))
	var temperature_ok := _write_layer(
		"temperature_c",
		"temperature.r32f",
		temperature,
		4,
		"R32F degrees Celsius"
	)
	var precipitation_ok := _write_layer(
		"precipitation",
		"precipitation.r32f",
		precipitation,
		4,
		"R32F normalized humidity/precipitation 0..1"
	)
	return temperature_ok and precipitation_ok


func write_u32_layer(layer_key: String, filename: String, payload: PackedByteArray,
		description: String) -> bool:
	if not _started:
		return false
	var expected := _dimensions.x * _dimensions.y * 4
	if payload.size() != expected:
		return false
	return _write_layer(layer_key, filename, payload, 4, description)


func write_u8_layer(layer_key: String, filename: String, payload: PackedByteArray,
		description: String) -> bool:
	if not _started:
		return false
	var expected := _dimensions.x * _dimensions.y
	if payload.size() != expected:
		return false
	return _write_layer(layer_key, filename, payload, 1, description)


func finish() -> String:
	if not _started or _layers.is_empty():
		return ""
	var planet_type := int(_params.get("planet_type", 0))
	var manifest := {
		"runtime_data_version": VERSION,
		"generator_version": PGAddonInfo.VERSION,
		"dimensions": [_dimensions.x, _dimensions.y],
		"projection": str(_params.get("projection", PGPlanetGridContract.PROJECTION_ID)),
		"sea_level_m": float(_params.get("sea_level", 0.0)),
		"planet_type": planet_type,
		"horizontal_wrap": true,
		"vertical_policy": "clamp",
		"layers": _layers,
		"water_types": {
			"0": "land",
			"1": "saltwater",
			"2": "freshwater",
		},
		"biomes": _build_biome_table(PGPlanetData.get_biomes_for_gpu(planet_type), false),
		"river_biomes": _build_biome_table(PGPlanetData.get_river_biomes_for_gpu(planet_type), true),
	}
	var path := _data_root.path_join(MANIFEST_FILE)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[PGRuntimeDataWriter] Unable to write runtime data manifest: " + path)
		return ""
	file.store_string(JSON.stringify(manifest, "  ", true))
	file.close()
	PGFileChecksumCache.invalidate(path)
	return path


func _write_layer(layer_key: String, filename: String, payload: PackedByteArray,
		bytes_per_cell: int, format_description: String) -> bool:
	if payload.is_empty():
		return false
	var path := _data_root.path_join(filename)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[PGRuntimeDataWriter] Unable to write runtime layer: " + path)
		return false
	file.store_buffer(payload)
	file.close()
	_layers[layer_key] = {
		"path": DIRECTORY_NAME.path_join(filename),
		"format": format_description,
		"bytes_per_cell": bytes_per_cell,
		"byte_size": payload.size(),
	}
	return true


static func remove_existing(output_root: String) -> void:
	var path := output_root.simplify_path().path_join(DIRECTORY_NAME)
	if not DirAccess.dir_exists_absolute(path):
		return
	_remove_tree(path)


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


static func _build_biome_table(source: Array, is_river: bool) -> Array:
	var result: Array = []
	for index in range(source.size()):
		var biome := source[index] as PGBiome
		if biome == null:
			# Preserve GPU ID -> table index alignment even if a malformed source
			# unexpectedly contains a null entry.
			result.append({})
			continue
		result.append({
			"id": index,
			"name": biome.get_nom(),
			"translation_key": PGPlanetData.get_biome_translation_key(biome),
			"color": biome.get_couleur().to_html(true),
			"vegetation_color": biome.get_couleur_vegetation().to_html(true),
			"is_river": is_river,
			"water_required": biome.get_water_need(),
			"freshwater_only": biome.isEauDouce(),
		})
	return result
