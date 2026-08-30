extends RefCounted
class_name PlanetExporter

## ============================================================================
## PLANET EXPORTER - GPU Texture to PNG with Enum.gd Color Palettes
## ============================================================================
## Converts GPU compute results to legacy-compatible PNG images
## Uses existing color palettes from enum.gd for consistency
## Now with CPU-side water classification and river generation
## ============================================================================

# Map generation parameters (for context-aware coloring)
var params: Dictionary = {}

# PNG/export-only CPU workers. Zero in the public parameters means automatic;
# this setting never controls the single GPU generation queue.
var _nb_threads: int = 1
var last_metrics: Dictionary = {}
var cancellation_probe: Callable = Callable()
var _admin_color_cursor: int = 0

# Export session state. PNG compression runs on a bounded worker pool while the
# main thread keeps converting/readbacking the next maps. Readback caching is
# restricted to textures consumed by several export stages.
var _png_jobs: Array = []
var _png_worker_limit: int = 1
var _png_failed_paths: Dictionary = {}
var _readback_cache: Dictionary = {}
var _readback_cache_bytes: int = 0
var _stage_timings: Dictionary = {}
var _png_file_timings: Dictionary = {}
const _ADMIN_STAT_STRIDE := 32
const _ADMIN_PAIR_STRIDE := 8
const _ADMIN_COLOR_ROW_STRIDE := 32
const _ADMIN_MOMENT_SCALE := 1024
const _ADMIN_EXTRACT_MAX_RETRIES := 3

const _CACHEABLE_EXPORT_TEXTURES := {
	"geo": true,
	"river_biome_id": true,
	"river_flux": true,
	"water_mask": true,
	"region_map": true,
	"ocean_region_map": true,
	"biome_id": true,
}

# Water colors by atmosphere type
static var WATER_COLORS = {
	# Type 0 (Default) - Bleu
	0: {
		"saltwater": Color.hex(0x25528aFF),  # Océan
		"freshwater": Color.hex(0x4584d2FF)  # Lac
	},
	# Type 1 (Toxic) - saumures acides jaune-olive
	1: {
		"saltwater": Color.hex(0x414c2dFF),
		"freshwater": Color.hex(0x636c3aFF)
	},
	# Type 2 (Volcanic) - Lave
	2: {
		"saltwater": Color.hex(0x602a1cFF),
		"freshwater": Color.hex(0xb8491bFF)
	},
	# Type 4 (Dead) - eau sombre et lacs boueux
	4: {
		"saltwater": Color.hex(0x313d38FF),
		"freshwater": Color.hex(0x4c4f42FF)
	}
}

# Water darkening factor for final map
static var WATER_DARKENING_FACTOR = 0.85

## Coordonne l'extraction et la conversion de toutes les cartes générées.
##
## Cette méthode agit comme un chef d'orchestre pour le pipeline de sortie ("Readback").
## Elle appelle séquentiellement les méthodes d'export individuelles (_export_elevation_map, etc.)
## pour transformer les buffers de données brutes du GPU (VRAM) en objets [Image] manipulables par le CPU.
## Elle assure la cohérence des données entre les différentes couches (ex: s'assurer que la carte
## des biomes utilise bien les données d'élévation fraîchement extraites).
func _cancel_requested() -> bool:
	if not cancellation_probe.is_valid():
		return false
	var request = cancellation_probe.call()
	if request is Dictionary:
		return bool(request.get("cancelled", false))
	return bool(request)


func _abort_export_if_cancelled(export_started_usec: int) -> bool:
	if not _cancel_requested():
		return false
	last_metrics["cancelled"] = true
	_flush_png_jobs()
	_clear_readback_cache()
	_finalize_metrics(export_started_usec)
	print("[Exporter] Export cancelled by generation request")
	return true


