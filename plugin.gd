@tool
extends EditorPlugin

## The public API is the global `class_name PlanetGeneratorService` facade.
## Stateful work lives in this deliberately different autoload name so Godot's
## global class namespace and autoload namespace never collide.
const AUTOLOAD_NAME := "PlanetGeneratorServiceRuntime"
const AUTOLOAD_PATH := "res://addons/planet_generator/runtime/service/planet_generator_service_runtime.gd"
const LEGACY_AUTOLOAD_NAME := "PlanetGeneratorService"
const LEGACY_AUTOLOAD_PATH := "res://addons/planet_generator/public/planet_generator_service.gd"


func _enable_plugin() -> void:
	# Migration from addon.1-addon.4. Those versions registered the public
	# service path itself as an autoload named PlanetGeneratorService.
	var legacy_setting := "autoload/%s" % LEGACY_AUTOLOAD_NAME
	if ProjectSettings.has_setting(legacy_setting):
		var legacy_existing := str(ProjectSettings.get_setting(legacy_setting, ""))
		if legacy_existing.trim_prefix("*") == LEGACY_AUTOLOAD_PATH:
			remove_autoload_singleton(LEGACY_AUTOLOAD_NAME)

	var setting_name := "autoload/%s" % AUTOLOAD_NAME
	if ProjectSettings.has_setting(setting_name):
		var existing := str(ProjectSettings.get_setting(setting_name, ""))
		if existing.trim_prefix("*") == AUTOLOAD_PATH:
			return
		push_error("[Planet Generator] Cannot register %s: an autoload with that name already exists (%s)." % [AUTOLOAD_NAME, existing])
		return
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	var setting_name := "autoload/%s" % AUTOLOAD_NAME
	if not ProjectSettings.has_setting(setting_name):
		return
	var existing := str(ProjectSettings.get_setting(setting_name, ""))
	if existing.trim_prefix("*") == AUTOLOAD_PATH:
		remove_autoload_singleton(AUTOLOAD_NAME)
