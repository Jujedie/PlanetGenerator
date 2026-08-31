class_name GlobalHydrologyContext
extends RefCounted

## Small global routing layer (normally <= 512 cells wide) used to carry
## drainage information across full-resolution tile boundaries. It is not a
## full-resolution planet texture and therefore stays bounded at Venus scale.

const NO_FLOW := 255
const D8 := [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]

var global_dimensions: Vector2i
var macro_dimensions: Vector2i
var stride: int
var elevation := PackedFloat32Array()
var flux := PackedFloat32Array()
var direction := PackedByteArray()
var max_flux := 1.0
var tile_routes: Dictionary = {}

static func build(dimensions: Vector2i, params: Dictionary,
		tile_size: int = PlanetGridContract.DEFAULT_TILE_SIZE,
		max_macro_width: int = 512) -> GlobalHydrologyContext:
	var context := GlobalHydrologyContext.new()
	context.global_dimensions = dimensions
	context.stride = maxi(1, ceili(float(dimensions.x) / float(maxi(max_macro_width, 32))))
	context.macro_dimensions = Vector2i(
		ceili(float(dimensions.x) / float(context.stride)),
		ceili(float(dimensions.y) / float(context.stride))
	)
	context._build_fields(params)
	context._build_tile_routes(tile_size)
	return context

static func build_from_height_tiles(dimensions: Vector2i, params: Dictionary,
		store: PlanetTileStore, tile_size: int = PlanetGridContract.DEFAULT_TILE_SIZE,
		max_macro_width: int = 512) -> GlobalHydrologyContext:
	var context := GlobalHydrologyContext.new()
	context.global_dimensions = dimensions
	context.stride = maxi(1, ceili(float(dimensions.x) / float(maxi(max_macro_width, 32))))
	context.macro_dimensions = Vector2i(
		ceili(float(dimensions.x) / float(context.stride)),
		ceili(float(dimensions.y) / float(context.stride))
	)
	context._build_fields_from_store(params, store, tile_size)
	context._build_tile_routes(tile_size)
	return context

func _build_fields_from_store(params: Dictionary, store: PlanetTileStore, tile_size: int) -> void:
	var count := macro_dimensions.x * macro_dimensions.y
	elevation.resize(count)
	var tile_cache: Dictionary = {}
	var tile_cache_order: Array[String] = []
	for y in range(macro_dimensions.y):
		for x in range(macro_dimensions.x):
			var cell := Vector2i(
				mini(x * stride + stride / 2, global_dimensions.x - 1),
				mini(y * stride + stride / 2, global_dimensions.y - 1)
			)
			var address := PlanetGridContract.cell_to_tile(cell, global_dimensions, tile_size)
			var tile: Vector2i = address["tile"]
			var key := "%d:%d" % [tile.x, tile.y]
			var payload: PackedByteArray
			if tile_cache.has(key):
				payload = tile_cache[key]
			else:
				payload = store.read_tile("height", 0, tile)
				tile_cache[key] = payload
				tile_cache_order.append(key)
				if tile_cache_order.size() > 16:
					var oldest: String = tile_cache_order.pop_front()
					tile_cache.erase(oldest)
			var rect := PlanetGridContract.tile_rect(tile, global_dimensions, tile_size)
			var local: Vector2i = address["local"]
			var offset := (local.y * rect.size.x + local.x) * 4
			if offset + 4 <= payload.size():
				elevation[y * macro_dimensions.x + x] = payload.decode_float(offset)
			else:
				elevation[y * macro_dimensions.x + x] = 0.0
	_build_routes_and_flux(params)

func _build_fields(params: Dictionary) -> void:
	var count := macro_dimensions.x * macro_dimensions.y
	elevation.resize(count)
	var seed := int(params.get("seed", 12345))
	var planet_type := int(params.get("planet_type", 0))
	var terrain_scale := float(params.get("terrain_scale", 0.0))
	for y in range(macro_dimensions.y):
		for x in range(macro_dimensions.x):
			var index := y * macro_dimensions.x + x
			var cell := Vector2i(
				mini(x * stride + stride / 2, global_dimensions.x - 1),
				mini(y * stride + stride / 2, global_dimensions.y - 1)
			)
			elevation[index] = TiledPhysicalFields.terrain_height_m(
				cell, global_dimensions, seed, planet_type, terrain_scale
			)
	_build_routes_and_flux(params)

