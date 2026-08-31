class_name PGTiledGlobalSimulationPipeline
extends RefCounted

signal phase_started(name: String)
signal tile_progress(phase: String, tile: Vector2i, completed: int, total: int)

## Full maximum-scale path for Milestone 5. Phases are completed globally one at
## a time, but each phase owns only one 2048px tile (+ its required halo) in
## active VRAM. Previous phase results are reconstructed from the on-disk tile
## store when a neighbourhood is required.

var params: Dictionary
var dimensions: Vector2i
var tile_size: int
var output_root: String
var generator: PGTiledGlobalGenerator
var store: PGPlanetTileStore
var reader: PGTileWindowReader
var gpu_runner: PGTiledPhaseGpuRunner
var cancel_token: PGGenerationCancelToken
var last_report: Dictionary = {}
var phase_reports: Dictionary = {}
var dataset_fingerprint := ""
var _cleaned_up := false

func _init(generation_params: Dictionary, root_dir: String) -> void:
	params = generation_params.duplicate(true)
	dimensions = params.get("global_dimensions", params.get("resolution", Vector2i(1024,512)))
	tile_size = int(params.get("tile_size", PGPlanetGridContract.DEFAULT_TILE_SIZE))
	output_root = root_dir
	generator = PGTiledGlobalGenerator.new(dimensions, tile_size)
	generator.hard_vram_budget_bytes = int(params.get("vram_budget_bytes", PGTiledGlobalGenerator.HARD_VRAM_BUDGET_BYTES))
	generator.preferred_vram_budget_bytes = mini(generator.hard_vram_budget_bytes, PGTiledGlobalGenerator.PREFERRED_VRAM_BUDGET_BYTES)
	cancel_token = generator.cancel_token
	store = PGPlanetTileStore.new(output_root)
	reader = PGTileWindowReader.new(store, dimensions, tile_size)
	dataset_fingerprint = PGTiledDatasetManifest.generation_fingerprint(params, dimensions, tile_size)
	generator.tile_completed.connect(_forward_tile_progress)

func generate() -> Dictionary:
	var started := Time.get_ticks_msec()
	if not _prepare_resume_state():
		return {"ok": false, "reason": "dataset_state"}
	if int(params.get("planet_type",0)) == 6:
		return {"ok":false,"reason":"gas_giant_uses_atmospheric_path"}
	gpu_runner = PGTiledPhaseGpuRunner.new(params)
	if not gpu_runner.is_ready():
		return {"ok":false,"reason":"rendering_device_unavailable"}
	store.remove_incomplete_files()

	# Phase A: absolute-coordinate terrain/tectonic context.
	if not _run_terrain(): return _finish_failure(started)
	# Phase B: neighbourhood-dependent erosion. Halo radius equals iteration
	# dependency radius, so cropped cores agree exactly at shared boundaries.
	if not _run_erosion(): return _finish_failure(started)
	# Phase C: final climate from the eroded surface.
	if not _run_climate(): return _finish_failure(started)

	# Small global drainage graph: bounded independently of full resolution.
	emit_signal("phase_started","global_hydrology_context")
	var macro := PGGlobalHydrologyContext.build_from_height_tiles(
		dimensions, params, store, tile_size
	)
	if not gpu_runner.set_hydrology_context(macro):
		last_report={"ok":false,"reason":"macro_hydrology_upload"}; return _finish_failure(started)
	if cancel_token.is_cancelled(): return _finish_failure(started)
	if not _run_hydrology(): return _finish_failure(started)
	if not _run_classification(): return _finish_failure(started)

	var runtime := _runtime_report(started)
	var manifest_path := PGTiledDatasetManifest.save(
		output_root,params,dimensions,tile_size,phase_reports,macro.report(),runtime
	)
	last_report = {
		"ok": not manifest_path.is_empty(), "cancelled":false,
		"manifest":manifest_path,"output_root":output_root,
		"dimensions":[dimensions.x,dimensions.y],"tile_size":tile_size,
		"phase_reports":phase_reports,"global_hydrology":macro.report(),
		"runtime":runtime,
	}
	# Raw tiles are now authoritative on disk; no RenderingDevice resource is
	# needed between generation and export. Release the worker immediately.
	if gpu_runner != null:
		gpu_runner.cleanup()
		gpu_runner = null
	_write_resume_state("complete" if bool(last_report.get("ok", false)) else "in_progress")
	return last_report

