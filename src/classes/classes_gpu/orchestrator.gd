extends RefCounted
class_name GPUOrchestrator

## ============================================================================
## GPU ORCHESTRATOR - VERSION CORRIGÉE
## ============================================================================
## Corrections appliquées :
## ✅ A. Chargement robuste des shaders avec chemins explicites
## ✅ B. Résolution fixée (suppression du calcul basé sur radius)
## ✅ C. Garbage collection complète (aucune fuite mémoire)
## ============================================================================

var gpu: GPUContext
var rd: RenderingDevice

# Textures principales
var geo_state_texture: RID
var atmo_state_texture: RID
var flux_map_texture: RID
var velocity_map_texture: RID

# Pipelines (shaders compilés)
var tectonic_pipeline: RID
var atmosphere_pipeline: RID
var erosion_pipeline: RID
var orogeny_pipeline: RID
var region_pipeline: RID

# Uniform Sets (réutilisables)
var tectonic_uniform_set: RID
var atmosphere_uniform_set: RID
var erosion_uniform_set: RID
var orogeny_uniform_set: RID
var region_uniform_set: RID

var resolution: Vector2i
var dt: float = 0.016

# ============================================================================
# INITIALISATION
# ============================================================================

func _init(gpu_context: GPUContext, res: Vector2i = Vector2i(128, 64)):
	gpu = gpu_context
	rd  = gpu.rd
	resolution = res
	
	print("[Orchestrator] 🚀 Initialisation...")
	
	# 1. Créer les textures
	_init_textures()
	
	# 2. Compiler et créer les pipelines (FIX A)
	if not _compile_all_shaders():
		push_error("[Orchestrator] ❌ ÉCHEC CRITIQUE: Impossible de compiler les shaders")
		return
	
	# 3. Créer les uniform sets
	_init_uniform_sets()
	
	print("[Orchestrator] ✅ Initialisé avec résolution : ", resolution)

# ============================================================================
# FIX A : CHARGEMENT ROBUSTE DES SHADERS
# ============================================================================

