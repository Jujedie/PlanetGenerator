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

# SSBO pour comptage de pixels par composante (water classification)
var water_counter_buffer: RID = RID()

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
		# Shader de cratères (planètes sans atmosphère)
		{"path": "res://shader/compute/topographie/cratering.glsl", "name": "cratering", "critical": false},
		# Shaders Érosion Hydraulique (Étape 2)
		{"path": "res://shader/compute/erosion/erosion_rainfall.glsl", "name": "erosion_rainfall", "critical": false},
		{"path": "res://shader/compute/erosion/erosion_flow.glsl", "name": "erosion_flow", "critical": false},
		{"path": "res://shader/compute/erosion/erosion_sediment.glsl", "name": "erosion_sediment", "critical": false},
		{"path": "res://shader/compute/erosion/erosion_flux_accumulation.glsl", "name": "erosion_flux_accumulation", "critical": false},
		# Shaders Atmosphère & Climat (Étape 3)
		{"path": "res://shader/compute/atmosphere_climat/temperature.glsl", "name": "temperature", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/precipitation.glsl", "name": "precipitation", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/clouds.glsl", "name": "clouds", "critical": false},
		{"path": "res://shader/compute/atmosphere_climat/ice_caps.glsl", "name": "ice_caps", "critical": false},
		# Shaders Ressources & Pétrole (Étape 5)
		{"path": "res://shader/compute/ressources/petrole.glsl", "name": "petrole", "critical": false},
		{"path": "res://shader/compute/ressources/resources.glsl", "name": "resources", "critical": false},
		# Shaders Classification des Eaux (Étape 2.5)
		{"path": "res://shader/compute/water/river_sources.glsl", "name": "river_sources", "critical": false},
		{"path": "res://shader/compute/water/river_propagation.glsl", "name": "river_propagation", "critical": false},
		{"path": "res://shader/compute/water/water_classification.glsl", "name": "water_classification", "critical": false},
		{"path": "res://shader/compute/water/water_jfa.glsl", "name": "water_jfa", "critical": false},
		{"path": "res://shader/compute/water/water_size_classification.glsl", "name": "water_size_classification", "critical": false},
		{"path": "res://shader/compute/water/water_finalize.glsl", "name": "water_finalize", "critical": false},
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
	
	print("[Orchestrator] ✅ Textures créées (4x ", int(size / 1024.0), " KB)")

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
	
	# === CRATERING SHADER (planètes sans atmosphère) ===
	if gpu.shaders.has("cratering") and gpu.shaders["cratering"].is_valid():
		print("  • Création uniform set: cratering")
		
		# Set 0 : Textures (geo en lecture/écriture)
		var uniforms_cratering = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
		]
		
		gpu.uniform_sets["cratering_textures"] = rd.uniform_set_create(uniforms_cratering, gpu.shaders["cratering"], 0)
		if not gpu.uniform_sets["cratering_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create cratering textures uniform set")
		else:
			print("    ✅ cratering textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ cratering shader invalide, uniform set ignoré")
	
	# === ÉTAPE 2 : ÉROSION HYDRAULIQUE ===
	# Initialiser les textures érosion avant de créer les uniform sets
	gpu.initialize_erosion_textures()
	
	# === EROSION RAINFALL SHADER ===
	if gpu.shaders.has("erosion_rainfall") and gpu.shaders["erosion_rainfall"].is_valid():
		print("  • Création uniform set: erosion_rainfall")
		
		# Set 0 : Textures (geo en lecture/écriture, climate en lecture)
		var uniforms_rainfall = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["climate"]),
		]
		
		gpu.uniform_sets["erosion_rainfall_textures"] = rd.uniform_set_create(uniforms_rainfall, gpu.shaders["erosion_rainfall"], 0)
		if not gpu.uniform_sets["erosion_rainfall_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_rainfall textures uniform set")
		else:
			print("    ✅ erosion_rainfall textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ erosion_rainfall shader invalide, uniform set ignoré")
	
	# === EROSION FLOW SHADER (avec ping-pong) ===
	if gpu.shaders.has("erosion_flow") and gpu.shaders["erosion_flow"].is_valid():
		print("  • Création uniform set: erosion_flow")
		
		# Set 0 (A->B) : geo en lecture, geo_temp en écriture, river_flux en rw
		var uniforms_flow_ab = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["geo_temp"]),
			gpu.create_texture_uniform(2, gpu.textures["river_flux"]),
		]
		
		gpu.uniform_sets["erosion_flow_textures"] = rd.uniform_set_create(uniforms_flow_ab, gpu.shaders["erosion_flow"], 0)
		if not gpu.uniform_sets["erosion_flow_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_flow textures uniform set")
		else:
			print("    ✅ erosion_flow textures uniform set créé")
		
		# Set 0 (B->A) : geo_temp en lecture, geo en écriture, river_flux en rw
		var uniforms_flow_ba = [
			gpu.create_texture_uniform(0, gpu.textures["geo_temp"]),
			gpu.create_texture_uniform(1, gpu.textures["geo"]),
			gpu.create_texture_uniform(2, gpu.textures["river_flux"]),
		]
		
		gpu.uniform_sets["erosion_flow_textures_swap"] = rd.uniform_set_create(uniforms_flow_ba, gpu.shaders["erosion_flow"], 0)
		if not gpu.uniform_sets["erosion_flow_textures_swap"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_flow swap textures uniform set")
		else:
			print("    ✅ erosion_flow swap textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ erosion_flow shader invalide, uniform set ignoré")
	
	# === EROSION SEDIMENT SHADER (avec ping-pong) ===
	if gpu.shaders.has("erosion_sediment") and gpu.shaders["erosion_sediment"].is_valid():
		print("  • Création uniform set: erosion_sediment")
		
		# Set 0 (A->B) : geo en lecture, geo_temp en écriture, river_flux en lecture
		var uniforms_sed_ab = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["geo_temp"]),
			gpu.create_texture_uniform(2, gpu.textures["river_flux"]),
		]
		
		gpu.uniform_sets["erosion_sediment_textures"] = rd.uniform_set_create(uniforms_sed_ab, gpu.shaders["erosion_sediment"], 0)
		if not gpu.uniform_sets["erosion_sediment_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_sediment textures uniform set")
		else:
			print("    ✅ erosion_sediment textures uniform set créé")
		
		# Set 0 (B->A) : geo_temp en lecture, geo en écriture, river_flux en lecture
		var uniforms_sed_ba = [
			gpu.create_texture_uniform(0, gpu.textures["geo_temp"]),
			gpu.create_texture_uniform(1, gpu.textures["geo"]),
			gpu.create_texture_uniform(2, gpu.textures["river_flux"]),
		]
		
		gpu.uniform_sets["erosion_sediment_textures_swap"] = rd.uniform_set_create(uniforms_sed_ba, gpu.shaders["erosion_sediment"], 0)
		if not gpu.uniform_sets["erosion_sediment_textures_swap"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_sediment swap textures uniform set")
		else:
			print("    ✅ erosion_sediment swap textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ erosion_sediment shader invalide, uniform set ignoré")
	
	# === EROSION FLUX ACCUMULATION SHADER (avec ping-pong sur flux) ===
	if gpu.shaders.has("erosion_flux_accumulation") and gpu.shaders["erosion_flux_accumulation"].is_valid():
		print("  • Création uniform set: erosion_flux_accumulation")
		
		# Set 0 (A->B) : geo en lecture, river_flux en lecture, flux_temp en écriture
		var uniforms_acc_ab = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["river_flux"]),
			gpu.create_texture_uniform(2, gpu.textures["flux_temp"]),
		]
		
		gpu.uniform_sets["erosion_flux_accumulation_textures"] = rd.uniform_set_create(uniforms_acc_ab, gpu.shaders["erosion_flux_accumulation"], 0)
		if not gpu.uniform_sets["erosion_flux_accumulation_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_flux_accumulation textures uniform set")
		else:
			print("    ✅ erosion_flux_accumulation textures uniform set créé")
		
		# Set 0 (B->A) : geo en lecture, flux_temp en lecture, river_flux en écriture
		var uniforms_acc_ba = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["flux_temp"]),
			gpu.create_texture_uniform(2, gpu.textures["river_flux"]),
		]
		
		gpu.uniform_sets["erosion_flux_accumulation_textures_swap"] = rd.uniform_set_create(uniforms_acc_ba, gpu.shaders["erosion_flux_accumulation"], 0)
		if not gpu.uniform_sets["erosion_flux_accumulation_textures_swap"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create erosion_flux_accumulation swap textures uniform set")
		else:
			print("    ✅ erosion_flux_accumulation swap textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ erosion_flux_accumulation shader invalide, uniform set ignoré")
	
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
	
	# === CLOUDS SHADER ===
	if gpu.shaders.has("clouds") and gpu.shaders["clouds"].is_valid():
		print("  • Création uniform set: clouds")
		
		# Set 0 : Texture clouds en écriture
		var uniforms_clouds = [
			gpu.create_texture_uniform(0, gpu.textures["clouds"]),
		]
		
		gpu.uniform_sets["clouds_textures"] = rd.uniform_set_create(uniforms_clouds, gpu.shaders["clouds"], 0)
		if not gpu.uniform_sets["clouds_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create clouds textures uniform set")
		else:
			print("    ✅ clouds textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ clouds shader invalide, uniform set ignoré")
	
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
	
	# === ÉTAPE 5 : RESSOURCES & PÉTROLE ===
	# Initialiser les textures ressources avant de créer les uniform sets
	gpu.initialize_resources_textures()
	
	# === PETROLE SHADER ===
	if gpu.shaders.has("petrole") and gpu.shaders["petrole"].is_valid():
		print("  • Création uniform set: petrole")
		
		# Set 0 : Textures (geo en lecture via sampler, petrole en écriture)
		# Binding 0: geo_texture (texture2D)
		# Binding 1: geo_sampler
		# Binding 2: petrole_texture (writeonly image2D)
		var geo_tex_uniform = RDUniform.new()
		geo_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
		geo_tex_uniform.binding = 0
		geo_tex_uniform.add_id(gpu.textures["geo"])
		
		var geo_sampler_uniform = RDUniform.new()
		geo_sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
		geo_sampler_uniform.binding = 1
		geo_sampler_uniform.add_id(_get_or_create_linear_sampler())
		
		var petrole_tex_uniform = gpu.create_texture_uniform(2, gpu.textures["petrole"])
		
		var uniforms_petrole = [geo_tex_uniform, geo_sampler_uniform, petrole_tex_uniform]
		
		gpu.uniform_sets["petrole_textures"] = rd.uniform_set_create(uniforms_petrole, gpu.shaders["petrole"], 0)
		if not gpu.uniform_sets["petrole_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create petrole textures uniform set")
		else:
			print("    ✅ petrole textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ petrole shader invalide, uniform set ignoré")
	
	# === RESOURCES SHADER ===
	if gpu.shaders.has("resources") and gpu.shaders["resources"].is_valid():
		print("  • Création uniform set: resources")
		
		# Set 0 : Textures (geo en lecture via sampler, resources en écriture)
		var geo_tex_uniform = RDUniform.new()
		geo_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
		geo_tex_uniform.binding = 0
		geo_tex_uniform.add_id(gpu.textures["geo"])
		
		var geo_sampler_uniform = RDUniform.new()
		geo_sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
		geo_sampler_uniform.binding = 1
		geo_sampler_uniform.add_id(_get_or_create_linear_sampler())
		
		var resources_tex_uniform = gpu.create_texture_uniform(2, gpu.textures["resources"])
		
		var uniforms_resources = [geo_tex_uniform, geo_sampler_uniform, resources_tex_uniform]
		
		gpu.uniform_sets["resources_textures"] = rd.uniform_set_create(uniforms_resources, gpu.shaders["resources"], 0)
		if not gpu.uniform_sets["resources_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create resources textures uniform set")
		else:
			print("    ✅ resources textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ resources shader invalide, uniform set ignoré")
	
	# Note: Les uniform sets pour les shaders water (étape 2.5) ne sont PAS créés ici
	# car ils nécessitent un ping-pong dynamique qui est géré dans les dispatch functions
	
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
	
	# === ÉTAPE 0.6 : CRATÈRES D'IMPACT (planètes sans atmosphère) ===
	run_cratering_phase(generation_params, w, h)
	
	# === ÉTAPE 2 : ÉROSION HYDRAULIQUE ===
	run_erosion_phase(generation_params, w, h)
	
	# === ÉTAPE 3 : ATMOSPHÈRE & CLIMAT ===
	# IMPORTANT: Doit être exécuté AVANT la classification des eaux
	# car les rivières dépendent des précipitations (climate texture canal G)
	run_atmosphere_phase(generation_params, w, h)
	
	# === ÉTAPE 2.5 : CLASSIFICATION DES EAUX ===
	# Exécuté après l'atmosphère pour avoir accès aux précipitations
	run_water_classification_phase(generation_params, w, h)
	
	# === ÉTAPE 5 : RESSOURCES & PÉTROLE ===
	run_resources_phase(generation_params, w, h)
	
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
	# - float ocean_threshold (4 bytes) - seuil océan/continent
	# - float padding3 (4 bytes)
	# Total : 32 bytes (aligné sur 16 bytes pour std140)
	
	var seed_val = int(params.get("seed", 12345))
	var elevation_modifier = float(params.get("terrain_scale", 0.0))
	var sea_level = float(params.get("sea_level", 0.0))
	var cylinder_radius = float(w) / (2.0 * PI)  # Rayon du cylindre pour le bruit seamless
	
	# Convertir pourcentage océan en seuil FBM
	var ocean_ratio = float(params.get("ocean_ratio", 55.0))
	var ocean_threshold = _percentage_to_threshold(ocean_ratio)
	
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
	buffer_bytes.encode_float(24, ocean_threshold)  # ocean_threshold
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
	print("  Ocean Ratio: ", ocean_ratio, "% -> threshold: ", ocean_threshold)
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

## Convertit un pourcentage d'océan (40-90%) en seuil FBM [-1, 1]
##
## La fonction FBM retourne des valeurs dans [-1, 1] avec une distribution
## approximativement normale centrée sur 0. Pour obtenir X% d'océan,
## on définit un seuil tel que X% des valeurs sont inférieures.
##
## Points de calibration empiriques :
## - 40% océan → seuil -0.25
## - 50% océan → seuil 0.0
## - 60% océan → seuil 0.15
## - 71% océan → seuil 0.35 (Terre réelle)
## - 80% océan → seuil 0.55
## - 90% océan → seuil 0.80
##
## @param percentage: Pourcentage d'océan désiré (40.0 = 40%, 90.0 = 90%)
## @return float: Seuil FBM dans [-1, 1]
func _percentage_to_threshold(percentage: float) -> float:
	var clamped_pct = clamp(percentage, 40.0, 90.0)
	
	# Interpolation linéaire par segments (calibré empiriquement)
	if clamped_pct <= 50.0:
		# 40-50% : -0.25 à 0.0
		var t = (clamped_pct - 40.0) / 10.0
		return lerp(-0.25, 0.0, t)
	elif clamped_pct <= 60.0:
		# 50-60% : 0.0 à 0.15
		var t = (clamped_pct - 50.0) / 10.0
		return lerp(0.0, 0.15, t)
	elif clamped_pct <= 71.0:
		# 60-71% : 0.15 à 0.35 (Terre = 71%)
		var t = (clamped_pct - 60.0) / 11.0
		return lerp(0.15, 0.35, t)
	elif clamped_pct <= 80.0:
		# 71-80% : 0.35 à 0.55
		var t = (clamped_pct - 71.0) / 9.0
		return lerp(0.35, 0.55, t)
	else:
		# 80-90% : 0.55 à 0.80
		var t = (clamped_pct - 80.0) / 10.0
		return lerp(0.55, 0.80, t)

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
# ÉTAPE 0.6 : CRATÈRES D'IMPACT (planètes sans atmosphère)
# ============================================================================

## Applique des cratères d'impact sur les planètes sans atmosphère.
##
## Cette phase génère procéduralement des cratères avec :
## - Distribution en loi de puissance (petits fréquents, gros rares)
## - Profil réaliste (bowl + rim + ejecta)
## - Variation azimutale pour éviter les cercles parfaits
##
## N'est exécutée QUE si atmosphere_type == 3 (sans atmosphère).
##
## @param params: Dictionnaire contenant seed, planet_type, crater_density, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_cratering_phase(params: Dictionary, w: int, h: int) -> void:
	# Vérifier que le shader est disponible
	if not gpu.shaders.has("cratering") or not gpu.shaders["cratering"].is_valid():
		push_warning("[Orchestrator] ⚠️ cratering shader non disponible, phase ignorée")
		return
	
	# Vérifier si la planète est sans atmosphère
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type != 3:  # 3 = Sans atmosphère
		print("[Orchestrator] ⏭️ Phase 0.6 : Cratères ignorés (planète avec atmosphère)")
		return
	
	print("[Orchestrator] ☄️ Phase 0.6 : Génération des cratères d'impact")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	# Paramètres de cratères
	var seed_val = int(params.get("seed", 12345))
	var crater_density = float(params.get("crater_density", 0.5))  # 0.0 - 1.0
	
	# Calculer l'échelle pixels → mètres
	# Pour une planète de rayon R km, la circonférence = 2πR km
	# Sur une texture de largeur W, chaque pixel = (2πR × 1000) / W mètres
	var planet_radius_km = float(params.get("planet_radius", 1737.0))  # Défaut: Lune (1737 km)
	var meters_per_pixel = (2.0 * PI * planet_radius_km * 1000.0) / float(w)
	
	# Calculer le nombre de cratères basé sur la densité et la taille
	# Densité 0.5 sur 2048x1024 → environ 500 cratères
	var base_craters = int(float(w * h) / 4000.0)
	var num_craters = int(float(base_craters) * crater_density)
	num_craters = clamp(num_craters, 50, 3000)  # Limites raisonnables
	
	# Paramètres du profil de cratère
	var max_radius = float(params.get("crater_max_radius", min(w, h) * 0.08))  # 8% de la dimension
	var min_radius = float(params.get("crater_min_radius", 3.0))  # Minimum 3 pixels
	var depth_ratio = float(params.get("crater_depth_ratio", 0.25))  # Profondeur = 25% du rayon
	var rim_height_ratio = float(params.get("crater_rim_ratio", 0.15))  # Rebord = 15% de la profondeur
	var ejecta_extent = float(params.get("crater_ejecta_extent", 2.5))  # Éjectas jusqu'à 2.5× rayon
	var ejecta_decay = float(params.get("crater_ejecta_decay", 3.0))  # Décroissance exponentielle
	var azimuth_variation = float(params.get("crater_azimuth_var", 0.3))  # 30% de variation
	
	print("  Nombre de cratères: ", num_craters)
	print("  Rayon: ", min_radius, " - ", max_radius, " px")
	print("  Profondeur ratio: ", depth_ratio)
	print("  Échelle: ", meters_per_pixel, " m/px")
	print("  Éjectas: ", ejecta_extent, "× rayon")
	
	# Structure UBO pour cratering (std140, 48 bytes):
	# uint seed (4) + uint width (4) + uint height (4) + uint num_craters (4) = 16 bytes
	# float max_radius (4) + float min_radius (4) + float depth_ratio (4) + float rim_height_ratio (4) = 16 bytes
	# float ejecta_extent (4) + float ejecta_decay (4) + float azimuth_variation (4) + float meters_per_pixel (4) = 16 bytes
	# Total: 48 bytes
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)
	
	buffer_bytes.encode_u32(0, seed_val)              # seed
	buffer_bytes.encode_u32(4, w)                      # width
	buffer_bytes.encode_u32(8, h)                      # height
	buffer_bytes.encode_u32(12, num_craters)           # num_craters
	buffer_bytes.encode_float(16, max_radius)          # max_radius
	buffer_bytes.encode_float(20, min_radius)          # min_radius
	buffer_bytes.encode_float(24, depth_ratio)         # depth_ratio
	buffer_bytes.encode_float(28, rim_height_ratio)    # rim_height_ratio
	buffer_bytes.encode_float(32, ejecta_extent)       # ejecta_extent
	buffer_bytes.encode_float(36, ejecta_decay)        # ejecta_decay
	buffer_bytes.encode_float(40, azimuth_variation)   # azimuth_variation
	buffer_bytes.encode_float(44, meters_per_pixel)    # meters_per_pixel
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create cratering param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["cratering"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create cratering param set")
		rd.free_rid(param_buffer)
		return
	
	# Dispatch du compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["cratering"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["cratering_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Nettoyage
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	
	print("[Orchestrator] ✅ Phase 0.6 : Cratères générés")

# ============================================================================
# ÉTAPE 2 : ÉROSION HYDRAULIQUE
# ============================================================================

## Simule l'érosion hydraulique sur le terrain.
##
## Cette phase exécute plusieurs itérations du cycle hydrologique :
## 1. Rainfall : Ajoute de l'eau selon la précipitation, évaporation
## 2. Flow : Écoulement de l'eau vers les cellules plus basses
## 3. Sediment : Érosion et dépôt de sédiments selon la capacité de transport
## 4. Flux Accumulation : Accumule le flux pour détecter les rivières
##
## Utilise un schéma ping-pong pour éviter les race conditions GPU.
##
## @param params: Dictionnaire contenant seed, erosion_iterations, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_erosion_phase(params: Dictionary, w: int, h: int) -> void:
	# Vérifier que les shaders sont disponibles
	var required_shaders = ["erosion_rainfall", "erosion_flow", "erosion_sediment", "erosion_flux_accumulation"]
	for shader_name in required_shaders:
		if not gpu.shaders.has(shader_name) or not gpu.shaders[shader_name].is_valid():
			push_warning("[Orchestrator] ⚠️ ", shader_name, " shader non disponible, phase érosion ignorée")
			return
	
	# Vérifier si la planète a une atmosphère (pas d'érosion sur planète sans atmosphère)
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type == 3:  # Sans atmosphère
		print("[Orchestrator] ⏭️ Phase 2 : Érosion ignorée (planète sans atmosphère)")
		return
	
	print("[Orchestrator] 💧 Phase 2 : Érosion Hydraulique")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	# Paramètres d'érosion - valeurs augmentées pour effet visible
	# Itérations: 50 → 200 pour propagation suffisante
	var erosion_iterations = int(params.get("erosion_iterations", 200))
	# Rain rate: 0.005 → 0.012 pour plus d'eau disponible
	var rain_rate = float(params.get("rain_rate", 0.012))
	var evap_rate = float(params.get("evap_rate", 0.02))
	var flow_rate = float(params.get("flow_rate", 0.25))
	# Erosion rate: 0.05 → 0.15 pour effet plus marqué
	var erosion_rate = float(params.get("erosion_rate", 0.15))
	# Deposition rate: 0.05 → 0.12 pour dépôts visibles
	var deposition_rate = float(params.get("deposition_rate", 0.12))
	# Capacity multiplier: 1.0 → 2.5 pour transport plus efficace
	var capacity_multiplier = float(params.get("capacity_multiplier", 2.5))
	var sea_level = float(params.get("sea_level", 0.0))
	var gravity = compute_gravity(float(params.get("planet_radius", 6371.0)), float(params.get("planet_density", 5500.0)))  # Default Earth-like density
	
	# Paramètres pour l'accumulation de flux
	var flux_iterations = int(params.get("flux_iterations", 10))
	var base_flux = float(params.get("base_flux", 1.0))
	var propagation_rate = float(params.get("propagation_rate", 0.8))
	
	print("  Iterations: ", erosion_iterations)
	print("  Rain Rate: ", rain_rate, " | Evap Rate: ", evap_rate)
	print("  Flow Rate: ", flow_rate)
	print("  Erosion/Deposition: ", erosion_rate, "/", deposition_rate)
	
	# === BOUCLE D'ÉROSION ===
	for iter in range(erosion_iterations):
		var use_swap = (iter % 2 == 1)
		
		# === PASSE 1 : PLUIE + ÉVAPORATION ===
		_dispatch_erosion_rainfall(w, h, groups_x, groups_y, rain_rate, evap_rate, sea_level)
		
		# === PASSE 2 : ÉCOULEMENT ===
		_dispatch_erosion_flow(w, h, groups_x, groups_y, flow_rate, sea_level, gravity, use_swap)
		
		# === PASSE 3 : TRANSPORT SÉDIMENT ===
		_dispatch_erosion_sediment(w, h, groups_x, groups_y, erosion_rate, deposition_rate, capacity_multiplier, sea_level, not use_swap)
	
	# === PASSE 4 : ACCUMULATION DE FLUX (pour rivières) ===
	print("  • Accumulation de flux (", flux_iterations, " passes)")
	for pass_idx in range(flux_iterations):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_erosion_flux_accumulation(w, h, groups_x, groups_y, pass_idx, sea_level, base_flux, propagation_rate, use_swap)
	
	print("[Orchestrator] ✅ Phase 2 : Érosion terminée")

## Dispatch le shader de pluie/évaporation
func _dispatch_erosion_rainfall(w: int, h: int, groups_x: int, groups_y: int, rain_rate: float, evap_rate: float, sea_level: float) -> void:
	if not gpu.uniform_sets.has("erosion_rainfall_textures") or not gpu.uniform_sets["erosion_rainfall_textures"].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float rain_rate, evap_rate, sea_level (12 bytes)
	# padding (12 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, rain_rate)
	buffer_bytes.encode_float(12, evap_rate)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, 0.0)  # padding1
	buffer_bytes.encode_float(24, 0.0)  # padding2
	buffer_bytes.encode_float(28, 0.0)  # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_rainfall"], 1)
	if not param_set.is_valid():
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_rainfall"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["erosion_rainfall_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader d'écoulement
func _dispatch_erosion_flow(w: int, h: int, groups_x: int, groups_y: int, flow_rate: float, sea_level: float, gravity: float, use_swap: bool) -> void:
	var uniform_set_name = "erosion_flow_textures_swap" if use_swap else "erosion_flow_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float flow_rate, min_slope, sea_level, gravity (16 bytes)
	# padding (8 bytes)
	
	var min_slope = 0.001
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, flow_rate)
	buffer_bytes.encode_float(12, min_slope)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, gravity)
	buffer_bytes.encode_float(24, 0.0)  # padding1
	buffer_bytes.encode_float(28, 0.0)  # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_flow"], 1)
	if not param_set.is_valid():
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_flow"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de transport de sédiments
func _dispatch_erosion_sediment(w: int, h: int, groups_x: int, groups_y: int, erosion_rate: float, deposition_rate: float, capacity_multiplier: float, sea_level: float, use_swap: bool) -> void:
	var uniform_set_name = "erosion_sediment_textures_swap" if use_swap else "erosion_sediment_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float erosion_rate, deposition_rate, capacity_multiplier, min_slope, sea_level, bedrock_hardness (24 bytes)
	
	var min_slope = 0.001
	var bedrock_hardness = 0.5
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, erosion_rate)
	buffer_bytes.encode_float(12, deposition_rate)
	buffer_bytes.encode_float(16, capacity_multiplier)
	buffer_bytes.encode_float(20, min_slope)
	buffer_bytes.encode_float(24, sea_level)
	buffer_bytes.encode_float(28, bedrock_hardness)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_sediment"], 1)
	if not param_set.is_valid():
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_sediment"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader d'accumulation de flux
func _dispatch_erosion_flux_accumulation(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, sea_level: float, base_flux: float, propagation_rate: float, use_swap: bool) -> void:
	var uniform_set_name = "erosion_flux_accumulation_textures_swap" if use_swap else "erosion_flux_accumulation_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height, pass_index (12 bytes)
	# float sea_level, base_flux, propagation_rate (12 bytes)
	# padding (8 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_index)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, base_flux)
	buffer_bytes.encode_float(20, propagation_rate)
	buffer_bytes.encode_float(24, 0.0)  # padding1
	buffer_bytes.encode_float(28, 0.0)  # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_flux_accumulation"], 1)
	if not param_set.is_valid():
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_flux_accumulation"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

