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
var _cleaned_up: bool = false
var last_phase_timings_ms: Dictionary = {}
var last_hydrology_stats: Dictionary = {}
var last_administrative_stats: Dictionary = {}
var last_performance_report: Dictionary = {}

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
		# Shaders Classification des Eaux & Rivières (Étape 2.5)
		{"path": "res://shader/compute/water/water_fill.glsl", "name": "water_fill", "critical": false},
		{"path": "res://shader/compute/water/water_jfa.glsl", "name": "water_jfa", "critical": false},
		{"path": "res://shader/compute/water/water_size_classify.glsl", "name": "water_size_classify", "critical": false},
		{"path": "res://shader/compute/water/river_sources.glsl", "name": "river_sources", "critical": false},
		{"path": "res://shader/compute/water/river_propagation.glsl", "name": "river_propagation", "critical": false},
		{"path": "res://shader/compute/water/river_classify.glsl", "name": "river_classify", "critical": false},
		{"path": "res://shader/compute/water/river_flow_direction.glsl", "name": "river_flow_direction", "critical": false},
		{"path": "res://shader/compute/water/river_fill_depression.glsl", "name": "river_fill_depression", "critical": false},
		{"path": "res://shader/compute/water/river_ocean_connect.glsl", "name": "river_ocean_connect", "critical": false},
		{"path": "res://shader/compute/water/river_type_assign.glsl", "name": "river_type_assign", "critical": false},
		{"path": "res://shader/compute/water/river_type_promote.glsl", "name": "river_type_promote", "critical": false},
		# Shaders Régions Administratives (Étape 4)
		{"path": "res://shader/compute/region/region_seed_placement.glsl", "name": "region_seed_placement", "critical": false},
		{"path": "res://shader/compute/region/region_growth.glsl", "name": "region_growth", "critical": false},
		{"path": "res://shader/compute/region/region_cleanup.glsl", "name": "region_cleanup", "critical": false},
		{"path": "res://shader/compute/region/region_finalize.glsl", "name": "region_finalize", "critical": false},
		# Shaders Régions Océaniques (Étape 4.5)
		{"path": "res://shader/compute/ocean_region/ocean_region_seed_placement.glsl", "name": "ocean_region_seed_placement", "critical": false},
		{"path": "res://shader/compute/ocean_region/ocean_region_growth.glsl", "name": "ocean_region_growth", "critical": false},
		{"path": "res://shader/compute/ocean_region/ocean_region_cleanup.glsl", "name": "ocean_region_cleanup", "critical": false},
		{"path": "res://shader/compute/ocean_region/ocean_region_finalize.glsl", "name": "ocean_region_finalize", "critical": false},
		# Shaders Biomes (Étape 4.1)
		{"path": "res://shader/compute/biome/biome_classify.glsl", "name": "biome_classify", "critical": false},
		{"path": "res://shader/compute/biome/biome_smooth.glsl", "name": "biome_smooth", "critical": false},
		# Shaders Final Map (Étape 6)
		{"path": "res://shader/compute/final_map.glsl", "name": "final_map", "critical": false},
		{"path": "res://shader/compute/water/water_to_color.glsl", "name": "water_to_color", "critical": false},
		# Shader Gas Giant Final Map (Type 6 - Gazeuse)
		{"path": "res://shader/compute/gas_giant_final.glsl", "name": "gas_giant_final", "critical": false},
		{"path": "res://shader/compute/gas_giant/gas_giant_velocity_init.glsl", "name": "gas_giant_velocity_init", "critical": false},
		{"path": "res://shader/compute/gas_giant/gas_giant_dye_init.glsl", "name": "gas_giant_dye_init", "critical": false},
		{"path": "res://shader/compute/gas_giant/gas_giant_advect.glsl", "name": "gas_giant_advect", "critical": false},
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
	"""Valide les textures d'état créées par GPUContext et recrée les absentes."""
	
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
	
	# GPUContext initialise déjà ces textures. L'ancienne version les recréait
	# ici puis remplaçait leurs RIDs dans le dictionnaire sans libérer les RIDs
	# d'origine (six textures perdues à chaque génération).
	var created_count := 0
	var reused_count := 0
	for tex_name in gpu.textures.keys():
		var existing_rid: RID = gpu.textures[tex_name]
		if existing_rid.is_valid():
			reused_count += 1
			continue

		var rid = rd.texture_create(fmt, RDTextureView.new(), [zero_data])
		if not rid.is_valid():
			push_error("[Orchestrator] ❌ Échec création texture: ", tex_name)
			continue
		gpu.textures[tex_name] = rid
		created_count += 1
	
	print("[Orchestrator] ✅ Textures d'état: ", reused_count, " réutilisées, ", created_count, " recréées")

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
		
		# Set 0 A->B : plates + geo en lecture, crust_age -> crust_age_temp
		var uniforms_jfa_ab = [
			gpu.create_texture_uniform(0, gpu.textures["plates"]),
			gpu.create_texture_uniform(1, gpu.textures["crust_age"]),
			gpu.create_texture_uniform(2, gpu.textures["crust_age_temp"]),
			gpu.create_texture_uniform(3, gpu.textures["geo"]),
		]
		
		gpu.uniform_sets["crust_age_jfa_textures"] = rd.uniform_set_create(uniforms_jfa_ab, gpu.shaders["crust_age_jfa"], 0)
		if not gpu.uniform_sets["crust_age_jfa_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create crust_age_jfa A->B uniform set")
		else:
			print("    ✅ crust_age_jfa A->B uniform set créé")

		# Set 0 B->A : crust_age_temp -> crust_age. La passe d'initialisation
		# utilise également ce set car elle ignore l'entrée et initialise A.
		var uniforms_jfa_ba = [
			gpu.create_texture_uniform(0, gpu.textures["plates"]),
			gpu.create_texture_uniform(1, gpu.textures["crust_age_temp"]),
			gpu.create_texture_uniform(2, gpu.textures["crust_age"]),
			gpu.create_texture_uniform(3, gpu.textures["geo"]),
		]

		gpu.uniform_sets["crust_age_jfa_textures_swap"] = rd.uniform_set_create(uniforms_jfa_ba, gpu.shaders["crust_age_jfa"], 0)
		if not gpu.uniform_sets["crust_age_jfa_textures_swap"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create crust_age_jfa B->A uniform set")
		else:
			print("    ✅ crust_age_jfa B->A uniform set créé")
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
		
		# Set 0 : Textures (climate en lecture/écriture, precipitation_colored en écriture, geo en lecture pour effet orographique)
		var uniforms_precipitation = [
			gpu.create_texture_uniform(0, gpu.textures["climate"]),
			gpu.create_texture_uniform(1, gpu.textures["precipitation_colored"]),
			gpu.create_texture_uniform(2, gpu.textures["geo"]),  # Ajouté pour effet orographique
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
	# NOTE: L'uniform set ice_caps est créé de façon lazy dans _dispatch_ice_caps()
	# car il dépend de water_colored qui n'est initialisé que pendant run_water_phase().
	if gpu.shaders.has("ice_caps") and gpu.shaders["ice_caps"].is_valid():
		print("  • ice_caps: uniform set sera créé lors du dispatch (dépendant de water_colored)")
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
	last_phase_timings_ms.clear()
	last_performance_report.clear()
	var simulation_started_usec = Time.get_ticks_usec()
	
	print("  Résolution de la simulation : ", w, "x", h)
	
	var _rids_to_free: Array[RID] = []

	# === TYPE 6 (GAZEUSE) : Pipeline simplifié ===
	# Les planètes gazeuses n'ont pas de surface solide.
	# Leur météorologie visible est générée directement par le pipeline
	# gazeux : aucune carte de température/précipitation terrestre n'est créée.
	var atmosphere_type = int(generation_params.get("planet_type", 0))
	if atmosphere_type == Enum.TYPE_GAZEUZE:
		print("[Orchestrator] 🪐 Planète gazeuse détectée - pipeline simplifié")
		
		# Carte finale gazeuse (pipeline multi-passes, écoulement fluide par advection)
		_run_timed_phase("gas_giant", run_gas_giant_phase.bind(generation_params, w, h))
		gpu.sync_for_cpu("simulation_complete")
		_record_total_simulation_time(simulation_started_usec)
		var gas_release := gpu.prepare_for_export(true)
		_build_performance_report(simulation_started_usec, gas_release)
		_print_phase_timing_summary()
		
		print("=".repeat(60))
		print("[Orchestrator] ✅ SIMULATION GAZEUSE TERMINÉE")
		print("=".repeat(60) + "\n")
		return

	# === ÉTAPE 0 : GÉNÉRATION TOPOGRAPHIQUE DE BASE ===
	_run_timed_phase("base_elevation", run_base_elevation_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 0.5 : ÂGE DE CROÛTE OCÉANIQUE (JFA) ===
	_run_timed_phase("crust_age", run_crust_age_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 0.6 : CRATÈRES D'IMPACT (planètes sans atmosphère) ===
	_run_timed_phase("cratering", run_cratering_phase.bind(generation_params, w, h))

	# === ÉTAPE 1.5 : CLIMAT PRÉLIMINAIRE POUR L'ÉROSION ===
	# L'érosion lit climate.G pour la pluie et climate.R pour le gel/évaporation.
	# Ces canaux doivent être valides avant la première itération hydraulique.
	_run_timed_phase("pre_erosion_climate", run_pre_erosion_climate_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 2 : ÉROSION HYDRAULIQUE ===
	_run_timed_phase("erosion", run_erosion_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 3 : ATMOSPHÈRE & CLIMAT ===
	# IMPORTANT: Doit être exécuté AVANT la classification des eaux
	# car les rivières dépendent des précipitations (climate texture canal G)
	_run_timed_phase("final_climate", run_atmosphere_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 2.5 : CLASSIFICATION DES EAUX & RIVIÈRES ===
	_run_timed_phase("water", run_water_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 3.5 : BANQUISE (après eau pour vérifier water_colored) ===
	_run_timed_phase("ice_caps", run_ice_caps_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 4.1 : BIOMES ===
	_run_timed_phase("biomes", run_biome_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 4 : RÉGIONS ADMINISTRATIVES ===
	_run_timed_phase("land_regions", run_region_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 4.5 : RÉGIONS OCÉANIQUES ===
	_run_timed_phase("ocean_regions", run_ocean_region_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 5 : RESSOURCES & PÉTROLE ===
	_run_timed_phase("resources", run_resources_phase.bind(generation_params, w, h))
	
	# === ÉTAPE 6 : FINAL MAP (COMBINAISON) ===
	_run_timed_phase("final_map", run_final_map_phase.bind(generation_params, w, h))
	# All previous dispatches are ordered on one controlled local-device queue.
	# This is the final simulation dependency before CPU export.
	gpu.sync_for_cpu("simulation_complete")
	_record_total_simulation_time(simulation_started_usec)
	var lifecycle_release := gpu.prepare_for_export(false)
	_build_performance_report(simulation_started_usec, lifecycle_release)
	_print_phase_timing_summary()
	
	print("[Orchestrator] 🧹 Nettoyage de ", _rids_to_free.size(), " ressources temporaires...")
	if rd:
		for rid in _rids_to_free:
			if rid.is_valid():
				gpu.release_rid(rid)
	else:
		push_warning("[Orchestrator] RD is null, skipping temp cleanup")
	_rids_to_free.clear()
	
	print("=".repeat(60))
	print("[Orchestrator] ✅ SIMULATION TERMINÉE (Clean)")
	print("=".repeat(60) + "\n")

## Exécute une phase et conserve sa durée pour les benchmarks déterministes.
func _run_timed_phase(phase_name: String, phase_callable: Callable) -> void:
	var started_usec = Time.get_ticks_usec()
	phase_callable.call()
	var elapsed_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	last_phase_timings_ms[phase_name] = elapsed_ms
	print("[Timing] ", phase_name, ": ", snappedf(elapsed_ms, 0.01), " ms")
	gpu._sample_memory_peaks()

func _record_total_simulation_time(started_usec: int) -> void:
	last_phase_timings_ms["total_simulation"] = float(Time.get_ticks_usec() - started_usec) / 1000.0

func _print_phase_timing_summary() -> void:
	print("[Timing] --- Simulation phase summary ---")
	for phase_name in last_phase_timings_ms:
		print("[Timing] ", phase_name, " = ", snappedf(float(last_phase_timings_ms[phase_name]), 0.01), " ms")
	if not last_performance_report.is_empty():
		print("[Timing] GPU queue wall = ", snappedf(float(last_performance_report.get("gpu_simulation_wall_ms", 0.0)), 0.01), " ms")
		print("[Timing] sync/readback = ", snappedf(float(last_performance_report.get("sync_time_ms", 0.0)), 0.01), "/", snappedf(float(last_performance_report.get("readback_time_ms", 0.0)), 0.01), " ms")

func _build_performance_report(started_usec: int, lifecycle_release: Dictionary) -> void:
	var gpu_metrics := gpu.get_metrics_snapshot()
	last_performance_report = gpu_metrics.duplicate(true)
	last_performance_report["gpu_simulation_wall_ms"] = (
		float(Time.get_ticks_usec() - started_usec) / 1000.0
	)
	last_performance_report["phase_enqueue_and_cpu_ms"] = last_phase_timings_ms.duplicate(true)
	last_performance_report["texture_lifecycle"] = gpu.get_texture_lifecycle()
	last_performance_report["lifecycle_release"] = lifecycle_release.duplicate(true)

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
	# - float planet_radius_km, uint active_plate_count (8 bytes)
	# - float feature_frequency_scale, chain_width_km (8 bytes)
	# Total : 48 bytes (aligné sur 16 bytes pour std140)
	
	var seed_val = int(params.get("seed", 12345))
	var elevation_modifier = float(params.get("terrain_scale", 0.0))
	var sea_level = float(params.get("sea_level", 0.0))
	var cylinder_radius = float(w) / (2.0 * PI)  # Rayon du cylindre pour le bruit seamless
	var planet_radius_km = maxf(float(params.get("planet_radius", 150.0)), 1.0)
	var radius_scale = maxf(planet_radius_km / 150.0, 0.01)
	var active_plate_count = clampi(int(round(12.0 * pow(radius_scale, 0.55))), 8, 48)
	var feature_frequency_scale = clampf(pow(radius_scale, 0.45), 0.65, 3.0)
	var chain_width_km = clampf(6.0 * pow(radius_scale, 0.35), 4.0, 18.0)
	
	# Convertir pourcentage océan en seuil FBM
	var ocean_ratio = float(params.get("ocean_ratio", 55.0))
	var ocean_threshold = _percentage_to_threshold(ocean_ratio)
	
	# Créer le buffer de données (PackedByteArray)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)
	
	# Écrire les données (little-endian)
	buffer_bytes.encode_u32(0, seed_val)           # seed
	buffer_bytes.encode_u32(4, w)                   # width
	buffer_bytes.encode_u32(8, h)                   # height
	buffer_bytes.encode_float(12, elevation_modifier) # elevation_modifier
	buffer_bytes.encode_float(16, sea_level)        # sea_level
	buffer_bytes.encode_float(20, cylinder_radius)  # cylinder_radius
	buffer_bytes.encode_float(24, ocean_threshold)  # ocean_threshold
	buffer_bytes.encode_float(28, 0.0)              # padding3
	buffer_bytes.encode_float(32, planet_radius_km)
	buffer_bytes.encode_u32(36, active_plate_count)
	buffer_bytes.encode_float(40, feature_frequency_scale)
	buffer_bytes.encode_float(44, chain_width_km)
	
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
		gpu.release_rid(param_buffer)
		return
	
	# 5. Calcul des groupes de travail (16x16 threads par groupe)
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	print("  Seed: ", seed_val)
	print("  Elevation Modifier: ", elevation_modifier)
	print("  Sea Level: ", sea_level)
	print("  Cylinder Radius: ", cylinder_radius)
	print("  Ocean Ratio: ", ocean_ratio, "% -> threshold: ", ocean_threshold)
	print("  Physical tectonics: ", active_plate_count, " plates | feature scale: ",
		snappedf(feature_frequency_scale, 0.01), " | chain width: ",
		snappedf(chain_width_km, 0.1), " km")
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
	gpu.submit_gpu_work()
	
	# 8. Nettoyage des ressources temporaires
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	
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
	if (
		not gpu.uniform_sets.has("crust_age_jfa_textures")
		or not gpu.uniform_sets["crust_age_jfa_textures"].is_valid()
		or not gpu.uniform_sets.has("crust_age_jfa_textures_swap")
		or not gpu.uniform_sets["crust_age_jfa_textures_swap"].is_valid()
	):
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
	var sea_level = float(params.get("sea_level", 0.0))
	
	# Calculer le nombre de passes JFA
	var max_dim = max(w, h)
	var num_passes = int(ceil(log(float(max_dim)) / log(2.0))) + 1
	
	print("  Spreading Rate: ", spreading_rate, " km/Ma")
	print("  Planet Radius: ", planet_radius, " km")
	print("  JFA Passes: ", num_passes)
	
	# === PASSE 0 : INITIALISATION ===
	# La passe d'initialisation écrit toujours dans crust_age (B->A).
	_dispatch_jfa_pass(w, h, groups_x, groups_y, 0, max_dim, spreading_rate, sea_level, true)
	
	# === PASSES 1+ : PROPAGATION JFA ===
	var step_size = max_dim / 2
	var pass_idx = 1
	var current_is_primary = true
	while step_size >= 1:
		# Si A est courant, écrire A->B. Sinon écrire B->A.
		var write_to_primary = not current_is_primary
		_dispatch_jfa_pass(w, h, groups_x, groups_y, pass_idx, step_size, spreading_rate, sea_level, write_to_primary)
		current_is_primary = not current_is_primary
		step_size = step_size / 2
		pass_idx += 1

	# La finalisation lit toujours crust_age. Si la dernière propagation a
	# produit crust_age_temp, une dernière relaxation step=1 la ramène dans A.
	if not current_is_primary:
		_dispatch_jfa_pass(w, h, groups_x, groups_y, pass_idx, 1, spreading_rate, sea_level, true)
		pass_idx += 1
	
	print("  JFA terminé après ", pass_idx, " passes")
	
	# === PASSE FINALE : CALCUL ÂGE ET SUBSIDENCE ===
	_dispatch_crust_age_finalize(w, h, groups_x, groups_y, spreading_rate, planet_radius, max_age, subsidence_coeff, sea_level)
	
	print("[Orchestrator] ✅ Phase 0.5 : Âge de croûte calculé")

## Dispatch une passe JFA
func _dispatch_jfa_pass(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, step_size: int, spreading_rate: float, sea_level: float, use_swap: bool) -> void:
	# Structure UBO pour crust_age_jfa:
	# uint width, height, pass_index, step_size (16 bytes)
	# float spreading_rate, sea_level, padding2, padding3 (16 bytes)
	# Total: 32 bytes
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)              # width
	buffer_bytes.encode_u32(4, h)              # height
	buffer_bytes.encode_u32(8, pass_index)     # pass_index
	buffer_bytes.encode_u32(12, step_size)     # step_size
	buffer_bytes.encode_float(16, spreading_rate)  # spreading_rate
	buffer_bytes.encode_float(20, sea_level)   # sea_level
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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["crust_age_jfa"])
	var uniform_set_name = "crust_age_jfa_textures_swap" if use_swap else "crust_age_jfa_textures"
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

## Dispatch la passe de finalisation (calcul âge + subsidence)
func _dispatch_crust_age_finalize(w: int, h: int, groups_x: int, groups_y: int, spreading_rate: float, planet_radius: float, max_age: float, subsidence_coeff: float, sea_level: float) -> void:
	# Structure UBO pour crust_age_finalize:
	# uint width, height (8 bytes)
	# float spreading_rate, planet_radius, max_age, subsidence_coeff, sea_level, padding2 (24 bytes)
	# Total: 32 bytes
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                    # width
	buffer_bytes.encode_u32(4, h)                    # height
	buffer_bytes.encode_float(8, spreading_rate)    # spreading_rate
	buffer_bytes.encode_float(12, planet_radius)    # planet_radius
	buffer_bytes.encode_float(16, max_age)          # max_age
	buffer_bytes.encode_float(20, subsidence_coeff) # subsidence_coeff
	buffer_bytes.encode_float(24, sea_level)         # sea_level
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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["crust_age_finalize"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["crust_age_finalize_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

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
	
	# Vérifier si la planète peut avoir des cratères
	# Types avec cratères : Sans Atmosphère (3), Mort (4), Stérile (5)
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type not in [Enum.TYPE_NO_ATMOS, Enum.TYPE_DEAD, Enum.TYPE_STERILE]:
		print("[Orchestrator] ⏭️ Phase 0.6 : Cratères ignorés (planète avec atmosphère épaisse)")
		return
	
	print("[Orchestrator] ☄️ Phase 0.6 : Génération des cratères d'impact (type=", atmosphere_type, ")")
	
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
		gpu.release_rid(param_buffer)
		return
	
	# Dispatch du compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["cratering"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["cratering_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	# Nettoyage
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	
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
	
	# Vérifier si la planète a une atmosphère (pas d'érosion sur planète sans atmosphère/stérile)
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]:  # Sans atmosphère ou Stérile
		print("[Orchestrator] ⏭️ Phase 2 : Érosion ignorée (type=", atmosphere_type, ")")
		return
	
	print("[Orchestrator] 💧 Phase 2 : Hydrologie de surface (sans incision)")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	# Paramètres d'érosion - valeurs augmentées pour effet visible
	# Itérations: 50 → 200 pour propagation suffisante
	var erosion_iterations = int(params.get("erosion_iterations", 200))
	# Rain rate: 0.005 → 0.012 pour plus d'eau disponible
	var rain_rate = float(params.get("rain_rate", 0.012))
	var evap_rate = float(params.get("evap_rate", 0.02))
	var flow_rate = float(params.get("flow_rate", 0.25))
	# L'incision de canyon est volontairement désactivée. La phase conserve la
	# pluie, l'écoulement et l'accumulation nécessaires aux rivières, mais le
	# transport sédimentaire sert uniquement au ping-pong des textures.
	var erosion_rate := 0.0
	var deposition_rate := 0.0
	# Capacity multiplier: 1.0 → 2.5 pour transport plus efficace
	var capacity_multiplier = float(params.get("capacity_multiplier", 2.5))
	var sea_level = float(params.get("sea_level", 0.0))
	var planet_radius_km = float(params.get("planet_radius", 6371.0))
	var gravity = compute_gravity(planet_radius_km, float(params.get("planet_density", 5.51)))
	var pixel_size_x_m = (2.0 * PI * planet_radius_km * 1000.0) / float(max(w, 1))
	var pixel_size_y_m = (PI * planet_radius_km * 1000.0) / float(max(h, 1))
	var nominal_cell_size_m = sqrt(pixel_size_x_m * pixel_size_y_m)
	var max_erosion_per_pass_m := 0.0
	var channel_flux_threshold = clampf(
		0.008 * pow(maxf(nominal_cell_size_m / 1000.0, 0.01), 0.25),
		0.005,
		0.04
	)
	
	# Paramètres pour l'accumulation de flux
	var flux_iterations = int(params.get("flux_iterations", 10))
	var base_flux = float(params.get("base_flux", 1.0))
	var propagation_rate = float(params.get("propagation_rate", 0.8))
	
	print("  Iterations: ", erosion_iterations)
	print("  Rain Rate: ", rain_rate, " | Evap Rate: ", evap_rate)
	print("  Flow Rate: ", flow_rate)
	print("  Incision/deposition terrain: désactivée (aucun canyon)")
	print("  Channel flux threshold: ", snappedf(channel_flux_threshold, 0.0001))
	print("  Nominal cell size: ", snappedf(pixel_size_x_m, 0.01), "m × ", snappedf(pixel_size_y_m, 0.01), "m")
	print("  Surface gravity: ", snappedf(gravity, 0.001), " m/s²")
	
	# === BOUCLE HYDROLOGIQUE ===
	for _iter in range(erosion_iterations):
		# === PASSE 1 : PLUIE + ÉVAPORATION ===
		# geo est toujours l'état autoritatif au début d'une itération.
		_dispatch_erosion_rainfall(w, h, groups_x, groups_y, rain_rate, evap_rate, sea_level)
		
		# === PASSE 2 : ÉCOULEMENT A->B ===
		_dispatch_erosion_flow(w, h, groups_x, groups_y, flow_rate, sea_level, gravity, pixel_size_x_m, pixel_size_y_m, false)
		
		# === PASSE 3 : CONSERVATION DE L'ÉTAT B->A (sans incision) ===
		# Chaque itération se termine donc dans geo; aucune itération impaire ne
		# peut relire ou restaurer un état temporaire obsolète.
		_dispatch_erosion_sediment(w, h, groups_x, groups_y, erosion_rate,
			deposition_rate, capacity_multiplier, sea_level, pixel_size_x_m,
			pixel_size_y_m, max_erosion_per_pass_m, channel_flux_threshold, true)
	
	# === PASSE 4 : ACCUMULATION DE FLUX (pour rivières) ===
	print("  • Accumulation de flux (", flux_iterations, " passes)")
	for pass_idx in range(flux_iterations):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_erosion_flux_accumulation(w, h, groups_x, groups_y, pass_idx, sea_level, base_flux, propagation_rate, use_swap)
	
	print("[Orchestrator] ✅ Phase 2 : Hydrologie de surface terminée")

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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_rainfall"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["erosion_rainfall_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

## Dispatch le shader d'écoulement
func _dispatch_erosion_flow(w: int, h: int, groups_x: int, groups_y: int, flow_rate: float, sea_level: float, gravity: float, pixel_size_x_m: float, pixel_size_y_m: float, use_swap: bool) -> void:
	var uniform_set_name = "erosion_flow_textures_swap" if use_swap else "erosion_flow_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float flow_rate, min_slope, sea_level, gravity (16 bytes)
	# float pixel_size_x_m, pixel_size_y_m (8 bytes)
	
	var min_slope = 0.001
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, flow_rate)
	buffer_bytes.encode_float(12, min_slope)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, gravity)
	buffer_bytes.encode_float(24, pixel_size_x_m)
	buffer_bytes.encode_float(28, pixel_size_y_m)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_flow"], 1)
	if not param_set.is_valid():
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_flow"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

## Dispatch le shader de transport de sédiments
func _dispatch_erosion_sediment(w: int, h: int, groups_x: int, groups_y: int,
		erosion_rate: float, deposition_rate: float, capacity_multiplier: float,
		sea_level: float, pixel_size_x_m: float, pixel_size_y_m: float,
		max_erosion_per_pass_m: float, channel_flux_threshold: float,
		use_swap: bool) -> void:
	var uniform_set_name = "erosion_sediment_textures_swap" if use_swap else "erosion_sediment_textures"
	if not gpu.uniform_sets.has(uniform_set_name) or not gpu.uniform_sets[uniform_set_name].is_valid():
		return
	
	# Structure UBO (std140, 32 bytes):
	# uint width, height (8 bytes)
	# float erosion_rate, deposition_rate, capacity_multiplier, min_slope,
	# sea_level, bedrock_hardness, pixel_size_x_m, pixel_size_y_m (32 bytes)
	
	var min_slope = 0.001
	var bedrock_hardness = 0.5
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)
	
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, erosion_rate)
	buffer_bytes.encode_float(12, deposition_rate)
	buffer_bytes.encode_float(16, capacity_multiplier)
	buffer_bytes.encode_float(20, min_slope)
	buffer_bytes.encode_float(24, sea_level)
	buffer_bytes.encode_float(28, bedrock_hardness)
	buffer_bytes.encode_float(32, pixel_size_x_m)
	buffer_bytes.encode_float(36, pixel_size_y_m)
	buffer_bytes.encode_float(40, max_erosion_per_pass_m)
	buffer_bytes.encode_float(44, channel_flux_threshold)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		return
	
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["erosion_sediment"], 1)
	if not param_set.is_valid():
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_sediment"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["erosion_flux_accumulation"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets[uniform_set_name], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)


# ============================================================================
# ÉTAPE 3 : ATMOSPHÈRE & CLIMAT
# ============================================================================

## Calcule uniquement température et précipitation sur le relief pré-érodé.
## Ce pré-passage fournit à l'érosion une pluie valide sans générer deux fois
## les nuages. Le passage climatique complet est recalculé après l'érosion.
func run_pre_erosion_climate_phase(params: Dictionary, w: int, h: int) -> void:
	var atmosphere_type = int(params.get("planet_type", 0))
	if atmosphere_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]:
		return

	print("[Orchestrator] 🌦️ Phase 1.5 : Climat préliminaire pour l'érosion")
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	var seed_val = int(params.get("seed", 12345))
	var avg_temperature = float(params.get("avg_temperature", 15.0))
	var avg_precipitation = float(params.get("global_humidity", 0.5))
	var sea_level = float(params.get("sea_level", 0.0))
	var cylinder_radius = float(w) / (2.0 * PI)

	_dispatch_temperature(w, h, groups_x, groups_y, seed_val, avg_temperature, sea_level, cylinder_radius, atmosphere_type)
	_dispatch_precipitation(w, h, groups_x, groups_y, seed_val, avg_precipitation, cylinder_radius, atmosphere_type, sea_level)
	print("[Orchestrator] ✅ Climat préliminaire prêt")

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
	var avg_precipitation = float(params.get("global_humidity", 0.5))
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("planet_type", 0))
	var cylinder_radius = float(w) / (2.0 * PI)
	
	# === PASSE 1 : TEMPÉRATURE ===
	_dispatch_temperature(w, h, groups_x, groups_y, seed_val, avg_temperature, sea_level, cylinder_radius, atmosphere_type)
	
	# === PASSE 2 : PRÉCIPITATION ===
	_dispatch_precipitation(w, h, groups_x, groups_y, seed_val, avg_precipitation, cylinder_radius, atmosphere_type, sea_level)
	
	# Pas de nuages ni de banquise sur planètes sans atmosphère ou stériles
	if atmosphere_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]:
		print("  ⏭️ Nuages et banquise ignorés (type=", atmosphere_type, ")")
		print("[Orchestrator] ✅ Phase 3 : Atmosphère & Climat terminée")
		return
	
	# === PASSE 3 : NUAGES ===
	var cloud_coverage = float(params.get("cloud_coverage", 0.5))
	var cloud_density = float(params.get("cloud_density", 0.8))
	_dispatch_clouds(w, h, groups_x, groups_y, seed_val, cloud_coverage, cloud_density, cylinder_radius, atmosphere_type)

	# NOTE: Banquise (ice_caps) déplacée après la phase eau pour pouvoir
	# vérifier water_colored et éviter de générer de la glace sans eau.
	
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
		gpu.release_rid(param_buffer)
		return
	
	# === SET 2 : PALETTE DE COULEURS DYNAMIQUE (SSBO) ===
	var palette_data: PackedByteArray = Enum.build_temperature_palette(atmosphere_type)
	var palette_ssbo: RID = rd.storage_buffer_create(palette_data.size(), palette_data)
	if not palette_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create temperature palette SSBO")
		gpu.release_rid(param_set)
		gpu.release_rid(param_buffer)
		return
	
	var palette_uniform := RDUniform.new()
	palette_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	palette_uniform.binding = 0
	palette_uniform.add_id(palette_ssbo)
	
	var palette_set: RID = rd.uniform_set_create([palette_uniform], gpu.shaders["temperature"], 2)
	if not palette_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create temperature palette uniform set")
		gpu.release_rid(palette_ssbo)
		gpu.release_rid(param_set)
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["temperature"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["temperature_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, palette_set, 2)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(palette_set)
	gpu.release_rid(palette_ssbo)
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

## Dispatch le shader de précipitation
func _dispatch_precipitation(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, avg_precipitation: float, cylinder_radius: float, atmosphere_type: int, sea_level: float = 0.0) -> void:
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
	# float sea_level (4 bytes)
	# padding (4 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, avg_precipitation)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_u32(20, atmosphere_type)
	buffer_bytes.encode_float(24, sea_level)  # sea_level pour effet orographique
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
		gpu.release_rid(param_buffer)
		return
	
	# === SET 2 : PALETTE DE COULEURS DYNAMIQUE (SSBO) ===
	var palette_data: PackedByteArray = Enum.build_precipitation_palette(atmosphere_type)
	var palette_ssbo: RID = rd.storage_buffer_create(palette_data.size(), palette_data)
	if not palette_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create precipitation palette SSBO")
		gpu.release_rid(param_set)
		gpu.release_rid(param_buffer)
		return
	
	var palette_uniform := RDUniform.new()
	palette_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	palette_uniform.binding = 0
	palette_uniform.add_id(palette_ssbo)
	
	var palette_set: RID = rd.uniform_set_create([palette_uniform], gpu.shaders["precipitation"], 2)
	if not palette_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create precipitation palette uniform set")
		gpu.release_rid(palette_ssbo)
		gpu.release_rid(param_set)
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["precipitation"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["precipitation_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, palette_set, 2)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(palette_set)
	gpu.release_rid(palette_ssbo)
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)


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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["clouds"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["clouds_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)


## Phase banquise - exécutée APRÈS la phase eau pour avoir accès à water_colored
func run_ice_caps_phase(params: Dictionary, w: int, h: int) -> void:
	var atmosphere_type = int(params.get("planet_type", 0))
	
	# Pas de banquise sur planètes sans atmosphère ou stériles
	if atmosphere_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]:
		print("[Orchestrator] ⏭️ Banquise ignorée (type=", atmosphere_type, ")")
		return
	
	print("[Orchestrator] 🧊 Phase 3.5 : Banquise")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	var seed_val = int(params.get("seed", 12345))
	var ice_probability = float(params.get("ice_probability", 0.9))
	var sea_level = float(params.get("sea_level", 0.0))
	
	_dispatch_ice_caps(w, h, groups_x, groups_y, seed_val, ice_probability, atmosphere_type, sea_level)
	
	print("[Orchestrator] ✅ Phase 3.5 : Banquise terminée")


## Dispatch le shader de banquise
func _dispatch_ice_caps(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, ice_probability: float, atmosphere_type: int, sea_level: float) -> void:
	if not gpu.shaders.has("ice_caps") or not gpu.shaders["ice_caps"].is_valid():
		push_warning("[Orchestrator] ⚠️ ice_caps shader non disponible")
		return
	
	# Création lazy de l'uniform set (water_colored doit exister)
	if not gpu.uniform_sets.has("ice_caps_textures") or not gpu.uniform_sets["ice_caps_textures"].is_valid():
		if not gpu.textures.has("water_colored") or not gpu.textures["water_colored"].is_valid():
			push_error("[Orchestrator] ❌ water_colored texture indisponible pour ice_caps")
			return
		print("  • Création lazy uniform set: ice_caps")
		var uniforms_ice = [
			gpu.create_texture_uniform(0, gpu.textures["geo"]),
			gpu.create_texture_uniform(1, gpu.textures["climate"]),
			gpu.create_texture_uniform(2, gpu.textures["ice_caps"]),
			gpu.create_texture_uniform(3, gpu.textures["water_colored"]),
		]
		gpu.uniform_sets["ice_caps_textures"] = rd.uniform_set_create(uniforms_ice, gpu.shaders["ice_caps"], 0)
		if not gpu.uniform_sets["ice_caps_textures"].is_valid():
			push_error("[Orchestrator] ❌ Failed to create ice_caps textures uniform set")
			return
		print("    ✅ ice_caps textures uniform set créé")
	
	print("  • Banquise (probabilité: ", ice_probability, ")")
	
	# Structure UBO (std140, 32 bytes):
	# uint seed, width, height (12 bytes)
	# float ice_probability (4 bytes)
	# uint atmosphere_type (4 bytes)
	# float sea_level (4 bytes)
	# padding (8 bytes)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, ice_probability)
	buffer_bytes.encode_u32(16, atmosphere_type)
	buffer_bytes.encode_float(20, sea_level)
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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ice_caps"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["ice_caps_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

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
# ÉTAPE 2.5 : CLASSIFICATION DES EAUX & RIVIÈRES
# ============================================================================

## Génère les cartes d'eau et de rivières.
##
## Cette phase exécute :
## 1. Water Fill : Identifie les zones d'eau (sous niveau mer + lacs altitude)
## 2. Water JFA : Regroupe en composantes connexes via Jump Flood Algorithm
## 3. Water Size Classify : Classifie eau salée (>= min_size) / douce (< min_size)
## 4. River Sources : Détecte les points sources de rivières
## 5. River Propagation : Propage le flux des rivières vers l'aval
##
## @param params: Dictionnaire contenant seed, sea_level, saltwater_min_size, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_water_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 💧 Phase 2.5 : Hydrologie déterministe")
	last_hydrology_stats.clear()

	var groups_x := ceili(float(w) / 16.0)
	var groups_y := ceili(float(h) / 16.0)
	var seed_val := int(params.get("seed", 12345))
	var sea_level := float(params.get("sea_level", 0.0))
	var atmosphere_type := int(params.get("planet_type", 0))

	# Les textures restent initialisées même lorsqu'un type de planète ne peut
	# pas avoir d'eau liquide, car les phases finales les référencent.
	gpu.initialize_water_textures()
	if atmosphere_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]:
		last_hydrology_stats = {"skipped_no_liquid_water": true}
		print("  ⏭️ Planète sans eau liquide (type=", atmosphere_type, ")")
		return

	var saltwater_min_size := maxi(int(params.get("saltwater_min_size", 1000)), 1)
	var freshwater_min_size := maxi(int(params.get("freshwater_min_size", 32)), 1)
	var lake_threshold := maxf(float(params.get("lake_threshold", 5.0)), 0.01)
	var river_precip_scale := maxf(float(params.get("river_precip_scale", 1.0)), 0.0)

	print("  Seed: ", seed_val, " | Sea Level: ", sea_level)
	print("  Lake minimum: ", lake_threshold, "m depth / ", freshwater_min_size, " cells")
	print("  Saltwater minimum: ", saltwater_min_size, " connected cells")

	# 1. Le premier masque ne contient que l'océan thermiquement liquide.
	# Les lacs seront dérivés ensuite de la profondeur réelle des bassins.
	print("  • Initialisation du masque océanique...")
	_dispatch_water_fill(w, h, groups_x, groups_y, sea_level, 0.0)

	# 2. Priority-Flood exact : convergence par épuisement de la file de
	# priorité, sans nombre de passes arbitraire. Le solveur classe ensuite les
	# composantes d'eau exactes avec wrap horizontal.
	print("  • Priority-Flood convergent et classification des bassins...")
	var solver := HydrologySolver.new()
	var surface_result := solver.solve_surface_and_water(
		gpu.readback_texture_raw("geo"),
		gpu.readback_texture_raw("climate"),
		gpu.readback_texture_raw("water_mask"),
		w,
		h,
		sea_level,
		lake_threshold,
		freshwater_min_size,
		saltwater_min_size,
		atmosphere_type,
	)
	if surface_result.is_empty():
		push_error("[Orchestrator] Hydrology surface solve failed")
		return

	gpu.initialize_final_map_textures()
	var water_mask_data: PackedByteArray = surface_result["water_mask"]
	var water_color_data: PackedByteArray = surface_result["water_colored"]
	var flow_direction_data: PackedByteArray = surface_result["flow_direction"]
	rd.texture_update(gpu.textures["water_mask"], 0, water_mask_data)
	rd.texture_update(gpu.textures["water_colored"], 0, water_color_data)
	rd.texture_update(gpu.textures["flow_direction"], 0, flow_direction_data)
	last_hydrology_stats = Dictionary(surface_result["stats"]).duplicate()

	print(
		"    Lacs conservés: ", last_hydrology_stats.get("lake_components_retained", 0),
		" | cellules lac supprimées: ", last_hydrology_stats.get("lake_cells_removed", 0),
		" | composantes eau: ", last_hydrology_stats.get("water_components", 0),
	)

	# 3. Le parent enregistré lors du Priority-Flood forme directement une
	# forêt D8 sans cycle. Cela évite de reconstruire un graphe ambigu sur les
	# plateaux remplis.
	print("  • Directions D8 dérivées de la forêt Priority-Flood")

	# 4. Chaque cellule terrestre reçoit exactement une contribution locale.
	_dispatch_river_sources(w, h, groups_x, groups_y, sea_level, river_precip_scale)

	# 5. Accumulation topologique exacte. river_iterations n'est volontairement
	# plus lu : le réseau ne dépend d'aucun compteur de propagation.
	print("  • Accumulation topologique conservatrice...")
	var accumulation_result := solver.accumulate_flow(
		flow_direction_data,
		water_mask_data,
		gpu.readback_texture_raw("river_flux"),
		w,
		h,
	)
	if accumulation_result.is_empty():
		push_error("[Orchestrator] Hydrology flow accumulation failed")
		return

	var accumulated_flux: PackedByteArray = accumulation_result["flux_data"]
	rd.texture_update(gpu.textures["river_flux"], 0, accumulated_flux)
	last_hydrology_stats.merge(Dictionary(accumulation_result["stats"]), true)
	var max_flux := float(accumulation_result["max_land_flux"])
	last_hydrology_stats["max_land_flux"] = max_flux

	var unresolved := int(last_hydrology_stats.get("unresolved_land_cells", 0))
	var nonpolar_sinks := int(last_hydrology_stats.get("nonpolar_land_sinks", 0))
	var relative_mass_error := float(last_hydrology_stats.get("relative_mass_error", 1.0))
	if unresolved > 0:
		push_error("[Hydrology] Drainage graph contains %d unresolved cells" % unresolved)
	if nonpolar_sinks > 0:
		push_error("[Hydrology] Drainage graph contains %d invalid non-polar sinks" % nonpolar_sinks)
	if relative_mass_error > 0.0001:
		push_error("[Hydrology] Flux conservation error: %.8f" % relative_mass_error)

	print(
		"    Terrain traité: ", last_hydrology_stats.get("processed_land_cells", 0),
		"/", last_hydrology_stats.get("land_cells", 0),
		" | erreur de masse relative: ", snappedf(relative_mass_error, 0.00000001),
		" | liens de seam: ", last_hydrology_stats.get("seam_flow_links", 0),
	)

	# 6. Une hiérarchie basée sur le flux accumulé est monotone vers l'aval :
	# affluent -> rivière -> fleuve. L'ancienne promotion sur 500 passes est
	# supprimée, tout comme sa dépendance à une distance arbitraire.
	var map_pixels := float(w * h)
	var reference_pixels := 2000.0 * 1000.0
	var density_scale := clampf(sqrt(reference_pixels / maxf(map_pixels, 1.0)), 0.5, 4.0)
	var river_affluent_threshold := max_flux * 0.005 * density_scale
	var river_riviere_threshold := max_flux * 0.02 * density_scale
	var river_fleuve_threshold := max_flux * 0.08 * density_scale
	if max_flux <= 0.0:
		river_affluent_threshold = INF
		river_riviere_threshold = INF
		river_fleuve_threshold = INF

	params["river_affluent_threshold"] = river_affluent_threshold
	params["river_riviere_threshold"] = river_riviere_threshold
	params["river_fleuve_threshold"] = river_fleuve_threshold
	last_hydrology_stats["river_affluent_threshold"] = river_affluent_threshold
	last_hydrology_stats["river_riviere_threshold"] = river_riviere_threshold
	last_hydrology_stats["river_fleuve_threshold"] = river_fleuve_threshold

	print(
		"    Flux max: ", max_flux,
		" | seuils: ", river_affluent_threshold,
		" / ", river_riviere_threshold,
		" / ", river_fleuve_threshold,
	)
	_dispatch_river_type_assign(
		w,
		h,
		groups_x,
		groups_y,
		river_affluent_threshold,
		river_riviere_threshold,
		river_fleuve_threshold,
	)
	_dispatch_river_classify(w, h, groups_x, groups_y, atmosphere_type)

	print("[Orchestrator] ✅ Phase 2.5 : Hydrologie terminée")

## Dispatch le shader d'identification des zones d'eau
func _dispatch_water_fill(w: int, h: int, groups_x: int, groups_y: int, sea_level: float, lake_threshold: float) -> void:
	if not gpu.shaders.has("water_fill") or not gpu.shaders["water_fill"].is_valid():
		push_warning("[Orchestrator] ⚠️ water_fill shader non disponible")
		return
	
	# Créer les uniforms de texture
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# water_component (RG32I)
	var comp_uniform = RDUniform.new()
	comp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	comp_uniform.binding = 2
	comp_uniform.add_id(gpu.textures["water_component"])
	tex_uniforms.append(comp_uniform)
	
	# climate_texture (RGBA32F) - pour vérification température eau liquide
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["climate"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_fill"], 0)
	
	# UBO paramètres (16 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, sea_level)
	buffer_bytes.encode_float(12, lake_threshold)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_fill"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_fill"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader JFA pour composantes connexes
func _dispatch_water_jfa(w: int, h: int, groups_x: int, groups_y: int, step_size: int, pass_index: int, use_swap: bool) -> void:
	if not gpu.shaders.has("water_jfa") or not gpu.shaders["water_jfa"].is_valid():
		return
	
	var input_tex = gpu.textures["water_component"] if not use_swap else gpu.textures["water_component_temp"]
	var output_tex = gpu.textures["water_component_temp"] if not use_swap else gpu.textures["water_component"]
	
	var tex_uniforms: Array[RDUniform] = []
	
	# Input (lecture)
	var in_uniform = RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	in_uniform.binding = 0
	in_uniform.add_id(input_tex)
	tex_uniforms.append(in_uniform)
	
	# Output (écriture)
	var out_uniform = RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 1
	out_uniform.add_id(output_tex)
	tex_uniforms.append(out_uniform)
	
	# water_mask
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 2
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_jfa"], 0)
	
	# UBO (16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_s32(8, step_size)
	buffer_bytes.encode_u32(12, pass_index)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_jfa"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_jfa"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de classification par taille
func _dispatch_water_size_classify(w: int, h: int, groups_x: int, groups_y: int, pass_type: int, saltwater_min_size: int, freshwater_max_size: int, sea_level: float, counter_buffer: RID) -> void:
	if not gpu.shaders.has("water_size_classify") or not gpu.shaders["water_size_classify"].is_valid():
		return
	
	var tex_uniforms: Array[RDUniform] = []
	
	# water_component (lecture)
	var comp_uniform = RDUniform.new()
	comp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	comp_uniform.binding = 0
	comp_uniform.add_id(gpu.textures["water_component"])
	tex_uniforms.append(comp_uniform)
	
	# water_mask (lecture/écriture)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# geo (lecture)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["geo"]))
	
	# SSBO comptage
	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 3
	ssbo_uniform.add_id(counter_buffer)
	tex_uniforms.append(ssbo_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_size_classify"], 0)
	
	# UBO (32 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_type)
	buffer_bytes.encode_u32(12, saltwater_min_size)
	buffer_bytes.encode_u32(16, freshwater_max_size)
	buffer_bytes.encode_float(20, sea_level)
	buffer_bytes.encode_float(24, 0.0)  # padding
	buffer_bytes.encode_float(28, 0.0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_size_classify"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_size_classify"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de coloration de l'eau (remplace water_size_classify pour la sortie visuelle)
func _dispatch_water_to_color(w: int, h: int, groups_x: int, groups_y: int, pass_type: int, sea_level: float, atmosphere_type: int, freshwater_max_size: int, counter_buffer: RID) -> void:
	if not gpu.shaders.has("water_to_color") or not gpu.shaders["water_to_color"].is_valid():
		push_error("Shader water_to_color non disponible")
		return
	
	var tex_uniforms: Array[RDUniform] = []
	
	# binding 0 : water_component (rg32i) - lecture seule
	var comp_uniform = RDUniform.new()
	comp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	comp_uniform.binding = 0
	comp_uniform.add_id(gpu.textures["water_component"])
	tex_uniforms.append(comp_uniform)
	
	# binding 1 : water_mask (r8ui) - lecture seule
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# binding 2 : geo_texture (rgba32f) - lecture seule
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["geo"]))
	
	# binding 3 : water_colored (rgba8) - écriture
	var color_uniform = RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 3
	color_uniform.add_id(gpu.textures["water_colored"])
	tex_uniforms.append(color_uniform)
	
	# binding 4 : SSBO comptage
	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 4
	ssbo_uniform.add_id(counter_buffer)
	tex_uniforms.append(ssbo_uniform)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["water_to_color"], 0)
	
	# UBO (32 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)                      # width
	buffer_bytes.encode_u32(4, h)                      # height
	buffer_bytes.encode_u32(8, pass_type)             # pass_type (0=comptage, 1=coloration)
	buffer_bytes.encode_u32(12, freshwater_max_size)  # freshwater_max_size
	buffer_bytes.encode_float(16, sea_level)          # sea_level
	buffer_bytes.encode_u32(20, atmosphere_type)      # atmosphere_type
	buffer_bytes.encode_float(24, 0.0)                # padding1
	buffer_bytes.encode_float(28, 0.0)                # padding2
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["water_to_color"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["water_to_color"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de remplissage de depressions (Planchon-Darboux)
## mode: 0 = initialisation, 1 = iteration
## use_swap: alterne les buffers ping-pong
func _dispatch_fill_depression(w: int, h: int, groups_x: int, groups_y: int, sea_level: float, mode: int, use_swap: bool) -> void:
	if not gpu.shaders.has("river_fill_depression") or not gpu.shaders["river_fill_depression"].is_valid():
		push_warning("[Orchestrator] river_fill_depression shader non disponible")
		return

	# Ping-pong: alterne entre river_flux et river_flux_temp
	var input_tex = gpu.textures["river_flux"] if not use_swap else gpu.textures["river_flux_temp"]
	var output_tex = gpu.textures["river_flux_temp"] if not use_swap else gpu.textures["river_flux"]

	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: geo_texture (RGBA32F) - elevation originale
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))

	# Binding 1: water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)

	# Binding 2: filled_in (R32F) - passe precedente (lecture)
	var in_uniform = RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	in_uniform.binding = 2
	in_uniform.add_id(input_tex)
	tex_uniforms.append(in_uniform)

	# Binding 3: filled_out (R32F) - cette passe (ecriture)
	var out_uniform = RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 3
	out_uniform.add_id(output_tex)
	tex_uniforms.append(out_uniform)

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_fill_depression"], 0)

	# UBO (16 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, sea_level)
	buffer_bytes.encode_u32(12, mode)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_fill_depression"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_fill_depression"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de calcul des directions d'écoulement D8
func _dispatch_river_flow_direction(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, sea_level: float) -> void:
	if not gpu.shaders.has("river_flow_direction") or not gpu.shaders["river_flow_direction"].is_valid():
		push_warning("[Orchestrator] ⚠️ river_flow_direction shader non disponible")
		return

	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: filled_elevation (R32F) - from Planchon-Darboux depression filling
	var filled_uniform = RDUniform.new()
	filled_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	filled_uniform.binding = 0
	filled_uniform.add_id(gpu.textures["river_flux"])
	tex_uniforms.append(filled_uniform)

	# Binding 1: water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)

	# Binding 2: flow_direction (R8UI) - output
	var dir_uniform = RDUniform.new()
	dir_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dir_uniform.binding = 2
	dir_uniform.add_id(gpu.textures["flow_direction"])
	tex_uniforms.append(dir_uniform)

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_flow_direction"], 0)

	# UBO (16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_float(12, sea_level)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_flow_direction"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_flow_direction"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader d'initialisation distribuée du flux (chaque pixel = précipitation)
func _dispatch_river_sources(w: int, h: int, groups_x: int, groups_y: int, sea_level: float, precip_scale: float) -> void:
	if not gpu.shaders.has("river_sources") or not gpu.shaders["river_sources"].is_valid():
		return

	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures["climate"]))

	# water_mask
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 2
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)

	# river_flux (R32F) - output
	var flux_uniform = RDUniform.new()
	flux_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	flux_uniform.binding = 3
	flux_uniform.add_id(gpu.textures["river_flux"])
	tex_uniforms.append(flux_uniform)

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_sources"], 0)

	# UBO (16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, sea_level)
	buffer_bytes.encode_float(12, precip_scale)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_sources"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_sources"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de propagation des rivières (accumulation conservatrice)
func _dispatch_river_propagation(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, sea_level: float, precip_scale: float, use_swap: bool) -> void:
	if not gpu.shaders.has("river_propagation") or not gpu.shaders["river_propagation"].is_valid():
		return

	var input_tex = gpu.textures["river_flux"] if not use_swap else gpu.textures["river_flux_temp"]
	var output_tex = gpu.textures["river_flux_temp"] if not use_swap else gpu.textures["river_flux"]

	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: flow_direction (R8UI)
	var dir_uniform = RDUniform.new()
	dir_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dir_uniform.binding = 0
	dir_uniform.add_id(gpu.textures["flow_direction"])
	tex_uniforms.append(dir_uniform)

	# Binding 1: water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)

	# Binding 2: climate_texture (RGBA32F)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["climate"]))

	# Binding 3: flux input (R32F)
	var in_uniform = RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	in_uniform.binding = 3
	in_uniform.add_id(input_tex)
	tex_uniforms.append(in_uniform)

	# Binding 4: flux output (R32F)
	var out_uniform = RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 4
	out_uniform.add_id(output_tex)
	tex_uniforms.append(out_uniform)

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_propagation"], 0)

	# UBO (32 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_index)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, precip_scale)
	buffer_bytes.encode_float(20, 0.0)  # padding1
	buffer_bytes.encode_float(24, 0.0)  # padding2
	buffer_bytes.encode_float(28, 0.0)  # padding3

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_propagation"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_propagation"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de vérification de connectivité à l'océan
func _dispatch_river_ocean_connect(w: int, h: int, groups_x: int, groups_y: int, pass_index: int, use_swap: bool) -> void:
	if not gpu.shaders.has("river_ocean_connect") or not gpu.shaders["river_ocean_connect"].is_valid():
		return

	var input_tex = gpu.textures["ocean_reachable"] if not use_swap else gpu.textures["ocean_reachable_temp"]
	var output_tex = gpu.textures["ocean_reachable_temp"] if not use_swap else gpu.textures["ocean_reachable"]

	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: flow_direction (R8UI)
	var dir_uniform = RDUniform.new()
	dir_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dir_uniform.binding = 0
	dir_uniform.add_id(gpu.textures["flow_direction"])
	tex_uniforms.append(dir_uniform)

	# Binding 1: water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)

	# Binding 2: connect input (R8UI)
	var in_uniform = RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	in_uniform.binding = 2
	in_uniform.add_id(input_tex)
	tex_uniforms.append(in_uniform)

	# Binding 3: connect output (R8UI)
	var out_uniform = RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 3
	out_uniform.add_id(output_tex)
	tex_uniforms.append(out_uniform)

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_ocean_connect"], 0)

	# UBO (16 bytes)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_index)
	buffer_bytes.encode_u32(12, 0)  # padding

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_ocean_connect"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_ocean_connect"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de classification initiale des types de rivière (flux → type)
func _dispatch_river_type_assign(w: int, h: int, groups_x: int, groups_y: int, affluent_threshold: float, riviere_threshold: float, fleuve_threshold: float) -> void:
	if not gpu.shaders.has("river_type_assign") or not gpu.shaders["river_type_assign"].is_valid():
		push_warning("[Orchestrator] ⚠️ river_type_assign shader not ready, skipping")
		return

	# === SET 0 : TEXTURES ===
	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: river_flux (R32F) - accumulated flux
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["river_flux"]))

	# Binding 1: water_mask (R8UI)
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures["water_mask"]))

	# Binding 2: river_type_out (R8UI) - output → ocean_reachable (repurposed)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["ocean_reachable"]))

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_type_assign"], 0)

	# === SET 1 : UBO PARAMETERS (32 bytes) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_float(8, affluent_threshold)
	buffer_bytes.encode_float(12, riviere_threshold)
	buffer_bytes.encode_float(16, fleuve_threshold)
	buffer_bytes.encode_float(20, 0.0)  # padding1
	buffer_bytes.encode_float(24, 0.0)  # padding2
	buffer_bytes.encode_float(28, 0.0)  # padding3

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_type_assign"], 1)

	# === DISPATCH ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_type_assign"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de promotion de type le long du chenal principal (ping-pong)
