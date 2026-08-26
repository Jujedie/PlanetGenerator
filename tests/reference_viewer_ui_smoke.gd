extends Node

func _ready() -> void:
	var master_scene := load("res://data/scn/master.tscn") as PackedScene
	var master := master_scene.instantiate()
	add_child(master)
	var project_path := ProjectSettings.globalize_path("user://temp/planet_project.json")
	if FileAccess.file_exists(project_path):
		master.call("_load_planet_project", project_path)
		master.call("_set_generation_phase_text", "GEN_STATUS_COMPLETE")
		master.call("_set_generation_memory_text", "GEN_STATUS_COMPLETED_IN", {"seconds": "13.36"})
		var progress := master.get("_generation_progress_bar") as ProgressBar
		progress.value = 100.0
	await get_tree().process_frame
	await get_tree().process_frame

	var viewer_layer := master.get_node_or_null("ReferenceViewerLayer") as CanvasLayer
	assert(viewer_layer != null)
	var viewer_root := viewer_layer.get_node_or_null("ReferenceViewer") as Control
	assert(viewer_root != null)
	var map_viewport := viewer_root.get_node_or_null("MapViewport") as Control
	var controls := viewer_root.get_node_or_null("MapViewerControls") as Control
	assert(map_viewport != null and map_viewport.size.x > 1000.0)
	assert(controls != null and controls.position.y > map_viewport.position.y + map_viewport.size.y)
	master.call("_show_parameters_workspace")
	assert(not viewer_layer.visible)
	var return_layer := master.get_node_or_null("ViewerReturnLayer") as CanvasLayer
	assert(return_layer != null and return_layer.visible)
	master.call("_show_viewer_workspace")
	assert(viewer_layer.visible and not return_layer.visible)

	DirAccess.make_dir_recursive_absolute("user://temp")
	var capture_path := "user://temp/reference_viewer_smoke.png"
	if DisplayServer.get_name() != "headless":
		var capture := get_viewport().get_texture().get_image()
		var capture_error := capture.save_png(capture_path)
		assert(capture_error == OK)
		master.call("_show_parameters_workspace")
		await get_tree().process_frame
		var parameter_capture := get_viewport().get_texture().get_image()
		var parameter_capture_error := parameter_capture.save_png("user://temp/parameter_workspace_smoke.png")
		assert(parameter_capture_error == OK)
	print("Reference viewer UI smoke: PASS — ", ProjectSettings.globalize_path(capture_path))
	get_tree().quit()