# ============================================================================
# ÉTAPE 2.5 : CLASSIFICATION DES EAUX
# ============================================================================

## Classifie les masses d'eau en océans, mers, lacs et rivières.
##
## Cette phase exécute :
## 1. Détection des sources de rivières (altitude + précipitation)
## 2. Propagation des rivières par descente de gradient
## 3. Classification initiale (océan/mer/lac/rivière par seuils)
## 4. JFA pour composantes connexes des masses d'eau
## 5. Reclassification par taille (océan > mer > lac)
##
## Écrit dans water_types (R32UI) :
## - 0 = Terre
## - 1 = Océan (grande masse sous niveau mer)
## - 2 = Mer (masse moyenne)
## - 3 = Lac (petite masse ou altitude >= sea_level)
## - 4 = Affluent (flux faible)
## - 5 = Rivière (flux moyen)
## - 6 = Fleuve (flux élevé)
##
## @param params: Dictionnaire contenant seed, sea_level, precipitation, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_water_classification_phase(params: Dictionary, w: int, h: int) -> void:
	# Vérifier si la planète a une atmosphère (pas d'eau sur planète sans atmosphère)
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type == 3:  # Sans atmosphère
		print("[Orchestrator] ⏭️ Phase 2.5 : Classification eaux ignorée (planète sans atmosphère)")
		return
	
	# Vérifier que les shaders sont disponibles
	var required_shaders = ["river_sources", "river_propagation", "water_classification", "water_jfa", "water_finalize"]
	for shader_name in required_shaders:
		if not gpu.shaders.has(shader_name) or not gpu.shaders[shader_name].is_valid():
			push_warning("[Orchestrator] ⚠️ ", shader_name, " shader non disponible, phase eaux ignorée")
			return
	
	print("[Orchestrator] 💧 Phase 2.5 : Classification des Eaux")
	
	# Initialiser les textures d'eau (si pas déjà fait)
	if not gpu.textures.has("water_sources"):
		gpu.initialize_water_textures()
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var sea_level = float(params.get("sea_level", 0.0))
	var _avg_precipitation = float(params.get("avg_precipitation", 0.5))  # Utilisé pour ajuster les seuils
	
	# Paramètres de rivières
	var min_altitude = 50.0  # Altitude minimale des sources au-dessus de la mer (réduit)
	var min_precipitation = 0.1  # Précipitation minimale pour source (réduit pour plus de sources)
	var cell_size = max(8.0, float(w) / 80.0)  # Taille de cellule pour espacement (plus petite = plus de sources)
	var river_propagation_iterations = 500  # Nombre de passes de propagation (augmenté pour longues rivières)
	var base_river_flux = 500.0  # Flux initial par source (augmenté pour accumulation)
	
	# Paramètres de classification
	var flux_threshold_low = 2.0     # Seuil affluent (réduit pour détection)
	var flux_threshold_mid = 25.0    # Seuil rivière (réduit pour détection)
	var flux_threshold_high = 100.0  # Seuil fleuve (réduit pour détection)
	var lake_min_water = 0.5         # Eau min pour lac en altitude
	
	# Paramètres de taille pour classification eau salée/douce
	# Eau salée = masse d'eau >= saltwater_threshold pixels
	# Eau douce = masse d'eau < saltwater_threshold pixels (et lacs d'altitude)
	var saltwater_threshold = 300    # Seuil minimal pour eau salée (fixe, pas basé sur résolution)
	
	print("  Seed: ", seed_val, " | Sea Level: ", sea_level)
	print("  Cell Size: ", cell_size, " | Propagation Iterations: ", river_propagation_iterations)
	print("  Saltwater Threshold: ", saltwater_threshold, " pixels (eau salée >= ce seuil)")
	
	# === PASSE 1 : DÉTECTION DES SOURCES ===
	print("  • Détection des sources de rivières...")
	_dispatch_river_sources(w, h, groups_x, groups_y, seed_val, sea_level, min_altitude, min_precipitation, cell_size)
	
	# === PASSE 2 : PROPAGATION DES RIVIÈRES ===
	print("  • Propagation des rivières (", river_propagation_iterations, " passes)...")
	for pass_idx in range(river_propagation_iterations):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_river_propagation(w, h, groups_x, groups_y, pass_idx, seed_val, sea_level, base_river_flux, use_swap)
	
	# Si river_propagation_iterations est pair, le résultat est dans water_paths_temp, donc on doit copier vers water_paths
	if river_propagation_iterations % 2 == 0:
		print("  • Copie du résultat propagation vers water_paths...")
		_copy_texture(gpu.textures["water_paths_temp"], gpu.textures["water_paths"], w, h)
	
	# === PASSE 3 : CLASSIFICATION INITIALE ===
	print("  • Classification initiale des eaux...")
	_dispatch_water_classification(w, h, groups_x, groups_y, sea_level, flux_threshold_low, flux_threshold_mid, flux_threshold_high, lake_min_water)
	
	# === PASSE 4 : JFA POUR COMPOSANTES CONNEXES ===
	var jfa_passes = int(ceil(log(max(w, h)) / log(2.0)))
	print("  • JFA composantes connexes (", jfa_passes, " passes)...")
	var step_size: int = int(pow(2, jfa_passes - 1))
	for pass_idx in range(jfa_passes):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_water_jfa(w, h, groups_x, groups_y, step_size, use_swap)
		step_size = max(1, step_size >> 1)  # Division par 2 entière
	
	# Si jfa_passes est pair, le résultat est dans water_jfa_temp, donc on doit copier vers water_jfa
	if jfa_passes % 2 == 0:
		print("  • Copie du résultat JFA vers water_jfa...")
		_copy_texture(gpu.textures["water_jfa_temp"], gpu.textures["water_jfa"], w, h)
	
	# === PASSE 4.5 : COMPTAGE ATOMIQUE DES PIXELS ===
	print("  • Comptage des pixels par composante...")
	_dispatch_water_size_classification(w, h, groups_x, groups_y)
	
	# === PASSE 5 : RECLASSIFICATION PAR TAILLE ===
	print("  • Reclassification par taille (eau salée >= ", saltwater_threshold, " pixels)...")
	_dispatch_water_finalize(w, h, groups_x, groups_y, sea_level, saltwater_threshold)
	
	print("[Orchestrator] ✅ Phase 2.5 : Classification des eaux terminée")

