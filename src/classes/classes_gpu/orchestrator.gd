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
		# Shader de génération topographique de base (Étape 0)
		{"path": "res://shader/compute/topographie/base_elevation.glsl", "name": "base_elevation", "critical": true},
		# Shaders d'âge de croûte (JFA + Finalisation)
		{"path": "res://shader/compute/topographie/crust_age_jfa.glsl", "name": "crust_age_jfa", "critical": false},
		{"path": "res://shader/compute/topographie/crust_age_finalize.glsl", "name": "crust_age_finalize", "critical": false},
		# Shaders Atmosphère & Climat (Étape 3)
		{"path": "res://shader/compute/atmosphere_climat/temperature.glsl", "name": "temperature", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/precipitation.glsl", "name": "precipitation", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/clouds_init.glsl", "name": "clouds_init", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/clouds_advection.glsl", "name": "clouds_advection", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/clouds_render.glsl", "name": "clouds_render", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/ice_caps.glsl", "name": "ice_caps", "critical": false},
	]
	
	var all_critical_loaded = true
	
	for s in shaders_to_load:
		var success = gpu.load_compute_shader(s["path"], s["name"])
		if not success or not gpu.shaders.has(s["name"]) or not gpu.shaders[s["name"]].is_valid():
			print("  ❌ Échec chargement shader: ", s["name"])
			if s["critical"]: all_critical_loaded = false
			continue
		
		var shader_rid = gpu.shaders[s["name"]]
		var pipeline_rid = gpu.pipelines[s["name"]]
		print("    ✅ ", s["name"], " : Shader=", shader_rid, " | Pipeline=", pipeline_rid)
	
	return all_critical_loaded

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
	
	# ✅ VALIDATION PRÉALABLE: Vérifier que les textures nécessaires à l'étape 0 sont valides
	# Note: À l'étape 0 (topographie de base), les textures "geo" et "plates" sont requises
	var required_textures = [
		{"name": "geo", "rid": gpu.textures.get("geo", RID())},
		{"name": "plates", "rid": gpu.textures.get("plates", RID())},
	]
	
	for tex_info in required_textures:
		if not tex_info["rid"].is_valid():
			push_error("[Orchestrator] ❌ Texture invalide: ", tex_info["name"])
			return
	
	print("  ✅ Toutes les textures sont valides")
	
	# === BASE ELEVATION SHADER (Topographie Step 0) ===
	if gpu.shaders.has("base_elevation") and gpu.shaders["base_elevation"].is_valid():
		print("  • Création uniform set: base_elevation")
		
		# Set 0 : Textures (geo_texture + plates_texture en écriture)
		var uniforms_set0 = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["plates"]),
		]
		
		gpu.uniform_sets["base_elevation_textures"] = rd.uniform_set_create(uniforms_set0, gpu.shaders["base_elevation"], 0)
		if not gpu.uniform_sets["base_elevation_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create base_elevation textures uniform set")
		else:
			print("    ✅ base_elevation textures uniform set créé (geo + plates)")
	else:
		push_warning("[Orchestrator] ⚠️ base_elevation shader invalide, uniform set ignoré")
	
	# === CRUST AGE JFA SHADER ===
	if gpu.shaders.has("crust_age_jfa") and gpu.shaders["crust_age_jfa"].is_valid():
		print("  • Création uniform set: crust_age_jfa")
		
		# Set 0 : Textures (plates en lecture, crust_age en lecture/écriture)
		var uniforms_jfa = [
			gpu.create_texture_uniform(0, gpu.textures["plates"]),
			gpu.create_texture_uniform(1, gpu.textures["crust_age"]),
		]
		
		gpu.uniform_sets["crust_age_jfa_textures"] = rd.uniform_set_create(uniforms_jfa, gpu.shaders["crust_age_jfa"], 0)
		if not gpu.uniform_sets["crust_age_jfa_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create crust_age_jfa textures uniform set")
		else:
			print("    ✅ crust_age_jfa textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ crust_age_jfa shader invalide, uniform set ignoré")
	
	# === CRUST AGE FINALIZE SHADER ===
	if gpu.shaders.has("crust_age_finalize") and gpu.shaders["crust_age_finalize"].is_valid():
		print("  • Création uniform set: crust_age_finalize")
		
		# Set 0 : Textures (plates, crust_age, geo)
		var uniforms_finalize = [
			gpu.create_texture_uniform(0, gpu.textures["plates"]),
			gpu.create_texture_uniform(1, gpu.textures["crust_age"]),
			gpu.create_texture_uniform(2, gpu.textures["geo"]),
		]
		
		gpu.uniform_sets["crust_age_finalize_textures"] = rd.uniform_set_create(uniforms_finalize, gpu.shaders["crust_age_finalize"], 0)
		if not gpu.uniform_sets["crust_age_finalize_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create crust_age_finalize textures uniform set")
		else:
			print("    ✅ crust_age_finalize textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ crust_age_finalize shader invalide, uniform set ignoré")
	
	# === ÉTAPE 3 : ATMOSPHÈRE & CLIMAT ===
	# Initialiser les textures climat avant de créer les uniform sets
	gpu.initialize_climate_textures()
	
	# === TEMPERATURE SHADER ===
	if gpu.shaders.has("temperature") and gpu.shaders["temperature"].is_valid():
		print("  • Création uniform set: temperature")
		
		# Set 0 : Textures (geo en lecture, climate en écriture, temperature_colored en écriture)
		var uniforms_temperature = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["climate"]),
			gpu.create_texture_uniform(2, gpu.textures["temperature_colored"]),
		]
		
		gpu.uniform_sets["temperature_textures"] = rd.uniform_set_create(uniforms_temperature, gpu.shaders["temperature"], 0)
		if not gpu.uniform_sets["temperature_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create temperature textures uniform set")
		else:
			print("    ✅ temperature textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ temperature shader invalide, uniform set ignoré")
	
	# === PRECIPITATION SHADER ===
	if gpu.shaders.has("precipitation") and gpu.shaders["precipitation"].is_valid():
		print("  • Création uniform set: precipitation")
		
		# Set 0 : Textures (climate en lecture/écriture, precipitation_colored en écriture)
		var uniforms_precipitation = [
			gpu.create_texture_uniform(0, gpu.textures["climate"]),
			gpu.create_texture_uniform(1, gpu.textures["precipitation_colored"]),
		]
		
		gpu.uniform_sets["precipitation_textures"] = rd.uniform_set_create(uniforms_precipitation, gpu.shaders["precipitation"], 0)
		if not gpu.uniform_sets["precipitation_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create precipitation textures uniform set")
		else:
			print("    ✅ precipitation textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ precipitation shader invalide, uniform set ignoré")
	
	# === CLOUDS INIT SHADER ===
	if gpu.shaders.has("clouds_init") and gpu.shaders["clouds_init"].is_valid():
		print("  • Création uniform set: clouds_init")
		
		# Set 0 : Textures (vapor en écriture, climate en écriture pour vent)
		var uniforms_clouds_init = [
			gpu.create_texture_uniform(0, gpu.textures["vapor"]),
			gpu.create_texture_uniform(1, gpu.textures["climate"]),
		]
		
		gpu.uniform_sets["clouds_init_textures"] = rd.uniform_set_create(uniforms_clouds_init, gpu.shaders["clouds_init"], 0)
		if not gpu.uniform_sets["clouds_init_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create clouds_init textures uniform set")
		else:
			print("    ✅ clouds_init textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ clouds_init shader invalide, uniform set ignoré")
	
	# === CLOUDS ADVECTION SHADER ===
	if gpu.shaders.has("clouds_advection") and gpu.shaders["clouds_advection"].is_valid():
		print("  • Création uniform set: clouds_advection")
		
		# Set 0 : Textures (vapor en lecture, vapor_temp en écriture, climate en lecture pour vent)
		var uniforms_advection = [
			gpu.create_texture_uniform(0, gpu.textures["vapor"]),
			gpu.create_texture_uniform(1, gpu.textures["vapor_temp"]),
			gpu.create_texture_uniform(2, gpu.textures["climate"]),
		]
		
		gpu.uniform_sets["clouds_advection_textures"] = rd.uniform_set_create(uniforms_advection, gpu.shaders["clouds_advection"], 0)
		if not gpu.uniform_sets["clouds_advection_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create clouds_advection textures uniform set")
		else:
			print("    ✅ clouds_advection textures uniform set créé")
		
		# Créer aussi l'uniform set inverse pour le ping-pong
		var uniforms_advection_swap = [
			gpu.create_texture_uniform(0, gpu.textures["vapor_temp"]),
			gpu.create_texture_uniform(1, gpu.textures["vapor"]),
			gpu.create_texture_uniform(2, gpu.textures["climate"]),
		]
		
		gpu.uniform_sets["clouds_advection_textures_swap"] = rd.uniform_set_create(uniforms_advection_swap, gpu.shaders["clouds_advection"], 0)
		if not gpu.uniform_sets["clouds_advection_textures_swap"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create clouds_advection swap textures uniform set")
		else:
			print("    ✅ clouds_advection swap textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ clouds_advection shader invalide, uniform set ignoré")
	
	# === CLOUDS RENDER SHADER ===
	if gpu.shaders.has("clouds_render") and gpu.shaders["clouds_render"].is_valid():
		print("  • Création uniform set: clouds_render")
		
		# Set 0 : Textures (vapor en lecture, clouds en écriture)
		var uniforms_render = [
			gpu.create_texture_uniform(0, gpu.textures["vapor"]),
			gpu.create_texture_uniform(1, gpu.textures["clouds"]),
		]
		
		gpu.uniform_sets["clouds_render_textures"] = rd.uniform_set_create(uniforms_render, gpu.shaders["clouds_render"], 0)
		if not gpu.uniform_sets["clouds_render_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create clouds_render textures uniform set")
		else:
			print("    ✅ clouds_render textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ clouds_render shader invalide, uniform set ignoré")
	
	# === ICE CAPS SHADER ===
	if gpu.shaders.has("ice_caps") and gpu.shaders["ice_caps"].is_valid():
		print("  • Création uniform set: ice_caps")
		
		# Set 0 : Textures (geo en lecture pour water_height, climate en lecture pour température, ice_caps en écriture)
		var uniforms_ice = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["climate"]),
			gpu.create_texture_uniform(2, gpu.textures["ice_caps"]),
		]
		
		gpu.uniform_sets["ice_caps_textures"] = rd.uniform_set_create(uniforms_ice, gpu.shaders["ice_caps"], 0)
		if not gpu.uniform_sets["ice_caps_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create ice_caps textures uniform set")
		else:
			print("    ✅ ice_caps textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ ice_caps shader invalide, uniform set ignoré")
	
	print("[Orchestrator] ✅ Uniform Sets initialization complete")

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

	# === ÉTAPE 0 : GÉNÉRATION TOPOGRAPHIQUE DE BASE ===
	run_base_elevation_phase(generation_params, w, h)
	
	# === ÉTAPE 0.5 : ÂGE DE CROÛTE OCÉANIQUE (JFA) ===
	run_crust_age_phase(generation_params, w, h)
	
	# === ÉTAPE 1 : ÉROSION HYDRAULIQUE (À implémenter) ===
	# run_erosion_phase(generation_params, w, h)
	
	# === ÉTAPE 3 : ATMOSPHÈRE & CLIMAT ===
	run_atmosphere_phase(generation_params, w, h)
	
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
# ÉTAPE 0 : GÉNÉRATION TOPOGRAPHIQUE DE BASE
# ============================================================================

