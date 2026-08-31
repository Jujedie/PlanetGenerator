class_name PlanetManifest
extends RefCounted

const MANIFEST_VERSION := 1
const PALETTE_VERSION := 3

static func build(generation_params: Dictionary, exported_files: Dictionary, output_dir: String = "") -> Dictionary:
	var radius_km := float(generation_params.get("planet_radius", 150.0))
	var dimensions: Vector2i = generation_params.get(
		"global_dimensions",
		generation_params.get("resolution", PlanetGridContract.logical_dimensions(radius_km))
	)
	var tile_size := int(generation_params.get("tile_size", PlanetGridContract.DEFAULT_TILE_SIZE))
	var layers: Dictionary = {}
	var sorted_names := exported_files.keys()
	sorted_names.sort()
	for layer_name in sorted_names:
		var path := str(exported_files[layer_name])
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		layers[str(layer_name)] = {
			"path": _relative_path(output_dir, path) if not output_dir.is_empty() else path.get_file(),
			"sha256": FileChecksumCache.sha256(path),
		}

	return {
		"manifest_version": MANIFEST_VERSION,
		"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		"seed": int(generation_params.get("seed", 0)),
		"planet_type": int(generation_params.get("planet_type", 0)),
		"parameters": _stable_parameters(generation_params),
		"grid": PlanetGridContract.contract_dictionary(radius_km, dimensions, tile_size),
		"palette_version": PALETTE_VERSION,
		"layer_formats": {
			"height": "R32F metres",
			"water_mask": "R8UI 0=land 1=saltwater 2=freshwater",
			"biome_id": "R16UI",
			"administrative_ids": "R32UI no-data=0xFFFFFFFF",
			"display_png": "RGBA8 sRGB",
		},
		"layers": layers,
	}

static func save(output_dir: String, generation_params: Dictionary,
		exported_files: Dictionary) -> String:
	var manifest := build(generation_params, exported_files, output_dir)
	var path := output_dir.path_join("planet_manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write planet manifest: " + path)
		return ""
	file.store_string(JSON.stringify(manifest, "  ", true))
	file.close()
	FileChecksumCache.invalidate(path)
	return path

static func _stable_parameters(generation_params: Dictionary) -> Dictionary:
	# Runtime objects and transient resolution aliases are intentionally omitted.
	var result: Dictionary = {}
	var keys := generation_params.keys()
	keys.sort()
	for key in keys:
		var value = generation_params[key]
		if value is RID or value is Object or key in ["resolution", "global_dimensions"]:
			continue
		if value is Vector2i:
			result[str(key)] = [value.x, value.y]
		elif value is Vector2:
			result[str(key)] = [value.x, value.y]
		elif value is Color:
			result[str(key)] = value.to_html(true)
		elif value is Dictionary or value is Array or value is String or value is StringName or value is bool or value is int or value is float:
			result[str(key)] = value
	return result


static func _relative_path(root: String, path: String) -> String:
	var normalized_root := root.simplify_path().trim_suffix("/") + "/"
	var normalized_path := path.simplify_path()
	if normalized_path.begins_with(normalized_root):
		return normalized_path.substr(normalized_root.length())
	return normalized_path
