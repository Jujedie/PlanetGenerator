class_name PlanetTileStore
extends RefCounted

## Atomic on-disk storage for completed global tiles. A tile is never considered
## complete until both its payload and metadata have been renamed into place.

const STORE_VERSION := 1

var root_dir: String

func _init(root: String) -> void:
	root_dir = root
	DirAccess.make_dir_recursive_absolute(root_dir)

func tile_path(layer: String, lod: int, tile: Vector2i) -> String:
	return root_dir.path_join("lod_%d" % lod).path_join(layer).path_join(
		"%03d_%03d.tile" % [tile.x, tile.y]
	)

func metadata_path(layer: String, lod: int, tile: Vector2i) -> String:
	return tile_path(layer, lod, tile) + ".json"

func has_complete_tile(layer: String, lod: int, tile: Vector2i) -> bool:
	var payload := tile_path(layer, lod, tile)
	var metadata := metadata_path(layer, lod, tile)
	if not FileAccess.file_exists(payload) or not FileAccess.file_exists(metadata):
		return false
	var meta_file := FileAccess.open(metadata, FileAccess.READ)
	if meta_file == null:
		return false
	var parsed = JSON.parse_string(meta_file.get_as_text())
	meta_file.close()
	if not parsed is Dictionary:
		return false
	return str(parsed.get("sha256", "")) == FileChecksumCache.sha256(payload)

func write_tile(layer: String, lod: int, tile: Vector2i, payload: PackedByteArray,
		metadata: Dictionary = {}) -> Dictionary:
	var final_path := tile_path(layer, lod, tile)
	var final_meta := metadata_path(layer, lod, tile)
	DirAccess.make_dir_recursive_absolute(final_path.get_base_dir())
	var temp_path := final_path + ".tmp"
	var temp_meta := final_meta + ".tmp"

	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "payload_open_failed"}
	file.store_buffer(payload)
	file.close()
	var checksum := FileChecksumCache.sha256(temp_path)

	var complete_meta := metadata.duplicate(true)
	complete_meta["store_version"] = STORE_VERSION
	complete_meta["layer"] = layer
	complete_meta["lod"] = lod
	complete_meta["tile"] = [tile.x, tile.y]
	complete_meta["bytes"] = payload.size()
	complete_meta["sha256"] = checksum
	var meta_file := FileAccess.open(temp_meta, FileAccess.WRITE)
	if meta_file == null:
		DirAccess.remove_absolute(temp_path)
		return {"ok": false, "error": "metadata_open_failed"}
	meta_file.store_string(JSON.stringify(complete_meta, "  ", true))
	meta_file.close()

	# Rename metadata last: a crash can leave a harmless orphan payload, but never
	# a metadata file that claims an incomplete payload is valid.
	if FileAccess.file_exists(final_path):
		FileChecksumCache.invalidate(final_path)
		DirAccess.remove_absolute(final_path)
	if FileAccess.file_exists(final_meta):
		DirAccess.remove_absolute(final_meta)
	var payload_error := DirAccess.rename_absolute(temp_path, final_path)
	if payload_error != OK:
		DirAccess.remove_absolute(temp_path)
		DirAccess.remove_absolute(temp_meta)
		return {"ok": false, "error": "payload_rename_failed", "code": payload_error}
	var meta_error := DirAccess.rename_absolute(temp_meta, final_meta)
	if meta_error != OK:
		DirAccess.remove_absolute(final_path)
		DirAccess.remove_absolute(temp_meta)
		FileChecksumCache.invalidate(final_path)
		return {"ok": false, "error": "metadata_rename_failed", "code": meta_error}
	FileChecksumCache.invalidate(temp_path)
	FileChecksumCache.remember(final_path, checksum)
	return {"ok": true, "path": final_path, "sha256": checksum}

func read_tile(layer: String, lod: int, tile: Vector2i) -> PackedByteArray:
	if not has_complete_tile(layer, lod, tile):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(tile_path(layer, lod, tile))

func remove_incomplete_files() -> int:
	return _remove_temp_recursive(root_dir)

func _remove_temp_recursive(path: String) -> int:
	var directory := DirAccess.open(path)
	if directory == null:
		return 0
	var removed := 0
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				removed += _remove_temp_recursive(child)
			elif entry.ends_with(".tmp"):
				if DirAccess.remove_absolute(child) == OK:
					removed += 1
		entry = directory.get_next()
	directory.list_dir_end()
	return removed

static func remove_layer(root: String, layer: String) -> int:
	var removed := 0
	var root_access := DirAccess.open(root)
	if root_access == null:
		return 0
	root_access.list_dir_begin()
	var entry := root_access.get_next()
	while not entry.is_empty():
		if root_access.current_is_dir() and entry.begins_with("lod_"):
			var layer_dir := root.path_join(entry).path_join(layer)
			if DirAccess.dir_exists_absolute(layer_dir):
				removed += _remove_tree(layer_dir)
		entry = root_access.get_next()
	root_access.list_dir_end()
	return removed

static func copy_tree(source: String, destination: String) -> bool:
	if not DirAccess.dir_exists_absolute(source):
		return false
	DirAccess.make_dir_recursive_absolute(destination)
	var directory := DirAccess.open(source)
	if directory == null:
		return false
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var src := source.path_join(entry)
			var dst := destination.path_join(entry)
			if directory.current_is_dir():
				if not copy_tree(src, dst):
					directory.list_dir_end()
					return false
			else:
				DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
				if DirAccess.copy_absolute(src, dst) != OK:
					directory.list_dir_end()
					return false
		entry = directory.get_next()
	directory.list_dir_end()
	return true

static func _remove_tree(path: String) -> int:
	var directory := DirAccess.open(path)
	if directory == null:
		return 0
	var removed := 0
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				removed += _remove_tree(child)
			else:
				if DirAccess.remove_absolute(child) == OK:
					removed += 1
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)
	return removed
