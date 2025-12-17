extends RefCounted

class_name PlanetGenerator

signal finished
signal progress_updated(value: float, status: String)

## ============================================================================
## PLANET GENERATOR - FINAL INTEGRATION
## ============================================================================
## Main controller that connects UI → GPU → Export
## Maintains backward compatibility with legacy CPU generation
## ============================================================================

# Constants
const BASE_EROSION_ITERATIONS = 100
const BASE_TECTONIC_YEARS     = 100_000_000
const BASE_ATMOSPHERE_STEPS   = 1000

# Original properties (unchanged)
var nom             : String
var circonference   : int
var renderProgress  : ProgressBar
var mapStatusLabel  : Label
var cheminSauvegarde: String

var avg_temperature   : float
var water_elevation   : int
var avg_precipitation : float
var elevation_modifier: int
var nb_thread         : int
var atmosphere_type   : int
var nb_avg_cases      : int

# Legacy images (for backward compatibility)
var elevation_map    : Image
var elevation_map_alt: Image
var precipitation_map: Image
var temperature_map  : Image
var region_map       : Image
var water_map        : Image
var banquise_map     : Image
var biome_map        : Image
var oil_map          : Image
var ressource_map    : Image
var nuage_map        : Image
var river_map        : Image
var final_map        : Image
var preview          : Image

# GPU acceleration components
var gpu_orchestrator: GPUOrchestrator = null
var use_gpu_acceleration: bool

# Generation parameters (compiled from UI)
var generation_params: Dictionary = {}

var cylinder_radius: float

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, elevation_modifier_param: int = 0, nb_thread_param: int = 8, atmosphere_type_param: int = 0, renderProgress_param: ProgressBar = null, mapStatusLabel_param: Label = null, nb_avg_cases_param: int = 50, cheminSauvegarde_param: String = "user://temp/", use_gpu_acceleration_param: bool = true) -> void:
	
	# Store all parameters
	self.nom            = nom_param
	self.circonference  = int(rayon * 2 * PI)
	self.renderProgress = renderProgress_param
	if self.renderProgress:
		self.renderProgress.value = 0.0
	
	self.mapStatusLabel   = mapStatusLabel_param
	self.cheminSauvegarde = cheminSauvegarde_param
	self.nb_avg_cases     = nb_avg_cases_param
	
	self.avg_temperature    = avg_temperature_param
	self.water_elevation    = water_elevation_param
	self.avg_precipitation  = avg_precipitation_param
	self.elevation_modifier = elevation_modifier_param
	self.nb_thread          = nb_thread_param
	self.atmosphere_type    = atmosphere_type_param
	
	self.cylinder_radius      = self.circonference / (2.0 * PI)
	self.use_gpu_acceleration = use_gpu_acceleration_param
	
	# Compile generation parameters
	_compile_generation_params()
	
	# Initialize GPU system
	_init_gpu_system()

func _compile_generation_params() -> void:
	"""
	Compile all generation parameters into a single dictionary
	This is passed to the GPU orchestrator and shaders
	"""
	
	randomize()
	generation_params = {
		"seed": randi(),
		"planet_name": nom,
		"planet_radius": circonference / (2.0 * PI),
		"resolution": Vector2i(circonference, circonference / 2),
		"avg_temperature": avg_temperature,
		"sea_level": float(water_elevation),
		"avg_precipitation": avg_precipitation,
		"elevation_modifier": float(elevation_modifier),
		"atmosphere_type": atmosphere_type,
		"nb_thread": nb_thread,
		"nb_avg_cases": nb_avg_cases,
		"erosion_iterations": BASE_EROSION_ITERATIONS,
		"tectonic_years": BASE_TECTONIC_YEARS,
		"atmosphere_steps": BASE_ATMOSPHERE_STEPS
	}
	
	print("[PlanetGenerator] Parameters compiled:")
	print("  Seed: ", generation_params["seed"])
	print("  Temperature: ", generation_params["avg_temperature"], "°C")
	print("  Sea Level: ", generation_params["sea_level"], "m")
	print("  Precipitation: ", generation_params["avg_precipitation"])

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
	"""Update UI status label"""
	if mapStatusLabel != null:
		var map_name = tr(map_key)
		var text = tr("CREATING").format({"map": map_name})
		mapStatusLabel.call_deferred("set_text", text)
	
	emit_signal("progress_updated", renderProgress.value if renderProgress else 0.0, map_key)

func addProgress(value: float) -> void:
	"""Update progress bar"""
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

# ============================================================================
# MAIN GENERATION ENTRY POINT
# ============================================================================

