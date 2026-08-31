class_name PGRuntimeDataReader
extends RefCounted

## Random-access reader for PGRuntimeDataWriter output. File handles are opened
## lazily and protected by a mutex so callers can safely query the same result
## object from multiple threads without loading entire planet layers into RAM.

const NO_DATA_U32 := 0xFFFFFFFF

var output_root: String = ""
var manifest_path: String = ""
var manifest: Dictionary = {}
var dimensions: Vector2i = Vector2i.ZERO

var _files: Dictionary = {}
var _mutex: Mutex = Mutex.new()


func open(output_directory: String, explicit_manifest_path: String = "") -> bool:
	close()
	output_root = output_directory.simplify_path()
	manifest_path = explicit_manifest_path
	if manifest_path.is_empty():
		manifest_path = output_root.path_join(PGRuntimeDataWriter.DIRECTORY_NAME).path_join(
			PGRuntimeDataWriter.MANIFEST_FILE
		)
	if not FileAccess.file_exists(manifest_path):
		return false
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return false
	manifest = (parsed as Dictionary).duplicate(true)
	var raw_dimensions: Variant = manifest.get("dimensions", [])
	if raw_dimensions is Array and raw_dimensions.size() >= 2:
		dimensions = Vector2i(int(raw_dimensions[0]), int(raw_dimensions[1]))
	if dimensions.x <= 0 or dimensions.y <= 0:
		manifest.clear()
		return false
	var version := int(manifest.get("runtime_data_version", -1))
	if version < 1 or version > PGRuntimeDataWriter.VERSION:
		manifest.clear()
		return false
	if not _validate_layers():
		manifest.clear()
		return false
	return true


func is_ready() -> bool:
	return not manifest.is_empty() and dimensions.x > 0 and dimensions.y > 0


func has_layer(layer_key: String) -> bool:
	var layers_value: Variant = manifest.get("layers", {})
	return layers_value is Dictionary and (layers_value as Dictionary).has(layer_key)


func get_layer_keys() -> Array[String]:
	var result: Array[String] = []
	var layers_value: Variant = manifest.get("layers", {})
	if layers_value is Dictionary:
		for key_value in (layers_value as Dictionary).keys():
			result.append(str(key_value))
	result.sort()
	return result


func read_f32(layer_key: String, global_cell: Vector2i) -> Variant:
	var bytes := _read_cell_bytes(layer_key, global_cell, 4)
	if bytes.size() != 4:
		return null
	return bytes.decode_float(0)


func read_u32(layer_key: String, global_cell: Vector2i) -> Variant:
	var bytes := _read_cell_bytes(layer_key, global_cell, 4)
	if bytes.size() != 4:
		return null
	return bytes.decode_u32(0)


func read_u8(layer_key: String, global_cell: Vector2i) -> Variant:
	var bytes := _read_cell_bytes(layer_key, global_cell, 1)
	if bytes.size() != 1:
		return null
	return int(bytes[0])


func canonical_cell(global_cell: Vector2i) -> Vector2i:
	if dimensions.x <= 0 or dimensions.y <= 0:
		return Vector2i.ZERO
	return Vector2i(
		posmod(global_cell.x, dimensions.x),
		clampi(global_cell.y, 0, dimensions.y - 1)
	)


func get_biome_info(biome_id: int, river: bool = false) -> Dictionary:
	if biome_id < 0:
		return {}
	var table_key := "river_biomes" if river else "biomes"
	var table_value: Variant = manifest.get(table_key, [])
	if not table_value is Array:
		return {}
	var table := table_value as Array
	if biome_id >= table.size():
		return {}
	var entry: Variant = table[biome_id]
	return (entry as Dictionary).duplicate(true) if entry is Dictionary else {}


func get_sea_level_m() -> float:
	return float(manifest.get("sea_level_m", 0.0))


func close() -> void:
	_mutex.lock()
	for file_value in _files.values():
		var file := file_value as FileAccess
		if file != null:
			file.close()
	_files.clear()
	_mutex.unlock()
	manifest.clear()
	dimensions = Vector2i.ZERO


func _validate_layers() -> bool:
	var layers_value: Variant = manifest.get("layers", {})
	if not layers_value is Dictionary or (layers_value as Dictionary).is_empty():
		return false
	var expected_cells: int = dimensions.x * dimensions.y
	for entry_value in (layers_value as Dictionary).values():
		if not entry_value is Dictionary:
			return false
		var entry := entry_value as Dictionary
		var relative_path := str(entry.get("path", ""))
		var bytes_per_cell := int(entry.get("bytes_per_cell", 0))
		if relative_path.is_empty() or bytes_per_cell <= 0:
			return false
		var path := output_root.path_join(relative_path).simplify_path()
		if not FileAccess.file_exists(path):
			return false
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return false
		var expected_size: int = expected_cells * bytes_per_cell
		var valid_size := file.get_length() == expected_size
		file.close()
		if not valid_size:
			return false
	return true


func _read_cell_bytes(layer_key: String, global_cell: Vector2i,
		expected_bytes_per_cell: int) -> PackedByteArray:
	if not is_ready():
		return PackedByteArray()
	var layers_value: Variant = manifest.get("layers", {})
	if not layers_value is Dictionary:
		return PackedByteArray()
	var layers := layers_value as Dictionary
	if not layers.has(layer_key):
		return PackedByteArray()
	var entry_value: Variant = layers[layer_key]
	if not entry_value is Dictionary:
		return PackedByteArray()
	var entry := entry_value as Dictionary
	var bytes_per_cell := int(entry.get("bytes_per_cell", 0))
	if bytes_per_cell != expected_bytes_per_cell:
		return PackedByteArray()
	var relative_path := str(entry.get("path", ""))
	if relative_path.is_empty():
		return PackedByteArray()
	var absolute_path := output_root.path_join(relative_path).simplify_path()
	var cell := canonical_cell(global_cell)
	var cell_index: int = cell.y * dimensions.x + cell.x
	var offset: int = cell_index * bytes_per_cell

	_mutex.lock()
	var file := _files.get(absolute_path) as FileAccess
	if file == null:
		file = FileAccess.open(absolute_path, FileAccess.READ)
		if file != null:
			_files[absolute_path] = file
	if file == null:
		_mutex.unlock()
		return PackedByteArray()
	if offset < 0 or offset + bytes_per_cell > file.get_length():
		_mutex.unlock()
		return PackedByteArray()
	file.seek(offset)
	var bytes := file.get_buffer(bytes_per_cell)
	_mutex.unlock()
	return bytes