func export_maps(gpu : GPUContext, output_dir: String, generation_params: Dictionary) -> Dictionary:
	"""
	Export all map types from GPU textures to PNG files
	Each individual export function handles its own threading internally
	
	Args:
		gpu: GPUContext with texture RIDs
		output_dir: Save directory path
		generation_params: Generation parameters (optional export_worker_count)
	
	Returns:
		Dictionary with keys: map_name -> file_path
	"""
	var export_started_usec := Time.get_ticks_usec()
	params = generation_params
	_nb_threads = _resolve_export_worker_count(params)
	_png_worker_limit = _resolve_png_worker_count(params)
	_admin_color_cursor = 0
	_png_jobs.clear()
	_png_failed_paths.clear()
	_readback_cache.clear()
	_readback_cache_bytes = 0
	_stage_timings.clear()
	_png_file_timings.clear()
	last_metrics = {
		"worker_count": _nb_threads,
		"png_worker_count": _png_worker_limit,
		"worker_policy": "automatic" if int(params.get("export_worker_count", 0)) <= 0 else "explicit_export_only",
		"readback_time_ms": 0.0,
		"readback_bytes": 0,
		"readback_count": 0,
		"readback_cache_hits": 0,
		"readback_cache_peak_bytes": 0,
		"png_compression_ms": 0.0,
		"png_checksum_ms": 0.0,
		"png_wait_ms": 0.0,
		"png_jobs": 0,
		"peak_cpu_map_bytes": 0,
		"peak_simultaneous_rgba32f_maps": 0,
		"rgba32f_map_readbacks": 0,
		"peak_system_ram_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
	}
	if _abort_export_if_cancelled(export_started_usec):
		return {}
	
	print("[Exporter] Starting map export to: ", output_dir,
		" (conversion workers=", _nb_threads, ", PNG workers=", _png_worker_limit,
		", policy=", last_metrics["worker_policy"], ")")
	
	if not DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	
	# Récupérer l'instance GPUContext
	var gpu_context = gpu
	if not gpu_context:
		push_error("[Exporter] GPUContext not available!")
		return {}
	
	var rd = gpu_context.rd
	
	# A single dependency barrier completes queued compute before streamed reads.
	gpu.sync_for_cpu("export_begin")
	
	# === TYPE 6 (GAZEUSE) : Export simplifié ===
	# Une géante gazeuse n'a pas de surface sur laquelle les cartes de climat
	# terrestres auraient un sens. Son rendu atmosphérique est entièrement
	# contenu dans final_map.
	var planet_type = int(params.get("planet_type", 0))
	if planet_type == 6:  # TYPE_GAZEUZE
		print("[Exporter] 🪐 Export gazeuse - carte atmosphérique finale uniquement")
		var exported_files = {}
		
		# Export final map
		var gas_stage_started := Time.get_ticks_usec()
		var final_result = _export_final_map(gpu, output_dir)
		for key in final_result.keys():
			exported_files[key] = final_result[key]
		_record_stage("final_map", gas_stage_started)
		var gas_png_started := Time.get_ticks_usec()
		_flush_png_jobs()
		_remove_failed_export_paths(exported_files)
		_record_stage("png_flush", gas_png_started)
		if _abort_export_if_cancelled(export_started_usec):
			return exported_files
		
		if bool(params.get("run_integrity_checks", true)):
			var integrity_report := PlanetIntegrityChecker.run(gpu, params, exported_files)
			var integrity_path := PlanetIntegrityChecker.save_report(output_dir, integrity_report)
			if not integrity_path.is_empty():
				exported_files["integrity_report"] = integrity_path
		exported_files = ExportCatalog.finalize_outputs(output_dir, exported_files, params)
		var manifest_path := PlanetManifest.save(output_dir, params, exported_files)
		if not manifest_path.is_empty():
			exported_files["manifest"] = manifest_path
		var project_path := PlanetProject.save(output_dir, params, exported_files)
		if not project_path.is_empty():
			exported_files["project"] = project_path
		_finalize_metrics(export_started_usec)
		print("[Exporter] Export gazeuse complete: ", exported_files.size(), " maps")
		return exported_files

	# GPUContext.prepare_for_export() deliberately frees every simulation shader
	# and pipeline before this function is called. Export compute shaders must
	# therefore be loaded here, after that lifecycle barrier, not during
	# GPUOrchestrator initialization. Otherwise all GPU export helpers silently
	# fall back to CPU even though their shaders compiled successfully earlier.
	var export_shader_specs := [
		["res://shader/compute/export/export_topography.glsl", "export_topography"],
		["res://shader/compute/export/export_final_map.glsl", "export_final_map"],
		["res://shader/compute/export/export_id_colorize.glsl", "export_id_colorize"],
		["res://shader/compute/export/export_admin_extract.glsl", "export_admin_extract"],
		["res://shader/compute/export/export_admin_hierarchy.glsl", "export_admin_hierarchy"],
		["res://shader/compute/export/export_resource_map.glsl", "export_resource_map"],
	]
	var export_shader_failures: Array[String] = []
	var export_shader_loaded := 0
	for shader_spec in export_shader_specs:
		var shader_path := str(shader_spec[0])
		var shader_name := str(shader_spec[1])
		var already_ready: bool = (
			gpu.shaders.has(shader_name)
			and gpu.pipelines.has(shader_name)
			and gpu.shaders[shader_name].is_valid()
			and gpu.pipelines[shader_name].is_valid()
		)
		if already_ready or gpu.load_compute_shader(shader_path, shader_name):
			export_shader_loaded += 1
		else:
			export_shader_failures.append(shader_name)
	last_metrics["gpu_export_shaders_loaded"] = export_shader_loaded
	last_metrics["gpu_export_shader_failures"] = export_shader_failures.duplicate()
	if export_shader_failures.is_empty():
		print("[Exporter] ✅ GPU export shaders ready: %d/%d" % [export_shader_loaded, export_shader_specs.size()])
	else:
		push_warning("[Exporter] GPU export shaders unavailable: %s; affected stages will use CPU fallback" % [
			str(export_shader_failures)
		])
	
	# Only geo and plates are export inputs. The previous path downloaded geo,
	# climate, temp_buffer, plates and crust_age together, retaining five full
	# RGBA32F CPU arrays while using only two of them.
	var rgba32f_textures = ["geo", "plates"]
	for map_type in rgba32f_textures:
		if not gpu.textures.has(map_type) or not gpu.textures[map_type]:
			push_error("[Exporter] ❌ Missing texture for map type: ", map_type)
			return {}

	var geo_format = rd.texture_get_format(gpu.textures["geo"])
	var width = geo_format.width
	var height = geo_format.height
	
	print("[Exporter] Detected texture size: ", width, "x", height)
	
	var expected_size = width * height * 16
	var exported_files = {}

	# Plates are consumed only once. Export them before retaining geo in the
	# readback cache so there is never more than one full RGBA32F CPU map alive.
	var stage_started := Time.get_ticks_usec()
	var plates_data := _read_texture(gpu, "plates")
	if plates_data.size() != expected_size:
		push_error("[Exporter] ❌ Plates data size mismatch: expected ", expected_size,
			", got ", plates_data.size())
		return {}
	var plates_result = _export_plates_map(plates_data, output_dir, width, height)
	for key in plates_result.keys():
		exported_files[key] = plates_result[key]
	plates_data = PackedByteArray()
	_record_stage("plates", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	# Geo is used by topography, cartography and a legacy saltwater recovery
	# fallback, so its single readback remains cached until hierarchy export.
	var geo_data := _read_texture(gpu, "geo")
	if geo_data.size() != expected_size:
		push_error("[Exporter] ❌ Geo data size mismatch: expected ", expected_size,
			", got ", geo_data.size())
		return {}
	stage_started = Time.get_ticks_usec()
	var topo_result = _export_topographie_maps(gpu, geo_data, output_dir, width, height)
	for key in topo_result.keys():
		exported_files[key] = topo_result[key]
	_record_stage("topography", stage_started)
	geo_data = PackedByteArray()
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	# === EXPORT CLIMAT (Step 3) - Optimisé RGBA8 Direct ===
	stage_started = Time.get_ticks_usec()
	# Les mondes sans atmosphère n'ont ni nuages ni surface liquide. Leur givre
	# terrestre éventuel fait partie de final_map, pas du masque de banquise.
	if planet_type in [3, 5]:  # TYPE_NO_ATMOS, TYPE_STERILE
		var climate_result = _export_climate_maps_without_clouds(gpu, output_dir)
		for key in climate_result.keys():
			exported_files[key] = climate_result[key]
	else:
		var climate_result = _export_climate_maps_optimized(gpu, output_dir)
		for key in climate_result.keys():
			exported_files[key] = climate_result[key]
	_record_stage("climate", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT EAUX (Step 2.5) - Classification des masses d'eau ===
	stage_started = Time.get_ticks_usec()
	# Pas d'eau sur planètes sans atmosphère ou stériles
	if planet_type not in [3, 5]:  # TYPE_NO_ATMOS, TYPE_STERILE
		var water_result = _export_water_classification(gpu, output_dir, width, height)
		for key in water_result.keys():
			exported_files[key] = water_result[key]
	
		# === EXPORT RIVIÈRES (Step 2.6) - Carte des rivières CPU ===
		var river_result = _export_river_map(gpu, output_dir, width, height)
		for key in river_result.keys():
			exported_files[key] = river_result[key]

		# === EXPORT TYPE RIVIÈRES (Step 2.7) - Carte des types de rivières ===
		var river_type_result = _export_river_type_map(gpu, output_dir, width, height)
		for key in river_type_result.keys():
			exported_files[key] = river_type_result[key]
	_record_stage("water_and_rivers", stage_started)
	_release_readback_cache("river_biome_id")
	_release_readback_cache("river_flux")
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT ADMINISTRATION (Step 4 + 4.5 + 4.6) ===
	# Extract the department graph on the GPU, keep political grouping on the CPU,
	# then render all four land (and four sea) hierarchy levels in one dispatch.
	stage_started = Time.get_ticks_usec()
	var administrative_result := _export_administrative_maps_hybrid(
		gpu, output_dir, planet_type not in [3, 5]
	)
	for key in administrative_result.keys():
		exported_files[key] = administrative_result[key]
	_record_stage("administration", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT BIOMES (Step 4.1) ===
	stage_started = Time.get_ticks_usec()
	var biome_result = _export_biome_map(gpu, output_dir)
	for key in biome_result.keys():
		exported_files[key] = biome_result[key]
	_record_stage("biome", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	# === CARTOGRAPHIE PALETTE-DRIVEN (Milestone 6) ===
	stage_started = Time.get_ticks_usec()
	if bool(params.get("export_cartographic_map", true)):
		var cartography_result := _export_cartographic_map(gpu, output_dir)
		for key in cartography_result.keys():
			exported_files[key] = cartography_result[key]
	if bool(params.get("export_grid_overlay", true)):
		var grid_overlay_result := _export_grid_overlay(gpu, output_dir)
		for key in grid_overlay_result.keys():
			exported_files[key] = grid_overlay_result[key]
	_record_stage("cartography", stage_started)
	_release_readback_cache("biome_id")
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT FINAL MAP (Step 6) ===
	stage_started = Time.get_ticks_usec()
	var final_result = _export_final_map(gpu, output_dir)
	for key in final_result.keys():
		exported_files[key] = final_result[key]
	_record_stage("final_map", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# Administration is already complete. Drop any legacy/readback cache before
	# streaming 100+ resource PNGs to keep the memory peak bounded.
	_clear_readback_cache()
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT RESSOURCES (Step 5) ===
	stage_started = Time.get_ticks_usec()
	var resources_result = _export_resources_maps(gpu, output_dir, width, height)
	for key in resources_result.keys():
		exported_files[key] = resources_result[key]
	_record_stage("resources", stage_started)
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	# Integrity/catalog must only see fully written files. This is the sole hard
	# barrier for the PNG worker pool in a normal export.
	stage_started = Time.get_ticks_usec()
	_flush_png_jobs()
	_remove_failed_export_paths(exported_files)
	_record_stage("png_flush", stage_started)
	
	if bool(params.get("run_integrity_checks", true)):
		stage_started = Time.get_ticks_usec()
		var integrity_report := PlanetIntegrityChecker.run(gpu, params, exported_files)
		var integrity_path := PlanetIntegrityChecker.save_report(output_dir, integrity_report)
		if not integrity_path.is_empty():
			exported_files["integrity_report"] = integrity_path
		_record_stage("integrity", stage_started)

	# M7.2: filtering/layout happens only after integrity has inspected the full
	# generated set, and before manifests compute their final relative paths.
	stage_started = Time.get_ticks_usec()
	exported_files = ExportCatalog.finalize_outputs(output_dir, exported_files, params)
	var manifest_path := PlanetManifest.save(output_dir, params, exported_files)
	if not manifest_path.is_empty():
		exported_files["manifest"] = manifest_path
	var project_path := PlanetProject.save(output_dir, params, exported_files)
	if not project_path.is_empty():
		exported_files["project"] = project_path
	_record_stage("catalog_manifest_project", stage_started)

	_finalize_metrics(export_started_usec)
	print("[Exporter] Export complete: ", exported_files.size(), " maps")
	print("[Exporter] Metrics: ", last_metrics)
	return exported_files


func _assign_administrative_colors(group_ids: Array) -> Dictionary:
	var unique_ids: Dictionary = {}
	for group_id in group_ids:
		unique_ids[group_id] = true
	var count := unique_ids.size()
	if _admin_color_cursor + count > HierarchyBuilder.ADMIN_COLOR_CAPACITY:
		push_error(
			"Administrative export needs %d unique colors, but RGBA8 can represent only %d reserved-safe colors"
			% [_admin_color_cursor + count, HierarchyBuilder.ADMIN_COLOR_CAPACITY]
		)
		return {}
	var colors := HierarchyBuilder.assign_colors(group_ids, _admin_color_cursor)
	_admin_color_cursor += count
	return colors

func _resolve_export_worker_count(generation_parameters: Dictionary) -> int:
	var processor_count := maxi(OS.get_processor_count(), 1)
	var requested := int(generation_parameters.get("export_worker_count", 0))
	if requested > 0:
		return clampi(requested, 1, processor_count)
	# Leave one logical processor available to the UI/OS and cap the number of
	# short-lived Thread objects. The GPU queue is deliberately unaffected.
	return clampi(processor_count - 1, 1, 16)


func _resolve_png_worker_count(generation_parameters: Dictionary) -> int:
	var processor_count := maxi(OS.get_processor_count(), 1)
	var requested := int(generation_parameters.get(
		"export_png_worker_count", generation_parameters.get("export_worker_count", 0)
	))
	if requested > 0:
		return clampi(requested, 1, mini(processor_count, 12))
	# PNG compression is CPU heavy and each in-flight image retains a full RGBA8
	# map. Half the logical cores, capped at 8, gives good overlap without turning
	# large exports into an unbounded RAM spike.
	return clampi(ceili(float(processor_count) * 0.5), 1, 8)


func _read_texture(gpu: GPUContext, texture_name: String) -> PackedByteArray:
	if _CACHEABLE_EXPORT_TEXTURES.has(texture_name) and _readback_cache.has(texture_name):
		last_metrics["readback_cache_hits"] = int(last_metrics.get("readback_cache_hits", 0)) + 1
		return _readback_cache[texture_name]
	var started_usec := Time.get_ticks_usec()
	var data := gpu.readback_texture_raw(texture_name)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_record_readback_metrics(gpu, texture_name, data, elapsed_ms)
	if _CACHEABLE_EXPORT_TEXTURES.has(texture_name) and not data.is_empty():
		_readback_cache[texture_name] = data
		_readback_cache_bytes += data.size()
		last_metrics["readback_cache_peak_bytes"] = maxi(
			int(last_metrics.get("readback_cache_peak_bytes", 0)), _readback_cache_bytes
		)
	return data


func _read_texture_rid(gpu: GPUContext, texture_rid: RID,
		label: String = "export_temp") -> PackedByteArray:
	if not texture_rid.is_valid():
		return PackedByteArray()
	gpu.sync_for_cpu("export_readback:" + label)
	var started_usec := Time.get_ticks_usec()
	var data := gpu.rd.texture_get_data(texture_rid, 0)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	last_metrics["readback_time_ms"] = float(last_metrics.get("readback_time_ms", 0.0)) + elapsed_ms
	last_metrics["readback_bytes"] = int(last_metrics.get("readback_bytes", 0)) + data.size()
	last_metrics["readback_count"] = int(last_metrics.get("readback_count", 0)) + 1
	last_metrics["peak_cpu_map_bytes"] = maxi(
		int(last_metrics.get("peak_cpu_map_bytes", 0)), data.size()
	)
	_sample_export_ram()
	return data


func _record_readback_metrics(gpu: GPUContext, texture_name: String,
		data: PackedByteArray, elapsed_ms: float) -> void:
	last_metrics["readback_time_ms"] = float(last_metrics.get("readback_time_ms", 0.0)) + elapsed_ms
	last_metrics["readback_bytes"] = int(last_metrics.get("readback_bytes", 0)) + data.size()
	last_metrics["readback_count"] = int(last_metrics.get("readback_count", 0)) + 1
	last_metrics["peak_cpu_map_bytes"] = maxi(
		int(last_metrics.get("peak_cpu_map_bytes", 0)), data.size()
	)
	if gpu.textures.has(texture_name):
		var texture_format := gpu.rd.texture_get_format(gpu.textures[texture_name])
		if texture_format.format == GPUContext.FORMAT_STATE:
			last_metrics["rgba32f_map_readbacks"] = int(last_metrics.get("rgba32f_map_readbacks", 0)) + 1
			last_metrics["peak_simultaneous_rgba32f_maps"] = 1
	_sample_export_ram()


func _release_readback_cache(texture_name: String) -> void:
	if not _readback_cache.has(texture_name):
		return
	var data: PackedByteArray = _readback_cache[texture_name]
	_readback_cache_bytes = maxi(_readback_cache_bytes - data.size(), 0)
	_readback_cache.erase(texture_name)


func _clear_readback_cache() -> void:
	_readback_cache.clear()
	_readback_cache_bytes = 0


func _save_png(image: Image, filepath: String) -> Error:
	if image == null or image.is_empty():
		return ERR_INVALID_DATA
	while _png_jobs.size() >= _png_worker_limit:
		_finish_oldest_png_job()
	FileChecksumCache.invalidate(filepath)
	var queued_usec := Time.get_ticks_usec()
	var thread := Thread.new()
	var start_error: Error = thread.start(_png_worker.bind(image, filepath))
	if start_error != OK:
		# Thread creation can fail under OS pressure. Preserve correctness with a
		# synchronous fallback instead of dropping an export.
		var sync_result: Dictionary = _png_worker(image, filepath)
		_consume_png_result(filepath, sync_result, queued_usec)
		return int(sync_result.get("error", FAILED))
	_png_jobs.append({
		"thread": thread,
		"path": filepath,
		"queued_usec": queued_usec,
	})
	last_metrics["png_jobs"] = int(last_metrics.get("png_jobs", 0)) + 1
	_sample_export_ram()
	return OK


func _png_worker(image: Image, filepath: String) -> Dictionary:
	var worker_started_usec := Time.get_ticks_usec()
	var compression_started := worker_started_usec
	var error: Error = image.save_png(filepath)
	var compression_ms := float(Time.get_ticks_usec() - compression_started) / 1000.0
	var checksum := ""
	var checksum_ms := 0.0
	if error == OK:
		var checksum_started := Time.get_ticks_usec()
		checksum = FileAccess.get_sha256(filepath)
		checksum_ms = float(Time.get_ticks_usec() - checksum_started) / 1000.0
	var worker_finished_usec := Time.get_ticks_usec()
	return {
		"error": error,
		"compression_ms": compression_ms,
		"checksum_ms": checksum_ms,
		"worker_wall_ms": float(worker_finished_usec - worker_started_usec) / 1000.0,
		"worker_started_usec": worker_started_usec,
		"worker_finished_usec": worker_finished_usec,
		"sha256": checksum,
	}


func _finish_oldest_png_job() -> void:
	if _png_jobs.is_empty():
		return
	var job: Dictionary = _png_jobs.pop_front()
	var thread: Thread = job["thread"]
	var wait_started := Time.get_ticks_usec()
	var worker_result = thread.wait_to_finish()
	last_metrics["png_wait_ms"] = float(last_metrics.get("png_wait_ms", 0.0)) + (
		float(Time.get_ticks_usec() - wait_started) / 1000.0
	)
	if worker_result is Dictionary:
		_consume_png_result(
			str(job["path"]),
			worker_result,
			int(job.get("queued_usec", 0)),
		)
	else:
		_png_failed_paths[str(job["path"])] = FAILED


func _consume_png_result(filepath: String, worker_result: Dictionary, queued_usec: int = 0) -> void:
	var error := int(worker_result.get("error", FAILED))
	var compression_ms := float(worker_result.get("compression_ms", 0.0))
	var checksum_ms := float(worker_result.get("checksum_ms", 0.0))
	var worker_wall_ms := float(worker_result.get(
		"worker_wall_ms", compression_ms + checksum_ms
	))
	var finished_usec := int(worker_result.get("worker_finished_usec", 0))
	var queue_to_ready_ms := worker_wall_ms
	if queued_usec > 0 and finished_usec >= queued_usec:
		queue_to_ready_ms = float(finished_usec - queued_usec) / 1000.0
	last_metrics["png_compression_ms"] = float(last_metrics.get("png_compression_ms", 0.0)) + compression_ms
	last_metrics["png_checksum_ms"] = float(last_metrics.get("png_checksum_ms", 0.0)) + checksum_ms
	var display_path := filepath.get_file()
	_png_file_timings[display_path] = {
		"encode_ms": compression_ms,
		"checksum_ms": checksum_ms,
		"worker_wall_ms": worker_wall_ms,
		"queue_to_ready_ms": queue_to_ready_ms,
	}
	print(
		"[Export Timing] PNG ", display_path,
		" = ", snappedf(worker_wall_ms, 0.01), " ms",
		" (encode=", snappedf(compression_ms, 0.01),
		" ms, checksum=", snappedf(checksum_ms, 0.01),
		" ms, queued→ready=", snappedf(queue_to_ready_ms, 0.01), " ms)",
	)
	FileChecksumCache.invalidate(filepath)
	if error == OK:
		var checksum := str(worker_result.get("sha256", ""))
		if not checksum.is_empty():
			FileChecksumCache.remember(filepath, checksum)
	else:
		_png_failed_paths[filepath] = error
		push_error("[Exporter] PNG worker failed for %s: %d" % [filepath, error])
	_sample_export_ram()


func _flush_png_jobs() -> void:
	while not _png_jobs.is_empty():
		_finish_oldest_png_job()


func _remove_failed_export_paths(exported_files: Dictionary) -> void:
	if _png_failed_paths.is_empty():
		return
	for key in exported_files.keys():
		if _png_failed_paths.has(str(exported_files[key])):
			exported_files.erase(key)


func _record_stage(stage_name: String, started_usec: int) -> void:
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_stage_timings[stage_name] = float(_stage_timings.get(stage_name, 0.0)) + elapsed_ms
	print("[Export Timing] ", stage_name, " = ", snappedf(elapsed_ms, 0.01), " ms")

func _sample_export_ram() -> void:
	last_metrics["peak_system_ram_bytes"] = maxi(
		int(last_metrics.get("peak_system_ram_bytes", 0)),
		int(Performance.get_monitor(Performance.MEMORY_STATIC))
	)

func _finalize_metrics(export_started_usec: int) -> void:
	var total_ms := float(Time.get_ticks_usec() - export_started_usec) / 1000.0
	last_metrics["total_export_ms"] = total_ms
	# Compression/checksum happen in parallel, so their summed worker CPU time
	# must not be subtracted from wall time. png_wait_ms is the actual time the
	# main export thread spent blocked on outstanding workers.
	last_metrics["cpu_conversion_ms"] = maxf(
		total_ms
		- float(last_metrics.get("readback_time_ms", 0.0))
		- float(last_metrics.get("png_wait_ms", 0.0)),
		0.0
	)
	last_metrics["stage_ms"] = _stage_timings.duplicate(true)
	last_metrics["png_file_ms"] = _png_file_timings.duplicate(true)
	print("[Export Timing] --- Export stage summary ---")
	for stage_name in _stage_timings.keys():
		print(
			"[Export Timing] ", stage_name, " = ",
			snappedf(float(_stage_timings[stage_name]), 0.01), " ms"
		)
	print("[Export Timing] --- PNG file summary ---")
	var png_names: Array = _png_file_timings.keys()
	png_names.sort()
	for png_name in png_names:
		var png_timing: Dictionary = _png_file_timings[png_name]
		print(
			"[Export Timing] ", png_name, " = ",
			snappedf(float(png_timing.get("worker_wall_ms", 0.0)), 0.01), " ms",
			" (encode=", snappedf(float(png_timing.get("encode_ms", 0.0)), 0.01),
			" ms, checksum=", snappedf(float(png_timing.get("checksum_ms", 0.0)), 0.01), " ms)"
		)
	print("[Export Timing] total_export = ", snappedf(total_ms, 0.01), " ms")
	_sample_export_ram()

func _create_export_rgba8_texture(gpu: GPUContext, width: int, height: int) -> RID:
	var format := RDTextureFormat.new()
	format.width = width
	format.height = height
	format.format = GPUContext.FORMAT_RGBA8
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return gpu.rd.texture_create(format, RDTextureView.new())


func _build_topography_palette_buffer() -> PackedByteArray:
	var color_thresholds: Array = Enum.COULEURS_ELEVATIONS.keys()
	var grey_thresholds: Array = Enum.COULEURS_ELEVATIONS_GREY.keys()
	color_thresholds.sort()
	grey_thresholds.sort()
	var bytes := PackedByteArray()
	bytes.resize((color_thresholds.size() + grey_thresholds.size()) * 16)
	var cursor := 0
	for threshold in color_thresholds:
		var color: Color = Enum.COULEURS_ELEVATIONS[threshold]
		bytes.encode_float(cursor, float(threshold))
		bytes.encode_float(cursor + 4, color.r)
		bytes.encode_float(cursor + 8, color.g)
		bytes.encode_float(cursor + 12, color.b)
		cursor += 16
	for threshold in grey_thresholds:
		var color: Color = Enum.COULEURS_ELEVATIONS_GREY[threshold]
		bytes.encode_float(cursor, float(threshold))
		bytes.encode_float(cursor + 4, color.r)
		bytes.encode_float(cursor + 8, color.g)
		bytes.encode_float(cursor + 12, color.b)
		cursor += 16
	return bytes


func _render_topography_gpu(gpu: GPUContext, width: int, height: int) -> Array:
	if not gpu.pipelines.has("export_topography") or not gpu.textures.has("geo"):
		return []
	var rd := gpu.rd
	var shader: RID = gpu.shaders["export_topography"]
	var outputs: Array[RID] = []
	for _i in range(3):
		var output := _create_export_rgba8_texture(gpu, width, height)
		if not output.is_valid():
			for rid in outputs:
				gpu.release_rid(rid)
			return []
		outputs.append(output)
	var texture_uniforms: Array[RDUniform] = [
		gpu.create_texture_uniform(0, gpu.textures["geo"]),
		gpu.create_texture_uniform(1, outputs[0]),
		gpu.create_texture_uniform(2, outputs[1]),
		gpu.create_texture_uniform(3, outputs[2]),
	]
	var texture_set := rd.uniform_set_create(texture_uniforms, shader, 0)
	var palette_bytes := _build_topography_palette_buffer()
	var palette_buffer := rd.storage_buffer_create(palette_bytes.size(), palette_bytes)
	var palette_uniform := RDUniform.new()
	palette_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	palette_uniform.binding = 0
	palette_uniform.add_id(palette_buffer)
	var palette_set := rd.uniform_set_create([palette_uniform], shader, 1)
	if not texture_set.is_valid() or not palette_set.is_valid():
		# Uniform sets must be released before the resources referenced by them.
		# RenderingDevice automatically invalidates a set as soon as one of its
		# textures/buffers is freed; freeing that invalidated RID afterwards emits
		# "Attempted to free invalid ID".
		gpu.release_rid(texture_set)
		gpu.release_rid(palette_set)
		gpu.release_rid(palette_buffer)
		for rid in outputs:
			gpu.release_rid(rid)
		return []

	var color_count := Enum.COULEURS_ELEVATIONS.size()
	var grey_count := Enum.COULEURS_ELEVATIONS_GREY.size()
	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_float(8, float(params.get("sea_level", 0.0)))
	push.encode_u32(12, 0 if int(params.get("planet_type", 0)) in [3, 5] else 1)
	push.encode_u32(16, color_count)
	push.encode_u32(20, color_count)
	push.encode_u32(24, grey_count)
	push.encode_u32(28, 0)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["export_topography"])
	rd.compute_list_bind_uniform_set(compute_list, texture_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, palette_set, 1)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(compute_list, ceili(width / 16.0), ceili(height / 16.0), 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()

	var images: Array = []
	# The provisional water overlay is only exported for worlds where the exact
	# hydrology/water-colour phase is absent. Normal watery worlds later export
	# authoritative water_colored, so do not read back a third unused RGBA8 map.
	var output_count := 3 if int(params.get("planet_type", 0)) in [3, 5] else 2
	for i in range(output_count):
		var data := _read_texture_rid(gpu, outputs[i], "topography_%d" % i)
		if data.size() != width * height * 4:
			images.clear()
			break
		images.append(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data))
	# Descriptor sets own references, not the resources themselves. Destroy the
	# sets first so they remain valid at free_rid() time, then release buffers and
	# temporary output textures.
	gpu.release_rid(texture_set)
	gpu.release_rid(palette_set)
	gpu.release_rid(palette_buffer)
	for rid in outputs:
		gpu.release_rid(rid)
	return images


func _unique_r32ui_ids(data: PackedByteArray) -> Array:
	var unique: Dictionary = {}
	for value in data.to_int32_array():
		var id := int(value)
		if id >= 0:
			unique[id] = true
	var ids: Array = unique.keys()
	ids.sort()
	return ids


func _pack_color_rgba8(color: Color) -> int:
	var r := clampi(roundi(color.r * 255.0), 0, 255)
	var g := clampi(roundi(color.g * 255.0), 0, 255)
	var b := clampi(roundi(color.b * 255.0), 0, 255)
	var a := clampi(roundi(color.a * 255.0), 0, 255)
	return r | (g << 8) | (b << 16) | (a << 24)


func _render_id_color_map_gpu(gpu: GPUContext, texture_name: String,
		raw_id_to_color: Dictionary, width: int, height: int) -> Image:
	if (
		raw_id_to_color.is_empty()
		or not gpu.pipelines.has("export_id_colorize")
		or not gpu.textures.has(texture_name)
	):
		return null
	var ids: Array = raw_id_to_color.keys()
	ids.sort()
	var pairs := PackedByteArray()
	pairs.resize(ids.size() * 8)
	for i in range(ids.size()):
		pairs.encode_u32(i * 8, int(ids[i]))
		pairs.encode_u32(i * 8 + 4, _pack_color_rgba8(raw_id_to_color[ids[i]]))
	var rd := gpu.rd
	var shader: RID = gpu.shaders["export_id_colorize"]
	var output := _create_export_rgba8_texture(gpu, width, height)
	var table_buffer := rd.storage_buffer_create(pairs.size(), pairs)
	if not output.is_valid() or not table_buffer.is_valid():
		gpu.release_rid(output)
		gpu.release_rid(table_buffer)
		return null
	var texture_set := rd.uniform_set_create([
		gpu.create_texture_uniform(0, gpu.textures[texture_name]),
		gpu.create_texture_uniform(1, output),
	], shader, 0)
	var table_uniform := RDUniform.new()
	table_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	table_uniform.binding = 0
	table_uniform.add_id(table_buffer)
	var table_set := rd.uniform_set_create([table_uniform], shader, 1)
	if not texture_set.is_valid() or not table_set.is_valid():
		gpu.release_rid(texture_set)
		gpu.release_rid(table_set)
		gpu.release_rid(table_buffer)
		gpu.release_rid(output)
		return null
	var push := PackedByteArray()
	push.resize(16)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_u32(8, ids.size())
	push.encode_u32(12, 0)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["export_id_colorize"])
	rd.compute_list_bind_uniform_set(compute_list, texture_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, table_set, 1)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(compute_list, ceili(width / 16.0), ceili(height / 16.0), 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	var output_data := _read_texture_rid(gpu, output, "id_colorize:" + texture_name)
	# Free descriptor sets before the output texture / lookup buffer that they
	# reference. Otherwise Godot invalidates both sets automatically and the two
	# following release_rid() calls become double-free attempts.
	gpu.release_rid(texture_set)
	gpu.release_rid(table_set)
	gpu.release_rid(table_buffer)
	gpu.release_rid(output)
	if output_data.size() != width * height * 4:
		return null
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output_data)


func _next_power_of_two(value: int) -> int:
	var result := 1
	var target := maxi(value, 1)
	while result < target:
		result <<= 1
	return result


func _create_storage_buffer_filled(rd: RenderingDevice, byte_size: int,
		fill_value: int) -> RID:
	if byte_size <= 0:
		return RID()
	var initial := PackedByteArray()
	initial.resize(byte_size)
	initial.fill(clampi(fill_value, 0, 255))
	return rd.storage_buffer_create(byte_size, initial)


func _storage_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _record_admin_buffer_readback(byte_count: int, elapsed_ms: float,
		compact_graph: bool = true) -> void:
	last_metrics["readback_time_ms"] = float(last_metrics.get("readback_time_ms", 0.0)) + elapsed_ms
	last_metrics["readback_bytes"] = int(last_metrics.get("readback_bytes", 0)) + byte_count
	last_metrics["readback_count"] = int(last_metrics.get("readback_count", 0)) + 1
	if compact_graph:
		last_metrics["admin_graph_readback_bytes"] = int(
			last_metrics.get("admin_graph_readback_bytes", 0)
		) + byte_count
	last_metrics["peak_cpu_map_bytes"] = maxi(
		int(last_metrics.get("peak_cpu_map_bytes", 0)), byte_count
	)
	_sample_export_ram()


func _read_buffer_after_sync(rd: RenderingDevice, buffer: RID,
		byte_count: int) -> PackedByteArray:
	if not buffer.is_valid() or byte_count <= 0:
		return PackedByteArray()
	var started_usec := Time.get_ticks_usec()
	var data: PackedByteArray = rd.buffer_get_data(buffer, 0, byte_count)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_record_admin_buffer_readback(data.size(), elapsed_ms)
	return data


func _release_admin_extract_resources(gpu: GPUContext, resources: Dictionary) -> void:
	for set_name in ["texture_set", "buffer_set"]:
		var uniform_set: RID = resources.get(set_name, RID())
		if uniform_set.is_valid():
			gpu.release_rid(uniform_set)
	for buffer_name in [
		"stat_hash", "edge_hash", "edges",
		"contact_hash", "contacts", "counters",
	]:
		var buffer: RID = resources.get(buffer_name, RID())
		if buffer.is_valid():
			gpu.release_rid(buffer)


func _dispatch_admin_extract_once(gpu: GPUContext, source_texture: String,
		width: int, height: int, maritime: bool, stat_capacity: int) -> Dictionary:
	var rd := gpu.rd
	if rd == null or not gpu.shaders.has("export_admin_extract"):
		return {"ok": false, "reason": "shader_unavailable"}
	if not gpu.textures.has(source_texture) or not gpu.textures[source_texture].is_valid():
		return {"ok": false, "reason": "source_unavailable"}
	if not gpu.textures.has("region_map") or not gpu.textures["region_map"].is_valid():
		return {"ok": false, "reason": "land_source_unavailable"}
	if not gpu.textures.has("water_mask") or not gpu.textures["water_mask"].is_valid():
		return {"ok": false, "reason": "water_mask_unavailable"}

	# Keep the sparse tables deliberately below 50% load. Unlike the previous
	# LOCKED-slot implementation these tables never wait for another workgroup:
	# each unit claims its id directly, while exact edge/contact pairs are claimed
	# with two atomic CAS operations. Capacity retries therefore mean real table
	# pressure rather than scheduler-dependent lock timeouts.
	var stat_hash_capacity := _next_power_of_two(stat_capacity * 2)
	var edge_capacity := maxi(stat_capacity * 4, 1024)
	var edge_hash_capacity := _next_power_of_two(edge_capacity * 2)
	var contact_capacity := maxi(stat_capacity * 2, 1024) if maritime else 1
	var contact_hash_capacity := _next_power_of_two(contact_capacity * 2) if maritime else 1

	var resources: Dictionary = {}
	# One 32-byte AdminStat lives directly in every stat hash slot. The first
	# uint is id+1 (zero means empty); the remaining atomics accumulate in place.
	# Reading the sparse table is only a few MiB for normal worlds and avoids the
	# cross-workgroup publication lock that caused false OVERFLOW_STATS flags.
	resources["stat_hash"] = _create_storage_buffer_filled(
		rd, stat_hash_capacity * _ADMIN_STAT_STRIDE, 0
	)
	resources["edge_hash"] = _create_storage_buffer_filled(
		rd, edge_hash_capacity * _ADMIN_PAIR_STRIDE, 0
	)
	resources["edges"] = _create_storage_buffer_filled(
		rd, edge_capacity * _ADMIN_PAIR_STRIDE, 0
	)
	resources["contact_hash"] = _create_storage_buffer_filled(
		rd, contact_hash_capacity * _ADMIN_PAIR_STRIDE, 0
	)
	resources["contacts"] = _create_storage_buffer_filled(
		rd, contact_capacity * _ADMIN_PAIR_STRIDE, 0
	)
	resources["counters"] = _create_storage_buffer_filled(rd, 16, 0)
	for buffer_name in [
		"stat_hash", "edge_hash", "edges",
		"contact_hash", "contacts", "counters",
	]:
		var buffer: RID = resources[buffer_name]
		if not buffer.is_valid():
			_release_admin_extract_resources(gpu, resources)
			return {"ok": false, "reason": "buffer_allocation_failed"}

	var shader: RID = gpu.shaders["export_admin_extract"]
	var texture_set := rd.uniform_set_create([
		gpu.create_texture_uniform(0, gpu.textures[source_texture]),
		gpu.create_texture_uniform(1, gpu.textures["region_map"]),
		gpu.create_texture_uniform(2, gpu.textures["water_mask"]),
	], shader, 0)
	var buffer_set := rd.uniform_set_create([
		_storage_buffer_uniform(0, resources["stat_hash"]),
		_storage_buffer_uniform(1, resources["edge_hash"]),
		_storage_buffer_uniform(2, resources["edges"]),
		_storage_buffer_uniform(3, resources["contact_hash"]),
		_storage_buffer_uniform(4, resources["contacts"]),
		_storage_buffer_uniform(5, resources["counters"]),
	], shader, 1)
	resources["texture_set"] = texture_set
	resources["buffer_set"] = buffer_set
	if not texture_set.is_valid() or not buffer_set.is_valid():
		_release_admin_extract_resources(gpu, resources)
		return {"ok": false, "reason": "uniform_set_failed"}

	var push := PackedByteArray()
	push.resize(48)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_u32(8, stat_hash_capacity)
	push.encode_u32(12, stat_capacity)
	push.encode_u32(16, edge_hash_capacity)
	push.encode_u32(20, edge_capacity)
	push.encode_u32(24, contact_hash_capacity)
	push.encode_u32(28, contact_capacity)
	push.encode_u32(32, 1 if maritime else 0)
	push.encode_u32(36, _ADMIN_MOMENT_SCALE)
	push.encode_u32(40, 0)
	push.encode_u32(44, 0)

	var dispatch_started := Time.get_ticks_usec()
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(
		compute_list, gpu.pipelines["export_admin_extract"]
	)
	rd.compute_list_bind_uniform_set(compute_list, texture_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, buffer_set, 1)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(
		compute_list, ceili(width / 16.0), ceili(height / 16.0), 1
	)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	gpu.sync_for_cpu("export_admin_extract:" + source_texture)
	var dispatch_ms := float(Time.get_ticks_usec() - dispatch_started) / 1000.0
	last_metrics["admin_gpu_extract_ms"] = float(
		last_metrics.get("admin_gpu_extract_ms", 0.0)
	) + dispatch_ms

	var counters_data := _read_buffer_after_sync(rd, resources["counters"], 16)
	if counters_data.size() != 16:
		_release_admin_extract_resources(gpu, resources)
		return {"ok": false, "reason": "counter_readback_failed"}
	var stat_count := int(counters_data.decode_u32(0))
	var edge_count := int(counters_data.decode_u32(4))
	var contact_count := int(counters_data.decode_u32(8))
	var overflow_flags := int(counters_data.decode_u32(12))
	if overflow_flags != 0:
		_release_admin_extract_resources(gpu, resources)
		return {
			"ok": false,
			"reason": "capacity_overflow",
			"overflow": overflow_flags,
			"stat_count": stat_count,
			"edge_count": edge_count,
			"contact_count": contact_count,
			"stat_capacity": stat_capacity,
			"edge_capacity": edge_capacity,
			"contact_capacity": contact_capacity,
		}

	stat_count = mini(stat_count, stat_capacity)
	edge_count = mini(edge_count, edge_capacity)
	contact_count = mini(contact_count, contact_capacity)
	# Stats are sparse hash slots, not a compact prefix. Read the complete table;
	# edges/contacts remain compact because the lock-free pair insertion knows
	# exactly which invocation first completed a new pair.
	var stats_data := _read_buffer_after_sync(
		rd, resources["stat_hash"], stat_hash_capacity * _ADMIN_STAT_STRIDE
	)
	var edges_data := _read_buffer_after_sync(
		rd, resources["edges"], edge_count * _ADMIN_PAIR_STRIDE
	)
	var contacts_data := PackedByteArray()
	if maritime and contact_count > 0:
		contacts_data = _read_buffer_after_sync(
			rd, resources["contacts"], contact_count * _ADMIN_PAIR_STRIDE
		)
	_release_admin_extract_resources(gpu, resources)

	if stats_data.size() != stat_hash_capacity * _ADMIN_STAT_STRIDE:
		return {"ok": false, "reason": "stats_readback_failed"}
	if edges_data.size() != edge_count * _ADMIN_PAIR_STRIDE:
		return {"ok": false, "reason": "edges_readback_failed"}
	if maritime and contacts_data.size() != contact_count * _ADMIN_PAIR_STRIDE:
		return {"ok": false, "reason": "contacts_readback_failed"}
	return {
		"ok": true,
		"stats": stats_data,
		"edges": edges_data,
		"contacts": contacts_data,
		"stat_count": stat_count,
		"stat_slot_count": stat_hash_capacity,
		"edge_count": edge_count,
		"contact_count": contact_count,
	}


func _decode_admin_graph(extracted: Dictionary, width: int, height: int,
		maritime: bool) -> Dictionary:
	var stat_count := int(extracted.get("stat_count", 0))
	var stat_slot_count := int(extracted.get("stat_slot_count", stat_count))
	var edge_count := int(extracted.get("edge_count", 0))
	var contact_count := int(extracted.get("contact_count", 0))
	var stats_data: PackedByteArray = extracted.get("stats", PackedByteArray())
	var edges_data: PackedByteArray = extracted.get("edges", PackedByteArray())
	var contacts_data: PackedByteArray = extracted.get("contacts", PackedByteArray())
	var coords: Dictionary = {}
	var weights: Dictionary = {}
	var adjacency: Dictionary = {}
	var saltwater_units: Dictionary = {}
	var first_seen: Dictionary = {}

	# Pack sortable pairs into native PackedInt64Array buffers. Array.sort_custom()
	# on hundreds of thousands of two-element Variant arrays was a significant
	# hidden CPU cost in the first hybrid exporter.
	var ordering_keys := PackedInt64Array()
	ordering_keys.resize(stat_count)
	var ordering_count := 0
	for stat_index in range(stat_slot_count):
		var offset := stat_index * _ADMIN_STAT_STRIDE
		var stored_key := int(stats_data.decode_u32(offset))
		if stored_key == 0:
			continue
		var unit_id := int((stored_key - 1) & 0xFFFFFFFF)
		var count := int(stats_data.decode_u32(offset + 4))
		if count <= 0:
			continue
		# The GPU uses 32-bit atomics. Guard pathological single-department maps
		# rather than accepting wrapped moments; the caller will use the legacy CPU
		# path in that extremely rare case.
		if int(count) * maxi(height - 1, 0) > 0xFFFFFFFF:
			return {"ok": false, "reason": "moment_overflow_risk"}
		if int(count) * _ADMIN_MOMENT_SCALE > 0x7FFFFFFF:
			return {"ok": false, "reason": "moment_overflow_risk"}
		var sum_cos := int(stats_data.decode_s32(offset + 8))
		var sum_sin := int(stats_data.decode_s32(offset + 12))
		var sum_y := int(stats_data.decode_u32(offset + 16))
		var first_rank := int(stats_data.decode_u32(offset + 20))
		var first_pixel := 0xFFFFFFFF - first_rank
		var flags := int(stats_data.decode_u32(offset + 24))
		var angle := atan2(float(sum_sin), float(sum_cos))
		if angle < 0.0:
			angle += TAU
		coords[unit_id] = Vector2(
			angle * float(width) / TAU - 0.5,
			float(sum_y) / float(count)
		)
		weights[unit_id] = count
		adjacency[unit_id] = {}
		first_seen[unit_id] = first_pixel
		ordering_keys[ordering_count] = (
			(int(first_pixel) << 32) | (unit_id & 0xFFFFFFFF)
		)
		ordering_count += 1
		if maritime and (flags & 1) != 0:
			saltwater_units[unit_id] = true

	ordering_keys.resize(ordering_count)
	ordering_keys.sort()
	var ids: Array = []
	ids.resize(ordering_count)
	for ordering_index in range(ordering_count):
		ids[ordering_index] = int(ordering_keys[ordering_index] & 0xFFFFFFFF)

	var edge_keys := PackedInt64Array()
	edge_keys.resize(edge_count)
	var valid_edge_count := 0
	for edge_index in range(edge_count):
		var edge_offset := edge_index * _ADMIN_PAIR_STRIDE
		var a := int(edges_data.decode_u32(edge_offset))
		var b := int(edges_data.decode_u32(edge_offset + 4))
		if a == 0xFFFFFFFF or b == 0xFFFFFFFF or a == b:
			continue
		if not adjacency.has(a) or not adjacency.has(b):
			continue
		var lo := mini(a, b)
		var hi := maxi(a, b)
		edge_keys[valid_edge_count] = (
			(lo << 32) | (hi & 0xFFFFFFFF)
		)
		valid_edge_count += 1
	edge_keys.resize(valid_edge_count)
	edge_keys.sort()
	var unique_edge_count := 0
	var previous_edge := 0
	var has_previous_edge := false
	for packed_edge in edge_keys:
		if has_previous_edge and int(packed_edge) == previous_edge:
			continue
		previous_edge = int(packed_edge)
		has_previous_edge = true
		var a := int((int(packed_edge) >> 32) & 0xFFFFFFFF)
		var b := int(int(packed_edge) & 0xFFFFFFFF)
		(adjacency[a] as Dictionary)[b] = true
		(adjacency[b] as Dictionary)[a] = true
		unique_edge_count += 1

	var contacts: Dictionary = {}
	if maritime:
		for contact_index in range(contact_count):
			var contact_offset := contact_index * _ADMIN_PAIR_STRIDE
			var sea_id := int(contacts_data.decode_u32(contact_offset))
			var land_id := int(contacts_data.decode_u32(contact_offset + 4))
			if sea_id == 0xFFFFFFFF or land_id == 0xFFFFFFFF:
				continue
			if not contacts.has(sea_id):
				contacts[sea_id] = {}
			(contacts[sea_id] as Dictionary)[land_id] = true

	return {
		"ok": true,
		"info": [ids, coords, adjacency, weights],
		"contacts": contacts,
		"saltwater_units": saltwater_units,
		"first_seen": first_seen,
		"unit_count": ids.size(),
		"edge_count": unique_edge_count,
		"contact_count": contact_count,
	}


func _extract_admin_graph_gpu(gpu: GPUContext, source_texture: String,
		width: int, height: int, maritime: bool) -> Dictionary:
	if (
		not gpu.pipelines.has("export_admin_extract")
		or not gpu.shaders.has("export_admin_extract")
	):
		return {"ok": false, "reason": "shader_unavailable"}
	var pixel_count := width * height
	# Administrative normalization targets at least tens of pixels per unit. A
	# 1/64 initial estimate keeps temporary SSBOs small; overflow causes a bounded
	# retry with twice the capacity without ever accepting truncated graph data.
	var initial_units := maxi(1024, ceili(float(pixel_count) / 64.0))
	var stat_capacity := _next_power_of_two(initial_units)
	for attempt in range(_ADMIN_EXTRACT_MAX_RETRIES):
		var extracted := _dispatch_admin_extract_once(
			gpu, source_texture, width, height, maritime, stat_capacity
		)
		if bool(extracted.get("ok", false)):
			var decode_started_usec: int = Time.get_ticks_usec()
			var decoded := _decode_admin_graph(extracted, width, height, maritime)
			var decode_ms: float = float(
				Time.get_ticks_usec() - decode_started_usec
			) / 1000.0
			last_metrics["admin_graph_decode_ms"] = float(
				last_metrics.get("admin_graph_decode_ms", 0.0)
			) + decode_ms
			if bool(decoded.get("ok", false)):
				decoded["attempts"] = attempt + 1
				last_metrics["admin_graph_units_" + source_texture] = int(
					decoded.get("unit_count", 0)
				)
				last_metrics["admin_graph_edges_" + source_texture] = int(
					decoded.get("edge_count", 0)
				)
				print(
					(
						"[Admin Timing] %s graph decode = %.2f ms "
						+ "(%d units, %d edges, attempt %d)"
					) % [
						source_texture, decode_ms,
						int(decoded.get("unit_count", 0)),
						int(decoded.get("edge_count", 0)), attempt + 1,
					]
				)
				return decoded
			return decoded
		if str(extracted.get("reason", "")) != "capacity_overflow":
			return extracted
		print(
			(
				"[Exporter] Administrative GPU graph capacity retry %d/%d "
				+ "(%s, units=%d, flags=0x%X, observed stats/edges/contacts=%d/%d/%d)"
			) % [
				attempt + 1, _ADMIN_EXTRACT_MAX_RETRIES, source_texture,
				stat_capacity, int(extracted.get("overflow", 0)),
				int(extracted.get("stat_count", 0)),
				int(extracted.get("edge_count", 0)),
				int(extracted.get("contact_count", 0)),
			]
		)
		stat_capacity *= 2
	return {"ok": false, "reason": "capacity_overflow"}


func _build_admin_level_colors(hierarchy: Array) -> Array:
	var colors: Array = []
	for level_index in range(3):
		var mapping: Dictionary = hierarchy[level_index] if level_index < hierarchy.size() else {}
		if mapping.is_empty():
			colors.append({})
			continue
		colors.append(_assign_administrative_colors(HierarchyBuilder._unique_values(mapping)))
	return colors


func _admin_hierarchy_output_mask(hierarchy: Array) -> Array:
	var mask: Array = [true]
	for level_index in range(3):
		var mapping: Dictionary = hierarchy[level_index] if level_index < hierarchy.size() else {}
		mask.append(not mapping.is_empty())
	return mask


func _build_admin_color_table(unit_ids: Array, department_colors: Dictionary,
		hierarchy: Array, level_colors: Array) -> PackedByteArray:
	var ordered_ids := unit_ids.duplicate()
	ordered_ids.sort()
	var table := PackedByteArray()
	table.resize(ordered_ids.size() * _ADMIN_COLOR_ROW_STRIDE)
	for index in range(ordered_ids.size()):
		var unit_id := int(ordered_ids[index])
		var offset := index * _ADMIN_COLOR_ROW_STRIDE
		table.encode_u32(offset, unit_id)
		var department_color: Color = department_colors.get(
			unit_id, Color.TRANSPARENT
		)
		table.encode_u32(offset + 4, _pack_color_rgba8(department_color))
		for level_index in range(3):
			var mapping: Dictionary = hierarchy[level_index] if level_index < hierarchy.size() else {}
			var colors: Dictionary = level_colors[level_index] if level_index < level_colors.size() else {}
			var group_id := int(mapping.get(unit_id, -1))
			var color: Color = Color.TRANSPARENT
			if group_id != -1 and colors.has(group_id):
				color = colors[group_id]
			table.encode_u32(offset + 8 + level_index * 4, _pack_color_rgba8(color))
		# Remaining 12 bytes are padding for predictable std430 struct stride.
		table.encode_u32(offset + 20, 0)
		table.encode_u32(offset + 24, 0)
		table.encode_u32(offset + 28, 0)
	return table


func _render_admin_family_gpu(gpu: GPUContext, source_texture: String,
		color_table: PackedByteArray, row_count: int, width: int, height: int,
		output_dir: String, filenames: Array, result_keys: Array,
		enabled_outputs: Array) -> Dictionary:
	var result: Dictionary = {}
	if row_count <= 0 or color_table.is_empty():
		return result
	if (
		not gpu.pipelines.has("export_admin_hierarchy")
		or not gpu.shaders.has("export_admin_hierarchy")
		or not gpu.textures.has(source_texture)
	):
		return result
	var rd := gpu.rd
	var shader: RID = gpu.shaders["export_admin_hierarchy"]
	var outputs: Array[RID] = []
	for _index in range(4):
		var output := _create_export_rgba8_texture(gpu, width, height)
		if not output.is_valid():
			for existing in outputs:
				gpu.release_rid(existing)
			return result
		outputs.append(output)
	var table_buffer := rd.storage_buffer_create(color_table.size(), color_table)
	if not table_buffer.is_valid():
		for output in outputs:
			gpu.release_rid(output)
		return result
	var texture_uniforms: Array[RDUniform] = [
		gpu.create_texture_uniform(0, gpu.textures[source_texture]),
	]
	for output_index in range(outputs.size()):
		texture_uniforms.append(gpu.create_texture_uniform(
			output_index + 1, outputs[output_index]
		))
	var texture_set := rd.uniform_set_create(texture_uniforms, shader, 0)
	var table_set := rd.uniform_set_create([
		_storage_buffer_uniform(0, table_buffer),
	], shader, 1)
	if not texture_set.is_valid() or not table_set.is_valid():
		gpu.release_rid(texture_set)
		gpu.release_rid(table_set)
		gpu.release_rid(table_buffer)
		for output in outputs:
			gpu.release_rid(output)
		return result

	var push := PackedByteArray()
	push.resize(16)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_u32(8, row_count)
	push.encode_u32(12, 0)
	var dispatch_started := Time.get_ticks_usec()
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(
		compute_list, gpu.pipelines["export_admin_hierarchy"]
	)
	rd.compute_list_bind_uniform_set(compute_list, texture_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, table_set, 1)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(
		compute_list, ceili(width / 16.0), ceili(height / 16.0), 1
	)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	gpu.sync_for_cpu("export_admin_render:" + source_texture)
	last_metrics["admin_gpu_render_ms"] = float(
		last_metrics.get("admin_gpu_render_ms", 0.0)
	) + float(Time.get_ticks_usec() - dispatch_started) / 1000.0

	var expected_bytes := width * height * 4
	var family_ok := true
	for output_index in range(outputs.size()):
		if output_index < enabled_outputs.size() and not bool(enabled_outputs[output_index]):
			continue
		var read_started := Time.get_ticks_usec()
		var data: PackedByteArray = rd.texture_get_data(outputs[output_index], 0)
		var read_ms := float(Time.get_ticks_usec() - read_started) / 1000.0
		_record_admin_buffer_readback(data.size(), read_ms, false)
		if data.size() != expected_bytes:
			family_ok = false
			continue
		var image := Image.create_from_data(
			width, height, false, Image.FORMAT_RGBA8, data
		)
		var filepath: String = output_dir.path_join(str(filenames[output_index]))
		var save_error: Error = _save_png(image, filepath)
		if save_error == OK:
			result[str(result_keys[output_index])] = filepath
		else:
			family_ok = false

	gpu.release_rid(texture_set)
	gpu.release_rid(table_set)
	gpu.release_rid(table_buffer)
	for output in outputs:
		gpu.release_rid(output)
	if not family_ok:
		push_warning("[Exporter] Administrative GPU family render was incomplete: " + source_texture)
	return result


func _export_administrative_maps_legacy(gpu: GPUContext, output_dir: String,
		include_sea: bool) -> Dictionary:
	var result: Dictionary = {}
	var land_result := _export_region_map(
		gpu, output_dir, bool(params.get("region_generation_optimised", true))
	)
	for key in land_result.keys():
		result[key] = land_result[key]
	if include_sea:
		var sea_result := _export_ocean_region_map(
			gpu, output_dir, bool(params.get("region_generation_optimised", true))
		)
		for key in sea_result.keys():
			result[key] = sea_result[key]
	var hierarchy_result := _export_hierarchy_maps(gpu, output_dir)
	for key in hierarchy_result.keys():
		result[key] = hierarchy_result[key]
	return result


func _export_administrative_maps_hybrid(gpu: GPUContext, output_dir: String,
		include_sea: bool) -> Dictionary:
	var cursor_before := _admin_color_cursor
	if (
		not gpu.pipelines.has("export_admin_extract")
		or not gpu.pipelines.has("export_admin_hierarchy")
	):
		push_warning("[Exporter] Administrative compute shaders unavailable; using legacy CPU scan")
		return _export_administrative_maps_legacy(gpu, output_dir, include_sea)
	if not gpu.textures.has("region_map") or not gpu.textures["region_map"].is_valid():
		return {}
	var format := gpu.rd.texture_get_format(gpu.textures["region_map"])
	var width := int(format.width)
	var height := int(format.height)

	print("[Exporter] 🏛️ Administrative export: GPU graph → CPU hierarchy → GPU multi-map")
	var land_graph := _extract_admin_graph_gpu(
		gpu, "region_map", width, height, false
	)
	if not bool(land_graph.get("ok", false)):
		push_warning("[Exporter] Land graph GPU extraction failed (%s); using legacy path" % [
			str(land_graph.get("reason", "unknown"))
		])
		_admin_color_cursor = cursor_before
		return _export_administrative_maps_legacy(gpu, output_dir, include_sea)

	var sea_graph: Dictionary = {}
	if include_sea and gpu.textures.has("ocean_region_map") and gpu.textures["ocean_region_map"].is_valid():
		sea_graph = _extract_admin_graph_gpu(
			gpu, "ocean_region_map", width, height, true
		)
		if not bool(sea_graph.get("ok", false)):
			push_warning("[Exporter] Sea graph GPU extraction failed (%s); using legacy path" % [
				str(sea_graph.get("reason", "unknown"))
			])
			_admin_color_cursor = cursor_before
			return _export_administrative_maps_legacy(gpu, output_dir, include_sea)

	var land_info: Array = land_graph["info"]
	var land_ids: Array = land_info[0]
	if land_ids.is_empty():
		return {}
	print("    GPU graph: %d land departments, %d adjacency edges" % [
		land_ids.size(), int(land_graph.get("edge_count", 0))
	])
	var hierarchy_started := Time.get_ticks_usec()
	var land_hierarchy := HierarchyBuilder.build_land_from_graph(
		land_info, width, height, params
	)
	var sea_hierarchy: Array = [{}, {}, {}]
	var sea_ids: Array = []
	if not sea_graph.is_empty():
		var sea_info: Array = sea_graph["info"]
		sea_ids = sea_info[0]
		var extracted_saltwater: Dictionary = sea_graph.get("saltwater_units", {})
		if not sea_ids.is_empty() and extracted_saltwater.is_empty():
			# Preserve the legacy re-export compatibility path that can reconstruct
			# saltwater labels from geo when an old in-memory generation converted
			# every water-mask value to freshwater.
			push_warning("[Exporter] No saltwater labels in GPU graph; using legacy recovery path")
			_admin_color_cursor = cursor_before
			return _export_administrative_maps_legacy(gpu, output_dir, include_sea)
		print("    GPU graph: %d sea departments, %d adjacency edges, %d coast contacts" % [
			sea_ids.size(), int(sea_graph.get("edge_count", 0)),
			int(sea_graph.get("contact_count", 0))
		])
		var sea_contacts: Dictionary = sea_graph.get("contacts", {})
		sea_hierarchy = HierarchyBuilder.build_sea_from_graph(
			sea_info, width, height, params, land_hierarchy,
			sea_contacts, extracted_saltwater
		)
	last_metrics["admin_cpu_hierarchy_ms"] = float(
		Time.get_ticks_usec() - hierarchy_started
	) / 1000.0

	# Preserve the legacy shared-color namespace order: land departments, sea
	# departments, then the three land and three sea hierarchy levels.
	var land_department_colors := _assign_administrative_colors(land_ids)
	var sea_department_colors: Dictionary = {}
	if not sea_ids.is_empty():
		sea_department_colors = _assign_administrative_colors(sea_ids)
	var land_level_colors := _build_admin_level_colors(land_hierarchy)
	var sea_level_colors: Array = [{}, {}, {}]
	if not sea_ids.is_empty():
		sea_level_colors = _build_admin_level_colors(sea_hierarchy)

	var result: Dictionary = {}
	var land_table := _build_admin_color_table(
		land_ids, land_department_colors, land_hierarchy, land_level_colors
	)
	var land_rendered := _render_admin_family_gpu(
		gpu, "region_map", land_table, land_ids.size(), width, height,
		output_dir,
		["departement_map.png", "region_map.png", "pays_map.png", "continent_map.png"],
		["region_colored", "Régions terrestres", "Pays", "Continents"],
		_admin_hierarchy_output_mask(land_hierarchy)
	)
	for key in land_rendered.keys():
		result[key] = land_rendered[key]

	if not sea_ids.is_empty():
		var sea_table := _build_admin_color_table(
			sea_ids, sea_department_colors, sea_hierarchy, sea_level_colors
		)
		var sea_rendered := _render_admin_family_gpu(
			gpu, "ocean_region_map", sea_table, sea_ids.size(), width, height,
			output_dir,
			[
				"departement_mer_map.png", "region_mer_map.png",
				"bassin_map.png", "ocean_map.png",
			],
			["ocean_region_colored", "Régions maritimes", "Bassins", "Océans"],
			_admin_hierarchy_output_mask(sea_hierarchy)
		)
		for key in sea_rendered.keys():
			result[key] = sea_rendered[key]

	last_metrics["admin_hybrid_used"] = true
	last_metrics["admin_land_departments"] = land_ids.size()
	last_metrics["admin_sea_departments"] = sea_ids.size()
	print("[Exporter] ✅ Administrative hybrid export queued: %d maps" % result.size())
	return result




func _create_resource_export_renderer(gpu: GPUContext, width: int, height: int) -> Dictionary:
	if not gpu.pipelines.has("export_resource_map") or not gpu.textures.has("resources"):
		return {}
	var output := _create_export_rgba8_texture(gpu, width, height)
	if not output.is_valid():
		return {}
	var texture_set := gpu.rd.uniform_set_create([
		gpu.create_texture_uniform(0, gpu.textures["resources"]),
		gpu.create_texture_uniform(1, output),
	], gpu.shaders["export_resource_map"], 0)
	if not texture_set.is_valid():
		gpu.release_rid(output)
		return {}
	return {"output": output, "set": texture_set}


func _render_resource_map_gpu(gpu: GPUContext, renderer: Dictionary,
		resource_id: int, color: Color, width: int, height: int) -> Image:
	if renderer.is_empty():
		return null
	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_u32(8, resource_id)
	push.encode_u32(12, clampi(roundi(color.r * 255.0), 0, 255))
	push.encode_u32(16, clampi(roundi(color.g * 255.0), 0, 255))
	push.encode_u32(20, clampi(roundi(color.b * 255.0), 0, 255))
	push.encode_u32(24, 0)
	push.encode_u32(28, 0)
	var rd := gpu.rd
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["export_resource_map"])
	rd.compute_list_bind_uniform_set(compute_list, renderer["set"], 0)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(compute_list, ceili(width / 16.0), ceili(height / 16.0), 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	var data := _read_texture_rid(gpu, renderer["output"], "resource:%d" % resource_id)
	if data.size() != width * height * 4:
		return null
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)


func _destroy_resource_export_renderer(gpu: GPUContext, renderer: Dictionary) -> void:
	if renderer.has("set"):
		gpu.release_rid(renderer["set"])
	if renderer.has("output"):
		gpu.release_rid(renderer["output"])


# ============================================================================
# INDIVIDUAL MAP EXPORTERS
# ============================================================================

## Exporte les cartes topographiques (élévation) en trois versions :
## - Version colorée : utilise COULEURS_ELEVATIONS d'Enum.gd
## - Version grisée : utilise COULEURS_ELEVATIONS_GREY d'Enum.gd
## - Courbes de niveau : lignes seules sur fond RGBA transparent
##
## La GeoTexture contient :
## - R = height (élévation en mètres, float brut)
## - G = bedrock (résistance)
## - B = sediment (épaisseur sédiments)
## - A = water_height (colonne d'eau)
##
## @param geo_img: Image RGBAF provenant de la texture GPU "geo"
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _export_topographie_maps(gpu: GPUContext, geo_data: PackedByteArray,
		output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🏔️ Exporting topographic maps (GPU palette conversion)...")
	var result: Dictionary = {}
	var pixel_count := width * height
	var geo_values := geo_data.to_float32_array()
	if geo_values.size() < pixel_count * 4:
		push_error("[Exporter] ❌ Invalid RGBA32F geo payload for topography")
		return result

	# Topology still needs scalar elevations on the CPU. Extraction is now a
	# contiguous packed-array pass instead of Image.get_pixel() calls.
	var relative_elevations := PackedFloat32Array()
	relative_elevations.resize(pixel_count)
	var sea_level := float(params.get("sea_level", 0.0))
	for pixel_index in range(pixel_count):
		relative_elevations[pixel_index] = geo_values[pixel_index * 4] - sea_level

	var images := _render_topography_gpu(gpu, width, height)
	var expected_images := 3 if int(params.get("planet_type", 0)) in [3, 5] else 2
	if images.size() != expected_images:
		push_warning("[Exporter] ⚠️ GPU topography conversion unavailable; using packed CPU fallback")
		images = _build_topography_cpu_fallback(geo_values, width, height, sea_level)
	if images.size() < expected_images:
		return result

	var topology_overlay := _build_topology_overlay(relative_elevations, width, height)
	var paths := [
		output_dir.path_join("topographie_map.png"),
		output_dir.path_join("topographie_map_grey.png"),
		output_dir.path_join("topology_map.png"),
	]
	var output_images: Array = [images[0], images[1], topology_overlay]
	var keys := ["topographie_map", "topographie_map_grey", "topology_map"]
	# On watery worlds eaux_map.png is exported later from authoritative
	# water_colored. Avoid compressing/writing the provisional mask only to
	# overwrite it a few stages later (and avoid two async jobs targeting one path).
	if int(params.get("planet_type", 0)) in [3, 5]:
		paths.append(output_dir.path_join("eaux_map.png"))
		output_images.append(images[2])
		keys.append("eaux_map")
	for i in range(output_images.size()):
		var err := _save_png(output_images[i], paths[i])
		if err == OK:
			result[keys[i]] = paths[i]
		else:
			push_error("[Exporter] ❌ Failed to queue %s: %d" % [paths[i], err])
	return result


func _build_topography_cpu_fallback(geo_values: PackedFloat32Array, width: int,
		height: int, sea_level: float) -> Array:
	var pixel_count := width * height
	var colored := PackedByteArray()
	var grey := PackedByteArray()
	var water := PackedByteArray()
	colored.resize(pixel_count * 4)
	grey.resize(pixel_count * 4)
	water.resize(pixel_count * 4)
	var has_water := int(params.get("planet_type", 0)) not in [3, 5]
	for pixel_index in range(pixel_count):
		var base := pixel_index * 4
		var elevation_int := roundi(geo_values[base] - sea_level)
		var color: Color = Enum.getElevationColor(elevation_int, false)
		var grey_color: Color = Enum.getElevationColor(elevation_int, true)
		colored[base] = clampi(roundi(color.r * 255.0), 0, 255)
		colored[base + 1] = clampi(roundi(color.g * 255.0), 0, 255)
		colored[base + 2] = clampi(roundi(color.b * 255.0), 0, 255)
		colored[base + 3] = 255
		grey[base] = clampi(roundi(grey_color.r * 255.0), 0, 255)
		grey[base + 1] = clampi(roundi(grey_color.g * 255.0), 0, 255)
		grey[base + 2] = clampi(roundi(grey_color.b * 255.0), 0, 255)
		grey[base + 3] = 255
		if has_water and geo_values[base + 3] > 0.0:
			water[base] = 51
			water[base + 1] = 102
			water[base + 2] = 204
			water[base + 3] = 255
	return [
		Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, colored),
		Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, grey),
		Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, water),
	]


