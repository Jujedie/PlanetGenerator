class_name LocalZoneGenerator
extends RefCounted

## Milestone 7 authoritative local-terrain generator.
##
## A global cell addresses a 1 km x 1 km zone. Global climate, tectonics,
## hydrology, biome and resources constrain the result, but are not copied as
## local map products. Every procedural sample is evaluated in absolute metre
## space so independently generated neighbours share byte-identical boundaries.

const DEFAULT_RESOLUTION := 1024
const ZONE_SIZE_M := 1000.0
const GENERATOR_CONTRACT_VERSION := 2
const MIN_RESOLUTION := 16
const MAX_RESOLUTION := 4096

static func planet_id(generation_params: Dictionary) -> String:
	var fields := [
		str(int(generation_params.get("seed", 0))),
		str(float(generation_params.get("planet_radius", 0.0))),
		str(int(generation_params.get("planet_type", 0))),
		str(PlanetGridContract.CONTRACT_VERSION),
		str(GENERATOR_CONTRACT_VERSION),
	]
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update("|".join(fields).to_utf8_buffer())
	return context.finish().hex_encode().substr(0, 24)

static func generate_zone(global_cell: Vector2i, sampler: GlobalMacroSampler,
		generation_params: Dictionary, resolution: int = DEFAULT_RESOLUTION,
		cache: LocalZoneCache = null) -> Dictionary:
	if sampler == null or not sampler.is_valid():
		return {}
	# Gas giants do not expose solid-surface zones.
	if int(generation_params.get("planet_type", 0)) == 6:
		return {}
	var dimensions := sampler.dimensions
	var cell := PlanetGridContract.wrapped_global_cell(global_cell, dimensions)
	var safe_resolution := clampi(resolution, MIN_RESOLUTION, MAX_RESOLUTION)
	var version := "%s-local%d" % [
		str(ProjectSettings.get_setting("application/config/version", "unknown")),
		GENERATOR_CONTRACT_VERSION,
	]
	var id := planet_id(generation_params)
	if cache != null:
		var cached := cache.load_zone(id, version, cell, safe_resolution)
		if not cached.is_empty():
			return cached

	var count := safe_resolution * safe_resolution
	var spacing_m := ZONE_SIZE_M / float(safe_resolution - 1)
	var seed := int(generation_params.get("seed", 0))
	var sea_level := float(generation_params.get("sea_level", 0.0))
	var planet_width_m := float(dimensions.x) * ZONE_SIZE_M

	var height_bytes := _alloc(count, 4)
	var normal_bytes := _alloc(count, 4)
	var slope_bytes := _alloc(count, 4)
	var water_depth_bytes := _alloc(count, 4)
	var water_mask_bytes := _alloc(count, 1)
	var flow_bytes := _alloc(count, 4)
	var soil_type_bytes := _alloc(count, 1)
	var soil_moisture_bytes := _alloc(count, 1)
	var soil_depth_bytes := _alloc(count, 4)
	var rock_type_bytes := _alloc(count, 1)
	var surface_bytes := _alloc(count, 1)
	var vegetation_bytes := _alloc(count, 1)
	var resource_bytes := _alloc(count, 4)
	var snow_ice_bytes := _alloc(count, 1)
	var spawn_bytes := _alloc(count, 1)
	var hazard_bytes := _alloc(count, 1)

	# Pass 1: detailed height. Height uses a globally continuous macro field +
	# absolute detail, rather than zone-local interpolation/noise.
	for y in range(safe_resolution):
		var gy := float(cell.y) + float(y) / float(safe_resolution - 1)
		for x in range(safe_resolution):
			var gx := float(cell.x) + float(x) / float(safe_resolution - 1)
			var index := y * safe_resolution + x
			height_bytes.encode_float(index * 4, _height_at_global(gx, gy, sampler, generation_params))

	# Pass 2: derivatives, local hydrology, soil/surface/ecology/resource fields.
	for y in range(safe_resolution):
		var gy := float(cell.y) + float(y) / float(safe_resolution - 1)
		for x in range(safe_resolution):
			var gx := float(cell.x) + float(x) / float(safe_resolution - 1)
			var index := y * safe_resolution + x
			var offset := index * 4
			var h := height_bytes.decode_float(offset)
			var delta_grid := spacing_m / ZONE_SIZE_M
			var h_l := _height_at_global(gx - delta_grid, gy, sampler, generation_params)
			var h_r := _height_at_global(gx + delta_grid, gy, sampler, generation_params)
			var h_u := _height_at_global(gx, gy - delta_grid, sampler, generation_params)
			var h_d := _height_at_global(gx, gy + delta_grid, sampler, generation_params)
			var dzdx := (h_r - h_l) / (2.0 * spacing_m)
			var dzdy := (h_d - h_u) / (2.0 * spacing_m)
			var normal := Vector3(-dzdx, 1.0, -dzdy).normalized()
			var slope_rad := atan(sqrt(dzdx * dzdx + dzdy * dzdy))
			_write_rgba8(normal_bytes, index, Vector4(
				normal.x * 0.5 + 0.5, normal.y * 0.5 + 0.5, normal.z * 0.5 + 0.5, 1.0
			))
			slope_bytes.encode_float(offset, slope_rad)

			var macro := _macro_at_global(gx, gy, sampler)
			var abs_x_m := gx * ZONE_SIZE_M
			var abs_y_m := gy * ZONE_SIZE_M
			var water := _local_water(abs_x_m, abs_y_m, planet_width_m, h, sea_level, macro, seed)
			water_depth_bytes.encode_float(offset, float(water["depth_m"]))
			water_mask_bytes[index] = int(water["type"])
			_write_flow(flow_bytes, index, water)

			var material := _soil_and_surface(
				abs_x_m, abs_y_m, planet_width_m, h, slope_rad, macro, water,
				generation_params, seed
			)
			soil_type_bytes[index] = int(material["soil_type"])
			soil_moisture_bytes[index] = _u8(float(material["moisture"]))
			soil_depth_bytes.encode_float(offset, float(material["soil_depth_m"]))
			rock_type_bytes[index] = int(material["rock_type"])
			surface_bytes[index] = int(material["surface"])

			var vegetation := _vegetation_density(
				abs_x_m, abs_y_m, planet_width_m, slope_rad, macro, water, material,
				generation_params, seed
			)
			vegetation_bytes[index] = _u8(vegetation)
			var resource := _local_resources(abs_x_m, abs_y_m, planet_width_m, macro, material, seed)
			_write_rgba8(resource_bytes, index, resource)
			var snow_ice := _snow_ice(h, macro, water, material)
			snow_ice_bytes[index] = _u8(snow_ice)
			var hazard := _hazard(slope_rad, water, material, snow_ice)
			hazard_bytes[index] = _u8(hazard)
			var spawn := clampf(
				(1.0 - smoothstep(deg_to_rad(18.0), deg_to_rad(42.0), slope_rad))
				* (1.0 - clampf(float(water["depth_m"]) / 0.35, 0.0, 1.0))
				* (1.0 - hazard) * (0.78 + 0.22 * (1.0 - vegetation)), 0.0, 1.0
			)
			spawn_bytes[index] = _u8(spawn)

	var images := {
		"height": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RF, height_bytes),
		"normals": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RGBA8, normal_bytes),
		"slope": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RF, slope_bytes),
		"water_depth": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RF, water_depth_bytes),
		"water_mask": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, water_mask_bytes),
		"flow": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RGBA8, flow_bytes),
		"soil_type": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, soil_type_bytes),
		"soil_moisture": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, soil_moisture_bytes),
		"soil_depth": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RF, soil_depth_bytes),
		"rock_type": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, rock_type_bytes),
		"surface_material": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, surface_bytes),
		"vegetation_density": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, vegetation_bytes),
		"resources": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_RGBA8, resource_bytes),
		"snow_ice": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, snow_ice_bytes),
		"spawn_mask": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, spawn_bytes),
		"hazard": Image.create_from_data(safe_resolution, safe_resolution, false, Image.FORMAT_R8, hazard_bytes),
	}
	var metadata := {
		"local_contract_version": GENERATOR_CONTRACT_VERSION,
		"planet_id": id,
		"generator_version": version,
		"global_cell": cell,
		"resolution": safe_resolution,
		"zone_size_m": ZONE_SIZE_M,
		"sample_spacing_m": spacing_m,
		"absolute_origin_m": [float(cell.x) * ZONE_SIZE_M, float(cell.y) * ZONE_SIZE_M],
		"projection": PlanetGridContract.PROJECTION_ID,
		"seed": seed,
		"authoritative_layers": images.keys(),
		"macro_constraints": ["elevation", "climate", "hydrology", "biome", "tectonics", "resources"],
		"excluded_from_physics": ["departments", "regions", "countries", "continents"],
		"soil_catalog_version": 1,
	}
	var result := {"metadata": metadata, "images": images, "cache_hit": false}
	if cache != null:
		cache.save_zone(result)
	return result