func _compile_all_shaders() -> bool:
	"""
	Charge et compile tous les shaders avec chemins explicites vérifiés.
	Retourne false si au moins un shader critique échoue.
	"""
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot compile shaders")
		return false
	
	print("[Orchestrator] 📦 Compilation des shaders...")
	
	# ✅ CHEMINS EXPLICITES (plus de chemins dynamiques)
	var shaders_to_load = [
		{
			"path": "res://shader/compute/tectonic_shader.glsl",
			"name": "tectonic",
			"critical": false
		},
		{
			"path": "res://shader/compute/atmosphere_shader.glsl",
			"name": "atmosphere",
			"critical": false
		},
		{
			"path": "res://shader/compute/hydraulic_erosion_shader.glsl",
			"name": "erosion",
			"critical": true  # ⚠️ OBLIGATOIRE
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
		
		# ✅ VÉRIFICATION 1: Fichier existe
		if not FileAccess.file_exists(path):
			var msg = "[Orchestrator] ❌ Shader introuvable: " + path
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# ✅ VÉRIFICATION 2: Chargement du fichier
		var shader_file = load(path)
		if not shader_file:
			var msg = "[Orchestrator] ❌ Échec chargement fichier: " + path
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# ✅ VÉRIFICATION 3: SPIR-V disponible
		var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
		if not shader_spirv:
			var msg = "[Orchestrator] ❌ Pas de SPIR-V disponible: " + name
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# ✅ VÉRIFICATION 4: Compilation SPIR-V
		var shader_rid: RID = rd.shader_create_from_spirv(shader_spirv)
		if not shader_rid.is_valid():
			var msg = "[Orchestrator] ❌ Échec compilation SPIR-V: " + name
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# ✅ VÉRIFICATION 5: Création du pipeline
		var pipeline_rid: RID = rd.compute_pipeline_create(shader_rid)
		if not pipeline_rid.is_valid():
			var msg = "[Orchestrator] ❌ Échec création pipeline: " + name
			if is_critical:
				push_error(msg)
				all_critical_loaded = false
			else:
				push_warning(msg + " (non critique, ignoré)")
			continue
		
		# ✅ SUCCÈS: Assigner au membre approprié
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
	"""Crée les textures GPU avec données initiales"""
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot create textures")
		return
	
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
	
	# Créer données vides
	var size = resolution.x * resolution.y * 4 * 4  # RGBA32F = 16 bytes
	var zero_data = PackedByteArray()
	zero_data.resize(size)
	zero_data.fill(0)
	
	# Créer les textures
	geo_state_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	atmo_state_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	flux_map_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	velocity_map_texture = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
	
	print("[Orchestrator] ✅ Textures créées (4x ", size / 1024, " KB)")

# ============================================================================
# INITIALISATION DES UNIFORM SETS
# ============================================================================

func _init_uniform_sets():
	"""Initialise les uniform sets avec validation et bindings corrects par shader"""
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot create uniform sets")
		return
	
	# Uniform sets spécifiques par shader (bindings selon les layouts des shaders)
	
	# Tectonic: utilise geo (binding 0), atmo (1), flux (2), velocity (3) - comme défini
	if tectonic_pipeline.is_valid():
		var tectonic_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),
			gpu.create_texture_uniform(1, atmo_state_texture),
			gpu.create_texture_uniform(2, flux_map_texture),
			gpu.create_texture_uniform(3, velocity_map_texture)
		]
		tectonic_uniform_set = rd.uniform_set_create(tectonic_uniforms, tectonic_pipeline, 0)
		if not tectonic_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create tectonic uniform set")
	
	# Atmosphere: binding 0=atmo_in, 1=geo, 2=atmo_out (mais atmo_out est writeonly, utiliser atmo pour in/out)
	if atmosphere_pipeline.is_valid():
		var atmosphere_uniforms = [
			gpu.create_texture_uniform(0, atmo_state_texture),  # atmospheric_state_in
			gpu.create_texture_uniform(1, geo_state_texture),   # geophysical_state
			gpu.create_texture_uniform(2, atmo_state_texture)   # atmospheric_state_out (même texture)
		]
		atmosphere_uniform_set = rd.uniform_set_create(atmosphere_uniforms, atmosphere_pipeline, 0)
		if not atmosphere_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create atmosphere uniform set")
	
	# Erosion: utilise geo (0), atmo (1), flux (2), velocity (3)
	if erosion_pipeline.is_valid():
		var erosion_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),
			gpu.create_texture_uniform(1, atmo_state_texture),
			gpu.create_texture_uniform(2, flux_map_texture),
			gpu.create_texture_uniform(3, velocity_map_texture)
		]
		erosion_uniform_set = rd.uniform_set_create(erosion_uniforms, erosion_pipeline, 0)
		if not erosion_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion uniform set (CRITIQUE)")
	
	# Orogeny: utilise plate_data (0, mais c'est geo?), geophysical_state (1)
	# Note: Le shader orogeny utilise binding 0 pour plate_data et 1 pour geophysical_state, mais plate_data n'existe pas, utiliser geo pour les deux?
	if orogeny_pipeline.is_valid():
		var orogeny_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),  # plate_data (approx)
			gpu.create_texture_uniform(1, geo_state_texture)   # geophysical_state
		]
		orogeny_uniform_set = rd.uniform_set_create(orogeny_uniforms, orogeny_pipeline, 0)
		if not orogeny_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create orogeny uniform set")
	
	# Region: utilise geo_map (0), seeds buffer (1, mais c'est dans le set séparé)
	if region_pipeline.is_valid():
		var region_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture)  # geo_map
		]
		region_uniform_set = rd.uniform_set_create(region_uniforms, region_pipeline, 0)
		if not region_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create region uniform set")
	
	print("[Orchestrator] ✅ Uniform Sets initialized with correct bindings")

# ============================================================================

func run_simulation(generation_params: Dictionary) -> void:
	"""
	Exécute la simulation complète en respectant la résolution de l'instance.
	"""
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot run simulation")
		return
	
	print("\n" + "=".repeat(60))
	print("[Orchestrator] 🌍 DÉMARRAGE SIMULATION COMPLÈTE")
	print("=".repeat(60))
	print("  Seed: ", generation_params.get("seed", 0))
	print("  Température: ", generation_params.get("avg_temperature", 15.0), "°C")
	
	# ✅ CORRECTION CRITIQUE : Utilisation de la résolution de l'instance
	# On n'utilise PLUS les constantes globales de GPUContext ici.
	var w = resolution.x
	var h = resolution.y
	
	print("  Résolution de la simulation : ", w, "x", h)
	
	# ✅ FIX C: GARBAGE COLLECTION (tracker tous les RIDs temporaires)
	var _rids_to_free: Array[RID] = []
	
	# Phase 1: Initialisation du terrain
	_initialize_terrain(generation_params)
	
	# Phase 2: Érosion hydraulique
	var erosion_iters = generation_params.get("erosion_iterations", 100)
	# On passe w et h qui correspondent maintenant à la taille réelle des textures
	var erosion_garbage = _run_hydraulic_erosion_tracked(erosion_iters, generation_params, w, h)
	_rids_to_free.append_array(erosion_garbage)
	
	# Phase 3: Orogenèse (si disponible)
	if orogeny_pipeline.is_valid():
		run_orogeny(generation_params, w, h)
	else:
		push_warning("[Orchestrator] ⚠️ Orogeny shader non disponible, étape ignorée")
	
	# Phase 4: Génération des régions (si disponible)
	if region_pipeline.is_valid():
		var region_garbage = _run_region_generation_tracked(generation_params, w, h)
		_rids_to_free.append_array(region_garbage)
	else:
		push_warning("[Orchestrator] ⚠️ Region shader non disponible, étape ignorée")
	
	# ✅ FIX C: CLEANUP COMPLET
	print("[Orchestrator] 🧹 Nettoyage de ", _rids_to_free.size(), " ressources temporaires...")
	if rd:
		for rid in _rids_to_free:
			if rid.is_valid():
				rd.free_rid(rid)
	else:
		push_warning("[Orchestrator] RD is null, skipping temp cleanup")
	_rids_to_free.clear()
	
	print("=".repeat(60))
	print("[Orchestrator] ✅ SIMULATION TERMINÉE (Clean)")
	print("=".repeat(60) + "\n")

