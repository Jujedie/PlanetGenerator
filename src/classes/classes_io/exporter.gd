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

# Water colors by atmosphere type
static var WATER_COLORS = {
	# Type 0 (Default) - Bleu
	0: {
		"saltwater": Color.hex(0x25528aFF),  # Océan
		"freshwater": Color.hex(0x4584d2FF)  # Lac
	},
	# Type 1 (Toxic) - saumures acides jaune-olive
	1: {
		"saltwater": Color.hex(0x536927FF),
		"freshwater": Color.hex(0x8b9d2cFF)
	},
	# Type 2 (Volcanic) - Lave
	2: {
		"saltwater": Color.hex(0x87260aFF),
		"freshwater": Color.hex(0xe84c0cFF)
	},
	# Type 4 (Dead) - eau sombre et lacs boueux
	4: {
		"saltwater": Color.hex(0x313d38FF),
		"freshwater": Color.hex(0x655b34FF)
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
	_admin_color_cursor = 0
	last_metrics = {
		"worker_count": _nb_threads,
		"worker_policy": "automatic" if int(params.get("export_worker_count", 0)) <= 0 else "explicit_export_only",
		"readback_time_ms": 0.0,
		"readback_bytes": 0,
		"readback_count": 0,
		"png_compression_ms": 0.0,
		"peak_cpu_map_bytes": 0,
		"peak_simultaneous_rgba32f_maps": 0,
		"rgba32f_map_readbacks": 0,
		"peak_system_ram_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
	}
	if _abort_export_if_cancelled(export_started_usec):
		return {}
	
	print("[Exporter] Starting map export to: ", output_dir,
		" (PNG workers=", _nb_threads, ", policy=", last_metrics["worker_policy"], ")")
	
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
		var final_result = _export_final_map(gpu, output_dir)
		for key in final_result.keys():
			exported_files[key] = final_result[key]
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
	
	# Stream each wide map through readback -> conversion -> PNG, then drop it.
	var geo_data := _read_texture(gpu, "geo")
	if geo_data.size() != expected_size:
		push_error("[Exporter] ❌ Geo data size mismatch: expected ", expected_size,
			", got ", geo_data.size())
		return {}
	var geo_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, geo_data)
	var topo_result = _export_topographie_maps(geo_img, output_dir, width, height)
	for key in topo_result.keys():
		exported_files[key] = topo_result[key]
	geo_img = null
	geo_data = PackedByteArray()
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	var plates_data := _read_texture(gpu, "plates")
	if plates_data.size() != expected_size:
		push_error("[Exporter] ❌ Plates data size mismatch: expected ", expected_size,
			", got ", plates_data.size())
		return {}
	var plates_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, plates_data)
	var plates_result = _export_plates_map(plates_img, output_dir, width, height)
	for key in plates_result.keys():
		exported_files[key] = plates_result[key]
	plates_img = null
	plates_data = PackedByteArray()
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT CLIMAT (Step 3) - Optimisé RGBA8 Direct ===
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
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT EAUX (Step 2.5) - Classification des masses d'eau ===
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
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT RÉGIONS (Step 4) - Régions administratives ===
	var region_result = _export_region_map(gpu, output_dir,params.get("region_generation_optimised",true))
	for key in region_result.keys():
		exported_files[key] = region_result[key]
	
	# === EXPORT RÉGIONS OCÉANIQUES (Step 4.5) ===
	# Pas de régions océaniques sans eau
	if planet_type not in [3, 5]:  # TYPE_NO_ATMOS, TYPE_STERILE
		var ocean_region_result = _export_ocean_region_map(gpu, output_dir,params.get("region_generation_optimised",true))
		for key in ocean_region_result.keys():
			exported_files[key] = ocean_region_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT BIOMES (Step 4.1) ===
	var biome_result = _export_biome_map(gpu, output_dir)
	for key in biome_result.keys():
		exported_files[key] = biome_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files

	# === CARTOGRAPHIE PALETTE-DRIVEN (Milestone 6) ===
	if bool(params.get("export_cartographic_map", true)):
		var cartography_result := _export_cartographic_map(gpu, output_dir)
		for key in cartography_result.keys():
			exported_files[key] = cartography_result[key]
	if bool(params.get("export_grid_overlay", true)):
		var grid_overlay_result := _export_grid_overlay(gpu, output_dir)
		for key in grid_overlay_result.keys():
			exported_files[key] = grid_overlay_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT FINAL MAP (Step 6) ===
	var final_result = _export_final_map(gpu, output_dir)
	for key in final_result.keys():
		exported_files[key] = final_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT HIÉRARCHIE ADMINISTRATIVE (Step 4.6) ===
	var hierarchy_result = _export_hierarchy_maps(gpu, output_dir)
	for key in hierarchy_result.keys():
		exported_files[key] = hierarchy_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	# === EXPORT RESSOURCES (Step 5) ===
	var resources_result = _export_resources_maps(gpu, output_dir, width, height)
	for key in resources_result.keys():
		exported_files[key] = resources_result[key]
	if _abort_export_if_cancelled(export_started_usec):
		return exported_files
	
	if bool(params.get("run_integrity_checks", true)):
		var integrity_report := PlanetIntegrityChecker.run(gpu, params, exported_files)
		var integrity_path := PlanetIntegrityChecker.save_report(output_dir, integrity_report)
		if not integrity_path.is_empty():
			exported_files["integrity_report"] = integrity_path

	# M7.2: filtering/layout happens only after integrity has inspected the full
	# generated set, and before manifests compute their final relative paths.
	exported_files = ExportCatalog.finalize_outputs(output_dir, exported_files, params)
	var manifest_path := PlanetManifest.save(output_dir, params, exported_files)
	if not manifest_path.is_empty():
		exported_files["manifest"] = manifest_path
	var project_path := PlanetProject.save(output_dir, params, exported_files)
	if not project_path.is_empty():
		exported_files["project"] = project_path

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

