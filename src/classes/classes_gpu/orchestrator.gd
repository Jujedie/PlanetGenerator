extends RefCounted
class_name GPUOrchestrator

var gpu: GPUContext
var rd: RenderingDevice

# Textures
var geo_state_texture: RID
var atmo_state_texture: RID
var flux_map_texture: RID
var velocity_map_texture: RID

# Pipelines
var tectonic_pipeline: RID
var atmosphere_pipeline: RID
var erosion_pipeline: RID
var orogeny_pipeline: RID
var region_pipeline: RID

# Uniform Sets
var tectonic_uniform_set: RID
var atmosphere_uniform_set: RID
var erosion_uniform_set: RID
var orogeny_uniform_set: RID
var region_uniform_set: RID

var resolution: Vector2i
var dt: float = 0.016

# ============================================================================
# INITIALISATION (CORRIGÉE)
# ============================================================================

func _init(gpu_context: GPUContext, res: Vector2i = Vector2i(2048, 1024)):
	gpu = gpu_context
	rd = gpu.rd
	resolution = res
	
	print("[Orchestrator] 🚀 Initialisation...")
	
	# 1. Créer les textures
	_init_textures()
	
	# 2. Compiler et créer les pipelines
	if not _compile_and_create_pipelines():
		push_error("[Orchestrator] ❌ ÉCHEC CRITIQUE: Impossible de créer les pipelines")
		return
	
	# 3. Créer les uniform sets
	_init_uniform_sets()
	
	print("[Orchestrator] ✅ Initialisé avec résolution : ", resolution)

# ============================================================================
# CHARGEMENT ROBUSTE DES SHADERS
# ============================================================================

func _compile_and_create_pipelines() -> bool:
	"""
	Charge et compile tous les shaders nécessaires.
	Retourne false si au moins un shader critique échoue.
	"""
	
	print("[Orchestrator] 📦 Compilation des shaders...")
	
	var shaders_to_load = [
		{
			"path": "res://shader/compute/tectonic_shader.glsl",
			"name": "tectonic",
			"critical": false  # Optionnel
		},
		{
			"path": "res://shader/compute/atmosphere_shader.glsl",
			"name": "atmosphere",
			"critical": false
		},
		{
			"path": "res://shader/compute/hydraulic_erosion_shader.glsl",
			"name": "erosion",
			"critical": true  # OBLIGATOIRE
		},
		{
			"path": "res://shader/compute/orogeny_shader.glsl",
			"name": "orogeny",
			"critical": false
		},
		{
			"path": "res://shader/compute/region_voronoi_shader.glsl",
			"name": "region",
			"critical": false
		}
	]
	
	var all_critical_loaded = true
	
	for shader_info in shaders_to_load:
		var path = shader_info["path"]
		var name = shader_info["name"]
		var is_critical = shader_info["critical"]
		
		print("  • Chargement: ", name)
		
		# Vérifier existence du fichier
		if not FileAccess.file_exists(path):
			var msg = "[Orchestrator] ❌ Fichier shader introuvable: " + path
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# Charger via GPUContext
		if not gpu.load_compute_shader(path, name):
			var msg = "[Orchestrator] ❌ Échec compilation: " + name
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# Créer le pipeline
		var shader_rid = gpu.shaders[name]
		var pipeline_rid = rd.compute_pipeline_create(shader_rid)
		
		if not pipeline_rid.is_valid():
			var msg = "[Orchestrator] ❌ Échec création pipeline: " + name
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# Assigner au membre approprié
		match name:
			"tectonic":
				tectonic_pipeline = pipeline_rid
			"atmosphere":
				atmosphere_pipeline = pipeline_rid
			"erosion":
				erosion_pipeline = pipeline_rid
			"orogeny":
				orogeny_pipeline = pipeline_rid
			"region":
				region_pipeline = pipeline_rid
		
		print("    ✅ ", name, " OK")
	
	if not all_critical_loaded:
		push_error("[Orchestrator] ❌ Au moins un shader critique n'a pas pu être chargé")
		return false
	
	print("[Orchestrator] ✅ Tous les shaders critiques sont prêts")
	return true

