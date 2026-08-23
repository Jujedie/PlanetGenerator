extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var venus := PlanetGridContract.logical_dimensions(6051.8)
	var generator := TiledGlobalGenerator.new(venus)
	var plan := generator.build_tile_plan(16)
	var grid := PlanetGridContract.tile_grid_dimensions(venus)
	var plan_ok := plan.size() == grid.x * grid.y and plan.size() == 120
	var budget := generator.validate_budget(64, 192)
	var budget_ok := bool(budget["within_hard_budget"]) and bool(budget["within_preferred_budget"])

	# Absolute sampling must agree in the overlapping halo of adjacent tiles.
	var test_generator := TiledGlobalGenerator.new(Vector2i(64, 32), 32)
	var test_plan := test_generator.build_tile_plan(4)
	var left: Dictionary = test_plan[0]
	var right: Dictionary = test_plan[1]
	var seam_ok := true
	for global_y in range(4, 28):
		for global_x in range(28, 36):
			var left_origin: Vector2i = left["sample_origin"]
			var right_origin: Vector2i = right["sample_origin"]
			var left_local := Vector2i(global_x - left_origin.x, global_y - left_origin.y)
			var right_local := Vector2i(global_x - right_origin.x, global_y - right_origin.y)
			var left_cell := TiledGlobalGenerator.absolute_cell_from_sample(left, left_local)
			var right_cell := TiledGlobalGenerator.absolute_cell_from_sample(right, right_local)
			seam_ok = seam_ok and left_cell == right_cell
			seam_ok = seam_ok and is_equal_approx(
				AbsoluteFieldSampler.unit_noise(left_cell, 12345, 2),
				AbsoluteFieldSampler.unit_noise(right_cell, 12345, 2)
			)

	# Coarse global drainage must route strictly downhill and remain acyclic.
	var outlets := {
		Vector2i(0, 0): [{"spill_height": 10.0}],
		Vector2i(1, 0): [{"spill_height": 8.0}],
		Vector2i(2, 0): [{"spill_height": 4.0}],
	}
	var routes := GlobalDrainageRouter.route(outlets, Vector2i(3, 1))
	var drainage_ok := routes.get(Vector2i(0, 0), Vector2i(-1, -1)) == Vector2i(2, 0) or routes.get(Vector2i(0, 0), Vector2i(-1, -1)) == Vector2i(1, 0)
	drainage_ok = drainage_ok and not routes.has(Vector2i(2, 0))

	var passed := plan_ok and budget_ok and seam_ok and drainage_ok
	print("[Milestone5] tiles=", plan.size(), " budget=", budget,
		" absolute_halo_seam=", seam_ok, " drainage=", routes)
	get_tree().quit(0 if passed else 1)