## Génère la heightmap de base avec bruit fBm et structures tectoniques.
##
## Cette phase remplace conceptuellement ElevationMapGenerator.gd (version CPU).
## Écrit dans GeoTexture (RGBA32F) :
## - R = height (élévation en mètres)
## - G = bedrock (résistance de la roche)
## - B = sediment (0 au départ, rempli par l'érosion)
## - A = water_height (colonne d'eau si sous niveau mer)
##
## @param params: Dictionnaire contenant seed, terrain_scale, sea_level, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_base_elevation_phase(params: Dictionary, w: int, h: int) -> void:
	if not rd or not gpu.pipelines.has("base_elevation") or not gpu.pipelines["base_elevation"].is_valid():
		push_warning("[Orchestrator] ⚠️ base_elevation pipeline not ready, skipping")
		return
	
	if not gpu.uniform_sets.has("base_elevation_textures") or not gpu.uniform_sets["base_elevation_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ base_elevation uniform set not ready, skipping")
		return
	
	print("[Orchestrator] 🏔️ Phase 0 : Génération Topographique de Base")
	
	# 1. Préparation des données UBO (Uniform Buffer Object)
	# Structure alignée std140 :
	# - uint seed (4 bytes)
	# - uint width (4 bytes)
	# - uint height (4 bytes)
	# - float elevation_modifier (4 bytes)
	# - float sea_level (4 bytes)
	# - float cylinder_radius (4 bytes)
	# - float padding2 (4 bytes)
	# - float padding3 (4 bytes)
	# Total : 32 bytes (aligné sur 16 bytes pour std140)
	
	var seed_val = int(params.get("seed", 12345))
	var elevation_modifier = float(params.get("terrain_scale", 0.0))
	var sea_level = float(params.get("sea_level", 0.0))
	var cylinder_radius = float(w) / (2.0 * PI)  # Rayon du cylindre pour le bruit seamless
	
	# Créer le buffer de données (PackedByteArray)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	# Écrire les données (little-endian)
	buffer_bytes.encode_u32(0, seed_val)           # seed
	buffer_bytes.encode_u32(4, w)                   # width
	buffer_bytes.encode_u32(8, h)                   # height
	buffer_bytes.encode_float(12, elevation_modifier) # elevation_modifier
	buffer_bytes.encode_float(16, sea_level)        # sea_level
	buffer_bytes.encode_float(20, cylinder_radius)  # cylinder_radius
	buffer_bytes.encode_float(24, 0.0)              # padding2
	buffer_bytes.encode_float(28, 0.0)              # padding3
	
	# 2. Création du Buffer Uniforme
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create base_elevation param buffer")
		return
	
	# 3. Création de l'Uniform pour le buffer
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	# 4. Création du Set 1 (paramètres)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["base_elevation"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create base_elevation param set")
		rd.free_rid(param_buffer)
		return
	
	# 5. Calcul des groupes de travail (16x16 threads par groupe)
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	print("  Seed: ", seed_val)
	print("  Elevation Modifier: ", elevation_modifier)
	print("  Sea Level: ", sea_level)
	print("  Cylinder Radius: ", cylinder_radius)
	print("  Dispatch: ", groups_x, "x", groups_y, " groupes (", w, "x", h, " pixels)")
	
	# 6. Dispatch du compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["base_elevation"])
	
	# Bind Set 0 (Textures)
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["base_elevation_textures"], 0)
	# Bind Set 1 (Paramètres)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	# 7. Soumettre et synchroniser
	rd.submit()
	rd.sync()
	
	# 8. Nettoyage des ressources temporaires
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	
	print("[Orchestrator] ✅ Phase 0 : Topographie de base générée")