## Produit des isolignes antialiasables par le moteur (alpha variable), sans
## aplat de fond. Le lissage est exprimé en kilomètres afin que leur niveau de
## détail ne change pas simplement parce que la résolution d'export augmente.
func _build_topology_overlay(relative_elevations: PackedFloat32Array,
		width: int, height: int) -> Image:
	var planet_radius_km := maxf(float(params.get("planet_radius", 150.0)), 1.0)
	var km_per_pixel := TAU * planet_radius_km / float(maxi(width, 1))
	var smoothing_km := maxf(float(params.get("topology_smoothing_km", 12.0)), 0.0)
	var smoothing_radius_px := clampi(
		int(round(smoothing_km / maxf(km_per_pixel, 0.001))), 1, 64
	)
	var elevations := _smooth_topology_elevations(
		relative_elevations, width, height, smoothing_radius_px
	)
	var minor_interval := maxf(
		float(params.get("topology_contour_interval_m", 250.0)), 25.0
	)
	var major_interval := maxf(
		float(params.get("topology_major_interval_m", 1000.0)), minor_interval
	)
	var pixels := PackedByteArray()
	pixels.resize(width * height * 4)

	for y in range(height):
		var below_y := mini(y + 1, height - 1)
		for x in range(width):
			var index := y * width + x
			var center := elevations[index]
			var right := elevations[y * width + ((x + 1) % width)]
			var below := elevations[below_y * width + x]
			var line_kind := maxi(
				_contour_crossing_kind(center, right, minor_interval, major_interval),
				_contour_crossing_kind(center, below, minor_interval, major_interval)
			)
			if line_kind == 0:
				continue

			var offset := index * 4
			if line_kind == 3: # côte : trait continu le plus lisible
				pixels[offset] = 238
				pixels[offset + 1] = 246
				pixels[offset + 2] = 241
				pixels[offset + 3] = 255
			elif line_kind == 2: # courbe maîtresse
				pixels[offset] = 250
				pixels[offset + 1] = 247
				pixels[offset + 2] = 235
				pixels[offset + 3] = 224
			else: # courbe intermédiaire
				pixels[offset] = 250
				pixels[offset + 1] = 247
				pixels[offset + 2] = 235
				pixels[offset + 3] = 148

	return Image.create_from_data(
		width, height, false, Image.FORMAT_RGBA8, pixels
	)