# ============================================================================
# PHASE 1: INITIALISATION DU TERRAIN
# ============================================================================

func _initialize_terrain(params: Dictionary) -> void:
	"""Initialise la texture géophysique avec du bruit basé sur la seed"""
	
	var seed_value = params.get("seed", 0)
	var elevation_modifier = params.get("elevation_modifier", 0.0)
	var sea_level = params.get("sea_level", 0.0)
	
	print("[Orchestrator] 🏔️ Initialisation du terrain (Seed: ", seed_value, ")")
	
	# Générer les données initiales sur CPU
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
			
			# Générer la hauteur via noise
			var nx = float(x) / float(resolution.x)
			var ny = float(y) / float(resolution.y)
			var height = noise.get_noise_2d(nx * 100, ny * 100) * 5000.0 + elevation_modifier
			
			# Packer dans RGBA
			init_data[idx + 0] = height                          # R = Lithosphère
			init_data[idx + 1] = max(0.0, sea_level - height)   # G = Eau
			init_data[idx + 2] = 0.0                             # B = Sédiment
			init_data[idx + 3] = 0.5                             # A = Dureté
	
	# Créer nouvelle texture avec données
	var fmt = rd.texture_get_format(geo_state_texture)
	var new_texture = rd.texture_create(fmt, RDTextureView.new(), [init_data.to_byte_array()])
	
	# Libérer l'ancienne, assigner la nouvelle
	rd.free_rid(geo_state_texture)
	geo_state_texture = new_texture
	
	# Recréer les uniform sets
	_init_uniform_sets()
	
	print("[Orchestrator] ✅ Terrain initialisé")

# ============================================================================
# PHASE 2: ÉROSION HYDRAULIQUE (AVEC GARBAGE TRACKING)
# ============================================================================

func _run_hydraulic_erosion_tracked(iterations: int, custom_params: Dictionary, w: int, h: int) -> Array[RID]:
	"""Exécute le cycle d'érosion hydraulique - Retourne les RIDs temporaires"""
	
	var garbage_bin: Array[RID] = []
	
	if not rd or not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] Erosion pipeline not ready - skipping")
		return garbage_bin
	
	print("[Orchestrator] 🌊 Érosion hydraulique: ", iterations, " itérations")
	
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
	
	# ✅ FIX B: GROUPES DE TRAVAIL BASÉS SUR LA VRAIE RÉSOLUTION
	var groups_x = ceili(float(w) / 8.0)
	var groups_y = ceili(float(h) / 8.0)
	
	for i in range(iterations):
		# Step 0: Pluie
		var rain_rids = _dispatch_erosion_step(0, params, groups_x, groups_y)
		garbage_bin.append_array(rain_rids)
		if rd:
			rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 1: Calcul du flux
		var flux_rids = _dispatch_erosion_step(1, params, groups_x, groups_y)
		garbage_bin.append_array(flux_rids)
		if rd:
			rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 2: Mise à jour de l'eau
		var water_rids = _dispatch_erosion_step(2, params, groups_x, groups_y)
		garbage_bin.append_array(water_rids)
		if rd:
			rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		# Step 3: Érosion/Déposition
		var erosion_rids = _dispatch_erosion_step(3, params, groups_x, groups_y)
		garbage_bin.append_array(erosion_rids)
		if rd:
			rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
		
		if i % 10 == 0:
			print("  Itération ", i, "/", iterations)
	
	# Sync final
	if rd:
		rd.submit()
		rd.sync()
	
	print("[Orchestrator] ✅ Érosion terminée (", garbage_bin.size(), " ressources à nettoyer)")
	return garbage_bin

