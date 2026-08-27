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
		master.call("_show_parameters_workspace")
	await get_tree().process_frame
	await get_tree().process_frame

	var viewer_layer := master.get_node_or_null("ReferenceViewerLayer") as CanvasLayer
	assert(viewer_layer != null)
	var viewer_root := viewer_layer.get_node_or_null("ReferenceViewer") as Control
	assert(viewer_root != null)
	var parameter_layer := master.get_node_or_null("ParameterWorkspaceLayer") as ParameterWorkspace
	assert(parameter_layer != null)
	assert(parameter_layer.visible and not viewer_layer.visible)
	var map_viewport := viewer_root.get_node_or_null("MapViewport") as Control
	var controls := viewer_root.get_node_or_null("MapViewerControls") as Control
	assert(map_viewport != null and map_viewport.size.x > 1000.0)
	assert(controls != null and controls.position.y > map_viewport.position.y + map_viewport.size.y)
	var base_select := master.get("_viewer_base_select") as OptionButton
	assert(base_select != null and base_select.custom_minimum_size.y >= 44.0)
	var shortcut_label := viewer_root.find_child("ShortcutLabel", true, false) as Label
	assert(shortcut_label != null and shortcut_label.text.contains("A/Q/D"))
	var overlay_select := master.get("_viewer_overlay_select") as OptionButton
	assert(overlay_select != null)
	var overlay_original_index: int = maxi(overlay_select.selected, 0)
	var overlay_smoke_index: int = overlay_select.item_count
	overlay_select.add_item("Shortcut smoke")
	overlay_select.set_item_metadata(overlay_smoke_index, "")
	master.call("_cycle_viewer_overlay", -1)
	var overlay_expected_index: int = posmod(overlay_original_index - 1, overlay_select.item_count)
	assert(overlay_select.selected == overlay_expected_index)
	master.call("_cycle_viewer_overlay", 1)
	assert(overlay_select.selected == overlay_original_index)
	overlay_select.remove_item(overlay_smoke_index)
	overlay_select.select(clampi(overlay_original_index, 0, maxi(overlay_select.item_count - 1, 0)))
	assert(base_select.get_theme_font_size("font_size") >= 21)
	assert(base_select.get_popup().get_theme_font_size("font_size") >= 21)
	assert(base_select.get_popup().max_size.y <= 620)
	master.call("_show_parameters_workspace")
	assert(not viewer_layer.visible and parameter_layer.visible)
	var preview_shortcuts := parameter_layer.find_child("PreviewShortcuts", true, false) as Label
	assert(preview_shortcuts != null and preview_shortcuts.text.contains("A/Q/D"))
	var first_preview := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	first_preview.fill(Color(0.9, 0.1, 0.1, 1.0))
	var second_preview := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	second_preview.fill(Color(0.1, 0.2, 0.9, 1.0))
	DirAccess.make_dir_recursive_absolute("user://temp")
	var first_preview_path := "user://temp/shortcut_preview_a.png"
	var second_preview_path := "user://temp/shortcut_preview_b.png"
	assert(first_preview.save_png(first_preview_path) == OK)
	assert(second_preview.save_png(second_preview_path) == OK)
	var shortcut_maps: Array[String] = [first_preview_path, second_preview_path]
	master.set("maps", shortcut_maps)
	master.set("map_index", 0)
	master.call("_update_viewer_sources")
	master.call("_load_current_map")
	var cycle_event := InputEventKey.new()
	cycle_event.keycode = KEY_RIGHT
	cycle_event.pressed = true
	master.call("_unhandled_key_input", cycle_event)
	assert(int(master.get("map_index")) == 1)
	assert(parameter_layer.preview_texture.texture != null)
	var cycled_preview := parameter_layer.preview_texture.texture.get_image()
	assert(cycled_preview != null and cycled_preview.get_pixel(0, 0).b > cycled_preview.get_pixel(0, 0).r)
	assert(parameter_layer.template_select.custom_minimum_size.y >= 44.0)
	assert(parameter_layer.template_select.get_popup().get_theme_font_size("font_size") >= 21)
	var parameter_controls := parameter_layer.get("_controls") as Dictionary
	var seed_spin := parameter_controls.get("seed") as SpinBox
	var name_edit := parameter_controls.get("planet_name") as LineEdit
	assert(seed_spin != null and seed_spin.get_theme_icon("updown") != null)
	assert(seed_spin.get_line_edit().get_theme_font_size("font_size") >= 20)
	assert(name_edit != null and name_edit.get_theme_font_size("font_size") >= 20)
	assert(name_edit.get_theme_stylebox("focus").get_border_width(SIDE_LEFT) >= 2)
	assert(parameter_layer.find_child("RandomSeedButton", true, false) != null)
	assert(parameter_layer.find_child("RandomNameButton", true, false) != null)
	master.call("_show_viewer_workspace")
	assert(viewer_layer.visible and not parameter_layer.visible)

	DirAccess.make_dir_recursive_absolute("user://temp")
	var capture_path := "user://temp/reference_viewer_smoke.png"
	if DisplayServer.get_name() != "headless":
		var capture := get_viewport().get_texture().get_image()
		var capture_error := capture.save_png(capture_path)
		assert(capture_error == OK)
		base_select.show_popup()
		await get_tree().process_frame
		await get_tree().process_frame
		var popup_capture := get_viewport().get_texture().get_image()
		var popup_capture_error := popup_capture.save_png("user://temp/selection_menu_smoke.png")
		assert(popup_capture_error == OK)
		base_select.get_popup().hide()
		master.call("_show_parameters_workspace")
		await get_tree().process_frame
		var parameter_capture := get_viewport().get_texture().get_image()
		var parameter_capture_error := parameter_capture.save_png("user://temp/parameter_workspace_smoke.png")
		assert(parameter_capture_error == OK)
		parameter_layer.template_select.show_popup()
		await get_tree().process_frame
		await get_tree().process_frame
		var parameter_popup_capture := get_viewport().get_texture().get_image()
		var parameter_popup_capture_error := parameter_popup_capture.save_png("user://temp/parameter_selection_menu_smoke.png")
		assert(parameter_popup_capture_error == OK)
	print("Reference viewer UI smoke: PASS — ", ProjectSettings.globalize_path(capture_path))
	get_tree().quit()
