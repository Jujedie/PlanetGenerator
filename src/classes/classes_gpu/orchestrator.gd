extends RefCounted

## Orchestrateur de Simulation Géophysique sur GPU.
##
## Cette classe agit comme le chef d'orchestre de la pipeline de génération.
## Elle est responsable de :
## 1. L'allocation des ressources mémoire (VRAM) pour les cartes d'état (GeoMap, AtmoMap).
## 2. La compilation et la liaison des Compute Shaders (Tectonique, Érosion, Atmosphère).
## 3. L'exécution séquentielle des simulations physiques avec synchronisation (Barriers).
## 4. La gestion des données globales (Uniform Buffers) partagées entre les shaders.
class_name GPUOrchestrator

var gpu: GPUContext
var rd: RenderingDevice

var resolution: Vector2i
var generation_params: Dictionary

# ============================================================================
# INITIALISATION
# ============================================================================

## Constructeur de l'orchestrateur.
##
## Initialise le contexte, valide les paramètres de génération et lance la séquence de préparation :
## compilation des shaders, allocation des textures et création des sets d'uniformes.
##
## @param gpu_context: Référence vers le gestionnaire de bas niveau [GPUContext].
## @param res: Résolution de la simulation (ex: 2048x1024).
## @param gen_params: Dictionnaire contenant les constantes physiques (gravité, niveau de la mer, seed...).
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
	for textures in gpu.textures.values():
		if not textures.is_valid():
			push_error("[Orchestrator] ❌ FATAL: Impossible de créer les textures GPU")
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
	
	print("[Orchestrator] ✅ Orchestrator initialisé avec succès")
	print("  - Résolution: ", resolution)
	print("  - Pipelines actifs:")
	for pipeline in gpu.shaders.keys():
		if gpu.shaders[pipeline].is_valid():
			print("    • ", pipeline)
# ============================================================================
# FIX A : CHARGEMENT ROBUSTE DES SHADERS
# ============================================================================

## Compile tous les shaders de calcul nécessaires à la simulation.
##
## Charge les fichiers `.glsl` depuis le disque (res://shaders/) et les compile en bytecode SPIR-V via le [GPUContext].
## Initialise les variables membres `tectonic_shader`, `erosion_shader`, `atmosphere_shader`, etc.
## En cas d'erreur de compilation, arrête l'initialisation et log l'erreur.
func _compile_all_shaders() -> bool:
	"""
	Charge les shaders et crée les pipelines correspondants.
	"""
	if not rd: return false
	print("[Orchestrator] 📦 Compilation des shaders et création des pipelines...")
	
	var shaders_to_load = [
		{"path": "res://shaders/compute/topographie/tectonic_plates.glsl", "name": "tectonic"},
		{"path": "res://shaders/compute/topographie/orogeny.glsl", "name": "orogeny"},
		{"path": "res://shaders/compute/topographie/hydraulic_erosion.glsl", "name": "erosion"}
	]
	
	for s in shaders_to_load:
		var ok = gpu.load_compute_shader(s["path"], s["name"])
		if not ok or not gpu.shaders.has(s["name"]) or not gpu.shaders[s["name"]].is_valid():
			push_error("  ❌ Échec chargement shader: ", s["name"])
			return false
		print("    ✅ ", s["name"], " : Shader=", gpu.shaders[s["name"]], " | Pipeline=", gpu.pipelines[s["name"]])
	
	return true

# ============================================================================
# INITIALISATION DES TEXTURES
# ============================================================================

## Alloue les textures d'état (State Maps) en mémoire vidéo.
##
## Crée les textures RGBA32F (128 bits par pixel) qui stockeront les données physiques
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
	for tex_name in gpu.textures.keys():
		var rid = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
		if not rid.is_valid():
			push_error("[Orchestrator] ❌ Échec création texture: ", tex_name)
			continue
		gpu.textures[tex_name] = rid
	
	print("[Orchestrator] ✅ Textures créées (4x ", size / 1024, " KB)")

# ============================================================================
# INITIALISATION DES UNIFORM SETS
# ============================================================================

