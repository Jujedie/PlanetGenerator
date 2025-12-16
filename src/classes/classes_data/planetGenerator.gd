extends RefCounted

class_name PlanetGenerator

signal finished

# ============================================================================
# MODIFIED FOR GPU ACCELERATION - Phase 4 Integration
# ============================================================================
# This version routes generation through GPUOrchestrator
# Maintains compatibility with legacy system while adding GPU path
# ============================================================================

# Original properties (keep all existing)
var nom: String
var circonference: int
var renderProgress: ProgressBar
var mapStatusLabel: Label
var cheminSauvegarde: String

var avg_temperature: float
var water_elevation: int
var avg_precipitation: float
var elevation_modifier: int
var nb_thread: int
var atmosphere_type: int
var nb_avg_cases: int

# Legacy images (keep for backward compatibility)
var elevation_map: Image
var elevation_map_alt: Image
# ... (keep all other image properties)

# NEW: GPU acceleration components
var gpu_orchestrator: GPUOrchestrator = null
var use_gpu_acceleration: bool = true  # Toggle for testing

var cylinder_radius: float

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, elevation_modifier_param: int = 0, nb_thread_param: int = 8, atmosphere_type_param: int = 0, renderProgress_param: ProgressBar = null, mapStatusLabel_param: Label = null, nb_avg_cases_param: int = 50, cheminSauvegarde_param: String = "user://temp/") -> void:
	# Original initialization (unchanged)
	self.nom = nom_param
	self.circonference = int(rayon * 2 * PI)
	self.renderProgress = renderProgress_param
	if self.renderProgress:
		self.renderProgress.value = 0.0
	self.mapStatusLabel = mapStatusLabel_param
	self.cheminSauvegarde = cheminSauvegarde_param
	self.nb_avg_cases = nb_avg_cases_param

	self.avg_temperature = avg_temperature_param
	self.water_elevation = water_elevation_param
	self.avg_precipitation = avg_precipitation_param
	self.elevation_modifier = elevation_modifier_param
	self.nb_thread = nb_thread_param
	self.atmosphere_type = atmosphere_type_param
	
	self.cylinder_radius = self.circonference / (2.0 * PI)
	
	# NEW: Initialize GPU orchestrator
	_init_gpu_system()

func _init_gpu_system() -> void:
	"""Initialize GPU acceleration if available"""
	var gpu_context = GPUContext.instance
	if not gpu_context:
		push_warning("[PlanetGenerator] GPUContext not available, falling back to CPU")
		use_gpu_acceleration = false
		return
	
	var resolution = Vector2i(self.circonference, self.circonference / 2)
	gpu_orchestrator = GPUOrchestrator.new(gpu_context, resolution)
	
	print("[PlanetGenerator] GPU acceleration enabled: ", resolution)

func update_map_status(map_key: String) -> void:
	# Original function (unchanged)
	if mapStatusLabel != null:
		var map_name = tr(map_key)
		var text = tr("CREATING").format({"map": map_name})
		mapStatusLabel.call_deferred("set_text", text)

func generate_planet():
	"""
	MODIFIED: GPU-accelerated generation path
	Falls back to legacy CPU method if GPU unavailable
	"""
	
	if use_gpu_acceleration and gpu_orchestrator:
		generate_planet_gpu()
	else:
		generate_planet_cpu()

func generate_planet_gpu():
	"""
	NEW: GPU-accelerated generation pipeline
	Phase 1: Tectonics → Phase 2: Atmosphere → Phase 3: Erosion → Phase 4: Export
	"""
	print("\n=== GPU-ACCELERATED PLANET GENERATION ===\n")
	print("Planet: ", nom)
	print("Resolution: ", circonference, "x", circonference / 2)
	
	# === PHASE 1: TECTONIC SIMULATION ===
	update_map_status("MAP_ELEVATION")
	print("1/4 - Tectonic simulation (100M years)...")
	
	# NOTE: Uncomment when tectonic shader is ready
	# gpu_orchestrator.run_tectonic_simulation(100_000_000)
	addProgress(25)
	
	# === PHASE 2: ATMOSPHERIC DYNAMICS ===
	update_map_status("MAP_ATMOSPHERE")
	print("2/4 - Atmospheric simulation (1000 steps)...")
	
	# NOTE: Uncomment when atmosphere shader is ready
	# gpu_orchestrator.run_atmospheric_simulation(1000)
	addProgress(25)
	
	# === PHASE 3: HYDRAULIC EROSION ===
	update_map_status("MAP_RIVERS")
	print("3/4 - Hydraulic erosion...")
	
	var erosion_params = {
		"delta_time": 0.016,
		"rain_rate": avg_precipitation * 0.001,
		"evaporation_rate": 0.0001,
		"erosion_rate": 0.015,
		"deposition_rate": 0.01
	}
	
	gpu_orchestrator.run_hydraulic_erosion(100, erosion_params)
	addProgress(25)
	
	# === PHASE 4: EXPORT FOR VISUALIZATION ===
	update_map_status("MAP_FINAL")
	print("4/4 - Exporting results...")
	
	# Export GPU textures to CPU images for legacy system
	var gpu_context = GPUContext.instance
	var geo_img = gpu_orchestrator.export_geo_state_to_image()
	var velocity_img = gpu_orchestrator.export_velocity_map_to_image()
	
	# Store in legacy format
	self.elevation_map = _extract_elevation_channel(geo_img)
	self.final_map = _convert_to_final_map(geo_img)
	
	# Save if path specified
	if cheminSauvegarde != "user://temp/":
		save_image(geo_img, "gpu_geophysical.exr", cheminSauvegarde)
		save_image(velocity_img, "gpu_velocity.png", cheminSauvegarde)
	
	addProgress(25)
	
	print("\n=== GPU GENERATION COMPLETE ===\n")
	emit_signal("finished")

