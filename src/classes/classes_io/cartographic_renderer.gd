class_name CartographicRenderer
extends RefCounted

## CPU reference renderer for cartographic output. It never mutates physical
## simulation buffers. The tiled path can call the same pixel rules on haloed
## tile data; the legacy path uses render_full_map after GPU readback.

const VIEW_PLANET := "planet"
const VIEW_REGIONAL := "regional"
const VIEW_LOCAL := "local"

static func contour_intervals(view: String) -> Vector2:
	match view:
		VIEW_LOCAL:
			return Vector2(5.0, 25.0)
		VIEW_REGIONAL:
			return Vector2(50.0, 250.0)
		_:
			return Vector2(250.0, 1000.0)

static func line_width(view: String) -> int:
	match view:
		VIEW_LOCAL:
			return 2
		VIEW_REGIONAL:
			return 1
		_:
			return 1

static func render_full_map(geo_data: PackedByteArray, water_data: PackedByteArray,
		biome_data: PackedByteArray, dimensions: Vector2i, radius_km: float,
		sea_level: float, palette: CartographicPalette,
		options: Dictionary = {}) -> Dictionary:
	var pixel_count := dimensions.x * dimensions.y
	if geo_data.size() != pixel_count * 16 or water_data.size() != pixel_count:
		return {}
	var has_biome := biome_data.size() == pixel_count * 4
	var view := str(options.get("view", VIEW_PLANET))
	var intervals := contour_intervals(view)
	var waterless_surface := bool(options.get("waterless_surface", false))
	var waterless_min := float(options.get("waterless_min_elevation", INF))
	var waterless_max := float(options.get("waterless_max_elevation", -INF))
	if waterless_surface and (
		not is_finite(waterless_min)
		or not is_finite(waterless_max)
		or waterless_max <= waterless_min
	):
		waterless_min = INF
		waterless_max = -INF
		for index in range(pixel_count):
			var relative_height := geo_data.decode_float(index * 16) - sea_level
			waterless_min = minf(waterless_min, relative_height)
			waterless_max = maxf(waterless_max, relative_height)
	var output := PackedByteArray()
	output.resize(pixel_count * 4)
	var label_placements: Array = []

	for y in range(dimensions.y):
		for x in range(dimensions.x):
			var index := y * dimensions.x + x
			var height_m := geo_data.decode_float(index * 16)
			var water_type := int(water_data[index])
			var palette_height := height_m
			if waterless_surface:
				palette_height = _waterless_palette_elevation(
					height_m - sea_level, waterless_min, waterless_max
				)
			var color := _base_color(palette_height, water_type, palette, sea_level)
			if water_type == 0:
				var shade := _hillshade(geo_data, x, y, dimensions, radius_km)
				var strength := palette.hillshade_strength
				color = color * lerpf(1.0 - strength, 1.0 + strength * 0.55, shade)
				if has_biome:
					var biome_id := int(biome_data.decode_u32(index * 4))
					color = _modulate_biome(color, biome_id, palette.biome_modulation_strength)

			var contour_kind := _contour_kind(geo_data, x, y, dimensions,
				height_m, water_type, sea_level, intervals,
				waterless_surface, waterless_min)
			if contour_kind == 2:
				color = color.lerp(palette.major_contour, 0.72)
			elif contour_kind == 1:
				color = color.lerp(palette.minor_contour, 0.48)
			if _is_coast(water_data, x, y, dimensions):
				color = color.lerp(palette.coastline, 0.82)
			_write_color(output, index * 4, color)

	for marker_value in options.get("markers", []):
		if not marker_value is Dictionary:
			continue
		var marker: Dictionary = marker_value
		var lon := deg_to_rad(float(marker.get("longitude_deg", 0.0)))
		var lat := deg_to_rad(float(marker.get("latitude_deg", 0.0)))
		var cell := PlanetGridContract.world_to_global_cell(lon, lat, dimensions)
		_draw_marker(output, dimensions, cell, palette.marker, line_width(view))
		label_placements.append({
			"text": str(marker.get("label", "")),
			"cell": cell,
			"longitude_deg": float(marker.get("longitude_deg", 0.0)),
			"latitude_deg": float(marker.get("latitude_deg", 0.0)),
		})

	return {
		"image": Image.create_from_data(dimensions.x, dimensions.y, false, Image.FORMAT_RGBA8, output),
		"labels": label_placements,
		"palette": palette.name,
		"palette_version": palette.version,
		"view": view,
		"minor_contour_m": intervals.x,
		"major_contour_m": intervals.y,
	}

