extends Node

func _ready() -> void:
	var root := "user://m71_project_test"
	DirAccess.make_dir_recursive_absolute(root)
	var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.4, 0.6, 1.0))
	var png := root.path_join("final_map.png")
	assert(img.save_png(png) == OK)
	var project_path := PlanetProject.save(root, {"planet_name": "Test", "seed": 42}, {"final_map": png})
	assert(not project_path.is_empty())
	var loaded := PlanetProject.load_project(project_path)
	assert(loaded["ok"])
	assert(loaded["maps"].size() == 1)
	assert(str(loaded["maps"][0]).ends_with("final_map.png"))
	assert(_test_canonical_ui_map_order(root))
	print("Milestone 7.1 reloadable project regression: PASS")
	get_tree().quit()


func _test_canonical_ui_map_order(root: String) -> bool:
	var resources_dir := root.path_join("maps/resources")
	DirAccess.make_dir_recursive_absolute(resources_dir)
	var names := [
		"or_map.png", "pays_map.png", "river_type_map.png", "cartographic_map.png",
		"topographie_map.png", "eaux_map.png", "biome_map.png", "departement_map.png",
	]
	var layers: Dictionary = {}
	for i in range(names.size()):
		var filename: String = names[i]
		var destination := resources_dir.path_join(filename) if filename == "or_map.png" else root.path_join(filename)
		var image := Image.create(2, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(float(i + 1) / 10.0, 0.2, 0.3, 1.0))
		assert(image.save_png(destination) == OK)
		# Intentionally shuffled keys to prove exporter/dictionary order is ignored.
		layers["layer_%02d" % (names.size() - i)] = destination
	var ordered := PlanetProject.display_maps_from_layers(layers)
	var ordered_names: Array[String] = []
	for path in ordered:
		ordered_names.append(path.get_file())
	return ordered_names == [
		"topographie_map.png", "biome_map.png",
		"eaux_map.png", "river_type_map.png",
		"departement_map.png", "pays_map.png",
		"cartographic_map.png",
		"or_map.png",
	]