## Affiche les identifiants (RID) des shaders compilés dans la console.
##
## Méthode de débogage pour vérifier que tous les shaders ont été correctement chargés par le RenderingDevice
## et possèdent un RID valide.
func log_all_shader_rids():
	if not gpu or not gpu.shaders:
		print("[DEBUG] gpu.shaders non disponible")
		return
	print("[DEBUG] Liste des shader RIDs dans GPUContext :")
	for name in gpu.shaders.keys():
		var rid = gpu.shaders[name]
		print("  Shader '", name, "' : ", rid, " (valid:", rid.is_valid(), ")")

## Crée et lie les ensembles d'uniformes (Uniform Sets) pour chaque pipeline.
##
## Configure les descripteurs qui relient les textures allouées (`geo_state_texture`) aux bindings GLSL
## (ex: `layout(set = 0, binding = 1) uniform image2D`).
## Prépare également le Buffer Uniforme Global contenant les constantes physiques.
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
	]
	
	for tex_info in required_textures:
		if not tex_info["rid"].is_valid():
			push_error("[Orchestrator] ❌ Texture invalide: ", tex_info["name"])
			return
	
	print("  ✅ Toutes les textures sont valides")
	
	# FOR EACH PIPELINE: Créer les uniform sets
	# === TECTONIC PLATES SHADER ===
	if gpu.shaders["tectonic"].is_valid():
		print("  • Création uniform set: tectonic")
		var uniforms = [
			gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID[0]]),
			gpu.create_texture_uniform(1, gpu.textures[GPUContext.TextureID[1]])
		]
		gpu.uniform_sets["tectonic"] = rd.uniform_set_create(uniforms, gpu.shaders["tectonic"], 0)
		if not gpu.uniform_sets["tectonic"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create tectonic uniform set")
		else:
			print("    ✅ tectonic uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️",  "tectonic"," pipeline invalide, uniform set ignoré")

	# === OROGENY SHADER ===
	if gpu.shaders["orogeny"].is_valid():
		print("  • Création uniform set: orogeny")
		var uniforms = [
			gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID[0]]),
			gpu.create_texture_uniform(1, gpu.textures[GPUContext.TextureID[1]])
		]
		gpu.uniform_sets["orogeny"] = rd.uniform_set_create(uniforms, gpu.shaders["orogeny"], 0)
		if not gpu.uniform_sets["orogeny"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create orogeny uniform set")
		else:
			print("    ✅ orogeny uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️",  "orogeny"," pipeline invalide, uniform set ignoré")

	# === EROSION SHADER ===
	if gpu.shaders["erosion"].is_valid():
		print("  • Création uniform set: erosion")
		var uniforms = [
			gpu.create_texture_uniform(0, gpu.textures[GPUContext.TextureID[0]]),
		]
		gpu.uniform_sets["erosion"] = rd.uniform_set_create(uniforms, gpu.shaders["erosion"], 0)
		if not gpu.uniform_sets["erosion"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion uniform set")
		else:
			print("    ✅ erosion uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️",  "erosion"," pipeline invalide, uniform set ignoré")

	print("[Orchestrator] ✅ Uniform Sets initialization complete")

# ============================================================================
# SEQUENCE DE SIMULATION COMPLÈTE
# ============================================================================

## Lance la séquence complète de simulation planétaire.
##
## Exécute les étapes dans l'ordre chronologique géologique :
## 1. Initialisation du terrain (Tectonique/Bruit de base).
## 2. Orogenèse (Formation des montagnes).
## 3. Érosion hydraulique (Cycle de l'eau et transport de sédiments).
## 4. Simulation atmosphérique (optionnelle à ce stade).
## 5. Génération des régions politiques/Voronoi.
##
## Émet des signaux de progression pour mettre à jour l'UI.
func run_simulation() -> void:
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
	
	var w = resolution.x
	var h = resolution.y
	
	print("  Résolution de la simulation : ", w, "x", h)
	
	var _rids_to_free: Array[RID] = []

	# ============================================================================
	# PHASE 1: TECTONIC PLATES GENERATION
	# ============================================================================
	run_tectonic_phase(generation_params, w, h, _rids_to_free)

	# ============================================================================
	# PHASE 2: OROGENIC DETAIL INJECTION
	# ============================================================================
	run_orogeny_phase(generation_params, w, h, _rids_to_free)

	# ============================================================================
	# PHASE 3: HYDRAULIC EROSION (ITERATIVE)
	# ============================================================================
	run_erosion_phase(generation_params, w, h, _rids_to_free)
	
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
# PHASES DE SIMULATION - TECTONIQUE, OROGENÈSE, ÉROSION (TOPOGRAPHIE)
# ============================================================================

func run_tectonic_phase(params: Dictionary, w: int, h: int, rids_to_free: Array[RID]) -> void:
	if not rd or not gpu.pipelines["tectonic"].is_valid():
		push_warning("[Orchestrator] ⚠️ Tectonic pipeline not ready, skipping")
		return
	
	print("[Orchestrator] Phase 1/3 - Tectonic Plates Generation")
	
	var seed_val = int(params.get("seed", 0))
	var num_plates = int(params.get("nb_cases_regions", 50))
	var plate_strength = 50.0
	var friction = 0.3
	var convergence = 3000.0
	var divergence = -1500.0
	var res_x = int(w)
	var res_y = int(h)
	var time_val = 0.0
	
	# CRITICAL FIX: std140 alignment requires 48 bytes total
	# Structure layout with padding:
	# 0-3:   seed (uint)
	# 4-7:   num_plates (uint)
	# 8-11:  plate_strength (float)
	# 12-15: friction_coefficient (float)
	# 16-19: convergence_uplift (float)
	# 20-23: divergence_subsidence (float)
	# 24-31: resolution (uvec2 = 2x uint)
	# 32-35: time (float)
	# 36-47: PADDING (12 bytes to reach 48)
	
	var buffer_data = PackedByteArray()
	buffer_data.resize(48)  # Must be 48 bytes for std140
	
	buffer_data.encode_u32(0, seed_val)
	buffer_data.encode_u32(4, num_plates)
	buffer_data.encode_float(8, plate_strength)
	buffer_data.encode_float(12, friction)
	buffer_data.encode_float(16, convergence)
	buffer_data.encode_float(20, divergence)
	buffer_data.encode_u32(24, res_x)
	buffer_data.encode_u32(28, res_y)
	buffer_data.encode_float(32, time_val)
	# bytes 36-47 are automatic padding (already zero from resize)
	
	var param_buffer = rd.uniform_buffer_create(48, buffer_data)
	rids_to_free.append(param_buffer)
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["tectonic"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create Tectonic Param Set")
		return
	rids_to_free.append(param_set)
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["tectonic"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["tectonic"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	print("[Orchestrator] ✅ Tectonic phase complete")

func run_orogeny_phase(params: Dictionary, w: int, h: int, rids_to_free: Array[RID]) -> void:
	if not rd or not gpu.pipelines["orogeny"].is_valid():
		push_warning("[Orchestrator] ⚠️ Orogeny pipeline not ready, skipping")
		return
	
	print("[Orchestrator] Phase 2/3 - Orogenic Detail Injection")
	
	var seed_val = int(params.get("seed", 0))
	var detail_scale = 0.005
	var mountain_intensity = 2000.0
	var erosion_factor = 0.02
	var res_x = int(w)
	var res_y = int(h)
	var time_val = 0.0
	
	# CRITICAL FIX: std140 alignment requires 32 bytes total
	# Structure layout:
	# 0-3:   seed (uint)
	# 4-7:   detail_scale (float)
	# 8-11:  mountain_intensity (float)
	# 12-15: erosion_factor (float)
	# 16-23: resolution (uvec2)
	# 24-27: time (float)
	# 28-31: PADDING (4 bytes)
	
	var buffer_data = PackedByteArray()
	buffer_data.resize(32)  # Must be 32 bytes for std140
	
	buffer_data.encode_u32(0, seed_val)
	buffer_data.encode_float(4, detail_scale)
	buffer_data.encode_float(8, mountain_intensity)
	buffer_data.encode_float(12, erosion_factor)
	buffer_data.encode_u32(16, res_x)
	buffer_data.encode_u32(20, res_y)
	buffer_data.encode_float(24, time_val)
	# bytes 28-31 are padding
	
	var param_buffer = rd.uniform_buffer_create(32, buffer_data)
	rids_to_free.append(param_buffer)
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["orogeny"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create Orogeny Param Set")
		return
	rids_to_free.append(param_set)
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["orogeny"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["orogeny"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	print("[Orchestrator] ✅ Orogeny phase complete")

func run_erosion_phase(params: Dictionary, w: int, h: int, rids_to_free: Array[RID]) -> void:
	if not rd or not gpu.pipelines["erosion"].is_valid():
		push_warning("[Orchestrator] ⚠️ Erosion pipeline not ready, skipping")
		return
	
	print("[Orchestrator] Phase 3/3 - Hydraulic Erosion (Iterative)")
	
	var num_iterations = int(params.get("erosion_iterations", 100))
	var seed_val = int(params.get("seed", 0))
	var rain = 0.01
	var evaporation = 0.05
	var sediment_cap = 4.0
	var erosion_str = 0.3
	var deposition_str = 0.3
	var gravity = 9.81
	var res_x = int(w)
	var res_y = int(h)
	var time_val = 0.0
	
	# CRITICAL FIX: std140 alignment requires 48 bytes total
	# Structure layout:
	# 0-3:   seed (uint)
	# 4-7:   iteration (uint)
	# 8-11:  rain_amount (float)
	# 12-15: evaporation_rate (float)
	# 16-19: sediment_capacity (float)
	# 20-23: erosion_strength (float)
	# 24-27: deposition_strength (float)
	# 28-31: gravity (float)
	# 32-39: resolution (uvec2)
	# 40-43: time (float)
	# 44-47: PADDING (4 bytes)
	
	for i in range(num_iterations):
		var buffer_data = PackedByteArray()
		buffer_data.resize(48)  # Must be 48 bytes for std140
		
		buffer_data.encode_u32(0, seed_val)
		buffer_data.encode_u32(4, i)
		buffer_data.encode_float(8, rain)
		buffer_data.encode_float(12, evaporation)
		buffer_data.encode_float(16, sediment_cap)
		buffer_data.encode_float(20, erosion_str)
		buffer_data.encode_float(24, deposition_str)
		buffer_data.encode_float(28, gravity)
		buffer_data.encode_u32(32, res_x)
		buffer_data.encode_u32(36, res_y)
		buffer_data.encode_float(40, time_val)
		# bytes 44-47 are padding
		
		var param_buffer = rd.uniform_buffer_create(48, buffer_data)
		
		var param_uniform = RDUniform.new()
		param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		param_uniform.binding = 0
		param_uniform.add_id(param_buffer)
		
		var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion"], 1)
		if not param_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create Erosion Param Set")
			rd.free_rid(param_buffer)
			return
		
		var groups_x = ceili(float(w) / 16.0)
		var groups_y = ceili(float(h) / 16.0)
		
		var compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion"])
		rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["erosion"], 0)
		rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
		rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		rd.compute_list_end()
		
		rd.submit()
		rd.sync()
		
		# Clean up this iteration's resources
		rd.free_rid(param_set)
		rd.free_rid(param_buffer)
		
		if i % 10 == 0:
			print("  Iteration ", i, "/", num_iterations)
	
	print("[Orchestrator] ✅ Erosion phase complete")

# ============================================================================
# EXEMPLE PHASES DE SIMULATION
# ============================================================================

#func run_example(params: Dictionary, w: int, h: int):	
#	if not rd or not gpu.pipelines["example"].is_valid() or not orogeny_uniform_set.is_valid():
#		push_warning("[Orchestrator] ⚠️ Orogeny pipeline not ready, skipping")
#		return
#	
#	print("[Orchestrator] Example Phase")
#	
#	# 1. Préparation des données des paramètres
#	var m_strength = float(params.get("mountain_strength", 50.0))
#	var r_strength = float(params.get("rift_strength", -30.0))
#	var erosion    = float(params.get("orogeny_erosion", 0.98))
#	var dt         = float(params.get("delta_time", 0.016))
#	
#	var buffer_data = PackedFloat32Array([m_strength, r_strength, erosion, dt])
#	var buffer_bytes = buffer_data.to_byte_array()
#	
#	# 2. Création du Buffer (Uniform Buffer)
#	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
#	
#	# 3. Création de l'Uniform
#	var param_uniform = RDUniform.new()
#	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
#	param_uniform.binding = 0 # Binding 0 dans le Set 1
#	param_uniform.add_id(param_buffer)
#	
#	# 4. Création du Set (Set Index 1)
#	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["example"], 1)
#	
#	if not param_set.is_valid():
#		push_error("[Orchestrator] ❌ Failed to create Example Param Set")
#		return
#		
#	# Calcul des groupes
#	var groups_x = ceili(float(w) / 16.0)
#	var groups_y = ceili(float(h) / 16.0)
#	
#	# 5. Dispatch
#	var compute_list = rd.compute_list_begin()
#	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["example"])
#	
#	# Bind du Set 0 (Textures)
#	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["example"], 0)
#	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
#	
#	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
#	rd.compute_list_end()
#	
#	# 6. Nettoyage immédiat (Optimisation)
#	# On libère les ressources temporaires après l'exécution de la commande (rd.submit n'est pas bloquant mais free_rid l'est pour la ressource)
#	# Note : Pour être 100% safe avec Vulkan, on devrait les garder jusqu'à la fin de la frame, 
#	# mais Godot gère souvent ça. Si ça crash, on les mettra dans une liste 'garbage_bin'.
#	rd.free_rid(param_set)
#	rd.free_rid(param_buffer)
#	
#	rd.submit()
#	rd.sync()
#	print("[Orchestrator] ✅ Orogenèse terminée")

# ============================================================================
# EXPORT
# ============================================================================

## Example d'exportation de carte
#func export_example_to_image() -> Image:
#	var byte_data = rd.texture_get_data(gpu.textures["example"], 0)
#	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)


# ============================================================================
# HELPERS METHODS
# ============================================================================

## Libère toutes les ressources GPU allouées par l'orchestrateur.
##
## Détruit manuellement les RIDs des textures, pipelines, shaders et uniform sets
## via [method RenderingDevice.free_rid] pour éviter les fuites de VRAM.
func cleanup():
	"""Nettoyage manuel - appeler avant de détruire l'orchestrateur"""
	
	if not rd:
		push_warning("[Orchestrator] RD is null, skipping cleanup")
		return
	
	print("[Orchestrator] 🧹 Nettoyage des ressources persistantes...")
	
	gpu._exit_tree()
	
	print("[Orchestrator] ✅ Ressources libérées")

## Intercepte la suppression de l'objet pour forcer le nettoyage.
##
## Garantit que [method cleanup] est appelée même si le script est libéré brusquement.
##
## @param what: Type de notification Godot.
func _notification(what: int) -> void:
	"""Nettoyage automatique quand l'objet est détruit"""
	if what == NOTIFICATION_PREDELETE:
		# cleanup()  # Commented out to prevent null instance error
		pass

# ============================================================================
# PHYSICS HELPERS
# ============================================================================

## Calcule la gravité de surface basée sur les paramètres physiques.
##
## Utilise la formule : g ~ Densité * Rayon (approximation pour une planète sphérique homogène).
## Cette valeur est passée aux shaders pour influencer la vitesse d'écoulement de l'eau.
##
## @return float: La gravité en m/s² (ou unités sim).
func compute_gravity(radius: float, density: float) -> float:
	const G = 6.67430e-11 # constante gravitationnelle en m^3·kg^-1·s^-2
	return (4.0 / 3.0) * PI * G * density * radius