## ============================================================================
## GPU GENERATION - RENDER THREAD SAFE VERSION
## ============================================================================

func generate_planet():
	"""
	Entry point - routes to GPU or CPU
	GPU path now uses call_deferred for render thread safety
	"""
	
	if use_gpu_acceleration and gpu_orchestrator:
		print("[PlanetGenerator] Starting GPU generation (render thread)...")
		# Call on render thread instead of worker thread
		call_deferred("_generate_planet_gpu_deferred")
	else:
		print("[PlanetGenerator] Starting CPU generation...")
		generate_planet_cpu()

func _generate_planet_gpu_deferred():
	"""
	GPU generation executed on render thread
	Called via call_deferred from generate_planet()
	"""
	
	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION (RENDER THREAD)")
	print("=".repeat(60))
	
	# === PHASE 1: FULL SIMULATION ===
	update_map_status("MAP_ELEVATION")
	print("Phase 1/4 - Running GPU simulation...")
	
	# Execute simulation synchronously on render thread
	gpu_orchestrator.run_simulation(generation_params)
	addProgress(60)
	
	# === PHASE 2: EXPORT MAPS ===
	update_map_status("MAP_FINAL")
	print("Phase 2/4 - Exporting maps...")
	
	_export_gpu_maps()
	addProgress(20)
	
	# === PHASE 3: UPDATE 2D ===
	update_map_status("MAP_PREVIEW")
	print("Phase 3/4 - Updating 2D...")
	
	# Update 2D preview image from GPU textures
	addProgress(10)
	
	# === PHASE 4: FINALIZE ===
	addProgress(10)
	
	print("=".repeat(60))
	print("GENERATION COMPLETE")
	print("=".repeat(60) + "\n")
	
	emit_signal("finished")

# ============================================================================
# GPU GENERATION PIPELINE
# ============================================================================

func generate_planet_gpu():
	"""
	GPU-accelerated generation pipeline
	Phase 1: Initialize → Phase 2: Simulate → Phase 3: Export → Phase 4: Visualize
	"""
	
	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION")
	print("=".repeat(60))
	print("Planet: ", nom)
	print("Resolution: ", generation_params["resolution"])
	print("Seed: ", generation_params["seed"])
	print("=".repeat(60) + "\n")
	
	# === PHASE 1: FULL SIMULATION ===
	update_map_status("MAP_ELEVATION")
	print("Phase 1/4 - Running full GPU simulation...")
	
	gpu_orchestrator.run_simulation(generation_params)
	addProgress(60)
	
	# === PHASE 2: EXPORT MAPS ===
	update_map_status("MAP_FINAL")
	print("Phase 2/4 - Exporting maps...")
	
	_export_gpu_maps()
	addProgress(20)
	
	# === PHASE 3: UPDATE 2D ===
	update_map_status("MAP_PREVIEW")
	print("Phase 3/4 - Updating 2D preview image...")
	
	# Update 2D preview image from GPU textures
	addProgress(10)
	
	# === PHASE 4: FINALIZE ===
	print("Phase 4/4 - Finalizing...")
	addProgress(10)
	
	print("\n" + "=".repeat(60))
	print("GENERATION COMPLETE")
	print("Total time: ", Time.get_ticks_msec() / 1000.0, " seconds")
	print("=".repeat(60) + "\n")
	
	emit_signal("finished")

func _export_gpu_maps() -> void:
	"""
	Export GPU textures to PNG files using PlanetExporter
	"""
	
	var gpu_context = GPUContext.instance
	
	# CRITICAL: Ensure all GPU work is complete
	gpu_context.rd.submit()
	gpu_context.rd.sync()
	
		
	var geo_rid = gpu_orchestrator.geo_state_texture
	var atmo_rid = gpu_orchestrator.atmo_state_texture
	
	# Validate texture RIDs
	if not geo_rid.is_valid() or not atmo_rid.is_valid():
		push_error("[PlanetGenerator] Invalid texture RIDs for export")
		return
	
	print("[PlanetGenerator] Exporting textures...")
	print("  Geo RID: ", geo_rid)
	print("  Atmo RID: ", atmo_rid)
	
	# Create exporter and export all maps
	var exporter = PlanetExporter.new()
	var exported_files = exporter.export_maps(geo_rid, atmo_rid, "user://temp/", generation_params)
	
	# Load exported images into legacy properties
	for map_type in exported_files:
		var file_path = exported_files[map_type]
		var img = Image.new()
		
		if img.load(file_path) == OK:
			match map_type:
				"elevation":
					self.elevation_map = img
				"elevation_alt":
					self.elevation_map_alt = img
				"water":
					self.water_map = img
				"river":
					self.river_map = img
				"temperature":
					self.temperature_map = img
				"precipitation":
					self.precipitation_map = img
				"biome":
					self.biome_map = img
				"cloud":
					self.nuage_map = img
				"final":
					self.final_map = img
				"preview":
					self.preview = img
			
			print("[PlanetGenerator] Loaded ", map_type, ": ", img.get_width(), "x", img.get_height())
		else:
			push_warning("[PlanetGenerator] Failed to load ", map_type, " from ", file_path)
	
	print("[PlanetGenerator] Maps exported to user://temp/")

