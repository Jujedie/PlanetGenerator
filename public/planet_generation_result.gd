class_name PlanetGenerationResult
extends RefCounted

## Immutable-ish handle returned by a completed generation job. It exposes the
## generated project without requiring access to GPU RIDs or the standalone UI.
##
## Addon API v2 also exposes exact cell queries backed by compact runtime data
## persisted before the generation worker releases its RenderingDevice state.

const WATER_LAND := 0
const WATER_SALTWATER := 1
const WATER_FRESHWATER := 2
const INVALID_ID := -1

var planet_id: String = ""
var planet_name: String = ""
var output_root: String = ""
var generator_version: String = PGAddonInfo.VERSION
var parameters: Dictionary = {}
var exported_files: Dictionary = {}
var layers: Dictionary = {}
var display_maps: Array[String] = []
var performance_report: Dictionary = {}
var export_metrics: Dictionary = {}
var project_manifest: Dictionary = {}
var planet_manifest: Dictionary = {}
var warnings: Array[String] = []

var _image_cache: Dictionary = {}
var _runtime_reader: PGRuntimeDataReader = null
var _runtime_reader_attempted: bool = false


static func from_generation(id: String, root: String, params: Dictionary,
		exports: Dictionary, performance: Dictionary, metrics: Dictionary,
		generation_warnings: Array[String] = []) -> PlanetGenerationResult:
	var result := PlanetGenerationResult.new()
	result.planet_id = id
	result.output_root = root
	result.parameters = params.duplicate(true)
	result.planet_name = str(params.get("planet_name", "Generated Planet"))
	result.exported_files = exports.duplicate(true)
	result.performance_report = performance.duplicate(true)
	result.export_metrics = metrics.duplicate(true)
	result.warnings = generation_warnings.duplicate()
	result._hydrate_manifests()
	return result


static func load_existing(path_or_directory: String) -> PlanetGenerationResult:
	var loaded := PGPlanetProject.load_project(path_or_directory)
	if not bool(loaded.get("ok", false)):
		return null
	var result := PlanetGenerationResult.new()
	result.output_root = str(loaded.get("root", path_or_directory))
	result.project_manifest = (loaded.get("manifest", {}) as Dictionary).duplicate(true)
	result.layers = (loaded.get("layers", {}) as Dictionary).duplicate(true)
	result.display_maps.clear()
	for map_value in loaded.get("maps", []):
		result.display_maps.append(str(map_value))
	result.planet_name = str(result.project_manifest.get("planet_name", "Generated Planet"))
	result.generator_version = str(result.project_manifest.get("generator_version", "unknown"))
	result.parameters = (result.project_manifest.get("parameters", {}) as Dictionary).duplicate(true)
	result.planet_id = result.output_root.get_file()
	result._load_planet_manifest()
	return result


func has_layer(layer_key: String) -> bool:
	return not get_layer_path(layer_key).is_empty()


func get_grid_dimensions() -> Vector2i:
	var reader := _get_runtime_reader()
	if reader != null and reader.is_ready():
		return reader.dimensions
	var grid: Variant = planet_manifest.get("grid", {})
	if grid is Dictionary:
		var dimensions: Variant = (grid as Dictionary).get("dimensions", [])
		if dimensions is Array and dimensions.size() >= 2:
			return Vector2i(int(dimensions[0]), int(dimensions[1]))
	var direct: Variant = parameters.get("global_dimensions", parameters.get("resolution", Vector2i.ZERO))
	if direct is Vector2i:
		return direct as Vector2i
	if direct is Array and direct.size() >= 2:
		return Vector2i(int(direct[0]), int(direct[1]))
	return Vector2i.ZERO


func get_tile_count(tile_size: int = PGPlanetGridContract.DEFAULT_TILE_SIZE) -> Vector2i:
	var dimensions := get_grid_dimensions()
	if dimensions.x <= 0 or dimensions.y <= 0:
		return Vector2i.ZERO
	return PGPlanetGridContract.tile_grid_dimensions(dimensions, tile_size)


func get_layer_keys() -> Array[String]:
	var keys: Array[String] = []
	for key_value in layers.keys():
		keys.append(str(key_value))
	keys.sort()
	return keys


func get_layer_path(layer_key: String) -> String:
	if layers.has(layer_key):
		return str(layers[layer_key])
	if exported_files.has(layer_key):
		return str(exported_files[layer_key])
	return ""


func load_layer_image(layer_key: String, use_cache: bool = true) -> Image:
	var path := get_layer_path(layer_key)
	if path.is_empty() or path.get_extension().to_lower() != "png":
		return null
	if use_cache and _image_cache.has(path):
		return _image_cache[path]
	var image := Image.new()
	if image.load(path) != OK:
		return null
	if use_cache:
		_image_cache[path] = image
	return image