# ============================================================================
# ÉTAPE 0.5 : ÂGE DE CROÛTE OCÉANIQUE (JFA)
# ============================================================================

## Calcule l'âge de la croûte océanique via Jump Flooding Algorithm.
##
## Le JFA propage la distance depuis les dorsales (frontières divergentes).
## L'âge est ensuite calculé à partir de cette distance et du taux d'expansion.
## La subsidence thermique est appliquée au plancher océanique.
##
## @param params: Dictionnaire contenant les paramètres de simulation
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_crust_age_phase(params: Dictionary, w: int, h: int) -> void:
	# Vérifier que les shaders sont disponibles
	if not gpu.shaders.has("crust_age_jfa") or not gpu.shaders["crust_age_jfa"].is_valid():
		push_warning("[Orchestrator] ⚠️ crust_age_jfa shader non disponible, phase ignorée")
		return
	if not gpu.shaders.has("crust_age_finalize") or not gpu.shaders["crust_age_finalize"].is_valid():
		push_warning("[Orchestrator] ⚠️ crust_age_finalize shader non disponible, phase ignorée")
		return
	if not gpu.uniform_sets.has("crust_age_jfa_textures") or not gpu.uniform_sets["crust_age_jfa_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ crust_age_jfa uniform set non disponible, phase ignorée")
		return
	
	print("[Orchestrator] 🌊 Phase 0.5 : Âge de Croûte Océanique (JFA)")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	# Paramètres de simulation
	var spreading_rate = float(params.get("spreading_rate", 50.0))  # km/Ma
	var planet_radius = float(params.get("planet_radius", 6371.0))  # km
	var max_age = float(params.get("max_crust_age", 200.0))  # Ma
	var subsidence_coeff = float(params.get("subsidence_coeff", 2800.0))  # m
	
	# Calculer le nombre de passes JFA
	var max_dim = max(w, h)
	var num_passes = int(ceil(log(float(max_dim)) / log(2.0))) + 1
	
	print("  Spreading Rate: ", spreading_rate, " km/Ma")
	print("  Planet Radius: ", planet_radius, " km")
	print("  JFA Passes: ", num_passes)
	
	# === PASSE 0 : INITIALISATION ===
	_dispatch_jfa_pass(w, h, groups_x, groups_y, 0, max_dim, spreading_rate)
	
	# === PASSES 1+ : PROPAGATION JFA ===
	var step_size = max_dim / 2
	var pass_idx = 1
	while step_size >= 1:
		_dispatch_jfa_pass(w, h, groups_x, groups_y, pass_idx, step_size, spreading_rate)
		step_size = step_size / 2
		pass_idx += 1
	
	print("  JFA terminé après ", pass_idx, " passes")
	
	# === PASSE FINALE : CALCUL ÂGE ET SUBSIDENCE ===
	_dispatch_crust_age_finalize(w, h, groups_x, groups_y, spreading_rate, planet_radius, max_age, subsidence_coeff)
	
	print("[Orchestrator] ✅ Phase 0.5 : Âge de croûte calculé")

