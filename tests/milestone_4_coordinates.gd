extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var venus := PlanetGridContract.logical_dimensions(6051.8)
	var tile_grid := PlanetGridContract.tile_grid_dimensions(venus)
	var dimension_ok := venus == Vector2i(30339, 15170)
	var tile_ok := tile_grid == Vector2i(15, 8)
	var area := PlanetGridContract.effective_cell_area_km2(6051.8, venus)
	var area_ok := absf(area - 1.0) < 0.001
	var roundtrip_ok := true
	var samples := [
		Vector2i(0, 0), Vector2i(venus.x - 1, 0),
		Vector2i(0, venus.y - 1), Vector2i(venus.x - 1, venus.y - 1),
		Vector2i(venus.x / 2, venus.y / 2), Vector2i(12345, 6789),
	]
	for cell in samples:
		var lon_lat := PlanetGridContract.global_cell_to_world(cell, venus)
		var back := PlanetGridContract.world_to_global_cell(lon_lat.x, lon_lat.y, venus)
		roundtrip_ok = roundtrip_ok and back == cell

	var coverage_cells := 0
	for ty in range(tile_grid.y):
		for tx in range(tile_grid.x):
			var rect := PlanetGridContract.tile_rect(Vector2i(tx, ty), venus)
			coverage_cells += rect.size.x * rect.size.y
	var coverage_ok := coverage_cells == venus.x * venus.y
	var last_rect := PlanetGridContract.tile_rect(tile_grid - Vector2i.ONE, venus)
	var crop_ok := last_rect.end == venus

	var values := PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
	var lod := PlanetGridContract.downsample_scalar_average(values, Vector2i(3, 2))
	var lod_ok := lod["dimensions"] == Vector2i(2, 1)
	var lod_data: PackedFloat32Array = lod["data"]
	lod_ok = lod_ok and is_equal_approx(lod_data[0], 3.0) and is_equal_approx(lod_data[1], 4.5)

	var passed := dimension_ok and tile_ok and area_ok and roundtrip_ok and coverage_ok and crop_ok and lod_ok
	print("[Milestone4] dimensions=", venus, " tile_grid=", tile_grid,
		" cell_area=", area, " roundtrip=", roundtrip_ok,
		" exact_coverage=", coverage_ok, " cropped_edge=", crop_ok,
		" deterministic_lod=", lod_ok)
	get_tree().quit(0 if passed else 1)
