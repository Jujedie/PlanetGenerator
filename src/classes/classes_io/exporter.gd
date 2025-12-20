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

func export_maps(geo_rid: RID, atmo_rid: RID, output_dir: String, generation_params: Dictionary) -> Dictionary:
	"""
	Export all map types from GPU textures to PNG files
	
	Args:
		geo_rid: Geophysical state texture
		atmo_rid: Atmospheric state texture
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
	
	# ✅ CORRECTION : Récupérer les dimensions RÉELLES de la texture
	if not geo_rid.is_valid() or not atmo_rid.is_valid():
		push_error("[Exporter] ❌ Invalid texture RIDs provided")
		return {}

	var geo_format = rd.texture_get_format(geo_rid)
	var width = geo_format.width
	var height = geo_format.height
	
	print("[Exporter] Detected texture size: ", width, "x", height)
	
	# Read GPU textures
	var geo_data = rd.texture_get_data(geo_rid, 0)
	var atmo_data = rd.texture_get_data(atmo_rid, 0)
	
	print("[Exporter] Geo data size: ", geo_data.size(), " bytes")
	
	# Validate data size based on DETECTED dimensions
	var expected_size = width * height * 16  # RGBAF32 = 16 bytes/pixel
	if geo_data.size() != expected_size:
		push_error("[Exporter] ❌ Invalid geo data size: ", geo_data.size(), " (expected ", expected_size, ")")
		return {}
	
	# Create images from raw data
	var geo_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, geo_data)
	var atmo_img = Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, atmo_data)
	
	# Export all map types
	var exported_files = {}
	
	exported_files["elevation"] = _export_elevation_map(geo_img, output_dir, false)
	exported_files["elevation_alt"] = _export_elevation_map(geo_img, output_dir, true)
	exported_files["water"] = _export_water_map(geo_img, output_dir)
	exported_files["river"] = _export_river_map(geo_img, atmo_img, output_dir)
	exported_files["temperature"] = _export_temperature_map(atmo_img, output_dir)
	exported_files["precipitation"] = _export_precipitation_map(atmo_img, output_dir)
	exported_files["biome"] = _export_biome_map(geo_img, atmo_img, output_dir)
	exported_files["cloud"] = _export_cloud_map(atmo_img, output_dir)
	exported_files["final"] = _export_final_map(geo_img, atmo_img, output_dir)
	exported_files["preview"] = _export_preview_map(geo_img, atmo_img, output_dir)
	
	print("[Exporter] Export complete: ", exported_files.size(), " maps")
	return exported_files

# ============================================================================
# INDIVIDUAL MAP EXPORTERS
# ============================================================================

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
			var elevation = pixel.r  # Lithosphere height
			var water = pixel.g      # Water depth
			
			var color: Color
			
			if water > 0.01:
				# Underwater - use water colors
				color = Color(0.145, 0.322, 0.541) if not grayscale else Color(0.1, 0.1, 0.1)
			else:
				# Land - use Enum elevation colors
				color = Enum.getElevationColor(int(elevation), grayscale)
			
			output.set_pixel(x, y, color)
	
	var filename = "elevation_map_alt.png" if grayscale else "elevation_map.png"
	var path = output_dir.path_join(filename)
	output.save_png(path)
	print("  ✓ Saved: ", filename)
	return path

func _export_water_map(geo_img: Image, output_dir: String) -> String:
	"""
	Binary water map (white = water, black = land)
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var pixel = geo_img.get_pixel(x, y)
			var water = pixel.g
			
			var color = Color.WHITE if water > 0.01 else Color.BLACK
			output.set_pixel(x, y, color)
	
	var path = output_dir.path_join("water_map.png")
	output.save_png(path)
	print("  ✓ Saved: water_map.png")
	return path