func _read_texture(gpu: GPUContext, texture_name: String) -> PackedByteArray:
	var started_usec := Time.get_ticks_usec()
	var data := gpu.readback_texture_raw(texture_name)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
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
			# Calls are intentionally sequential and the caller clears each wide
			# array before requesting the next one.
			last_metrics["peak_simultaneous_rgba32f_maps"] = 1
	_sample_export_ram()
	return data

func _save_png(image: Image, filepath: String) -> Error:
	var started_usec := Time.get_ticks_usec()
	# The same export directory may be reused across generations. Invalidate the
	# checksum cache before/after writing so second-resolution mtimes can never
	# make a rewritten same-size PNG look unchanged.
	FileChecksumCache.invalidate(filepath)
	var error := image.save_png(filepath)
	FileChecksumCache.invalidate(filepath)
	last_metrics["png_compression_ms"] = (
		float(last_metrics.get("png_compression_ms", 0.0))
		+ float(Time.get_ticks_usec() - started_usec) / 1000.0
	)
	_sample_export_ram()
	return error

func _sample_export_ram() -> void:
	last_metrics["peak_system_ram_bytes"] = maxi(
		int(last_metrics.get("peak_system_ram_bytes", 0)),
		int(Performance.get_monitor(Performance.MEMORY_STATIC))
	)