static func _height_at_global(gx: float, gy: float, sampler: GlobalMacroSampler,
		params: Dictionary) -> float:
	var macro := _macro_at_global(gx, gy, sampler)
	var base_height := float(macro["height_m"])
	var stress := float(macro["tectonic_stress"])
	var seed := int(params.get("seed", 0))
	var planet_width_m := float(sampler.dimensions.x) * ZONE_SIZE_M
	var x_m := gx * ZONE_SIZE_M
	var y_m := gy * ZONE_SIZE_M
	var detail := _terrain_detail(x_m, y_m, planet_width_m, seed, stress)
	var erosion := _regional_erosion(x_m, y_m, planet_width_m, seed, base_height,
		float(macro["precipitation"]))
	return base_height + detail - erosion

static func _macro_at_global(gx: float, gy: float, sampler: GlobalMacroSampler) -> Dictionary:
	# Bounded Y / periodic X continuous bilinear macro field. At integer global
	# coordinates this evaluates exactly to that cell's authoritative sample.
	var x0 := floori(gx)
	var y0 := clampi(floori(gy), 0, sampler.dimensions.y - 1)
	var u = gx - floor(gx)
	var v := clampf(gy - floor(gy), 0.0, 1.0)
	var y1 := mini(y0 + 1, sampler.dimensions.y - 1)
	var a := sampler.sample(Vector2i(x0, y0))
	var b := sampler.sample(Vector2i(x0 + 1, y0))
	var c := sampler.sample(Vector2i(x0, y1))
	var d := sampler.sample(Vector2i(x0 + 1, y1))
	return {
		"height_m": _bilinear(a, b, c, d, "height_m", u, v),
		"temperature_c": _bilinear(a, b, c, d, "temperature_c", u, v),
		"precipitation": clampf(_bilinear(a, b, c, d, "precipitation", u, v), 0.0, 1.0),
		"river_flux": maxf(_bilinear(a, b, c, d, "river_flux", u, v), 0.0),
		"tectonic_stress": maxf(_bilinear(a, b, c, d, "tectonic_stress", u, v), 0.0),
		"water_strength": _bilinear_water(a, b, c, d, u, v),
		"water_type": _nearest_int(gx, gy, sampler, "water_type", 0),
		"biome_id": _nearest_int(gx, gy, sampler, "biome_id", -1),
		"flow_direction": _nearest_int(gx, gy, sampler, "flow_direction", 255),
		"plate_id": _nearest_int(gx, gy, sampler, "plate_id", -1),
		"resources_rgba": _bilinear_vec4(a, b, c, d, "resources_rgba", u, v),
	}

