class_name TiledDatasetManifest
extends RefCounted

const VERSION := 1
const LAYER_FORMATS := {
	"height_base": "R32F metres (pre-erosion)",
	"height": "R32F metres",
	"plates": "R32UI deterministic plate id",
	"climate": "RG32F temperature_C, humidity_0_1",
	"water_mask": "R8UI 0=land 1=surface water",
	"river_flux": "R32F hierarchical accumulated proxy flux",
	"flow_direction": "R8UI D8 0..7, 255=no-flow",
	"biome_id": "R32UI biome class id",
	"region_map": "R32UI land administrative id",
	"ocean_region_map": "R32UI water administrative id",
	"resources": "RGBA8UI deterministic resource channels",
}


static func generation_fingerprint(generation_params: Dictionary, dimensions: Vector2i, tile_size: int) -> String:
	var stable: Dictionary = {
		"dataset_version": VERSION,
		"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		"dimensions": [dimensions.x, dimensions.y],
		"tile_size": tile_size,
	}
	var keys := generation_params.keys()
	keys.sort()
	for key in keys:
		if str(key) in ["resolution", "global_dimensions", "tiled_global_generation"]:
			continue
		var value = generation_params[key]
		if value is bool or value is int or value is float or value is String or value is StringName:
			stable[str(key)] = value
		elif value is Vector2i:
			stable[str(key)] = [value.x, value.y]
		elif value is Vector2:
			stable[str(key)] = [value.x, value.y]
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(stable).to_utf8_buffer())
	return context.finish().hex_encode()

static func save(root_dir: String, generation_params: Dictionary,
		dimensions: Vector2i, tile_size: int, phase_reports: Dictionary,
		hydrology_report: Dictionary, runtime_report: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(root_dir)
	var checksums: Dictionary = {}
	var phase_names := phase_reports.keys(); phase_names.sort()
	for phase_name in phase_names:
		var phase: Dictionary = phase_reports[phase_name]
		var phase_checksums: Dictionary = phase.get("checksums", {})
		var keys := phase_checksums.keys(); keys.sort()
		for key in keys:
			checksums[str(key)] = phase_checksums[key]
	var radius := float(generation_params.get("planet_radius", 150.0))
	var manifest := {
		"tiled_dataset_version": VERSION,
		"generator_version": str(ProjectSettings.get_setting("application/config/version", "unknown")),
		"seed": int(generation_params.get("seed", 0)),
		"planet_type": int(generation_params.get("planet_type", 0)),
		"grid": PlanetGridContract.contract_dictionary(radius, dimensions, tile_size),
		"layer_formats": LAYER_FORMATS,
		"phase_reports": phase_reports,
		"global_hydrology": hydrology_report,
		"runtime": runtime_report,
		"tile_checksums": checksums,
	}
	var path := root_dir.path_join("tiled_planet_manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write tiled manifest: " + path)
		return ""
	file.store_string(JSON.stringify(manifest, "  ", true)); file.close()
	return path