# ============================================================================
# LEGACY CPU GENERATION (Fallback)
# ============================================================================

func generate_planet_cpu():
	"""
	Original CPU-based generation pipeline
	Maintained for fallback compatibility
	"""
	
	print("\n=== CPU GENERATION (Legacy Mode) ===\n")
	
	# Original generation code
	update_map_status("MAP_FINAL")
	self.final_map = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)
	addProgress(10)
	
	update_map_status("MAP_CLOUDS")
	var nuage_gen = NuageMapGenerator.new(self)
	self.nuage_map = nuage_gen.generate()
	addProgress(5)
	
	update_map_status("MAP_ELEVATION")
	var elevation_gen = ElevationMapGenerator.new(self)
	self.elevation_map = elevation_gen.generate()
	self.elevation_map_alt = elevation_gen.get_elevation_map_alt()
	addProgress(10)
	
	update_map_status("MAP_PRECIPITATION")
	var precipitation_gen = PrecipitationMapGenerator.new(self)
	self.precipitation_map = precipitation_gen.generate()
	addProgress(10)
	
	update_map_status("MAP_WATER")
	var water_gen = WaterMapGenerator.new(self)
	self.water_map = water_gen.generate()
	addProgress(10)
	
	update_map_status("MAP_OIL")
	var oil_gen = OilMapGenerator.new(self)
	self.oil_map = oil_gen.generate()
	addProgress(5)
	
	update_map_status("MAP_RESOURCES")
	var ressource_gen = RessourceMapGenerator.new(self)
	self.ressource_map = ressource_gen.generate()
	addProgress(5)
	
	update_map_status("MAP_TEMPERATURE")
	var temperature_gen = TemperatureMapGenerator.new(self)
	self.temperature_map = temperature_gen.generate()
	addProgress(10)
	
	update_map_status("MAP_RIVERS")
	var river_gen = RiverMapGenerator.new(self)
	self.river_map = river_gen.generate()
	addProgress(5)
	
	update_map_status("MAP_ICE")
	var banquise_gen = BanquiseMapGenerator.new(self)
	self.banquise_map = banquise_gen.generate()
	addProgress(5)
	
	update_map_status("MAP_REGIONS")
	var region_gen = RegionMapGenerator.new(self)
	self.region_map = region_gen.generate()
	addProgress(10)
	
	update_map_status("MAP_BIOMES")
	var biome_gen = BiomeMapGenerator.new(self)
	self.biome_map = biome_gen.generate()
	addProgress(25)
	
	update_map_status("MAP_DONE")
	generate_preview()
	
	print("\n=== CPU GENERATION COMPLETE ===\n")
	emit_signal("finished")

# ============================================================================
# PUBLIC API FOR EXTERNAL COMPONENTS
# ============================================================================