static func _local_water(x_m: float, y_m: float, planet_width_m: float,
		height_m: float, sea_level: float, macro: Dictionary, seed: int) -> Dictionary:
	var global_water := clampf(float(macro["water_strength"]), 0.0, 1.0)
	var coast_noise := (_value_noise_meters(x_m, y_m, planet_width_m, seed + 1801, 85.0) - 0.5) * 0.22
	var standing_water := global_water > 0.52 + coast_noise
	var standing_depth := maxf(sea_level - height_m, 0.0) if standing_water else 0.0

	var flux := maxf(float(macro["river_flux"]), 0.0)
	var river_strength := clampf(log(1.0 + flux) / 8.0, 0.0, 1.0)
	var direction := _flow_vector(int(macro["flow_direction"]))
	if direction == Vector2.ZERO:
		var angle := _value_noise_meters(x_m, y_m, planet_width_m, seed + 1811, 900.0) * TAU
		direction = Vector2(cos(angle), sin(angle))
	var perpendicular := Vector2(-direction.y, direction.x)
	var center_noise := (_value_noise_meters(x_m, y_m, planet_width_m, seed + 1823, 140.0) - 0.5) * 75.0
	var across := fposmod(Vector2(x_m, y_m).dot(perpendicular) + center_noise, ZONE_SIZE_M) - ZONE_SIZE_M * 0.5
	var half_width := 1.5 + river_strength * 18.0
	var river := river_strength > 0.035 and absf(across) <= half_width
	var river_depth := (0.25 + river_strength * 4.5) * (1.0 - clampf(absf(across) / maxf(half_width, 0.001), 0.0, 1.0)) if river else 0.0
	var depth := maxf(standing_depth, river_depth)
	var local_type := int(macro["water_type"]) if standing_water else (3 if river else 0)
	var flow_strength := river_strength if river else (0.08 if standing_water else 0.0)
	return {
		"type": local_type,
		"depth_m": depth,
		"river": river,
		"standing": standing_water,
		"coast": clampf(1.0 - absf(global_water - 0.5) * 8.0, 0.0, 1.0),
		"flow": direction.normalized(),
		"flow_strength": flow_strength,
	}

