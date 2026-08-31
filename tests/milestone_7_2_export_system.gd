extends Node

const RESOURCE_KEYS: Array[String] = ["aluminium_map", "or_map", "petrole_map"]


func _write_png(path: String, color: Color) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	img.fill(color)
	assert(img.save_png(path) == OK)


func _build_fixture(root: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(root)
	var paths: Dictionary = {}
	for pair in [
		["final_map", "final_map.png"],
		["grid_overlay", "grid_overlay.png"],
		["plaques_map", "plaques_map.png"],
		["plaques_bordures_map", "plaques_bordures_map.png"],
	]:
		var path := root.path_join(str(pair[1]))
		_write_png(path, Color(0.1, 0.2, 0.3, 1.0))
		paths[str(pair[0])] = path

	# Resource dictionary keys are dynamic and do not contain the word
	# "resource". The path must therefore drive preset classification.
	var legacy_resources := root.path_join("ressource")
	for resource_key in RESOURCE_KEYS:
		var resource_path := legacy_resources.path_join(resource_key + ".png")
		_write_png(resource_path, Color(0.4, 0.3, 0.2, 1.0))
		paths[resource_key] = resource_path

	# Simulate stale copies from older catalog layouts.
	for resource_key in RESOURCE_KEYS:
		_write_png(
			root.path_join("maps").path_join(resource_key + ".png"),
			Color(1.0, 0.0, 1.0, 1.0)
		)
	return paths


func _ready() -> void:
	var standard_root := "user://m72_export_standard"
	var standard := ExportCatalog.finalize_outputs(
		standard_root,
		_build_fixture(standard_root),
		{"export_preset": ExportCatalog.PRESET_STANDARD}
	)
	assert(standard.has("final_map"))
	assert(standard.has("grid_overlay"))
	assert(str(standard["grid_overlay"]).contains("/overlays/"))
	assert(standard.has("plaques_map"))
	assert(not standard.has("plaques_bordures_map"))
	for resource_key in RESOURCE_KEYS:
		assert(not standard.has(resource_key))
		assert(not FileAccess.file_exists(
			standard_root.path_join("maps").path_join(resource_key + ".png")
		))
		assert(not FileAccess.file_exists(
			standard_root.path_join("maps/resources").path_join(resource_key + ".png")
		))
	assert(standard.has("catalog"))

	var complete_root := "user://m72_export_complete"
	var complete := ExportCatalog.finalize_outputs(
		complete_root,
		_build_fixture(complete_root),
		{"export_preset": ExportCatalog.PRESET_COMPLETE}
	)
	assert(complete.has("plaques_map"))
	assert(not complete.has("plaques_bordures_map"))
	for resource_key in RESOURCE_KEYS:
		assert(complete.has(resource_key))
		assert(str(complete[resource_key]).contains("/maps/resources/"))

	var development_root := "user://m72_export_development"
	var development := ExportCatalog.finalize_outputs(
		development_root,
		_build_fixture(development_root),
		{"export_preset": ExportCatalog.PRESET_DEVELOPMENT}
	)
	assert(development.has("plaques_bordures_map"))
	assert(str(development["plaques_bordures_map"]).contains("/debug/"))
	for resource_key in RESOURCE_KEYS:
		assert(development.has(resource_key))

	print("Milestone 7.2 export system regression: PASS")
	get_tree().quit()
