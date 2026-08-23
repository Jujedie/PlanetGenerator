class_name PlanetGridContract
extends RefCounted

## Canonical, versioned coordinate/storage contract shared by every global layer.
## The projection is Lambert cylindrical equal-area with the equator as the
## standard parallel. X is longitude and Y is proportional to sin(latitude).

const CONTRACT_VERSION := 1
const PROJECTION_ID := "lambert_cylindrical_equal_area_v1"
const MAX_REFERENCE_RADIUS_KM := 6051.8
const MAX_LOGICAL_DIMENSIONS := Vector2i(30339, 15170)
const DEFAULT_CELL_AREA_KM2 := 1.0
const DEFAULT_TILE_SIZE := 2048
const NO_DATA_U32 := 0xFFFFFFFF
const NO_DATA_U8 := 0xFF

static func logical_dimensions(radius_km: float,
		cell_area_km2: float = DEFAULT_CELL_AREA_KM2) -> Vector2i:
	var radius := clampf(radius_km, 1.0, MAX_REFERENCE_RADIUS_KM)
	var cell_area := maxf(cell_area_km2, 0.000001)
	var surface_area := 4.0 * PI * radius * radius
	# A 2:1 equal-area cylinder gives N ~= width*height and width ~= 2*height.
	var width := maxi(2, int(round(sqrt(2.0 * surface_area / cell_area))))
	var height := maxi(1, int(round(float(width) * 0.5)))
	if radius >= MAX_REFERENCE_RADIUS_KM and cell_area <= DEFAULT_CELL_AREA_KM2:
		width = mini(width, MAX_LOGICAL_DIMENSIONS.x)
		height = mini(height, MAX_LOGICAL_DIMENSIONS.y)
	return Vector2i(width, height)

static func effective_cell_area_km2(radius_km: float, dimensions: Vector2i) -> float:
	if dimensions.x <= 0 or dimensions.y <= 0:
		return 0.0
	return 4.0 * PI * radius_km * radius_km / float(dimensions.x * dimensions.y)

static func normalize_longitude_radians(longitude: float) -> float:
	return fposmod(longitude + PI, TAU) - PI

static func world_to_global_cell(longitude_radians: float, latitude_radians: float,
		dimensions: Vector2i) -> Vector2i:
	var longitude := normalize_longitude_radians(longitude_radians)
	var latitude := clampf(latitude_radians, -PI * 0.5, PI * 0.5)
	var u := (longitude + PI) / TAU
	# North pole is row 0. Equal-area Y is linear in sin(latitude).
	var v := (1.0 - sin(latitude)) * 0.5
	var x := posmod(int(floor(u * float(dimensions.x))), dimensions.x)
	var y := clampi(int(floor(v * float(dimensions.y))), 0, dimensions.y - 1)
	return Vector2i(x, y)

static func global_cell_to_world(cell: Vector2i, dimensions: Vector2i) -> Vector2:
	var x := posmod(cell.x, dimensions.x)
	var y := clampi(cell.y, 0, dimensions.y - 1)
	var u := (float(x) + 0.5) / float(dimensions.x)
	var v := (float(y) + 0.5) / float(dimensions.y)
	var longitude := u * TAU - PI
	var sin_latitude := clampf(1.0 - 2.0 * v, -1.0, 1.0)
	return Vector2(longitude, asin(sin_latitude))

static func global_cell_to_unit_vector(cell: Vector2i, dimensions: Vector2i) -> Vector3:
	var lon_lat := global_cell_to_world(cell, dimensions)
	var cos_lat := cos(lon_lat.y)
	return Vector3(
		cos_lat * cos(lon_lat.x),
		sin(lon_lat.y),
		cos_lat * sin(lon_lat.x)
	)

static func world_vector_to_global_cell(direction: Vector3, dimensions: Vector2i) -> Vector2i:
	var normalized := direction.normalized()
	var latitude := asin(clampf(normalized.y, -1.0, 1.0))
	var longitude := atan2(normalized.z, normalized.x)
	return world_to_global_cell(longitude, latitude, dimensions)

static func tile_grid_dimensions(dimensions: Vector2i,
		tile_size: int = DEFAULT_TILE_SIZE) -> Vector2i:
	var size := maxi(tile_size, 1)
	return Vector2i(
		ceili(float(dimensions.x) / float(size)),
		ceili(float(dimensions.y) / float(size))
	)

static func cell_to_tile(cell: Vector2i, dimensions: Vector2i,
		tile_size: int = DEFAULT_TILE_SIZE) -> Dictionary:
	var size := maxi(tile_size, 1)
	var canonical := Vector2i(
		posmod(cell.x, dimensions.x), clampi(cell.y, 0, dimensions.y - 1)
	)
	var tile := Vector2i(canonical.x / size, canonical.y / size)
	return {
		"tile": tile,
		"local": canonical - tile * size,
		"global": canonical,
	}