static func _soil_and_surface(x_m: float, y_m: float, planet_width_m: float,
		height_m: float, slope_rad: float, macro: Dictionary, water: Dictionary,
		params: Dictionary, seed: int) -> Dictionary:
	var planet_type := int(params.get("planet_type", 0))
	var precipitation := clampf(float(macro["precipitation"]), 0.0, 1.0)
	var temperature := float(macro["temperature_c"])
	var coast := float(water["coast"])
	var river_wet := 0.45 if bool(water["river"]) else 0.0
	var drainage := _value_noise_meters(x_m, y_m, planet_width_m, seed + 2101, 120.0)
	var moisture := clampf(precipitation * 0.72 + coast * 0.16 + river_wet + (1.0 - drainage) * 0.16, 0.0, 1.0)
	if planet_type in [3, 5]:
		moisture = 0.0
	var slope01 := clampf(slope_rad / deg_to_rad(55.0), 0.0, 1.0)
	var stress := clampf(float(macro["tectonic_stress"]), 0.0, 1.0)
	var sediment := clampf((1.0 - slope01) * (0.35 + moisture * 0.65), 0.0, 1.0)
	var soil_depth := clampf((1.0 - slope01) * (0.25 + sediment * 2.4), 0.0, 3.0)
	soil_depth *= 0.65 + 0.7 * _value_noise_meters(x_m, y_m, planet_width_m, seed + 2111, 55.0)
	if planet_type in [3, 5]:
		soil_depth = 0.05 + 0.45 * (1.0 - slope01)

	var rock_type := LocalSurfaceCatalog.RockType.SEDIMENTARY
	if planet_type in [3, 5]:
		rock_type = LocalSurfaceCatalog.RockType.REGOLITH
	elif stress > 0.68:
		rock_type = LocalSurfaceCatalog.RockType.METAMORPHIC
	elif stress > 0.42:
		rock_type = LocalSurfaceCatalog.RockType.IGNEOUS
	elif _value_noise_meters(x_m, y_m, planet_width_m, seed + 2129, 600.0) > 0.84:
		rock_type = LocalSurfaceCatalog.RockType.VOLCANIC

	var soil_type := LocalSurfaceCatalog.SoilType.DIRT
	if planet_type in [3, 5]:
		soil_type = LocalSurfaceCatalog.SoilType.REGOLITH
	elif slope_rad > deg_to_rad(42.0) or soil_depth < 0.12:
		soil_type = LocalSurfaceCatalog.SoilType.ROCK
	elif slope_rad > deg_to_rad(28.0):
		soil_type = LocalSurfaceCatalog.SoilType.GRAVEL
	elif coast > 0.48 and slope_rad < deg_to_rad(12.0):
		soil_type = LocalSurfaceCatalog.SoilType.SAND
	elif moisture > 0.82 and slope_rad < deg_to_rad(8.0) and temperature < 16.0:
		soil_type = LocalSurfaceCatalog.SoilType.PEAT
	elif moisture > 0.70 and slope_rad < deg_to_rad(12.0):
		soil_type = LocalSurfaceCatalog.SoilType.SILT
	elif sediment > 0.72 and drainage < 0.38:
		soil_type = LocalSurfaceCatalog.SoilType.CLAY
	elif rock_type == LocalSurfaceCatalog.RockType.VOLCANIC:
		soil_type = LocalSurfaceCatalog.SoilType.VOLCANIC
	elif moisture < 0.10 and coast < 0.1 and absf(height_m) < 250.0 and drainage < 0.25:
		soil_type = LocalSurfaceCatalog.SoilType.SALT

	var surface := LocalSurfaceCatalog.SurfaceMaterial.DIRT
	if float(water["depth_m"]) > 1.5:
		surface = LocalSurfaceCatalog.SurfaceMaterial.DEEP_WATER
	elif float(water["depth_m"]) > 0.01:
		surface = LocalSurfaceCatalog.SurfaceMaterial.SHALLOW_WATER
	elif temperature < -8.0 and moisture > 0.18:
		surface = LocalSurfaceCatalog.SurfaceMaterial.SNOW
	elif soil_type == LocalSurfaceCatalog.SoilType.ROCK:
		surface = LocalSurfaceCatalog.SurfaceMaterial.BARE_ROCK
	elif soil_type == LocalSurfaceCatalog.SoilType.GRAVEL:
		surface = LocalSurfaceCatalog.SurfaceMaterial.GRAVEL
	elif soil_type == LocalSurfaceCatalog.SoilType.SAND:
		surface = LocalSurfaceCatalog.SurfaceMaterial.SAND
	elif soil_type == LocalSurfaceCatalog.SoilType.PEAT:
		surface = LocalSurfaceCatalog.SurfaceMaterial.PEAT
	elif soil_type == LocalSurfaceCatalog.SoilType.SALT:
		surface = LocalSurfaceCatalog.SurfaceMaterial.SALT_CRUST
	elif moisture > 0.70:
		surface = LocalSurfaceCatalog.SurfaceMaterial.MUD
	elif moisture > 0.32:
		surface = LocalSurfaceCatalog.SurfaceMaterial.GRASS

	return {
		"soil_type": soil_type,
		"rock_type": rock_type,
		"soil_depth_m": soil_depth,
		"moisture": moisture,
		"surface": surface,
	}