func _contour_crossing_kind(a: float, b: float, minor_interval: float,
		major_interval: float) -> int:
	var a_is_land := a >= 0.0
	var b_is_land := b >= 0.0
	if a_is_land != b_is_land:
		return 3
	if int(floor(a / major_interval)) != int(floor(b / major_interval)):
		return 2
	if int(floor(a / minor_interval)) != int(floor(b / minor_interval)):
		return 1
	return 0


## Flou boîte séparable O(n), horizontalement raccordé et verticalement
## borné. Il retire le bruit pixel par pixel sans effacer les grands reliefs.
func _smooth_topology_elevations(source: PackedFloat32Array, width: int,
		height: int, radius: int) -> PackedFloat32Array:
	var horizontal := PackedFloat32Array()
	var smoothed := PackedFloat32Array()
	horizontal.resize(width * height)
	smoothed.resize(width * height)
	var window_size := radius * 2 + 1
	var inverse_window := 1.0 / float(window_size)

	for y in range(height):
		var row_offset := y * width
		var rolling_sum := 0.0
		for dx in range(-radius, radius + 1):
			rolling_sum += source[row_offset + posmod(dx, width)]
		for x in range(width):
			horizontal[row_offset + x] = rolling_sum * inverse_window
			rolling_sum -= source[row_offset + posmod(x - radius, width)]
			rolling_sum += source[row_offset + posmod(x + radius + 1, width)]

	for x in range(width):
		var rolling_sum := 0.0
		for dy in range(-radius, radius + 1):
			rolling_sum += horizontal[clampi(dy, 0, height - 1) * width + x]
		for y in range(height):
			smoothed[y * width + x] = rolling_sum * inverse_window
			rolling_sum -= horizontal[
				clampi(y - radius, 0, height - 1) * width + x
			]
			rolling_sum += horizontal[
				clampi(y + radius + 1, 0, height - 1) * width + x
			]

	return smoothed

