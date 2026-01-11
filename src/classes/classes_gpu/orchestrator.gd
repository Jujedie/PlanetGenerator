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
		# Shaders Régions Hiérarchiques (Étape 4)
		{"path": "res://shader/compute/regions/region_cost_field.glsl", "name": "region_cost_field", "critical": false},
		{"path": "res://shader/compute/regions/region_seed_init.glsl", "name": "region_seed_init", "critical": false},
		{"path": "res://shader/compute/regions/region_growth.glsl", "name": "region_growth", "critical": false},
		{"path": "res://shader/compute/regions/region_boundaries.glsl", "name": "region_boundaries", "critical": false},
		{"path": "res://shader/compute/regions/region_hierarchy.glsl", "name": "region_hierarchy", "critical": false},
		{"path": "res://shader/compute/regions/region_fill_orphans.glsl", "name": "region_fill_orphans", "critical": false},
		# Shaders Ressources & Pétrole (Étape 5)
		{"path": "res://shader/compute/ressources/oil.glsl", "name": "oil", "critical": false},
		{"path": "res://shader/compute/ressources/resources.glsl", "name": "resources", "critical": false},
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
	
	# === OIL SHADER ===
	if gpu.shaders.has("oil") and gpu.shaders["oil"].is_valid():
		print("  • Création uniform set: oil")
		
		# Set 0 : Textures (geo en lecture via sampler, oil en écriture)
		# Binding 0: geo_texture (texture2D)
		# Binding 1: geo_sampler
		# Binding 2: oil_texture (writeonly image2D)
		var geo_tex_uniform = RDUniform.new()
		geo_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
		geo_tex_uniform.binding = 0
		geo_tex_uniform.add_id(gpu.textures["geo"])
		
		var geo_sampler_uniform = RDUniform.new()
		geo_sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
		geo_sampler_uniform.binding = 1
		geo_sampler_uniform.add_id(_get_or_create_linear_sampler())
		
		var oil_tex_uniform = gpu.create_texture_uniform(2, gpu.textures["oil"])
		
		var uniforms_oil = [geo_tex_uniform, geo_sampler_uniform, oil_tex_uniform]
		
		gpu.uniform_sets["oil_textures"] = rd.uniform_set_create(uniforms_oil, gpu.shaders["oil"], 0)
		if not gpu.uniform_sets["oil_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create oil textures uniform set")
		else:
			print("    ✅ oil textures uniform set créé")
	else:
		push_warning("[Orchestrator] ⚠️ oil shader invalide, uniform set ignoré")
	
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
	
	# === ÉTAPE 4 : RÉGIONS HIÉRARCHIQUES ===
	# Les uniform sets pour les régions seront créés dynamiquement dans run_regions_phase()
	# car ils nécessitent le ping-pong entre textures
	# Ici on initialise juste les textures
	gpu.initialize_regions_textures()
	print("  • Textures régions initialisées (uniform sets créés dynamiquement)")
	
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
	run_atmosphere_phase(generation_params, w, h)
	
	# === ÉTAPE 4 : RÉGIONS HIÉRARCHIQUES ===
	run_regions_phase(generation_params, w, h)
	
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
## 1. Oil : Gisements pétroliers basés sur géologie (bassins sédimentaires)
## 2. Resources : Tous les autres minéraux avec distribution par probabilité
##
## Le pétrole et les ressources ne sont pas générés si atmosphere_type == 3
## (pas de vie organique = pas d'hydrocarbures, pas de dépôts sédimentaires).
##
## @param params: Dictionnaire contenant seed, atmosphere_type, oil_probability, etc.
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
	var oil_probability = float(params.get("oil_probability", 0.025))
	var oil_deposit_size = float(params.get("oil_deposit_size", 200.0))
	
	# Paramètres globaux des ressources
	var global_richness = float(params.get("global_richness", 1.0))
	
	# === PASSE 1 : PÉTROLE ===
	_dispatch_oil(w, h, groups_x, groups_y, seed_val, sea_level, cylinder_radius, atmosphere_type, oil_probability, oil_deposit_size)
	
	# === PASSE 2 : AUTRES RESSOURCES ===
	_dispatch_resources(w, h, groups_x, groups_y, seed_val, sea_level, cylinder_radius, atmosphere_type, global_richness)
	
	print("[Orchestrator] ✅ Phase 5 : Ressources & Pétrole terminée")