func _prepare_resume_state() -> bool:
	DirAccess.make_dir_recursive_absolute(output_root)
	var state_path := output_root.path_join(".generation_state.json")
	if FileAccess.file_exists(state_path):
		var file := FileAccess.open(state_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary and str(parsed.get("fingerprint", "")) != dataset_fingerprint:
				# Never resume tiles from a different seed/parameter/version contract.
				PGPlanetTileStore._remove_tree(output_root)
				DirAccess.make_dir_recursive_absolute(output_root)
	return _write_resume_state("in_progress")

func _write_resume_state(status: String) -> bool:
	var final_path := output_root.path_join(".generation_state.json")
	var temp_path := final_path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({
		"fingerprint": dataset_fingerprint,
		"status": status,
		"dimensions": [dimensions.x, dimensions.y],
		"tile_size": tile_size,
	}, "  ", true))
	file.close()
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	return DirAccess.rename_absolute(temp_path, final_path) == OK

func cancel(reason: String = "user") -> void:
	if generator != null: generator.cancel(reason)

func export_dataset(destination: String) -> bool:
	if not bool(last_report.get("ok",false)): return false
	return PGPlanetTileStore.copy_tree(output_root,destination)

func cleanup() -> void:
	if _cleaned_up:return
	_cleaned_up=true
	cancel("cleanup")
	if gpu_runner!=null:gpu_runner.cleanup();gpu_runner=null
	reader=null;store=null;generator=null

func _run_terrain() -> bool:
	emit_signal("phase_started","terrain_tectonics")
	var report:=generator.run_phase("terrain_tectonics",output_root,0,8,_terrain_tile,0,["height_base","plates"])
	phase_reports["terrain_tectonics"]=report
	return bool(report.get("ok",false))

func _terrain_tile(descriptor: Dictionary, token: PGGenerationCancelToken) -> Dictionary:
	return gpu_runner.generate_terrain(descriptor,token)

func _run_erosion() -> bool:
	emit_signal("phase_started","erosion")
	# One erosion iteration can propagate information by one cell. Using the
	# exact iteration count as halo guarantees the cropped core has no tile-edge
	# dependency. A hard cap protects texture dimensions; larger configured
	# iteration counts are processed in deterministic chunks below.
	var requested:=maxi(int(params.get("erosion_iterations",0)),0)
	if requested==0:
		# Still materialise authoritative post-erosion height tiles.
		var copy_report:=generator.run_phase("erosion",output_root,0,8,_copy_height_tile,0,["height"])
		phase_reports["erosion"]=copy_report;return bool(copy_report.get("ok",false))
	var max_chunk_halo:=mini(128,maxi((PGTiledGlobalGenerator.MAX_TILE_SAMPLE_EDGE-tile_size)/2,1))
	var remaining:=requested
	var source_layer:="height_base"
	var chunk:=0
	var aggregate: Dictionary={"ok":true,"chunks":[],"checksums":{}}
	while remaining>0:
		if cancel_token.is_cancelled():return false
		var iterations:=mini(remaining,max_chunk_halo)
		var phase_name:="erosion_chunk_%02d"%chunk
		var expected_layer:="height" if remaining==iterations else "height_erosion_%02d"%chunk
		var callable:=_erosion_tile.bind(source_layer,expected_layer,iterations)
		var report:=generator.run_phase(phase_name,output_root,iterations,8,callable,0,[expected_layer])
		aggregate["chunks"].append(report)
		var chunk_checksums: Dictionary = report.get("checksums", {})
		for key in chunk_checksums.keys():
			aggregate["checksums"][key] = chunk_checksums[key]
		if not bool(report.get("ok",false)):
			aggregate["ok"]=false;phase_reports["erosion"]=aggregate;return false
		if source_layer!="height_base":_remove_layer_files(source_layer)
		source_layer=expected_layer;remaining-=iterations;chunk+=1;reader.clear_cache()
	aggregate["requested_iterations"]=requested;aggregate["chunk_count"]=chunk;phase_reports["erosion"]=aggregate
	return true