static func _vegetation_density(x_m: float, y_m: float, planet_width_m: float,
		slope_rad: float, macro: Dictionary, water: Dictionary, material: Dictionary,
		params: Dictionary, seed: int) -> float:
	if int(params.get("planet_type", 0)) in [3, 5] or float(water["depth_m"]) > 0.01:
		return 0.0
	var moisture := float(material["moisture"])
	var temp := float(macro["temperature_c"])
	var temperature_fit := clampf(1.0 - absf(temp - 18.0) / 42.0, 0.0, 1.0)
	var slope_fit := 1.0 - smoothstep(deg_to_rad(24.0), deg_to_rad(48.0), slope_rad)
	var biome_factor := 0.55 + 0.45 * _value_noise_meters(x_m, y_m, planet_width_m,
		seed + 3109 + maxi(int(macro["biome_id"]), 0) * 17, 70.0)
	return clampf(moisture * temperature_fit * slope_fit * biome_factor, 0.0, 1.0)

static func _local_resources(x_m: float, y_m: float, planet_width_m: float,
		macro: Dictionary, material: Dictionary, seed: int) -> Vector4:
	var macro_resources: Vector4 = macro["resources_rgba"]
	var geology := 0.75 + 0.25 * float(material["soil_depth_m"]) / 3.0
	var r := clampf((0.25 + macro_resources.x * 0.75) * _ridged_noise(x_m, y_m, planet_width_m, seed + 4103, 110.0) * geology, 0.0, 1.0)
	var g := clampf((0.25 + macro_resources.y * 0.75) * _ridged_noise(x_m, y_m, planet_width_m, seed + 4111, 75.0), 0.0, 1.0)
	var b := clampf((0.25 + macro_resources.z * 0.75) * _ridged_noise(x_m, y_m, planet_width_m, seed + 4127, 45.0), 0.0, 1.0)
	var a := clampf((0.25 + macro_resources.w * 0.75) * _ridged_noise(x_m, y_m, planet_width_m, seed + 4133, 28.0), 0.0, 1.0)
	return Vector4(r, g, b, a)

