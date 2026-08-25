extends Node

func _ready() -> void:
	var root := "user://m72_export_test"
	DirAccess.make_dir_recursive_absolute(root)
	var paths := {}
	for pair in [["final_map", "final_map.png"], ["grid_overlay", "grid_overlay.png"], ["plates", "plaques_map.png"]]:
		var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.1, 0.2, 0.3, 1.0))
		var path := root.path_join(pair[1])
		assert(img.save_png(path) == OK)
		paths[pair[0]] = path

	# Legacy resource exporter uses `ressource/` and resource names do not carry
	# a generic "resource" prefix, e.g. aluminium_map / fer_map / or_map.
	var legacy_resources := root.path_join("ressource")
	DirAccess.make_dir_recursive_absolute(legacy_resources)
	for pair in [["aluminium_map", "aluminium_map.png"], ["or_map", "or_map.png"], ["petrole_map", "petrole_map.png"]]:
		var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.4, 0.3, 0.2, 1.0))
		var path := legacy_resources.path_join(pair[1])
		assert(img.save_png(path) == OK)
		paths[pair[0]] = path
	# Simulate stale copies left in maps/ by an older M7.2 generation. They
	# must disappear once the same resources have canonical outputs.
	var stale_maps := root.path_join("maps")
	DirAccess.make_dir_recursive_absolute(stale_maps)
	for filename in ["aluminium_map.png", "or_map.png", "petrole_map.png"]:
		var stale := Image.create(4, 2, false, Image.FORMAT_RGBA8)
		stale.fill(Color(1.0, 0.0, 1.0, 1.0))
		assert(stale.save_png(stale_maps.path_join(filename)) == OK)

	var result := ExportCatalog.finalize_outputs(root, paths, {"export_preset": "standard"})
	assert(result.has("final_map"))
	assert(str(result["final_map"]).contains("/maps/"))
	assert(result.has("grid_overlay"))
	assert(str(result["grid_overlay"]).contains("/overlays/"))
	assert(not result.has("plates"))
	for resource_key in ["aluminium_map", "or_map", "petrole_map"]:
		assert(result.has(resource_key))
		assert(str(result[resource_key]).contains("/maps/resources/"))
		assert(not FileAccess.file_exists(stale_maps.path_join(resource_key + ".png")))
	assert(not DirAccess.dir_exists_absolute(legacy_resources))
	assert(result.has("catalog"))
	print("Milestone 7.2 export system regression: PASS")
	get_tree().quit()
