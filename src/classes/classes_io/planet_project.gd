class_name PlanetProject
extends RefCounted

## Milestone 7.1 — Reloadable Planet Projects

const PROJECT_VERSION := 1
const FILE_NAME := "planet_project.json"
const PREFERRED_MAP_ORDER := [
	"final_map", "cartographic_map", "elevation", "elevation_alt", "water_colored",
	"river_map", "river_type", "biome", "region_colored", "land_region",
	"land_country", "land_continent", "ocean_region_colored", "sea_region",
	"sea_basin", "sea_ocean", "grid_overlay",
]

static func save(output_dir: String, generation_params: Dictionary,
		exported_files: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(output_dir)
	var layers: Dictionary = {}
	var keys := exported_files.keys(); keys.sort()
	for key in keys:
		var path := str(exported_files[key])
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		layers[str(key)] = {
			"path": _relative_path(output_dir, path),
			"sha256": FileAccess.get_sha256(path),
			"kind": _kind_for_path(path),
		}
	var manifest := {
		"planet_project_version": PROJECT_VERSION,
		"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		"planet_name": str(generation_params.get("planet_name", "Generated Planet")),
		"seed": int(generation_params.get("seed", 0)),
		"planet_type": int(generation_params.get("planet_type", 0)),
		"created_unix": int(Time.get_unix_time_from_system()),
		"root": ".",
		"parameters": PlanetManifest._stable_parameters(generation_params),
		"layers": layers,
	}
	var path := output_dir.path_join(FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[PlanetProject] Unable to write " + path)
		return ""
	file.store_string(JSON.stringify(manifest, "  ", true))
	file.close()
	return path


static func load_project(path_or_directory: String) -> Dictionary:
	var manifest_path := path_or_directory
	if DirAccess.dir_exists_absolute(path_or_directory):
		manifest_path = path_or_directory.path_join(FILE_NAME)
	if manifest_path.get_file() != FILE_NAME or not FileAccess.file_exists(manifest_path):
		return {"ok": false, "reason": "planet_project.json not found", "path": manifest_path}
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "unable to open project manifest", "path": manifest_path}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return {"ok": false, "reason": "invalid project JSON", "path": manifest_path}
	var manifest: Dictionary = parsed
	if int(manifest.get("planet_project_version", -1)) > PROJECT_VERSION:
		return {"ok": false, "reason": "project was created by a newer data version", "path": manifest_path}
	var root := manifest_path.get_base_dir()
	var resolved: Dictionary = {}
	var broken: Array[String] = []
	for key in manifest.get("layers", {}):
		var entry: Dictionary = manifest["layers"][key]
		var rel := str(entry.get("path", ""))
		var absolute := root.path_join(rel).simplify_path()
		resolved[str(key)] = absolute
		if not FileAccess.file_exists(absolute):
			broken.append(str(key))
	return {
		"ok": broken.is_empty(),
		"reason": "" if broken.is_empty() else "project references missing files",
		"manifest_path": manifest_path,
		"root": root,
		"manifest": manifest,
		"layers": resolved,
		"missing_layers": broken,
		"maps": display_maps_from_layers(resolved),
	}


static func display_maps_from_layers(layers: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var used: Dictionary = {}
	for key in PREFERRED_MAP_ORDER:
		if layers.has(key):
			var path := str(layers[key])
			if path.get_extension().to_lower() == "png" and FileAccess.file_exists(path):
				result.append(path); used[key] = true
	var remaining := layers.keys(); remaining.sort()
	for key in remaining:
		if used.has(key):
			continue
		var path := str(layers[key])
		if path.get_extension().to_lower() == "png" and FileAccess.file_exists(path):
			result.append(path)
	return result


static func _relative_path(root: String, path: String) -> String:
	var normalized_root := root.simplify_path().trim_suffix("/") + "/"
	var normalized_path := path.simplify_path()
	if normalized_path.begins_with(normalized_root):
		return normalized_path.substr(normalized_root.length())
	return normalized_path


static func _kind_for_path(path: String) -> String:
	match path.get_extension().to_lower():
		"png": return "map"
		"json": return "metadata"
		_: return "data"
