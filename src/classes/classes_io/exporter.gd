extends RefCounted
class_name PlanetExporter

## ============================================================================
## PLANET EXPORTER - GPU Texture to PNG with Enum.gd Color Palettes
## ============================================================================
## Converts GPU compute results to legacy-compatible PNG images
## Uses existing color palettes from enum.gd for consistency
## ============================================================================

# Map generation parameters (for context-aware coloring)
var params: Dictionary = {}

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
	
	Args:
		rids: Dictionary with RIDs for each map type
		output_dir: Save directory path
		generation_params: Generation parameters
	
	Returns:
		Dictionary with keys: map_name -> file_path
	"""
	params = generation_params
	
	print("[Exporter] Starting map export to: ", output_dir)
	
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
	var climate_result = _export_climate_maps_optimized(gpu, output_dir)
	for key in climate_result.keys():
		exported_files[key] = climate_result[key]
	
	# === EXPORT EAUX (Step 2.5) - Classification des masses d'eau ===
	var water_result = _export_water_classification(gpu, output_dir, width, height)
	for key in water_result.keys():
		exported_files[key] = water_result[key]
	
	# === EXPORT RÉGIONS (Step 4) - Régions administratives ===
	var region_result = _export_region_map(gpu, output_dir)
	for key in region_result.keys():
		exported_files[key] = region_result[key]
	
	# === EXPORT RÉGIONS OCÉANIQUES (Step 4.5) ===
	var ocean_region_result = _export_ocean_region_map(gpu, output_dir)
	for key in ocean_region_result.keys():
		exported_files[key] = ocean_region_result[key]
	
	# === EXPORT BIOMES (Step 4.1) ===
	var biome_result = _export_biome_map(gpu, output_dir)
	for key in biome_result.keys():
		exported_files[key] = biome_result[key]
	
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
	
	# Vérifier si la planète a une atmosphère (pas d'eau sur planètes sans atmosphère)
	var atmosphere_type = int(params.get("planet_type", 0))
	var has_water = (atmosphere_type != 3)  # 3 = Sans atmosphère
	
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
func _export_region_map(gpu: GPUContext, output_dir: String, optimised_region_generation : bool = true) -> Dictionary:
	print("[Exporter] 🗺️ Exporting region map (optimized RGBA8 direct)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	var tex_id = "region_colored"
	var filename = "region_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'region_colored' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for region texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (RGBA8 = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for region map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image directement à partir des données
	var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create region image")
		return result

	if not optimised_region_generation:
		# Fusion des régions de taille 1 avec des voisins
		var land_color = Color(0x16 / 255.0, 0x1a / 255.0, 0x1f / 255.0)  # 0x161a1f
		img = _merge_isolated_regions(img, width, height, land_color)
	
	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = img.save_png(filepath)
	
	if err == OK:
		result[tex_id] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
	else:
		push_error("[Exporter] ❌ Failed to save region map: ", err)
	
	print("[Exporter] ✅ Region export complete")
	return result

## Exporte ocean_region_colored (RGBA8) en PNG
## Identique à _export_region_map mais pour les régions océaniques
##
## @param gpu: Instance GPUContext avec la texture ocean_region_colored
## @param output_dir: Dossier de sortie
## @return Dictionary: Chemin du fichier exporté
func _export_ocean_region_map(gpu: GPUContext, output_dir: String, optimised_region_generation : bool = true) -> Dictionary:
	print("[Exporter] 🌊 Exporting ocean region map (optimized RGBA8 direct)...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU avant lecture
	rd.submit()
	rd.sync()
	
	var tex_id = "ocean_region_colored"
	var filename = "ocean_region_map.png"
	
	if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
		print("  ⚠️ Texture 'ocean_region_colored' non disponible, skip")
		return result
	
	# Lecture directe des données RGBA8 depuis le GPU
	var data = rd.texture_get_data(gpu.textures[tex_id], 0)
	
	if data.size() == 0:
		push_error("[Exporter] ❌ Empty data for ocean region texture")
		return result
	
	# Récupérer les dimensions depuis le format de texture
	var tex_format = rd.texture_get_format(gpu.textures[tex_id])
	var width = tex_format.width
	var height = tex_format.height
	
	# Vérifier la taille des données (RGBA8 = 4 bytes par pixel)
	var expected_size = width * height * 4
	if data.size() != expected_size:
		push_error("[Exporter] ❌ Data size mismatch for ocean region map: expected ", 
			expected_size, ", got ", data.size())
		return result
	
	# Créer l'image directement à partir des données
	var img = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	
	if not img:
		push_error("[Exporter] ❌ Failed to create ocean region image")
		return result
	
	if not optimised_region_generation:
		# Fusion des régions de taille 1 avec des voisins
		var ocean_color = Color(0x2a / 255.0, 0x2a / 255.0, 0x2a / 255.0)  # 0x2a2a2a
		img = _merge_isolated_regions(img, width, height, ocean_color)

	# Sauvegarder en PNG
	var filepath = output_dir + "/" + filename
	var err = img.save_png(filepath)
	
	if err == OK:
		result[tex_id] = filepath
		print("  ✅ Saved: ", filepath, " (", width, "x", height, ", direct RGBA8)")
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
							
							# RGB = couleur * intensité, Alpha = intensité
							var color = Color(
								base_color.r * intensity,
								base_color.g * intensity,
								base_color.b * intensity,
								intensity
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
# ÉTAPE 2.5 : EXPORT CLASSIFICATION DES EAUX
# ============================================================================

## Couleurs pour les types d'eau (nouvelle classification eau salée/douce)
const WATER_TYPE_COLORS = {
	0: Color(0, 0, 0, 0),           # NONE - Transparent (terre)
	1: Color(0.02, 0.1, 0.3),       # SALTWATER - Bleu très foncé (#05194d)
	2: Color(0.4, 0.9, 1.0),        # FRESHWATER - Cyan très clair (#66e6ff)
}

## Noms des types d'eau pour debug
const WATER_TYPE_NAMES = [
	"Terre",
	"Eau salée",
	"Eau douce"
]

## Exporte les cartes de classification des eaux.
##
## Génère :
## - eaux_map.png : Carte colorée eau salée/douce (sans rivières)
## - river_map.png : Carte de flux des rivières (séparée)
##
## @param gpu: Instance GPUContext avec les textures d'eau
## @param output_dir: Dossier de sortie
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @return Dictionary: Chemins des fichiers exportés
func _export_water_classification(gpu: GPUContext, output_dir: String, width: int, height: int) -> Dictionary:
	print("[Exporter] 💧 Exporting water classification maps...")
	
	var result = {}
	var rd = gpu.rd
	
	if not rd:
		push_error("[Exporter] ❌ RenderingDevice not available")
		return result
	
	# Synchroniser le GPU
	rd.submit()
	rd.sync()
	
	# === EXPORT WATER_MASK (R8UI) - Carte eaux_map.png ===
	if gpu.textures.has("water_mask") and gpu.textures["water_mask"].is_valid():
		var mask_data = rd.texture_get_data(gpu.textures["water_mask"], 0)
		
		if mask_data.size() > 0:
			# Créer l'image de sortie
			var water_colored = Image.create(width, height, false, Image.FORMAT_RGBA8)
			
			# Compteurs pour statistiques
			var type_counts = [0, 0, 0]
			
			# Parcourir les données R8UI (1 byte par pixel)
			for y in range(height):
				for x in range(width):
					var idx = y * width + x
					var water_type = mask_data.decode_u8(idx)
					
					# Limiter au nombre de types connus
					water_type = mini(water_type, 2)
					type_counts[water_type] += 1
					
					# Couleur selon le type
					var color = WATER_TYPE_COLORS.get(water_type, Color(0, 0, 0, 0))
					water_colored.set_pixel(x, y, color)
			
			# Afficher statistiques
			print("  Water type distribution:")
			for i in range(3):
				if type_counts[i] > 0:
					var percent = 100.0 * type_counts[i] / (width * height)
					print("    - ", WATER_TYPE_NAMES[i], ": ", type_counts[i], " (", "%.2f" % percent, "%)")
			
			# Sauvegarder la carte colorée
			var path_colored = output_dir + "/eaux_map.png"
			var err_colored = water_colored.save_png(path_colored)
			if err_colored == OK:
				result["eaux_map"] = path_colored
				print("  ✅ Saved: ", path_colored)
			else:
				push_error("[Exporter] ❌ Failed to save eaux_map: ", err_colored)
		else:
			print("  ⚠️ water_mask texture empty")
	else:
		print("  ⚠️ water_mask texture not available")
	
	# === EXPORT RIVER_FLUX (R32F) - Carte river_map.png ===
	if gpu.textures.has("river_flux") and gpu.textures["river_flux"].is_valid():
		var flux_data = rd.texture_get_data(gpu.textures["river_flux"], 0)
		
		if flux_data.size() > 0:
			# Trouver le flux maximum pour normalisation
			var max_flux = 0.0
			var non_zero_count = 0
			
			for y in range(height):
				for x in range(width):
					var idx = (y * width + x) * 4
					var flux = flux_data.decode_float(idx)
					if flux > 0.0:
						non_zero_count += 1
						max_flux = maxf(max_flux, flux)
			
			print("  River flux stats:")
			print("    - Non-zero pixels: ", non_zero_count, " / ", width * height)
			print("    - Max flux: ", max_flux)
			
			if max_flux < 0.001:
				print("  ⚠️ No significant river flux detected")
				max_flux = 1.0  # Éviter division par zéro
			
			# Seuil minimum pour dessiner une rivière (basé sur le flux max)
			var flux_threshold = max_flux * 0.01  # 1% du flux max
			
			# Créer l'image du flux
			var river_map = Image.create(width, height, false, Image.FORMAT_RGBA8)
			var river_pixel_count = 0
			
			for y in range(height):
				for x in range(width):
					var idx = (y * width + x) * 4
					var flux = flux_data.decode_float(idx)
					
					if flux > flux_threshold:
						river_pixel_count += 1
						# Normaliser avec courbe logarithmique pour meilleur contraste
						var normalized = log(1.0 + flux) / log(1.0 + max_flux)
						normalized = clampf(normalized, 0.0, 1.0)
						
						# Couleur bleu avec intensité variable
						# Plus le flux est fort, plus la rivière est large/visible
						var color = Color(
							0.1 + 0.1 * normalized,
							0.3 + 0.4 * normalized,
							0.6 + 0.4 * normalized,
							0.6 + 0.4 * normalized
						)
						river_map.set_pixel(x, y, color)
					else:
						river_map.set_pixel(x, y, Color(0, 0, 0, 0))
			
			print("    - River pixels drawn: ", river_pixel_count)
			
			var path_river = output_dir + "/river_map.png"
			var err_river = river_map.save_png(path_river)
			if err_river == OK:
				result["river_map"] = path_river
				print("  ✅ Saved: ", path_river)
			else:
				push_error("[Exporter] ❌ Failed to save river_map: ", err_river)
		else:
			print("  ⚠️ river_flux texture empty")
	else:
		print("  ⚠️ river_flux texture not available")
	
	print("[Exporter] ✅ Water export complete: ", result.size(), " maps")
	return result

## Fusionne les régions isolées (taille 1) avec leurs voisins les plus fréquents
##
## Pour chaque pixel qui n'a AUCUN voisin de sa couleur, remplit récursivement
## tous les pixels voisins avec sa propre couleur (flood-fill).
##
## @param img: Image source (modifiée)
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @param ignore_color: Couleur à ignorer (terre pour régions, océan pour régions océaniques)
## @return Image: Image avec régions isolées fusionnées
func _merge_isolated_regions(img: Image, width: int, height: int, ignore_color: Color) -> Image:
	print("  • Fusion des régions isolées (flood-fill récursif)...")
	
	# Voisinage 4-connecté (nord, ouest, est, sud)
	var neighbors = [
		Vector2i(0, -1),   # Nord
		Vector2i(-1, 0),   # Ouest
		Vector2i(1, 0),    # Est
		Vector2i(0, 1)     # Sud
	]
	
	var total_filled = 0
	
	for y in range(height):
		for x in range(width):
			var my_color = img.get_pixel(x, y)
			
			# Ignorer les pixels de la couleur à ignorer (terre/océan)
			if _colors_equal(my_color, ignore_color):
				continue
			
			# Vérifier si ce pixel a au moins un voisin de sa couleur
			var has_same_neighbor = false
			var neighbor_colors = {}
			
			for offset in neighbors:
				var nx = (x + offset.x + width) % width  # Wrap X
				var ny = clampi(y + offset.y, 0, height - 1)  # Clamp Y
				
				var neighbor_color = img.get_pixel(nx, ny)
				
				# Ignorer la couleur interdite
				if _colors_equal(neighbor_color, ignore_color):
					continue
				
				# Vérifier si même couleur que le pixel
				if _colors_equal(neighbor_color, my_color):
					has_same_neighbor = true
					break
				
				# Compter les occurrences de chaque couleur voisine
				var color_key = _color_to_key(neighbor_color)
				if neighbor_colors.has(color_key):
					neighbor_colors[color_key].count += 1
				else:
					neighbor_colors[color_key] = {"color": neighbor_color, "count": 1}
			
			# Si pas de voisin de la même couleur
			if not has_same_neighbor:
				# Vérifier s'il y a 2 voisins ou plus avec la même couleur
				var should_stop = false
				for color_data in neighbor_colors.values():
					if color_data.count >= 2:
						# Adopter cette couleur au lieu de faire le flood-fill
						img.set_pixel(x, y, color_data.color)
						total_filled += 1
						should_stop = true
						break
				
				# Si pas de couleur dominante (>=2 voisins), faire le flood-fill
				if not should_stop:
					var filled = _flood_fill_neighbors(img, x, y, my_color, ignore_color, width, height, neighbors)
					total_filled += filled
	
	print("    Fusion terminée : ", total_filled, " pixels colorés")
	return img

## Remplit récursivement tous les pixels voisins (non-ignore_color) avec fill_color
##
## @param img: Image à modifier
## @param x: Position X du pixel source
## @param y: Position Y du pixel source
## @param fill_color: Couleur à appliquer
## @param ignore_color: Couleur à ne pas toucher
## @param width: Largeur de l'image
## @param height: Hauteur de l'image
## @param neighbors: Liste des offsets de voisinage
## @return int: Nombre de pixels colorés
func _flood_fill_neighbors(img: Image, x: int, y: int, fill_color: Color, ignore_color: Color, width: int, height: int, neighbors: Array) -> int:
	var filled_count = 0
	var to_fill = []  # Pile pour flood-fill itératif (éviter stack overflow)
	var visited = {}  # Dictionnaire pour éviter de revisiter les mêmes pixels
	
	# Ajouter tous les voisins directs à la pile
	for offset in neighbors:
		var nx = (x + offset.x + width) % width  # Wrap X
		var ny = clampi(y + offset.y, 0, height - 1)  # Clamp Y
		
		var key = str(nx) + "," + str(ny)
		if not visited.has(key):
			to_fill.append(Vector2i(nx, ny))
			visited[key] = true
	
	# Flood-fill itératif
	while to_fill.size() > 0:
		var pos = to_fill.pop_back()
		var current_color = img.get_pixel(pos.x, pos.y)
		
		# Ignorer si c'est la couleur interdite ou déjà la bonne couleur
		if _colors_equal(current_color, ignore_color) or _colors_equal(current_color, fill_color):
			continue
		
		# Colorier ce pixel
		img.set_pixel(pos.x, pos.y, fill_color)
		filled_count += 1
		
		# Ajouter les voisins à la pile
		for offset in neighbors:
			var nx = (pos.x + offset.x + width) % width  # Wrap X
			var ny = clampi(pos.y + offset.y, 0, height - 1)  # Clamp Y
			
			var key = str(nx) + "," + str(ny)
			if not visited.has(key):
				to_fill.append(Vector2i(nx, ny))
				visited[key] = true
	
	return filled_count

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
