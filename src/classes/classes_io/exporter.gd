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

# Number of threads for parallel processing
var _nb_threads: int = 8

# Water colors by atmosphere type
static var WATER_COLORS = {
	# Type 0 (Default) - Bleu
	0: {
		"saltwater": Color.hex(0x25528aFF),  # Océan
		"freshwater": Color.hex(0x4584d2FF)  # Lac
	},
	# Type 1 (Toxic) - Vert toxique
	1: {
		"saltwater": Color.hex(0x329b83FF),
		"freshwater": Color.hex(0x48d63bFF)
	},
	# Type 2 (Volcanic) - Lave
	2: {
		"saltwater": Color.hex(0xd69617FF),
		"freshwater": Color.hex(0xb7490eFF)
	},
	# Type 4 (Dead) - Vert mort
	4: {
		"saltwater": Color.hex(0x49794aFF),
		"freshwater": Color.hex(0x619f63FF)
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
func export_maps(gpu : GPUContext, output_dir: String, generation_params: Dictionary) -> Dictionary:
	"""
	Export all map types from GPU textures to PNG files
	Each individual export function handles its own threading internally
	
	Args:
		gpu: GPUContext with texture RIDs
		output_dir: Save directory path
		generation_params: Generation parameters (includes nb_thread)
	
	Returns:
		Dictionary with keys: map_name -> file_path
	"""
	params = generation_params
	_nb_threads = int(params.get("nb_thread", 8))
	
	print("[Exporter] Starting map export to: ", output_dir, " (nb_threads=", _nb_threads, ")")
	
	if not DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	
	# Récupérer l'instance GPUContext
	var gpu_context = gpu
	if not gpu_context:
		push_error("[Exporter] GPUContext not available!")
		return {}
	
	var rd = gpu_context.rd
	
	# Ensure GPU work is complete before reading
	rd.submit()
	rd.sync()
	
	# === TYPE 6 (GAZEUSE) : Export simplifié ===
	# Seulement température, précipitation et carte finale
	var planet_type = int(params.get("planet_type", 0))
	if planet_type == 6:  # TYPE_GAZEUZE
		print("[Exporter] 🪐 Export gazeuse - cartes limitées (température, précipitation, final)")
		var exported_files = {}
		
		# Export climat (température + précipitation colorées seulement)
		var climate_result = _export_climate_maps_gas_giant(gpu, output_dir)
		for key in climate_result.keys():
			exported_files[key] = climate_result[key]
		
		# Export final map
		var final_result = _export_final_map(gpu, output_dir)
		for key in final_result.keys():
			exported_files[key] = final_result[key]
		
		print("[Exporter] Export gazeuse complete: ", exported_files.size(), " maps")
		return exported_files
	
	# Liste des textures RGBA32F (16 bytes/pixel) - exclure les textures climat
	var rgba32f_textures = ["geo", "climate", "temp_buffer", "plates", "crust_age"]
	
	for map_type in rgba32f_textures:
		if not gpu.textures.has(map_type) or not gpu.textures[map_type]:
			push_error("[Exporter] ❌ Missing texture for map type: ", map_type)
			return {}

	var geo_format = rd.texture_get_format(gpu.textures["geo"])
	var width = geo_format.width
	var height = geo_format.height
	
	print("[Exporter] Detected texture size: ", width, "x", height)
	
	var maps : Dictionary[String, PackedByteArray] = {}
	# Read GPU textures (only RGBA32F textures)
	for map in rgba32f_textures:
		if gpu.textures.has(map):
			print("[Exporter] Reading texture for map type: ", map)
			var data = rd.texture_get_data(gpu.textures[map], 0)
			maps[map] = data
	
	# Validate data size based on DETECTED dimensions (RGBA32F = 16 bytes/pixel)
	var expected_size = width * height * 16
	for map in maps.keys():
		if maps[map].size() != expected_size:
			push_error("[Exporter] ❌ Data size mismatch for map type: ", map, 
				". Expected: ", expected_size, ", Got: ", maps[map].size())
			return {}
	
	var imgs : Dictionary[String, Image] = {}
	# Create images from raw data
	for map in maps.keys():
		var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, maps[map])
		imgs[map] = img
	
	# Export all map types
	var exported_files = {}
	
	# === EXPORT TOPOGRAPHIE (Step 0) ===
	if imgs.has("geo"):
		var topo_result = _export_topographie_maps(imgs["geo"], output_dir, width, height)
		for key in topo_result.keys():
			exported_files[key] = topo_result[key]
	
	# === EXPORT PLAQUES TECTONIQUES (Step 0) ===
	if imgs.has("plates"):
		var plates_result = _export_plates_map(imgs["plates"], output_dir, width, height)
		for key in plates_result.keys():
			exported_files[key] = plates_result[key]
	
	# === EXPORT CLIMAT (Step 3) - Optimisé RGBA8 Direct ===
	# Pour les planètes sans atmosphère ou stériles, exporter seulement temp/precip (pas nuages/banquise)
	if planet_type in [3, 5]:  # TYPE_NO_ATMOS, TYPE_STERILE
		var climate_result = _export_climate_maps_gas_giant(gpu, output_dir)  # Réutilise: exporte seulement temp + precip
		for key in climate_result.keys():
			exported_files[key] = climate_result[key]
	else:
		var climate_result = _export_climate_maps_optimized(gpu, output_dir)
		for key in climate_result.keys():
			exported_files[key] = climate_result[key]
	
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
	
	# === EXPORT BIOMES (Step 4.1) ===
	var biome_result = _export_biome_map(gpu, output_dir)
	for key in biome_result.keys():
		exported_files[key] = biome_result[key]
	
	# === EXPORT FINAL MAP (Step 6) ===
	var final_result = _export_final_map(gpu, output_dir)
	for key in final_result.keys():
		exported_files[key] = final_result[key]
	
	# === EXPORT RESSOURCES (Step 5) ===
	var resources_result = _export_resources_maps(gpu, output_dir, width, height)
	for key in resources_result.keys():
		exported_files[key] = resources_result[key]
	
	print("[Exporter] Export complete: ", exported_files.size(), " maps")
	return exported_files

# ============================================================================
# INDIVIDUAL MAP EXPORTERS
# ============================================================================

## Exporte les cartes topographiques (élévation) en deux versions :
## - Version colorée : utilise COULEURS_ELEVATIONS d'Enum.gd
## - Version grisée : utilise COULEURS_ELEVATIONS_GREY d'Enum.gd
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
	var path_water = output_dir + "/eaux_map.png"
	
	var err_colored = elevation_colored.save_png(path_colored)
	var err_grey = elevation_grey.save_png(path_grey)
	var err_water = water_mask.save_png(path_water)
	
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
	
	if err_water == OK:
		result["eaux_map"] = path_water
		print("  ✅ Saved: ", path_water)
	else:
		push_error("[Exporter] ❌ Failed to save eaux_map: ", err_water)
	
	return result

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
	
	var err_plates = plates_colored.save_png(path_plates)
	var err_borders = plates_borders.save_png(path_borders)
	
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

## Exporte la heightmap brute (valeurs float normalisées en niveaux de gris)
## Utile pour le debug et l'importation dans d'autres outils
##
## @param geo_img: Image RGBAF provenant de la texture GPU "geo"
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return String: Chemin du fichier exporté
func _export_raw_heightmap(geo_img: Image, output_dir: String, width: int, height: int) -> String:
	print("[Exporter] 📊 Exporting raw heightmap...")
	
	var raw_heightmap = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	# Trouver min/max pour normalisation
	var min_elev = INF
	var max_elev = -INF
	
	for y in range(height):
		for x in range(width):
			var elev = geo_img.get_pixel(x, y).r
			min_elev = min(min_elev, elev)
			max_elev = max(max_elev, elev)
	
	print("  Elevation range: ", min_elev, " to ", max_elev, " meters")
	
	var range_elev = max_elev - min_elev
	if range_elev < 0.001:
		range_elev = 1.0  # Éviter division par zéro
	
	# Normaliser et écrire
	for y in range(height):
		for x in range(width):
			var elev = geo_img.get_pixel(x, y).r
			var normalized = (elev - min_elev) / range_elev
			var grey = clamp(normalized, 0.0, 1.0)
			raw_heightmap.set_pixel(x, y, Color(grey, grey, grey, 1.0))
	
	var path = output_dir + "/heightmap_raw.png"
	var err = raw_heightmap.save_png(path)
	
	if err == OK:
		print("  ✅ Saved: ", path)
		return path
	else:
		push_error("[Exporter] ❌ Failed to save raw heightmap: ", err)
		return ""

# ============================================================================
# EXPORT CLIMAT GAZEUSE (température + précipitation seulement)
# ============================================================================

## Exporte uniquement température et précipitation pour les planètes gazeuses.
## Pas de nuages ni de banquise car il n'y a pas de surface.
func _export_climate_maps_gas_giant(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🪐 Exporting gas giant climate maps (temp + precip)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	rd.submit()
	rd.sync()
	
	# Seulement température et précipitation pour les gazeuses
	var climate_textures = {
		"temperature_colored": "temperature_map.png",
		"precipitation_colored": "precipitation_map.png",
	}
	
	for tex_id in climate_textures.keys():
		if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
			print("  ⚠️ Texture '", tex_id, "' non disponible, skip")
			continue
		
		var data = rd.texture_get_data(gpu.textures[tex_id], 0)
		
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
		var save_err = img.save_png(filepath)
		
		if save_err == OK:
			result[tex_id] = filepath
			print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
		else:
			push_error("[Exporter] ❌ Failed to save ", filename, ": ", save_err)
	
	print("[Exporter] ✅ Gas giant climate export complete: ", result.size(), " maps")
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
	rd.submit()
	rd.sync()
	
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
		var data = rd.texture_get_data(gpu.textures[tex_id], 0)
		
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
		var err = img.save_png(filepath)
		
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
	print("[Exporter] 🗺️ Exporting region map (CPU coloration with Region.gd system)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	var tex_id = "region_map"  # R32UI - IDs bruts
	var filename = "region_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'region_map' non disponible, skip")
		return result
	
	# Lecture directe des données R32UI depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
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
	# Pour fusionner les régions qui touchent les bords (wrap horizontal)
	# On stocke les IDs vus sur la colonne 0 et la colonne width-1
	var left_edge_ids: Dictionary = {}  # y -> id
	var right_edge_ids: Dictionary = {}  # y -> id
	
	for y in range(height):
		for x in range(width):
			var offset = (y * width + x) * 4
			var region_id = data.decode_u32(offset)
			
			# 0xFFFFFFFF = non-assigné (eau ou terre sans région)
			if region_id == 0xFFFFFFFF:
				continue
			
			if not region_first_seen.has(region_id):
				region_first_seen[region_id] = Vector2i(x, y)
			
			# Enregistrer les IDs sur les bords
			if x == 0:
				left_edge_ids[y] = region_id
			elif x == width - 1:
				right_edge_ids[y] = region_id
	
	# Fusionner les régions qui se touchent via le wrap horizontal
	# Une région sur le bord droit (x=width-1) est adjacente au bord gauche (x=0)
	var merge_map: Dictionary = {}  # id_to_merge -> id_target
	for y in right_edge_ids.keys():
		if left_edge_ids.has(y):
			var right_id = right_edge_ids[y]
			var left_id = left_edge_ids[y]
			if right_id != left_id and right_id != 0xFFFFFFFF and left_id != 0xFFFFFFFF:
				# Fusionner le plus grand ID vers le plus petit
				var keep_id = min(right_id, left_id)
				var merge_id = max(right_id, left_id)
				merge_map[merge_id] = keep_id
	
	# Appliquer la transitivité des fusions
	for merge_id in merge_map.keys():
		var target = merge_map[merge_id]
		while merge_map.has(target):
			target = merge_map[target]
		merge_map[merge_id] = target
	
	print("    Found ", region_first_seen.size(), " unique regions, ", merge_map.size(), " to merge via wrap")
	
	# =========================================================================
	# PHASE 2 : Assigner les couleurs séquentiellement (système Region.gd)
	# =========================================================================
	print("  Phase 2: Assigning colors (Region.gd step=17 system)...")
	
	var id_to_color: Dictionary = {}
	var color_counter: Array = [0, 0, 0, 255]  # R, G, B, A
	const STEP = 17  # Identique à Region.gd
	
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
	
	# Assigner les couleurs dans l'ordre
	for item in unique_sorted:
		var eff_id = item[0]
		if id_to_color.has(eff_id):
			continue
		
		# Créer la couleur actuelle
		var color = Color(color_counter[0] / 255.0, color_counter[1] / 255.0, 
						  color_counter[2] / 255.0, color_counter[3] / 255.0)
		id_to_color[eff_id] = color
		
		# Incrémenter le compteur (système Region.gd)
		color_counter[0] += STEP
		if color_counter[0] > 255:
			color_counter[0] = color_counter[0] % 256
			color_counter[1] += STEP
		if color_counter[1] > 255:
			color_counter[1] = color_counter[1] % 256
			color_counter[2] += STEP
		if color_counter[2] > 255:
			color_counter[2] = color_counter[2] % 256
	
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
	var err = img.save_png(filepath)
	
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
					r = int(color.r * 255.0)
					g = int(color.g * 255.0)
					b = int(color.b * 255.0)
					a = int(color.a * 255.0)
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
	print("[Exporter] 🌊 Exporting ocean region map (CPU coloration with Region.gd system)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	var tex_id = "ocean_region_map"  # R32UI - IDs bruts
	var filename = "ocean_region_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'ocean_region_map' non disponible, skip")
		return result
	
	# Lecture directe des données R32UI depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
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
	var left_edge_ids: Dictionary = {}
	var right_edge_ids: Dictionary = {}
	
	for y in range(height):
		for x in range(width):
			var offset = (y * width + x) * 4
			var region_id = data.decode_u32(offset)
			
			# 0xFFFFFFFF = non-assigné (terre ou océan sans région)
			if region_id == 0xFFFFFFFF:
				continue
			
			if not region_first_seen.has(region_id):
				region_first_seen[region_id] = Vector2i(x, y)
			
			if x == 0:
				left_edge_ids[y] = region_id
			elif x == width - 1:
				right_edge_ids[y] = region_id
	
	# Fusionner les régions via wrap horizontal
	var merge_map: Dictionary = {}
	for y in right_edge_ids.keys():
		if left_edge_ids.has(y):
			var right_id = right_edge_ids[y]
			var left_id = left_edge_ids[y]
			if right_id != left_id and right_id != 0xFFFFFFFF and left_id != 0xFFFFFFFF:
				var keep_id = min(right_id, left_id)
				var merge_id = max(right_id, left_id)
				merge_map[merge_id] = keep_id
	
	# Transitivité
	for merge_id in merge_map.keys():
		var target = merge_map[merge_id]
		while merge_map.has(target):
			target = merge_map[target]
		merge_map[merge_id] = target
	
	print("    Found ", region_first_seen.size(), " unique ocean regions, ", merge_map.size(), " to merge via wrap")
	
	# =========================================================================
	# PHASE 2 : Assigner les couleurs séquentiellement (système Region.gd)
	# =========================================================================
	print("  Phase 2: Assigning colors (Region.gd step=17 system)...")
	
	var id_to_color: Dictionary = {}
	var color_counter: Array = [0, 0, 0, 255]
	const STEP = 17
	
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
	
	for item in unique_sorted:
		var eff_id = item[0]
		if id_to_color.has(eff_id):
			continue
		
		var color = Color(color_counter[0] / 255.0, color_counter[1] / 255.0, 
						  color_counter[2] / 255.0, color_counter[3] / 255.0)
		id_to_color[eff_id] = color
		
		color_counter[0] += STEP
		if color_counter[0] > 255:
			color_counter[0] = color_counter[0] % 256
			color_counter[1] += STEP
		if color_counter[1] > 255:
			color_counter[1] = color_counter[1] % 256
			color_counter[2] += STEP
		if color_counter[2] > 255:
			color_counter[2] = color_counter[2] % 256
	
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
	var err = img.save_png(filepath)
	
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
	rd.submit()
	rd.sync()
	
	var tex_id = "biome_colored"
	var filename = "biome_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'biome_colored' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
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
	var err = img.save_png(filepath)
	
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
	
	# Créer le sous-dossier ressource
	var resources_dir = output_dir + "/ressource"
	if not DirAccess.dir_exists_absolute(resources_dir):
		DirAccess.make_dir_recursive_absolute(resources_dir)
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	# === EXPORT PÉTROLE (RGBA8 direct) ===
	if gpu.textures.has("petrole") and gpu.textures["petrole"].is_valid():
		var petrole_data = rd.texture_get_data(gpu.textures["petrole"], 0)
		
		if petrole_data.size() > 0:
			var expected_size = width * height * 4  # RGBA8
			if petrole_data.size() == expected_size:
				var petrole_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, petrole_data)
				var petrole_path = resources_dir + "/petrole_map.png"
				var err = petrole_img.save_png(petrole_path)
				
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
	
	# === EXPORT RESSOURCES (RGBA32F -> cartes individuelles) ===
	if gpu.textures.has("resources") and gpu.textures["resources"].is_valid():
		var res_data = rd.texture_get_data(gpu.textures["resources"], 0)
		
		if res_data.size() > 0:
			var expected_size = width * height * 16  # RGBA32F
			if res_data.size() == expected_size:
				# Créer l'image source
				var res_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, res_data)
				
				# Créer une image pour chaque ressource
				var resource_images: Dictionary = {}
				for i in range(RESOURCE_NAMES.size()):
					resource_images[i] = Image.create(width, height, false, Image.FORMAT_RGBA8)
				
				# Récupérer les couleurs des ressources depuis Enum.gd
				var resource_colors = []
				for res in Enum.RESSOURCES:
					resource_colors.append(res.couleur)  # Utiliser 'couleur' au lieu de 'color'
				
				# Parcourir chaque pixel
				for y in range(height):
					for x in range(width):
						var pixel = res_img.get_pixel(x, y)
						var resource_id = int(round(pixel.r))
						var intensity = pixel.g
						var has_resource = pixel.a > 0.5
						
						if has_resource and resource_id >= 0 and resource_id < RESOURCE_NAMES.size():
							# Couleur de la ressource
							var base_color = resource_colors[resource_id] if resource_id < resource_colors.size() else Color(1, 1, 1, 1)
							
							# Alpha variable du shader (bruit + intensité)
							var alpha = pixel.a
							
							# RGB = couleur * intensité, Alpha = alpha du shader
							var color = Color(
								base_color.r * intensity,
								base_color.g * intensity,
								base_color.b * intensity,
								alpha
							)
							
							# Écrire dans la carte individuelle
							resource_images[resource_id].set_pixel(x, y, color)
				
				# Sauvegarder TOUTES les cartes individuelles
				for i in range(RESOURCE_NAMES.size()):
					if not resource_images.has(i):
						continue
					
					var res_path = resources_dir + "/" + RESOURCE_NAMES[i] + "_map.png"
					var err = resource_images[i].save_png(res_path)
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
	rd.submit()
	rd.sync()
	
	# Vérifier que water_colored existe (généré par water_to_color.glsl)
	if not gpu.textures.has("water_colored") or not gpu.textures["water_colored"].is_valid():
		push_error("[Exporter] ❌ water_colored texture not available - run water phase first")
		return result
	
	# Lire directement la texture water_colored (RGBA8) déjà calculée par le GPU
	var water_data = rd.texture_get_data(gpu.textures["water_colored"], 0)
	if water_data.size() == 0:
		push_error("[Exporter] ❌ water_colored texture data is empty")
		return result
	
	# Créer l'image directement depuis les données GPU
	var water_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, water_data)
	
	# Sauvegarder
	var path_water = output_dir + "/eaux_map.png"
	var err = water_img.save_png(path_water)
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
func _export_river_map(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 🌊 Exporting river map (GPU river_biome_id based)...")

	var result = {}
	var rd = gpu.rd

	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result

	# Synchroniser le GPU
	rd.submit()
	rd.sync()

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

	var biome_id_data = rd.texture_get_data(gpu.textures["river_biome_id"], 0)

	if biome_id_data.size() == 0:
		print("  ⚠️ river_biome_id texture empty")
		return result

	# Créer l'image de sortie
	var river_img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	river_img.fill(Color(0, 0, 0, 0))  # Transparent par défaut

	var river_pixel_count = 0
	var skipped_no_biome = 0
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
	for biome_name in biome_counts.keys():
		print("    - ", biome_name, ": ", biome_counts[biome_name])

	# Sauvegarder
	var path_river = output_dir + "/river_map.png"
	var err = river_img.save_png(path_river)
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

	# Lire ocean_reachable qui contient le type promu (0=affluent,1=riviere,2=fleuve,255=none)
	if not gpu.textures.has("ocean_reachable") or not gpu.textures["ocean_reachable"].is_valid():
		print("  ⚠️ ocean_reachable (river type) texture not available")
		return result

	# Lire river_biome_id pour filtrer par température (cohérent avec river_map)
	var has_biome_id = gpu.textures.has("river_biome_id") and gpu.textures["river_biome_id"].is_valid()
	var biome_id_data: PackedByteArray = []
	if has_biome_id:
		biome_id_data = rd.texture_get_data(gpu.textures["river_biome_id"], 0)

	var has_river_type = true
	var has_water_mask = gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid()
	var river_type_data: PackedByteArray = rd.texture_get_data(gpu.textures["ocean_reachable"], 0)
	var water_mask_data: PackedByteArray = []
	if has_water_mask:
		water_mask_data = rd.texture_get_data(gpu.textures["water_mask"], 0)

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
				if biome_idx == 0xFFFFFFFF:
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
	var err = type_img.save_png(path_type)
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
## - Rivières (overlay bleu si flux > seuil)
## - Relief topographique (ombrage hillshade)
## - Banquise (overlay prioritaire)
##
## Post-traitement CPU :
## - Assombrit les pixels eau avec WATER_DARKENING_FACTOR
##
## @param gpu: Instance GPUContext avec la texture final_map
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemin du fichier exporté
func _export_final_map(gpu: GPUContext, output_dir: String) -> Dictionary:
	print("[Exporter] 🗺️ Exporting final map (GPU compute shader + CPU darkening)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	var tex_id = "final_map"
	var filename = "final_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'final_map' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
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
	
	# === POST-TRAITEMENT CPU : Assombrir les pixels eau ===
	# Lire la texture geo pour identifier les pixels eau (élévation < 0)
	if gpu.textures.has("geo") and gpu.textures["geo"].is_valid():
		var geo_data = rd.texture_get_data(gpu.textures["geo"], 0)
		
		if geo_data.size() > 0:
			print("  Applying water darkening factor: ", WATER_DARKENING_FACTOR)
			var water_pixels_darkened = 0
			
			for y in range(height):
				for x in range(width):
					var geo_idx = (y * width + x) * 16  # RGBA32F = 16 bytes par pixel
					var elevation = geo_data.decode_float(geo_idx)  # R = élévation
					
					# Si c'est de l'eau (élévation négative)
					if elevation < 0.0:
						var current_color = img.get_pixel(x, y)
						# Assombrir RGB tout en gardant l'alpha
						var darkened_color = Color(
							current_color.r * WATER_DARKENING_FACTOR,
							current_color.g * WATER_DARKENING_FACTOR,
							current_color.b * WATER_DARKENING_FACTOR,
							current_color.a
						)
						img.set_pixel(x, y, darkened_color)
						water_pixels_darkened += 1
			
			print("  Water pixels darkened: ", water_pixels_darkened)
	else:
		print("  ⚠️ geo texture not available, skipping water darkening")
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = img.save_png(filepath)
	
	if err == OK:
		result[tex_id] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", with water darkening)")
	else:
		push_error("[Exporter] ❌ Failed to save final_map: ", err)
	
	print("[Exporter] ✅ Final map export complete")
	return result

## Compare deux couleurs avec tolérance pour erreurs de compression
func _colors_equal(c1: Color, c2: Color) -> bool:
	var threshold = 0.01
	return (
		absf(c1.r - c2.r) < threshold and
		absf(c1.g - c2.g) < threshold and
		absf(c1.b - c2.b) < threshold
	)

## Convertit une couleur en clé de dictionnaire
func _color_to_key(c: Color) -> String:
	return str(int(c.r * 255)) + "," + str(int(c.g * 255)) + "," + str(int(c.b * 255))
