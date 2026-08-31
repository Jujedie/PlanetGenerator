class_name PGExportCatalog
extends RefCounted

## Milestone 7.2 — Export System v2
##
## Keeps generated data, user-facing maps, overlays and development views in a
## predictable on-disk layout. PGPlanetExporter uses the same retention
## contract to skip unrequested presentation stages before GPU readback and PNG
## compression; this catalog stage still validates/organizes surviving files.

const CATALOG_VERSION := 4
const PRESET_MINIMAL := "minimal"
const PRESET_STANDARD := "standard"
const PRESET_COMPLETE := "complete"
const PRESET_DEVELOPMENT := "development"
const PRESET_CUSTOM := "custom"

const ALWAYS_METADATA := ["integrity_report", "manifest", "project", "catalog"]
# Canonical keys emitted by exporter.gd. Legacy aliases are retained only
# where they improve compatibility with older projects/tests.
const MINIMAL_KEYS := ["final_map", "cartographic", "eaux_map", "river_map", "biome_colored"]
const DEBUG_KEYS := ["plaques_bordures_map", "plates_borders"]
const OVERLAY_KEYS := ["grid_overlay", "topology_map", "topology"]
const RESOURCE_KEYS := ["petrole", "resources", "resource", "ressource"]

static func normalize_preset(value) -> String:
	var preset := str(value).strip_edges().to_lower()
	if preset in [PRESET_MINIMAL, PRESET_STANDARD, PRESET_COMPLETE, PRESET_DEVELOPMENT, PRESET_CUSTOM]:
		return preset
	return PRESET_STANDARD

static func should_keep(key: String, params: Dictionary, path: String = "") -> bool:
	if key in ALWAYS_METADATA:
		return true
	var preset := normalize_preset(params.get("export_preset", PRESET_STANDARD))
	var is_resource := _is_resource_output(key, path)
	var is_debug := key in DEBUG_KEYS
	match preset:
		PRESET_MINIMAL:
			return key in MINIMAL_KEYS
		PRESET_STANDARD:
			# Normal user-facing maps, without resources or debug-only layers.
			return not is_resource and not is_debug
		PRESET_COMPLETE:
			# Full gameplay/data export: resources included, debug excluded.
			return not is_debug
		PRESET_DEVELOPMENT:
			# Development is the only preset that keeps diagnostic/debug layers too.
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
	if _is_resource_output(key, path):
		return "maps/resources"
	if path.get_extension().to_lower() == "png":
		return "maps"
	return "raw"


static func _is_resource_output(key: String, path: String) -> bool:
	# Resource keys are dynamic (`aluminium_map`, `fer_map`, ...), so the
	# directory is the authoritative signal. This recognizes both legacy
	# `ressource/` staging and canonical `maps/resources/` output paths.
	var normalized_path := path.replace("\\", "/").to_lower()
	var parent_dir := normalized_path.get_base_dir().get_file()
	if parent_dir in ["ressource", "resources"]:
		return true
	if "/ressource/" in normalized_path or "/resources/" in normalized_path:
		return true

	# Compatibility fallback for callers that only know the dictionary key.
	var normalized_key := key.to_lower()
	for needle in RESOURCE_KEYS:
		if normalized_key.contains(needle):
			return true
	return false

static func finalize_outputs(output_root: String, exported_files: Dictionary,
		params: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(output_root)
	var result: Dictionary = {}
	var catalog_entries: Dictionary = {}
	# Resource filenames seen in this generation. An empty canonical path means
	# the selected preset filtered that resource and every stale copy must go.
	var resource_cleanup_targets: Dictionary = {}
	var keys := exported_files.keys(); keys.sort()
	for key_value in keys:
		var key := str(key_value)
		var source := str(exported_files[key_value])
		if source.is_empty() or not FileAccess.file_exists(source):
			continue
		var category := category_for(key, source)
		if category == "maps/resources":
			resource_cleanup_targets[source.get_file()] = ""
		if not should_keep(key, params, source):
			# Presets control exported presentation files only. Never delete an
			# unknown non-PNG authoritative/raw file.
			if source.get_extension().to_lower() == "png":
				PGFileChecksumCache.invalidate(source)
				DirAccess.remove_absolute(source)
			continue
		if key in ALWAYS_METADATA or source.get_extension().to_lower() != "png":
			result[key] = source
			continue
		var destination_dir := output_root.path_join(category)
		DirAccess.make_dir_recursive_absolute(destination_dir)
		var destination := destination_dir.path_join(source.get_file())
		# PNG workers compute and cache SHA-256 while compression is already running.
		# Preserve that hash across the catalog move instead of rereading every PNG
		# serially after all workers have finished.
		var source_sha256 := PGFileChecksumCache.sha256(source)
		PGFileChecksumCache.invalidate(destination)
		if source.simplify_path() != destination.simplify_path():
			var move_error := DirAccess.rename_absolute(source, destination)
			if move_error != OK:
				var bytes := FileAccess.get_file_as_bytes(source)
				var out := FileAccess.open(destination, FileAccess.WRITE)
				if out == null:
					push_warning("[PGExportCatalog] Cannot move " + source)
					result[key] = source
					continue
				out.store_buffer(bytes); out.close()
				DirAccess.remove_absolute(source)
		result[key] = destination
		if not source_sha256.is_empty():
			PGFileChecksumCache.remember(destination, source_sha256)
		catalog_entries[key] = {
			"path": _relative_path(output_root, destination),
			"category": category,
			"sha256": source_sha256 if not source_sha256.is_empty() else PGFileChecksumCache.sha256(destination),
		}
		if category == "maps/resources":
			resource_cleanup_targets[source.get_file()] = destination

	# The job output directory can be reused by explicit callers. Remove stale
	# resource copies whether this preset retained the canonical resource or
	# deliberately filtered it out.
	_remove_stale_resource_duplicates(output_root, resource_cleanup_targets)
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
		output_root.path_join("maps").path_join("resources"),
	]
	for filename_value in canonical_files.keys():
		var filename := str(filename_value)
		var canonical := str(canonical_files[filename_value]).simplify_path()
		for directory_value in candidate_dirs:
			var candidate := str(directory_value).path_join(filename)
			if candidate.simplify_path() == canonical:
				continue
			if FileAccess.file_exists(candidate):
				PGFileChecksumCache.invalidate(candidate)
				var err := DirAccess.remove_absolute(candidate)
				if err != OK:
					push_warning("[PGExportCatalog] Cannot remove stale resource copy: " + candidate)



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
	PGFileChecksumCache.invalidate(path)
	return path

static func _relative_path(root: String, path: String) -> String:
	var normalized_root := root.simplify_path().trim_suffix("/") + "/"
	var normalized_path := path.simplify_path()
	if normalized_path.begins_with(normalized_root):
		return normalized_path.substr(normalized_root.length())
	return normalized_path
