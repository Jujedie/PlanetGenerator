class_name PGPlanetProject
extends RefCounted

## Milestone 7.1 — Reloadable Planet Projects

const PROJECT_VERSION := 1
const FILE_NAME := "planet_project.json"
# Canonical display order for the standalone UI.  Keep this path/file based so
# generated planets and reloaded PGPlanetProject manifests are presented in the
# exact same order regardless of dictionary insertion order.
#
# 0. Natural/topographic maps
# 1. Hydrology
# 2. Administrative hierarchy
# 3. Other presentation/debug maps
# 4. Resources (always last)
const NATURAL_MAP_ORDER := [
	"topographie_map.png",
	"topographie_map_grey.png",
	"topology_map.png",
	"final_map.png",
	"plaques_map.png",
	"plaques_bordures_map.png",
	"biome_map.png",
	"temperature_map.png",
	"precipitation_map.png",
	"clouds_map.png",
	"ice_caps_map.png",
]

const HYDROLOGY_MAP_ORDER := [
	"eaux_map.png",
	"water_map.png",
	"river_map.png",
	"river_type_map.png",
]

const ADMIN_MAP_ORDER := [
	"departement_map.png",
	"region_map.png",
	"pays_map.png",
	"continent_map.png",
	"departement_mer_map.png",
	"region_mer_map.png",
	"bassin_map.png",
	"ocean_map.png",
]

const OTHER_MAP_ORDER := [
	"cartographic_map.png",
	"grid_overlay.png",
	"preview.png",
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
			"sha256": PGFileChecksumCache.sha256(path),
			"kind": _kind_for_path(path),
		}
	var manifest := {
		"planet_project_version": PROJECT_VERSION,
		"generator_version": PGAddonInfo.VERSION,
		"planet_name": str(generation_params.get("planet_name", "Generated Planet")),
		"seed": int(generation_params.get("seed", 0)),
		"planet_type": int(generation_params.get("planet_type", 0)),
		"created_unix": int(Time.get_unix_time_from_system()),
		"root": ".",
		"parameters": PGPlanetManifest._stable_parameters(generation_params),
		"layers": layers,
	}
	var path := output_dir.path_join(FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[PGPlanetProject] Unable to write " + path)
		return ""
	file.store_string(JSON.stringify(manifest, "  ", true))
	file.close()
	PGFileChecksumCache.invalidate(path)
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
	# Do not inherit Dictionary ordering from the exporter.  A single canonical
	# sort controls the arrow navigation, the advanced viewer selectors and
	# projects loaded back from disk.
	var entries: Array[Dictionary] = []
	var seen_paths: Dictionary = {}
	for key_value in layers.keys():
		var path := str(layers[key_value])
		if path.get_extension().to_lower() != "png" or not FileAccess.file_exists(path):
			continue
		var normalized := path.simplify_path()
		if seen_paths.has(normalized):
			continue
		seen_paths[normalized] = true
		entries.append({"key": str(key_value), "path": path})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _display_sort_key(str(a["key"]), str(a["path"])) < _display_sort_key(str(b["key"]), str(b["path"]))
	)

	var result: Array[String] = []
	for entry in entries:
		result.append(str(entry["path"]))
	return result


static func _display_sort_key(layer_key: String, path: String) -> String:
	var file_name := path.get_file().to_lower()
	var normalized_path := path.replace("\\", "/").to_lower()

	# Resources are deliberately forced to the very end.  Their filename order
	# is alphabetical and deterministic, while their UI label remains localized.
	if (
		normalized_path.contains("/maps/resources/")
		or normalized_path.contains("/resources/")
		or normalized_path.contains("/ressource/")
	):
		return "4|%s|%s" % [file_name, layer_key.to_lower()]

	var index := NATURAL_MAP_ORDER.find(file_name)
	if index >= 0:
		return "0|%04d|%s" % [index, file_name]

	index = HYDROLOGY_MAP_ORDER.find(file_name)
	if index >= 0:
		return "1|%04d|%s" % [index, file_name]

	index = ADMIN_MAP_ORDER.find(file_name)
	if index >= 0:
		return "2|%04d|%s" % [index, file_name]

	index = OTHER_MAP_ORDER.find(file_name)
	if index >= 0:
		return "3|%04d|%s" % [index, file_name]

	# Unknown/new PNGs belong to the "rest" group.  This makes the ordering
	# forward-compatible without accidentally placing new maps after resources.
	return "3|9000|%s|%s" % [file_name, layer_key.to_lower()]


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
