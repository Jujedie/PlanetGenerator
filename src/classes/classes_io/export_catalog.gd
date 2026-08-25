class_name ExportCatalog
extends RefCounted

## Milestone 7.2 — Export System v2
##
## Keeps generated data, user-facing maps, overlays and development views in a
## predictable on-disk layout. The exporter still produces its authoritative
## maps first; this catalog stage only filters/organizes finished files, so it
## cannot change simulation results.

const CATALOG_VERSION := 3
const PRESET_MINIMAL := "minimal"
const PRESET_STANDARD := "standard"
const PRESET_COMPLETE := "complete"
const PRESET_DEVELOPMENT := "development"
const PRESET_CUSTOM := "custom"

const ALWAYS_METADATA := ["integrity_report", "manifest", "project", "catalog"]
const MINIMAL_KEYS := ["final_map", "cartographic", "water_colored", "river_map", "biome"]
const STANDARD_EXCLUDE := ["plates", "plates_borders", "river_type"]
const DEBUG_KEYS := ["plates", "plates_borders", "river_type"]
const OVERLAY_KEYS := ["grid_overlay", "topology"]
const RESOURCE_KEYS := ["petrole", "resources", "resource", "ressource"]

static func normalize_preset(value) -> String:
	var preset := str(value).strip_edges().to_lower()
	if preset in [PRESET_MINIMAL, PRESET_STANDARD, PRESET_COMPLETE, PRESET_DEVELOPMENT, PRESET_CUSTOM]:
		return preset
	return PRESET_STANDARD

static func should_keep(key: String, params: Dictionary) -> bool:
	if key in ALWAYS_METADATA:
		return true
	var preset := normalize_preset(params.get("export_preset", PRESET_STANDARD))
	match preset:
		PRESET_MINIMAL:
			return key in MINIMAL_KEYS
		PRESET_STANDARD:
			return key not in STANDARD_EXCLUDE
		PRESET_COMPLETE, PRESET_DEVELOPMENT:
			return true
		PRESET_CUSTOM:
			var enabled = params.get("export_enabled_keys", [])
			return key in enabled
	return true

static func category_for(key: String, path: String) -> String:
	if key in OVERLAY_KEYS:
		return "overlays"
	if key in DEBUG_KEYS:
		return "debug"

	# Resource maps are produced by the legacy exporter inside a `ressource/`
	# directory, while their dictionary keys are simply names such as
	# `aluminium_map`, `fer_map` or `or_map`. Looking only for the word
	# "resource" in the key therefore misclassified almost every resource PNG
	# as a normal map. The source directory is the authoritative category hint.
	var normalized_path := path.replace("\\", "/").to_lower()
	var parent_dir := normalized_path.get_base_dir().get_file()
	if parent_dir in ["ressource", "resources"]:
		return "maps/resources"
	if "/ressource/" in normalized_path or "/resources/" in normalized_path:
		return "maps/resources"

	# Keep key-based detection as a compatibility fallback for callers that
	# already provide flattened paths.
	var normalized_key := key.to_lower()
	for needle in RESOURCE_KEYS:
		if normalized_key.contains(needle):
			return "maps/resources"
	if path.get_extension().to_lower() == "png":
		return "maps"
	return "raw"