static func tile_rect(tile: Vector2i, dimensions: Vector2i,
		tile_size: int = DEFAULT_TILE_SIZE) -> Rect2i:
	var size := maxi(tile_size, 1)
	var origin := tile * size
	var remaining := dimensions - origin
	return Rect2i(origin, Vector2i(
		clampi(remaining.x, 0, size), clampi(remaining.y, 0, size)
	))

static func tile_rect_with_halo(tile: Vector2i, dimensions: Vector2i, halo: int,
		tile_size: int = DEFAULT_TILE_SIZE) -> Dictionary:
	var core := tile_rect(tile, dimensions, tile_size)
	var h := maxi(halo, 0)
	# X halo is intentionally allowed outside [0,width): consumers wrap it in
	# absolute coordinates. Y halo is clipped at the poles.
	var y0 := maxi(core.position.y - h, 0)
	var y1 := mini(core.end.y + h, dimensions.y)
	return {
		"core": core,
		"sample_origin": Vector2i(core.position.x - h, y0),
		"sample_size": Vector2i(core.size.x + h * 2, y1 - y0),
		"crop_offset": Vector2i(h, core.position.y - y0),
	}

static func wrapped_global_cell(cell: Vector2i, dimensions: Vector2i) -> Vector2i:
	return Vector2i(posmod(cell.x, dimensions.x), clampi(cell.y, 0, dimensions.y - 1))

static func lod_dimensions(base_dimensions: Vector2i, lod: int) -> Vector2i:
	var divisor := 1 << maxi(lod, 0)
	return Vector2i(
		maxi(1, ceili(float(base_dimensions.x) / float(divisor))),
		maxi(1, ceili(float(base_dimensions.y) / float(divisor)))
	)

static func lod_source_rect(lod_cell: Vector2i, lod: int,
		base_dimensions: Vector2i) -> Rect2i:
	var scale := 1 << maxi(lod, 0)
	var origin := lod_cell * scale
	return Rect2i(origin, Vector2i(
		mini(scale, base_dimensions.x - origin.x),
		mini(scale, base_dimensions.y - origin.y)
	))

static func downsample_scalar_average(values: PackedFloat32Array,
		dimensions: Vector2i) -> Dictionary:
	var target := lod_dimensions(dimensions, 1)
	var out := PackedFloat32Array()
	out.resize(target.x * target.y)
	for y in range(target.y):
		for x in range(target.x):
			var total := 0.0
			var count := 0
			for dy in range(2):
				var sy := y * 2 + dy
				if sy >= dimensions.y:
					continue
				for dx in range(2):
					var sx := x * 2 + dx
					if sx >= dimensions.x:
						continue
					total += values[sy * dimensions.x + sx]
					count += 1
			out[y * target.x + x] = total / float(maxi(count, 1))
	return {"dimensions": target, "data": out}

static func downsample_categorical_mode(values: PackedInt32Array,
		dimensions: Vector2i, no_data: int = -1) -> Dictionary:
	var target := lod_dimensions(dimensions, 1)
	var out := PackedInt32Array()
	out.resize(target.x * target.y)
	for y in range(target.y):
		for x in range(target.x):
			var counts: Dictionary = {}
			for dy in range(2):
				var sy := y * 2 + dy
				if sy >= dimensions.y:
					continue
				for dx in range(2):
					var sx := x * 2 + dx
					if sx >= dimensions.x:
						continue
					var value := int(values[sy * dimensions.x + sx])
					if value == no_data:
						continue
					counts[value] = int(counts.get(value, 0)) + 1
			var chosen := no_data
			var best_count := -1
			for value in counts.keys():
				var count := int(counts[value])
				if count > best_count or (count == best_count and int(value) < chosen):
					chosen = int(value)
					best_count = count
			out[y * target.x + x] = chosen
	return {"dimensions": target, "data": out}

static func contract_dictionary(radius_km: float, dimensions: Vector2i,
		tile_size: int = DEFAULT_TILE_SIZE) -> Dictionary:
	return {
		"contract_version": CONTRACT_VERSION,
		"projection": PROJECTION_ID,
		"radius_km": radius_km,
		"dimensions": [dimensions.x, dimensions.y],
		"cell_area_km2": effective_cell_area_km2(radius_km, dimensions),
		"tile_size": tile_size,
		"tile_grid": [
			tile_grid_dimensions(dimensions, tile_size).x,
			tile_grid_dimensions(dimensions, tile_size).y,
		],
		"horizontal_wrap": true,
		"polar_behavior": "clamp_y; cell_centres never sample exact poles",
		"lod": {
			"scalar": "deterministic 2x2 arithmetic mean",
			"categorical": "deterministic 2x2 mode; smallest id wins ties",
		},
	}