func _export_river_map(geo_img: Image, atmo_img: Image, output_dir: String) -> String:
	"""
	River map - detect high flow areas using sediment transport
	Rivers appear where water + velocity + slope are significant
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	output.fill(Color(0, 0, 0, 0))  # Transparent background
	
	var planet_type = params.get("atmosphere_type", 0)
	
	for y in range(height):
		for x in range(width):
			var geo_pixel = geo_img.get_pixel(x, y)
			var atmo_pixel = atmo_img.get_pixel(x, y)
			
			var water = geo_pixel.g
			var sediment = geo_pixel.b
			var temperature = atmo_pixel.r
			var humidity = atmo_pixel.g
			
			# River detection: water present + sediment transport + sufficient precipitation
			var is_river = false
			var river_size = 0
			
			if water > 0.05 and water < 10.0:  # Not ocean, but has water
				# Calculate local slope (simplified)
				var slope = _calculate_slope(geo_img, x, y)
				
				# River criteria: water flow + precipitation + slope
				if sediment > 5.0 and humidity > 0.3 and slope > 0.001:
					is_river = true
					
					# Determine river size based on water volume
					if water > 2.0 and sediment > 20.0:
						river_size = 2  # Fleuve
					elif water > 0.5:
						river_size = 1  # Rivière
					else:
						river_size = 0  # Affluent
			
			if is_river:
				# Use enum.gd river biome colors
				var river_biome = Enum.getRiverBiomeBySize(int(temperature - 273.0), planet_type, river_size)
				if river_biome:
					output.set_pixel(x, y, river_biome.get_couleur())
				else:
					# Fallback color based on size
					match river_size:
						0: output.set_pixel(x, y, Color(0.42, 0.67, 0.90))  # Light blue
						1: output.set_pixel(x, y, Color(0.29, 0.56, 0.85))  # Medium blue
						2: output.set_pixel(x, y, Color(0.24, 0.50, 0.77))  # Dark blue
	
	var path = output_dir.path_join("river_map.png")
	output.save_png(path)
	print("  ✓ Saved: river_map.png")
	return path

func _export_temperature_map(atmo_img: Image, output_dir: String) -> String:
	"""
	Temperature map using enum.gd color palette
	"""
	
	var width = atmo_img.get_width()
	var height = atmo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var pixel = atmo_img.get_pixel(x, y)
			var temperature_kelvin = pixel.r
			var temperature_celsius = temperature_kelvin - 273.15
			
			var color = Enum.getTemperatureColor(temperature_celsius)
			output.set_pixel(x, y, color)
	
	var path = output_dir.path_join("temperature_map.png")
	output.save_png(path)
	print("  ✓ Saved: temperature_map.png")
	return path

func _export_precipitation_map(atmo_img: Image, output_dir: String) -> String:
	"""
	Precipitation map using enum.gd color palette
	"""
	
	var width = atmo_img.get_width()
	var height = atmo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var pixel = atmo_img.get_pixel(x, y)
			var humidity = pixel.g  # Use humidity as precipitation proxy
			
			var color = Enum.getPrecipitationColor(humidity)
			output.set_pixel(x, y, color)
	
	var path = output_dir.path_join("precipitation_map.png")
	output.save_png(path)
	print("  ✓ Saved: precipitation_map.png")
	return path

func _export_biome_map(geo_img: Image, atmo_img: Image, output_dir: String) -> String:
	"""
	Biome map using Whittaker diagram + enum.gd biomes
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	var planet_type = params.get("atmosphere_type", 0)
	var sea_level = params.get("sea_level", 0.0)
	
	for y in range(height):
		for x in range(width):
			var geo_pixel = geo_img.get_pixel(x, y)
			var atmo_pixel = atmo_img.get_pixel(x, y)
			
			var elevation = geo_pixel.r
			var water = geo_pixel.g
			var temperature_kelvin = atmo_pixel.r
			var humidity = atmo_pixel.g
			
			var is_water = water > 0.01
			var temperature_celsius = int(temperature_kelvin - 273.15)
			
			# Get biome from enum.gd (using existing logic)
			var biome_noise = (sin(x * 0.1) + cos(y * 0.1)) * 0.5 + 0.5  # Simple noise
			var biome = Enum.getBiomeByNoise(
				planet_type,
				int(elevation),
				humidity,
				temperature_celsius,
				is_water,
				biome_noise
			)
			
			if biome:
				output.set_pixel(x, y, biome.get_couleur())
			else:
				output.set_pixel(x, y, Color.MAGENTA)  # Error color
	
	var path = output_dir.path_join("biome_map.png")
	output.save_png(path)
	print("  ✓ Saved: biome_map.png")
	return path