static func finalize_outputs(output_root: String, exported_files: Dictionary,
		params: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(output_root)
	var result: Dictionary = {}
	var catalog_entries: Dictionary = {}
	# filename -> canonical final path. Used after organization to remove stale
	# copies left by older M7.2 exports in maps/, ressource/ or resources/.
	var canonical_resource_files: Dictionary = {}
	var keys := exported_files.keys(); keys.sort()
	for key_value in keys:
		var key := str(key_value)
		var source := str(exported_files[key_value])
		if source.is_empty() or not FileAccess.file_exists(source):
			continue
		if not should_keep(key, params):
			# Presets control exported presentation files only. Never delete an
			# unknown non-PNG authoritative/raw file.
			if source.get_extension().to_lower() == "png":
				DirAccess.remove_absolute(source)
			continue
		if key in ALWAYS_METADATA or source.get_extension().to_lower() != "png":
			result[key] = source
			continue
		var category := category_for(key, source)
		var destination_dir := output_root.path_join(category)
		DirAccess.make_dir_recursive_absolute(destination_dir)
		var destination := destination_dir.path_join(source.get_file())
		if source.simplify_path() != destination.simplify_path():
			var move_error := DirAccess.rename_absolute(source, destination)
			if move_error != OK:
				var bytes := FileAccess.get_file_as_bytes(source)
				var out := FileAccess.open(destination, FileAccess.WRITE)
				if out == null:
					push_warning("[ExportCatalog] Cannot move " + source)
					result[key] = source
					continue
				out.store_buffer(bytes); out.close()
				DirAccess.remove_absolute(source)
		result[key] = destination
		catalog_entries[key] = {
			"path": _relative_path(output_root, destination),
			"category": category,
			"sha256": FileAccess.get_sha256(destination),
		}
		if category == "maps/resources":
			canonical_resource_files[source.get_file()] = destination

	# `user://temp` is deliberately reused between generations. Before this
	# fix, a successful newer export could coexist with old resource PNGs in
	# maps/, making it look as if the organizer had failed. Remove only files
	# for which this generation produced a canonical resource counterpart.
	_remove_stale_resource_duplicates(output_root, canonical_resource_files)
	_remove_empty_legacy_resource_dirs(output_root)
	var catalog_path := _write_catalog(output_root, params, catalog_entries)
	if not catalog_path.is_empty():
		result["catalog"] = catalog_path
	return result


static func _remove_stale_resource_duplicates(output_root: String,
		canonical_files: Dictionary) -> void:
	if canonical_files.is_empty():
		return
	var candidate_dirs := [
		output_root,
		output_root.path_join("maps"),
		output_root.path_join("ressource"),
		output_root.path_join("resources"),
	]
	for filename_value in canonical_files.keys():
		var filename := str(filename_value)
		var canonical := str(canonical_files[filename_value]).simplify_path()
		for directory_value in candidate_dirs:
			var candidate := str(directory_value).path_join(filename)
			if candidate.simplify_path() == canonical:
				continue
			if FileAccess.file_exists(candidate):
				var err := DirAccess.remove_absolute(candidate)
				if err != OK:
					push_warning("[ExportCatalog] Cannot remove stale resource copy: " + candidate)



static func _remove_empty_legacy_resource_dirs(output_root: String) -> void:
	# Nothing writes to these staging directories anymore. Any PNG still found
	# there is necessarily a stale output from a pre-7.2b generation and can be
	# removed safely. Keep unknown non-PNG files rather than deleting user data.
	for folder_name in ["ressource", "resources"]:
		var path := output_root.path_join(folder_name)
		if not DirAccess.dir_exists_absolute(path):
			continue
		var dir := DirAccess.open(path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if not dir.current_is_dir() and entry.get_extension().to_lower() == "png":
				DirAccess.remove_absolute(path.path_join(entry))
			entry = dir.get_next()
		dir.list_dir_end()
		# Re-open after deletions to determine whether the directory is empty.
		dir = DirAccess.open(path)
		if dir == null:
			continue
		dir.list_dir_begin()
		entry = dir.get_next()
		dir.list_dir_end()
		if entry.is_empty():
			DirAccess.remove_absolute(path)

static func _write_catalog(output_root: String, params: Dictionary, entries: Dictionary) -> String:
	var path := output_root.path_join("export_catalog.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify({
		"catalog_version": CATALOG_VERSION,
		"preset": normalize_preset(params.get("export_preset", PRESET_STANDARD)),
		"entries": entries,
	}, "  ", true))
	file.close()
	return path

static func _relative_path(root: String, path: String) -> String:
	var normalized_root := root.simplify_path().trim_suffix("/") + "/"
	var normalized_path := path.simplify_path()
	if normalized_path.begins_with(normalized_root):
		return normalized_path.substr(normalized_root.length())
	return normalized_path