## Exporte la carte des plaques tectoniques avec couleurs distinctes par plaque
##
## La PlatesTexture contient :
## - R = plate_id (numéro de plaque 0-11)
## - G = velocity_x (composante X de la vélocité)
## - B = velocity_y (composante Y de la vélocité)
## - A = convergence_type (-1=divergence, 0=transformante, +1=convergence)
##
## @param plates_img: Image RGBAF provenant de la texture GPU "plates"
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _export_plates_map(plates_data: PackedByteArray, output_dir: String,
		width: int, height: int) -> Dictionary:
	print("[Exporter] 🌍 Exporting tectonic plates map (packed conversion)...")
	var result: Dictionary = {}
	var values := plates_data.to_float32_array()
	if values.size() < width * height * 4:
		return result
	var plate_colors = [
		Color(0.8, 0.2, 0.2), Color(0.2, 0.8, 0.2), Color(0.2, 0.2, 0.8),
		Color(0.8, 0.8, 0.2), Color(0.8, 0.2, 0.8), Color(0.2, 0.8, 0.8),
		Color(0.9, 0.5, 0.1), Color(0.5, 0.2, 0.7), Color(0.3, 0.6, 0.3),
		Color(0.6, 0.3, 0.3), Color(0.4, 0.4, 0.7), Color(0.7, 0.7, 0.4),
	]
	var path_plates := output_dir.path_join("plaques_map.png")
	var path_borders := output_dir.path_join("plaques_bordures_map.png")
	var want_borders := ExportCatalog.should_keep(
		"plaques_bordures_map", params, path_borders
	)
	var colored := PackedByteArray()
	colored.resize(width * height * 4)
	var borders := PackedByteArray()
	if want_borders:
		borders.resize(width * height * 4)
	for y in range(height):
		for x in range(width):
			var pixel_index := y * width + x
			var src := pixel_index * 4
			var plate_id := int(round(values[src]))
			var convergence_type := values[src + 3]
			var color: Color = plate_colors[posmod(plate_id, plate_colors.size())]
			if absf(convergence_type) > 0.5:
				color = color.darkened(0.2) if convergence_type > 0.0 else color.lightened(0.2)
			var dst := pixel_index * 4
			colored[dst] = clampi(roundi(color.r * 255.0), 0, 255)
			colored[dst + 1] = clampi(roundi(color.g * 255.0), 0, 255)
			colored[dst + 2] = clampi(roundi(color.b * 255.0), 0, 255)
			colored[dst + 3] = 255
			if not want_borders:
				continue
			var is_border := false
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := posmod(x + dx, width)
					var ny := clampi(y + dy, 0, height - 1)
					var neighbor_id := int(round(values[(ny * width + nx) * 4]))
					if neighbor_id != plate_id:
						is_border = true
						break
				if is_border:
					break
			if is_border:
				var border_color := Color(1.0, 0.5, 0.0, 1.0)
				if convergence_type > 0.5:
					border_color = Color(1.0, 0.0, 0.0, 1.0)
				elif convergence_type < -0.5:
					border_color = Color(0.0, 0.5, 1.0, 1.0)
				borders[dst] = clampi(roundi(border_color.r * 255.0), 0, 255)
				borders[dst + 1] = clampi(roundi(border_color.g * 255.0), 0, 255)
				borders[dst + 2] = clampi(roundi(border_color.b * 255.0), 0, 255)
				borders[dst + 3] = 255
	var plates_image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, colored)
	if _save_png(plates_image, path_plates) == OK:
		result["plaques_map"] = path_plates
	if want_borders:
		var border_image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, borders)
		if _save_png(border_image, path_borders) == OK:
			result["plaques_bordures_map"] = path_borders
	return result

func _export_climate_maps_without_clouds(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] Exporting climate maps without clouds (temp + precip)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	

	
	# Température et précipitation nulle, sans nuages ni banquise.
	var climate_textures = {
		"temperature_colored": "temperature_map.png",
		"precipitation_colored": "precipitation_map.png",
	}
	
	for tex_id in climate_textures.keys():
		if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
			print("  ⚠️ Texture '", tex_id, "' non disponible, skip")
			continue
		
		var data = _read_texture(gpu, tex_id)
		
		if data.size() == 0:
			push_error("[Exporter] ❌ Empty data for texture: ", tex_id)
			continue
		
		var tex_format = rd.texture_get_format(gpu.textures[tex_id])
		var width = tex_format.width
		var height = tex_format.height
		
		var expected_size = width * height * 4
		if data.size() != expected_size:
			push_error("[Exporter] ❌ Data size mismatch for ", tex_id, 
				": expected ", expected_size, ", got ", data.size())
			continue
		
		var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
		
		if not img:
			push_error("[Exporter] ❌ Failed to create image from ", tex_id)
			continue
		
		var filename = climate_textures[tex_id]
		var filepath = output_dir + "/" + filename
		var save_err = _save_png(img, filepath)
		
		if save_err == OK:
			result[tex_id] = filepath
			print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
		else:
			push_error("[Exporter] ❌ Failed to save ", filename, ": ", save_err)
	
	print("[Exporter] ✅ Cloudless climate export complete: ", result.size(), " maps")
	return result