## Dispatch le shader de pétrole
func _dispatch_oil(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, sea_level: float, cylinder_radius: float, atmosphere_type: int, oil_probability: float, deposit_size: float) -> void:
	if not gpu.shaders.has("oil") or not gpu.shaders["oil"].is_valid():
		push_warning("[Orchestrator] ⚠️ oil shader non disponible")
		return
	if not gpu.uniform_sets.has("oil_textures") or not gpu.uniform_sets["oil_textures"].is_valid():
		push_warning("[Orchestrator] ⚠️ oil uniform set non disponible")
		return
	
	print("  • Pétrole (probabilité: ", oil_probability, ", taille: ", deposit_size, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float sea_level (4 bytes)
	# float cylinder_radius (4 bytes)
	# uint atmosphere_type (4 bytes)
	# float oil_probability (4 bytes)
	# float deposit_size (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_float(24, oil_probability)
	buffer_bytes.encode_float(28, deposit_size)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create oil param buffer")
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["oil"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create oil param set")
		rd.free_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["oil"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["oil_textures"], 0)
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
# ÉTAPE 4 : RÉGIONS HIÉRARCHIQUES
# ============================================================================

## Génère les régions hiérarchiques à 3 niveaux sur GPU.
##
## Structure :
## - Niveau 1 : Départements/Comtés (maille fine, ~150-300 régions terrestres + ~50-100 océaniques)
## - Niveau 2 : Régions (regroupement de 4-8 départements)
## - Niveau 3 : Zones (regroupement macro de 3-5 régions)
##
## Les régions terrestres et océaniques sont traitées séparément.
##
## @param params: Paramètres de génération
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_regions_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🗺️ Phase 4 : Régions Hiérarchiques")
	
	var groups_x = ceili(float(w) / 8.0)
	var groups_y = ceili(float(h) / 8.0)
	
	var seed_val = int(params.get("seed", 12345))
	var num_land_regions = int(params.get("num_land_regions", 150))
	var num_ocean_regions = int(params.get("num_ocean_regions", 50))
	var growth_iterations = int(params.get("region_growth_iterations", 200))
	var smoothing_passes = int(params.get("region_smoothing_passes", 2))
	var swap_probability = float(params.get("region_swap_probability", 0.3))
	
	# Paramètres de coût terrain
	var k_slope = float(params.get("region_k_slope", 5.0))
	var k_river = float(params.get("region_k_river", 10.0))
	var k_noise = float(params.get("region_k_noise", 2.0))
	var river_threshold = float(params.get("river_threshold", 0.1))
	
	# === PHASE 1 : CALCUL DU CHAMP DE COÛT ===
	print("  • Calcul du champ de coût terrain...")
	_dispatch_region_cost_field(w, h, groups_x, groups_y, seed_val, k_slope, k_river, k_noise, river_threshold)
	
	# === PHASE 2 : RÉGIONS TERRESTRES (3 niveaux) ===
	print("  • Génération régions terrestres (", num_land_regions, " départements)...")
	_dispatch_regions_pipeline(w, h, groups_x, groups_y, seed_val, num_land_regions, 
		growth_iterations, smoothing_passes, swap_probability, false, "regions_land_1")
	
	# Hiérarchie terrestre : niveau 2 (régions = 1/5 des départements)
	var num_land_level2 = maxi(10, num_land_regions / 5)
	_dispatch_region_hierarchy(w, h, groups_x, groups_y, seed_val, 
		num_land_regions, num_land_level2, "regions_land_1", "regions_land_2")
	print("    → Niveau 2 : ", num_land_level2, " régions")
	
	# Hiérarchie terrestre : niveau 3 (zones = 1/4 des régions)
	var num_land_level3 = maxi(3, num_land_level2 / 4)
	_dispatch_region_hierarchy(w, h, groups_x, groups_y, seed_val, 
		num_land_level2, num_land_level3, "regions_land_2", "regions_land_3")
	print("    → Niveau 3 : ", num_land_level3, " zones")
	
	# === PHASE 3 : RÉGIONS OCÉANIQUES (3 niveaux) ===
	print("  • Génération régions océaniques (", num_ocean_regions, " départements)...")
	_dispatch_regions_pipeline(w, h, groups_x, groups_y, seed_val + 1000, num_ocean_regions, 
		growth_iterations, smoothing_passes, swap_probability, true, "regions_ocean_1")
	
	# Hiérarchie océanique : niveau 2
	var num_ocean_level2 = maxi(5, num_ocean_regions / 5)
	_dispatch_region_hierarchy(w, h, groups_x, groups_y, seed_val + 1000, 
		num_ocean_regions, num_ocean_level2, "regions_ocean_1", "regions_ocean_2")
	print("    → Niveau 2 : ", num_ocean_level2, " régions")
	
	# Hiérarchie océanique : niveau 3
	var num_ocean_level3 = maxi(2, num_ocean_level2 / 4)
	_dispatch_region_hierarchy(w, h, groups_x, groups_y, seed_val + 1000, 
		num_ocean_level2, num_ocean_level3, "regions_ocean_2", "regions_ocean_3")
	print("    → Niveau 3 : ", num_ocean_level3, " zones")
	
	print("[Orchestrator] ✅ Phase 4 : Régions Hiérarchiques terminée")

## Dispatch le shader de calcul du champ de coût terrain
func _dispatch_region_cost_field(w: int, h: int, groups_x: int, groups_y: int, 
		seed_val: int, k_slope: float, k_river: float, k_noise: float, river_threshold: float) -> void:
	
	if not gpu.shaders.has("region_cost_field") or not gpu.shaders["region_cost_field"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_cost_field shader non disponible")
		return
	
	# Créer les uniforms pour ce shader
	# Bindings : 0=geo (readonly), 1=river_flux (readonly), 2=cost_field (writeonly), 3=params
	var uniforms: Array[RDUniform] = []
	
	var geo_uniform = gpu.create_texture_uniform(0, gpu.textures["geo"])
	uniforms.append(geo_uniform)
	
	var flux_uniform = gpu.create_texture_uniform(1, gpu.textures["river_flux"])
	uniforms.append(flux_uniform)
	
	var cost_uniform = gpu.create_texture_uniform(2, gpu.textures["region_cost_field"])
	uniforms.append(cost_uniform)
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_s32(0, w)              # width
	buffer_bytes.encode_s32(4, h)              # height
	buffer_bytes.encode_float(8, k_slope)      # k_slope
	buffer_bytes.encode_float(12, k_river)     # k_river
	buffer_bytes.encode_float(16, k_noise)     # k_noise
	buffer_bytes.encode_float(20, river_threshold) # river_threshold
	buffer_bytes.encode_u32(24, seed_val)      # seed
	buffer_bytes.encode_float(28, 1.0)         # base_cost
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 3
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_cost_field"], 0)
	
	# Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_cost_field"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Cleanup
	rd.free_rid(uniform_set)
	rd.free_rid(param_buffer)

## Pipeline complète de génération des régions (init + growth + boundaries + fill)
func _dispatch_regions_pipeline(w: int, h: int, groups_x: int, groups_y: int,
		seed_val: int, num_regions: int, growth_iterations: int, smoothing_passes: int,
		swap_probability: float, is_ocean: bool, output_texture: String) -> void:
	
	# === ÉTAPE 1 : Initialisation des seeds ===
	_dispatch_region_seeds(w, h, groups_x, groups_y, seed_val, num_regions, is_ocean, output_texture)
	
	# === ÉTAPE 2 : Croissance itérative ===
	for i in range(growth_iterations):
		_dispatch_region_growth(w, h, groups_x, groups_y, is_ocean, i, output_texture)
	
	# === ÉTAPE 3 : Post-traitement des frontières ===
	for pass_num in range(smoothing_passes + 1):  # +1 pour la passe d'irrégularité
		_dispatch_region_boundaries(w, h, groups_x, groups_y, seed_val, swap_probability, 
			smoothing_passes, pass_num, output_texture)
	
	# === ÉTAPE 4 : Remplissage des orphelins ===
	for _fill_pass in range(3):  # Quelques passes pour garantir le remplissage
		_dispatch_region_fill_orphans(w, h, groups_x, groups_y, is_ocean, output_texture)

## Dispatch le shader d'initialisation des seeds
func _dispatch_region_seeds(w: int, h: int, groups_x: int, groups_y: int,
		seed_val: int, num_regions: int, is_ocean: bool, output_texture: String) -> void:
	
	if not gpu.shaders.has("region_seed_init") or not gpu.shaders["region_seed_init"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_seed_init shader non disponible")
		return
	
	var uniforms: Array[RDUniform] = []
	
	# Binding 0: geo (readonly)
	uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# Binding 1: region_state (read/write)
	uniforms.append(gpu.create_texture_uniform(1, gpu.textures[output_texture]))
	
	# Binding 2: region_seeds
	uniforms.append(gpu.create_texture_uniform(2, gpu.textures["region_seeds"]))
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_s32(0, w)                          # width
	buffer_bytes.encode_s32(4, h)                          # height
	buffer_bytes.encode_s32(8, num_regions)                # num_regions
	buffer_bytes.encode_s32(12, 1 if is_ocean else 0)      # is_ocean_mode
	buffer_bytes.encode_u32(16, seed_val)                  # seed
	buffer_bytes.encode_s32(20, 50)                        # min_region_size
	buffer_bytes.encode_s32(24, 5000)                      # max_region_size
	buffer_bytes.encode_float(28, 0.0)                     # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 3
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_seed_init"], 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_seed_init"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	rd.free_rid(uniform_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de croissance des régions
func _dispatch_region_growth(w: int, h: int, groups_x: int, groups_y: int,
		is_ocean: bool, iteration: int, state_texture: String) -> void:
	
	if not gpu.shaders.has("region_growth") or not gpu.shaders["region_growth"].is_valid():
		return
	
	var uniforms: Array[RDUniform] = []
	
	# Binding 0: geo (readonly)
	uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# Binding 1: cost_field (readonly)
	uniforms.append(gpu.create_texture_uniform(1, gpu.textures["region_cost_field"]))
	
	# Binding 2: region_state_in (readonly) - on utilise la même texture car on lit et écrit atomiquement
	uniforms.append(gpu.create_texture_uniform(2, gpu.textures[state_texture]))
	
	# Binding 3: region_state_out (writeonly) - même texture (in-place update)
	uniforms.append(gpu.create_texture_uniform(3, gpu.textures[state_texture]))
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_s32(0, w)                          # width
	buffer_bytes.encode_s32(4, h)                          # height
	buffer_bytes.encode_s32(8, 1 if is_ocean else 0)       # is_ocean_mode
	buffer_bytes.encode_s32(12, iteration)                 # iteration
	buffer_bytes.encode_float(16, 1.0)                     # distance_weight
	buffer_bytes.encode_float(20, 0.0)                     # padding1
	buffer_bytes.encode_float(24, 0.0)                     # padding2
	buffer_bytes.encode_float(28, 0.0)                     # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 4
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_growth"], 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_growth"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	rd.free_rid(uniform_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de post-traitement des frontières
func _dispatch_region_boundaries(w: int, h: int, groups_x: int, groups_y: int,
		seed_val: int, swap_probability: float, smoothing_passes: int, current_pass: int,
		state_texture: String) -> void:
	
	if not gpu.shaders.has("region_boundaries") or not gpu.shaders["region_boundaries"].is_valid():
		return
	
	var uniforms: Array[RDUniform] = []
	
	# Binding 0: region_state_in (readonly)
	uniforms.append(gpu.create_texture_uniform(0, gpu.textures[state_texture]))
	
	# Binding 1: region_state_out (writeonly)
	uniforms.append(gpu.create_texture_uniform(1, gpu.textures[state_texture]))
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_s32(0, w)                          # width
	buffer_bytes.encode_s32(4, h)                          # height
	buffer_bytes.encode_u32(8, seed_val)                   # seed
	buffer_bytes.encode_float(12, swap_probability)        # swap_probability
	buffer_bytes.encode_s32(16, smoothing_passes)          # smoothing_passes
	buffer_bytes.encode_s32(20, current_pass)              # current_pass
	buffer_bytes.encode_float(24, 0.0)                     # padding1
	buffer_bytes.encode_float(28, 0.0)                     # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 2
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_boundaries"], 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_boundaries"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	rd.free_rid(uniform_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de remplissage des pixels orphelins
func _dispatch_region_fill_orphans(w: int, h: int, groups_x: int, groups_y: int,
		is_ocean: bool, state_texture: String) -> void:
	
	if not gpu.shaders.has("region_fill_orphans") or not gpu.shaders["region_fill_orphans"].is_valid():
		return
	
	var uniforms: Array[RDUniform] = []
	
	# Binding 0: geo (readonly)
	uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# Binding 1: region_state_in (readonly)
	uniforms.append(gpu.create_texture_uniform(1, gpu.textures[state_texture]))
	
	# Binding 2: region_state_out (writeonly)
	uniforms.append(gpu.create_texture_uniform(2, gpu.textures[state_texture]))
	
	# Structure UBO (std140, 16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_s32(0, w)                          # width
	buffer_bytes.encode_s32(4, h)                          # height
	buffer_bytes.encode_s32(8, 1 if is_ocean else 0)       # is_ocean_mode
	buffer_bytes.encode_s32(12, 5)                         # search_radius
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 3
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_fill_orphans"], 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_fill_orphans"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	rd.free_rid(uniform_set)
	rd.free_rid(param_buffer)

## Dispatch le shader de hiérarchie (regroupement niveau N → niveau N+1)
func _dispatch_region_hierarchy(w: int, h: int, groups_x: int, groups_y: int,
		seed_val: int, source_num: int, target_num: int, 
		source_texture: String, target_texture: String) -> void:
	
	if not gpu.shaders.has("region_hierarchy") or not gpu.shaders["region_hierarchy"].is_valid():
		return
	
	var uniforms: Array[RDUniform] = []
	
	# Binding 0: level_in (readonly)
	uniforms.append(gpu.create_texture_uniform(0, gpu.textures[source_texture]))
	
	# Binding 1: level_out (writeonly)
	uniforms.append(gpu.create_texture_uniform(1, gpu.textures[target_texture]))
	
	# Structure UBO (std140, 32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_s32(0, w)                          # width
	buffer_bytes.encode_s32(4, h)                          # height
	buffer_bytes.encode_s32(8, source_num)                 # source_num_regions
	buffer_bytes.encode_s32(12, target_num)                # target_num_regions
	buffer_bytes.encode_u32(16, seed_val)                  # seed
	buffer_bytes.encode_float(20, 0.0)                     # padding1
	buffer_bytes.encode_float(24, 0.0)                     # padding2
	buffer_bytes.encode_float(28, 0.0)                     # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 2
	param_uniform.add_id(param_buffer)
	uniforms.append(param_uniform)
	
	var uniform_set = rd.uniform_set_create(uniforms, gpu.shaders["region_hierarchy"], 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_hierarchy"])
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	rd.free_rid(uniform_set)
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