func _dispatch_river_type_promote(w: int, h: int, groups_x: int, groups_y: int, use_swap: bool) -> void:
	if not gpu.shaders.has("river_type_promote") or not gpu.shaders["river_type_promote"].is_valid():
		return

	var input_tex = gpu.textures["ocean_reachable"] if not use_swap else gpu.textures["ocean_reachable_temp"]
	var output_tex = gpu.textures["ocean_reachable_temp"] if not use_swap else gpu.textures["ocean_reachable"]

	# === SET 0 : TEXTURES ===
	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: river_type_in (R8UI) - input ping
	tex_uniforms.append(gpu.create_texture_uniform(0, input_tex))

	# Binding 1: river_type_out (R8UI) - output pong
	tex_uniforms.append(gpu.create_texture_uniform(1, output_tex))

	# Binding 2: river_flux (R32F) - for main channel identification
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["river_flux"]))

	# Binding 3: flow_direction (R8UI)
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["flow_direction"]))

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_type_promote"], 0)

	# === SET 1 : UBO PARAMETERS (16 bytes) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, 0)   # padding1
	buffer_bytes.encode_u32(12, 0)  # padding2

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_type_promote"], 1)

	# === DISPATCH ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_type_promote"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de classification des rivières en biomes (avec connectivité océan)
