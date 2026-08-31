extends Node

const Normalizer = preload("res://src/classes/classes_io/department_normalizer.gd")
const INVALID_ID := 0xFFFFFFFF


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var land_contract := _test_water_mask_land_contract()
	var seam_merge := _test_wrapped_seam_merge()
	var vertical_boundary := _test_no_vertical_wrap()
	var tiny_merge := _test_tiny_leftover_merge()
	var island_exception := _test_isolated_island_exception()
	var maritime_coverage := _test_maritime_isolated_micro_absorption()
	print("[DepartmentRegression] water_mask_land_contract=", land_contract)
	print("[DepartmentRegression] wrapped_seam_merge=", seam_merge)
	print("[DepartmentRegression] no_vertical_wrap=", vertical_boundary)
	print("[DepartmentRegression] tiny_leftover_merge=", tiny_merge)
	print("[DepartmentRegression] isolated_island_exception=", island_exception)
	print("[DepartmentRegression] maritime_isolated_micro_absorption=", maritime_coverage)
	if not land_contract:
		push_error("Dry below-sea pixels were incorrectly rejected as administrative land")
	if not seam_merge:
		push_error("A tiny seam department did not merge through wrapped X adjacency")
	if not vertical_boundary:
		push_error("Top and bottom map borders were incorrectly treated as adjacent")
	if not tiny_merge:
		push_error("An undersized land leftover was not absorbed")
	if not island_exception:
		push_error("A small isolated island was merged across water")
	if not maritime_coverage:
		push_error("Isolated maritime micro-departments were not absorbed while preserving coverage")
	get_tree().quit(0 if (
		land_contract and seam_merge and vertical_boundary
		and tiny_merge and island_exception and maritime_coverage
	) else 1)


func _test_water_mask_land_contract() -> bool:
	var w := 8
	var h := 4
	var water := PackedByteArray()
	water.resize(w * h)
	water.fill(0) # Entire test surface is dry, including the below-sea half.
	var geo := PackedByteArray()
	geo.resize(w * h * 16)
	for y in range(h):
		for x in range(w):
			geo.encode_float((y * w + x) * 16, 25.0 if y < 2 else -25.0)
	var land := Normalizer.build_land_mask(water, geo, w, h, 0.0)
	var regions := _empty_regions(w, h)
	for index in range(w * h):
		regions.encode_u32(index * 4, 7)
	var result := Normalizer.normalize(regions, land, w, h, 8.0)
	if result.is_empty():
		return false
	var normalized: PackedByteArray = result["data"]
	for y in range(h):
		for x in range(w):
			var assigned := int(normalized.decode_u32((y * w + x) * 4)) != INVALID_ID
			if not assigned:
				return false
	return int(result["removed_non_land"]) == 0


func _test_wrapped_seam_merge() -> bool:
	var w := 10
	var h := 5
	var land := PackedByteArray()
	land.resize(w * h)
	land.fill(0)
	var regions := _empty_regions(w, h)
	for y in range(h):
		_set_land_region(land, regions, w, 8, y, 100)
		_set_land_region(land, regions, w, 9, y, 100)
		_set_land_region(land, regions, w, 2, y, 300)
	for y in range(1, 4):
		_set_land_region(land, regions, w, 0, y, 200)
	_set_land_region(land, regions, w, 1, 2, 300)

	var result := Normalizer.normalize(regions, land, w, h, 10.0, 0.50, 1.85)
	var normalized: PackedByteArray = result["data"]
	var seam_neighbor := int(normalized.decode_u32((2 * w + 9) * 4))
	var former_tiny := int(normalized.decode_u32((2 * w + 0) * 4))
	var flat_neighbor := int(normalized.decode_u32((2 * w + 1) * 4))
	return (
		former_tiny == seam_neighbor
		and former_tiny != flat_neighbor
		and int(result["undersized_nonisolated"]) == 0
	)


func _test_no_vertical_wrap() -> bool:
	var w := 5
	var h := 4
	var land := PackedByteArray()
	land.resize(w * h)
	land.fill(0)
	var regions := _empty_regions(w, h)
	_set_land_region(land, regions, w, 2, 0, 77)
	_set_land_region(land, regions, w, 2, h - 1, 77)
	var result := Normalizer.normalize(regions, land, w, h, 4.0, 0.45, 1.85)
	var normalized: PackedByteArray = result["data"]
	return (
		int(normalized.decode_u32((2) * 4))
		!= int(normalized.decode_u32(((h - 1) * w + 2) * 4))
		and int(result["split_fragments"]) == 1
	)


