class_name GlobalMacroSampler
extends RefCounted

## Read-only bridge between the global planet and high-resolution local zones.
## Administrative layers are intentionally absent. Climate/plates/river data are
## consumed only as physical macro constraints and are never copied as local maps.

var dimensions := Vector2i.ZERO
var generation_params: Dictionary = {}

var geo_data := PackedByteArray()       # monolithic RGBA32F
var height_data := PackedByteArray()    # tiled R32F
var water_data := PackedByteArray()     # R8UI
var biome_data := PackedByteArray()     # R32UI
var climate_data := PackedByteArray()   # monolithic RGBA32F or tiled RG32F
var river_flux_data := PackedByteArray()# R32F
var flow_data := PackedByteArray()      # tiled R8UI when available
var plates_data := PackedByteArray()    # monolithic RGBA32F or tiled R32UI
var resources_data := PackedByteArray() # RGBA8

var tile_store: PlanetTileStore = null
var tile_reader: TileWindowReader = null
var tiled := false

static func from_gpu(gpu: GPUContext, params: Dictionary) -> GlobalMacroSampler:
	if gpu == null or gpu.rd == null or not gpu.textures.has("geo") or not gpu.textures["geo"].is_valid():
		return null
	var format = gpu.rd.texture_get_format(gpu.textures["geo"])
	var sampler := GlobalMacroSampler.new()
	sampler.dimensions = Vector2i(format.width, format.height)
	sampler.generation_params = params.duplicate(true)
	for entry in [
		["geo", "geo_data"], ["water_mask", "water_data"],
		["biome_id", "biome_data"], ["climate", "climate_data"],
		["river_flux", "river_flux_data"], ["flow_direction", "flow_data"],
		["plates", "plates_data"], ["resources", "resources_data"],
	]:
		var texture_name: String = entry[0]
		if gpu.textures.has(texture_name) and gpu.textures[texture_name].is_valid():
			sampler.set(entry[1], gpu.readback_texture_raw(texture_name))
	return sampler

static func from_tiled_dataset(root_dir: String, params: Dictionary) -> GlobalMacroSampler:
	var sampler := GlobalMacroSampler.new()
	sampler.dimensions = params.get("global_dimensions", params.get("resolution", Vector2i.ZERO))
	if sampler.dimensions.x <= 0 or sampler.dimensions.y <= 0:
		return null
	sampler.generation_params = params.duplicate(true)
	var tile_size := int(params.get("tile_size", PlanetGridContract.DEFAULT_TILE_SIZE))
	sampler.tile_store = PlanetTileStore.new(root_dir)
	sampler.tile_reader = TileWindowReader.new(sampler.tile_store, sampler.dimensions, tile_size)
	sampler.tiled = true
	# Height is the only mandatory layer. The rest gracefully degrade so old
	# datasets can still generate terrain-local detail.
	var first := sampler.tile_store.read_tile("height", 0, Vector2i.ZERO)
	if first.is_empty():
		return null
	return sampler

static func from_raw(global_dimensions: Vector2i, geo: PackedByteArray,
		water: PackedByteArray, biome: PackedByteArray,
		climate: PackedByteArray = PackedByteArray(),
		river_flux: PackedByteArray = PackedByteArray(),
		plates: PackedByteArray = PackedByteArray(), params: Dictionary = {}) -> GlobalMacroSampler:
	var sampler := GlobalMacroSampler.new()
	sampler.dimensions = global_dimensions
	sampler.geo_data = geo
	sampler.water_data = water
	sampler.biome_data = biome
	sampler.climate_data = climate
	sampler.river_flux_data = river_flux
	sampler.plates_data = plates
	sampler.generation_params = params.duplicate(true)
	return sampler

func is_valid() -> bool:
	if dimensions.x <= 0 or dimensions.y <= 0:
		return false
	if tiled:
		return tile_reader != null
	var pixels := dimensions.x * dimensions.y
	return geo_data.size() == pixels * 16 or height_data.size() == pixels * 4

func sample(cell: Vector2i) -> Dictionary:
	if not is_valid():
		return {}
	var canonical := PlanetGridContract.wrapped_global_cell(cell, dimensions)
	if tiled:
		return _sample_tiled(canonical)
	return _sample_raw(canonical)

