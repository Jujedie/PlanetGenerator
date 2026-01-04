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
	
	for map_type in gpu.textures.keys():
		if not gpu.textures[map_type]:
			push_error("[Exporter] ❌ Missing texture for map type: ", map_type)
			return {}

	var geo_format = rd.texture_get_format(gpu.textures["geo"])
	var width = geo_format.width
	var height = geo_format.height
	
	print("[Exporter] Detected texture size: ", width, "x", height)
	
	var maps : Dictionary[String, PackedByteArray] = {}
	# Read GPU textures
	for map in gpu.textures.keys():
		print("[Exporter] Reading texture for map type: ", map)
		var data = rd.texture_get_data(gpu.textures[map], 0)
		maps[map] = data
	
	# Validate data size based on DETECTED dimensions
	var expected_size = width * height * 16  # RGBAF32 = 16 bytes/pixel
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
	
	# Parcourir chaque pixel et convertir l'élévation en couleur
	for y in range(height):
		for x in range(width):
			# Lire les données brutes de la GeoTexture
			var geo_pixel = geo_img.get_pixel(x, y)
			var elevation_meters = geo_pixel.r  # Élévation en mètres (float)
			var water_height = geo_pixel.a       # Colonne d'eau
			
			# Convertir l'élévation float en entier (arrondi)
			var elevation_int = int(round(elevation_meters))
			
			# Obtenir les couleurs via Enum.gd
			var color_colored = Enum.getElevationColor(elevation_int, false)
			var color_grey = Enum.getElevationColor(elevation_int, true)
			
			# Écrire les pixels
			elevation_colored.set_pixel(x, y, color_colored)
			elevation_grey.set_pixel(x, y, color_grey)
			
			# Water mask : bleu si eau, transparent sinon
			if water_height > 0.0:
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
## - G = border_dist (distance au bord de plaque)
## - B = plate_elevation (élévation de base du plateau)
## - A = is_oceanic (1.0 si océanique, 0.0 si continental)
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
			var border_dist = plate_pixel.g
			var is_oceanic = plate_pixel.a > 0.5
			
			# Couleur de la plaque
			var color = plate_colors[plate_id % plate_colors.size()]
			
			# Assombrir les plaques océaniques
			if is_oceanic:
				color = color.darkened(0.3)
			
			plates_colored.set_pixel(x, y, color)
			
			# Carte des bordures : VRAIE LIGNE FINE
			# border_dist < 0.005 = bordure visible (ligne très fine)
			if border_dist < 0.005:
				var border_intensity = 1.0 - (border_dist / 0.005)
				plates_borders.set_pixel(x, y, Color(border_intensity, border_intensity * 0.5, 0.0, 1.0))
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
# HELPER FUNCTIONS
# ============================================================================

## Calcule la pente locale (gradient) en un point donné.
##
## Utilitaire mathématique utilisé lors de la détermination des biomes (ex: distinction entre
## "Plaine herbeuse" et "Falaise rocheuse").
## Utilise les voisins immédiats (x+1, y+1) de la heightmap pour calculer la normale.
##
## @param x: Coordonnée X du pixel.
## @param y: Coordonnée Y du pixel.
## @return float: Valeur de la pente (0.0 = plat, 1.0 = vertical).
func _calculate_slope(img: Image, x: int, y: int) -> float:
	"""
	Calculate terrain slope at given pixel
	"""
	var width = img.get_width()
	var height = img.get_height()
	
	var h_center = img.get_pixel(x, y).r
	
	# Sample neighbors with wrapping
	var x_left = (x - 1 + width) % width
	var x_right = (x + 1) % width
	var y_top = clamp(y - 1, 0, height - 1)
	var y_bottom = clamp(y + 1, 0, height - 1)
	
	var h_left = img.get_pixel(x_left, y).r
	var h_right = img.get_pixel(x_right, y).r
	var h_top = img.get_pixel(x, y_top).r
	var h_bottom = img.get_pixel(x, y_bottom).r
	
	# Calculate gradients
	var dx = (h_right - h_left) / 2.0
	var dy = (h_bottom - h_top) / 2.0
	
	# Return magnitude of gradient
	return sqrt(dx * dx + dy * dy)