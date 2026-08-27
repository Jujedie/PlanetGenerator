class_name TileWindowReader
extends RefCounted

## Reassembles a halo/window from already completed core tiles without ever
## materialising a full-resolution global layer in RAM. X wraps; Y is clipped by
## the descriptor produced by PlanetGridContract.

var store: PlanetTileStore
var dimensions: Vector2i
var tile_size: int
var _cache: Dictionary = {}
var _cache_order: Array[String] = []

func _init(tile_store: PlanetTileStore, global_dimensions: Vector2i,
		configured_tile_size: int = PlanetGridContract.DEFAULT_TILE_SIZE) -> void:
	store = tile_store
	dimensions = global_dimensions
	tile_size = maxi(configured_tile_size, 1)

func clear_cache() -> void:
	_cache.clear()
	_cache_order.clear()

func read_window(layer: String, lod: int, origin: Vector2i, size: Vector2i,
		bytes_per_pixel: int) -> PackedByteArray:
	if size.x <= 0 or size.y <= 0 or bytes_per_pixel <= 0:
		return PackedByteArray()
	var output := PackedByteArray()
	for dy in range(size.y):
		var gy := clampi(origin.y + dy, 0, dimensions.y - 1)
		var remaining := size.x
		var gx_unwrapped := origin.x
		while remaining > 0:
			var gx := posmod(gx_unwrapped, dimensions.x)
			var tile := Vector2i(gx / tile_size, gy / tile_size)
			var rect := PlanetGridContract.tile_rect(tile, dimensions, tile_size)
			if rect.size.x <= 0 or rect.size.y <= 0:
				return PackedByteArray()
			var local_x := gx - rect.position.x
			var local_y := gy - rect.position.y
			var span := mini(remaining, rect.size.x - local_x)
			# Do not let one segment cross the global wrap; the next iteration
			# deliberately starts again at X=0.
			span = mini(span, dimensions.x - gx)
			var payload := _tile_payload(layer, lod, tile)
			var expected := rect.size.x * rect.size.y * bytes_per_pixel
			if payload.size() != expected:
				push_error("Tile window read failed for %s %s: expected %d bytes, got %d" % [
					layer, tile, expected, payload.size()
				])
				return PackedByteArray()
			var source_offset := (local_y * rect.size.x + local_x) * bytes_per_pixel
			var byte_count := span * bytes_per_pixel
			output.append_array(payload.slice(source_offset, source_offset + byte_count))
			gx_unwrapped += span
			remaining -= span
	return output

func read_core(layer: String, lod: int, tile: Vector2i) -> PackedByteArray:
	return _tile_payload(layer, lod, tile)

func _tile_payload(layer: String, lod: int, tile: Vector2i) -> PackedByteArray:
	var key := "%s:%d:%d:%d" % [layer, lod, tile.x, tile.y]
	if _cache.has(key):
		return _cache[key]
	var payload := store.read_tile(layer, lod, tile)
	_cache[key] = payload
	_cache_order.append(key)
	# A halo touches at most a handful of tiles. Avoid retaining an entire planet
	# in system RAM if a phase scans hundreds of tiles. Keep a tiny FIFO alongside
	# the dictionary instead of allocating Dictionary.keys() on every eviction.
	if _cache_order.size() > 16:
		var oldest := _cache_order.pop_front()
		_cache.erase(oldest)
	return payload
