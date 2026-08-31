extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var venus := PlanetGridContract.logical_dimensions(6051.8)
	var selection_ok := TiledGlobalGenerator.should_use_tiled(venus)
	# 7520×3760 is below both the 8192 texture edge and the 5 GiB hard
	# working-set envelope. Production must therefore use the exact monolithic
	# pipeline rather than the experimental tiled approximation.
	var production_size := Vector2i(7520, 3760)
	var production_monolithic_ok := (
		TiledGlobalGenerator.fits_monolithic_envelope(production_size)
		and not TiledGlobalGenerator.should_use_tiled(production_size)
	)
	var production_limit := TiledGlobalGenerator.last_monolithic_dimensions_for_aspect(
		production_size
	)
	production_monolithic_ok = (
		production_monolithic_ok and production_limit == Vector2i(8192, 4096)
	)
	var max_plan := TiledGlobalGenerator.new(venus).build_tile_plan(128)
	var max_plan_ok := max_plan.size() == 120
	var budget := TiledGlobalGenerator.new(venus).validate_budget(128, 33)
	var budget_ok := bool(budget["within_hard_budget"]) and int(budget["sample_edge"]) <= TiledGlobalGenerator.MAX_TILE_SAMPLE_EDGE

	# Small end-to-end tiled generation is run twice with different tile sizes.
	# Identical raw layers prove that absolute-coordinate generation + halos are
	# independent of where tile boundaries happen to fall.
	var params := {
		"seed": 424242,
		"planet_type": 0,
		"planet_radius": 100.0,
		"resolution": Vector2i(128, 64),
		"global_dimensions": Vector2i(128, 64),
		"global_cell_area_km2": 1.0,
		"sea_level": 0.0,
		"avg_temperature": 15.0,
		"terrain_scale": 1.0,
		"erosion_iterations": 3,
		"erosion_rate": 0.05,
		"nb_cases_regions": 24.0,
		"nb_cases_ocean_regions": 32.0,
		"vram_budget_bytes": 512 * 1024 * 1024,
	}
	var first_params := params.duplicate(true); first_params["tile_size"] = 64
	var second_params := params.duplicate(true); second_params["tile_size"] = 128
	var root_a := "user://m5_full_test_a"
	var root_b := "user://m5_full_test_b"
	PlanetTileStore._remove_tree(root_a)
	PlanetTileStore._remove_tree(root_b)
	var first := TiledGlobalSimulationPipeline.new(first_params, root_a)
	var report_a := first.generate()
	first.cleanup()
	first = null
	var second := TiledGlobalSimulationPipeline.new(second_params, root_b)
	var report_b := second.generate()
	second.cleanup()
	second = null
	var generated_ok := bool(report_a.get("ok", false)) and bool(report_b.get("ok", false))
	var seam_ok := generated_ok
	if generated_ok:
		for layer_spec in [
			["height", 4], ["climate", 8], ["water_mask", 1],
			["river_flux", 4], ["flow_direction", 1], ["biome_id", 4],
		]:
			var layer := str(layer_spec[0]); var bpp := int(layer_spec[1])
			var reader_a := TileWindowReader.new(PlanetTileStore.new(root_a), Vector2i(128,64), 64)
			var reader_b := TileWindowReader.new(PlanetTileStore.new(root_b), Vector2i(128,64), 128)
			var data_a := reader_a.read_window(layer,0,Vector2i.ZERO,Vector2i(128,64),bpp)
			var data_b := reader_b.read_window(layer,0,Vector2i.ZERO,Vector2i(128,64),bpp)
			seam_ok = seam_ok and data_a == data_b and not data_a.is_empty()

	var cancel_pipeline := TiledGlobalSimulationPipeline.new(first_params, "user://m5_cancel_test")
	cancel_pipeline.cancel("acceptance_test")
	var cancelled := cancel_pipeline.generate()
	var cancellation_ok := bool(cancelled.get("cancelled", false)) or str(cancelled.get("reason", "")) == "acceptance_test"
	cancel_pipeline.cleanup()
	cancel_pipeline = null
	GPUContext.shutdown_shared_device()

	var passed := (
		selection_ok
		and production_monolithic_ok
		and max_plan_ok
		and budget_ok
		and generated_ok
		and seam_ok
		and cancellation_ok
	)
	print("[Milestone5-Full] max_tiles=",max_plan.size()," budget=",budget,
		" production_7520_monolithic=",production_monolithic_ok,
		" generated=",generated_ok," tile_boundary_invariant=",seam_ok," cancellation=",cancellation_ok)
	get_tree().quit(0 if passed else 1)