func _finalize_metrics(export_started_usec: int) -> void:
	var total_ms := float(Time.get_ticks_usec() - export_started_usec) / 1000.0
	last_metrics["total_export_ms"] = total_ms
	last_metrics["cpu_conversion_ms"] = maxf(
		total_ms
		- float(last_metrics.get("readback_time_ms", 0.0))
		- float(last_metrics.get("png_compression_ms", 0.0)),
		0.0
	)
	_sample_export_ram()

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
func _export_topographie_maps(geo_img: Image, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🏔️ Exporting topographic maps...")
	
	var result = {}
	
	# Créer les images de sortie (format RGBA8 pour PNG)
	var elevation_colored = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var elevation_grey = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var water_mask = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var relative_elevations := PackedFloat32Array()
	relative_elevations.resize(width * height)
	
	# Vérifier si la planète a de l'eau (pas d'eau sur planètes sans atmosphère ou stériles)
	var atmosphere_type = int(params.get("planet_type", 0))
	var has_water = atmosphere_type not in [3, 5]  # 3 = Sans atmosphère, 5 = Stérile
	
	# Parcourir chaque pixel et convertir l'élévation en couleur
	for y in range(height):
		for x in range(width):
			# Lire les données brutes de la GeoTexture
			var geo_pixel = geo_img.get_pixel(x, y)
			var elevation_meters = geo_pixel.r  # Élévation en mètres (float)
			var water_height = geo_pixel.a       # Colonne d'eau
			
			# CORRECTION: Utiliser l'altitude RELATIVE au niveau de l'eau
			# Les couleurs représentent maintenant la hauteur par rapport à l'eau
			var sea_level = params.get("sea_level", 0.0)
			var relative_elevation = elevation_meters - sea_level
			var elevation_int = int(round(relative_elevation))
			relative_elevations[y * width + x] = relative_elevation
			
			# Obtenir les couleurs via Enum.gd (altitude relative)
			var color_colored = Enum.getElevationColor(elevation_int, false)
			var color_grey = Enum.getElevationColor(elevation_int, true)
			
			# Écrire les pixels
			elevation_colored.set_pixel(x, y, color_colored)
			elevation_grey.set_pixel(x, y, color_grey)
			
			# Water mask : bleu si eau ET planète avec atmosphère, transparent sinon
			if has_water and water_height > 0.0:
				water_mask.set_pixel(x, y, Color(0.2, 0.4, 0.8, 1.0))
			else:
				water_mask.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
	
	# Sauvegarder les images avec noms standardisés
	var path_colored = output_dir + "/topographie_map.png"
	var path_grey = output_dir + "/topographie_map_grey.png"
	var path_topology = output_dir + "/topology_map.png"
	var path_water = output_dir + "/eaux_map.png"
	var topology_overlay := _build_topology_overlay(relative_elevations, width, height)
	
	var err_colored = _save_png(elevation_colored, path_colored)
	var err_grey = _save_png(elevation_grey, path_grey)
	var err_topology = _save_png(topology_overlay, path_topology)
	var err_water = _save_png(water_mask, path_water)
	
	if err_colored == OK:
		result["topographie_map"] = path_colored
		print("  ✅ Saved: ", path_colored)
	else:
		push_error("[Exporter] ❌ Failed to save topographie_map: ", err_colored)
	
	if err_grey == OK:
		result["topographie_map_grey"] = path_grey
		print("  ✅ Saved: ", path_grey)
	else:
		push_error("[Exporter] ❌ Failed to save topographie_map_grey: ", err_grey)

	if err_topology == OK:
		result["topology_map"] = path_topology
		print("  ✅ Saved: ", path_topology, " (RGBA transparent)")
	else:
		push_error("[Exporter] ❌ Failed to save topology_map: ", err_topology)
	
	if err_water == OK:
		result["eaux_map"] = path_water
		print("  ✅ Saved: ", path_water)
	else:
		push_error("[Exporter] ❌ Failed to save eaux_map: ", err_water)
	
	return result


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
func _export_plates_map(plates_img: Image, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🌍 Exporting tectonic plates map...")
	
	var result = {}
	
	# Palette de couleurs pour les 12 plaques tectoniques
	var plate_colors = [
		Color(0.8, 0.2, 0.2),  # Rouge
		Color(0.2, 0.8, 0.2),  # Vert
		Color(0.2, 0.2, 0.8),  # Bleu
		Color(0.8, 0.8, 0.2),  # Jaune
		Color(0.8, 0.2, 0.8),  # Magenta
		Color(0.2, 0.8, 0.8),  # Cyan
		Color(0.9, 0.5, 0.1),  # Orange
		Color(0.5, 0.2, 0.7),  # Violet
		Color(0.3, 0.6, 0.3),  # Vert foncé
		Color(0.6, 0.3, 0.3),  # Rouge foncé
		Color(0.4, 0.4, 0.7),  # Bleu clair
		Color(0.7, 0.7, 0.4),  # Kaki
	]
	
	# Créer les images de sortie
	var plates_colored = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var plates_borders = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var plate_pixel = plates_img.get_pixel(x, y)
			var plate_id = int(round(plate_pixel.r))
			var _velocity_x = plate_pixel.g  # Pour usage futur (flèches de direction)
			var _velocity_y = plate_pixel.b
			var convergence_type = plate_pixel.a  # -1, 0, ou +1
			
			# Couleur de la plaque
			var color = plate_colors[plate_id % plate_colors.size()]
			
			# Modifier la couleur selon le type de frontière
			# Convergence = plus saturé, Divergence = plus clair
			if abs(convergence_type) > 0.5:
				if convergence_type > 0:
					color = color.darkened(0.2)  # Convergence = plus foncé
				else:
					color = color.lightened(0.2)  # Divergence = plus clair
			
			plates_colored.set_pixel(x, y, color)
			
			# Carte des bordures : détecter les transitions de plate_id
			# Comparer avec les voisins pour trouver les bordures
			var is_border = false
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx = (x + dx + width) % width  # Wrap X
					var ny = clamp(y + dy, 0, height - 1)
					var neighbor = plates_img.get_pixel(nx, ny)
					var neighbor_id = int(round(neighbor.r))
					if neighbor_id != plate_id:
						is_border = true
						break
				if is_border:
					break
			
			if is_border:
				# Colorer selon le type de convergence
				var border_color = Color(1.0, 0.5, 0.0, 1.0)  # Orange par défaut
				if convergence_type > 0.5:
					border_color = Color(1.0, 0.0, 0.0, 1.0)  # Rouge = convergence
				elif convergence_type < -0.5:
					border_color = Color(0.0, 0.5, 1.0, 1.0)  # Bleu = divergence
				plates_borders.set_pixel(x, y, border_color)
			else:
				plates_borders.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
	
	# Sauvegarder
	var path_plates = output_dir + "/plaques_map.png"
	var path_borders = output_dir + "/plaques_bordures_map.png"
	
	var err_plates = _save_png(plates_colored, path_plates)
	var err_borders = _save_png(plates_borders, path_borders)
	
	if err_plates == OK:
		result["plaques_map"] = path_plates
		print("  ✅ Saved: ", path_plates)
	else:
		push_error("[Exporter] ❌ Failed to save plaques_map: ", err_plates)
	
	if err_borders == OK:
		result["plaques_bordures_map"] = path_borders
		print("  ✅ Saved: ", path_borders)
	else:
		push_error("[Exporter] ❌ Failed to save plaques_bordures_map: ", err_borders)
	
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
func _export_region_map(gpu: GPUContext, output_dir: String, _optimised_region_generation : bool = true) -> Dictionary:
	print("[Exporter] 🗺️ Exporting region map (CPU administrative coloration)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture

	
	var tex_id = "region_map"  # R32UI - IDs bruts
	var filename = "departement_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'region_map' non disponible, skip")
		return result
	
	# Lecture directe des données R32UI depuis le GPU
	var data = _read_texture(gpu, tex_id)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for region texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (R32UI = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for region map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image de sortie RGBA8
	var img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create region image")
		return result
	
	# =========================================================================
	# PHASE 1 : Collecter tous les IDs uniques et gérer le wrapping horizontal
	# =========================================================================
	print("  Phase 1: Collecting unique region IDs...")
	
	# Dictionnaire: region_id -> premier pixel où on l'a vu
	var region_first_seen: Dictionary = {}
	
	for y in range(height):
		for x in range(width):
			var offset = (y * width + x) * 4
			var region_id = data.decode_u32(offset)
			
			# 0xFFFFFFFF = non-assigné (eau ou terre sans région)
			if region_id == 0xFFFFFFFF:
				continue
			
			if not region_first_seen.has(region_id):
				region_first_seen[region_id] = Vector2i(x, y)

	# Deux IDs différents qui se touchent sur la couture sont voisins, pas une
	# seule région. Le JFA conserve déjà un même ID à travers le wrap.
	var merge_map := HierarchyBuilder.compute_merge_map(data, width, height)

	print("    Found ", region_first_seen.size(), " unique regions")
	
	# =========================================================================
	# PHASE 2 : Assigner les couleurs séquentiellement
	# =========================================================================
	print("  Phase 2: Assigning deterministic high-contrast colors...")
	
	var id_to_color: Dictionary = {}
	
	# Trier les IDs par ordre de première apparition (y puis x) pour consistance
	var sorted_ids: Array = []
	for region_id in region_first_seen.keys():
		# Appliquer la fusion
		var effective_id = region_id
		if merge_map.has(region_id):
			effective_id = merge_map[region_id]
		sorted_ids.append([effective_id, region_first_seen[region_id]])
	
	# Dédupliquer après fusion
	var seen_effective: Dictionary = {}
	var unique_sorted: Array = []
	for item in sorted_ids:
		var eff_id = item[0]
		if not seen_effective.has(eff_id):
			seen_effective[eff_id] = true
			unique_sorted.append(item)
	
	# Trier par position (y * width + x)
	unique_sorted.sort_custom(func(a, b): 
		var pos_a = a[1].y * width + a[1].x
		var pos_b = b[1].y * width + b[1].x
		return pos_a < pos_b
	)
	
	var ordered_ids: Array = []
	for item in unique_sorted:
		ordered_ids.append(item[0])
	id_to_color = _assign_administrative_colors(ordered_ids)
	
	print("    Assigned ", id_to_color.size(), " unique colors")
	
	# =========================================================================
	# PHASE 3 : Colorier l'image en parallèle (subdivision par threads)
	# =========================================================================
	print("  Phase 3: Coloring image with ", _nb_threads, " threads...")
	
	# Créer le buffer de sortie RGBA8 (4 bytes par pixel)
	var output_data = PackedByteArray()
	output_data.resize(width * height * 4)
	
	var rows_per_thread = ceili(float(height) / float(_nb_threads))
	var threads: Array[Thread] = []
	
	# Couleur pour les pixels sans région (RGBA8) - TRANSPARENT
	var no_region_rgba = PackedByteArray([0x00, 0x00, 0x00, 0x00])  # Transparent
	
	for t in range(_nb_threads):
		var start_y = t * rows_per_thread
		var end_y = min(start_y + rows_per_thread, height)
		
		if start_y >= height:
			break
		
		var thread = Thread.new()
		thread.start(_color_region_rows_fast.bind(
			data, output_data, width, start_y, end_y, 
			id_to_color, merge_map, no_region_rgba
		))
		threads.append(thread)
	
	# Attendre tous les threads
	for thread in threads:
		thread.wait_to_finish()
	
	# Créer l'image à partir du buffer
	img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output_data)
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = _save_png(img, filepath)
	
	if err == OK:
		result["region_colored"] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", CPU colored)")
	else:
		push_error("[Exporter] ❌ Failed to save region map: ", err)
	
	print("[Exporter] ✅ Region export complete")
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
func _export_ocean_region_map(gpu: GPUContext, output_dir: String, _optimised_region_generation : bool = true) -> Dictionary:
	print("[Exporter] 🌊 Exporting ocean region map (CPU administrative coloration)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture

	
	var tex_id = "ocean_region_map"  # R32UI - IDs bruts
	var filename = "departement_mer_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'ocean_region_map' non disponible, skip")
		return result
	
	# Lecture directe des données R32UI depuis le GPU
	var data = _read_texture(gpu, tex_id)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for ocean region texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (R32UI = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for ocean region map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image de sortie RGBA8
	var img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create ocean region image")
		return result
	
	# =========================================================================
	# PHASE 1 : Collecter tous les IDs uniques et gérer le wrapping horizontal
	# =========================================================================
	print("  Phase 1: Collecting unique ocean region IDs...")
	
	var region_first_seen: Dictionary = {}
	
	for y in range(height):
		for x in range(width):
			var offset = (y * width + x) * 4
			var region_id = data.decode_u32(offset)
			
			# 0xFFFFFFFF = non-assigné (terre ou océan sans région)
			if region_id == 0xFFFFFFFF:
				continue
			
			if not region_first_seen.has(region_id):
				region_first_seen[region_id] = Vector2i(x, y)

	var merge_map := HierarchyBuilder.compute_merge_map(data, width, height)

	print("    Found ", region_first_seen.size(), " unique ocean regions")
	
	# =========================================================================
	# PHASE 2 : Assigner les couleurs séquentiellement
	# =========================================================================
	print("  Phase 2: Assigning deterministic high-contrast colors...")
	
	var id_to_color: Dictionary = {}
	
	var sorted_ids: Array = []
	for region_id in region_first_seen.keys():
		var effective_id = region_id
		if merge_map.has(region_id):
			effective_id = merge_map[region_id]
		sorted_ids.append([effective_id, region_first_seen[region_id]])
	
	var seen_effective: Dictionary = {}
	var unique_sorted: Array = []
	for item in sorted_ids:
		var eff_id = item[0]
		if not seen_effective.has(eff_id):
			seen_effective[eff_id] = true
			unique_sorted.append(item)
	
	unique_sorted.sort_custom(func(a, b): 
		var pos_a = a[1].y * width + a[1].x
		var pos_b = b[1].y * width + b[1].x
		return pos_a < pos_b
	)
	
	var ordered_ids: Array = []
	for item in unique_sorted:
		ordered_ids.append(item[0])
	id_to_color = _assign_administrative_colors(ordered_ids)
	
	print("    Assigned ", id_to_color.size(), " unique colors")
	
	# =========================================================================
	# PHASE 3 : Colorier l'image en parallèle
	# =========================================================================
	print("  Phase 3: Coloring image with ", _nb_threads, " threads...")
	
	# Créer le buffer de sortie RGBA8 (4 bytes par pixel)
	var output_data = PackedByteArray()
	output_data.resize(width * height * 4)
	
	var rows_per_thread = ceili(float(height) / float(_nb_threads))
	var threads: Array[Thread] = []
	
	# Couleur pour les pixels sans région océanique (RGBA8) - TRANSPARENT
	var no_region_rgba = PackedByteArray([0x00, 0x00, 0x00, 0x00])  # Transparent
	
	for t in range(_nb_threads):
		var start_y = t * rows_per_thread
		var end_y = min(start_y + rows_per_thread, height)
		
		if start_y >= height:
			break
		
		var thread = Thread.new()
		thread.start(_color_region_rows_fast.bind(
			data, output_data, width, start_y, end_y, 
			id_to_color, merge_map, no_region_rgba
		))
		threads.append(thread)
	
	for thread in threads:
		thread.wait_to_finish()
	
	# Créer l'image à partir du buffer
	img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output_data)
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = _save_png(img, filepath)
	
	if err == OK:
		result["ocean_region_colored"] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", CPU colored)")
	else:
		push_error("[Exporter] ❌ Failed to save ocean region map: ", err)
	
	print("[Exporter] ✅ Ocean region export complete")
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
func _export_resources_maps(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] ⛏️ Exporting resources maps...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# M7.2b: resources are a first-class export category. Write them directly
	# to their final directory instead of staging them in `ressource/` and
	# relying on a later move. This also makes interrupted exports unambiguous.
	var resources_dir := output_dir.path_join("maps").path_join("resources")
	if not DirAccess.dir_exists_absolute(resources_dir):
		DirAccess.make_dir_recursive_absolute(resources_dir)
	
	# Synchroniser le GPU avant lecture

	
	# === EXPORT PÉTROLE (RGBA8 direct) ===
	if gpu.textures.has("petrole") and gpu.textures["petrole"].is_valid():
		var petrole_data = _read_texture(gpu, "petrole")
		
		if petrole_data.size() > 0:
			var expected_size = width * height * 4  # RGBA8
			if petrole_data.size() == expected_size:
				var petrole_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, petrole_data)
				var petrole_path = resources_dir + "/petrole_map.png"
				var err = _save_png(petrole_img, petrole_path)
				
				if err == OK:
					result["petrole_map"] = petrole_path
					print("  ✅ Saved: ", petrole_path)
				else:
					push_error("[Exporter] ❌ Failed to save petrole_map: ", err)
			else:
				push_error("[Exporter] ❌ Petrole data size mismatch: expected ", expected_size, ", got ", petrole_data.size())
		else:
			print("  ⚠️ Petrole texture empty, skipping")
	else:
		print("  ⚠️ Petrole texture not available, skipping")
	
	if _cancel_requested():
		print("[Exporter] Resource export cancelled after petroleum map")
		return result

	# === EXPORT RESSOURCES (RGBA8UI -> cartes individuelles streamées) ===
	if gpu.textures.has("resources") and gpu.textures["resources"].is_valid():
		var res_data = _read_texture(gpu, "resources")
		
		if res_data.size() > 0:
			var expected_size = width * height * 4  # RGBA8UI
			if res_data.size() == expected_size:
				var resource_count := RESOURCE_NAMES.size()
				var counts := PackedInt32Array()
				counts.resize(resource_count)
				for pixel_index in range(width * height):
					if (pixel_index & 65535) == 0 and _cancel_requested():
						print("[Exporter] Resource export cancelled while counting resources")
						return result
					var source_offset := pixel_index * 4
					var resource_id := int(res_data[source_offset])
					if res_data[source_offset + 3] > 0 and resource_id < resource_count:
						counts[resource_id] += 1

				# Compact counting-sort index: 4 bytes per occupied pixel, avoiding
				# 115 simultaneous full-size RGBA8 Image allocations.
				var offsets := PackedInt32Array()
				offsets.resize(resource_count + 1)
				for i in range(resource_count):
					offsets[i + 1] = offsets[i] + counts[i]
				var cursors := offsets.duplicate()
				var resource_indices := PackedInt32Array()
				resource_indices.resize(offsets[resource_count])
				for pixel_index in range(width * height):
					if (pixel_index & 65535) == 0 and _cancel_requested():
						print("[Exporter] Resource export cancelled while building resource index")
						return result
					var source_offset := pixel_index * 4
					var resource_id := int(res_data[source_offset])
					if res_data[source_offset + 3] == 0 or resource_id >= resource_count:
						continue
					resource_indices[cursors[resource_id]] = pixel_index
					cursors[resource_id] += 1

				var resource_colors: Array[Color] = []
				for resource in Enum.RESSOURCES:
					resource_colors.append(resource.couleur)

				# Materialize, compress and release exactly one resource map at a time.
				for i in range(RESOURCE_NAMES.size()):
					if _cancel_requested():
						print("[Exporter] Resource export cancelled at resource ", i)
						return result
					var output := PackedByteArray()
					output.resize(width * height * 4)
					output.fill(0)
					var base_color := resource_colors[i] if i < resource_colors.size() else Color.WHITE
					for index_position in range(offsets[i], offsets[i + 1]):
						var pixel_index := resource_indices[index_position]
						var source_offset := pixel_index * 4
						var output_offset := source_offset
						var intensity := float(res_data[source_offset + 1]) / 255.0
						output[output_offset] = clampi(roundi(base_color.r * intensity * 255.0), 0, 255)
						output[output_offset + 1] = clampi(roundi(base_color.g * intensity * 255.0), 0, 255)
						output[output_offset + 2] = clampi(roundi(base_color.b * intensity * 255.0), 0, 255)
						output[output_offset + 3] = res_data[source_offset + 3]
					var resource_image := Image.create_from_data(
						width, height, false, Image.FORMAT_RGBA8, output
					)
					last_metrics["peak_cpu_map_bytes"] = maxi(
						int(last_metrics.get("peak_cpu_map_bytes", 0)),
						res_data.size() + resource_indices.size() * 4 + output.size()
					)
					var res_path = resources_dir + "/" + RESOURCE_NAMES[i] + "_map.png"
					var err = _save_png(resource_image, res_path)
					if err == OK:
						result[RESOURCE_NAMES[i] + "_map"] = res_path
						print("  ✅ Saved: ", res_path)
					else:
						push_error("[Exporter] ❌ Failed to save ", RESOURCE_NAMES[i], "_map: ", err)
			else:
				push_error("[Exporter] ❌ Resources data size mismatch: expected ", expected_size, ", got ", res_data.size())
		else:
			print("  ⚠️ Resources texture empty, skipping")
	else:
		print("  ⚠️ Resources texture not available, skipping")
	
	print("[Exporter] ✅ Resources export complete: ", result.size(), " maps")
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

	
	# Vérifier que water_colored existe (généré par water_to_color.glsl)
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
	print("[Exporter] 🌊 Exporting river map (GPU river_biome_id based)...")

	var result = {}
	var rd = gpu.rd

	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result

	# Synchroniser le GPU


	# Récupérer le type d'atmosphère
	var atmosphere_type = int(params.get("planet_type", 0))

	# Récupérer les biomes rivières pour ce type d'atmosphère
	# L'ordre et le filtrage sont IDENTIQUES au SSBO GPU (get_river_biomes_for_gpu)
	var river_biomes_list: Array = Enum.get_river_biomes_for_gpu(atmosphere_type)

	if river_biomes_list.size() == 0:
		print("  ⚠️ No river biomes found for atmosphere type ", atmosphere_type)
		return result

	print("  Found ", river_biomes_list.size(), " river biomes for atmosphere type ", atmosphere_type)
	for rb in river_biomes_list:
		print("    - ", rb.get_nom(), " (", rb.get_couleur(), ")")

	# Lire la texture river_biome_id (R32UI) depuis le GPU
	# Cette texture contient l'index du biome rivière assigné par river_classify.glsl
	# 0xFFFFFFFF = pas de rivière (filtré par température + type)
	if not gpu.textures.has("river_biome_id") or not gpu.textures["river_biome_id"].is_valid():
		print("  ⚠️ river_biome_id texture not available")
		return result

	var biome_id_data = _read_texture(gpu, "river_biome_id")

	if biome_id_data.size() == 0:
		print("  ⚠️ river_biome_id texture empty")
		return result

	# river_biome_id contient aussi les plus petits affluents. Utiliser le flux
	# et le seuil physique calculé par l'hydrologie empêche l'export d'une maille
	# cyan extrêmement dense sur toute la planète.
	var flux_data := PackedByteArray()
	if gpu.textures.has("river_flux") and gpu.textures["river_flux"].is_valid():
		flux_data = _read_texture(gpu, "river_flux")
	var has_flux_data := flux_data.size() >= width * height * 4
	var display_flux_threshold := _river_display_flux_threshold()
	var water_mask_data := PackedByteArray()
	if gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid():
		water_mask_data = _read_texture(gpu, "water_mask")
	var has_water_mask := water_mask_data.size() >= width * height

	# Créer l'image de sortie
	var river_img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	river_img.fill(Color(0, 0, 0, 0))  # Transparent par défaut

	var river_pixel_count = 0
	var skipped_no_biome = 0
	var skipped_low_flux = 0
	var biome_counts: Dictionary = {}

	for y in range(height):
		for x in range(width):
			var pixel_idx = y * width + x
			var byte_offset = pixel_idx * 4  # R32UI = 4 bytes par pixel

			if byte_offset + 4 > biome_id_data.size():
				continue

			# Lire l'index du biome rivière assigné par le GPU
			var biome_idx = biome_id_data.decode_u32(byte_offset)

			# 0xFFFFFFFF = pas de rivière (pas de biome adapté en température)
			if biome_idx == 0xFFFFFFFF:
				continue
			if has_water_mask and water_mask_data[pixel_idx] > 0:
				continue

			if has_flux_data and flux_data.decode_float(byte_offset) < display_flux_threshold:
				skipped_low_flux += 1
				continue

			# Vérifier que l'index est valide dans la liste des biomes
			if biome_idx >= river_biomes_list.size():
				skipped_no_biome += 1
				continue

			river_pixel_count += 1

			# Utiliser le biome sélectionné par le GPU (température déjà vérifiée)
			var selected_biome: Biome = river_biomes_list[biome_idx]
			var color = selected_biome.get_couleur()
			river_img.set_pixel(x, y, color)

			var biome_name = selected_biome.get_nom()
			if biome_counts.has(biome_name):
				biome_counts[biome_name] += 1
			else:
				biome_counts[biome_name] = 1

	print("  River pixels drawn: ", river_pixel_count)
	if skipped_no_biome > 0:
		print("  ⚠️ Skipped ", skipped_no_biome, " pixels with invalid biome index")
	if skipped_low_flux > 0:
		print("  Filtered ", skipped_low_flux, " minor tributary pixels below flux ", display_flux_threshold)
	for biome_name in biome_counts.keys():
		print("    - ", biome_name, ": ", biome_counts[biome_name])

	# Sauvegarder
	var path_river = output_dir + "/river_map.png"
	var err = _save_png(river_img, path_river)
	if err == OK:
		result["river_map"] = path_river
		print("  ✅ Saved: ", path_river)
	else:
		push_error("[Exporter] ❌ Failed to save river_map: ", err)

	print("[Exporter] ✅ River map export complete")
	return result