func _dispatch_river_classify(w: int, h: int, groups_x: int, groups_y: int, atmosphere_type: int) -> void:
	if not gpu.shaders.has("river_classify") or not gpu.shaders["river_classify"].is_valid():
		push_warning("[Orchestrator] ⚠️ river_classify shader not ready, skipping")
		return

	# === SET 0 : TEXTURES ===
	var tex_uniforms: Array[RDUniform] = []

	# Binding 0: river_type (R8UI) - promoted type from ocean_reachable
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["ocean_reachable"]))

	# Binding 1: climate_texture (RGBA32F)
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures["climate"]))

	# Binding 2: river_biome_id (R32UI) - output
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["river_biome_id"]))

	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["river_classify"], 0)

	# === SET 1 : UBO PARAMETERS (16 bytes) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, 0)   # padding1
	buffer_bytes.encode_u32(12, 0)  # padding2

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["river_classify"], 1)

	# === SET 2 : RIVER BIOMES SSBO ===
	var planet_type = atmosphere_type
	var river_biomes_data = Enum.build_river_biomes_gpu_buffer(planet_type, true)  # is_vegetation = true
	var river_ssbo = rd.storage_buffer_create(river_biomes_data.size(), river_biomes_data)

	if not river_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create river biomes SSBO")
		gpu.release_rid(param_set)
		gpu.release_rid(tex_set)
		gpu.release_rid(param_buffer)
		return

	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 0
	ssbo_uniform.add_id(river_ssbo)
	var ssbo_set = rd.uniform_set_create([ssbo_uniform], gpu.shaders["river_classify"], 2)

	# === DISPATCH ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["river_classify"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, ssbo_set, 2)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(ssbo_set)
	gpu.release_rid(river_ssbo)
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

	print("  [Orchestrator] ✅ Rivières classifiées en biomes")

