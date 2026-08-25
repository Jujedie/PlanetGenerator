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
	print("Milestone 7.1 reloadable project regression: PASS")
	get_tree().quit()