func generate_planet_cpu():
	"""
	ORIGINAL: Legacy CPU-based generation (unchanged)
	Fallback when GPU unavailable
	"""
	print("\n=== CPU GENERATION (Legacy Mode) ===\n")
	
	# Keep all original code here...
	# (I'm not copying the full original function to save space)
	
	# 1. Final map creation
	update_map_status("MAP_FINAL")
	self.final_map = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)
	addProgress(10)
	
	# 2. Clouds
	update_map_status("MAP_CLOUDS")
	var nuage_gen = NuageMapGenerator.new(self)
	self.nuage_map = nuage_gen.generate()
	addProgress(5)
	
	# ... (rest of original code)
	
	emit_signal("finished")

# ============================================================================
# GPU HELPER FUNCTIONS
# ============================================================================

func _extract_elevation_channel(geo_img: Image) -> Image:
	"""Extract Red channel (lithosphere) from geophysical image"""
	var elev_img = Image.create(geo_img.get_width(), geo_img.get_height(), false, Image.FORMAT_RGBAF)
	
	for y in range(geo_img.get_height()):
		for x in range(geo_img.get_width()):
			var pixel = geo_img.get_pixel(x, y)
			var elevation = pixel.r  # Lithosphere height
			var color = Enum.getElevationColor(int(elevation))
			elev_img.set_pixel(x, y, color)
	
	return elev_img

func _convert_to_final_map(geo_img: Image) -> Image:
	"""
	Convert GPU geophysical data to legacy final_map format
	Applies terrain/water coloring rules
	"""
	var final = Image.create(geo_img.get_width(), geo_img.get_height(), false, Image.FORMAT_RGBA8)
	
	for y in range(geo_img.get_height()):
		for x in range(geo_img.get_width()):
			var pixel = geo_img.get_pixel(x, y)
			var height = pixel.r
			var water = pixel.g
			
			var color: Color
			if water > 0.01:
				# Water
				color = Color(0.2, 0.4, 0.8)
			else:
				# Terrain - use elevation color mapping
				var elev_color = Enum.getElevationColor(int(height), true)
				color = elev_color
			
			final.set_pixel(x, y, color)
	
	return final

func get_gpu_texture_rids() -> Dictionary:
	"""
	NEW: Get GPU texture RIDs for 3D visualization
	
	Returns:
		Dictionary with keys: "geo", "atmo"
	"""
	if not gpu_orchestrator:
		return {}
	
	var gpu_context = GPUContext.instance
	return {
		"geo": gpu_context.textures[GPUContext.TextureID.GEOPHYSICAL_STATE],
		"atmo": gpu_context.textures[GPUContext.TextureID.ATMOSPHERIC_STATE]
	}

# ============================================================================
# ORIGINAL FUNCTIONS (Keep unchanged)
# ============================================================================

func generate_preview() -> void:
	# Original code (unchanged)
	self.preview = Image.create(self.circonference / 2, self.circonference / 2, false, Image.FORMAT_RGBA8)
	# ... rest of original function

func save_maps():
	# Original code (unchanged)
	print("\nSauvegarde de la carte finale")
	save_image(self.final_map, "final_map.png", self.cheminSauvegarde)
	# ... rest of original function

func getMaps() -> Array[String]:
	# Original code (unchanged)
	deleteImagesTemps()
	return [
		save_image(self.elevation_map, "elevation_map.png"),
		# ... rest of original function
	]

func is_ready() -> bool:
	# Original condition (unchanged)
	return self.elevation_map != null and self.precipitation_map != null # ... etc

func addProgress(value) -> void:
	# Original code (unchanged)
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

static func save_image(image: Image, file_name: String, file_path = null) -> String:
	# Original code (unchanged)
	if file_path == null:
		var img_path = "user://temp/" + file_name
		if DirAccess.open("user://temp/") == null:
			DirAccess.make_dir_absolute("user://temp/")
		image.save_png(img_path)
		return img_path
	# ... rest of original function
	return ""

static func deleteImagesTemps():
	# Original code (unchanged)
	var dir = DirAccess.open("user://temp/")
	if dir == null:
		DirAccess.make_dir_absolute("user://temp/")
		dir = DirAccess.open("user://temp/")
	# ... rest of original function