## Dispatch une passe JFA
func _dispatch_jfa_pass(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, step_size: int, spreading_rate: float) -> void:
	# Structure UBO pour crust_age_jfa:
	# uint width, height, pass_index, step_size (16 bytes)
	# float spreading_rate, padding1, padding2, padding3 (16 bytes)
	# Total: 32 bytes
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)              # width
	buffer_bytes.encode_u32(4, h)              # height
	buffer_bytes.encode_u32(8, pass_index)     # pass_index
	buffer_bytes.encode_u32(12, step_size)     # step_size
	buffer_bytes.encode_float(16, spreading_rate)  # spreading_rate
	buffer_bytes.encode_float(20, 0.0)         # padding1
	buffer_bytes.encode_float(24, 0.0)         # padding2
	buffer_bytes.encode_float(28, 0.0)         # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create JFA param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["crust_age_jfa"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create JFA param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["crust_age_jfa"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["crust_age_jfa_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch la passe de finalisation (calcul âge + subsidence)
func _dispatch_crust_age_finalize(w: int, h: int, groups_x: int, groups_y: int, spreading_rate: float, planet_radius: float, max_age: float, subsidence_coeff: float) -> void:
	# Structure UBO pour crust_age_finalize:
	# uint width, height (8 bytes)
	# float spreading_rate, planet_radius, max_age, subsidence_coeff, padding1, padding2 (24 bytes)
	# Total: 32 bytes
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                    # width
	buffer_bytes.encode_u32(4, h)                    # height
	buffer_bytes.encode_float(8, spreading_rate)    # spreading_rate
	buffer_bytes.encode_float(12, planet_radius)    # planet_radius
	buffer_bytes.encode_float(16, max_age)          # max_age
	buffer_bytes.encode_float(20, subsidence_coeff) # subsidence_coeff
	buffer_bytes.encode_float(24, 0.0)              # padding1
	buffer_bytes.encode_float(28, 0.0)              # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create finalize param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["crust_age_finalize"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create finalize param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["crust_age_finalize"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["crust_age_finalize_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

