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
func export_maps(rids: Dictionary[String,RID], output_dir: String, generation_params: Dictionary) -> Dictionary:
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
	var gpu_context = GPUContext.instance
	if not gpu_context:
		push_error("[Exporter] GPUContext not available!")
		return {}
	
	var rd = gpu_context.rd
	
	# Ensure GPU work is complete before reading
	rd.submit()
	rd.sync()
	
	for map_type in rids.keys():
		if not rids[map_type]:
			push_error("[Exporter] ❌ Missing RID for map type: ", map_type)
			return {}

	var geo_format = rd.texture_get_format(rids["geo"])
	var width = geo_format.width
	var height = geo_format.height
	
	print("[Exporter] Detected texture size: ", width, "x", height)
	
	var maps : Dictionary[String, PackedByteArray] = {}
	# Read GPU textures
	for map in rids.keys():
		print("[Exporter] Reading texture for map type: ", map)
		var data = rd.texture_get_data(rids[map], 0)
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
	
	exported_files["elevation"] = _export_elevation_map(imgs["geo"], output_dir, false)
	exported_files["elevation_alt"] = _export_elevation_map(imgs["geo"], output_dir, true)
	
	print("[Exporter] Export complete: ", exported_files.size(), " maps")
	return exported_files

# ============================================================================
# INDIVIDUAL MAP EXPORTERS
# ============================================================================

## Extrait la carte topographique depuis le GPU.
##
## @return Image: L'image en niveaux de gris représentant le relief.
func _export_elevation_map(geo_img: Image, output_dir: String, grayscale: bool = false) -> String:
	"""
	Export elevation map using enum.gd color palette
	Blue for water, terrain colors for land
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	var sea_level = params.get("sea_level", 0.0)
	
	for y in range(height):
		for x in range(width):
			var pixel = geo_img.get_pixel(x, y)
			# Récupérer l'élévation
			var elevation = -1 # Placeholder
			
			var color: Color
			
			color = Enum.getElevationColor(int(elevation), grayscale)
			
			output.set_pixel(x, y, color)
	
	var filename = "elevation_map_alt.png" if grayscale else "elevation_map.png"
	var path = output_dir.path_join(filename)
	output.save_png(path)
	print("  ✓ Saved: ", filename)
	return path

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