static func render_grid_overlay(dimensions: Vector2i, palette: CartographicPalette,
		options: Dictionary = {}) -> Dictionary:
	var pixel_count := dimensions.x * dimensions.y
	var output := PackedByteArray()
	output.resize(pixel_count * 4)
	var view := str(options.get("view", VIEW_PLANET))
	var alpha := clampi(int(options.get("alpha", 166)), 0, 255)
	if view != VIEW_LOCAL:
		for y in range(dimensions.y):
			for x in range(dimensions.x):
				if _is_coordinate_grid(x, y, dimensions, view):
					_write_color(output, (y * dimensions.x + x) * 4, palette.grid, alpha)
	return {
		"image": Image.create_from_data(dimensions.x, dimensions.y, false, Image.FORMAT_RGBA8, output),
		"view": view,
		"palette": palette.name,
		"palette_version": palette.version,
		"alpha": alpha,
	}


static func _base_color(height_m: float, water_type: int,
		palette: CartographicPalette, sea_level: float) -> Color:
	if water_type == 1:
		var depth := maxf(sea_level - height_m, 0.0)
		return palette.saltwater.darkened(clampf(depth / 12000.0, 0.0, 0.28))
	if water_type == 2:
		return palette.freshwater
	return palette.color_for_elevation(height_m)


static func _waterless_palette_elevation(relative_height: float,
		minimum_height: float, maximum_height: float) -> float:
	var normalized := clampf(
		(relative_height - minimum_height) / maxf(maximum_height - minimum_height, 1.0),
		0.0,
		1.0
	)
	return lerpf(20.0, 6000.0, pow(normalized, 0.88))

static func _height(geo_data: PackedByteArray, x: int, y: int,
		dimensions: Vector2i) -> float:
	var px := posmod(x, dimensions.x)
	var py := clampi(y, 0, dimensions.y - 1)
	return geo_data.decode_float((py * dimensions.x + px) * 16)

static func _hillshade(geo_data: PackedByteArray, x: int, y: int,
		dimensions: Vector2i, radius_km: float) -> float:
	var lon_lat := PlanetGridContract.global_cell_to_world(Vector2i(x, y), dimensions)
	var dlon := TAU / float(dimensions.x)
	var dx_m := maxf(radius_km * 1000.0 * dlon * maxf(cos(lon_lat.y), 0.02), 1.0)
	var y0 := maxi(y - 1, 0)
	var y1 := mini(y + 1, dimensions.y - 1)
	var lat0 := PlanetGridContract.global_cell_to_world(Vector2i(x, y0), dimensions).y
	var lat1 := PlanetGridContract.global_cell_to_world(Vector2i(x, y1), dimensions).y
	var dy_m := maxf(radius_km * 1000.0 * absf(lat1 - lat0), 1.0)
	var dzdx := (_height(geo_data, x + 1, y, dimensions) - _height(geo_data, x - 1, y, dimensions)) / (2.0 * dx_m)
	var dzdy := (_height(geo_data, x, y + 1, dimensions) - _height(geo_data, x, y - 1, dimensions)) / (2.0 * dy_m)
	var normal := Vector3(-dzdx, 1.0, -dzdy).normalized()
	var light := Vector3(-0.55, 0.78, -0.30).normalized()
	return clampf(normal.dot(light) * 0.5 + 0.5, 0.0, 1.0)