func _build_routes_and_flux(params: Dictionary) -> void:
	var count := macro_dimensions.x * macro_dimensions.y
	flux.resize(count)
	direction.resize(count)
	direction.fill(NO_FLOW)
	var seed := int(params.get("seed", 12345))
	var sea_level := float(params.get("sea_level", 0.0))
	var avg_temp := float(params.get("avg_temperature", 15.0))
	for y in range(macro_dimensions.y):
		for x in range(macro_dimensions.x):
			var index := y * macro_dimensions.x + x
			var cell := Vector2i(
				mini(x * stride + stride / 2, global_dimensions.x - 1),
				mini(y * stride + stride / 2, global_dimensions.y - 1)
			)
			var climate := TiledPhysicalFields.climate_at(
				cell, global_dimensions, seed, elevation[index], avg_temp
			)
			flux[index] = maxf(climate.y, 0.001)

	# D8 direction on the bounded global macro grid. X is periodic.
	for y in range(macro_dimensions.y):
		for x in range(macro_dimensions.x):
			var index := y * macro_dimensions.x + x
			if elevation[index] < sea_level:
				continue
			var best_height := elevation[index]
			var best_dir := NO_FLOW
			for d in range(D8.size()):
				var nx := posmod(x + D8[d].x, macro_dimensions.x)
				var ny = y + D8[d].y
				if ny < 0 or ny >= macro_dimensions.y:
					continue
				var neighbor = ny * macro_dimensions.x + nx
				if elevation[neighbor] < best_height:
					best_height = elevation[neighbor]
					best_dir = d
			direction[index] = best_dir

	# Exact one-pass accumulation in descending elevation order. Every selected
	# edge is strictly downhill, hence the macro graph is acyclic.
	var order: Array[int] = []
	order.resize(count)
	for i in range(count):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		if is_equal_approx(elevation[a], elevation[b]):
			return a < b
		return elevation[a] > elevation[b]
	)
	for index in order:
		var d := int(direction[index])
		if d == NO_FLOW:
			continue
		var x := index % macro_dimensions.x
		var y := int(index / macro_dimensions.x)
		var nx := posmod(x + D8[d].x, macro_dimensions.x)
		var ny = y + D8[d].y
		if ny < 0 or ny >= macro_dimensions.y:
			continue
		var downstream = ny * macro_dimensions.x + nx
		flux[downstream] += flux[index]
	max_flux = 1.0
	for value in flux:
		max_flux = maxf(max_flux, value)

func _build_tile_routes(tile_size: int) -> void:
	var grid := PlanetGridContract.tile_grid_dimensions(global_dimensions, tile_size)
	var outlets: Dictionary = {}
	for ty in range(grid.y):
		for tx in range(grid.x):
			var tile := Vector2i(tx, ty)
			var rect := PlanetGridContract.tile_rect(tile, global_dimensions, tile_size)
			var macro_x0 := clampi(rect.position.x / stride, 0, macro_dimensions.x - 1)
			var macro_x1 := clampi((rect.end.x - 1) / stride, 0, macro_dimensions.x - 1)
			var macro_y0 := clampi(rect.position.y / stride, 0, macro_dimensions.y - 1)
			var macro_y1 := clampi((rect.end.y - 1) / stride, 0, macro_dimensions.y - 1)
			var candidates: Array = []
			for my in range(macro_y0, macro_y1 + 1):
				for mx in range(macro_x0, macro_x1 + 1):
					if mx not in [macro_x0, macro_x1] and my not in [macro_y0, macro_y1]:
						continue
					var idx := my * macro_dimensions.x + mx
					candidates.append({
						"spill_height": float(elevation[idx]),
						"flux": float(flux[idx]),
						"macro_cell": Vector2i(mx, my),
					})
			outlets[tile] = candidates
	tile_routes = GlobalDrainageRouter.route(outlets, grid)

func flux_bytes() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(flux.size() * 4)
	for i in range(flux.size()):
		data.encode_float(i * 4, flux[i])
	return data

func direction_bytes() -> PackedByteArray:
	return direction.duplicate()

func report() -> Dictionary:
	return {
		"stride": stride,
		"macro_dimensions": [macro_dimensions.x, macro_dimensions.y],
		"macro_cells": macro_dimensions.x * macro_dimensions.y,
		"max_flux": max_flux,
		"tile_routes": tile_routes.size(),
	}