func _copy_height_tile(descriptor: Dictionary, token: PGGenerationCancelToken) -> Dictionary:
	if token.is_cancelled():return {}
	var tile: Vector2i=descriptor["tile"]
	return {"height":reader.read_core("height_base",0,tile)}

func _erosion_tile(descriptor: Dictionary, token: PGGenerationCancelToken,
		source_layer: String, output_layer: String, iterations: int) -> Dictionary:
	var data:=reader.read_window(source_layer,0,descriptor["sample_origin"],descriptor["sample_size"],4)
	var result:=gpu_runner.erode_height(descriptor,data,iterations,token)
	if result.has("height") and output_layer!="height":
		result[output_layer]=result["height"];result.erase("height")
	return result

func _run_climate() -> bool:
	emit_signal("phase_started","climate")
	var report:=generator.run_phase("climate",output_root,1,12,_climate_tile,0,["climate"])
	phase_reports["climate"]=report;reader.clear_cache();return bool(report.get("ok",false))

func _climate_tile(descriptor: Dictionary, token: PGGenerationCancelToken) -> Dictionary:
	var height:=reader.read_window("height",0,descriptor["sample_origin"],descriptor["sample_size"],4)
	return gpu_runner.generate_climate(descriptor,height,token)

func _run_hydrology() -> bool:
	emit_signal("phase_started","hydrology")
	var report:=generator.run_phase("hydrology",output_root,1,18,_hydrology_tile,0,["water_mask","river_flux","flow_direction"])
	phase_reports["hydrology"]=report;reader.clear_cache();return bool(report.get("ok",false))

func _hydrology_tile(descriptor: Dictionary, token: PGGenerationCancelToken) -> Dictionary:
	var origin: Vector2i=descriptor["sample_origin"];var size: Vector2i=descriptor["sample_size"]
	var height:=reader.read_window("height",0,origin,size,4);var climate:=reader.read_window("climate",0,origin,size,8)
	return gpu_runner.generate_hydrology(descriptor,height,climate,token)

func _run_classification() -> bool:
	emit_signal("phase_started","classification")
	var report:=generator.run_phase("classification",output_root,0,33,_classification_tile,0,["biome_id","region_map","ocean_region_map","resources"])
	phase_reports["classification"]=report;reader.clear_cache();return bool(report.get("ok",false))

func _classification_tile(descriptor: Dictionary, token: PGGenerationCancelToken) -> Dictionary:
	var tile: Vector2i=descriptor["tile"]
	return gpu_runner.generate_classification(descriptor,
		reader.read_core("height",0,tile),reader.read_core("climate",0,tile),
		reader.read_core("water_mask",0,tile),reader.read_core("river_flux",0,tile),token)

func _finish_failure(started: int) -> Dictionary:
	var cancelled:=cancel_token.is_cancelled()
	last_report={"ok":false,"cancelled":cancelled,"reason":cancel_token.reason if cancelled else "phase_failed","phase_reports":phase_reports,"runtime":_runtime_report(started)}
	if gpu_runner != null:
		gpu_runner.cleanup()
		gpu_runner = null
	return last_report

func _runtime_report(started: int) -> Dictionary:
	var peak_estimate:=0
	for phase in phase_reports.values():
		if phase is Dictionary and phase.has("budget"):peak_estimate=maxi(peak_estimate,int(phase["budget"].get("estimated_bytes",0)))
		elif phase is Dictionary and phase.has("chunks"):
			for chunk_value in phase["chunks"]:
				var chunk: Dictionary = chunk_value
				var chunk_budget: Dictionary = chunk.get("budget", {})
				peak_estimate = maxi(peak_estimate, int(chunk_budget.get("estimated_bytes", 0)))
	return {"elapsed_ms":Time.get_ticks_msec()-started,"estimated_peak_active_vram_bytes":peak_estimate,"hard_vram_budget_bytes":generator.hard_vram_budget_bytes,"within_hard_budget":peak_estimate<=generator.hard_vram_budget_bytes,"full_resolution_texture_allocated":false}

func _forward_tile_progress(phase: String,tile: Vector2i,completed: int,total: int)->void:
	emit_signal("tile_progress",phase,tile,completed,total)

func _remove_layer_files(layer: String)->void:
	PGPlanetTileStore.remove_layer(output_root,layer)