# ============================================================================
# INITIALISATION DES TEXTURES
# ============================================================================

func _init_textures():
	"""
	Create GPU textures with initial data
	Must be called from render thread
	"""
	
	var fmt = RDTextureFormat.new()
	fmt.width = resolution.x
	fmt.height = resolution.y
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Create zero-initialized data
	var size = resolution.x * resolution.y * 4 * 4  # RGBA32F = 16 bytes
	var zero_data = PackedByteArray()
	zero_data.resize(size)
	zero_data.fill(0)
	
	# Create textures with initial data (safe on render thread)
	geo_state_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	atmo_state_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	flux_map_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	velocity_map_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	
	print("[Orchestrator] Textures créées (4x ", size / 1024, " KB)")

# ============================================================================
# INITIALISATION DES UNIFORM SETS
# ============================================================================

func _init_uniform_sets():
	"""Initialize uniform sets with validation"""
	
	# Create texture uniforms
	var texture_uniforms = [
		gpu.create_texture_uniform(0, geo_state_texture),
		gpu.create_texture_uniform(1, atmo_state_texture),
		gpu.create_texture_uniform(2, flux_map_texture),
		gpu.create_texture_uniform(3, velocity_map_texture)
	]
	
	# Only create uniform sets for valid pipelines
	if tectonic_pipeline.is_valid():
		tectonic_uniform_set = rd.uniform_set_create(texture_uniforms, tectonic_pipeline, 0)
		if not tectonic_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create tectonic uniform set")
	else:
		push_warning("[Orchestrator] ⚠️ Skipping tectonic uniform set (invalid pipeline)")
	
	if atmosphere_pipeline.is_valid():
		atmosphere_uniform_set = rd.uniform_set_create(texture_uniforms, atmosphere_pipeline, 0)
		if not atmosphere_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create atmosphere uniform set")
	else:
		push_warning("[Orchestrator] ⚠️ Skipping atmosphere uniform set (invalid pipeline)")
	
	if erosion_pipeline.is_valid():
		erosion_uniform_set = rd.uniform_set_create(texture_uniforms, erosion_pipeline, 0)
		if not erosion_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion uniform set")
	else:
		push_error("[Orchestrator] ❌ Erosion uniform set requis mais pipeline invalide!")
	
	if orogeny_pipeline.is_valid():
		orogeny_uniform_set = rd.uniform_set_create(texture_uniforms, orogeny_pipeline, 0)
	
	if region_pipeline.is_valid():
		region_uniform_set = rd.uniform_set_create(texture_uniforms, region_pipeline, 0)
	
	print("[Orchestrator] ✓ Uniform Sets initialized")

# ============================================================================
# SIMULATION COMPLÈTE
# ============================================================================

func run_simulation(generation_params: Dictionary) -> void:
	print("\n" + "=".repeat(60))
	print("[Orchestrator] 🌍 DÉMARRAGE SIMULATION COMPLÈTE")
	print("=".repeat(60))
	print("  Seed: ", generation_params.get("seed", 0))
	print("  Température: ", generation_params.get("avg_temperature", 15.0), "°C")
	print("  Résolution: ", resolution)
	
	# Phase 1: Initialisation du terrain
	_initialize_terrain(generation_params)
	
	# Phase 2: Érosion hydraulique (100 itérations)
	var erosion_iters = generation_params.get("erosion_iterations", 100)
	run_hydraulic_erosion(erosion_iters, generation_params)
	
	# Phase 3: Orogenèse (si disponible)
	if orogeny_pipeline.is_valid():
		run_orogeny(generation_params)
	else:
		push_warning("[Orchestrator] ⚠️ Orogeny shader non disponible, étape ignorée")
	
	# Phase 4: Génération des régions (si disponible)
	if region_pipeline.is_valid():
		run_region_generation(generation_params)
	else:
		push_warning("[Orchestrator] ⚠️ Region shader non disponible, étape ignorée")
	
	print("=".repeat(60))
	print("[Orchestrator] ✅ SIMULATION TERMINÉE")
	print("=".repeat(60) + "\n")

