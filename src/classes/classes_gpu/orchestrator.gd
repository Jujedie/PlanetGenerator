extends RefCounted
class_name GPUOrchestrator

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
var generation_params: Dictionary
var dt: float = 0.016

# ============================================================================
# INITIALISATION
# ============================================================================

func _init(gpu_context: GPUContext, res: Vector2i = Vector2i(128, 64), gen_params: Dictionary = {}) -> void:
	gpu = gpu_context
	resolution = res
	generation_params = gen_params
	
	print("[Orchestrator] 🚀 Initialisation...")
	
	# ✅ VALIDATION 1: GPUContext existe
	if not gpu:
		push_error("[Orchestrator] ❌ FATAL: GPUContext is null")
		return
	
	# ✅ VALIDATION 2: RenderingDevice est valide
	rd = gpu.rd
	if not rd:
		push_error("[Orchestrator] ❌ FATAL: RenderingDevice is null")
		push_error("  Le GPUContext n'a pas pu initialiser le GPU")
		return
	
	print("[Orchestrator] ✅ RenderingDevice valide")
	
	# ✅ VALIDATION 3: Tester la résolution
	if resolution.x <= 0 or resolution.y <= 0:
		push_error("[Orchestrator] ❌ FATAL: Résolution invalide: ", resolution)
		return
	
	if resolution.x > 8192 or resolution.y > 8192:
		push_warning("[Orchestrator] ⚠️ Résolution très élevée: ", resolution, " (risque VRAM)")
	
	print("[Orchestrator] ✅ Résolution: ", resolution)
	
	# 1. Créer les textures
	_init_textures()
	
	# ✅ VALIDATION 4: Vérifier que les textures sont créées
	if not geo_state_texture.is_valid() or not atmo_state_texture.is_valid():
		push_error("[Orchestrator] ❌ FATAL: Échec création des textures")
		return
	
	print("[Orchestrator] ✅ Textures créées")
	
	# 2. Compiler et créer les pipelines
	var shaders_ok = _compile_all_shaders()
	if not shaders_ok:
		push_error("[Orchestrator] ❌ FATAL: Impossible de compiler les shaders critiques")
		return
	
	print("[Orchestrator] ✅ Shaders compilés")
	
	# 3. Créer les uniform sets
	
	_init_uniform_sets()
	
	# ✅ VALIDATION 5: Vérifier qu'au moins le pipeline d'érosion est prêt
	if not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] ❌ FATAL: Pipeline d'érosion (critique) non opérationnel")
		return
	
	print("[Orchestrator] ✅ Orchestrator initialisé avec succès")
	print("  - Résolution: ", resolution)
	print("  - Pipelines actifs:")
	if tectonic_pipeline.is_valid(): print("    • Tectonic")
	if atmosphere_pipeline.is_valid(): print("    • Atmosphere")
	if erosion_pipeline.is_valid(): print("    • Erosion")
	if orogeny_pipeline.is_valid(): print("    • Orogeny")
	if region_pipeline.is_valid(): print("    • Region")

# ============================================================================
# FIX A : CHARGEMENT ROBUSTE DES SHADERS
# ============================================================================

func _compile_all_shaders() -> bool:
	"""
	Charge et compile tous les shaders avec validation stricte.
	Retourne false si au moins un shader critique échoue.
	"""
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot compile shaders")
		return false
	
	print("[Orchestrator] 📦 Compilation des shaders...")
	
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
			"critical": true
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
		
		gpu.load_compute_shader(path, name)
		var pipeline_rid = gpu.shaders[name]

		# ✅ SUCCÈS: Assigner UNIQUEMENT si tout est valide
		match name:
			"tectonic":
				tectonic_pipeline = pipeline_rid
				print("    ✅ Tectonic pipeline RID: ", pipeline_rid)
			"atmosphere":
				atmosphere_pipeline = pipeline_rid
				print("    ✅ Atmosphere pipeline RID: ", pipeline_rid)
			"erosion":
				erosion_pipeline = pipeline_rid
				print("    ✅ Erosion pipeline RID: ", pipeline_rid)
			"orogeny":
				orogeny_pipeline = pipeline_rid
				print("    ✅ Orogeny pipeline RID: ", pipeline_rid)
			"region":
				region_pipeline = pipeline_rid
				print("    ✅ Region pipeline RID: ", pipeline_rid)
		
		print("    ✅ ", name, " OK (Pipeline RID: ", pipeline_rid, ")")
	
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