# ============================================================================
# ÉTAPE 3 : EXPORT CLIMAT OPTIMISÉ (RGBA8 DIRECT)
# ============================================================================

## Exporte les cartes climatiques de l'étape 3 de manière optimisée.
##
## Les textures temperature_colored, precipitation_colored, clouds, ice_caps
## sont déjà en format RGBA8 dans le GPU, donc on peut les exporter directement
## sans conversion pixel par pixel (bypass du parcours individuel).
##
## Cette méthode est 10-100x plus rapide que le parcours pixel par pixel car :
## - Lecture directe depuis VRAM via rd.texture_get_data()
## - Création d'image via Image.create_from_data() (mémoire mappée)
## - Pas de boucle for x/y
##
## @param gpu: Instance GPUContext avec les textures climat
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemins des fichiers exportés
func _export_climate_maps_optimized(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🌡️ Exporting climate maps (optimized RGBA8 direct)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture

	
	# Liste des textures climat à exporter (RGBA8)
	var climate_textures = {
		"temperature_colored": "temperature_map.png",
		"precipitation_colored": "precipitation_map.png",
		"clouds": "clouds_map.png",
		"ice_caps": "ice_caps_map.png"
	}
	
	for tex_id in climate_textures.keys():
		if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
			print("  ⚠️ Texture '", tex_id, "' non disponible, skip")
			continue
		
		# Lecture directe des données RGBA8 depuis le GPU
		var data = _read_texture(gpu, tex_id)
		
		if data.size() == 0:
			push_error("[Exporter] ❌ Empty data for texture: ", tex_id)
			continue
		
		# Récupérer les dimensions depuis le format de texture
		var tex_format = rd.texture_get_format(gpu.textures[tex_id])
		var width = tex_format.width
		var height = tex_format.height
		
		# Vérifier la taille des données (RGBA8 = 4 bytes par pixel)
		var expected_size = width * height * 4
		if data.size() != expected_size:
			push_error("[Exporter] ❌ Data size mismatch for ", tex_id, 
				": expected ", expected_size, ", got ", data.size())
			continue
		
		# Créer l'image directement à partir des données (pas de boucle!)
		var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
		
		if not img:
			push_error("[Exporter] ❌ Failed to create image from ", tex_id)
			continue
		
		# Sauvegarder en PNG
		var filename = climate_textures[tex_id]
		var filepath = output_dir + "/" + filename
		var err = _save_png(img, filepath)
		
		if err == OK:
			result[tex_id] = filepath
			print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
		else:
			push_error("[Exporter] ❌ Failed to save ", filename, ": ", err)
	
	print("[Exporter] ✅ Climate export complete: ", result.size(), " maps")
	return result

# ============================================================================
# ÉTAPE 4 : EXPORT RÉGIONS (RGBA8 DIRECT)
# ============================================================================

## Exporte la carte des régions administratives de l'étape 4.
##
## La texture region_colored est déjà en format RGBA8 dans le GPU,
## donc export direct sans conversion pixel par pixel.
##
## @param gpu: Instance GPUContext avec la texture region_colored
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemin du fichier exporté
func _export_region_map(gpu: GPUContext, output_dir: String,
		_optimised_region_generation: bool = true) -> Dictionary:
	print("[Exporter] 🗺️ Exporting region map (GPU administrative LUT)...")
	var result: Dictionary = {}
	if not gpu.rd:
		return result
	var tex_id := "region_map"
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'region_map' non disponible, skip")
		return result
	var data := _read_texture(gpu, tex_id)
	var format := gpu.rd.texture_get_format(gpu.textures[tex_id])
	var width := format.width
	var height := format.height
	if data.size() != width * height * 4:
		push_error("[Exporter] ❌ Invalid region_map payload")
		return result

	var ids := data.to_int32_array()
	var region_first_seen: Dictionary = {}
	for pixel_index in range(ids.size()):
		var region_id := int(ids[pixel_index])
		if region_id < 0:
			continue
		if not region_first_seen.has(region_id):
			region_first_seen[region_id] = pixel_index
	var merge_map := HierarchyBuilder.compute_merge_map(data, width, height)
	print("    Found ", region_first_seen.size(), " unique regions")

	var ordering: Array = []
	for raw_id in region_first_seen.keys():
		var effective_id := int(merge_map.get(raw_id, raw_id))
		ordering.append([effective_id, int(region_first_seen[raw_id])])
	ordering.sort_custom(func(a, b): return int(a[1]) < int(b[1]))
	var ordered_ids: Array = []
	var seen_effective: Dictionary = {}
	for item in ordering:
		if not seen_effective.has(item[0]):
			seen_effective[item[0]] = true
			ordered_ids.append(item[0])
	var id_to_color := _assign_administrative_colors(ordered_ids)
	var raw_to_color: Dictionary = {}
	for raw_id in region_first_seen.keys():
		var effective_id := int(merge_map.get(raw_id, raw_id))
		if id_to_color.has(effective_id):
			raw_to_color[raw_id] = id_to_color[effective_id]

	var img := _render_id_color_map_gpu(gpu, tex_id, raw_to_color, width, height)
	if img == null:
		push_warning("[Exporter] ⚠️ GPU region colorization unavailable; using threaded fallback")
		var output_data := PackedByteArray()
		output_data.resize(width * height * 4)
		var rows_per_thread := ceili(float(height) / float(_nb_threads))
		var threads: Array[Thread] = []
		var no_region_rgba := PackedByteArray([0, 0, 0, 0])
		for t in range(_nb_threads):
			var start_y := t * rows_per_thread
			var end_y := mini(start_y + rows_per_thread, height)
			if start_y >= height:
				break
			var thread := Thread.new()
			thread.start(_color_region_rows_fast.bind(
				data, output_data, width, start_y, end_y,
				id_to_color, merge_map, no_region_rgba
			))
			threads.append(thread)
		for thread in threads:
			thread.wait_to_finish()
		img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output_data)
	var filepath := output_dir.path_join("departement_map.png")
	var err := _save_png(img, filepath)
	if err == OK:
		result["region_colored"] = filepath
	else:
		push_error("[Exporter] ❌ Failed to queue region map: %d" % err)
	return result

## Thread worker pour colorier les lignes de régions (version rapide avec buffer)
func _color_region_rows_fast(data: PackedByteArray, output_data: PackedByteArray, width: int, 
							start_y: int, end_y: int, id_to_color: Dictionary, 
							merge_map: Dictionary, no_region_rgba: PackedByteArray) -> void:
	for y in range(start_y, end_y):
		for x in range(width):
			var in_offset = (y * width + x) * 4
			var out_offset = (y * width + x) * 4
			var region_id = data.decode_u32(in_offset)
			
			var r: int
			var g: int
			var b: int
			var a: int = 255
			
			# 0xFFFFFFFF = non-assigné (eau ou pas de région)
			if region_id == 0xFFFFFFFF:
				r = no_region_rgba[0]
				g = no_region_rgba[1]
				b = no_region_rgba[2]
				a = no_region_rgba[3]
			else:
				# Appliquer la fusion si nécessaire
				var eff_id = region_id
				if merge_map.has(region_id):
					eff_id = merge_map[region_id]
				
				if id_to_color.has(eff_id):
					var color: Color = id_to_color[eff_id]
					r = roundi(color.r * 255.0)
					g = roundi(color.g * 255.0)
					b = roundi(color.b * 255.0)
					a = roundi(color.a * 255.0)
				else:
					r = no_region_rgba[0]
					g = no_region_rgba[1]
					b = no_region_rgba[2]
					a = no_region_rgba[3]
			
			# Écriture directe dans le buffer (pas de mutex nécessaire car zones disjointes)
			output_data[out_offset] = r
			output_data[out_offset + 1] = g
			output_data[out_offset + 2] = b
			output_data[out_offset + 3] = a

## Exporte ocean_region_colored (RGBA8) en PNG
## Identique à _export_region_map mais pour les régions océaniques
##
## @param gpu: Instance GPUContext avec la texture ocean_region_map
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemin du fichier exporté
func _export_ocean_region_map(gpu: GPUContext, output_dir: String,
		_optimised_region_generation: bool = true) -> Dictionary:
	print("[Exporter] 🌊 Exporting ocean region map (GPU administrative LUT)...")
	var result: Dictionary = {}
	if not gpu.rd:
		return result
	var tex_id := "ocean_region_map"
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'ocean_region_map' non disponible, skip")
		return result
	var data := _read_texture(gpu, tex_id)
	var format := gpu.rd.texture_get_format(gpu.textures[tex_id])
	var width := format.width
	var height := format.height
	if data.size() != width * height * 4:
		push_error("[Exporter] ❌ Invalid ocean_region_map payload")
		return result
	var ids := data.to_int32_array()
	var first_seen: Dictionary = {}
	for pixel_index in range(ids.size()):
		var region_id := int(ids[pixel_index])
		if region_id < 0:
			continue
		if not first_seen.has(region_id):
			first_seen[region_id] = pixel_index
	var merge_map := HierarchyBuilder.compute_merge_map(data, width, height)
	var ordering: Array = []
	for raw_id in first_seen.keys():
		ordering.append([int(merge_map.get(raw_id, raw_id)), int(first_seen[raw_id])])
	ordering.sort_custom(func(a, b): return int(a[1]) < int(b[1]))
	var ordered_ids: Array = []
	var seen_effective: Dictionary = {}
	for item in ordering:
		if not seen_effective.has(item[0]):
			seen_effective[item[0]] = true
			ordered_ids.append(item[0])
	var id_to_color := _assign_administrative_colors(ordered_ids)
	var raw_to_color: Dictionary = {}
	for raw_id in first_seen.keys():
		var effective_id := int(merge_map.get(raw_id, raw_id))
		if id_to_color.has(effective_id):
			raw_to_color[raw_id] = id_to_color[effective_id]

	var img := _render_id_color_map_gpu(gpu, tex_id, raw_to_color, width, height)
	if img == null:
		push_warning("[Exporter] ⚠️ GPU ocean-region colorization unavailable; using threaded fallback")
		var output_data := PackedByteArray()
		output_data.resize(width * height * 4)
		var rows_per_thread := ceili(float(height) / float(_nb_threads))
		var threads: Array[Thread] = []
		var no_region_rgba := PackedByteArray([0, 0, 0, 0])
		for t in range(_nb_threads):
			var start_y := t * rows_per_thread
			var end_y := mini(start_y + rows_per_thread, height)
			if start_y >= height:
				break
			var thread := Thread.new()
			thread.start(_color_region_rows_fast.bind(
				data, output_data, width, start_y, end_y,
				id_to_color, merge_map, no_region_rgba
			))
			threads.append(thread)
		for thread in threads:
			thread.wait_to_finish()
		img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output_data)
	var filepath := output_dir.path_join("departement_mer_map.png")
	var err := _save_png(img, filepath)
	if err == OK:
		result["ocean_region_colored"] = filepath
	else:
		push_error("[Exporter] ❌ Failed to queue ocean region map: %d" % err)
	return result

# ============================================================================
# ÉTAPE 4.1 : EXPORT BIOMES
# ============================================================================