func load_layer_texture(layer_key: String, use_cache: bool = true) -> Texture2D:
	var image := load_layer_image(layer_key, use_cache)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)


func sample_layer_color(layer_key: String, global_cell: Vector2i) -> Color:
	var image := load_layer_image(layer_key)
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		return Color(0, 0, 0, 0)
	var cell := Vector2i(posmod(global_cell.x, image.get_width()), clampi(global_cell.y, 0, image.get_height() - 1))
	return image.get_pixelv(cell)


func extract_global_tile(layer_key: String, tile: Vector2i,
		tile_size: int = PGPlanetGridContract.DEFAULT_TILE_SIZE) -> Image:
	var source := load_layer_image(layer_key)
	if source == null:
		return null
	var dimensions := source.get_size()
	var rect := PGPlanetGridContract.tile_rect(tile, dimensions, tile_size)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return null
	return source.get_region(rect)


func read_tiled_payload(layer_key: String, lod: int, tile: Vector2i) -> PackedByteArray:
	var tiled_root := str(exported_files.get("tiled_dataset", ""))
	if tiled_root.is_empty() and layers.has("tiled_dataset"):
		tiled_root = str(layers["tiled_dataset"])
	if tiled_root.is_empty():
		return PackedByteArray()
	var store := PGPlanetTileStore.new(tiled_root)
	return store.read_tile(layer_key, lod, tile)


# ---------------------------------------------------------------------------
# Exact runtime cell-query API
# ---------------------------------------------------------------------------

## Returns true when exact scalar/categorical runtime data was persisted for
## this planet. Outputs created by addon.3 or older can still expose PNG layers,
## but exact height/climate/region getters are unavailable for those projects.
func has_runtime_data() -> bool:
	return _get_runtime_reader() != null


func get_runtime_data_layers() -> Array[String]:
	var reader := _get_runtime_reader()
	if reader != null:
		return reader.get_layer_keys()
	var empty: Array[String] = []
	return empty


func get_runtime_data_manifest() -> Dictionary:
	var reader := _get_runtime_reader()
	return reader.manifest.duplicate(true) if reader != null else {}


## Exact generated surface elevation in the generator's absolute elevation
## datum. Use get_height_at() for the more intuitive metres relative to the
## configured sea level.
func get_surface_elevation_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	var value := _read_runtime_f32("surface_elevation_m", global_cell)
	return float(value) if value != null else default_value


## Elevation in metres relative to the configured sea level. Negative values
## are below sea level; positive values are above it.
func get_height_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	var value := _read_runtime_f32("surface_elevation_m", global_cell)
	if value == null:
		return default_value
	return float(value) - get_sea_level_m()


## Alias for get_height_at().
func get_elevation_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	return get_height_at(global_cell, default_value)


func get_sea_level_m() -> float:
	var reader := _get_runtime_reader()
	if reader != null:
		return reader.get_sea_level_m()
	return float(parameters.get("sea_level", 0.0))


## Temperature in degrees Celsius.
func get_temperature_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	var value := _read_runtime_f32("temperature_c", global_cell)
	return float(value) if value != null else default_value


## Normalized precipitation/humidity field generated by the climate pipeline
## (0.0 dry -> 1.0 wet). This is the same climate.g value used by biome and
## hydrology shaders; it is not millimetres of rainfall.
func get_precipitation_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	var value := _read_runtime_f32("precipitation", global_cell)
	return float(value) if value != null else default_value


## Alias because the current generator uses the same normalized climate.g
## channel as both its humidity and precipitation proxy.
func get_humidity_at(global_cell: Vector2i, default_value: float = NAN) -> float:
	return get_precipitation_at(global_cell, default_value)


func get_water_type_at(global_cell: Vector2i) -> int:
	var reader := _get_runtime_reader()
	if reader == null:
		return INVALID_ID
	var value := reader.read_u8("water_type", global_cell)
	return int(value) if value != null else INVALID_ID


func is_water_at(global_cell: Vector2i) -> bool:
	return get_water_type_at(global_cell) in [WATER_SALTWATER, WATER_FRESHWATER]


func get_water_at(global_cell: Vector2i) -> Dictionary:
	var water_type := get_water_type_at(global_cell)
	if water_type == INVALID_ID:
		return {
			"available": false,
			"type": INVALID_ID,
			"name": "unknown",
			"is_water": false,
			"is_saltwater": false,
			"is_freshwater": false,
		}
	return {
		"available": true,
		"type": water_type,
		"name": _water_type_name(water_type),
		"is_water": water_type != WATER_LAND,
		"is_saltwater": water_type == WATER_SALTWATER,
		"is_freshwater": water_type == WATER_FRESHWATER,
	}


