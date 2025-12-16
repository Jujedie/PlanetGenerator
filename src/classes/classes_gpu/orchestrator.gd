extends RefCounted
class_name GPUOrchestrator

# ============================================================================
# ORCHESTRATEUR GPU - Mise à jour Phase 3 : Érosion Hydraulique
# ============================================================================
# Ajout des textures temporaires et de la fonction run_hydraulic_erosion()
# ============================================================================

var gpu: GPUContext
var rd: RenderingDevice

# Textures principales
var geo_state_texture: RID
var atmo_state_texture: RID

# Textures temporaires pour l'érosion
var flux_map_texture: RID
var velocity_map_texture: RID

# Pipelines
var tectonic_pipeline: RID
var atmosphere_pipeline: RID
var erosion_pipeline: RID  # NOUVEAU

# Uniform Sets
var tectonic_uniform_set: RID
var atmosphere_uniform_set: RID
var erosion_uniform_set: RID  # NOUVEAU

# Paramètres
var resolution: Vector2i
var dt: float = 0.016  # 60 FPS par défaut

# ============================================================================
# INITIALISATION
# ============================================================================

func _init(gpu_context: GPUContext, res: Vector2i = Vector2i(2048, 1024)):
	gpu = gpu_context
	rd = gpu.rd
	resolution = res
	
	_init_textures()
	_init_pipelines()
	_init_uniform_sets()
	
	print("[Orchestrator] Initialisé avec résolution : ", resolution)

func _init_textures():
	# === TEXTURES PRINCIPALES ===
	var fmt = RDTextureFormat.new()
	fmt.width = resolution.x
	fmt.height = resolution.y
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	
	geo_state_texture = rd.texture_create(fmt, RDTextureView.new())
	atmo_state_texture = rd.texture_create(fmt, RDTextureView.new())
	
	# === TEXTURES TEMPORAIRES POUR L'ÉROSION ===
	flux_map_texture = rd.texture_create(fmt, RDTextureView.new())
	velocity_map_texture = rd.texture_create(fmt, RDTextureView.new())
	
	# Initialisation à zéro
	_clear_texture(flux_map_texture)
	_clear_texture(velocity_map_texture)
	
	print("[Orchestrator] Textures créées (Geo, Atmo, Flux, Velocity)")

func _clear_texture(texture_rid: RID):
	var size = resolution.x * resolution.y * 4 * 4  # RGBA32F = 16 bytes
	var zero_data = PackedByteArray()
	zero_data.resize(size)
	zero_data.fill(0)
	rd.texture_update(texture_rid, 0, zero_data)

# ============================================================================
# INITIALISATION DES PIPELINES
# ============================================================================

func _init_pipelines():
	# Pipeline Tectonique (existant)
	var tectonic_shader = gpu.load_compute_shader("res://shader/compute/tectonic_shader.glsl")
	tectonic_pipeline = rd.compute_pipeline_create(tectonic_shader)
	
	# Pipeline Atmosphérique (existant)
	var atmosphere_shader = gpu.load_compute_shader("res://shader/compute/atmosphere_shader.glsl")
	atmosphere_pipeline = rd.compute_pipeline_create(atmosphere_shader)
	
	# === NOUVEAU PIPELINE : ÉROSION HYDRAULIQUE ===
	var erosion_shader = gpu.load_compute_shader("res://shader/compute/hydraulic_erosion.glsl")
	erosion_pipeline = rd.compute_pipeline_create(erosion_shader)
	
	print("[Orchestrator] Pipelines créés (Tectonic, Atmosphere, Erosion)")

# ============================================================================
# INITIALISATION DES UNIFORM SETS
# ============================================================================

func _init_uniform_sets():
	# Set 0 : Textures (partagé entre tous les shaders)
	var texture_uniforms = [
		gpu.create_texture_uniform(0, geo_state_texture),
		gpu.create_texture_uniform(1, atmo_state_texture),
		gpu.create_texture_uniform(2, flux_map_texture),
		gpu.create_texture_uniform(3, velocity_map_texture)
	]
	
	# Note : Les pipelines tectonique/atmo n'utilisent que bindings 0-1,
	# mais on crée un set universel pour simplifier
	tectonic_uniform_set = rd.uniform_set_create(texture_uniforms, tectonic_pipeline, 0)
	atmosphere_uniform_set = rd.uniform_set_create(texture_uniforms, atmosphere_pipeline, 0)
	erosion_uniform_set = rd.uniform_set_create(texture_uniforms, erosion_pipeline, 0)
	
	print("[Orchestrator] Uniform Sets créés")

# ============================================================================
# FONCTION PRINCIPALE : ÉROSION HYDRAULIQUE
# ============================================================================

func run_hydraulic_erosion(iterations: int = 10, custom_params: Dictionary = {}):
	"""
	Exécute le cycle complet d'érosion hydraulique
	
	Args:
		iterations: Nombre d'itérations de la simulation
		custom_params: Dictionnaire optionnel pour surcharger les paramètres
			- delta_time: Pas de temps (défaut: 0.016)
			- rain_rate: Taux de pluie (défaut: 0.001)
			- erosion_rate: Taux d'érosion (défaut: 0.01)
			- etc. (voir shader pour la liste complète)
	"""
	
	print("[Orchestrator] Démarrage érosion hydraulique : ", iterations, " itérations")
	
	# Paramètres par défaut
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
	
	# Calcul des groupes de travail (8x8 local size)
	var groups_x = ceili(resolution.x / 8.0)
	var groups_y = ceili(resolution.y / 8.0)
	
	for i in range(iterations):
		# === ÉTAPE 0 : PLUIE ===
		_dispatch_erosion_step(0, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# === ÉTAPE 1 : CALCUL DES FLUX ===
		_dispatch_erosion_step(1, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# === ÉTAPE 2 : MISE À JOUR DE L'EAU & VITESSE ===
		_dispatch_erosion_step(2, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# === ÉTAPE 3 : ÉROSION/DÉPOSITION ===
		_dispatch_erosion_step(3, params, groups_x, groups_y)
		rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		if i % 10 == 0:
			print("  Itération ", i, "/", iterations, " terminée")
	
	# Synchronisation finale
	rd.submit()
	rd.sync()
	
	print("[Orchestrator] Érosion hydraulique terminée")

func _dispatch_erosion_step(step: int, params: Dictionary, groups_x: int, groups_y: int):
	"""Dispatch une étape du shader d'érosion avec les paramètres"""
	
	# Création du buffer de paramètres
	var param_data = PackedFloat32Array([
		float(step),                        # int step (casté en float)
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
		0.0  # Padding pour alignement 16 bytes
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
# FONCTIONS UTILITAIRES POUR L'EXPORT
# ============================================================================

func export_geo_state_to_image() -> Image:
	"""Exporte la texture Géophysique vers une Image Godot"""
	var byte_data = rd.texture_get_data(geo_state_texture, 0)
	var img = Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)
	return img

func export_velocity_map_to_image() -> Image:
	"""Exporte la carte de vitesse (utile pour debug)"""
	var byte_data = rd.texture_get_data(velocity_map_texture, 0)
	var img = Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)
	return img

# ============================================================================
# CLEANUP
# ============================================================================

func cleanup():
	rd.free_rid(geo_state_texture)
	rd.free_rid(atmo_state_texture)
	rd.free_rid(flux_map_texture)
	rd.free_rid(velocity_map_texture)
	rd.free_rid(tectonic_pipeline)
	rd.free_rid(atmosphere_pipeline)
	rd.free_rid(erosion_pipeline)
	print("[Orchestrator] Ressources GPU libérées")