# ============================================================================
# ÉTAPE 4.1 : CLASSIFICATION DES BIOMES
# ============================================================================

## Génère la carte des biomes basée sur température, humidité et élévation.
##
## Cette phase utilise le diagramme de Whittaker avec tables différentes par
## type de planète (Terran, Toxic, Volcanic, NoAtmo, Dead, Sterile).
## 
## Données d'entrée:
## - geo_texture : élévation, water_height
## - climate_texture : température, humidité
## - water_mask : type d'eau (0=terre, 1=salée, 2=douce)
## - river_flux : intensité du flux (pour boost humidité zones humides)
##
## Exclut explicitement : rivières, calottes glaciaires
##
## @param params: Dictionnaire contenant seed, planet_type, sea_level, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_biome_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🌿 Phase 4.1 : Classification des Biomes")
	
	# Vérifier que les shaders sont disponibles
	if not gpu.shaders.has("biome_classify") or not gpu.shaders["biome_classify"].is_valid():
		push_warning("[Orchestrator] ⚠️ biome_classify shader not ready, skipping biome phase")
		return
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("planet_type", 0))
	var cylinder_radius = float(w) / (2.0 * PI)
	var flux_humidity_boost = 0.5  # Boost d'humidité près des flux d'eau
	
	print("  Seed: ", seed_val, " | Type planète: ", atmosphere_type)
	print("  Sea level: ", sea_level, " | Cylinder radius: ", cylinder_radius)
	
	# Initialiser les textures de biome
	gpu.initialize_biome_textures()
	
	# Construire le SSBO des biomes depuis enum.gd (filtrés par type de planète)
	var biomes_buffer_data = Enum.build_biomes_gpu_buffer(atmosphere_type)
	var biomes_ssbo = rd.storage_buffer_create(biomes_buffer_data.size(), biomes_buffer_data)
	
	if not biomes_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create biomes SSBO")
		return
	
	print("  ✅ SSBO biomes créé: ", Enum.get_biome_gpu_count(atmosphere_type), " biomes (type=", atmosphere_type, ")")
	
	# === PASSE 1 : CLASSIFICATION INITIALE ===
	print("  • Classification des biomes...")
	_dispatch_biome_classify(w, h, groups_x, groups_y, seed_val, atmosphere_type, sea_level, cylinder_radius, flux_humidity_boost, biomes_ssbo)
	
	# === PASSES 2-3 : LISSAGE (2 passes ping-pong) ===
	if gpu.shaders.has("biome_smooth") and gpu.shaders["biome_smooth"].is_valid():
		print("  • Lissage des biomes (2 passes)...")
		var border_noise = 0.3  # Force du bruit aux frontières
		
		for pass_idx in range(2):
			_dispatch_biome_smooth(w, h, groups_x, groups_y, seed_val, pass_idx, border_noise, biomes_ssbo)
	else:
		push_warning("[Orchestrator] ⚠️ biome_smooth shader not ready, skipping smoothing")
	
	# Nettoyer le SSBO
	gpu.release_rid(biomes_ssbo)
	
	print("[Orchestrator] ✅ Phase 4.1 terminée")