static func _snow_ice(height_m: float, macro: Dictionary, water: Dictionary,
		material: Dictionary) -> float:
	var temperature := float(macro["temperature_c"]) - maxf(height_m, 0.0) * 0.0012
	var moisture := float(material["moisture"])
	if float(water["depth_m"]) > 0.05 and temperature < -3.0:
		return clampf((-temperature - 3.0) / 18.0, 0.0, 1.0)
	if temperature < 0.0:
		return clampf((-temperature) / 22.0, 0.0, 1.0) * clampf(moisture * 1.8, 0.0, 1.0)
	return 0.0

static func _hazard(slope_rad: float, water: Dictionary, material: Dictionary,
		snow_ice: float) -> float:
	var steep := smoothstep(deg_to_rad(28.0), deg_to_rad(55.0), slope_rad)
	var water_hazard := clampf(float(water["depth_m"]) / 1.2, 0.0, 1.0)
	var mud := 0.72 if int(material["surface"]) == LocalSurfaceCatalog.SurfaceMaterial.MUD else 0.0
	var peat := 0.55 if int(material["surface"]) == LocalSurfaceCatalog.SurfaceMaterial.PEAT else 0.0
	return maxf(maxf(steep, water_hazard), maxf(maxf(mud, peat), snow_ice * 0.55))

static func _terrain_detail(x_m: float, y_m: float, planet_width_m: float,
		seed: int, tectonic_stress: float) -> float:
	var broad := (_value_noise_meters(x_m, y_m, planet_width_m, seed + 101, 240.0) - 0.5) * 30.0
	var medium := (_value_noise_meters(x_m, y_m, planet_width_m, seed + 211, 82.0) - 0.5) * 11.0
	var fine := (_value_noise_meters(x_m, y_m, planet_width_m, seed + 307, 24.0) - 0.5) * 3.2
	return (broad + medium + fine) * (1.0 + clampf(tectonic_stress, 0.0, 1.0) * 0.45)

static func _regional_erosion(x_m: float, y_m: float, planet_width_m: float,
		seed: int, macro_height: float, precipitation: float) -> float:
	# Absolute regional patch field (~250 m support), not a per-zone simulation.
	# Adjacent zones therefore evaluate the same incised valley solution.
	var drainage := _value_noise_meters(x_m, y_m, planet_width_m, seed + 701, 260.0)
	var branch := _value_noise_meters(x_m, y_m, planet_width_m, seed + 719, 95.0)
	var incision := pow(clampf(1.0 - absf(drainage - (0.44 + (branch - 0.5) * 0.08)) * 7.0, 0.0, 1.0), 2.0)
	var relief := clampf(absf(macro_height) / 1800.0, 0.12, 1.0)
	return incision * relief * (0.35 + clampf(precipitation, 0.0, 1.0) * 0.65) * 19.0

static func _bilinear(a: Dictionary, b: Dictionary, c: Dictionary, d: Dictionary,
		key: String, u: float, v: float) -> float:
	var top := lerpf(float(a.get(key, 0.0)), float(b.get(key, 0.0)), u)
	var bottom := lerpf(float(c.get(key, 0.0)), float(d.get(key, 0.0)), u)
	return lerpf(top, bottom, v)