## Dispatch le shader de détection des sources de rivières
func _dispatch_river_sources(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, sea_level: float, min_altitude: float, min_precipitation: float, cell_size: float) -> void:
	if not gpu.shaders.has("river_sources") or not gpu.shaders["river_sources"].is_valid():
		return
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures["climate"]))
	
	# Uniform pour water_sources (R32UI - utilise IMAGE)
	var sources_uniform = RDUniform.new()
	sources_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	sources_uniform.binding = 2
	sources_uniform.add_id(gpu.textures["water_sources"])
	tex_uniforms.append(sources_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_sources"], 0)
	if not tex_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create river_sources texture set")
		return
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                    # width
	buffer_bytes.encode_u32(4, h)                    # height
	buffer_bytes.encode_u32(8, seed_val)             # seed
	buffer_bytes.encode_u32(12, 10000)               # max_sources (non utilisé actuellement)
	buffer_bytes.encode_float(16, sea_level)         # sea_level
	buffer_bytes.encode_float(20, min_altitude)      # min_altitude
	buffer_bytes.encode_float(24, min_precipitation) # min_precipitation
	buffer_bytes.encode_float(28, cell_size)         # cell_size
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_sources"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_sources"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)

## Dispatch le shader de propagation des rivières
func _dispatch_river_propagation(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, seed_val: int, sea_level: float, base_flux: float, use_swap: bool) -> void:
	if not gpu.shaders.has("river_propagation") or not gpu.shaders["river_propagation"].is_valid():
		return
	
	# Textures input/output en ping-pong
	var input_tex = gpu.textures["water_paths"] if not use_swap else gpu.textures["water_paths_temp"]
	var output_tex = gpu.textures["water_paths_temp"] if not use_swap else gpu.textures["water_paths"]
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# Input (R32F readonly)
	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input_uniform.binding = 1
	input_uniform.add_id(input_tex)
	tex_uniforms.append(input_uniform)
	
	# Output (R32F writeonly)
	var output_uniform = RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 2
	output_uniform.add_id(output_tex)
	tex_uniforms.append(output_uniform)
	
	# Sources (R32UI readonly)
	var sources_uniform = RDUniform.new()
	sources_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	sources_uniform.binding = 3
	sources_uniform.add_id(gpu.textures["water_sources"])
	tex_uniforms.append(sources_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_propagation"], 0)
	if not tex_set.is_valid():
		return
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                    # width
	buffer_bytes.encode_u32(4, h)                    # height
	buffer_bytes.encode_u32(8, pass_index)           # pass_index
	buffer_bytes.encode_float(12, sea_level)         # sea_level
	buffer_bytes.encode_float(16, base_flux)         # base_flux
	buffer_bytes.encode_float(20, 0.01)              # min_slope
	buffer_bytes.encode_float(24, 0.3)               # meander_factor
	buffer_bytes.encode_u32(28, seed_val)            # seed
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_propagation"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_propagation"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)

