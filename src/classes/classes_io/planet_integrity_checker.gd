class_name PlanetIntegrityChecker
extends RefCounted

## Milestone 7 — Global Data Integrity
##
## Runs after rendering while authoritative GPU textures are still alive.
## The checker is deliberately read-only: it never repairs data. Every repair
## stays in the simulation/normalization stage so a PASS means the produced
## planet was already coherent.

const INVALID_ID: int = 0xFFFFFFFF
const CARDINAL := [
	Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
]
const ADMIN_EXPORT_KEYS := [
	"region_colored", "ocean_region_colored",
	"land_region", "land_country", "land_continent",
	"sea_region", "sea_basin", "sea_ocean",
]

static func run(gpu: GPUContext, generation_params: Dictionary,
		exported_files: Dictionary, preloaded_layers: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var checks: Array[Dictionary] = []
	var metrics: Dictionary = {}
	var dimensions := _resolve_dimensions(gpu, generation_params, exported_files)
	var width := dimensions.x
	var height := dimensions.y
	var pixel_count := width * height

	_add(checks, "geometry.dimensions", "PASS" if pixel_count > 0 else "FAIL",
		"Canonical raster dimensions are available.", {
			"width": width, "height": height, "pixels": pixel_count,
		})
	if pixel_count <= 0:
		return _finish(checks, metrics, started)

	var water := _read_texture(gpu, "water_mask", preloaded_layers)
	var land_ids := _read_texture(gpu, "region_map", preloaded_layers)
	var sea_ids := _read_texture(gpu, "ocean_region_map", preloaded_layers)
	var flow_direction := _read_texture(gpu, "flow_direction", preloaded_layers)
	var river_flux := _read_texture(gpu, "river_flux", preloaded_layers)
	var reused_layers: Array[String] = []
	for layer_name in ["water_mask", "region_map", "ocean_region_map", "flow_direction", "river_flux"]:
		if preloaded_layers.has(layer_name):
			reused_layers.append(layer_name)
	metrics["preloaded_layers"] = reused_layers

	_check_raw_sizes(checks, water, land_ids, sea_ids, flow_direction, river_flux, pixel_count)
	_check_land_water_coverage(checks, metrics, water, land_ids, sea_ids, width, height,
		int(generation_params.get("planet_type", 0)))
	_check_department_topology(checks, metrics, "land", land_ids, water, width, height,
		float(generation_params.get("nb_cases_regions", 50.0)), false)
	_check_department_topology(checks, metrics, "sea", sea_ids, water, width, height,
		float(generation_params.get("nb_cases_ocean_regions", 100.0)), true)
	_check_hydrology(checks, metrics, water, flow_direction, river_flux, pixel_count,
		int(generation_params.get("planet_type", 0)))
	_check_exports(checks, metrics, exported_files, width, height,
		int(generation_params.get("planet_type", 0)), sea_ids.size() == pixel_count * 4,
		generation_params)
	_check_river_export_consistency(checks, metrics, exported_files,
		int(generation_params.get("planet_type", 0)), generation_params)
	_check_administrative_colors(checks, metrics, exported_files)

	return _finish(checks, metrics, started)


static func save_report(output_dir: String, report: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(output_dir)
	var path := output_dir.path_join("integrity_report.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[Integrity] Unable to write report: " + path)
		return ""
	file.store_string(JSON.stringify(report, "  ", true))
	file.close()
	FileChecksumCache.invalidate(path)
	_print_summary(report)
	return path


static func validate_snapshot(snapshot: Dictionary, width: int, height: int,
		generation_params: Dictionary = {}) -> Dictionary:
	## Pure-CPU entry point used by regression tests.
	var started := Time.get_ticks_usec()
	var checks: Array[Dictionary] = []
	var metrics: Dictionary = {}
	var pixel_count := width * height
	var water: PackedByteArray = snapshot.get("water_mask", PackedByteArray())
	var land_ids: PackedByteArray = snapshot.get("region_map", PackedByteArray())
	var sea_ids: PackedByteArray = snapshot.get("ocean_region_map", PackedByteArray())
	var flow_direction: PackedByteArray = snapshot.get("flow_direction", PackedByteArray())
	var river_flux: PackedByteArray = snapshot.get("river_flux", PackedByteArray())
	_check_raw_sizes(checks, water, land_ids, sea_ids, flow_direction, river_flux, pixel_count)
	_check_land_water_coverage(checks, metrics, water, land_ids, sea_ids, width, height,
		int(generation_params.get("planet_type", 0)))
	_check_department_topology(checks, metrics, "land", land_ids, water, width, height,
		float(generation_params.get("nb_cases_regions", 50.0)), false)
	_check_department_topology(checks, metrics, "sea", sea_ids, water, width, height,
		float(generation_params.get("nb_cases_ocean_regions", 100.0)), true)
	_check_hydrology(checks, metrics, water, flow_direction, river_flux, pixel_count,
		int(generation_params.get("planet_type", 0)))
	return _finish(checks, metrics, started)


static func _resolve_dimensions(gpu: GPUContext, params: Dictionary,
		exported_files: Dictionary) -> Vector2i:
	if gpu != null and gpu.rd != null:
		for texture_name in ["water_mask", "region_map", "geo"]:
			if gpu.textures.has(texture_name) and gpu.textures[texture_name].is_valid():
				var fmt = gpu.rd.texture_get_format(gpu.textures[texture_name])
				return Vector2i(fmt.width, fmt.height)
	var fallback: Vector2i = params.get("global_dimensions", params.get("resolution", Vector2i.ZERO))
	if fallback != Vector2i.ZERO:
		return fallback
	for path_value in exported_files.values():
		var path := str(path_value)
		if path.get_extension().to_lower() != "png" or not FileAccess.file_exists(path):
			continue
		var image := Image.new()
		if image.load(path) == OK:
			return image.get_size()
	return Vector2i.ZERO


static func _read_texture(gpu: GPUContext, texture_name: String,
		preloaded_layers: Dictionary = {}) -> PackedByteArray:
	if preloaded_layers.has(texture_name):
		var preloaded = preloaded_layers[texture_name]
		if preloaded is PackedByteArray:
			return preloaded
	if gpu == null or gpu.rd == null:
		return PackedByteArray()
	if not gpu.textures.has(texture_name):
		return PackedByteArray()
	var rid: RID = gpu.textures[texture_name]
	if not rid.is_valid():
		return PackedByteArray()
	return gpu.readback_texture_raw(texture_name)


static func _check_raw_sizes(checks: Array[Dictionary], water: PackedByteArray,
		land_ids: PackedByteArray, sea_ids: PackedByteArray,
		flow: PackedByteArray, flux: PackedByteArray, pixel_count: int) -> void:
	_check_optional_size(checks, "layer.water_mask", water, pixel_count, "R8UI")
	_check_optional_size(checks, "layer.region_map", land_ids, pixel_count * 4, "R32UI")
	_check_optional_size(checks, "layer.ocean_region_map", sea_ids, pixel_count * 4, "R32UI")
	_check_optional_size(checks, "layer.flow_direction", flow, pixel_count, "R8UI")
	_check_optional_size(checks, "layer.river_flux", flux, pixel_count * 4, "R32F")


static func _check_optional_size(checks: Array[Dictionary], check_id: String,
		data: PackedByteArray, expected: int, format_name: String) -> void:
	if data.is_empty():
		_add(checks, check_id, "SKIP", "Authoritative layer is not present in this generation.", {
			"format": format_name,
		})
		return
	var ok := data.size() == expected
	_add(checks, check_id, "PASS" if ok else "FAIL",
		"Layer byte size matches its declared format." if ok else "Layer byte size is inconsistent.", {
			"format": format_name, "expected_bytes": expected, "actual_bytes": data.size(),
		})


static func _check_land_water_coverage(checks: Array[Dictionary], metrics: Dictionary,
		water: PackedByteArray, land_ids: PackedByteArray, sea_ids: PackedByteArray,
		width: int, height: int, planet_type: int) -> void:
	var pixels := width * height
	if water.size() != pixels:
		_add(checks, "surface.coverage", "SKIP", "water_mask unavailable; coverage cannot be verified.")
		return
	var has_land_ids := land_ids.size() == pixels * 4
	var has_sea_ids := sea_ids.size() == pixels * 4
	var land_pixels := 0
	var water_pixels := 0
	var land_missing := 0
	var land_on_water := 0
	var sea_missing := 0
	var sea_on_land := 0
	for index in range(pixels):
		var is_water := water[index] > 0
		if is_water:
			water_pixels += 1
		else:
			land_pixels += 1
		if has_land_ids:
			var land_id := int(land_ids.decode_u32(index * 4))
			if is_water and land_id != INVALID_ID:
				land_on_water += 1
			elif not is_water and land_id == INVALID_ID:
				land_missing += 1
		if has_sea_ids:
			var sea_id := int(sea_ids.decode_u32(index * 4))
			if not is_water and sea_id != INVALID_ID:
				sea_on_land += 1
			elif is_water and sea_id == INVALID_ID:
				sea_missing += 1
	metrics["surface"] = {
		"land_pixels": land_pixels,
		"water_pixels": water_pixels,
		"land_unassigned": land_missing,
		"land_id_on_water": land_on_water,
		"water_unassigned": sea_missing,
		"sea_id_on_land": sea_on_land,
	}
	if has_land_ids:
		var land_ok := land_missing == 0 and land_on_water == 0
		_add(checks, "administration.land_coverage", "PASS" if land_ok else "FAIL",
			"Every dry pixel has exactly land administration semantics." if land_ok else "Land administration disagrees with water_mask.", {
				"unassigned_land": land_missing, "land_ids_on_water": land_on_water,
			})
	else:
		_add(checks, "administration.land_coverage", "SKIP", "region_map unavailable.")

	# No-atmosphere/sterile worlds deliberately skip the water simulation and
	# maritime hierarchy. On every other solid-surface planet, all generated
	# water must receive a maritime department.
	if planet_type in [3, 5] or water_pixels == 0:
		_add(checks, "administration.sea_coverage", "SKIP", "This planet has no maritime administrative domain.")
	elif has_sea_ids:
		var sea_ok := sea_missing == 0 and sea_on_land == 0
		_add(checks, "administration.sea_coverage", "PASS" if sea_ok else "FAIL",
			"Every water pixel has exactly maritime administration semantics." if sea_ok else "Maritime administration disagrees with water_mask.", {
				"unassigned_water": sea_missing, "sea_ids_on_land": sea_on_land,
			})
	else:
		_add(checks, "administration.sea_coverage", "FAIL", "ocean_region_map is missing despite surface water.")


static func _check_department_topology(checks: Array[Dictionary], metrics: Dictionary,
		domain_name: String, ids: PackedByteArray, water: PackedByteArray,
		width: int, height: int, target_cells: float, maritime: bool) -> void:
	var pixels := width * height
	if ids.size() != pixels * 4 or water.size() != pixels:
		_add(checks, "administration.%s_topology" % domain_name, "SKIP", "Required raw layers are unavailable.")
		return
	var visited := PackedByteArray()
	visited.resize(pixels)
	visited.fill(0)
	var component_count_by_id: Dictionary = {}
	var area_by_id: Dictionary = {}
	var neighbor_ids: Dictionary = {}
	var seam_contacts := 0
	for start in range(pixels):
		if visited[start] != 0:
			continue
		var in_domain := (water[start] > 0) if maritime else (water[start] == 0)
		if not in_domain:
			visited[start] = 1
			continue
		var raw_id := int(ids.decode_u32(start * 4))
		if raw_id == INVALID_ID:
			visited[start] = 1
			continue
		component_count_by_id[raw_id] = int(component_count_by_id.get(raw_id, 0)) + 1
		var queue: Array[int] = [start]
		visited[start] = 1
		var head := 0
		var area := 0
		while head < queue.size():
			var current := queue[head]
			head += 1
			area += 1
			var x := current % width
			var y := current / width
			for delta in CARDINAL:
				var ny = y + delta.y
				if ny < 0 or ny >= height:
					continue
				var raw_nx = x + delta.x
				var nx := posmod(raw_nx, width)
				if raw_nx != nx:
					seam_contacts += 1
				var neighbor = ny * width + nx
				var neighbor_domain := (water[neighbor] > 0) if maritime else (water[neighbor] == 0)
				if not neighbor_domain:
					continue
				var neighbor_id := int(ids.decode_u32(neighbor * 4))
				if neighbor_id != raw_id:
					if neighbor_id != INVALID_ID:
						if not neighbor_ids.has(raw_id):
							neighbor_ids[raw_id] = {}
						neighbor_ids[raw_id][neighbor_id] = true
					continue
				if visited[neighbor] == 0:
					visited[neighbor] = 1
					queue.append(neighbor)
		area_by_id[raw_id] = int(area_by_id.get(raw_id, 0)) + area

	var disconnected: Array = []
	for raw_id in component_count_by_id:
		if int(component_count_by_id[raw_id]) > 1:
			disconnected.append(raw_id)
	var target := maxf(target_cells, 1.0)
	var min_cells := maxi(2, int(ceil(target * 0.45)))
	var max_cells := maxi(min_cells + 1, int(ceil(target * 1.85)))
	var undersized_mergeable := 0
	var undersized_topological := 0
	var undersized_locally_consistent := 0
	var undersized_blocked_by_maximum := 0
	var oversized := 0
	var min_area := 0x7FFFFFFF
	var max_area := 0
	var total_area := 0
	for raw_id in area_by_id:
		var area := int(area_by_id[raw_id])
		min_area = mini(min_area, area)
		max_area = maxi(max_area, area)
		total_area += area
		if area < min_cells:
			var neighbors: Dictionary = neighbor_ids.get(raw_id, {})
			if neighbors.is_empty():
				undersized_topological += 1
			else:
				var neighbor_areas: Array[int] = []
				var has_safe_merge := false
				for neighbor_id in neighbors.keys():
					var neighbor_area := int(area_by_id.get(neighbor_id, 0))
					if neighbor_area <= 0:
						continue
					neighbor_areas.append(neighbor_area)
					if area + neighbor_area <= max_cells:
						has_safe_merge = true
				neighbor_areas.sort()
				var local_minimum := min_cells
				if not neighbor_areas.is_empty():
					var local_median := neighbor_areas[int((neighbor_areas.size() - 1) / 2)]
					local_minimum = mini(min_cells, maxi(int(ceil(float(local_median) * 0.55)), 2))
				if area >= local_minimum:
					undersized_locally_consistent += 1
				elif has_safe_merge:
					undersized_mergeable += 1
				elif area <= maxi(int(floor(float(min_cells) * 0.5)), 2):
					undersized_mergeable += 1
				else:
					undersized_blocked_by_maximum += 1
		elif area > max_cells:
			oversized += 1
	if area_by_id.is_empty():
		min_area = 0
	var topology_ok := disconnected.is_empty()
	_add(checks, "administration.%s_unique_components" % domain_name,
		"PASS" if topology_ok else "FAIL",
		"Every administrative ID is one wrap-aware connected component." if topology_ok else "One or more IDs are reused by disconnected components.", {
			"ids_with_multiple_components": disconnected.size(),
			"sample_ids": disconnected.slice(0, mini(8, disconnected.size())),
			"seam_neighbor_checks": seam_contacts,
		})
	var size_ok := undersized_mergeable == 0
	_add(checks, "administration.%s_sizes" % domain_name,
		"PASS" if size_ok else "FAIL",
		"Department size contract is respected; isolated small components are explicit topological exceptions." if size_ok else "Mergeable undersized departments remain.", {
			"target_cells": target, "minimum_cells": min_cells, "maximum_cells": max_cells,
			"department_count": area_by_id.size(), "minimum_actual": min_area,
			"maximum_actual": max_area, "mean_actual": float(total_area) / float(maxi(area_by_id.size(), 1)),
			"undersized_mergeable": undersized_mergeable,
			"undersized_topological_exceptions": undersized_topological,
			"undersized_locally_consistent": undersized_locally_consistent,
			"undersized_blocked_by_maximum": undersized_blocked_by_maximum,
			"oversized_soft_limit": oversized,
		})
	metrics["%s_departments" % domain_name] = {
		"count": area_by_id.size(), "disconnected_ids": disconnected.size(),
		"undersized_mergeable": undersized_mergeable,
		"undersized_topological_exceptions": undersized_topological,
		"undersized_locally_consistent": undersized_locally_consistent,
		"undersized_blocked_by_maximum": undersized_blocked_by_maximum,
		"oversized_soft_limit": oversized,
	}


static func _check_hydrology(checks: Array[Dictionary], metrics: Dictionary,
		water: PackedByteArray, flow: PackedByteArray, flux: PackedByteArray,
		pixel_count: int, planet_type: int) -> void:
	if planet_type in [3, 5]:
		var invalid_water := 0
		var invalid_direction := 0
		var invalid_flux := 0
		if water.size() == pixel_count:
			for value in water:
				if value != 0:
					invalid_water += 1
		if flow.size() == pixel_count:
			for value in flow:
				if value != 255:
					invalid_direction += 1
		if flux.size() == pixel_count * 4:
			for value in flux.to_float32_array():
				if not is_zero_approx(float(value)):
					invalid_flux += 1
		var disabled_available := (
			water.size() == pixel_count
			and flow.size() == pixel_count
			and flux.size() == pixel_count * 4
		)
		var disabled_valid := (
			disabled_available
			and invalid_water == 0
			and invalid_direction == 0
			and invalid_flux == 0
		)
		metrics["disabled_hydrology"] = {
			"available": disabled_available,
			"nonzero_water_pixels": invalid_water,
			"non_sentinel_flow_pixels": invalid_direction,
			"nonzero_flux_pixels": invalid_flux,
		}
		_add(checks, "hydrology.disabled_contract",
			"PASS" if disabled_valid else "FAIL",
			"Disabled hydrology layers contain canonical zero/sentinel values."
				if disabled_valid
				else "A disabled hydrology layer contains undefined or non-canonical values.",
			metrics["disabled_hydrology"])
		_add(checks, "hydrology.values", "SKIP", "Hydrology is disabled for this planet type.")
		return
	var bad_direction := 0
	if not flow.is_empty() and flow.size() == pixel_count:
		for value in flow:
			if value > 7 and value != 255:
				bad_direction += 1
	var bad_flux := 0
	var max_flux := 0.0
	if not flux.is_empty() and flux.size() == pixel_count * 4:
		for index in range(pixel_count):
			var value := flux.decode_float(index * 4)
			if is_nan(value) or is_inf(value) or value < 0.0:
				bad_flux += 1
			else:
				max_flux = maxf(max_flux, value)
	metrics["hydrology"] = {
		"invalid_flow_direction_pixels": bad_direction,
		"invalid_flux_pixels": bad_flux,
		"maximum_flux": max_flux,
	}
	var available := flow.size() == pixel_count and flux.size() == pixel_count * 4
	if not available:
		_add(checks, "hydrology.values", "SKIP", "Hydrology raw layers are not both available.")
		return
	var ok := bad_direction == 0 and bad_flux == 0
	_add(checks, "hydrology.values", "PASS" if ok else "FAIL",
		"Flow directions and accumulated flux values are valid." if ok else "Hydrology contains invalid directions or non-finite/negative flux.", metrics["hydrology"])


static func _check_exports(checks: Array[Dictionary], metrics: Dictionary,
		exported_files: Dictionary, width: int, height: int, planet_type: int,
		has_ocean_region_layer: bool, generation_params: Dictionary) -> void:
	var wrong_size: Array[String] = []
	var missing: Array[String] = []
	var png_count := 0
	for key in exported_files:
		var path := str(exported_files[key])
		if path.is_empty() or not FileAccess.file_exists(path):
			missing.append(str(key))
			continue
		if path.get_extension().to_lower() != "png":
			continue
		png_count += 1
		# Reading/decompressing every PNG is extremely expensive for complete
		# exports (116+ resource maps). Dimensions live in the fixed PNG IHDR
		# header, so validate them without decoding the pixel payload.
		var dimensions := _png_header_dimensions(path)
		if dimensions.x != width or dimensions.y != height:
			wrong_size.append(str(key))
	# Validate the keys actually returned by PlanetExporter, not obsolete aliases.
	var required_candidates := [
		["topographie_map", "topographie_map.png"],
		["biome_colored", "biome_map.png"],
		["final_map", "final_map.png"],
		["region_colored", "departement_map.png"],
	]
	if planet_type == 6:
		required_candidates = [["final_map", "final_map.png"]]
	elif planet_type not in [3, 5]:
		required_candidates.append_array([
			["eaux_map", "eaux_map.png"],
			["river_map", "river_map.png"],
			["river_type_map", "river_type_map.png"],
		])
		# Completely dry planets intentionally skip maritime administration and do
		# not create ocean_region_map/ocean_region_colored. The raw-layer checks
		# already fail if a maritime domain should exist but its authoritative layer
		# is missing, so only require this export when that layer actually exists.
		if has_ocean_region_layer:
			required_candidates.append(["ocean_region_colored", "departement_mer_map.png"])
	var required: Array[String] = []
	for candidate in required_candidates:
		if ExportCatalog.should_keep(str(candidate[0]), generation_params, str(candidate[1])):
			required.append(str(candidate[0]))
	var required_missing: Array[String] = []
	for key in required:
		if not exported_files.has(key) or not FileAccess.file_exists(str(exported_files[key])):
			required_missing.append(key)
	var ok := missing.is_empty() and wrong_size.is_empty() and required_missing.is_empty()
	metrics["exports"] = {
		"png_count": png_count, "missing_paths": missing,
		"wrong_dimensions": wrong_size, "required_missing": required_missing,
	}
	_add(checks, "exports.files", "PASS" if ok else "FAIL",
		"All announced PNG exports exist and share the canonical dimensions." if ok else "Export set contains missing or inconsistent files.", metrics["exports"])


static func _png_header_dimensions(path: String) -> Vector2i:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 24:
		return Vector2i.ZERO
	var header := file.get_buffer(24)
	file.close()
	if header.size() < 24:
		return Vector2i.ZERO
	var signature := [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
	for i in range(signature.size()):
		if int(header[i]) != int(signature[i]):
			return Vector2i.ZERO
	if header[12] != 0x49 or header[13] != 0x48 or header[14] != 0x44 or header[15] != 0x52:
		return Vector2i.ZERO
	var width := (
		(int(header[16]) << 24) | (int(header[17]) << 16)
		| (int(header[18]) << 8) | int(header[19])
	)
	var height := (
		(int(header[20]) << 24) | (int(header[21]) << 16)
		| (int(header[22]) << 8) | int(header[23])
	)
	return Vector2i(width, height)


static func _check_river_export_consistency(checks: Array[Dictionary], metrics: Dictionary,
		exported_files: Dictionary, planet_type: int, generation_params: Dictionary) -> void:
	if planet_type in [3, 5, 6]:
		_add(checks, "hydrology.river_export_consistency", "SKIP",
			"This planet type has no exported surface river network.")
		return
	var wants_river := ExportCatalog.should_keep(
		"river_map", generation_params, "river_map.png"
	)
	var wants_type := ExportCatalog.should_keep(
		"river_type_map", generation_params, "river_type_map.png"
	)
	if not wants_river or not wants_type:
		_add(checks, "hydrology.river_export_consistency", "SKIP",
			"The selected export preset does not request both river presentation maps.")
		return
	if not exported_files.has("river_map") or not exported_files.has("river_type_map"):
		_add(checks, "hydrology.river_export_consistency", "FAIL",
			"river_map.png or river_type_map.png is missing.")
		return
	var river := Image.new()
	var river_type := Image.new()
	if river.load(str(exported_files["river_map"])) != OK or river_type.load(str(exported_files["river_type_map"])) != OK:
		_add(checks, "hydrology.river_export_consistency", "FAIL",
			"One of the river PNGs cannot be decoded.")
		return
	if river.get_size() != river_type.get_size():
		_add(checks, "hydrology.river_export_consistency", "FAIL",
			"River and river-type maps have different dimensions.", {
				"river_size": [river.get_width(), river.get_height()],
				"river_type_size": [river_type.get_width(), river_type.get_height()],
			})
		return
	var river_pixels := 0
	var type_pixels := 0
	var only_river := 0
	var only_type := 0
	for y in range(river.get_height()):
		for x in range(river.get_width()):
			var in_river := river.get_pixel(x, y).a > 0.0
			var in_type := river_type.get_pixel(x, y).a > 0.0
			if in_river:
				river_pixels += 1
			if in_type:
				type_pixels += 1
			if in_river and not in_type:
				only_river += 1
			elif in_type and not in_river:
				only_type += 1
	var ok := only_river == 0 and only_type == 0
	metrics["river_exports"] = {
		"river_pixels": river_pixels,
		"river_type_pixels": type_pixels,
		"only_in_river_map": only_river,
		"only_in_river_type_map": only_type,
	}
	_add(checks, "hydrology.river_export_consistency", "PASS" if ok else "FAIL",
		"river_type_map classifies exactly the same river pixels as river_map." if ok else "river_type_map and river_map disagree on river presence.",
		metrics["river_exports"])


static func _check_administrative_colors(checks: Array[Dictionary], metrics: Dictionary,
		exported_files: Dictionary) -> void:
	var color_owner: Dictionary = {}
	var collisions: Array[Dictionary] = []
	var entity_colors := 0
	for key in ADMIN_EXPORT_KEYS:
		if not exported_files.has(key):
			continue
		var path := str(exported_files[key])
		if not FileAccess.file_exists(path) or path.get_extension().to_lower() != "png":
			continue
		var image := Image.new()
		if image.load(path) != OK:
			continue
		var local_colors: Dictionary = {}
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				var color := image.get_pixel(x, y)
				if color.a < 0.5:
					continue
				var encoded := color.to_rgba32()
				local_colors[encoded] = true
		for encoded in local_colors:
			entity_colors += 1
			if color_owner.has(encoded) and color_owner[encoded] != key:
				collisions.append({"rgba32": encoded, "first": color_owner[encoded], "second": key})
			else:
				color_owner[encoded] = key
	metrics["administrative_colors"] = {
		"unique_namespace_colors": color_owner.size(),
		"level_color_instances": entity_colors,
		"cross_level_collisions": collisions.size(),
	}
	var ok := collisions.is_empty()
	_add(checks, "administration.unique_colors", "PASS" if ok else "FAIL",
		"Administrative export levels use a collision-free shared color namespace." if ok else "The same opaque administrative color is reused by different levels.", {
			"collisions": collisions.slice(0, mini(12, collisions.size())),
			"collision_count": collisions.size(),
		})


static func _add(checks: Array[Dictionary], check_id: String, status: String,
		message: String, data: Dictionary = {}) -> void:
	checks.append({
		"id": check_id,
		"status": status,
		"message": message,
		"data": data,
	})


static func _finish(checks: Array[Dictionary], metrics: Dictionary, started_usec: int) -> Dictionary:
	var failed := 0
	var warnings := 0
	var passed := 0
	var skipped := 0
	for check in checks:
		match str(check.get("status", "")):
			"FAIL": failed += 1
			"WARN": warnings += 1
			"PASS": passed += 1
			"SKIP": skipped += 1
	var result := "FAIL" if failed > 0 else ("WARN" if warnings > 0 else "PASS")
	return {
		"integrity_report_version": 2,
		"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		"created_unix": int(Time.get_unix_time_from_system()),
		"result": result,
		"summary": {"passed": passed, "failed": failed, "warnings": warnings, "skipped": skipped},
		"checks": checks,
		"metrics": metrics,
		"runtime_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}


static func _print_summary(report: Dictionary) -> void:
	print("\nPLANET INTEGRITY REPORT")
	print("=======================")
	for check in report.get("checks", []):
		var status := str(check.get("status", ""))
		print("%-42s %s" % [str(check.get("id", "")), status])
		if status in ["FAIL", "WARN", "SKIP"]:
			print("    ↳ ", str(check.get("message", "")))
			var data: Dictionary = check.get("data", {})
			if not data.is_empty():
				print("      ", data)
	print("-----------------------")
	print("RESULT: ", report.get("result", "UNKNOWN"), "  ", report.get("summary", {}))