func _export_cloud_map(atmo_img: Image, output_dir: String) -> String:
	"""
	Cloud map (white = clouds, transparent = clear)
	"""
	
	var width = atmo_img.get_width()
	var height = atmo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var pixel = atmo_img.get_pixel(x, y)
			var cloud_density = pixel.a  # Cloud data in alpha channel
			
			if cloud_density > 0.15:
				var alpha = clamp((cloud_density - 0.15) * 1.5, 0.0, 1.0)
				output.set_pixel(x, y, Color(1, 1, 1, alpha))
			else:
				output.set_pixel(x, y, Color(0, 0, 0, 0))
	
	var path = output_dir.path_join("nuage_map.png")
	output.save_png(path)
	print("  ✓ Saved: nuage_map.png")
	return path

func _export_final_map(geo_img: Image, atmo_img: Image, output_dir: String) -> String:
	"""
	Final composite map - terrain colored by elevation with vegetation tint
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var output = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	var planet_type = params.get("atmosphere_type", 0)
	
	for y in range(height):
		for x in range(width):
			var geo_pixel = geo_img.get_pixel(x, y)
			var atmo_pixel = atmo_img.get_pixel(x, y)
			
			var elevation = geo_pixel.r
			var water = geo_pixel.g
			var temperature_kelvin = atmo_pixel.r
			var humidity = atmo_pixel.g
			
			var is_water = water > 0.01
			var temperature_celsius = int(temperature_kelvin - 273.15)
			
			# Get base elevation color
			var base_color = Enum.getElevationColor(int(elevation), true)
			
			# Get biome for vegetation tint
			var biome_noise = (sin(x * 0.1) + cos(y * 0.1)) * 0.5 + 0.5
			var biome = Enum.getBiomeByNoise(
				planet_type,
				int(elevation),
				humidity,
				temperature_celsius,
				is_water,
				biome_noise
			)
			
			var final_color: Color
			if biome:
				# Multiply elevation color by biome vegetation color
				var veg_color = biome.get_couleur_vegetation()
				final_color = base_color * veg_color
			else:
				final_color = base_color
			
			final_color.a = 1.0
			output.set_pixel(x, y, final_color)
	
	var path = output_dir.path_join("final_map.png")
	output.save_png(path)
	print("  ✓ Saved: final_map.png")
	return path

func _export_preview_map(geo_img: Image, atmo_img: Image, output_dir: String) -> String:
	"""
	Preview map - circular projection with clouds
	"""
	
	var width = geo_img.get_width()
	var height = geo_img.get_height()
	var preview_size = width / 2
	var output = Image.create(preview_size, preview_size, false, Image.FORMAT_RGBA8)
	output.fill(Color(0, 0, 0, 0))
	
	var center = Vector2(preview_size / 2, preview_size / 2)
	var radius = preview_size / 2
	
	for y in range(preview_size):
		for x in range(preview_size):
			var pos = Vector2(x, y)
			var dist = pos.distance_to(center)
			
			if dist <= radius:
				# Map to equirectangular coordinates
				var nx = x
				var ny = y
				
				# Sample final map
				var geo_pixel = geo_img.get_pixel(nx, ny)
				var atmo_pixel = atmo_img.get_pixel(nx, ny)
				
				var elevation = geo_pixel.r
				var base_color = Enum.getElevationColor(int(elevation), true)
				
				# Add clouds
				var cloud_density = atmo_pixel.a
				if cloud_density > 0.15:
					var cloud_alpha = clamp((cloud_density - 0.15) * 1.5, 0.0, 0.7)
					base_color = base_color.lerp(Color.WHITE, cloud_alpha)
				
				output.set_pixel(x, y, base_color)
	
	var path = output_dir.path_join("preview.png")
	output.save_png(path)
	print("  ✓ Saved: preview.png")
	return path

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

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