## Export de la carte des types de rivières avec couleurs fixes
## Affluent = cyan clair, Rivière = bleu, Fleuve = bleu foncé
func _export_river_type_map(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🗺️ Exporting river type map...")

	var result = {}
	var rd = gpu.rd

	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result

	var atmosphere_type := int(params.get("planet_type", 0))
	var river_biomes_list: Array = Enum.get_river_biomes_for_gpu(atmosphere_type)

	# Lire ocean_reachable qui contient le type promu (0=affluent,1=riviere,2=fleuve,255=none)
	if not gpu.textures.has("ocean_reachable") or not gpu.textures["ocean_reachable"].is_valid():
		print("  ⚠️ ocean_reachable (river type) texture not available")
		return result

	# Lire river_biome_id pour filtrer par température (cohérent avec river_map)
	var has_biome_id = gpu.textures.has("river_biome_id") and gpu.textures["river_biome_id"].is_valid()
	var biome_id_data: PackedByteArray = []
	if has_biome_id:
		biome_id_data = _read_texture(gpu, "river_biome_id")

	var has_river_type = true
	var has_water_mask = gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid()
	var river_type_data: PackedByteArray = _read_texture(gpu, "ocean_reachable")
	var water_mask_data: PackedByteArray = []
	var flux_data := PackedByteArray()
	if gpu.textures.has("river_flux") and gpu.textures["river_flux"].is_valid():
		flux_data = _read_texture(gpu, "river_flux")
	var has_flux_data := flux_data.size() >= width * height * 4
	var display_flux_threshold := _river_display_flux_threshold()
	if has_water_mask:
		water_mask_data = _read_texture(gpu, "water_mask")

	# Couleurs fixes pour chaque type
	var color_affluent = Color(0.4, 0.75, 1.0, 1.0)   # Cyan clair
	var color_riviere  = Color(0.1, 0.35, 0.85, 1.0)   # Bleu
	var color_fleuve    = Color(0.15, 0.05, 0.55, 1.0)  # Bleu-violet foncé

	var type_img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	type_img.fill(Color(0, 0, 0, 0))

	var count_affluent = 0
	var count_riviere = 0
	var count_fleuve = 0

	for y in range(height):
		for x in range(width):
			var pixel_idx = y * width + x

			# Filtrage par type promu : 255 = pas de riviere
			if has_river_type and river_type_data.size() > pixel_idx:
				if river_type_data[pixel_idx] == 255:
					continue
			# Exclure les pixels d'eau
			if has_water_mask and water_mask_data.size() > pixel_idx:
				if water_mask_data[pixel_idx] > 0:
					continue

			# Filtrer par river_biome_id : si le GPU n'a assigné aucun biome
			# (température hors plage), ne pas afficher cette rivière
			if has_biome_id and biome_id_data.size() >= (pixel_idx + 1) * 4:
				var biome_idx = biome_id_data.decode_u32(pixel_idx * 4)
				if biome_idx == 0xFFFFFFFF or biome_idx >= river_biomes_list.size():
					continue

			# river_type_map classifies the same visible network as river_map.
			if has_flux_data and flux_data.decode_float(pixel_idx * 4) < display_flux_threshold:
				continue

			var rtype = 0
			if has_river_type and river_type_data.size() > pixel_idx:
				rtype = river_type_data[pixel_idx]

			if rtype == 2:
				type_img.set_pixel(x, y, color_fleuve)
				count_fleuve += 1
			elif rtype == 1:
				type_img.set_pixel(x, y, color_riviere)
				count_riviere += 1
			else:
				type_img.set_pixel(x, y, color_affluent)
				count_affluent += 1

	print("  River type counts:")
	print("    - Affluent (cyan):  ", count_affluent)
	print("    - Rivière (bleu):   ", count_riviere)
	print("    - Fleuve (foncé):   ", count_fleuve)
	print("    - Total:            ", count_affluent + count_riviere + count_fleuve)

	var path_type = output_dir + "/river_type_map.png"
	var err = _save_png(type_img, path_type)
	if err == OK:
		result["river_type_map"] = path_type
		print("  ✅ Saved: ", path_type)
	else:
		push_error("[Exporter] ❌ Failed to save river_type_map: ", err)

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
## Post-traitement CPU :
## - Assombrit les pixels eau avec WATER_DARKENING_FACTOR
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


func _export_final_map(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🗺️ Exporting final map (GPU compute shader + CPU darkening)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture

	
	var tex_id = "final_map"
	var filename = "final_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'final_map' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = _read_texture(gpu, tex_id)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for final_map texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (RGBA8 = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for final_map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image directement à partir des données
	var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create final_map image")
		return result
	
	# === POST-TRAITEMENT CPU : Assombrir uniformément tous les pixels eau ===
	# water_colored est la source de vérité pour les mers comme pour les eaux
	# douces. La texture geo ne sert que de repli si le masque est indisponible.
	# La texture geo n'a aucune signification pour une géante gazeuse et n'est
	# volontairement jamais utilisée pour modifier son rendu final.
	var planet_type = int(params.get("planet_type", 0))
	var water_darkening_factor: float = WATER_DARKENING_FACTOR
	if planet_type == Enum.TYPE_TOXIC:
		water_darkening_factor = 0.92
	elif planet_type == Enum.TYPE_VOLCANIC:
		# La lave est émissive : le post-traitement ne doit pas annuler la
		# luminance construite par le shader de carte finale.
		water_darkening_factor = 1.0
	elif planet_type == Enum.TYPE_DEAD:
		water_darkening_factor = 0.82
	if planet_type != Enum.TYPE_GAZEUZE and gpu.textures.has("geo") and gpu.textures["geo"].is_valid():
		var geo_data = _read_texture(gpu, "geo")
		var water_data := PackedByteArray()
		if gpu.textures.has("water_colored") and gpu.textures["water_colored"].is_valid():
			water_data = _read_texture(gpu, "water_colored")
		var has_water_data: bool = water_data.size() == expected_size
		var ice_data := PackedByteArray()
		if gpu.textures.has("ice_caps") and gpu.textures["ice_caps"].is_valid():
			ice_data = _read_texture(gpu, "ice_caps")
		var has_ice_data: bool = ice_data.size() == expected_size
		
		if geo_data.size() > 0:
			print("  Applying water darkening factor: ", water_darkening_factor)
			var water_pixels_darkened = 0
			var ice_pixels_preserved = 0
			
			for y in range(height):
				for x in range(width):
					var pixel_idx = y * width + x
					var geo_idx = pixel_idx * 16  # RGBA32F = 16 bytes par pixel
					var elevation = geo_data.decode_float(geo_idx)  # R = élévation
					var is_water: bool = (
						has_water_data and water_data[pixel_idx * 4 + 3] > 0
					) or (not has_water_data and elevation < 0.0)
					var is_ice: bool = has_ice_data and ice_data[pixel_idx * 4 + 3] > 6
					
					# Ne jamais assombrir la banquise déjà composée par le GPU.
					if is_water and not is_ice:
						var current_color = img.get_pixel(x, y)
						# Assombrir RGB tout en gardant l'alpha
						var darkened_color = Color(
							current_color.r * water_darkening_factor,
							current_color.g * water_darkening_factor,
							current_color.b * water_darkening_factor,
							current_color.a
						)
						img.set_pixel(x, y, darkened_color)
						water_pixels_darkened += 1
					elif is_water and is_ice:
						ice_pixels_preserved += 1
			
			print("  Water pixels darkened: ", water_pixels_darkened)
			print("  Ice pixels preserved: ", ice_pixels_preserved)
	elif planet_type != Enum.TYPE_GAZEUZE:
		print("  ⚠️ geo texture not available, skipping water darkening")
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = _save_png(img, filepath)
	
	if err == OK:
		result[tex_id] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", with water darkening)")
	else:
		push_error("[Exporter] ❌ Failed to save final_map: ", err)
	
	print("[Exporter] ✅ Final map export complete")
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
	
	# ─── Peinture et export (threadé) ────────────────────────────────────────
	var exports: Array = [
		[land_data, merge_land, land[0], "region_map.png",    "Régions terrestres"],
		[land_data, merge_land, land[1], "pays_map.png",      "Pays"],
		[land_data, merge_land, land[2], "continent_map.png", "Continents"],
	]
	if not sea_data.is_empty():
		exports.append([sea_data, merge_sea, sea[0], "region_mer_map.png", "Régions maritimes"])
		exports.append([sea_data, merge_sea, sea[1], "bassin_map.png",     "Bassins"])
		exports.append([sea_data, merge_sea, sea[2], "ocean_map.png",      "Océans"])
	
	for entry in exports:
		var data: PackedByteArray = entry[0]
		var merge: Dictionary = entry[1]
		var d2g: Dictionary = entry[2]
		var filename: String = entry[3]
		var label: String = entry[4]
		
		if d2g.is_empty():
			print("  ⚠️ ", label, " — pas de données, ignoré")
			continue
		
		# Assigner les couleurs step-17 aux groupes
		var group_ids := HierarchyBuilder._unique_values(d2g)
		var colors := _assign_administrative_colors(group_ids)
		
		# Peindre l'image en parallèle
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
				data, output, width, sy, ey, merge, d2g, colors))
			threads.append(thread)
		
		for thread in threads:
			thread.wait_to_finish()
		
		var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output)
		var filepath := output_dir + "/" + filename
		var err := _save_png(img, filepath)
		
		if err == OK:
			result[label] = filepath
			print("  ✅ ", label, " → ", filename, " (", width, "×", height, ")")
		else:
			push_error("[Exporter] ❌ Échec sauvegarde ", filename, " : ", err)
	
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
