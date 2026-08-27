extends Node

func _ready() -> void:
	assert(int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) >= 1600)
	assert(not bool(ProjectSettings.get_setting("display/window/size/maximize_disabled", true)))
	assert(UIPolish.human_bytes(1024) == "1.00 KiB")
	assert(UIPolish.human_bytes(1024 * 1024).ends_with("MiB"))
	assert(ExportCatalog.should_keep("plates", {"export_preset": ExportCatalog.PRESET_STANDARD}))
	assert(ExportCatalog.should_keep("river_type", {"export_preset": ExportCatalog.PRESET_STANDARD}))
	assert(not ExportCatalog.should_keep("plates_borders", {"export_preset": ExportCatalog.PRESET_STANDARD}))
	print("Milestone 7.7 UI polish regression: PASS")
	get_tree().quit()