## Ground biome ID. This ID indexes the planet-specific non-river biome table.
func get_biome_id_at(global_cell: Vector2i) -> int:
	return _read_runtime_id("biome_id", global_cell)


## River biome ID, or -1 when no river biome is present on the queried cell.
func get_river_biome_id_at(global_cell: Vector2i) -> int:
	return _read_runtime_id("river_biome_id", global_cell)


func get_ground_biome_at(global_cell: Vector2i) -> Dictionary:
	var reader := _get_runtime_reader()
	if reader != null:
		var biome_id := get_biome_id_at(global_cell)
		if biome_id >= 0:
			return _decorate_biome_info(reader.get_biome_info(biome_id, false))

	# Compatibility fallback for older generated projects: biome PNG color can
	# recover the categorical biome name, but it does not provide exact climate
	# or elevation data.
	var color := sample_layer_color("biome_colored", global_cell)
	if color.a <= 0.0:
		return {}
	var planet_type := int(parameters.get("planet_type", 0))
	var biome := PGPlanetData.find_biome_by_map_color(color, planet_type, 0)
	if biome == null:
		return {}
	var filtered := PGPlanetData.get_biomes_for_gpu(planet_type)
	return _biome_object_to_info(biome, filtered.find(biome), false)


func get_river_biome_at(global_cell: Vector2i) -> Dictionary:
	var reader := _get_runtime_reader()
	if reader != null:
		var biome_id := get_river_biome_id_at(global_cell)
		if biome_id >= 0:
			return _decorate_biome_info(reader.get_biome_info(biome_id, true))

	var color := sample_layer_color("river_map", global_cell)
	if color.a <= 0.0:
		return {}
	var planet_type := int(parameters.get("planet_type", 0))
	var biome := PGPlanetData.find_biome_by_map_color(color, planet_type, 1)
	if biome == null:
		return {}
	var filtered := PGPlanetData.get_river_biomes_for_gpu(planet_type)
	return _biome_object_to_info(biome, filtered.find(biome), true)


## Surface biome visible to gameplay. A river biome takes precedence when a
## river is present; otherwise the underlying ground/water biome is returned.
func get_biome_at(global_cell: Vector2i, include_river: bool = true) -> Dictionary:
	if include_river:
		var river := get_river_biome_at(global_cell)
		if not river.is_empty():
			return river
	return get_ground_biome_at(global_cell)


## Canonical biome name for gameplay/serialization. Returns an empty string when
## no biome can be resolved. Use get_biome_display_name_at() for localization.
func get_biome_name_at(global_cell: Vector2i, include_river: bool = true) -> String:
	var biome := get_biome_at(global_cell, include_river)
	return str(biome.get("name", ""))


## Localized biome name when a translation exists, otherwise the canonical name.
func get_biome_display_name_at(global_cell: Vector2i, include_river: bool = true) -> String:
	var biome := get_biome_at(global_cell, include_river)
	return str(biome.get("display_name", biome.get("name", "")))


## Base land administrative ID (department/lowest land hierarchy level).
## Returns -1 on water or when the layer is unavailable.
func get_region_id_at(global_cell: Vector2i) -> int:
	return _read_runtime_id("region_id", global_cell)


func get_region_at(global_cell: Vector2i) -> int:
	return get_region_id_at(global_cell)


## Base ocean administrative ID. Returns -1 on land or when unavailable.
func get_ocean_region_id_at(global_cell: Vector2i) -> int:
	return _read_runtime_id("ocean_region_id", global_cell)


func get_ocean_region_at(global_cell: Vector2i) -> int:
	return get_ocean_region_id_at(global_cell)


## Returns the main gameplay-relevant values for one global map cell in a
## single dictionary. Exact scalar fields require runtime query data.
func get_cell_data(global_cell: Vector2i, include_river_biome: bool = true) -> Dictionary:
	var dimensions := get_grid_dimensions()
	if dimensions.x <= 0 or dimensions.y <= 0:
		return {"available": false, "cell": global_cell}
	var cell := PGPlanetGridContract.wrapped_global_cell(global_cell, dimensions)
	var lon_lat := PGPlanetGridContract.global_cell_to_world(cell, dimensions)
	var ground_biome := get_ground_biome_at(cell)
	var river_biome := get_river_biome_at(cell) if include_river_biome else {}
	var surface_biome := river_biome if not river_biome.is_empty() else ground_biome
	var water := get_water_at(cell)
	var biome_id := int(surface_biome.get("id", INVALID_ID))
	var biome_name := str(surface_biome.get("name", ""))
	var biome_display_name := str(surface_biome.get("display_name", biome_name))
	return {
		"available": true,
		"runtime_data_available": has_runtime_data(),
		"cell": cell,
		"longitude_radians": lon_lat.x,
		"latitude_radians": lon_lat.y,
		"surface_elevation_m": get_surface_elevation_at(cell),
		"height_m": get_height_at(cell),
		"sea_level_m": get_sea_level_m(),
		"temperature_c": get_temperature_at(cell),
		"precipitation": get_precipitation_at(cell),
		"humidity": get_humidity_at(cell),
		"water": water,
		"water_type": int(water.get("type", INVALID_ID)),
		"biome": surface_biome,
		"biome_id": biome_id,
		"biome_name": biome_name,
		"biome_display_name": biome_display_name,
		"ground_biome": ground_biome,
		"ground_biome_id": int(ground_biome.get("id", INVALID_ID)),
		"river_biome": river_biome,
		"river_biome_id": int(river_biome.get("id", INVALID_ID)),
		"region_id": get_region_id_at(cell),
		"ocean_region_id": get_ocean_region_id_at(cell),
	}