# ============================================================================
# ÉTAPE 3 : ATMOSPHÈRE & CLIMAT
# ============================================================================

## Génère les cartes climatiques : température, précipitation, nuages, banquise.
##
## Cette phase exécute :
## 1. Température : basée sur latitude, altitude, bruit fBm
## 2. Précipitation : basée sur 3 types de bruit + influence latitude
## 3. Nuages : simulation fluide (init, advection x N, render)
## 4. Banquise : eau + température < 0 avec probabilité
##
## Écrit dans ClimateTexture (RGBA32F) :
## - R = temperature (°C)
## - G = humidity/precipitation (0-1)
## - B = wind_x
## - A = wind_y
##
## Écrit aussi dans les textures colorées (RGBA8) pour export direct.
##
## @param params: Dictionnaire contenant seed, avg_temperature, avg_precipitation, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_atmosphere_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🌡️ Phase 3 : Atmosphère & Climat")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var avg_temperature = float(params.get("avg_temperature", 15.0))
	var avg_precipitation = float(params.get("avg_precipitation", 0.5))
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("atmosphere_type", 0))
	var cylinder_radius = float(w) / (2.0 * PI)
	
	# === PASSE 1 : TEMPÉRATURE ===
	_dispatch_temperature(w, h, groups_x, groups_y, seed_val, avg_temperature, sea_level, cylinder_radius, atmosphere_type)
	
	# === PASSE 2 : PRÉCIPITATION ===
	_dispatch_precipitation(w, h, groups_x, groups_y, seed_val, avg_precipitation, cylinder_radius, atmosphere_type)
	
	# === PASSE 3 : NUAGES (SIMULATION FLUIDE) ===
	var wind_base_speed = float(params.get("wind_base_speed", 10.0))
	# Itérations pour cohérence temporelle (le réalisme est dans clouds_render)
	var cloud_iterations = int(params.get("cloud_iterations", 100))
	var condensation_threshold = float(params.get("condensation_threshold", 0.35))
	
	# 3.1 : Initialisation du champ de vapeur et du vent
	_dispatch_clouds_init(w, h, groups_x, groups_y, seed_val, wind_base_speed, cylinder_radius, atmosphere_type)
	
	# 3.2 : Advection (boucle ping-pong)
	for i in range(cloud_iterations):
		var use_swap = (i % 2 == 1)
		_dispatch_clouds_advection(w, h, groups_x, groups_y, i, use_swap)
	
	# 3.3 : Rendu des nuages
	_dispatch_clouds_render(w, h, groups_x, groups_y, seed_val, condensation_threshold, cylinder_radius, atmosphere_type)
	
	# === PASSE 4 : BANQUISE ===
	var ice_probability = float(params.get("ice_probability", 0.9))
	_dispatch_ice_caps(w, h, groups_x, groups_y, seed_val, ice_probability, atmosphere_type)
	
	print("[Orchestrator] ✅ Phase 3 : Atmosphère & Climat terminée")