# ============================================================================
# PHASE 1: INITIALISATION DU TERRAIN
# ============================================================================

func _initialize_terrain(params: Dictionary) -> void:
	"""
	Initialize geophysical texture with seed-based noise
	NOW SAFE: Only calls texture operations on render thread
	"""
	
	var seed_value = params.get("seed", 0)
	var elevation_modifier = params.get("elevation_modifier", 0.0)
	var sea_level = params.get("sea_level", 0.0)
	
	print("[Orchestrator] 🏔️ Initialisation du terrain (Seed: ", seed_value, ")")
	
	# Generate initial data on CPU
	var noise = FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 2.0 / float(resolution.x)
	noise.fractal_octaves = 8
	
	var init_data = PackedFloat32Array()
	init_data.resize(resolution.x * resolution.y * 4)
	
	for y in range(resolution.y):
		for x in range(resolution.x):
			var idx = (y * resolution.x + x) * 4
			
			# Generate height using noise
			var nx = float(x) / float(resolution.x)
			var ny = float(y) / float(resolution.y)
			var height = noise.get_noise_2d(nx * 100, ny * 100) * 5000.0 + elevation_modifier
			
			# Pack into RGBA
			init_data[idx + 0] = height                          # R = Lithosphere
			init_data[idx + 1] = max(0.0, sea_level - height)   # G = Water
			init_data[idx + 2] = 0.0                             # B = Sediment
			init_data[idx + 3] = 0.5                             # A = Hardness
	
	# ✅ SAFE: This method works on render thread
	# Create new texture with data instead of updating
	var fmt = rd.texture_get_format(geo_state_texture)
	var new_texture = rd.texture_create(fmt, RDTextureView.new(), [init_data.to_byte_array()])
	
	# Free old, assign new
	rd.free_rid(geo_state_texture)
	geo_state_texture = new_texture
	
	# Recreate uniform sets with new texture
	_init_uniform_sets()
	
	print("[Orchestrator] ✅ Terrain initialisé")

# ============================================================================
# PHASE 2: ÉROSION HYDRAULIQUE
# ============================================================================