func _test_tiny_leftover_merge() -> bool:
	var w := 9
	var h := 5
	var land := PackedByteArray()
	land.resize(w * h)
	land.fill(1)
	var regions := _empty_regions(w, h)
	for y in range(h):
		for x in range(w):
			var region_id := 10 if x <= 3 else 20
			if x == 4:
				region_id = 10 if y < 2 else 20
			regions.encode_u32((y * w + x) * 4, region_id)
	regions.encode_u32((2 * w + 4) * 4, 30)

	var result := Normalizer.normalize(regions, land, w, h, 20.0, 0.45, 1.85)
	var normalized: PackedByteArray = result["data"]
	var leftover_id := int(normalized.decode_u32((2 * w + 4) * 4))
	var left_id := int(normalized.decode_u32((2 * w + 3) * 4))
	var right_id := int(normalized.decode_u32((2 * w + 5) * 4))
	return (
		(leftover_id == left_id or leftover_id == right_id)
		and _unique_ids(normalized).size() == 2
		and int(result["merged_components"]) >= 1
		and int(result["undersized_nonisolated"]) == 0
	)


func _test_isolated_island_exception() -> bool:
	var w := 7
	var h := 3
	var land := PackedByteArray()
	land.resize(w * h)
	land.fill(0)
	var regions := _empty_regions(w, h)
	_set_land_region(land, regions, w, 1, 1, 11)
	for y in range(h):
		for x in range(4, 7):
			_set_land_region(land, regions, w, x, y, 22)
	var result := Normalizer.normalize(regions, land, w, h, 12.0, 0.50, 1.85)
	var normalized: PackedByteArray = result["data"]
	return (
		int(normalized.decode_u32((1 * w + 1) * 4)) == 11
		and int(normalized.decode_u32((1 * w + 3) * 4)) == INVALID_ID
		and int(result["isolated_undersized"]) == 1
	)


func _test_maritime_isolated_micro_absorption() -> bool:
	var w := 16
	var h := 5
	var water := PackedByteArray()
	water.resize(w * h)
	water.fill(0)
	var regions := _empty_regions(w, h)

	# Valid 20-cell water department.
	for y in range(h):
		for x in range(4):
			_set_land_region(water, regions, w, x, y, 10)
	# Two disconnected water bodies below the 5-cell minimum.
	_set_land_region(water, regions, w, 8, 1, 100)
	_set_land_region(water, regions, w, 8, 2, 100)
	_set_land_region(water, regions, w, 12, 3, 200)

	var normalized := Normalizer.normalize(
		regions, water, w, h, 10.0, 0.50, 1.85, false, true
	)
	if normalized.is_empty():
		return false
	var water_types := water.duplicate()
	for index in range(w * h):
		if water_types[index] != 0:
			water_types[index] = 2
	var absorbed := Normalizer.consolidate_disconnected_undersized(
		normalized["data"], water, water_types, w, h, 10.0, 0.50, 1.85
	)
	if absorbed.is_empty():
		return false
	var data: PackedByteArray = absorbed["data"]
	var counts: Dictionary = {}
	for index in range(w * h):
		if water[index] == 0:
			continue
		var region_id := int(data.decode_u32(index * 4))
		if region_id == INVALID_ID:
			return false
		counts[region_id] = int(counts.get(region_id, 0)) + 1
	for size in counts.values():
		if int(size) < 5:
			return false
	return (
		int(absorbed["unassigned_mask_cells"]) == 0
		and int(absorbed["grouped_departments"]) >= 1
	)


func _empty_regions(w: int, h: int) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(w * h * 4)
	for index in range(w * h):
		data.encode_u32(index * 4, INVALID_ID)
	return data


func _set_land_region(land: PackedByteArray, regions: PackedByteArray,
		w: int, x: int, y: int, region_id: int) -> void:
	var index := y * w + x
	land[index] = 1
	regions.encode_u32(index * 4, region_id)


func _unique_ids(data: PackedByteArray) -> Dictionary:
	var ids: Dictionary = {}
	for offset in range(0, data.size(), 4):
		var region_id := int(data.decode_u32(offset))
		if region_id != INVALID_ID:
			ids[region_id] = true
	return ids