## Dispatch le shader de classification des biomes
func _dispatch_biome_classify(w: int, h: int, groups_x: int, groups_y: int, 
		seed_val: int, atmosphere_type: int, sea_level: float, 
		cylinder_radius: float, flux_humidity_boost: float, biomes_ssbo: RID) -> void:
	
	# Vérifier les textures nécessaires
	var required_textures = ["geo", "climate", "water_mask", "river_flux", "biome_id", "biome_colored"]
	for tex_id in required_textures:
		if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
			push_error("[Orchestrator] ❌ Missing texture for biome_classify: ", tex_id)
			return
	
	# === SET 0 : TEXTURES ===
	var tex_uniforms: Array[RDUniform] = []
	
	# Binding 0: geo_texture (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	# Binding 1: climate_texture (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures["climate"]))
	# Binding 2: water_mask (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["water_mask"]))
	# Binding 3: river_flux (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["river_flux"]))
	# Binding 4: biome_id (writeonly)
	tex_uniforms.append(gpu.create_texture_uniform(4, gpu.textures["biome_id"]))
	# Binding 5: biome_colored (writeonly)
	tex_uniforms.append(gpu.create_texture_uniform(5, gpu.textures["biome_colored"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["biome_classify"], 0)
	
	# === SET 1 : PARAMÈTRES UBO (32 bytes aligné std140) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)                       # width
	buffer_bytes.encode_u32(4, h)                       # height
	buffer_bytes.encode_u32(8, atmosphere_type)        # atmosphere_type
	buffer_bytes.encode_u32(12, seed_val)              # seed
	buffer_bytes.encode_float(16, sea_level)           # sea_level
	buffer_bytes.encode_float(20, cylinder_radius)     # cylinder_radius
	buffer_bytes.encode_float(24, flux_humidity_boost) # flux_humidity_boost
	buffer_bytes.encode_float(28, 0.0)                 # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["biome_classify"], 1)
	
	# === SET 2 : SSBO BIOMES ===
	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 0
	ssbo_uniform.add_id(biomes_ssbo)
	var ssbo_set = rd.uniform_set_create([ssbo_uniform], gpu.shaders["biome_classify"], 2)
	
	# === DISPATCH ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["biome_classify"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, ssbo_set, 2)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	# Cleanup
	gpu.release_rid(ssbo_set)
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de lissage des biomes (ping-pong)
func _dispatch_biome_smooth(w: int, h: int, groups_x: int, groups_y: int,
		seed_val: int, pass_index: int, border_noise: float, biomes_ssbo: RID) -> void:
	
	# Déterminer les textures source/destination selon le pass
	var src_id_tex: String
	var src_color_tex: String
	var dst_id_tex: String
	var dst_color_tex: String
	
	if pass_index % 2 == 0:
		# Pass pair: biome_id -> biome_id_temp, biome_colored -> biome_colored_temp
		src_id_tex = "biome_id"
		src_color_tex = "biome_colored"
		dst_id_tex = "biome_id_temp"
		dst_color_tex = "biome_colored_temp"
	else:
		# Pass impair: biome_id_temp -> biome_id, biome_colored_temp -> biome_colored
		src_id_tex = "biome_id_temp"
		src_color_tex = "biome_colored_temp"
		dst_id_tex = "biome_id"
		dst_color_tex = "biome_colored"
	
	# Vérifier les textures
	for tex_id in [src_id_tex, src_color_tex, dst_id_tex, dst_color_tex, "water_mask"]:
		if not gpu.textures.has(tex_id) or not gpu.textures[tex_id].is_valid():
			push_error("[Orchestrator] ❌ Missing texture for biome_smooth: ", tex_id)
			return
	
	# === SET 0 : TEXTURES ===
	var tex_uniforms: Array[RDUniform] = []
	
	# Binding 0: biome_id_in (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures[src_id_tex]))
	# Binding 1: biome_colored_in (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(1, gpu.textures[src_color_tex]))
	# Binding 2: biome_id_out (writeonly)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures[dst_id_tex]))
	# Binding 3: biome_colored_out (writeonly)
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures[dst_color_tex]))
	# Binding 4: water_mask (readonly)
	tex_uniforms.append(gpu.create_texture_uniform(4, gpu.textures["water_mask"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["biome_smooth"], 0)
	
	# === SET 1 : PARAMÈTRES UBO (32 bytes aligné std140) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)                   # width
	buffer_bytes.encode_u32(4, h)                   # height
	buffer_bytes.encode_u32(8, pass_index)         # pass_index
	buffer_bytes.encode_u32(12, seed_val)          # seed
	buffer_bytes.encode_float(16, border_noise)    # border_noise
	buffer_bytes.encode_float(20, 0.0)             # padding1
	buffer_bytes.encode_float(24, 0.0)             # padding2
	buffer_bytes.encode_float(28, 0.0)             # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["biome_smooth"], 1)
	
	# === SET 2 : SSBO BIOMES ===
	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 0
	ssbo_uniform.add_id(biomes_ssbo)
	var ssbo_set = rd.uniform_set_create([ssbo_uniform], gpu.shaders["biome_smooth"], 2)
	
	# === DISPATCH ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["biome_smooth"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, ssbo_set, 2)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	# Cleanup
	gpu.release_rid(ssbo_set)
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

# ============================================================================
# ÉTAPE 4 : RÉGIONS ADMINISTRATIVES
# ============================================================================

## Génère les régions administratives sur la terre uniquement.
##
## Cette phase remplace conceptuellement RegionMapGenerator.gd (version CPU).
## Utilise un algorithme de croissance Dijkstra-like avec système de coûts :
## - Terrain plat : coût 1
## - Montée (altitude +) : coût 2  
## - Traversée rivière : coût +3
##
## Les régions ne sont générées que sur la terre (water_mask == 0).
##
## @param params: Dictionnaire contenant seed, nb_cases_regions, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_region_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🗺️ Phase 4 : Régions Administratives")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("planet_type", 0))
	
	# Si pas d'atmosphère, pas de régions (planète sans vie)
	if atmosphere_type == 3:
		print("  ⏭️ Planète sans atmosphère - pas de régions")
		return
	
	# Paramètres de coûts
	var cost_flat = float(params.get("region_cost_flat", 1.0))
	var cost_uphill = float(params.get("region_cost_hill", params.get("region_cost_uphill", 2.0)))
	var cost_river = float(params.get("region_cost_river", 3.0))
	var river_threshold = float(params.get("region_river_threshold", 1.0))
	var budget_variation = float(params.get("region_budget_variation", 0.5))
	var noise_strength = clampf(float(params.get("region_noise_strength", 0.5)), 0.0, 2.0)
	
	# La croissance locale ne saute jamais par-dessus la mer. Le nombre de
	# passes ne définit pas la taille politique : il ne fait qu'assurer la
	# couverture topologique de la projection.
	var max_dim = max(w, h)
	var water_mask_data := gpu.readback_texture_raw("water_mask")
	var geo_data := gpu.readback_texture_raw("geo")
	# Un même prédicat de terre pilote le comptage, les shaders et la
	# normalisation. Un pixel sous le niveau marin ne devient jamais un
	# département si la classification hydrologique est incomplète.
	var land_mask := DepartmentNormalizer.build_land_mask(
		water_mask_data, geo_data, w, h, sea_level
	)
	var actual_land_cells := _count_mask_value(land_mask, 1)
	# "nb_cases_regions" contrôle la surface locale visible d'un département.
	# Il ne doit pas être réinterprété comme un nombre global de graines : avec
	# une valeur de 15, une zone doit couvrir environ 15 cases de terre, quelle
	# que soit la surface totale de la texture. Les niveaux région/pays/continent
	# restent, eux, construits plus tard selon l'échelle physique de la planète.
	var hierarchy_targets := HierarchyBuilder.compute_physical_targets(
		params, false, actual_land_cells
	)
	var target_department_cells := clampf(
		float(params.get("land_department_target_cells",
			params.get("nb_cases_regions", 50.0))),
		1.0,
		float(maxi(actual_land_cells, 1))
	)
	var target_departments := clampi(int(round(
		float(actual_land_cells) / target_department_cells
	)), 1, maxi(actual_land_cells, 1))
	var target_regions := clampi(
		int(hierarchy_targets["regions"]), 1, target_departments
	)
	var desired_seed_density := clampf(
		float(target_departments) / float(maxi(actual_land_cells, 1)),
		0.000001,
		0.105
	)
	# Valeur conservée dans l'UBO pour compatibilité. Le shader place désormais
	# les minima de hash dans un disque dont l'aire suit directement la cible.
	var seed_probability := 1.0 - pow(
		maxf(1.0 - 9.0 * desired_seed_density, 0.000001), 1.0 / 9.0
	)
	var mean_department_spacing_px := sqrt(target_department_cells)
	var seed_neighborhood_radius := clampi(int(round(
		mean_department_spacing_px / sqrt(PI)
	)), 0, 8)
	var minimum_department_ratio := clampf(
		float(params.get("land_department_min_ratio", 0.45)), 0.10, 0.90
	)
	var maximum_department_ratio := maxf(
		float(params.get("land_department_max_ratio", 1.85)),
		minimum_department_ratio + 0.10
	)
	var requested_iterations = int(params.get("region_iterations", max_dim * 2))
	var region_iterations = clampi(requested_iterations, max_dim, max_dim * 2)

	print("  Seed: ", seed_val, " | Cellules terrestres mesurées: ", actual_land_cells)
	print("  Surface terrestre: ", snappedf(float(hierarchy_targets["surface_km2"]), 1.0),
		" km² | taille département cible: ", snappedf(target_department_cells, 0.1),
		" cases | départements cibles: ", target_departments,
		" | régions cibles: ", target_regions)
	print("  Densité blue-noise cible: ", snappedf(desired_seed_density, 0.0001),
		" | rayon local: ", seed_neighborhood_radius,
		" px | espacement moyen: ", snappedf(mean_department_spacing_px, 0.1), " px")
	print("  Irrégularité organique: ", noise_strength,
		" | plage souple: ", snappedf(minimum_department_ratio * 100.0, 0.1),
		"–", snappedf(maximum_department_ratio * 100.0, 0.1),
		" % | passes topologiques: ", region_iterations)
	
	# Initialiser les textures de région
	gpu.initialize_region_textures()
	
	# === PASSE 1 : PLACEMENT DES SEEDS ===
	print("  • Placement des seeds de régions...")
	_dispatch_region_seed_placement(
		w, h, groups_x, groups_y, seed_val, seed_probability, sea_level,
		budget_variation, mean_department_spacing_px
	)
	
	# === PASSE 2 : CROISSANCE LOCALE MASQUÉE ===
	print("  • Croissance organique connexe (", region_iterations, " passes)...")
	for pass_idx in range(region_iterations):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_region_growth(w, h, groups_x, groups_y, 1, seed_val,
			sea_level, river_threshold, cost_flat, cost_uphill, cost_river,
			noise_strength, mean_department_spacing_px, use_swap)
	
	# Si nombre impair de passes, copier le résultat vers la texture principale
	if region_iterations % 2 == 1:
		_copy_region_textures(w, h)
	
	# === PASSE 2.5 : NETTOYAGE FINAL (sécurité pour îles isolées) ===
	print("  • Nettoyage final (sécurité)...")
	# Propagation strictement 4-connexe : aucun saut au-dessus du masque.
	var cleanup_passes = maxi(4, ceili(mean_department_spacing_px))
	for cleanup_pass in range(cleanup_passes):
		var use_swap = ((region_iterations + cleanup_pass) % 2 == 1)
		_dispatch_region_cleanup(
			w, h, groups_x, groups_y, seed_val, sea_level, use_swap
		)
	
	# Si nombre impair de passes totales, copier le résultat
	if (region_iterations + cleanup_passes) % 2 == 1:
		_copy_region_textures(w, h)
	# Une normalisation topologique absorbe les résidus trop petits dans leur
	# meilleur voisin réel. Elle utilise la même couture X et ne fusionne jamais
	# deux masses terrestres séparées par l'eau.
	var normalization := DepartmentNormalizer.normalize(
		gpu.readback_texture_raw("region_map"), land_mask, w, h,
		target_department_cells, minimum_department_ratio,
		maximum_department_ratio
	)
	if not normalization.is_empty():
		var normalized_data: PackedByteArray = normalization["data"]
		rd.texture_update(gpu.textures["region_map"], 0, normalized_data)
		print(
			"  • Normalisation départements : ", normalization["merged_components"],
			" fusion(s), ", normalization["split_fragments"],
			" fragment(s) séparé(s), ", normalization["removed_non_land"],
			" pixel(s) hors terre supprimé(s), ",
			normalization["isolated_undersized"],
			" petite(s) île(s) sans voisin"
		)
	
	# === PASSE 3 : FINALISATION ET COLORATION ===
	print("  • Finalisation et coloration...")
	_dispatch_region_finalize(w, h, groups_x, groups_y, seed_val, sea_level)
	var department_stats := _measure_partition_sizes(
		"region_map", target_department_cells
	)
	for key in normalization.keys():
		if key != "data":
			department_stats["normalization_" + str(key)] = normalization[key]
	last_administrative_stats["land_departments"] = department_stats
	_print_partition_stats("Départements terrestres", last_administrative_stats["land_departments"])
	
	print("[Orchestrator] ✅ Phase 4 : Régions terminées")

func _count_mask_cells(mask_data: PackedByteArray, water: bool) -> int:
	var count := 0
	for value in mask_data:
		if (value != 0) == water:
			count += 1
	return count

func _count_mask_value(mask_data: PackedByteArray, expected: int) -> int:
	var count := 0
	for value in mask_data:
		if value == expected:
			count += 1
	return count

func _measure_partition_sizes(texture_name: String, target_cells: float) -> Dictionary:
	var raw := gpu.readback_texture_raw(texture_name)
	var counts: Dictionary = {}
	for offset in range(0, raw.size(), 4):
		var region_id := raw.decode_u32(offset)
		if region_id == 0xFFFFFFFF:
			continue
		counts[region_id] = int(counts.get(region_id, 0)) + 1
	var sizes: Array[int] = []
	var total_cells := 0
	for size in counts.values():
		var cell_count := int(size)
		sizes.append(cell_count)
		total_cells += cell_count
	sizes.sort()
	if sizes.is_empty():
		return {}
	var outlier_threshold := maxi(int(ceil(target_cells * 4.0)), 1)
	var outlier_count := 0
	for size in sizes:
		if size > outlier_threshold:
			outlier_count += 1
	return {
		"count": sizes.size(),
		"cells": total_cells,
		"target_cells": target_cells,
		"mean": float(total_cells) / float(sizes.size()),
		"minimum": sizes[0],
		"p05": _partition_percentile(sizes, 0.05),
		"p10": _partition_percentile(sizes, 0.10),
		"median": _partition_percentile(sizes, 0.50),
		"p75": _partition_percentile(sizes, 0.75),
		"p90": _partition_percentile(sizes, 0.90),
		"p95": _partition_percentile(sizes, 0.95),
		"p99": _partition_percentile(sizes, 0.99),
		"maximum": sizes[sizes.size() - 1],
		"extreme_outlier_threshold": outlier_threshold,
		"extreme_outliers": outlier_count,
	}

func _partition_percentile(sorted_sizes: Array[int], percentile: float) -> int:
	var index := clampi(
		int(floor(float(sorted_sizes.size() - 1) * percentile)),
		0,
		sorted_sizes.size() - 1
	)
	return sorted_sizes[index]

func _print_partition_stats(label: String, stats: Dictionary) -> void:
	if stats.is_empty():
		print("  ⚠️ ", label, " : aucune zone mesurable")
		return
	print(
		"  ", label, " : n=", stats["count"],
		" | moyenne=", snappedf(float(stats["mean"]), 0.01),
		" | médiane=", stats["median"],
		" | min/max=", stats["minimum"], "/", stats["maximum"],
		" | p90/p95/p99=", stats["p90"], "/", stats["p95"], "/", stats["p99"],
		" | extrêmes >", stats["extreme_outlier_threshold"],
		": ", stats["extreme_outliers"]
	)

## Scinde les fragments rares partageant un même ID en départements autonomes.
## Aucun pixel ne change de masque et aucune fusion n'est effectuée.
func _repair_disconnected_partition(texture_name: String, w: int, h: int) -> int:
	var raw := gpu.readback_texture_raw(texture_name)
	var pixel_count := w * h
	if raw.size() != pixel_count * 4:
		return 0
	var visited := PackedByteArray()
	visited.resize(pixel_count)
	visited.fill(0)
	var completed_ids: Dictionary = {}
	var used_ids: Dictionary = {}
	for offset in range(0, raw.size(), 4):
		var value := raw.decode_u32(offset)
		if value != 0xFFFFFFFF:
			used_ids[value] = true
	var next_id := pixel_count
	var split_count := 0

	for start in range(pixel_count):
		if visited[start] != 0:
			continue
		var region_id := raw.decode_u32(start * 4)
		if region_id == 0xFFFFFFFF:
			visited[start] = 1
			continue
		var component: Array[int] = [start]
		visited[start] = 1
		var head := 0
		while head < component.size():
			var current := component[head]
			head += 1
			var x := current % w
			var y := int(current / w)
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx := posmod(x + offset.x, w)
				var ny := clampi(y + offset.y, 0, h - 1)
				var neighbor := ny * w + nx
				if visited[neighbor] == 0 and raw.decode_u32(neighbor * 4) == region_id:
					visited[neighbor] = 1
					component.append(neighbor)
		if completed_ids.has(region_id):
			while used_ids.has(next_id):
				next_id += 1
			for pixel in component:
				raw.encode_u32(pixel * 4, next_id)
			used_ids[next_id] = true
			next_id += 1
			split_count += 1
		else:
			completed_ids[region_id] = true

	if split_count > 0:
		rd.texture_update(gpu.textures[texture_name], 0, raw)
		print("  • Continuité ", texture_name, " : ", split_count,
			" fragment(s) conservé(s) sous un ID autonome")
	return split_count

## Dispatch le shader de placement des seeds de région
func _dispatch_region_seed_placement(w: int, h: int, groups_x: int,
		groups_y: int, seed_val: int, seed_probability: float,
		sea_level: float, budget_variation: float,
		mean_spacing_px: float) -> void:
	if not gpu.shaders.has("region_seed_placement") or not gpu.shaders["region_seed_placement"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_seed_placement shader non disponible")
		return
	
	# Créer les uniforms de texture (set 0)
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# region_map (R32UI)
	var map_uniform = RDUniform.new()
	map_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_uniform.binding = 2
	map_uniform.add_id(gpu.textures["region_map"])
	tex_uniforms.append(map_uniform)
	
	# region_cost (R32F)
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["region_cost"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["region_seed_placement"], 0)
	
	# UBO paramètres (32 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_float(12, seed_probability)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, budget_variation)
	buffer_bytes.encode_float(24, mean_spacing_px)
	buffer_bytes.encode_float(28, 0.0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["region_seed_placement"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_seed_placement"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de croissance des régions (Dijkstra-like)
func _dispatch_region_growth(w: int, h: int, groups_x: int, groups_y: int,
		pass_idx: int, seed_val: int, sea_level: float, river_threshold: float,
		cost_flat: float, cost_uphill: float, cost_river: float,
		noise_strength: float, mean_spacing_px: float, use_swap: bool) -> void:
	if not gpu.shaders.has("region_growth") or not gpu.shaders["region_growth"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_growth shader non disponible")
		return
	
	# Textures ping-pong (comme pour les régions océaniques)
	var map_in: RID = gpu.textures["region_map"] if not use_swap else gpu.textures["region_map_temp"]
	var map_out: RID = gpu.textures["region_map_temp"] if not use_swap else gpu.textures["region_map"]
	var cost_in: RID = gpu.textures["region_cost"] if not use_swap else gpu.textures["region_cost_temp"]
	var cost_out: RID = gpu.textures["region_cost_temp"] if not use_swap else gpu.textures["region_cost"]
	
	# Créer les uniforms de texture (set 0)
	var tex_uniforms: Array[RDUniform] = []
	
	# geo_texture (binding 0)
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	# water_mask (binding 1)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# river_flux (binding 2)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["river_flux"]))
	
	# region_map_in (binding 3) - lecture
	var map_in_uniform = RDUniform.new()
	map_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_in_uniform.binding = 3
	map_in_uniform.add_id(map_in)
	tex_uniforms.append(map_in_uniform)
	
	# region_cost_in (binding 4) - lecture
	tex_uniforms.append(gpu.create_texture_uniform(4, cost_in))
	
	# region_map_out (binding 5) - écriture
	var map_out_uniform = RDUniform.new()
	map_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_out_uniform.binding = 5
	map_out_uniform.add_id(map_out)  # Ping-pong correct pour éviter les race conditions
	tex_uniforms.append(map_out_uniform)
	
	# region_cost_out (binding 6) - écriture
	tex_uniforms.append(gpu.create_texture_uniform(6, cost_out))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["region_growth"], 0)
	
	# UBO paramètres (48 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_idx)
	buffer_bytes.encode_u32(12, seed_val)  # seed pour le bruit
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, river_threshold)
	buffer_bytes.encode_float(24, cost_flat)
	buffer_bytes.encode_float(28, cost_uphill)
	buffer_bytes.encode_float(32, cost_river)
	buffer_bytes.encode_float(36, noise_strength)  # Force du bruit
	buffer_bytes.encode_float(40, mean_spacing_px)
	buffer_bytes.encode_float(44, 0.0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["region_growth"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_growth"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Copie les textures de région du buffer temp vers le buffer principal
func _copy_region_textures(w: int, h: int) -> void:
	# Copier region_map_temp -> region_map
	_copy_texture(gpu.textures["region_map_temp"], gpu.textures["region_map"], w, h)
	# Copier region_cost_temp -> region_cost
	_copy_texture(gpu.textures["region_cost_temp"], gpu.textures["region_cost"], w, h)

## Dispatch le shader de nettoyage final des régions (assigne toute terre restante)
func _dispatch_region_cleanup(w: int, h: int, groups_x: int,
		groups_y: int, seed_val: int, sea_level: float,
		use_swap: bool) -> void:
	if not gpu.shaders.has("region_cleanup") or not gpu.shaders["region_cleanup"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_cleanup shader non disponible")
		return
	
	# Choisir les textures source/destination selon le ping-pong
	var src_map: RID = gpu.textures["region_map"] if not use_swap else gpu.textures["region_map_temp"]
	var dst_map: RID = gpu.textures["region_map_temp"] if not use_swap else gpu.textures["region_map"]
	var dst_cost: RID = gpu.textures["region_cost_temp"] if not use_swap else gpu.textures["region_cost"]
	
	# Créer les uniforms de texture (set 0)
	var tex_uniforms: Array[RDUniform] = []
	
	# water_mask (R8UI)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 0
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# region_map_in (R32UI)
	var map_in_uniform = RDUniform.new()
	map_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_in_uniform.binding = 1
	map_in_uniform.add_id(src_map)
	tex_uniforms.append(map_in_uniform)
	
	# region_map_out (R32UI)
	var map_out_uniform = RDUniform.new()
	map_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_out_uniform.binding = 2
	map_out_uniform.add_id(dst_map)
	tex_uniforms.append(map_out_uniform)
	
	# region_cost_out (R32F)
	tex_uniforms.append(gpu.create_texture_uniform(3, dst_cost))

	# geo_texture (RGBA32F) : même prédicat de terre que seed/growth
	tex_uniforms.append(gpu.create_texture_uniform(4, gpu.textures["geo"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["region_cleanup"], 0)
	
	# UBO paramètres (16 bytes, std140)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_float(12, sea_level)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["region_cleanup"], 1)
	
	# Dispatch
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_cleanup"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de finalisation des régions (coloration)
func _dispatch_region_finalize(w: int, h: int, groups_x: int,
		groups_y: int, seed_val: int, sea_level: float) -> void:
	if not gpu.shaders.has("region_finalize") or not gpu.shaders["region_finalize"].is_valid():
		push_warning("[Orchestrator] ⚠️ region_finalize shader non disponible")
		return
	
	# Créer les uniforms de texture (set 0)
	var tex_uniforms: Array[RDUniform] = []
	
	# region_map (binding 0)
	var map_uniform = RDUniform.new()
	map_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_uniform.binding = 0
	map_uniform.add_id(gpu.textures["region_map"])
	tex_uniforms.append(map_uniform)
	
	# water_mask (binding 1)
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	# region_colored (binding 2)
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["region_colored"]))

	# geo_texture (binding 3) : protège aussi l'aperçu GPU contre un masque
	# hydrologique incomplet.
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["geo"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["region_finalize"], 0)
	
	# UBO paramètres (32 bytes, std140)
	# Couleur eau legacy : 0x161a1f = RGB(22, 26, 31)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_u32(12, 22)   # water_color_r
	buffer_bytes.encode_u32(16, 26)   # water_color_g
	buffer_bytes.encode_u32(20, 31)   # water_color_b
	buffer_bytes.encode_float(24, sea_level)
	buffer_bytes.encode_float(28, 0.0)  # padding
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["region_finalize"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["region_finalize"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

# ============================================================================
# ÉTAPE 4.5 : RÉGIONS OCÉANIQUES
# ============================================================================

## Exécute la phase de génération des régions océaniques (step 4.5)
## @param params: Dictionnaire contenant seed, nb_cases_ocean_regions, etc.
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_ocean_region_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🌊 Phase 4.5 : Régions Océaniques")
	
	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)
	
	var seed_val = int(params.get("seed", 12345))
	var sea_level = float(params.get("sea_level", 0.0))
	var ocean_ratio = clampf(float(params.get("ocean_ratio", 55.0)), 5.0, 100.0)
	
	# Paramètres de coûts pour océans
	var cost_flat = float(params.get("ocean_cost_flat", 1.0))
	var cost_deeper = float(params.get("ocean_cost_deeper", 2.0))
	var noise_strength = float(params.get("ocean_noise_strength", 0.5))  # Réduit pour ne pas dominer les coûts
	
	var expected_water_pixels = maxf(float(w * h) * ocean_ratio / 100.0, 1.0)
	var physical_targets := HierarchyBuilder.compute_physical_targets(
		params, true, int(round(expected_water_pixels))
	)
	var target_ocean_regions = int(physical_targets["regions"])
	var target_departments = int(physical_targets["departments"])
	var seed_probability = clampf(float(target_departments) / expected_water_pixels, 0.000001, 0.02)
	var mean_department_spacing_px = sqrt(expected_water_pixels / float(maxi(target_departments, 1)))
	var max_dim = max(w, h)
	var requested_iterations = int(params.get("ocean_iterations", max_dim * 2))
	var ocean_iterations = clampi(requested_iterations, max_dim, max_dim * 2)
	
	print("  Seed: ", seed_val, " | Régions maritimes cibles: ", target_ocean_regions,
		" | Départements cibles: ", target_departments)
	print("  Surface maritime: ", snappedf(float(physical_targets["surface_km2"]), 1.0),
		" km² | espacement moyen: ", snappedf(mean_department_spacing_px, 0.1), " px")
	print("  Coûts - Plat: ", cost_flat, " | Profondeur: ", cost_deeper)
	print("  Bruit frontières: ", noise_strength)
	print("  Itérations de croissance: ", ocean_iterations)
	
	# Initialiser les textures océaniques
	gpu.initialize_ocean_region_textures()
	
	# === PASSE 1 : PLACEMENT DES SEEDS ===
	print("  • Placement des seeds de régions océaniques...")
	_dispatch_ocean_region_seed_placement(w, h, groups_x, groups_y, seed_val,
		target_ocean_regions, sea_level, seed_probability)
	
	# === PASSE 2 : CROISSANCE ITÉRATIVE ===
	print("  • Croissance des régions océaniques (", ocean_iterations, " passes)...")
	for pass_idx in range(ocean_iterations):
		var use_swap = (pass_idx % 2 == 1)
		_dispatch_ocean_region_growth(w, h, groups_x, groups_y, pass_idx,
			seed_val, sea_level, cost_flat, cost_deeper, noise_strength,
			mean_department_spacing_px, use_swap)
	
	if ocean_iterations % 2 == 1:
		_copy_ocean_region_textures(w, h)
	
	# === PASSE 2.5 : NETTOYAGE FINAL ===
	print("  • Nettoyage final (couverture complète)...")
	# Le nettoyage reste local afin de préserver les composantes maritimes.
	var cleanup_passes = maxi(4, ceili(mean_department_spacing_px))
	for cleanup_pass in range(cleanup_passes):
		var use_swap = ((ocean_iterations + cleanup_pass) % 2 == 1)
		_dispatch_ocean_region_cleanup(w, h, groups_x, groups_y, seed_val, use_swap)
	
	if (ocean_iterations + cleanup_passes) % 2 == 1:
		_copy_ocean_region_textures(w, h)
	_repair_disconnected_partition("ocean_region_map", w, h)
	
	# === PASSE 3 : FINALISATION ET COLORATION ===
	print("  • Finalisation et coloration...")
	_dispatch_ocean_region_finalize(w, h, groups_x, groups_y, seed_val)
	
	print("[Orchestrator] ✅ Phase 4.5 : Régions océaniques terminées")

## Dispatch le shader de placement des seeds de région océanique
func _dispatch_ocean_region_seed_placement(w: int, h: int, groups_x: int,
		groups_y: int, seed_val: int, nb_cases_region: int, sea_level: float,
		seed_probability: float) -> void:
	if not gpu.shaders.has("ocean_region_seed_placement") or not gpu.shaders["ocean_region_seed_placement"].is_valid():
		push_warning("[Orchestrator] ⚠️ ocean_region_seed_placement shader non disponible")
		return
	
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	var map_uniform = RDUniform.new()
	map_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_uniform.binding = 2
	map_uniform.add_id(gpu.textures["ocean_region_map"])
	tex_uniforms.append(map_uniform)
	
	tex_uniforms.append(gpu.create_texture_uniform(3, gpu.textures["ocean_region_cost"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["ocean_region_seed_placement"], 0)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_float(12, sea_level)
	buffer_bytes.encode_float(16, seed_probability)
	buffer_bytes.encode_float(20, 0.25)
	buffer_bytes.encode_u32(24, nb_cases_region)
	buffer_bytes.encode_u32(28, 0)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["ocean_region_seed_placement"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ocean_region_seed_placement"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de croissance des régions océaniques
func _dispatch_ocean_region_growth(w: int, h: int, groups_x: int,
		groups_y: int, pass_idx: int, seed_val: int, sea_level: float,
		cost_flat: float, cost_deeper: float, noise_strength: float,
		mean_spacing_px: float, use_swap: bool) -> void:
	if not gpu.shaders.has("ocean_region_growth") or not gpu.shaders["ocean_region_growth"].is_valid():
		push_warning("[Orchestrator] ⚠️ ocean_region_growth shader non disponible")
		return
	
	var src_map: RID = gpu.textures["ocean_region_map"] if not use_swap else gpu.textures["ocean_region_map_temp"]
	var src_cost: RID = gpu.textures["ocean_region_cost"] if not use_swap else gpu.textures["ocean_region_cost_temp"]
	var dst_map: RID = gpu.textures["ocean_region_map_temp"] if not use_swap else gpu.textures["ocean_region_map"]
	var dst_cost: RID = gpu.textures["ocean_region_cost_temp"] if not use_swap else gpu.textures["ocean_region_cost"]
	
	var tex_uniforms: Array[RDUniform] = []
	tex_uniforms.append(gpu.create_texture_uniform(0, gpu.textures["geo"]))
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	var map_in_uniform = RDUniform.new()
	map_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_in_uniform.binding = 2
	map_in_uniform.add_id(src_map)
	tex_uniforms.append(map_in_uniform)
	
	tex_uniforms.append(gpu.create_texture_uniform(3, src_cost))
	
	var map_out_uniform = RDUniform.new()
	map_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_out_uniform.binding = 4
	map_out_uniform.add_id(dst_map)
	tex_uniforms.append(map_out_uniform)
	
	tex_uniforms.append(gpu.create_texture_uniform(5, dst_cost))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["ocean_region_growth"], 0)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, pass_idx)
	buffer_bytes.encode_u32(12, seed_val)
	buffer_bytes.encode_float(16, sea_level)
	buffer_bytes.encode_float(20, cost_flat)
	buffer_bytes.encode_float(24, cost_deeper)
	buffer_bytes.encode_float(28, noise_strength)
	buffer_bytes.encode_float(32, mean_spacing_px)
	buffer_bytes.encode_float(36, 0.0)
	buffer_bytes.encode_float(40, 0.0)
	buffer_bytes.encode_float(44, 0.0)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["ocean_region_growth"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ocean_region_growth"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Copie les textures océaniques du buffer temp vers le buffer principal
func _copy_ocean_region_textures(w: int, h: int) -> void:
	_copy_texture(gpu.textures["ocean_region_map_temp"], gpu.textures["ocean_region_map"], w, h)
	_copy_texture(gpu.textures["ocean_region_cost_temp"], gpu.textures["ocean_region_cost"], w, h)

## Dispatch le shader de nettoyage des régions océaniques
func _dispatch_ocean_region_cleanup(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, use_swap: bool) -> void:
	if not gpu.shaders.has("ocean_region_cleanup") or not gpu.shaders["ocean_region_cleanup"].is_valid():
		push_warning("[Orchestrator] ⚠️ ocean_region_cleanup shader non disponible")
		return
	
	var src_map: RID = gpu.textures["ocean_region_map"] if not use_swap else gpu.textures["ocean_region_map_temp"]
	var dst_map: RID = gpu.textures["ocean_region_map_temp"] if not use_swap else gpu.textures["ocean_region_map"]
	var dst_cost: RID = gpu.textures["ocean_region_cost_temp"] if not use_swap else gpu.textures["ocean_region_cost"]
	
	var tex_uniforms: Array[RDUniform] = []
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 0
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	var map_in_uniform = RDUniform.new()
	map_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_in_uniform.binding = 1
	map_in_uniform.add_id(src_map)
	tex_uniforms.append(map_in_uniform)
	
	var map_out_uniform = RDUniform.new()
	map_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_out_uniform.binding = 2
	map_out_uniform.add_id(dst_map)
	tex_uniforms.append(map_out_uniform)
	
	tex_uniforms.append(gpu.create_texture_uniform(3, dst_cost))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["ocean_region_cleanup"], 0)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(16)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_u32(12, 0)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["ocean_region_cleanup"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ocean_region_cleanup"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Dispatch le shader de finalisation des régions océaniques (coloration)
func _dispatch_ocean_region_finalize(w: int, h: int, groups_x: int, groups_y: int, seed_val: int) -> void:
	if not gpu.shaders.has("ocean_region_finalize") or not gpu.shaders["ocean_region_finalize"].is_valid():
		push_warning("[Orchestrator] ⚠️ ocean_region_finalize shader non disponible")
		return
	
	var tex_uniforms: Array[RDUniform] = []
	
	var map_uniform = RDUniform.new()
	map_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	map_uniform.binding = 0
	map_uniform.add_id(gpu.textures["ocean_region_map"])
	tex_uniforms.append(map_uniform)
	
	var mask_uniform = RDUniform.new()
	mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	mask_uniform.binding = 1
	mask_uniform.add_id(gpu.textures["water_mask"])
	tex_uniforms.append(mask_uniform)
	
	tex_uniforms.append(gpu.create_texture_uniform(2, gpu.textures["ocean_region_colored"]))
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["ocean_region_finalize"], 0)
	
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_u32(12, 42)   # land_color_r (gris)
	buffer_bytes.encode_u32(16, 42)   # land_color_g
	buffer_bytes.encode_u32(20, 42)   # land_color_b
	buffer_bytes.encode_float(24, 0.0)
	buffer_bytes.encode_float(28, 0.0)
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["ocean_region_finalize"], 1)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["ocean_region_finalize"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

# ============================================================================
# ÉTAPE 5 : RESSOURCES & PÉTROLE
# ============================================================================

## Génère les cartes de ressources et de pétrole.
##
## Cette phase exécute :
## 1. Petrole : Gisements pétroliers basés sur géologie (bassins sédimentaires)
## 2. Resources : Tous les autres minéraux avec distribution par probabilité
##
# ============================================================================
# ÉTAPE 4.1 : BIOMES
# ============================================================================

# ============================================================================
# ÉTAPE 5 : RESSOURCES & PÉTROLE
# ============================================================================

## Génère les cartes de pétrole et de ressources minérales.
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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["petrole"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["petrole_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

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
		gpu.release_rid(param_buffer)
		return
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["resources"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["resources_textures"], 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	gpu.submit_gpu_work()
	
	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)

# ============================================================================
# ÉTAPE 6 BIS : FINAL MAP GAZEUSE (TYPE 6)
# ============================================================================

## Exécute le pipeline complet de génération d'une planète gazeuse :
## 1. Calcul du champ de vélocité (jets zonaux + tourbillons curl-noise)
## 2. Initialisation du colorant (bandes de couleur)
## 3. Advection semi-lagrangienne du colorant sur N itérations (ping-pong)
## 4. Composition finale (climat + tempêtes + assombrissement polaire)
func run_gas_giant_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🪐 Pipeline gazeuse multi-passes (advection fluide)")

	if not rd:
		push_warning("[Orchestrator] ⚠️ RD non disponible, pipeline gazeuse ignoré")
		return

	gpu.initialize_gas_giant_textures()
	gpu.initialize_final_map_textures()

	var groups_x = ceili(float(w) / 16.0)
	var groups_y = ceili(float(h) / 16.0)

	var seed_val = int(params.get("seed", 12345))
	var cylinder_radius = float(w) / (2.0 * PI)
	var avg_temperature = float(params.get("avg_temperature", 15.0))
	var num_bands = clampi(int(params.get("gas_giant_num_bands", 12)), 6, 24)
	var jet_strength = float(params.get("gas_giant_jet_strength", 4.0))
	var eddy_strength = float(params.get("gas_giant_eddy_strength", 2.5))
	var advection_dt = float(params.get("gas_giant_advection_dt", 1.4))

	# --- Iteration count: scale with resolution -----------------------------
	# Displacement per iteration is roughly constant in PIXELS (velocity/dt
	# are resolution-independent by design), so the fraction of the
	# circumference actually mixed per iteration shrinks as resolution
	# grows. Compensate with more, smaller, accurate steps at higher
	# resolution -- same principle as river_propagation's max(w,h)-scaled loop.
	var base_iterations = int(params.get("gas_giant_advection_iterations", 40))
	var reference_width = float(params.get("gas_giant_reference_width", 1024.0))
	var resolution_scale = max(float(w) / reference_width, 1.0)
	var advection_iterations = int(round(float(base_iterations) * resolution_scale))
	advection_iterations = clampi(advection_iterations, base_iterations, base_iterations * 8)

	# --- Sharpen: keep TOTAL compounded contrast fixed, not per-step -------
	# La correction agit maintenant sur la saturation autour de la luminance,
	# pas sur chaque canal autour de 0.5. Une correction totale faible conserve
	# les filaments sans pousser les bandes claires vers le blanc pur ni les
	# bandes sombres vers le noir.
	var target_total_sharpen = clampf(float(params.get("gas_giant_target_sharpen", 1.18)), 1.0, 1.5)
	var advection_sharpen = pow(target_total_sharpen, 1.0 / float(advection_iterations))

	# === PASSE 1 : CHAMP DE VÉLOCITÉ (calculé une seule fois) ===
	_dispatch_gas_giant_velocity_init(w, h, groups_x, groups_y, seed_val, cylinder_radius, num_bands, jet_strength, eddy_strength)

	# === PASSE 2 : INITIALISATION DU COLORANT ===
	_dispatch_gas_giant_dye_init(w, h, groups_x, groups_y, seed_val, cylinder_radius, avg_temperature, num_bands)

	# === PASSE 3 : ADVECTION (ping-pong dye_a <-> dye_b) ===
	print("  • Advection du colorant (", advection_iterations, " passes, sharpen/step=", advection_sharpen, ")...")
	var advection_completed := _dispatch_gas_giant_advection(
		w,
		h,
		groups_x,
		groups_y,
		advection_iterations,
		advection_dt,
		advection_sharpen,
	)

	# The final composition can consume either side of the ping-pong pair,
	# avoiding another GPU submission just to copy an odd final pass.
	var final_dye_texture: RID = gpu.textures["gas_dye_a"]
	if advection_completed and advection_iterations % 2 == 1:
		final_dye_texture = gpu.textures["gas_dye_b"]

	# === PASSE 4 : COMPOSITION FINALE ===
	_dispatch_gas_giant_final(w, h, groups_x, groups_y, seed_val, cylinder_radius, avg_temperature, final_dye_texture)

	print("[Orchestrator] ✅ Pipeline gazeuse terminée")

func _dispatch_gas_giant_velocity_init(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, cylinder_radius: float, num_bands: int, jet_strength: float, eddy_strength: float) -> void:
	if not gpu.shaders.has("gas_giant_velocity_init") or not gpu.shaders["gas_giant_velocity_init"].is_valid():
		push_warning("[Orchestrator] ⚠️ gas_giant_velocity_init shader non disponible")
		return

	var tex_uniforms: Array[RDUniform] = [
		gpu.create_texture_uniform(0, gpu.textures["gas_velocity"]),
	]
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["gas_giant_velocity_init"], 0)

	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_float(12, cylinder_radius)
	buffer_bytes.encode_u32(16, num_bands)
	buffer_bytes.encode_float(20, jet_strength)
	buffer_bytes.encode_float(24, eddy_strength)
	buffer_bytes.encode_float(28, 0.0)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["gas_giant_velocity_init"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["gas_giant_velocity_init"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)


func _dispatch_gas_giant_dye_init(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, cylinder_radius: float, avg_temperature: float, num_bands: int) -> void:
	if not gpu.shaders.has("gas_giant_dye_init") or not gpu.shaders["gas_giant_dye_init"].is_valid():
		push_warning("[Orchestrator] ⚠️ gas_giant_dye_init shader non disponible")
		return

	var tex_uniforms: Array[RDUniform] = [
		gpu.create_texture_uniform(0, gpu.textures["gas_dye_a"]),
	]
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["gas_giant_dye_init"], 0)

	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, seed_val)
	buffer_bytes.encode_u32(4, w)
	buffer_bytes.encode_u32(8, h)
	buffer_bytes.encode_u32(12, num_bands)
	buffer_bytes.encode_float(16, cylinder_radius)
	buffer_bytes.encode_float(20, avg_temperature)
	buffer_bytes.encode_float(24, 0.0)
	buffer_bytes.encode_float(28, 0.0)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["gas_giant_dye_init"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["gas_giant_dye_init"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)


func _dispatch_gas_giant_advection(w: int, h: int, groups_x: int, groups_y: int, iterations: int, dt: float, sharpen: float) -> bool:
	if not gpu.shaders.has("gas_giant_advect") or not gpu.shaders["gas_giant_advect"].is_valid():
		push_warning("[Orchestrator] ⚠️ gas_giant_advect shader non disponible")
		return false
	if iterations <= 0:
		return true

	# Parameters must remain distinct because all commands are submitted
	# together. Texture bindings only have two ping-pong configurations.
	# Keep every RID alive until the single GPU sync below.
	var texture_sets: Array[RID] = []
	var param_buffers: Array[RID] = []
	var param_sets: Array[RID] = []

	for swap_index in range(mini(iterations, 2)):
		var use_swap := swap_index == 1
		var input_tex: RID = gpu.textures["gas_dye_b"] if use_swap else gpu.textures["gas_dye_a"]
		var output_tex: RID = gpu.textures["gas_dye_a"] if use_swap else gpu.textures["gas_dye_b"]

		var tex_uniforms: Array[RDUniform] = [
			gpu.create_texture_uniform(0, gpu.textures["gas_velocity"]),
			gpu.create_texture_uniform(1, input_tex),
			gpu.create_texture_uniform(2, output_tex),
		]
		var tex_set := rd.uniform_set_create(tex_uniforms, gpu.shaders["gas_giant_advect"], 0)
		if not tex_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create gas advection texture set")
			_free_rid_array(param_sets)
			_free_rid_array(param_buffers)
			_free_rid_array(texture_sets)
			return false
		texture_sets.append(tex_set)

	for pass_index in range(iterations):
		var buffer_bytes := PackedByteArray()
		buffer_bytes.resize(32)
		buffer_bytes.encode_u32(0, w)
		buffer_bytes.encode_u32(4, h)
		buffer_bytes.encode_u32(8, pass_index)
		buffer_bytes.encode_float(12, dt)
		buffer_bytes.encode_float(16, sharpen)
		buffer_bytes.encode_float(20, 0.0)
		buffer_bytes.encode_float(24, 0.0)
		buffer_bytes.encode_float(28, 0.0)

		var param_buffer := rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
		if not param_buffer.is_valid():
			push_error("[Orchestrator] ❌ Failed to create gas advection parameter buffer")
			_free_rid_array(param_sets)
			_free_rid_array(param_buffers)
			_free_rid_array(texture_sets)
			return false
		param_buffers.append(param_buffer)

		var param_uniform := RDUniform.new()
		param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		param_uniform.binding = 0
		param_uniform.add_id(param_buffer)
		var param_set := rd.uniform_set_create([param_uniform], gpu.shaders["gas_giant_advect"], 1)
		if not param_set.is_valid():
			push_error("[Orchestrator] ❌ Failed to create gas advection parameter set")
			_free_rid_array(param_sets)
			_free_rid_array(param_buffers)
			_free_rid_array(texture_sets)
			return false
		param_sets.append(param_set)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["gas_giant_advect"])
	for pass_index in range(iterations):
		rd.compute_list_bind_uniform_set(compute_list, texture_sets[pass_index % 2], 0)
		rd.compute_list_bind_uniform_set(compute_list, param_sets[pass_index], 1)
		rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		if pass_index + 1 < iterations:
			rd.compute_list_add_barrier(compute_list)
	rd.compute_list_end()

	# One submit/sync replaces the previous CPU/GPU round-trip per iteration.
	gpu.submit_gpu_work()

	_free_rid_array(param_sets)
	_free_rid_array(param_buffers)
	_free_rid_array(texture_sets)
	return true


func _dispatch_gas_giant_final(w: int, h: int, groups_x: int, groups_y: int, seed_val: int, cylinder_radius: float, avg_temperature: float, dye_texture: RID) -> void:
	if not gpu.shaders.has("gas_giant_final") or not gpu.shaders["gas_giant_final"].is_valid():
		push_warning("[Orchestrator] ⚠️ gas_giant_final shader non disponible")
		return

	var tex_uniforms: Array[RDUniform] = [
		gpu.create_texture_uniform(0, dye_texture),
		gpu.create_texture_uniform(1, gpu.textures["gas_velocity"]),
		gpu.create_texture_uniform(2, gpu.textures["climate"]),
		gpu.create_texture_uniform(3, gpu.textures["final_map"]),
	]
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["gas_giant_final"], 0)

	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	buffer_bytes.encode_u32(0, w)
	buffer_bytes.encode_u32(4, h)
	buffer_bytes.encode_u32(8, seed_val)
	buffer_bytes.encode_float(12, cylinder_radius)
	buffer_bytes.encode_float(16, avg_temperature)
	buffer_bytes.encode_float(20, 0.0)
	buffer_bytes.encode_float(24, 0.0)
	buffer_bytes.encode_float(28, 0.0)

	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["gas_giant_final"], 1)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["gas_giant_final"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	gpu.submit_gpu_work()

	gpu.release_rid(param_set)
	gpu.release_rid(param_buffer)
	gpu.release_rid(tex_set)

## Génère la carte finale pour une planète gazeuse.
##
## Utilise le shader gas_giant_final qui lit climate_texture (R=temp, G=humidity)
## et produit une apparence de géante gazeuse avec bandes horizontales et tourbillons.
##
## @param params: Dictionnaire contenant les paramètres de génération
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_gas_giant_final_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🪐 Phase 6 : Génération Final Map (Gazeuse)")
	
	if not rd or not gpu.pipelines.has("gas_giant_final") or not gpu.pipelines["gas_giant_final"].is_valid():
		push_warning("[Orchestrator] ⚠️ gas_giant_final pipeline not ready, skipping")
		return
	
	# Initialiser la texture final_map (RGBA8)
	gpu.initialize_final_map_textures()
	
	var groups_x = int(ceil(float(w) / 16.0))
	var groups_y = int(ceil(float(h) / 16.0))
	
	var seed_val = int(params.get("seed", 12345))
	var avg_temperature = float(params.get("avg_temperature", 15.0))
	var cylinder_radius = float(w) / (2.0 * PI)
	
	# === UBO (32 bytes, std140) ===
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(32)
	
	buffer_bytes.encode_u32(0, w)                      # width
	buffer_bytes.encode_u32(4, h)                      # height
	buffer_bytes.encode_u32(8, seed_val)               # seed
	buffer_bytes.encode_float(12, cylinder_radius)     # cylinder_radius
	buffer_bytes.encode_float(16, avg_temperature)     # avg_temperature
	buffer_bytes.encode_float(20, 0.0)                 # padding1
	buffer_bytes.encode_float(24, 0.0)                 # padding2
	buffer_bytes.encode_float(28, 0.0)                 # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create gas_giant_final param buffer")
		return
	
	# === SET 0 : Textures (climate_texture + final_map) ===
	var tex_uniforms: Array[RDUniform] = []
	
	# Binding 0: climate_texture (RGBA32F, lecture)
	var u_climate = RDUniform.new()
	u_climate.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_climate.binding = 0
	u_climate.add_id(gpu.textures["climate"])
	tex_uniforms.append(u_climate)
	
	# Binding 1: final_map (RGBA8, écriture)
	var u_final = RDUniform.new()
	u_final.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_final.binding = 1
	u_final.add_id(gpu.textures["final_map"])
	tex_uniforms.append(u_final)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["gas_giant_final"], 0)
	if not tex_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create gas_giant_final textures uniform set")
		gpu.release_rid(param_buffer)
		return
	
	# === SET 1 : Parameters UBO ===
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["gas_giant_final"], 1)
	if not param_set.is_valid():
		push_error("[Orchestrator] ❌ Failed to create gas_giant_final param set")
		gpu.release_rid(tex_set)
		gpu.release_rid(param_buffer)
		return
	
	# === Dispatch ===
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["gas_giant_final"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	
	# Nettoyer
	gpu.release_rid(param_set)
	gpu.release_rid(tex_set)
	gpu.release_rid(param_buffer)
	
	print("[Orchestrator] ✅ Carte finale gazeuse générée")

# ============================================================================
# ÉTAPE 6 : FINAL MAP (COMBINAISON)
# ============================================================================

## Génère la carte finale combinée et la carte colorée des eaux.
##
## Cette phase exécute :
## 1. Water to Color : Coloration des masses d'eau (eau salée/douce)
## 2. Final Map : Combinaison biome + rivières + relief + banquise
##
## @param params: Dictionnaire contenant les paramètres de génération
## @param w: Largeur de la texture
## @param h: Hauteur de la texture
func run_final_map_phase(params: Dictionary, w: int, h: int) -> void:
	print("[Orchestrator] 🎨 Phase 6 : Génération Final Map")
	
	# Initialiser les textures de final map
	gpu.initialize_final_map_textures()
	
	# === ÉTAPE 6.1 : WATER TO COLOR ===
	_run_water_to_color_phase(params, w, h)
	
	# === ÉTAPE 6.2 : FINAL MAP ===
	_run_final_map_shader(params, w, h)
	
	print("[Orchestrator] ✅ Phase 6 terminée")

## Exécute le shader de coloration des eaux
func _run_water_to_color_phase(params: Dictionary, w: int, h: int) -> void:
	# HydrologySolver a deja produit water_mask et water_colored avec la
	# classification exacte des composantes (0=terre, 1=mer, 2=eau douce).
	# Rejouer ici l'ancien shader de classification utilisait des labels JFA
	# obsoletes et pouvait convertir toute la mer en eau douce juste avant
	# l'export. La carte finale doit seulement reutiliser ce resultat.
	if not last_hydrology_stats.is_empty():
		print("  [Orchestrator] 💧 Classification des eaux conservée (hydrologie exacte)")
		return
	if not rd or not gpu.pipelines.has("water_to_color") or not gpu.pipelines["water_to_color"].is_valid():
		push_warning("[Orchestrator] ⚠️ water_to_color pipeline not ready, skipping")
		return
	
	print("  [Orchestrator] 💧 Coloration des eaux...")
	
	var groups_x = int(ceil(float(w) / 16.0))
	var groups_y = int(ceil(float(h) / 16.0))
	
	var sea_level = float(params.get("sea_level", 0.0))
	var atmosphere_type = int(params.get("planet_type", 0))
	var freshwater_max_size = int(params.get("freshwater_max_size", 999))
	
	# Créer le buffer de comptage pour les composantes d'eau
	var buffer_size = w * h * 4  # uint par pixel
	var counter_data = PackedByteArray()
	counter_data.resize(buffer_size)
	counter_data.fill(0)
	
	var counter_buffer = rd.storage_buffer_create(buffer_size, counter_data)
	if not counter_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create water counter buffer")
		return
	
	# === PASSE 1 : COMPTAGE ===
	_dispatch_water_to_color(w, h, groups_x, groups_y, 0, sea_level, atmosphere_type, freshwater_max_size, counter_buffer)
	
	# === PASSE 2 : COLORATION ===
	_dispatch_water_to_color(w, h, groups_x, groups_y, 1, sea_level, atmosphere_type, freshwater_max_size, counter_buffer)
	
	# Nettoyer le buffer de comptage
	gpu.release_rid(counter_buffer)
	
	print("  [Orchestrator] ✅ Eaux colorées")

## Exécute le shader de génération de la carte finale
func _run_final_map_shader(params: Dictionary, w: int, h: int) -> void:
	if not rd or not gpu.pipelines.has("final_map") or not gpu.pipelines["final_map"].is_valid():
		push_warning("[Orchestrator] ⚠️ final_map pipeline not ready, skipping")
		return
	
	print("  [Orchestrator] 🗺️ Génération carte finale...")
	
	var groups_x = int(ceil(float(w) / 16.0))
	var groups_y = int(ceil(float(h) / 16.0))
	
	var atmosphere_type = int(params.get("planet_type", 0))
	var sea_level = float(params.get("sea_level", 0.0))
	
	# Ne dessiner sur la carte finale que les rivières établies, pas chaque
	# micro-affluent. Les seuils ont déjà été adaptés à la surface de la planète
	# par la phase hydrologique.
	var river_threshold = float(params.get(
		"river_riviere_threshold",
		params.get("river_affluent_threshold", 5.0)
	))
	var relief_strength = 0.16
	var water_relief_factor = 0.25
	
	# Calculer min/max élévation pour normalisation (approximatif)
	var min_elevation = -10000.0
	var max_elevation = 10000.0
	
	# Créer le buffer de paramètres (40 bytes pour inclure water_relief_factor + padding)
	var buffer_bytes = PackedByteArray()
	buffer_bytes.resize(48)  # Alignement std140
	
	buffer_bytes.encode_u32(0, w)                      # width
	buffer_bytes.encode_u32(4, h)                      # height
	buffer_bytes.encode_u32(8, atmosphere_type)       # atmosphere_type
	buffer_bytes.encode_float(12, river_threshold)    # river_threshold
	buffer_bytes.encode_float(16, relief_strength)    # relief_strength
	buffer_bytes.encode_float(20, sea_level)          # sea_level
	buffer_bytes.encode_float(24, min_elevation)      # min_elevation
	buffer_bytes.encode_float(28, max_elevation)      # max_elevation
	buffer_bytes.encode_float(32, water_relief_factor) # water_relief_factor
	buffer_bytes.encode_float(36, 0.0)                # padding1
	buffer_bytes.encode_float(40, 0.0)                # padding2
	buffer_bytes.encode_float(44, 0.0)                # padding3
	
	var param_buffer = rd.uniform_buffer_create(buffer_bytes.size(), buffer_bytes)
	if not param_buffer.is_valid():
		push_error("[Orchestrator] ❌ Failed to create final_map param buffer")
		return
	
	# Créer les uniformes pour set 0 (textures)
	var tex_uniforms: Array[RDUniform] = []
	
	# Binding 0: geo_texture (RGBA32F)
	var u_geo = RDUniform.new()
	u_geo.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_geo.binding = 0
	u_geo.add_id(gpu.textures["geo"])
	tex_uniforms.append(u_geo)
	
	# Binding 1: biome_colored (RGBA8)
	var u_biome = RDUniform.new()
	u_biome.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_biome.binding = 1
	u_biome.add_id(gpu.textures["biome_colored"])
	tex_uniforms.append(u_biome)
	
	# Binding 2: river_flux (R32F)
	var u_river = RDUniform.new()
	u_river.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_river.binding = 2
	u_river.add_id(gpu.textures["river_flux"])
	tex_uniforms.append(u_river)
	
	# Binding 3: ice_caps (RGBA8)
	var u_ice = RDUniform.new()
	u_ice.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_ice.binding = 3
	u_ice.add_id(gpu.textures["ice_caps"])
	tex_uniforms.append(u_ice)
	
	# Binding 4: water_colored (RGBA8) - couleurs des eaux (salée/douce)
	var u_water = RDUniform.new()
	u_water.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_water.binding = 4
	u_water.add_id(gpu.textures["water_colored"])
	tex_uniforms.append(u_water)
	
	# Binding 5: final_map (RGBA8) output
	var u_final = RDUniform.new()
	u_final.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_final.binding = 5
	u_final.add_id(gpu.textures["final_map"])
	tex_uniforms.append(u_final)
	
	# Binding 6: biome_id (R32UI) - IDs des biomes pour lookup SSBO végétation
	var u_biome_id = RDUniform.new()
	u_biome_id.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_biome_id.binding = 6
	u_biome_id.add_id(gpu.textures["biome_id"])
	tex_uniforms.append(u_biome_id)
	
	# Binding 7: river_biome_id (R32UI) - IDs des biomes rivière pour lookup SSBO rivière
	var u_river_biome_id = RDUniform.new()
	u_river_biome_id.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_river_biome_id.binding = 7
	u_river_biome_id.add_id(gpu.textures["river_biome_id"])
	tex_uniforms.append(u_river_biome_id)
	
	var tex_set = rd.uniform_set_create(tex_uniforms, gpu.shaders["final_map"], 0)
	
	# Créer les uniformes pour set 1 (paramètres)
	var param_uniform = RDUniform.new()
	param_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	param_uniform.binding = 0
	param_uniform.add_id(param_buffer)
	
	var param_set = rd.uniform_set_create([param_uniform], gpu.shaders["final_map"], 1)
	
	# Créer le SSBO des biomes avec couleurs végétation pour set 2
	var biomes_veg_data = Enum.build_biomes_gpu_buffer(atmosphere_type, true)  # is_vegetation = true
	var biomes_veg_ssbo = rd.storage_buffer_create(biomes_veg_data.size(), biomes_veg_data)
	
	if not biomes_veg_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create vegetation biomes SSBO")
		gpu.release_rid(param_set)
		gpu.release_rid(tex_set)
		gpu.release_rid(param_buffer)
		return
	
	var ssbo_uniform = RDUniform.new()
	ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo_uniform.binding = 0
	ssbo_uniform.add_id(biomes_veg_ssbo)
	
	var ssbo_set = rd.uniform_set_create([ssbo_uniform], gpu.shaders["final_map"], 2)
	
	# Créer le SSBO des biomes rivière pour set 3
	var river_biomes_data = Enum.build_river_biomes_gpu_buffer(atmosphere_type, true)  # is_vegetation = true
	var river_biomes_ssbo = rd.storage_buffer_create(river_biomes_data.size(), river_biomes_data)
	
	if not river_biomes_ssbo.is_valid():
		push_error("[Orchestrator] ❌ Failed to create river biomes SSBO for final_map")
		gpu.release_rid(ssbo_set)
		gpu.release_rid(biomes_veg_ssbo)
		gpu.release_rid(param_set)
		gpu.release_rid(tex_set)
		gpu.release_rid(param_buffer)
		return
	
	var river_ssbo_uniform = RDUniform.new()
	river_ssbo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	river_ssbo_uniform.binding = 0
	river_ssbo_uniform.add_id(river_biomes_ssbo)
	
	var river_ssbo_set = rd.uniform_set_create([river_ssbo_uniform], gpu.shaders["final_map"], 3)
	
	# Dispatcher
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["final_map"])
	rd.compute_list_bind_uniform_set(compute_list, tex_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, param_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, ssbo_set, 2)
	rd.compute_list_bind_uniform_set(compute_list, river_ssbo_set, 3)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	gpu.submit_gpu_work()
	
	# Nettoyer
	gpu.release_rid(river_ssbo_set)
	gpu.release_rid(river_biomes_ssbo)
	gpu.release_rid(ssbo_set)
	gpu.release_rid(biomes_veg_ssbo)
	gpu.release_rid(param_set)
	gpu.release_rid(tex_set)
	gpu.release_rid(param_buffer)
	
	print("  [Orchestrator] ✅ Carte finale générée")

# ============================================================================
# EXPORT
# ============================================================================

## Exporte la carte d'élévation brute (GeoTexture) en Image
## Retourne les données float brutes pour traitement ultérieur
func export_geo_texture_to_image() -> Image:
	if not rd or not gpu.textures.has("geo") or not gpu.textures["geo"].is_valid():
		push_error("[Orchestrator] ❌ Cannot export geo texture - invalid RID")
		return null
	
	var byte_data = gpu.readback_texture_raw("geo")
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)

## Exporte toutes les cartes générées via PlanetExporter
## 
## @param output_dir: Dossier de sortie pour les fichiers PNG
## @return Dictionary: Chemins des fichiers exportés
func export_all_maps(output_dir: String) -> Dictionary:
	print("[Orchestrator] 📤 Exporting all maps to: ", output_dir)
	
	var exporter = PlanetExporter.new()
	var exported := exporter.export_maps(gpu, output_dir, generation_params)
	last_performance_report["export"] = exporter.last_metrics.duplicate(true)
	last_performance_report["total_generation_and_export_ms"] = (
		float(last_performance_report.get("gpu_simulation_wall_ms", 0.0))
		+ float(exporter.last_metrics.get("total_export_ms", 0.0))
	)
	return exported

## Example d'exportation de carte
func export_example_to_image() -> Image:
	var byte_data = gpu.readback_texture_raw("example")
	return Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBAF, byte_data)


# ============================================================================
# HELPERS METHODS
# ============================================================================

func _free_rid_array(rids: Array[RID]) -> void:
	for rid in rids:
		if rid.is_valid():
			gpu.release_rid(rid)

## Libère toutes les ressources GPU allouées par l'orchestrateur.
##
## Détruit manuellement les RIDs des textures, pipelines, shaders et uniform sets
## via [method RenderingDevice.free_rid] pour éviter les fuites de VRAM.
func cleanup() -> void:
	"""Nettoyage manuel - appeler avant de détruire l'orchestrateur"""
	if _cleaned_up:
		return
	_cleaned_up = true

	if not rd:
		gpu = null
		return
	
	print("[Orchestrator] 🧹 Nettoyage des ressources persistantes...")

	# S'assurer qu'aucune commande n'utilise encore les ressources que nous
	# allons libérer. C'est indispensable avant de remplacer un device local.
	gpu.sync_for_cpu("orchestrator_cleanup")

	if _linear_sampler.is_valid():
		gpu.release_rid(_linear_sampler)
		_linear_sampler = RID()

	if water_counter_buffer.is_valid():
		gpu.release_rid(water_counter_buffer)
		water_counter_buffer = RID()

	# Les orchestrator-owned resources are gone; the context can now release
	# descriptor sets, pipelines, shaders and remaining textures.
	if gpu:
		gpu.cleanup()

	# Relâcher les références propres à cet orchestrateur. GPUContext conserve
	# un device partagé pour éviter les create/destroy Vulkan successifs.
	gpu = null
	rd = null
	
	print("[Orchestrator] ✅ Ressources libérées")

## Copie une texture vers une autre (pour résoudre les problèmes de ping-pong)
func _copy_texture(src: RID, dst: RID, width: int, height: int) -> void:
	"""Copie src vers dst en utilisant texture_copy"""
	if not rd or not src.is_valid() or not dst.is_valid():
		push_error("[Orchestrator] ❌ Cannot copy texture: invalid RID or RD")
		return
	
	rd.texture_copy(src, dst, Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(width, height, 1), 0, 0, 0, 0)
	gpu.submit_gpu_work()

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
	# Les paramètres de l'interface sont en kilomètres et g/cm³. Convertir en
	# unités SI avant d'appliquer g = 4/3 * PI * G * rho * R.
	var radius_m = max(radius, 0.0) * 1000.0
	var density_kg_m3 = max(density, 0.0) * 1000.0
	return (4.0 / 3.0) * PI * G * density_kg_m3 * radius_m