func clear_image_cache() -> void:
	_image_cache.clear()


func clear_runtime_data_cache() -> void:
	if _runtime_reader != null:
		_runtime_reader.close()
	_runtime_reader = null
	_runtime_reader_attempted = false


func clear_caches() -> void:
	clear_image_cache()
	clear_runtime_data_cache()


func _hydrate_manifests() -> void:
	var project := PGPlanetProject.load_project(output_root)
	if bool(project.get("ok", false)):
		project_manifest = (project.get("manifest", {}) as Dictionary).duplicate(true)
		layers = (project.get("layers", {}) as Dictionary).duplicate(true)
		display_maps.clear()
		for path_value in project.get("maps", []):
			display_maps.append(str(path_value))
	else:
		# Generation can still return a useful result if a minimal/experimental
		# path did not produce planet_project.json.
		for key_value in exported_files.keys():
			var path := str(exported_files[key_value])
			if path.get_extension().to_lower() == "png" and FileAccess.file_exists(path):
				layers[str(key_value)] = path
			elif key_value == "runtime_data_manifest" and FileAccess.file_exists(path):
				layers[str(key_value)] = path
		display_maps = PGPlanetProject.display_maps_from_layers(layers)
	_load_planet_manifest()


func _load_planet_manifest() -> void:
	var path := output_root.path_join("planet_manifest.json")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		planet_manifest = (parsed as Dictionary).duplicate(true)


func _get_runtime_reader() -> PGRuntimeDataReader:
	if _runtime_reader != null and _runtime_reader.is_ready():
		return _runtime_reader
	if _runtime_reader_attempted:
		return null
	_runtime_reader_attempted = true
	var explicit_manifest := get_layer_path("runtime_data_manifest")
	var reader := PGRuntimeDataReader.new()
	if not reader.open(output_root, explicit_manifest):
		return null
	_runtime_reader = reader
	return _runtime_reader


func _read_runtime_f32(layer_key: String, global_cell: Vector2i) -> Variant:
	var reader := _get_runtime_reader()
	return reader.read_f32(layer_key, global_cell) if reader != null else null


func _read_runtime_id(layer_key: String, global_cell: Vector2i) -> int:
	var reader := _get_runtime_reader()
	if reader == null:
		return INVALID_ID
	var value := reader.read_u32(layer_key, global_cell)
	if value == null:
		return INVALID_ID
	var raw_id := int(value)
	return INVALID_ID if raw_id == PGRuntimeDataReader.NO_DATA_U32 else raw_id


func _decorate_biome_info(info: Dictionary) -> Dictionary:
	if info.is_empty():
		return info
	var result := info.duplicate(true)
	var canonical_name := str(result.get("name", ""))
	var translation_key := str(result.get("translation_key", canonical_name))
	var translated := str(TranslationServer.translate(translation_key))
	result["display_name"] = canonical_name if translated == translation_key else translated
	return result


func _biome_object_to_info(biome: PGBiome, biome_id: int, is_river: bool) -> Dictionary:
	if biome == null:
		return {}
	return _decorate_biome_info({
		"id": biome_id,
		"name": biome.get_nom(),
		"translation_key": PGPlanetData.get_biome_translation_key(biome),
		"color": biome.get_couleur().to_html(true),
		"vegetation_color": biome.get_couleur_vegetation().to_html(true),
		"is_river": is_river,
		"water_required": biome.get_water_need(),
		"freshwater_only": biome.isEauDouce(),
	})


func _water_type_name(water_type: int) -> String:
	match water_type:
		WATER_LAND:
			return "land"
		WATER_SALTWATER:
			return "saltwater"
		WATER_FRESHWATER:
			return "freshwater"
		_:
			return "unknown"
