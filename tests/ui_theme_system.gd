extends Node


func _ready() -> void:
	var previous_theme: StringName = UITheme.current_theme_id
	var previous_locale := TranslationServer.get_locale()
	UITheme.set_theme(&"amber", false)
	var master := (load("res://data/scn/master.tscn") as PackedScene).instantiate()
	add_child(master)
	await get_tree().process_frame
	await get_tree().process_frame

	var parameters := master.get_node_or_null("ParameterWorkspaceLayer") as ParameterWorkspace
	var viewer := master.get_node_or_null("ReferenceViewerLayer") as ReferenceViewerWorkspace
	assert(parameters != null and viewer != null)
	assert(parameters.theme_select.item_count == UITheme.get_theme_ids().size())
	assert(viewer.theme_select.item_count == UITheme.get_theme_ids().size())
	_assert_theme_translations(parameters, viewer)
	var parameter_background := parameters.root.get_node("Background") as ColorRect
	var viewer_background := viewer.root.get_node("Background") as ColorRect
	var amber_title_size := parameters.title_label.get_theme_font_size("font_size")
	assert(_same_color(parameter_background.color, UITheme.color(&"background")))

	UITheme.set_theme(&"ocean", false)
	await get_tree().process_frame
	assert(parameters.theme_select.selected == UITheme.get_theme_index())
	assert(viewer.theme_select.selected == UITheme.get_theme_index())
	assert(_same_color(parameter_background.color, UITheme.color(&"background")))
	assert(_same_color(viewer_background.color, UITheme.color(&"background")))
	assert(_same_color(
		parameters.title_label.get_theme_color("font_color"),
		UITheme.color(&"accent")
	))
	assert(_same_color(
		viewer.phase_label.get_theme_color("font_color"),
		UITheme.color(&"accent")
	))
	assert(parameters.theme_select.get_popup().get_theme_font_size("font_size") >= 21)
	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute("user://temp")
		assert(get_viewport().get_texture().get_image().save_png(
			"user://temp/theme_ocean_parameters.png"
		) == OK)
		master.call("_show_viewer_workspace")
		await get_tree().process_frame
		assert(get_viewport().get_texture().get_image().save_png(
			"user://temp/theme_ocean_viewer.png"
		) == OK)
		master.call("_show_parameters_workspace")
		await get_tree().process_frame

	UITheme.set_theme(&"contrast", false)
	await get_tree().process_frame
	assert(parameters.title_label.get_theme_font_size("font_size") > amber_title_size)
	assert(_same_color(parameter_background.color, Color.BLACK))
	assert(_same_color(
		parameters.generate_button.get_theme_color("font_color"),
		UITheme.color(&"background")
	))

	if DisplayServer.get_name() != "headless":
		var capture := get_viewport().get_texture().get_image()
		assert(capture.save_png("user://temp/theme_contrast_smoke.png") == OK)

	UITheme.set_theme(previous_theme, false)
	TranslationServer.set_locale(previous_locale)
	print("UI theme system regression: PASS")
	get_tree().quit(0)


func _assert_theme_translations(
	parameters: ParameterWorkspace,
	viewer: ReferenceViewerWorkspace
) -> void:
	var expected := {
		"en": ["Amber", "Ocean", "High contrast", "UI theme"],
		"fr": ["Ambre", "Océan", "Contraste élevé", "Thème de l’interface"],
		"de": ["Bernstein", "Ozean", "Hoher Kontrast", "UI-Theme"],
	}
	for locale in expected:
		TranslationServer.set_locale(str(locale))
		parameters.refresh_translations()
		viewer.refresh_translations()
		var translated: Array = expected[locale]
		for index in range(3):
			assert(parameters.theme_select.get_item_text(index) == translated[index])
			assert(viewer.theme_select.get_item_text(index) == translated[index])
		assert(parameters.theme_select.tooltip_text == translated[3])
		assert(viewer.theme_select.tooltip_text == translated[3])


func _same_color(left: Color, right: Color) -> bool:
	return (
		absf(left.r - right.r) < 0.002
		and absf(left.g - right.g) < 0.002
		and absf(left.b - right.b) < 0.002
		and absf(left.a - right.a) < 0.002
	)