func _sample_tiled(cell: Vector2i) -> Dictionary:
	var height_payload := tile_reader.read_window("height", 0, cell, Vector2i.ONE, 4)
	if height_payload.size() != 4:
		return {}
	var climate := tile_reader.read_window("climate", 0, cell, Vector2i.ONE, 8)
	var water := tile_reader.read_window("water_mask", 0, cell, Vector2i.ONE, 1)
	var biome := tile_reader.read_window("biome_id", 0, cell, Vector2i.ONE, 4)
	var flux := tile_reader.read_window("river_flux", 0, cell, Vector2i.ONE, 4)
	var flow := tile_reader.read_window("flow_direction", 0, cell, Vector2i.ONE, 1)
	var plate := tile_reader.read_window("plates", 0, cell, Vector2i.ONE, 4)
	var resources := tile_reader.read_window("resources", 0, cell, Vector2i.ONE, 4)
	return {
		"cell": cell,
		"height_m": height_payload.decode_float(0),
		"water_type": int(water[0]) if water.size() == 1 else 0,
		"biome_id": int(biome.decode_u32(0)) if biome.size() == 4 else -1,
		"temperature_c": climate.decode_float(0) if climate.size() == 8 else float(generation_params.get("avg_temperature", 15.0)),
		"precipitation": climate.decode_float(4) if climate.size() == 8 else 0.5,
		"river_flux": flux.decode_float(0) if flux.size() == 4 else 0.0,
		"flow_direction": int(flow[0]) if flow.size() == 1 else 255,
		"plate_id": int(plate.decode_u32(0)) if plate.size() == 4 else -1,
		"tectonic_stress": _tiled_plate_boundary_strength(cell),
		"resources_rgba": _rgba8_vector(resources),
	}

func _sample_raw(cell: Vector2i) -> Dictionary:
	var pixels := dimensions.x * dimensions.y
	var index := cell.y * dimensions.x + cell.x
	var height_m := 0.0
	if geo_data.size() == pixels * 16:
		height_m = geo_data.decode_float(index * 16)
	elif height_data.size() == pixels * 4:
		height_m = height_data.decode_float(index * 4)
	var climate_stride := int(climate_data.size() / maxi(pixels, 1))
	var temperature := float(generation_params.get("avg_temperature", 15.0))
	var precipitation := 0.5
	if climate_stride >= 8:
		temperature = climate_data.decode_float(index * climate_stride)
		precipitation = climate_data.decode_float(index * climate_stride + 4)
	var plate_id := -1
	var tectonic_stress := 0.0
	var plate_stride := int(plates_data.size() / maxi(pixels, 1))
	if plate_stride >= 16:
		plate_id = int(round(plates_data.decode_float(index * plate_stride)))
		tectonic_stress = absf(plates_data.decode_float(index * plate_stride + 12))
	elif plate_stride == 4:
		plate_id = int(plates_data.decode_u32(index * 4))
		tectonic_stress = _raw_plate_boundary_strength(cell, plate_stride)
	return {
		"cell": cell,
		"height_m": height_m,
		"water_type": int(water_data[index]) if water_data.size() == pixels else 0,
		"biome_id": int(biome_data.decode_u32(index * 4)) if biome_data.size() == pixels * 4 else -1,
		"temperature_c": temperature,
		"precipitation": precipitation,
		"river_flux": river_flux_data.decode_float(index * 4) if river_flux_data.size() == pixels * 4 else 0.0,
		"flow_direction": int(flow_data[index]) if flow_data.size() == pixels else 255,
		"plate_id": plate_id,
		"tectonic_stress": tectonic_stress,
		"resources_rgba": _rgba8_at(resources_data, index, pixels),
	}

func _tiled_plate_boundary_strength(cell: Vector2i) -> float:
	var center := tile_reader.read_window("plates", 0, cell, Vector2i.ONE, 4)
	if center.size() != 4:
		return 0.0
	var center_id := center.decode_u32(0)
	var different := 0
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var payload := tile_reader.read_window("plates", 0, cell + offset, Vector2i.ONE, 4)
		if payload.size() == 4 and payload.decode_u32(0) != center_id:
			different += 1
	return float(different) / 4.0

func _raw_plate_boundary_strength(cell: Vector2i, stride: int) -> float:
	if stride != 4:
		return 0.0
	var center := int(plates_data.decode_u32((cell.y * dimensions.x + cell.x) * 4))
	var different := 0
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor := PlanetGridContract.wrapped_global_cell(cell + offset, dimensions)
		var value := int(plates_data.decode_u32((neighbor.y * dimensions.x + neighbor.x) * 4))
		if value != center:
			different += 1
	return float(different) / 4.0

static func _rgba8_at(bytes: PackedByteArray, index: int, pixels: int) -> Vector4:
	if bytes.size() != pixels * 4:
		return Vector4.ZERO
	var offset := index * 4
	return Vector4(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) / 255.0

static func _rgba8_vector(bytes: PackedByteArray) -> Vector4:
	if bytes.size() != 4:
		return Vector4.ZERO
	return Vector4(bytes[0], bytes[1], bytes[2], bytes[3]) / 255.0