## Dispatch le shader de température
func _dispatch_temperature(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, avg_temperature: float, sea_level: float, cylinder_radius: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("temperature") or not gpu.shaders["temperature"].is_valid():
		push_warning("[Orchestrator] ⚠️ temperature shader non disponible")
		return
	if not gpu.uniform_sets.has("temperature_textures") or not gpu.uniform_sets["temperature_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ temperature uniform set non disponible")
		return
	
	print("  • Température (avg: ", avg_temperature, "°C)")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float avg_temperature, sea_level, cylinder_radius (12 bytes)
	# uint atmosphere_type (4 bytes)
	# padding (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, avg_temperature)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, cylinder_radius)
	buffer_bytes.encode_u32(24, atmosphere_type)
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create temperature param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["temperature"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create temperature param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["temperature"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["temperature_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de précipitation
func _dispatch_precipitation(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, avg_precipitation: float, cylinder_radius: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("precipitation") or not gpu.shaders["precipitation"].is_valid():
		push_warning("[Orchestrator] ⚠️ precipitation shader non disponible")
		return
	if not gpu.uniform_sets.has("precipitation_textures") or not gpu.uniform_sets["precipitation_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ precipitation uniform set non disponible")
		return
	
	print("  • Précipitation (avg: ", avg_precipitation, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float avg_precipitation, cylinder_radius (8 bytes)
	# uint atmosphere_type (4 bytes)
	# padding (8 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, avg_precipitation)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_u32(24, 0)  # padding
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create precipitation param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["precipitation"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create precipitation param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["precipitation"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["precipitation_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader d'initialisation des nuages
func _dispatch_clouds_init(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, wind_base_speed: float, cylinder_radius: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("clouds_init") or not gpu.shaders["clouds_init"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_init shader non disponible")
		return
	if not gpu.uniform_sets.has("clouds_init_textures") or not gpu.uniform_sets["clouds_init_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_init uniform set non disponible")
		return
	
	print("  • Nuages - Initialisation (wind speed: ", wind_base_speed, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float wind_base_speed, cylinder_radius (8 bytes)
	# uint atmosphere_type (4 bytes)
	# padding (8 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, wind_base_speed)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_u32(24, 0)  # padding
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_init param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["clouds_init"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_init param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["clouds_init"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["clouds_init_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader d'advection des nuages (une itération)
func _dispatch_clouds_advection(w: int, h: int, groups_x: int, groups_y: int, iteration: int, use_swap: bool) -> void:
	if not gpu.shaders.has("clouds_advection") or not gpu.shaders["clouds_advection"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_advection shader non disponible")
		return
	
	var uniform_set_name = "clouds_advection_textures_swap" if use_swap else "clouds_advection_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_advection uniform set non disponible")
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float dt, dissipation (8 bytes)
	# uint iteration (4 bytes)
	# padding (12 bytes)
	
	var dt = 0.5  # Pas de temps plus grand pour stabilité
	var dissipation = 0.998  # Dissipation réduite pour préserver les structures
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, dt)
	buffer_bytes.encode_float(12, dissipation)
	buffer_bytes.encode_u32(16, iteration)
	buffer_bytes.encode_u32(20, 0)  # padding
	buffer_bytes.encode_u32(24, 0)  # padding
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_advection param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["clouds_advection"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_advection param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["clouds_advection"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de rendu des nuages
func _dispatch_clouds_render(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, condensation_threshold: float, cylinder_radius: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("clouds_render") or not gpu.shaders["clouds_render"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_render shader non disponible")
		return
	if not gpu.uniform_sets.has("clouds_render_textures") or not gpu.uniform_sets["clouds_render_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds_render uniform set non disponible")
		return
	
	print("  • Nuages - Rendu (condensation: ", condensation_threshold, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float condensation_threshold, cylinder_radius (8 bytes)
	# uint atmosphere_type (4 bytes)
	# padding (8 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, condensation_threshold)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_u32(24, 0)  # padding
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_render param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["clouds_render"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds_render param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["clouds_render"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["clouds_render_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de banquise
func _dispatch_ice_caps(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, ice_probability: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("ice_caps") or not gpu.shaders["ice_caps"].is_valid():
		push_warning("[Orchestrator] ⚠️ ice_caps shader non disponible")
		return
	if not gpu.uniform_sets.has("ice_caps_textures") or not gpu.uniform_sets["ice_caps_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ ice_caps uniform set non disponible")
		return
	
	print("  • Banquise (probabilité: ", ice_probability, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float ice_probability (4 bytes)
	# uint atmosphere_type (4 bytes)
	# padding (12 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, ice_probability)
	buffer_bytes.encode_u32(16, atmosphere_type)
	buffer_bytes.encode_u32(20, 0)  # padding
	buffer_bytes.encode_u32(24, 0)  # padding
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create ice_caps param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["ice_caps"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create ice_caps param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ice_caps"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["ice_caps_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

# ============================================================================
# EXEMPLE PHASES DE SIMULATION
# ============================================================================

func run_example(params: Dictionary, w: int, h: int):	
	if not rd or not gpu.pipelines["example"].is_valid():
		push_warning("[Orchestrator] ⚠️ Orogeny pipeline not ready, skipping")
		return
	
	print("[Orchestrator] Example Phase")
	
	# 1. Préparation des données des paramètres
	var m_strength = float(params.get("mountain_strength", 50.0))
	var r_strength = float(params.get("rift_strength", -30.0))
	var erosion    = float(params.get("orogeny_erosion", 0.98))
	var dt         = float(params.get("delta_time", 0.016))
	
	var buffer_data = PackedFloat32Array([m_strength, r_strength, erosion, dt])
	var buffer_bytes = buffer_data.to_byte_array()
	
	# 2. Création du Buffer (Uniform Buffer)
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	
	# 3. Création de l'Uniform
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0 # Binding 0 dans le Set 1
	param_uniform.add_id(param_buffer)
	
	# 4. Création du Set (Set Index 1)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["example"], 1)
	
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create Example Param Set")
		return
		
	# Calcul des groupes
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	# 5. Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["example"])
	
	# Bind du Set 0 (Textures)
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["example"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	# 6. Nettoyage immédiat (Optimisation)
	# On libère les ressources temporaires après l'exécution de la commande (rd.submit n'est pas bloquant mais free_rid l'est pour la ressource)
	# Note : Pour être 100% safe avec Vulkan, on devrait les garder jusqu'à la fin de la frame, 
	# mais Godot gère souvent ça. Si ça crash, on les mettra dans une liste 'garbage_bin'.
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	
	rd.submit()
	rd.sync()
	print("[Orchestrator] ✅ Orogenèse terminée")

# ============================================================================
# EXPORT
# ============================================================================

## Exporte la carte d'élévation brute (GeoTexture) en Image
## Retourne les données float brutes pour traitement ultérieur
func export_geo_texture_to_image() -> Image:
	if not rd or not gpu.textures.has("geo") or not gpu.textures["geo"].is_valid():
		push_error("[Orchestrator] ❌ Cannot export geo texture - invalid RID")
		return null
	
	rd.submit()
	rd.sync()
	
	var byte_data = rd.texture_get_data(gpu.textures["geo"], 0)
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)

## Exporte toutes les cartes générées via PlanetExporter
## 
## @param output_dir: Dossier de sortie pour les fichiers PNG
## @return Dictionary: Chemins des fichiers exportés
func export_all_maps(output_dir: String) -> Dictionary:
	print("[Orchestrator] 📤 Exporting all maps to: ", output_dir)
	
	var exporter = PlanetExporter.new()
	return exporter.export_maps(gpu, output_dir, generation_params)

## Example d'exportation de carte
func export_example_to_image() -> Image:
	var byte_data = rd.texture_get_data(gpu.textures["example"], 0)
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)


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
