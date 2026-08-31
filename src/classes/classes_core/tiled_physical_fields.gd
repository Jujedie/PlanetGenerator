class_name TiledPhysicalFields
extends RefCounted

## Deterministic macro fields shared by the CPU routing pass and the tiled GPU
## shaders.  All randomness is addressed by absolute global cells so a tile can
## be regenerated in isolation without changing its neighbours.

static func terrain_height_m(cell: Vector2i, dimensions: Vector2i,
		seed: int, planet_type: int = 0, terrain_scale: float = 0.0) -> float:
	var c := PlanetGridContract.wrapped_global_cell(cell, dimensions)
	var continent_scale := maxi(dimensions.x / 6, 32)
	var macro_scale := maxi(dimensions.x / 12, 16)
	var ridge_scale := maxi(dimensions.x / 96, 4)
	var detail_scale := maxi(dimensions.x / 220, 2)
	var continent := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, continent_scale, 10)
	var macro := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, macro_scale, 11)
	var detail := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, ridge_scale, 12)
	var fine := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, detail_scale, 13)
	var ridge := pow(1.0 - abs(detail * 2.0 - 1.0), 3.0)
	var uplift_noise := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, macro_scale, 14)
	var height := (continent - 0.505) * 9200.0
	height += (macro - 0.5) * 2600.0
	height += (ridge - 0.35) * 2100.0
	height += (fine - 0.5) * 320.0
	match planet_type:
		2: # volcanic
			height += pow(AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, ridge_scale, 21), 5.0) * 1800.0
		3: # airless
			height += (fine - 0.5) * 480.0
		5: # sterile
			height *= 0.82
		_:
			pass
	height += clampf(uplift_noise, 0.0, 1.0) * maxf(terrain_scale, 0.0) * 0.4
	return height

static func climate_at(cell: Vector2i, dimensions: Vector2i, seed: int,
		height_m: float, average_temperature: float) -> Vector2:
	var c := PlanetGridContract.wrapped_global_cell(cell, dimensions)
	var world := PlanetGridContract.global_cell_to_world(c, dimensions)
	var latitude_factor = abs(sin(world.y))
	var broad_scale := maxi(dimensions.x / 30, 8)
	var moisture := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, broad_scale, 31)
	var thermal := AbsoluteFieldSampler.smooth_noise(c, dimensions, seed, broad_scale * 2, 32)
	var temperature = average_temperature - latitude_factor * 52.0
	temperature -= maxf(height_m, 0.0) * 0.0062
	temperature += (thermal - 0.5) * 9.0
	var humidity := clampf(0.18 + moisture * 0.72 - latitude_factor * 0.14, 0.0, 1.0)
	humidity *= clampf(1.0 - maxf(height_m, 0.0) / 18000.0, 0.35, 1.0)
	return Vector2(temperature, humidity)

static func plate_id(cell: Vector2i, dimensions: Vector2i, seed: int) -> int:
	var scale := maxi(dimensions.x / 32, 8)
	var c := PlanetGridContract.wrapped_global_cell(cell, dimensions)
	var coarse := Vector2i(c.x / scale, c.y / scale)
	return AbsoluteFieldSampler.hash_cell(coarse, seed, 44) & 0x7FFFFFFF
