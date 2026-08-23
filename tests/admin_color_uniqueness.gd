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
	var passed := (
		unique
		and deterministic
		and no_opaque_black
		and not seen_colors.has(no_data_key)
		and seen_colors.size() == SAMPLE_PER_LEVEL * LEVEL_COUNT
	)
	print("[AdminColors] entities=", seen_colors.size(),
		" unique=", unique, " deterministic=", deterministic,
		" avoids_no_data=", no_opaque_black)
	get_tree().quit(0 if passed else 1)

func _rgba8_key(color: Color) -> String:
	return "%d,%d,%d,%d" % [
		roundi(color.r * 255.0), roundi(color.g * 255.0),
		roundi(color.b * 255.0), roundi(color.a * 255.0),
	]