## Export de la carte des biomes (GPU compute shader)
func _export_biome_map(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🌿 Exporting biome map (GPU compute shader)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture

	
	var tex_id = "biome_colored"
	var filename = "biome_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'biome_colored' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = _read_texture(gpu, tex_id)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for biome texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (RGBA8 = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for biome map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image directement à partir des données
	var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create biome image")
		return result
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = _save_png(img, filepath)
	
	if err == OK:
		result[tex_id] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
	else:
		push_error("[Exporter] ❌ Failed to save biome map: ", err)
	
	print("[Exporter] ✅ Biome export complete")
	return result

# ============================================================================
# ÉTAPE 5 : EXPORT RESSOURCES
# ============================================================================

## Noms des ressources (doit correspondre à l'ordre dans enum.gd RESSOURCES - 116 ressources)
const RESOURCE_NAMES = [
	# CAT 1: Ultra-abondants (6)
	"silicium", "aluminium", "fer", "calcium", "magnesium", "potassium",
	# CAT 2: Très communs (6)
	"titane", "phosphate", "manganese", "soufre", "charbon", "calcaire",
	# CAT 3: Communs (10)
	"baryum", "strontium", "zirconium", "vanadium", "chrome", "nickel", "zinc", "cuivre", "sel", "fluorine",
	# CAT 4: Modérément rares (7)
	"cobalt", "lithium", "niobium", "plomb", "bore", "thorium", "graphite",
	# CAT 5: Rares (9)
	"etain", "beryllium", "arsenic", "germanium", "uranium", "molybdene", "tungstene", "antimoine", "tantale",
	# CAT 6: Très rares (7)
	"argent", "cadmium", "mercure", "selenium", "indium", "bismuth", "tellure",
	# CAT 7: Extrêmement rares (8)
	"or", "platine", "palladium", "rhodium", "iridium", "osmium", "ruthenium", "rhenium",
	# CAT 8: Terres rares (16)
	"cerium", "lanthane", "neodyme", "yttrium", "praseodyme", "samarium", "gadolinium", "dysprosium", "erbium", "europium", "terbium", "holmium", "thulium", "ytterbium", "lutetium", "scandium",
	# CAT 9: Hydrocarbures (7)
	"gaz_naturel", "lignite", "anthracite", "tourbe", "schiste_bitumineux", "methane_hydrate",
	# CAT 10: Pierres précieuses (12)
	"diamant", "emeraude", "rubis", "saphir", "topaze", "amethyste", "opale", "turquoise", "grenat", "peridot", "jade", "lapis_lazuli",
	# CAT 11: Minéraux industriels (22)
	"quartz", "feldspath", "mica", "argile", "kaolin", "gypse", "talc", "bauxite", "marbre", "granit", "ardoise", "gres", "sable", "gravier", "basalte", "obsidienne", "pierre_ponce", "amiante", "vermiculite", "perlite", "bentonite", "zeolite",
	# CAT 12: Minéraux spéciaux (6)
	"hafnium", "gallium", "cesium", "rubidium", "helium", "terres_rares_melangees"
]

## Exporte les cartes de ressources et de pétrole.
##
## Crée un sous-dossier "ressource/" contenant :
## - petrole_map.png : Carte de pétrole (noir/transparent)
## - Une carte par ressource minérale avec la couleur définie dans enum.gd
##
## @param gpu: Instance GPUContext avec les textures ressources
## @param output_dir: Dossier de sortie principal
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _export_resources_maps(gpu: GPUContext, output_dir: String, width: int,
		height: int) -> Dictionary:
	print("[Exporter] ⛏️ Exporting resources maps (GPU streaming + parallel PNG)...")
	var result: Dictionary = {}
	if not gpu.rd:
		return result
	var resources_dir := output_dir.path_join("maps").path_join("resources")
	DirAccess.make_dir_recursive_absolute(resources_dir)

	# Do not materialize files that ExportCatalog will immediately delete. This is
	# especially important for the default/standard preset, where the old path
	# compressed 116 resource PNGs and then discarded every one of them.
	var wanted: Dictionary = {}
	var petrole_path := resources_dir.path_join("petrole_map.png")
	if ExportCatalog.should_keep("petrole_map", params, petrole_path):
		wanted["petrole_map.png"] = true
	for name in RESOURCE_NAMES:
		var filename : String = name + "_map.png"
		var key : String = name + "_map"
		var path := resources_dir.path_join(filename)
		if ExportCatalog.should_keep(key, params, path):
			wanted[filename] = true
	_prune_unrequested_resource_pngs(resources_dir, wanted)
	if wanted.is_empty():
		print("  • Resource PNGs filtered by export preset; generation skipped")
		return result

	if wanted.has("petrole_map.png") and gpu.textures.has("petrole") and gpu.textures["petrole"].is_valid():
		var petrole_data := _read_texture(gpu, "petrole")
		if petrole_data.size() == width * height * 4:
			var petrole_img := Image.create_from_data(
				width, height, false, Image.FORMAT_RGBA8, petrole_data
			)
			if _save_png(petrole_img, petrole_path) == OK:
				result["petrole_map"] = petrole_path
	if _cancel_requested():
		return result

	if not gpu.textures.has("resources") or not gpu.textures["resources"].is_valid():
		print("  ⚠️ Resources texture not available, skipping")
		return result

	var renderer := _create_resource_export_renderer(gpu, width, height)
	if renderer.is_empty():
		push_warning("[Exporter] ⚠️ GPU resource renderer unavailable; using CPU fallback")
		return _export_resources_cpu_fallback(gpu, resources_dir, width, height, result, wanted)

	var resource_colors: Array[Color] = []
	for resource in Enum.RESSOURCES:
		resource_colors.append(resource.couleur)
	for i in range(RESOURCE_NAMES.size()):
		if _cancel_requested():
			break
		var filename : String = RESOURCE_NAMES[i] + "_map.png"
		if not wanted.has(filename):
			continue
		var base_color := resource_colors[i] if i < resource_colors.size() else Color.WHITE
		var resource_image := _render_resource_map_gpu(
			gpu, renderer, i, base_color, width, height
		)
		if resource_image == null:
			push_error("[Exporter] ❌ GPU resource render failed at resource %d" % i)
			continue
		var res_path := resources_dir.path_join(filename)
		if _save_png(resource_image, res_path) == OK:
			result[RESOURCE_NAMES[i] + "_map"] = res_path
	_destroy_resource_export_renderer(gpu, renderer)
	print("[Exporter] ✅ Resources queued: ", result.size(), " maps")
	return result


func _prune_unrequested_resource_pngs(resources_dir: String, wanted: Dictionary) -> void:
	var dir := DirAccess.open(resources_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if (
			not dir.current_is_dir()
			and entry.get_extension().to_lower() == "png"
			and not wanted.has(entry)
		):
			var path := resources_dir.path_join(entry)
			FileChecksumCache.invalidate(path)
			DirAccess.remove_absolute(path)
		entry = dir.get_next()
	dir.list_dir_end()


func _export_resources_cpu_fallback(gpu: GPUContext, resources_dir: String,
		width: int, height: int, initial_result: Dictionary, wanted: Dictionary) -> Dictionary:
	var result := initial_result
	var res_data := _read_texture(gpu, "resources")
	if res_data.size() != width * height * 4:
		return result
	var resource_count := RESOURCE_NAMES.size()
	var counts := PackedInt32Array()
	counts.resize(resource_count)
	for pixel_index in range(width * height):
		var source_offset := pixel_index * 4
		var resource_id := int(res_data[source_offset])
		if res_data[source_offset + 3] > 0 and resource_id < resource_count:
			counts[resource_id] += 1
	var offsets := PackedInt32Array()
	offsets.resize(resource_count + 1)
	for i in range(resource_count):
		offsets[i + 1] = offsets[i] + counts[i]
	var cursors := offsets.duplicate()
	var resource_indices := PackedInt32Array()
	resource_indices.resize(offsets[resource_count])
	for pixel_index in range(width * height):
		var source_offset := pixel_index * 4
		var resource_id := int(res_data[source_offset])
		if res_data[source_offset + 3] == 0 or resource_id >= resource_count:
			continue
		resource_indices[cursors[resource_id]] = pixel_index
		cursors[resource_id] += 1
	var resource_colors: Array[Color] = []
	for resource in Enum.RESSOURCES:
		resource_colors.append(resource.couleur)
	for i in range(RESOURCE_NAMES.size()):
		if _cancel_requested():
			break
		var filename : String = RESOURCE_NAMES[i] + "_map.png"
		if not wanted.has(filename):
			continue
		var output := PackedByteArray()
		output.resize(width * height * 4)
		output.fill(0)
		var base_color := resource_colors[i] if i < resource_colors.size() else Color.WHITE
		for index_position in range(offsets[i], offsets[i + 1]):
			var pixel_index := resource_indices[index_position]
			var source_offset := pixel_index * 4
			var intensity := int(res_data[source_offset + 1])
			output[source_offset] = int((clampi(roundi(base_color.r * 255.0), 0, 255) * intensity + 127) / 255)
			output[source_offset + 1] = int((clampi(roundi(base_color.g * 255.0), 0, 255) * intensity + 127) / 255)
			output[source_offset + 2] = int((clampi(roundi(base_color.b * 255.0), 0, 255) * intensity + 127) / 255)
			output[source_offset + 3] = res_data[source_offset + 3]
		var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output)
		var path := resources_dir.path_join(RESOURCE_NAMES[i] + "_map.png")
		if _save_png(image, path) == OK:
			result[RESOURCE_NAMES[i] + "_map"] = path
	return result

# ============================================================================
# ÉTAPE 2.5 : EXPORT CLASSIFICATION DES EAUX (CPU FLOOD-FILL)
# ============================================================================

## Exporte les cartes de classification des eaux via CPU flood-fill.
##
## Algorithme :
## 1. Lit la texture geo pour identifier les pixels sous le niveau de la mer
## 2. Colore TOUS les pixels eau en couleur "eau salée" initialement
## 3. Flood-fill pour identifier les composantes connexes
## 4. Si une composante a moins de freshwater_max_size pixels -> eau douce
##
## @param gpu: Instance GPUContext avec les textures
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _export_water_classification(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 💧 Exporting water classification map (GPU direct)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU

	
	# Vérifier que water_colored existe (généré par hydrology_water_color.glsl)
	if not gpu.textures.has("water_colored") or not gpu.textures["water_colored"].is_valid():
		push_error("[Exporter] ❌ water_colored texture not available - run water phase first")
		return result
	
	# Lire directement la texture water_colored (RGBA8) déjà calculée par le GPU
	var water_data = _read_texture(gpu, "water_colored")
	if water_data.size() == 0:
		push_error("[Exporter] ❌ water_colored texture data is empty")
		return result
	
	# Créer l'image directement depuis les données GPU
	var water_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, water_data)
	
	# Sauvegarder
	var path_water = output_dir + "/eaux_map.png"
	var err = _save_png(water_img, path_water)
	if err == OK:
		result["eaux_map"] = path_water
		print("  ✅ Saved: ", path_water, " (GPU direct - water_colored)")
	else:
		push_error("[Exporter] ❌ Failed to save eaux_map: ", err)
	
	print("[Exporter] ✅ Water classification export complete")
	return result

# ============================================================================
# ÉTAPE 2.6 : EXPORT RIVER MAP (CPU)
# ============================================================================

## Exporte la carte des rivières en CPU.
##
## Algorithme :
## 1. Lit la texture river_flux pour identifier les pixels de rivière
## 2. Pour chaque pixel rivière (flux > threshold), assigne le biome rivière correspondant
## 3. Les biomes rivière sont choisis selon le type d'atmosphère
##
## @param gpu: Instance GPUContext avec les textures
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _river_display_flux_threshold() -> float:
	return maxf(float(params.get(
		"river_map_min_flux",
		params.get(
			"river_riviere_threshold",
			params.get("river_affluent_threshold", 0.0)
		)
	)), 0.0)


func _export_river_map(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🌊 Exporting river map (packed GPU data)...")
	var result: Dictionary = {}
	if not gpu.rd:
		return result
	var atmosphere_type := int(params.get("planet_type", 0))
	var river_biomes_list: Array = Enum.get_river_biomes_for_gpu(atmosphere_type)
	if river_biomes_list.is_empty():
		return result
	if not gpu.textures.has("river_biome_id") or not gpu.textures["river_biome_id"].is_valid():
		return result
	var biome_id_data := _read_texture(gpu, "river_biome_id")
	var biome_ids := biome_id_data.to_int32_array()
	if biome_ids.size() < width * height:
		return result
	var flux_values := PackedFloat32Array()
	if gpu.textures.has("river_flux") and gpu.textures["river_flux"].is_valid():
		var flux_data := _read_texture(gpu, "river_flux")
		if flux_data.size() >= width * height * 4:
			flux_values = flux_data.to_float32_array()
	var has_flux_data := flux_values.size() >= width * height
	var display_flux_threshold := _river_display_flux_threshold()
	var water_mask_data := PackedByteArray()
	if gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid():
		water_mask_data = _read_texture(gpu, "water_mask")
	var has_water_mask := water_mask_data.size() >= width * height

	var biome_rgba: Array[PackedByteArray] = []
	var biome_names: Array[String] = []
	for rb in river_biomes_list:
		var color: Color = rb.get_couleur()
		biome_rgba.append(PackedByteArray([
			clampi(roundi(color.r * 255.0), 0, 255),
			clampi(roundi(color.g * 255.0), 0, 255),
			clampi(roundi(color.b * 255.0), 0, 255),
			clampi(roundi(color.a * 255.0), 0, 255),
		]))
		biome_names.append(str(rb.get_nom()))
	var pixels := PackedByteArray()
	pixels.resize(width * height * 4)
	var river_pixel_count := 0
	var skipped_no_biome := 0
	var skipped_low_flux := 0
	var biome_counts: Dictionary = {}
	for pixel_index in range(width * height):
		var biome_idx := int(biome_ids[pixel_index])
		# Signed -1 is the byte-identical R32UI sentinel 0xFFFFFFFF.
		if biome_idx < 0:
			continue
		if has_water_mask and water_mask_data[pixel_index] > 0:
			continue
		if has_flux_data and flux_values[pixel_index] < display_flux_threshold:
			skipped_low_flux += 1
			continue
		if biome_idx >= biome_rgba.size():
			skipped_no_biome += 1
			continue
		var offset := pixel_index * 4
		var rgba: PackedByteArray = biome_rgba[biome_idx]
		pixels[offset] = rgba[0]
		pixels[offset + 1] = rgba[1]
		pixels[offset + 2] = rgba[2]
		pixels[offset + 3] = rgba[3]
		river_pixel_count += 1
		var biome_name := biome_names[biome_idx]
		biome_counts[biome_name] = int(biome_counts.get(biome_name, 0)) + 1
	print("  River pixels drawn: ", river_pixel_count)
	if skipped_no_biome > 0:
		print("  ⚠️ Skipped ", skipped_no_biome, " pixels with invalid biome index")
	if skipped_low_flux > 0:
		print("  Filtered ", skipped_low_flux, " minor tributary pixels below flux ", display_flux_threshold)
	for biome_name in biome_counts.keys():
		print("    - ", biome_name, ": ", biome_counts[biome_name])
	var river_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
	var path_river := output_dir.path_join("river_map.png")
	if _save_png(river_img, path_river) == OK:
		result["river_map"] = path_river
	return result

## Export de la carte des types de rivières avec couleurs fixes
## Affluent = cyan clair, Rivière = bleu, Fleuve = bleu foncé
func _export_river_type_map(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🗺️ Exporting river type map (packed conversion)...")
	var result: Dictionary = {}
	if not gpu.rd:
		return result
	if not gpu.textures.has("ocean_reachable") or not gpu.textures["ocean_reachable"].is_valid():
		return result
	var atmosphere_type := int(params.get("planet_type", 0))
	var river_biomes_list: Array = Enum.get_river_biomes_for_gpu(atmosphere_type)
	var river_type_data := _read_texture(gpu, "ocean_reachable")
	if river_type_data.size() < width * height:
		return result
	var biome_ids := PackedInt32Array()
	if gpu.textures.has("river_biome_id") and gpu.textures["river_biome_id"].is_valid():
		var biome_data := _read_texture(gpu, "river_biome_id")
		if biome_data.size() >= width * height * 4:
			biome_ids = biome_data.to_int32_array()
	var has_biome_id := biome_ids.size() >= width * height
	var water_mask_data := PackedByteArray()
	if gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid():
		water_mask_data = _read_texture(gpu, "water_mask")
	var has_water_mask := water_mask_data.size() >= width * height
	var flux_values := PackedFloat32Array()
	if gpu.textures.has("river_flux") and gpu.textures["river_flux"].is_valid():
		var flux_data := _read_texture(gpu, "river_flux")
		if flux_data.size() >= width * height * 4:
			flux_values = flux_data.to_float32_array()
	var has_flux_data := flux_values.size() >= width * height
	var display_flux_threshold := _river_display_flux_threshold()
	var color_bytes := [
		PackedByteArray([102, 191, 255, 255]),
		PackedByteArray([26, 89, 217, 255]),
		PackedByteArray([38, 13, 140, 255]),
	]
	var pixels := PackedByteArray()
	pixels.resize(width * height * 4)
	var counts := PackedInt32Array([0, 0, 0])
	for pixel_index in range(width * height):
		var rtype := int(river_type_data[pixel_index])
		if rtype == 255:
			continue
		if has_water_mask and water_mask_data[pixel_index] > 0:
			continue
		if has_biome_id:
			var biome_idx := int(biome_ids[pixel_index])
			if biome_idx < 0 or biome_idx >= river_biomes_list.size():
				continue
		if has_flux_data and flux_values[pixel_index] < display_flux_threshold:
			continue
		var type_index := 2 if rtype == 2 else (1 if rtype == 1 else 0)
		var rgba: PackedByteArray = color_bytes[type_index]
		var offset := pixel_index * 4
		pixels[offset] = rgba[0]
		pixels[offset + 1] = rgba[1]
		pixels[offset + 2] = rgba[2]
		pixels[offset + 3] = rgba[3]
		counts[type_index] += 1
	print("  River type counts:")
	print("    - Affluent (cyan):  ", counts[0])
	print("    - Rivière (bleu):   ", counts[1])
	print("    - Fleuve (foncé):   ", counts[2])
	print("    - Total:            ", counts[0] + counts[1] + counts[2])
	var type_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
	var path_type := output_dir.path_join("river_type_map.png")
	if _save_png(type_img, path_type) == OK:
		result["river_type_map"] = path_type
	return result

# ============================================================================
# ÉTAPE 6 : EXPORT FINAL MAP
# ============================================================================

## Export de la carte finale combinée (GPU compute shader)
##
## La texture final_map contient la combinaison :
## - Biome (couleur de base végétation)
## - Rivières (fluide propre au type de monde si flux > seuil)
## - Relief topographique (ombrage hillshade)
## - Givre/neige terrestres climatiques et banquise maritime prioritaire
##
## L'assombrissement de l'eau est appliqué par export_final_map.glsl sur une
## texture temporaire : la texture de simulation final_map reste inchangée.
##
## @param gpu: Instance GPUContext avec la texture final_map
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemin du fichier exporté
func _export_cartographic_map(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🧭 Exporting Milestone 6 cartographic map...")
	# geo + water are authoritative requirements. biome_id enriches the style but
	# is deliberately optional so a future lifecycle change cannot make the whole
	# cartographic export disappear without an explanation.
	for texture_name in ["geo", "water_mask"]:
		if not gpu.textures.has(texture_name) or not gpu.textures[texture_name].is_valid():
			push_warning("[Exporter] ⚠️ cartographic_map.png skipped: missing texture '%s'" % texture_name)
			return {}
	var format = gpu.rd.texture_get_format(gpu.textures["geo"])
	var dimensions := Vector2i(format.width, format.height)
	var pixel_count := dimensions.x * dimensions.y
	var geo_data := _read_texture(gpu, "geo")
	var water_data := _read_texture(gpu, "water_mask")
	var biome_data := PackedByteArray()
	if gpu.textures.has("biome_id") and gpu.textures["biome_id"].is_valid():
		biome_data = _read_texture(gpu, "biome_id")
	else:
		push_warning("[Exporter] ⚠️ biome_id unavailable: cartographic map will render without biome modulation")
	if geo_data.size() != pixel_count * 16:
		push_warning("[Exporter] ⚠️ cartographic_map.png skipped: invalid geo payload (%d/%d bytes)" % [geo_data.size(), pixel_count * 16])
		return {}
	if water_data.size() != pixel_count:
		push_warning("[Exporter] ⚠️ cartographic_map.png skipped: invalid water payload (%d/%d bytes)" % [water_data.size(), pixel_count])
		return {}
	var palette_path := str(params.get("cartography_palette_path", CartographicPalette.DEFAULT_PATH))
	var palette := CartographicPalette.load_palette(palette_path)
	var rendered := CartographicRenderer.render_full_map(
		geo_data, water_data, biome_data, dimensions,
		float(params.get("planet_radius", 150.0)),
		float(params.get("sea_level", 0.0)), palette, {
			"view": str(params.get("cartography_view", CartographicRenderer.VIEW_PLANET)),
			"markers": params.get("cartography_markers", []),
		}
	)
	geo_data = PackedByteArray()
	water_data = PackedByteArray()
	biome_data = PackedByteArray()
	if rendered.is_empty():
		return {}
	var image: Image = rendered["image"]
	var path := output_dir.path_join("cartographic_map.png")
	var save_error := _save_png(image, path)
	if save_error != OK:
		push_error("[Exporter] ❌ Failed to save cartographic_map.png: %s" % save_error)
		return {}
	print("  ✅ Saved: ", path, " (", dimensions.x, "x", dimensions.y, ", palette=", palette.name, ")")
	return {"cartographic": path}


func _export_grid_overlay(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] # Exporting cartographic grid overlay...")
	if not gpu.textures.has("geo") or not gpu.textures["geo"].is_valid():
		push_warning("[Exporter] ⚠️ grid_overlay.png skipped: missing texture 'geo'")
		return {}
	var format = gpu.rd.texture_get_format(gpu.textures["geo"])
	var dimensions := Vector2i(format.width, format.height)
	var palette_path := str(params.get("cartography_palette_path", CartographicPalette.DEFAULT_PATH))
	var palette := CartographicPalette.load_palette(palette_path)
	var rendered := CartographicRenderer.render_grid_overlay(dimensions, palette, {
		"view": str(params.get("cartography_view", CartographicRenderer.VIEW_PLANET)),
		"alpha": int(params.get("cartography_grid_alpha", 166)),
	})
	if rendered.is_empty():
		return {}
	var image: Image = rendered["image"]
	var path := output_dir.path_join("grid_overlay.png")
	var save_error := _save_png(image, path)
	if save_error != OK:
		push_error("[Exporter] ❌ Failed to save grid_overlay.png: %s" % save_error)
		return {}
	print("  ✅ Saved: ", path, " (", dimensions.x, "x", dimensions.y, ", alpha=", rendered.get("alpha", 166), ")")
	return {"grid_overlay": path}


func _final_map_darkening_factor() -> float:
	var planet_type := int(params.get("planet_type", 0))
	if planet_type == Enum.TYPE_TOXIC:
		return 0.92
	if planet_type == Enum.TYPE_VOLCANIC:
		return 0.93
	if planet_type == Enum.TYPE_DEAD:
		return 0.82
	return WATER_DARKENING_FACTOR


func _render_final_export_gpu(gpu: GPUContext, width: int, height: int,
		darkening_factor: float) -> Image:
	if (
		not gpu.pipelines.has("export_final_map")
		or not gpu.shaders.has("export_final_map")
		or not gpu.textures.has("final_map")
		or not gpu.textures.has("water_colored")
		or not gpu.textures.has("ice_caps")
		or not gpu.textures["final_map"].is_valid()
		or not gpu.textures["water_colored"].is_valid()
		or not gpu.textures["ice_caps"].is_valid()
	):
		return null
	var rd := gpu.rd
	var output := _create_export_rgba8_texture(gpu, width, height)
	if not output.is_valid():
		return null
	var texture_set := rd.uniform_set_create([
		gpu.create_texture_uniform(0, gpu.textures["final_map"]),
		gpu.create_texture_uniform(1, gpu.textures["water_colored"]),
		gpu.create_texture_uniform(2, gpu.textures["ice_caps"]),
		gpu.create_texture_uniform(3, output),
	], gpu.shaders["export_final_map"], 0)
	if not texture_set.is_valid():
		gpu.release_rid(output)
		return null
	var push := PackedByteArray()
	push.resize(16)
	push.encode_u32(0, width)
	push.encode_u32(4, height)
	push.encode_float(8, darkening_factor)
	push.encode_u32(12, 0)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["export_final_map"])
	rd.compute_list_bind_uniform_set(compute_list, texture_set, 0)
	rd.compute_list_set_push_constant(compute_list, push, push.size())
	rd.compute_list_dispatch(compute_list, ceili(width / 16.0), ceili(height / 16.0), 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	var data := _read_texture_rid(gpu, output, "final_export")
	gpu.release_rid(texture_set)
	gpu.release_rid(output)
	if data.size() != width * height * 4:
		return null
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)


func _build_final_export_cpu_fallback(gpu: GPUContext, width: int, height: int,
		darkening_factor: float) -> Image:
	var expected_size := width * height * 4
	var final_data := _read_texture(gpu, "final_map")
	if final_data.size() != expected_size:
		return null
	var output := final_data.duplicate()
	var water_data := PackedByteArray()
	if gpu.textures.has("water_colored") and gpu.textures["water_colored"].is_valid():
		water_data = _read_texture(gpu, "water_colored")
	var ice_data := PackedByteArray()
	if gpu.textures.has("ice_caps") and gpu.textures["ice_caps"].is_valid():
		ice_data = _read_texture(gpu, "ice_caps")
	var has_water := water_data.size() == expected_size
	var has_ice := ice_data.size() == expected_size
	var geo_values := PackedFloat32Array()
	if not has_water and gpu.textures.has("geo") and gpu.textures["geo"].is_valid():
		var geo_data := _read_texture(gpu, "geo")
		if geo_data.size() == width * height * 16:
			geo_values = geo_data.to_float32_array()
	var has_geo := geo_values.size() >= width * height * 4
	for pixel_index in range(width * height):
		var base := pixel_index * 4
		var is_water := (
			(has_water and water_data[base + 3] > 0)
			or (not has_water and has_geo and geo_values[pixel_index * 4] < 0.0)
		)
		var is_ice := has_ice and ice_data[base + 3] > 6
		if not is_water or is_ice:
			continue
		output[base] = clampi(roundi(float(output[base]) * darkening_factor), 0, 255)
		output[base + 1] = clampi(roundi(float(output[base + 1]) * darkening_factor), 0, 255)
		output[base + 2] = clampi(roundi(float(output[base + 2]) * darkening_factor), 0, 255)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output)


func _export_final_map(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🗺️ Exporting final map (GPU export post-process)...")
	var result: Dictionary = {}
	var rd := gpu.rd
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	if not gpu.textures.has("final_map") or not gpu.textures["final_map"].is_valid():
		print("  ⚠️ Texture 'final_map' non disponible, skip")
		return result
	var tex_format := rd.texture_get_format(gpu.textures["final_map"])
	var width: int = tex_format.width
	var height: int = tex_format.height
	var planet_type := int(params.get("planet_type", 0))
	var img: Image = null
	if planet_type == Enum.TYPE_GAZEUZE:
		var data := _read_texture(gpu, "final_map")
		if data.size() == width * height * 4:
			img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	else:
		var factor := _final_map_darkening_factor()
		img = _render_final_export_gpu(gpu, width, height, factor)
		if img == null:
			push_warning("[Exporter] ⚠️ GPU final-map post-process unavailable; using packed CPU fallback")
			img = _build_final_export_cpu_fallback(gpu, width, height, factor)
	if img == null:
		push_error("[Exporter] ❌ Failed to build final_map image")
		return result
	var filepath := output_dir.path_join("final_map.png")
	var err := _save_png(img, filepath)
	if err == OK:
		result["final_map"] = filepath
		print("  ✅ Queued: ", filepath, " (", width, "x", height, ")")
	else:
		push_error("[Exporter] ❌ Failed to queue final_map: %d" % err)
	return result

## ============================================================================
## EXPORT HIÉRARCHIE ADMINISTRATIVE (GPU RGBA8 direct readback)
## ============================================================================
## Exporte les 6 niveaux hiérarchiques (3 terre + 3 mer) depuis les textures
## RGBA8 déjà colorées par hierarchy_finalize.glsl

func _export_hierarchy_maps(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🏛️ Construction hiérarchie administrative (CPU)...")
	
	var result: Dictionary = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	

	
	# ─── Lecture des données R32UI ────────────────────────────────────────────
	var land_data := PackedByteArray()
	var sea_data := PackedByteArray()
	var water_mask_data := PackedByteArray()
	var width: int = 0
	var height: int = 0
	
	if gpu.textures.has("region_map") and gpu.textures["region_map"].is_valid():
		land_data = _read_texture(gpu, "region_map")
		var fmt = rd.texture_get_format(gpu.textures["region_map"])
		width = fmt.width
		height = fmt.height
	
	if width == 0 or land_data.is_empty():
		print("  ⚠️ Pas de données region_map, hiérarchie ignorée")
		return result
	
	if gpu.textures.has("ocean_region_map") and gpu.textures["ocean_region_map"].is_valid():
		sea_data = _read_texture(gpu, "ocean_region_map")
	if gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid():
		water_mask_data = _read_texture(gpu, "water_mask")
	# Compatibilite avec une generation deja terminee par l'ancienne phase
	# finale : celle-ci pouvait remplacer toutes les valeurs mer (1) par eau
	# douce (2). Restaurer uniquement les pixels aquatiques sous le niveau marin
	# depuis l'altitude brute permet de reexporter sans regenerer la planete.
	water_mask_data = _recover_missing_saltwater_mask(
		gpu, water_mask_data, width, height
	)
	
	# ─── Merge maps (wrap horizontal) ────────────────────────────────────────
	var merge_land := HierarchyBuilder.compute_merge_map(land_data, width, height)
	var merge_sea: Dictionary = {}
	if not sea_data.is_empty():
		merge_sea = HierarchyBuilder.compute_merge_map(sea_data, width, height)
	
	# ─── Construction des hiérarchies (BFS) ──────────────────────────────────
	print("  Hiérarchie terrestre :")
	var land := HierarchyBuilder.build_land(land_data, width, height, merge_land, params)
	# land = [dept→région, dept→pays, dept→continent]
	
	var sea: Array = [{}, {}, {}]
	if not sea_data.is_empty():
		print("  Hiérarchie maritime :")
		sea = HierarchyBuilder.build_sea(
			sea_data, width, height, merge_sea, params,
			land_data, merge_land, land, water_mask_data
		)
	# sea = [dept→région-mer, dept→bassin, dept→océan]
	
	# ─── Peinture et export ──────────────────────────────────────────────────
	# Les hiérarchies restent construites sur CPU (topologie/dictionnaires), mais
	# la peinture des millions de pixels passe par un LUT SSBO sur le GPU.
	var land_raw_ids := _unique_r32ui_ids(land_data)
	var sea_raw_ids: Array = []
	if not sea_data.is_empty():
		sea_raw_ids = _unique_r32ui_ids(sea_data)
	var exports: Array = [
		["region_map", land_data, land_raw_ids, merge_land, land[0], "region_map.png",    "Régions terrestres"],
		["region_map", land_data, land_raw_ids, merge_land, land[1], "pays_map.png",      "Pays"],
		["region_map", land_data, land_raw_ids, merge_land, land[2], "continent_map.png", "Continents"],
	]
	if not sea_data.is_empty():
		exports.append(["ocean_region_map", sea_data, sea_raw_ids, merge_sea, sea[0], "region_mer_map.png", "Régions maritimes"])
		exports.append(["ocean_region_map", sea_data, sea_raw_ids, merge_sea, sea[1], "bassin_map.png",     "Bassins"])
		exports.append(["ocean_region_map", sea_data, sea_raw_ids, merge_sea, sea[2], "ocean_map.png",      "Océans"])

	for entry in exports:
		var texture_name: String = entry[0]
		var data: PackedByteArray = entry[1]
		var raw_ids: Array = entry[2]
		var merge: Dictionary = entry[3]
		var d2g: Dictionary = entry[4]
		var filename: String = entry[5]
		var label: String = entry[6]
		if d2g.is_empty():
			print("  ⚠️ ", label, " — pas de données, ignoré")
			continue
		var group_ids := HierarchyBuilder._unique_values(d2g)
		var colors := _assign_administrative_colors(group_ids)
		var raw_to_color: Dictionary = {}
		for raw_id in raw_ids:
			var effective_id := int(merge.get(raw_id, raw_id))
			var group_id := int(d2g.get(effective_id, -1))
			if group_id != -1 and colors.has(group_id):
				raw_to_color[raw_id] = colors[group_id]

		var img := _render_id_color_map_gpu(
			gpu, texture_name, raw_to_color, width, height
		)
		if img == null:
			push_warning("[Exporter] ⚠️ GPU hierarchy colorization unavailable for %s; using threaded fallback" % label)
			var output := PackedByteArray()
			output.resize(width * height * 4)
			var rows_pt := ceili(float(height) / float(_nb_threads))
			var threads: Array[Thread] = []
			for t in range(_nb_threads):
				var sy := t * rows_pt
				var ey := mini(sy + rows_pt, height)
				if sy >= height:
					break
				var thread := Thread.new()
				thread.start(_paint_hierarchy_rows.bind(
					data, output, width, sy, ey, merge, d2g, colors
				))
				threads.append(thread)
			for thread in threads:
				thread.wait_to_finish()
			img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output)

		var filepath := output_dir.path_join(filename)
		var err := _save_png(img, filepath)
		if err == OK:
			result[label] = filepath
			print("  ✅ Queued: ", label, " → ", filename, " (", width, "×", height, ")")
		else:
			push_error("[Exporter] ❌ Échec file PNG %s : %d" % [filename, err])

	print("[Exporter] ✅ Hiérarchie exportée (", result.size(), " cartes)")
	return result


func _recover_missing_saltwater_mask(gpu: GPUContext,
		water_mask_data: PackedByteArray, width: int, height: int) -> PackedByteArray:
	if water_mask_data.size() != width * height or water_mask_data.is_empty():
		return water_mask_data
	var water_pixels := 0
	var saltwater_pixels := 0
	for value in water_mask_data:
		if value > 0:
			water_pixels += 1
		if value == 1:
			saltwater_pixels += 1
	if water_pixels == 0 or saltwater_pixels > 0:
		return water_mask_data
	if not gpu.textures.has("geo") or not gpu.textures["geo"].is_valid():
		return water_mask_data
	var geo_data: PackedByteArray = _read_texture(gpu, "geo")
	if geo_data.size() != width * height * 16:
		return water_mask_data
	var sea_level := float(params.get("sea_level", 0.0))
	var saltwater_min_size := maxi(int(params.get("saltwater_min_size", 1000)), 1)
	var recovered := water_mask_data.duplicate()
	var visited := PackedByteArray()
	visited.resize(width * height)
	visited.fill(0)
	var recovered_saltwater := 0
	for start in range(width * height):
		if recovered[start] == 0 or visited[start] != 0:
			continue
		var component := PackedInt32Array([start])
		visited[start] = 1
		var touches_subsea := geo_data.decode_float(start * 16) < sea_level
		var head := 0
		while head < component.size():
			var current := int(component[head])
			head += 1
			var x := current % width
			var y := current / width
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := posmod(x + dx, width)
					var ny := clampi(y + dy, 0, height - 1)
					var neighbor := ny * width + nx
					if recovered[neighbor] == 0 or visited[neighbor] != 0:
						continue
					visited[neighbor] = 1
					component.append(neighbor)
					touches_subsea = touches_subsea or (
						geo_data.decode_float(neighbor * 16) < sea_level
					)
		var component_is_saltwater := (
			touches_subsea and component.size() >= saltwater_min_size
		)
		var recovered_type := 1 if component_is_saltwater else 2
		for index in component:
			recovered[index] = recovered_type
		if component_is_saltwater:
			recovered_saltwater += component.size()
	if recovered_saltwater > 0:
		print("  ⚠️ Masque marin restauré pour l'export : ", recovered_saltwater,
			" pixels salés récupérés")
		return recovered
	return water_mask_data

## Thread worker : peint les lignes d'une carte hiérarchique depuis les données R32UI.
func _paint_hierarchy_rows(data: PackedByteArray, output: PackedByteArray,
		width: int, start_y: int, end_y: int,
		merge: Dictionary, d2g: Dictionary, colors: Dictionary) -> void:
	for y in range(start_y, end_y):
		for x in range(width):
			var off := (y * width + x) * 4
			var raw: int = data.decode_u32(off)
			if raw == 0xFFFFFFFF:
				output[off] = 0
				output[off + 1] = 0
				output[off + 2] = 0
				output[off + 3] = 0
				continue
			var eff: int = merge.get(raw, raw)
			var gid: int = d2g.get(eff, -1)
			if gid == -1:
				output[off] = 0
				output[off + 1] = 0
				output[off + 2] = 0
				output[off + 3] = 0
				continue
			var c: Color = colors.get(gid, Color.TRANSPARENT)
			output[off]     = roundi(c.r * 255.0)
			output[off + 1] = roundi(c.g * 255.0)
			output[off + 2] = roundi(c.b * 255.0)
			output[off + 3] = roundi(c.a * 255.0)
