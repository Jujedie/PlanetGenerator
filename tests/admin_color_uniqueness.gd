extends Node

const SAMPLE_PER_LEVEL := 4096
const LEVEL_COUNT := 8

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var seen_colors: Dictionary = {}
	var cursor := 0
	var deterministic := true
	var unique := true
	for level in range(LEVEL_COUNT):
		var ids: Array = []
		for index in range(SAMPLE_PER_LEVEL):
			ids.append(level * 1000000 + index)
		var colors := HierarchyBuilder.assign_colors(ids, cursor)
		var colors_repeat := HierarchyBuilder.assign_colors(ids, cursor)
		for gid in ids:
			var color: Color = colors[gid]
			var repeat: Color = colors_repeat[gid]
			var key := _rgba8_key(color)
			if seen_colors.has(key):
				unique = false
			seen_colors[key] = true
			deterministic = deterministic and key == _rgba8_key(repeat)
		cursor += ids.size()

	var no_data_key := "0,0,0,0"
	var no_opaque_black := not seen_colors.has("0,0,0,255")
	var isolated_ocean_unique := _test_isolated_ocean_components_keep_unique_ids()
	var passed := (
		unique
		and deterministic
		and no_opaque_black
		and not seen_colors.has(no_data_key)
		and seen_colors.size() == SAMPLE_PER_LEVEL * LEVEL_COUNT
		and isolated_ocean_unique
	)
	print("[AdminColors] entities=", seen_colors.size(),
		" unique=", unique, " deterministic=", deterministic,
		" avoids_no_data=", no_opaque_black,
		" isolated_ocean_unique=", isolated_ocean_unique)
	get_tree().quit(0 if passed else 1)

func _rgba8_key(color: Color) -> String:
	return "%d,%d,%d,%d" % [
		roundi(color.r * 255.0), roundi(color.g * 255.0),
		roundi(color.b * 255.0), roundi(color.a * 255.0),
	]


func _test_isolated_ocean_components_keep_unique_ids() -> bool:
	# Three physically disconnected water bodies deliberately start with the same
	# raw ID. normalize() must split them into three real departments; no later
	# distance-based consolidation is allowed to join them again.
	var w := 12
	var h := 3
	var water := PackedByteArray()
	water.resize(w * h)
	water.fill(0)
	var regions := PackedByteArray()
	regions.resize(w * h * 4)
	for index in range(w * h):
		regions.encode_u32(index * 4, DepartmentNormalizer.INVALID_ID)
	for point in [Vector2i(1, 1), Vector2i(5, 1), Vector2i(9, 1)]:
		var index := point.y * w + point.x
		water[index] = 1
		regions.encode_u32(index * 4, 7)

	var result := DepartmentNormalizer.normalize(
		regions, water, w, h, 10.0, 0.50, 1.85, false, true
	)
	if result.is_empty():
		return false
	var data: PackedByteArray = result["data"]
	var ids: Array = []
	for point in [Vector2i(1, 1), Vector2i(5, 1), Vector2i(9, 1)]:
		var region_id := int(data.decode_u32((point.y * w + point.x) * 4))
		if region_id == DepartmentNormalizer.INVALID_ID:
			return false
		ids.append(region_id)
	var unique_ids: Dictionary = {}
	for region_id in ids:
		unique_ids[region_id] = true
	if unique_ids.size() != 3:
		return false
	var colors := HierarchyBuilder.assign_colors(ids, 100000)
	var unique_colors: Dictionary = {}
	for region_id in ids:
		unique_colors[_rgba8_key(colors[region_id])] = true
	return unique_colors.size() == 3 and int(result["isolated_undersized"]) == 3