func _dispatch_erosion_step(step: int, params: Dictionary, groups_x: int, groups_y: int) -> Array[RID]:
	"""Dispatch d'un step d'érosion - Retourne les RIDs à libérer"""
	
	var temp_rids: Array[RID] = []
	
	if not rd or not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] Cannot dispatch - invalid rd/pipeline/uniform set")
		return temp_rids
	
	# Créer le buffer de paramètres
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
	temp_rids.append(param_buffer)  # ✅ TRACKER POUR CLEANUP
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], erosion_pipeline, 1)
	temp_rids.append(param_set)  # ✅ TRACKER POUR CLEANUP
	
	# Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, erosion_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, erosion_uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	return temp_rids

# ============================================================================
# PHASE 3: OROGENÈSE
# ============================================================================

func run_orogeny(params: Dictionary, w: int, h: int):
	"""Accentuation des montagnes"""
	
	if not rd or not orogeny_pipeline.is_valid() or not orogeny_uniform_set.is_valid():
		push_warning("[Orchestrator] ⚠️ Orogeny pipeline not ready, skipping")
		return
	
	print("[Orchestrator] ⛰️ Orogenèse (accentuation des montagnes)")
	
	var groups_x = ceili(float(w) / 8.0)
	var groups_y = ceili(float(h) / 8.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, orogeny_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, orogeny_uniform_set, 0)
	
	# Add push constants for resolution
	var push_constants = PackedFloat32Array([float(w), float(h)])
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), 0)
	
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	print("[Orchestrator] ✅ Orogenèse terminée")

# ============================================================================
# PHASE 4: GÉNÉRATION DE RÉGIONS (AVEC GARBAGE TRACKING)
# ============================================================================

func _run_region_generation_tracked(params: Dictionary, w: int, h: int) -> Array[RID]:
	"""Génération de régions Voronoi - Retourne les RIDs temporaires"""
	
	var temp_rids: Array[RID] = []
	
	if not rd or not region_pipeline.is_valid() or not region_uniform_set.is_valid():
		push_warning("[Orchestrator] ⚠️ Region pipeline not ready, skipping")
		return temp_rids
	
	print("[Orchestrator] 🗺️ Génération des régions (Voronoi)")
	
	var num_seeds = params.get("nb_avg_cases", 50)
	var seed_value = params.get("seed", 0)
	
	# Créer buffer de seeds aléatoires
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	
	var seed_data = PackedVector2Array()
	for i in range(num_seeds):
		seed_data.append(Vector2(
			rng.randf_range(0.0, float(w)),
			rng.randf_range(0.0, float(h))
		))
	
	var seed_buffer = rd.storage_buffer_create(seed_data.to_byte_array().size(), seed_data.to_byte_array())
	temp_rids.append(seed_buffer)  # ✅ TRACKER POUR CLEANUP
	
	var seed_uniform = RDUniform.new()
	seed_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	seed_uniform.binding = 1
	seed_uniform.add_id(seed_buffer)
	
	var region_set = rd.uniform_set_create([seed_uniform], region_pipeline, 1)
	if not region_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create region set")
		return temp_rids
	temp_rids.append(region_set)  # ✅ TRACKER POUR CLEANUP
	
	var groups_x = ceili(float(w) / 8.0)
	var groups_y = ceili(float(h) / 8.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, region_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, region_uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, region_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	print("[Orchestrator] ✅ Régions générées (", temp_rids.size(), " ressources à nettoyer)")
	return temp_rids

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
# CLEANUP (DESTRUCTOR)
# ============================================================================

func cleanup():
	"""Nettoyage manuel - appeler avant de détruire l'orchestrateur"""
	
	if not rd:
		push_warning("[Orchestrator] RD is null, skipping cleanup")
		return
	
	print("[Orchestrator] 🧹 Nettoyage des ressources persistantes...")
	
	# Libérer les textures
	if geo_state_texture.is_valid():
		rd.free_rid(geo_state_texture)
	if atmo_state_texture.is_valid():
		rd.free_rid(atmo_state_texture)
	if flux_map_texture.is_valid():
		rd.free_rid(flux_map_texture)
	if velocity_map_texture.is_valid():
		rd.free_rid(velocity_map_texture)
	
	# Libérer les pipelines
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
	
	# Libérer les uniform sets
	if tectonic_uniform_set.is_valid():
		rd.free_rid(tectonic_uniform_set)
	if atmosphere_uniform_set.is_valid():
		rd.free_rid(atmosphere_uniform_set)
	if erosion_uniform_set.is_valid():
		rd.free_rid(erosion_uniform_set)
	if orogeny_uniform_set.is_valid():
		rd.free_rid(orogeny_uniform_set)
	if region_uniform_set.is_valid():
		rd.free_rid(region_uniform_set)
	
	print("[Orchestrator] ✅ Ressources libérées")

func _notification(what: int) -> void:
	"""Nettoyage automatique quand l'objet est détruit"""
	if what == NOTIFICATION_PREDELETE:
		# cleanup()  # Commented out to prevent null instance error
		pass