func run_hydraulic_erosion(iterations: int = 10, custom_params: Dictionary = {}):
	"""Execute hydraulic erosion cycle"""
	
	# CRITICAL: Check if erosion pipeline is ready
	if not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] Erosion pipeline not ready - skipping")
		return
	
	print("[Orchestrator] 🌊 Érosion hydraulique: ", iterations, " itérations")
	
	# Default parameters
	var params = {
		"delta_time": custom_params.get("delta_time", 0.016),
		"pipe_area": custom_params.get("pipe_area", 1.0),
		"pipe_length": custom_params.get("pipe_length", 1.0),
		"gravity": custom_params.get("gravity", 9.81),
		"rain_rate": custom_params.get("rain_rate", 0.001),
		"evaporation_rate": custom_params.get("evaporation_rate", 0.0001),
		"sediment_capacity_k": custom_params.get("sediment_capacity_k", 0.1),
		"erosion_rate": custom_params.get("erosion_rate", 0.01),
		"deposition_rate": custom_params.get("deposition_rate", 0.01),
		"min_height_delta": custom_params.get("min_height_delta", 0.001)
	}
	
	# Calculate work groups (8x8 local size)
	var groups_x = ceili(resolution.x / 8.0)
	var groups_y = ceili(resolution.y / 8.0)
	
	for i in range(iterations):
		# Step 0: Rain
		_dispatch_erosion_step(0, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 1: Flux calculation
		_dispatch_erosion_step(1, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 2: Water update
		_dispatch_erosion_step(2, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 3: Erosion/Deposition
		_dispatch_erosion_step(3, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		if i % 10 == 0:
			print("  Itération ", i, "/", iterations)
	
	# Final sync
	rd.submit()
	rd.sync()
	
	print("[Orchestrator] ✅ Érosion terminée")

func _dispatch_erosion_step(step: int, params: Dictionary, groups_x: int, groups_y: int):
	"""Dispatch erosion shader with validation"""
	
	# CRITICAL: Check if pipeline and uniform set are valid
	if not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] Cannot dispatch - invalid pipeline/uniform set")
		return
	
	# Create parameter buffer
	var param_data = PackedFloat32Array([
		float(step),
		params["delta_time"],
		params["pipe_area"],
		params["pipe_length"],
		params["gravity"],
		params["rain_rate"],
		params["evaporation_rate"],
		params["sediment_capacity_k"],
		params["erosion_rate"],
		params["deposition_rate"],
		params["min_height_delta"],
		0.0  # Padding
	])
	
	var param_buffer = rd.storage_buffer_create(param_data.to_byte_array().size(), param_data.to_byte_array())
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], erosion_pipeline, 1)
	
	# Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, erosion_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, erosion_uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	# Cleanup
	rd.free_rid(param_buffer)

# ============================================================================
# PHASE 3: OROGENÈSE
# ============================================================================

func run_orogeny(params: Dictionary):
	"""Accentuation des montagnes (optionnel)"""
	
	if not orogeny_pipeline.is_valid():
		return
	
	print("[Orchestrator] ⛰️ Orogenèse (accentuation des montagnes)")
	
	var groups_x = ceili(resolution.x / 8.0)
	var groups_y = ceili(resolution.y / 8.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, orogeny_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, orogeny_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	print("[Orchestrator] ✅ Orogenèse terminée")

# ============================================================================
# PHASE 4: GÉNÉRATION DE RÉGIONS
# ============================================================================

func run_region_generation(params: Dictionary):
	"""Génération de régions Voronoi (optionnel)"""
	
	if not region_pipeline.is_valid():
		return
	
	print("[Orchestrator] 🗺️ Génération des régions (Voronoi)")
	
	var num_seeds = params.get("nb_avg_cases", 50)
	var seed_value = params.get("seed", 0)
	
	# Créer buffer de seeds aléatoires
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	
	var seed_data = PackedVector2Array()
	for i in range(num_seeds):
		seed_data.append(Vector2(
			rng.randf_range(0.0, float(resolution.x)),
			rng.randf_range(0.0, float(resolution.y))
		))
	
	var seed_buffer = rd.storage_buffer_create(seed_data.to_byte_array().size(), seed_data.to_byte_array())
	var seed_uniform = RDUniform.new()
	seed_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	seed_uniform.binding = 1
	seed_uniform.add_id(seed_buffer)
	
	var region_set = rd.uniform_set_create([seed_uniform], region_pipeline, 1)
	
	var groups_x = ceili(resolution.x / 8.0)
	var groups_y = ceili(resolution.y / 8.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, region_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, region_uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, region_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	rd.free_rid(seed_buffer)
	
	print("[Orchestrator] ✅ Régions générées")

# ============================================================================
# EXPORT
# ============================================================================

func export_geo_state_to_image() -> Image:
	var byte_data = rd.texture_get_data(geo_state_texture, 0)
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)

func export_velocity_map_to_image() -> Image:
	var byte_data = rd.texture_get_data(velocity_map_texture, 0)
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)

# ============================================================================
# CLEANUP
# ============================================================================

func cleanup():
	rd.free_rid(geo_state_texture)
	rd.free_rid(atmo_state_texture)
	rd.free_rid(flux_map_texture)
	rd.free_rid(velocity_map_texture)
	if tectonic_pipeline.is_valid():
		rd.free_rid(tectonic_pipeline)
	if atmosphere_pipeline.is_valid():
		rd.free_rid(atmosphere_pipeline)
	if erosion_pipeline.is_valid():
		rd.free_rid(erosion_pipeline)
	if orogeny_pipeline.is_valid():
		rd.free_rid(orogeny_pipeline)
	if region_pipeline.is_valid():
		rd.free_rid(region_pipeline)
	print("[Orchestrator] ✅ Ressources libérées")