static func _bilinear_water(a: Dictionary, b: Dictionary, c: Dictionary, d: Dictionary,
		u: float, v: float) -> float:
	var aw := 1.0 if int(a.get("water_type", 0)) != 0 else 0.0
	var bw := 1.0 if int(b.get("water_type", 0)) != 0 else 0.0
	var cw := 1.0 if int(c.get("water_type", 0)) != 0 else 0.0
	var dw := 1.0 if int(d.get("water_type", 0)) != 0 else 0.0
	return lerpf(lerpf(aw, bw, u), lerpf(cw, dw, u), v)

static func _bilinear_vec4(a: Dictionary, b: Dictionary, c: Dictionary, d: Dictionary,
		key: String, u: float, v: float) -> Vector4:
	var av: Vector4 = a.get(key, Vector4.ZERO)
	var bv: Vector4 = b.get(key, Vector4.ZERO)
	var cv: Vector4 = c.get(key, Vector4.ZERO)
	var dv: Vector4 = d.get(key, Vector4.ZERO)
	return av.lerp(bv, u).lerp(cv.lerp(dv, u), v)

static func _nearest_int(gx: float, gy: float, sampler: GlobalMacroSampler,
		key: String, fallback: int) -> int:
	var cell := Vector2i(roundi(gx), clampi(roundi(gy), 0, sampler.dimensions.y - 1))
	return int(sampler.sample(cell).get(key, fallback))

static func _flow_vector(direction: int) -> Vector2:
	# D8 convention used by the tiled path; unknown values fall back to a
	# deterministic absolute direction in _local_water.
	var dirs := [
		Vector2(1, 0), Vector2(1, 1).normalized(), Vector2(0, 1), Vector2(-1, 1).normalized(),
		Vector2(-1, 0), Vector2(-1, -1).normalized(), Vector2(0, -1), Vector2(1, -1).normalized(),
	]
	return dirs[direction] if direction >= 0 and direction < dirs.size() else Vector2.ZERO

static func _value_noise_meters(x_m: float, y_m: float, planet_width_m: float,
		seed: int, feature_m: float) -> float:
	var scale := maxf(feature_m, 0.01)
	var ix := floori(x_m / scale)
	var iy := floori(y_m / scale)
	var fx := _fade(x_m / scale - floor(x_m / scale))
	var fy := _fade(y_m / scale - floor(y_m / scale))
	var wrap_cells := maxi(roundi(planet_width_m / scale), 1)
	var a := _hash01(posmod(ix, wrap_cells), iy, seed)
	var b := _hash01(posmod(ix + 1, wrap_cells), iy, seed)
	var c := _hash01(posmod(ix, wrap_cells), iy + 1, seed)
	var d := _hash01(posmod(ix + 1, wrap_cells), iy + 1, seed)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)

static func _ridged_noise(x_m: float, y_m: float, planet_width_m: float,
		seed: int, feature_m: float) -> float:
	return 1.0 - absf(_value_noise_meters(x_m, y_m, planet_width_m, seed, feature_m) * 2.0 - 1.0)

static func _hash01(x: int, y: int, seed: int) -> float:
	var h := AbsoluteFieldSampler.hash_u32(
		int(x) * 73856093 ^ int(y) * 19349663 ^ seed * 83492791
	)
	return float(h) / 4294967295.0

static func _fade(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

static func _alloc(count: int, bytes_per_pixel: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count * bytes_per_pixel)
	return out

static func _u8(value: float) -> int:
	return clampi(roundi(clampf(value, 0.0, 1.0) * 255.0), 0, 255)

static func _write_rgba8(output: PackedByteArray, index: int, value: Vector4) -> void:
	var offset := index * 4
	output[offset] = _u8(value.x)
	output[offset + 1] = _u8(value.y)
	output[offset + 2] = _u8(value.z)
	output[offset + 3] = _u8(value.w)

static func _write_flow(output: PackedByteArray, index: int, water: Dictionary) -> void:
	var direction: Vector2 = water["flow"]
	_write_rgba8(output, index, Vector4(
		direction.x * 0.5 + 0.5,
		direction.y * 0.5 + 0.5,
		float(water["flow_strength"]),
		float(water["coast"]),
	))
