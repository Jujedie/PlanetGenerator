extends Node

func _ready() -> void:
	assert(int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) >= 1600)
	assert(not bool(ProjectSettings.get_setting("display/window/size/maximize_disabled", true)))
	# A resizable 1600x900 canvas must support sub-1.0 scaling. Integer-only
	# scaling clips the logical UI whenever the OS window is smaller than 1600x900.
	assert(str(ProjectSettings.get_setting("display/window/stretch/scale_mode", "")) == "fractional")
	assert(UIPolish.human_bytes(1024) == "1.00 KiB")
	assert(UIPolish.human_bytes(1024 * 1024).ends_with("MiB"))
	assert(ExportCatalog.should_keep("plaques_map", {"export_preset": ExportCatalog.PRESET_STANDARD}))
	assert(ExportCatalog.should_keep("river_type_map", {"export_preset": ExportCatalog.PRESET_STANDARD}))
	assert(not ExportCatalog.should_keep(
		"aluminium_map",
		{"export_preset": ExportCatalog.PRESET_STANDARD},
		"user://export/maps/resources/aluminium_map.png"
	))
	assert(ExportCatalog.should_keep(
		"aluminium_map",
		{"export_preset": ExportCatalog.PRESET_COMPLETE},
		"user://export/maps/resources/aluminium_map.png"
	))
	assert(not ExportCatalog.should_keep(
		"plaques_bordures_map", {"export_preset": ExportCatalog.PRESET_COMPLETE}
	))
	assert(ExportCatalog.should_keep(
		"plaques_bordures_map", {"export_preset": ExportCatalog.PRESET_DEVELOPMENT}
	))
	assert(ExportCatalog.should_keep("eaux_map", {"export_preset": ExportCatalog.PRESET_MINIMAL}))
	assert(ExportCatalog.should_keep("biome_colored", {"export_preset": ExportCatalog.PRESET_MINIMAL}))
	assert(not ExportCatalog.should_keep(
		"temperature_colored", {"export_preset": ExportCatalog.PRESET_MINIMAL}
	))
	print("Milestone 7.7 UI polish regression: PASS")
	get_tree().quit()