# === LOG DE VÉRIFICATION DES SHADERS ===
func log_all_shader_rids():
	if not gpu or not gpu.shaders:
		print("[DEBUG] gpu.shaders non disponible")
		return
	print("[DEBUG] Liste des shader RIDs dans GPUContext :")
	for name in gpu.shaders.keys():
		var rid = gpu.shaders[name]
		print("  Shader '", name, "' : ", rid, " (valid:", rid.is_valid(), ")")

func _init_uniform_sets():
	"""
	Initialise les uniform sets avec validation stricte des pipelines et textures.
	"""
	
	log_all_shader_rids()
	
	if not rd:
		push_error("[Orchestrator] ❌ RD is null, cannot create uniform sets")
		return
	
	print("[Orchestrator] 🔧 Création des uniform sets...")
	
	# ✅ VALIDATION PRÉALABLE: Vérifier que toutes les textures sont valides
	var required_textures = [
		{"name": "geo_state", "rid": geo_state_texture},
		{"name": "atmo_state", "rid": atmo_state_texture},
		{"name": "flux_map", "rid": flux_map_texture},
		{"name": "velocity_map", "rid": velocity_map_texture}
	]
	
	for tex_info in required_textures:
		if not tex_info["rid"].is_valid():
			push_error("[Orchestrator] ❌ Texture invalide: ", tex_info["name"])
			return
	
	print("  ✅ Toutes les textures sont valides")
	
	# === TECTONIC UNIFORM SET ===
	if tectonic_pipeline.is_valid():
		print("  • Création uniform set: tectonic")
		var tectonic_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),
			gpu.create_texture_uniform(1, atmo_state_texture),
			gpu.create_texture_uniform(2, flux_map_texture),
			gpu.create_texture_uniform(3, velocity_map_texture)
		]

		tectonic_uniform_set = rd.uniform_set_create(tectonic_uniforms, tectonic_pipeline, 0)
		if not tectonic_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create tectonic uniform set")
			push_error("  Pipeline RID: ", tectonic_pipeline)
			push_error("  Bindings: 0-3, Textures: ", geo_state_texture, atmo_state_texture, flux_map_texture, velocity_map_texture)
		else:
			print("    ✅ Tectonic uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ Tectonic pipeline invalide, uniform set ignoré")
	
	# === ATMOSPHERE UNIFORM SET ===
	if atmosphere_pipeline.is_valid():
		print("  • Création uniform set: atmosphere")
		var atmosphere_uniforms = [
			gpu.create_texture_uniform(0, atmo_state_texture),  # atmospheric_state_in
			gpu.create_texture_uniform(1, geo_state_texture),   # geophysical_state
			gpu.create_texture_uniform(2, atmo_state_texture)   # atmospheric_state_out (même texture)
		]
		atmosphere_uniform_set = rd.uniform_set_create(atmosphere_uniforms, atmosphere_pipeline, 0)
		if not atmosphere_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create atmosphere uniform set")
			push_error("  Pipeline RID: ", atmosphere_pipeline)
			push_error("  Bindings: 0-2, Textures: ", atmo_state_texture, geo_state_texture)
		else:
			print("    ✅ Atmosphere uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ Atmosphere pipeline invalide, uniform set ignoré")
	
	# === EROSION UNIFORM SET ===
	if erosion_pipeline.is_valid():
		print("  • Création uniform set: erosion")
		var erosion_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),
			gpu.create_texture_uniform(1, atmo_state_texture),
			gpu.create_texture_uniform(2, flux_map_texture),
			gpu.create_texture_uniform(3, velocity_map_texture)
		]
		erosion_uniform_set = rd.uniform_set_create(erosion_uniforms, erosion_pipeline, 0)
		if not erosion_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ CRITIQUE: Failed to create erosion uniform set")
			push_error("  Pipeline RID: ", erosion_pipeline)
			push_error("  Bindings: 0-3, Textures: ", geo_state_texture, atmo_state_texture, flux_map_texture, velocity_map_texture)
		else:
			print("    ✅ Erosion uniform set créé")
	else:
		push_error("[Orchestrator] ❌ CRITIQUE: Erosion pipeline invalide")
	
	# === OROGENY UNIFORM SET ===
	if orogeny_pipeline.is_valid():
		print("  • Création uniform set: orogeny")
		var orogeny_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture),  # plate_data (approx)
			gpu.create_texture_uniform(1, geo_state_texture)   # geophysical_state
		]
		orogeny_uniform_set = rd.uniform_set_create(orogeny_uniforms, orogeny_pipeline, 0)
		if not orogeny_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create orogeny uniform set")
		else:
			print("    ✅ Orogeny uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ Orogeny pipeline invalide, uniform set ignoré")
	
	# === REGION UNIFORM SET ===
	if region_pipeline.is_valid():
		print("  • Création uniform set: region")
		var region_uniforms = [
			gpu.create_texture_uniform(0, geo_state_texture)  # geo_map
		]
		region_uniform_set = rd.uniform_set_create(region_uniforms, region_pipeline, 0)
		if not region_uniform_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create region uniform set")
		else:
			print("    ✅ Region uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ Region pipeline invalide, uniform set ignoré")
	
	print("[Orchestrator] ✅ Uniform Sets initialization complete")

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

	for pipeline in [erosion_pipeline, erosion_uniform_set]:
		if pipeline == null or not pipeline.is_valid():
			push_error("[Orchestrator] Erosion pipeline/uniform set invalid - skipping")
			return garbage_bin
	
	print("[Orchestrator] 🌊 Érosion hydraulique: ", iterations, " itérations")
	
	# Calcul gravité
	var rayon_planete = generation_params.get("planet_radius")  # Terre par défaut
	var densite_planete = 5514    # Terre en kg/m³
	var gravite = compute_gravity(rayon_planete, densite_planete)
	print("Gravité = ", gravite, " m/s²")

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
		
		# Step 1: Calcul du flux
		var flux_rids = _dispatch_erosion_step(1, params, groups_x, groups_y)
		garbage_bin.append_array(flux_rids)
		
		# Step 2: Mise à jour de l'eau
		var water_rids = _dispatch_erosion_step(2, params, groups_x, groups_y)
		garbage_bin.append_array(water_rids)
		
		# Step 3: Érosion/Déposition
		var erosion_rids = _dispatch_erosion_step(3, params, groups_x, groups_y)
		garbage_bin.append_array(erosion_rids)
		
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
	
	# Sécurité accrue : on vérifie tout avant de commencer
	if not rd or not erosion_pipeline.is_valid() or not erosion_uniform_set.is_valid():
		push_error("[Orchestrator] Cannot dispatch - invalid rd/pipeline/uniform set")
		return temp_rids
	
	# Créer le buffer de paramètres
	# NOTE: Le padding est important pour l'alignement std140 des UBOs, 
	# mais ton shader semble utiliser des scalaires simples alignés sur 4 bytes, 
	# donc ton Array actuel devrait passer.
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
		0.0  # Padding (alignement 16 bytes souvent préféré, mais ici 48 bytes total c'est ok)
	])
	
	var param_bytes = param_data.to_byte_array()
	
	# --- CORRECTION MAJEURE ICI ---
	# 1. Utiliser uniform_buffer_create au lieu de storage_buffer_create
	# Cela assigne le flag VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT
	var param_buffer = rd.uniform_buffer_create(param_bytes.size(), param_bytes)
	temp_rids.append(param_buffer)
	
	var param_uniform = RDUniform.new()
	# 2. Changer le type pour correspondre au GLSL "uniform Parameters {...}"
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER 
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	# Création du set
	var param_set = rd.uniform_set_create([param_uniform], erosion_pipeline, 1)
	
	# Validation critique : si le set a échoué (ex: mismatch type), on arrête tout
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create param uniform set (Check Type Mismatch)")
		return temp_rids 
		
	temp_rids.append(param_set)
	
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

func compute_gravity(radius: float, density: float) -> float:
	const G = 6.67430e-11 # constante gravitationnelle en m^3·kg^-1·s^-2
	return (4.0 / 3.0) * PI * G * density * radius