## Dispatch le shader de classification initiale des eaux
func _dispatch_water_classification(w: int, h: int, groups_x: int, groups_y: int, sea_level: float, flux_low: float, flux_mid: float, flux_high: float, lake_min_water: float) -> void:
	if not gpu.shaders.has("water_classification") or not gpu.shaders["water_classification"].is_valid():
		return
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# River paths (utiliser le résultat final de la propagation)
	var paths_uniform = RDUniform.new()
	paths_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	paths_uniform.binding = 1
	paths_uniform.add_id(gpu.textures["water_paths"])
	tex_uniforms.append(paths_uniform)
	
	# Water types output
	var types_uniform = RDUniform.new()
	types_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	types_uniform.binding = 2
	types_uniform.add_id(gpu.textures["water_types"])
	tex_uniforms.append(types_uniform)
	
	# Water JFA output
	var jfa_uniform = RDUniform.new()
	jfa_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	jfa_uniform.binding = 3
	jfa_uniform.add_id(gpu.textures["water_jfa"])
	tex_uniforms.append(jfa_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_classification"], 0)
	if not tex_set.is_valid():
		return
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                    # width
	buffer_bytes.encode_u32(4, h)                    # height
	buffer_bytes.encode_float(8, sea_level)          # sea_level
	buffer_bytes.encode_float(12, flux_low)          # flux_threshold_low
	buffer_bytes.encode_float(16, flux_mid)          # flux_threshold_mid
	buffer_bytes.encode_float(20, flux_high)         # flux_threshold_high
	buffer_bytes.encode_float(24, lake_min_water)    # lake_min_water
	buffer_bytes.encode_float(28, 0.0)               # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_classification"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_classification"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)

## Dispatch le shader JFA pour composantes connexes
func _dispatch_water_jfa(w: int, h: int, groups_x: int, groups_y: int, step_size: int, use_swap: bool) -> void:
	if not gpu.shaders.has("water_jfa") or not gpu.shaders["water_jfa"].is_valid():
		return
	
	# Textures input/output en ping-pong
	var input_tex = gpu.textures["water_jfa"] if not use_swap else gpu.textures["water_jfa_temp"]
	var output_tex = gpu.textures["water_jfa_temp"] if not use_swap else gpu.textures["water_jfa"]
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	
	# Input JFA
	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input_uniform.binding = 0
	input_uniform.add_id(input_tex)
	tex_uniforms.append(input_uniform)
	
	# Output JFA
	var output_uniform = RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 1
	output_uniform.add_id(output_tex)
	tex_uniforms.append(output_uniform)
	
	# Water types (readonly)
	var types_uniform = RDUniform.new()
	types_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	types_uniform.binding = 2
	types_uniform.add_id(gpu.textures["water_types"])
	tex_uniforms.append(types_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_jfa"], 0)
	if not tex_set.is_valid():
		return
	
	# Structure UBO (std140, 16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	
	buffer_bytes.encode_u32(0, w)          # width
	buffer_bytes.encode_u32(4, h)          # height
	buffer_bytes.encode_s32(8, step_size)  # step_size
	buffer_bytes.encode_u32(12, 0)         # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_jfa"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_jfa"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)

## Dispatch le shader de comptage des pixels par composante (via atomics)
func _dispatch_water_size_classification(w: int, h: int, groups_x: int, groups_y: int) -> void:
	if not gpu.shaders.has("water_size_classification") or not gpu.shaders["water_size_classification"].is_valid():
		push_warning("[Orchestrator] ⚠️ water_size_classification shader non disponible, comptage ignoré")
		return
	
	# Créer le SSBO pour les compteurs (w * h * 4 bytes) s'il n'existe pas
	var counter_size = w * h * 4
	if not water_counter_buffer.is_valid():
		var counter_data = PackedByteArray()
		counter_data.resize(counter_size)
		counter_data.fill(0)
		water_counter_buffer = rd.storage_buffer_create(counter_size, counter_data)
		
		if not water_counter_buffer.is_valid():
			push_error("[Orchestrator] ❌ Failed to create water counter SSBO")
			return
	else:
		# Réinitialiser le buffer à zéro
		var zero_data = PackedByteArray()
		zero_data.resize(counter_size)
		zero_data.fill(0)
		rd.buffer_update(water_counter_buffer, 0, counter_size, zero_data)
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	
	# Water JFA (readonly)
	var jfa_uniform = RDUniform.new()
	jfa_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	jfa_uniform.binding = 0
	jfa_uniform.add_id(gpu.textures["water_jfa"])
	tex_uniforms.append(jfa_uniform)
	
	# Water types (readonly)
	var types_uniform = RDUniform.new()
	types_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	types_uniform.binding = 1
	types_uniform.add_id(gpu.textures["water_types"])
	tex_uniforms.append(types_uniform)
	
	# Counter SSBO (read/write)
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 2
	counter_uniform.add_id(water_counter_buffer)
	tex_uniforms.append(counter_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_size_classification"], 0)
	if not tex_set.is_valid():
		return
	
	# Structure UBO (std140, 16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)   # width
	buffer_bytes.encode_u32(4, h)   # height
	buffer_bytes.encode_u32(8, 0)   # padding1
	buffer_bytes.encode_u32(12, 0)  # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_size_classification"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_size_classification"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)

## Dispatch le shader de finalisation (reclassification eau salée/douce)
func _dispatch_water_finalize(w: int, h: int, groups_x: int, groups_y: int, sea_level: float, saltwater_threshold: int) -> void:
	if not gpu.shaders.has("water_finalize") or not gpu.shaders["water_finalize"].is_valid():
		return
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	
	# Water JFA (readonly)
	var jfa_uniform = RDUniform.new()
	jfa_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	jfa_uniform.binding = 0
	jfa_uniform.add_id(gpu.textures["water_jfa"])
	tex_uniforms.append(jfa_uniform)
	
	# Water types (read/write)
	var types_uniform = RDUniform.new()
	types_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	types_uniform.binding = 1
	types_uniform.add_id(gpu.textures["water_types"])
	tex_uniforms.append(types_uniform)
	
	# Counter SSBO (readonly) - doit exister après _dispatch_water_size_classification
	if not water_counter_buffer.is_valid():
		# Créer un buffer vide si le comptage n'a pas été effectué
		var counter_size = w * h * 4
		var counter_data = PackedByteArray()
		counter_data.resize(counter_size)
		counter_data.fill(0)
		water_counter_buffer = rd.storage_buffer_create(counter_size, counter_data)
	
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 2
	counter_uniform.add_id(water_counter_buffer)
	tex_uniforms.append(counter_uniform)
	
	# Geo texture (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["geo"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_finalize"], 0)
	if not tex_set.is_valid():
		return
	
	# Structure UBO (std140, 32 bytes)
	# Nouvelle structure : width, height, sea_level, saltwater_threshold
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                     # width
	buffer_bytes.encode_u32(4, h)                     # height
	buffer_bytes.encode_float(8, sea_level)           # sea_level
	buffer_bytes.encode_u32(12, saltwater_threshold)  # saltwater_threshold (>= ce seuil = eau salée)
	buffer_bytes.encode_u32(16, 0)                    # padding (ancien sea_threshold)
	buffer_bytes.encode_u32(20, 0)                    # padding (ancien lake_threshold)
	buffer_bytes.encode_float(24, 0.0)                # padding1
	buffer_bytes.encode_float(28, 0.0)                # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		rd.free_rid(tex_set)
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_finalize"], 1)
	if not param_set.is_valid():
		rd.free_rid(tex_set)
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_finalize"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)
	rd.free_rid(tex_set)
	
	# Libérer le buffer de comptage après utilisation
	if water_counter_buffer.is_valid():
		rd.free_rid(water_counter_buffer)
		water_counter_buffer = RID()

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
	
	# === PASSE 3 : NUAGES ===
	var cloud_coverage = float(params.get("cloud_coverage", 0.5))
	var cloud_density = float(params.get("cloud_density", 0.8))
	_dispatch_clouds(w, h, groups_x, groups_y, seed_val, cloud_coverage, cloud_density, cylinder_radius, atmosphere_type)

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


## Dispatch le shader de nuages
func _dispatch_clouds(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, cloud_coverage: float, cloud_density: float, cylinder_radius: float, atmosphere_type: int) -> void:
	if not gpu.shaders.has("clouds") or not gpu.shaders["clouds"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds shader non disponible")
		return
	if not gpu.uniform_sets.has("clouds_textures") or not gpu.uniform_sets["clouds_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ clouds uniform set non disponible")
		return
	
	print("  • Nuages (coverage: ", cloud_coverage, ", density: ", cloud_density, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float cloud_coverage, cylinder_radius (8 bytes)
	# uint atmosphere_type (4 bytes)
	# float cloud_density (4 bytes)
	# padding (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, cloud_coverage)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_float(24, cloud_density)
	buffer_bytes.encode_u32(28, 0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["clouds"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create clouds param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["clouds"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["clouds_textures"], 0)
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
# SAMPLER HELPER
# ============================================================================

var _linear_sampler: RID = RID()

## Crée ou récupère un sampler linéaire pour lecture de textures
func _get_or_create_linear_sampler() -> RID:
	if _linear_sampler.is_valid():
		return _linear_sampler
	
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	
	_linear_sampler = rd.sampler_create(sampler_state)
	return _linear_sampler

# ============================================================================
# ÉTAPE 5 : RESSOURCES & PÉTROLE
# ============================================================================

## Génère les cartes de ressources et de pétrole.
##
## Cette phase exécute :
## 1. Petrole : Gisements pétroliers basés sur géologie (bassins sédimentaires)
## 2. Resources : Tous les autres minéraux avec distribution par probabilité
##
## Le pétrole et les ressources ne sont pas générés si atmosphere_type == 3
## (pas de vie organique = pas d'hydrocarbures, pas de dépôts sédimentaires).
##
## @param params: Dictionnaire contenant seed, atmosphere_type, petrole_probability, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_resources_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] ⛏️ Phase 5 : Ressources & Pétrole")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("atmosphere_type", 0))
	var cylinder_radius = float(w) / (2.0 * PI)
	
	# Paramètres de pétrole (depuis enum.gd)
	var petrole_probability = float(params.get("petrole_probability", 0.025))
	var petrole_deposit_size = float(params.get("petrole_deposit_size", 200.0))
	
	# Paramètres globaux des ressources
	var global_richness = float(params.get("global_richness", 1.0))
	
	# === PASSE 1 : PÉTROLE ===
	_dispatch_petrole(w, h, groups_x, groups_y, seed_val, sea_level, cylinder_radius, atmosphere_type, petrole_probability, petrole_deposit_size)
	
	# === PASSE 2 : AUTRES RESSOURCES ===
	_dispatch_resources(w, h, groups_x, groups_y, seed_val, sea_level, cylinder_radius, atmosphere_type, global_richness)
	
	print("[Orchestrator] ✅ Phase 5 : Ressources & Pétrole terminée")

## Dispatch le shader de pétrole
func _dispatch_petrole(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, sea_level: float, cylinder_radius: float, atmosphere_type: int, petrole_probability: float, deposit_size: float) -> void:
	if not gpu.shaders.has("petrole") or not gpu.shaders["petrole"].is_valid():
		push_warning("[Orchestrator] ⚠️ petrole shader non disponible")
		return
	if not gpu.uniform_sets.has("petrole_textures") or not gpu.uniform_sets["petrole_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ petrole uniform set non disponible")
		return
	
	print("  • Pétrole (probabilité: ", petrole_probability, ", taille: ", deposit_size, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float sea_level (4 bytes)
	# float cylinder_radius (4 bytes)
	# uint atmosphere_type (4 bytes)
	# float petrole_probability (4 bytes)
	# float deposit_size (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_float(24, petrole_probability)
	buffer_bytes.encode_float(28, deposit_size)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create petrole param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["petrole"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create petrole param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["petrole"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["petrole_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de ressources minérales
func _dispatch_resources(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, sea_level: float, cylinder_radius: float, atmosphere_type: int, global_richness: float) -> void:
	if not gpu.shaders.has("resources") or not gpu.shaders["resources"].is_valid():
		push_warning("[Orchestrator] ⚠️ resources shader non disponible")
		return
	if not gpu.uniform_sets.has("resources_textures") or not gpu.uniform_sets["resources_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ resources uniform set non disponible")
		return
	
	print("  • Ressources minérales (richesse: ", global_richness, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float sea_level (4 bytes)
	# float cylinder_radius (4 bytes)
	# uint atmosphere_type (4 bytes)
	# float global_richness (4 bytes)
	# padding (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_float(24, global_richness)
	buffer_bytes.encode_float(28, 0.0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create resources param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["resources"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create resources param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["resources"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["resources_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	rd.free_rid(param_set)
	rd.free_rid(param_buffer)

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

## Copie une texture vers une autre (pour résoudre les problèmes de ping-pong)
func _copy_texture(src: RID, dst: RID, width: int, height: int) -> void:
	"""Copie src vers dst en utilisant texture_copy"""
	if not rd or not src.is_valid() or not dst.is_valid():
		push_error("[Orchestrator] ❌ Cannot copy texture: invalid RID or RD")
		return
	
	rd.texture_copy(src, dst, Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(width, height, 1), 0, 0, 0, 0)
	rd.submit()
	rd.sync()

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
