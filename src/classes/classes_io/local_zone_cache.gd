class_name LocalZoneCache
extends RefCounted

const CACHE_VERSION := 2

var root_dir: String

func _init(root: String) -> void:
	root_dir = root
	DirAccess.make_dir_recursive_absolute(root_dir)

func zone_dir(planet_id: String, generator_version: String,
		cell: Vector2i, resolution: int) -> String:
	return root_dir.path_join(planet_id).path_join(generator_version.validate_filename()).path_join(
		"%d_%d_%d" % [cell.x, cell.y, resolution]
	)

func load_zone(planet_id: String, generator_version: String,
		cell: Vector2i, resolution: int) -> Dictionary:
	var directory := zone_dir(planet_id, generator_version, cell, resolution)
	var metadata_path := directory.path_join("zone.json")
	if not FileAccess.file_exists(metadata_path):
		return {}
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if file == null:
		return {}
	var metadata = JSON.parse_string(file.get_as_text())
	file.close()
	if not metadata is Dictionary or int(metadata.get("cache_version", 0)) != CACHE_VERSION:
		return {}
	var stored_cell = metadata.get("global_cell", [0, 0])
	if stored_cell is Array and stored_cell.size() >= 2:
		metadata["global_cell"] = Vector2i(int(stored_cell[0]), int(stored_cell[1]))
	var images: Dictionary = {}
	for name in (metadata.get("images", {}) as Dictionary).keys():
		var info: Dictionary = metadata["images"][name]
		var raw_path := directory.path_join(str(info.get("file", "")))
		if not FileAccess.file_exists(raw_path) or FileAccess.get_sha256(raw_path) != str(info.get("sha256", "")):
			return {}
		var bytes := FileAccess.get_file_as_bytes(raw_path)
		var image := Image.create_from_data(
			int(info["width"]), int(info["height"]), false,
			int(info["format"]), bytes
		)
		images[name] = image
	return {"metadata": metadata, "images": images, "cache_hit": true}

func save_zone(zone: Dictionary) -> bool:
	var metadata: Dictionary = zone.get("metadata", {})
	var images: Dictionary = zone.get("images", {})
	if metadata.is_empty() or images.is_empty():
		return false
	var directory := zone_dir(str(metadata["planet_id"]), str(metadata["generator_version"]),
		metadata["global_cell"], int(metadata["resolution"]))
	DirAccess.make_dir_recursive_absolute(directory)
	var image_meta: Dictionary = {}
	var names := images.keys()
	names.sort()
	for name in names:
		var image: Image = images[name]
		var payload := image.get_data()
		var temp_path := directory.path_join(str(name) + ".bin.tmp")
		var final_path := directory.path_join(str(name) + ".bin")
		var file := FileAccess.open(temp_path, FileAccess.WRITE)
		if file == null:
			return false
		file.store_buffer(payload)
		file.close()
		if FileAccess.file_exists(final_path):
			DirAccess.remove_absolute(final_path)
		if DirAccess.rename_absolute(temp_path, final_path) != OK:
			return false
		image_meta[str(name)] = {
			"file": final_path.get_file(), "width": image.get_width(), "height": image.get_height(),
			"format": int(image.get_format()), "sha256": FileAccess.get_sha256(final_path),
		}
	var stored_meta := metadata.duplicate(true)
	stored_meta["cache_version"] = CACHE_VERSION
	stored_meta["images"] = image_meta
	var json_meta := stored_meta.duplicate(true)
	var cell: Vector2i = stored_meta["global_cell"]
	json_meta["global_cell"] = [cell.x, cell.y]
	var meta_tmp := directory.path_join("zone.json.tmp")
	var meta_final := directory.path_join("zone.json")
	var meta_file := FileAccess.open(meta_tmp, FileAccess.WRITE)
	if meta_file == null:
		return false
	meta_file.store_string(JSON.stringify(json_meta, "  ", true))
	meta_file.close()
	if FileAccess.file_exists(meta_final):
		DirAccess.remove_absolute(meta_final)
	return DirAccess.rename_absolute(meta_tmp, meta_final) == OK