static func _contour_kind(geo_data: PackedByteArray, x: int, y: int,
		dimensions: Vector2i, height_m: float, water_type: int, sea_level: float,
		intervals: Vector2, waterless_surface: bool = false,
		waterless_minimum: float = 0.0) -> int:
	var relative := (
		height_m - sea_level - waterless_minimum
		if waterless_surface
		else (absf(height_m - sea_level) if water_type != 0 else maxf(height_m - sea_level, 0.0))
	)
	var minor_band := floori(relative / intervals.x)
	var major_band := floori(relative / intervals.y)
	for offset in [Vector2i.RIGHT, Vector2i.DOWN]:
		var neighbor_height := _height(geo_data, x + offset.x, y + offset.y, dimensions)
		var neighbor_relative := (
			neighbor_height - sea_level - waterless_minimum
			if waterless_surface
			else (absf(neighbor_height - sea_level) if water_type != 0 else maxf(neighbor_height - sea_level, 0.0))
		)
		if floori(neighbor_relative / intervals.y) != major_band:
			return 2
		if floori(neighbor_relative / intervals.x) != minor_band:
			return 1
	return 0

static func _is_coast(water_data: PackedByteArray, x: int, y: int,
		dimensions: Vector2i) -> bool:
	var index := y * dimensions.x + x
	var water := water_data[index] != 0
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var ny = y + offset.y
		if ny < 0 or ny >= dimensions.y:
			continue
		var nx := posmod(x + offset.x, dimensions.x)
		if (water_data[ny * dimensions.x + nx] != 0) != water:
			return true
	return false

static func _is_coordinate_grid(x: int, y: int, dimensions: Vector2i, view: String) -> bool:
	if view == VIEW_LOCAL:
		return false
	var lon_step := 10.0 if view == VIEW_REGIONAL else 30.0
	var lat_step := 5.0 if view == VIEW_REGIONAL else 15.0
	var world := PlanetGridContract.global_cell_to_world(Vector2i(x, y), dimensions)
	var right := PlanetGridContract.global_cell_to_world(Vector2i((x + 1) % dimensions.x, y), dimensions)
	var down := PlanetGridContract.global_cell_to_world(Vector2i(x, mini(y + 1, dimensions.y - 1)), dimensions)
	var lon_deg := rad_to_deg(world.x)
	var next_lon_deg := rad_to_deg(right.x)
	if next_lon_deg < lon_deg:
		next_lon_deg += 360.0
	var lon_bucket := floori((lon_deg + 180.0) / lon_step)
	var next_lon_bucket := floori((next_lon_deg + 180.0) / lon_step)
	if lon_bucket != next_lon_bucket:
		return true
	var lat_deg := rad_to_deg(world.y)
	var next_lat_deg := rad_to_deg(down.y)
	return floori((lat_deg + 90.0) / lat_step) != floori((next_lat_deg + 90.0) / lat_step)

static func _modulate_biome(color: Color, biome_id: int, strength: float) -> Color:
	if strength <= 0.0 or biome_id == 0xFFFFFFFF:
		return color
	var hash := AbsoluteFieldSampler.hash_u32(biome_id * 2654435761)
	var signed := (float(hash & 0xFFFF) / 65535.0) * 2.0 - 1.0
	return color.lightened(maxf(signed, 0.0) * strength).darkened(maxf(-signed, 0.0) * strength)

static func _draw_marker(output: PackedByteArray, dimensions: Vector2i,
		cell: Vector2i, color: Color, width: int) -> void:
	var radius := 2 + maxi(width, 1)
	for d in range(-radius, radius + 1):
		for offset in [Vector2i(d, 0), Vector2i(0, d)]:
			var x := posmod(cell.x + offset.x, dimensions.x)
			var y := clampi(cell.y + offset.y, 0, dimensions.y - 1)
			_write_color(output, (y * dimensions.x + x) * 4, color)

static func _write_color(output: PackedByteArray, offset: int, color: Color, alpha: int = 255) -> void:
	output[offset] = clampi(roundi(color.r * 255.0), 0, 255)
	output[offset + 1] = clampi(roundi(color.g * 255.0), 0, 255)
	output[offset + 2] = clampi(roundi(color.b * 255.0), 0, 255)
	output[offset + 3] = clampi(alpha, 0, 255)