func get_gpu_texture_rids() -> Dictionary:
	"""
	Get GPU texture RIDs for direct 3D binding
	
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

func export_to_directory(output_dir: String) -> void:
	"""
	Export all maps to specified directory
	Called from master.gd when Export button is pressed
	"""
	
	print("[PlanetGenerator] Exporting to: ", output_dir)
	
	if use_gpu_acceleration and gpu_orchestrator:
		# GPU path - use PlanetExporter
		var geo_rid = gpu_orchestrator.geo_state_texture
		var atmo_rid = gpu_orchestrator.atmo_state_texture
		
		var exporter = PlanetExporter.new()
		exporter.export_maps(geo_rid, atmo_rid, output_dir, generation_params)
	else:
		# CPU path - use legacy save
		save_maps_to_directory(output_dir)
	
	print("[PlanetGenerator] Export complete")

func save_maps_to_directory(output_dir: String) -> void:
	"""Legacy save function for CPU-generated maps"""
	
	if not output_dir.ends_with("/"):
		output_dir += "/"
	
	if not DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	
	if self.elevation_map:
		self.elevation_map.save_png(output_dir + "elevation_map.png")
	if self.elevation_map_alt:
		self.elevation_map_alt.save_png(output_dir + "elevation_map_alt.png")
	if self.precipitation_map:
		self.precipitation_map.save_png(output_dir + "precipitation_map.png")
	if self.temperature_map:
		self.temperature_map.save_png(output_dir + "temperature_map.png")
	if self.water_map:
		self.water_map.save_png(output_dir + "water_map.png")
	if self.river_map:
		self.river_map.save_png(output_dir + "river_map.png")
	if self.biome_map:
		self.biome_map.save_png(output_dir + "biome_map.png")
	if self.oil_map:
		self.oil_map.save_png(output_dir + "oil_map.png")
	if self.ressource_map:
		self.ressource_map.save_png(output_dir + "ressource_map.png")
	if self.nuage_map:
		self.nuage_map.save_png(output_dir + "nuage_map.png")
	if self.region_map:
		self.region_map.save_png(output_dir + "region_map.png")
	if self.final_map:
		self.final_map.save_png(output_dir + "final_map.png")
	if self.preview:
		self.preview.save_png(output_dir + "preview.png")

# ============================================================================
# LEGACY FUNCTIONS (Unchanged for backward compatibility)
# ============================================================================

func generate_preview() -> void:
	"""Generate circular preview (CPU method)"""
	self.preview = Image.create(self.circonference / 2, self.circonference / 2, false, Image.FORMAT_RGBA8)
	
	var radius = self.circonference / 4
	var center = Vector2(self.circonference / 4, self.circonference / 4)
	
	for x in range(self.preview.get_width()):
		for y in range(self.preview.get_height()):
			var pos = Vector2(x, y)
			if pos.distance_to(center) <= radius:
				var base_color = self.final_map.get_pixel(x, y)
				if self.nuage_map.get_pixel(x, y) != Color.hex(0x00000000):
					var cloud_alpha = 0.7
					var cloud_color = Color(1.0, 1.0, 1.0, cloud_alpha)
					var blended = base_color.lerp(cloud_color, cloud_alpha)
					blended.a = 1.0
					self.preview.set_pixel(x, y, blended)
				else:
					self.preview.set_pixel(x, y, base_color)
			else:
				self.preview.set_pixel(x, y, Color.TRANSPARENT)

func save_maps():
	"""Legacy save to default directory"""
	save_maps_to_directory(cheminSauvegarde)

func getMaps() -> Array[String]:
	"""Get temporary map file paths for UI preview"""
	deleteImagesTemps()
	
	var temp_dir = "user://temp/"
	return [
		save_image_temp(self.elevation_map, "elevation_map.png", temp_dir),
		save_image_temp(self.elevation_map_alt, "elevation_map_alt.png", temp_dir),
		save_image_temp(self.nuage_map, "nuage_map.png", temp_dir),
		save_image_temp(self.oil_map, "oil_map.png", temp_dir),
		save_image_temp(self.ressource_map, "ressource_map.png", temp_dir),
		save_image_temp(self.precipitation_map, "precipitation_map.png", temp_dir),
		save_image_temp(self.temperature_map, "temperature_map.png", temp_dir),
		save_image_temp(self.water_map, "water_map.png", temp_dir),
		save_image_temp(self.river_map, "river_map.png", temp_dir),
		save_image_temp(self.biome_map, "biome_map.png", temp_dir),
		save_image_temp(self.final_map, "final_map.png", temp_dir),
		save_image_temp(self.region_map, "region_map.png", temp_dir),
		save_image_temp(self.preview, "preview.png", temp_dir)
	]

func is_ready() -> bool:
	"""Check if all maps are generated"""
	return (self.elevation_map != null and 
			self.precipitation_map != null and 
			self.temperature_map != null and 
			self.water_map != null and 
			self.river_map != null and 
			self.biome_map != null and 
			self.final_map != null and 
			self.region_map != null and 
			self.nuage_map != null and 
			self.oil_map != null and 
			self.banquise_map != null and 
			self.preview != null)

static func save_image_temp(image: Image, file_name: String, temp_dir: String) -> String:
	"""Save image to temporary directory"""
	if not image:
		return ""
	
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	var path = temp_dir + file_name
	image.save_png(path)
	return path

static func deleteImagesTemps():
	"""Clear temporary directory"""
	var dir = DirAccess.open("user://temp/")
	if dir == null:
		DirAccess.make_dir_absolute("user://temp/")
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
