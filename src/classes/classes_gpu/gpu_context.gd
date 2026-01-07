extends Node
class_name GPUContext

# === CONSTANTES DE CONFIGURATION ===
const FORMAT_STATE = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const FORMAT_RGBA8 = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
const FORMAT_R32F = RenderingDevice.DATA_FORMAT_R32_SFLOAT

# IDs des textures GPU utilisées dans la pipeline
# geo : GeoTexture (RGBA32F) - R=height, G=bedrock, B=sediment, A=water_height
# climate : ClimateTexture (RGBA32F) - R=temperature, G=humidity, B=windX, A=windY
# temp_buffer : Buffer temporaire pour ping-pong
# plates : PlateTexture (RGBA32F) - R=plate_id, G=velocity_x, B=velocity_y, A=convergence_type
# crust_age : CrustAgeTexture (RGBA32F) - R=distance_km, G=age_ma, B=subsidence, A=valid
static var TextureID : Array[String] = ["geo", "climate", "temp_buffer", "plates", "crust_age"]

# Textures Étape 3 - Atmosphère & Climat
# vapor : VaporTexture (R32F) - densité de vapeur d'eau pour simulation fluide
# vapor_temp : VaporTempTexture (R32F) - buffer ping-pong pour advection
# temperature_colored : (RGBA8) - couleur température pour export direct
# precipitation_colored : (RGBA8) - couleur précipitation pour export direct
# clouds : (RGBA8) - nuages blanc/transparent
# ice_caps : (RGBA8) - banquise blanc/transparent
static var TextureID_Climat : Array[String] = ["vapor", "vapor_temp", "temperature_colored", "precipitation_colored", "clouds", "ice_caps"]

# === MEMBRES ===
var rd: RenderingDevice
var textures: Dictionary = {}
var shaders: Dictionary = {}
var pipelines: Dictionary = {}
var uniform_sets: Dictionary = {}
var resolution: Vector2i

func _init(resolution: Vector2i) -> void:
	self.resolution = resolution
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		push_error("❌ FATAL: Impossible de créer le RenderingDevice local")
		push_error("  Causes possibles:")
		push_error("    - GPU ne supporte pas Vulkan/Metal")

		push_error("    - Drivers graphiques obsolètes")
		push_error("    - Godot lancé en mode headless sans GPU")
		return
	
	# ✅ VALIDATION: Tester que le RD fonctionne
	var test_format = RDTextureFormat.new()
	test_format.width = 16
	test_format.height = 16
	test_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	test_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	
	var test_data = PackedByteArray()
	test_data.resize(16 * 16 * 16)
	test_data.fill(0)
	
	var test_texture = rd.texture_create(test_format, RDTextureView.new(), [test_data])
	if not test_texture.is_valid():
		push_error("❌ FATAL: RenderingDevice créé mais incapable de créer des textures")
		rd = null
		return
	
	# Nettoyer la texture de test
	rd.free_rid(test_texture)
	
	print("✅ RenderingDevice validé et fonctionnel")
	
	# Créer les textures de travail
	_initialize_textures()

func get_vram_usage() -> String:
	var total_bytes = 0
	for tex_id in textures:
		total_bytes += resolution.x * resolution.y * 16
	return "VRAM: %.2f MB" % (total_bytes / 1024.0 / 1024.0)

# === CRÉATION DES TEXTURES ===
func _initialize_textures() -> void:
	# Format RGBA32F pour textures d'état
	var format := RDTextureFormat.new()
	format.width = resolution.x
	format.height = resolution.y
	format.format = FORMAT_STATE
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer les textures d'état (RGBA32F)
	for tex_id in TextureID:
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 16)  # 16 bytes per pixel (RGBA32F)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture ID:", tex_id)
			continue
			
		textures[tex_id] = rid
	
	print("✅ Textures GPU d'état créées (%d x %d KB)" % [TextureID.size(), resolution.x * resolution.y * 16 / 1024])

# === CRÉATION DES TEXTURES CLIMAT (Étape 3) ===
func initialize_climate_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 3 (Atmosphère & Climat).
	Appelé par l'orchestrateur avant la phase atmosphérique.
	"""
	
	# Format R32F pour textures de vapeur (ping-pong)
	var format_r32f := RDTextureFormat.new()
	format_r32f.width = resolution.x
	format_r32f.height = resolution.y
	format_r32f.format = FORMAT_R32F
	format_r32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format RGBA8 pour textures colorées (export direct)
	var format_rgba8 := RDTextureFormat.new()
	format_rgba8.width = resolution.x
	format_rgba8.height = resolution.y
	format_rgba8.format = FORMAT_RGBA8
	format_rgba8.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer les textures de vapeur (R32F - 4 bytes par pixel)
	for tex_id in ["vapor", "vapor_temp"]:
		if textures.has(tex_id):
			continue  # Déjà créée
		
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)  # 4 bytes per pixel (R32F)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32f, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture vapeur:", tex_id)
			continue
			
		textures[tex_id] = rid
	
	# Créer les textures colorées (RGBA8 - 4 bytes par pixel)
	for tex_id in ["temperature_colored", "precipitation_colored", "clouds", "ice_caps"]:
		if textures.has(tex_id):
			continue  # Déjà créée
		
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)  # 4 bytes per pixel (RGBA8)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba8, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture colorée:", tex_id)
			continue
			
		textures[tex_id] = rid
	
	print("✅ Textures climat créées (2x R32F + 4x RGBA8)")

# === CHARGEMENT DES SHADERS (SÉCURISÉ) ===
func load_compute_shader(glsl_path: String, shader_name: String) -> bool:
	if not FileAccess.file_exists(glsl_path):
		push_error("❌ SHADER NOT FOUND: " + glsl_path)
		return false

	var shader_file = load(glsl_path)
	if not shader_file:
		push_error("❌ Échec chargement fichier: " + glsl_path)
		return false

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_spirv:
		push_error("❌ Pas de SPIR-V disponible: " + shader_name)
		return false

	var shader_rid: RID = rd.shader_create_from_spirv(shader_spirv)
	if not shader_rid.is_valid():
		push_error("❌ Échec compilation SPIR-V: " + shader_name)
		return false

	# --- PERSISTENCE FORCÉE ---
	shaders[shader_name] = shader_rid
	pipelines[shader_name] = rd.compute_pipeline_create(shader_rid)

	print("✅ Shader compilé et enregistré dans GPUContext: " + shader_name)
	return true

# === HELPER: CRÉER UN UNIFORM TEXTURE ===
func create_texture_uniform(binding: int, texture_rid: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture_rid)
	return uniform

# === DISPATCH COMPUTE ===
func dispatch_compute(shader_name: String, groups_x: int, groups_y: int = 1, groups_z: int = 1) -> void:
	if not pipelines.has(shader_name):
		push_error("❌ Pipeline introuvable: " + shader_name)
		return
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipelines[shader_name])
	
	if uniform_sets.has(shader_name):
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[shader_name], 0)
	
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, groups_z)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

# === READBACK TEXTURE ===
func readback_texture(tex_id: String) -> Image:
	if not textures.has(tex_id):
		push_error("❌ Texture introuvable: ", tex_id)
		return null
	
	var data := rd.texture_get_data(textures[tex_id], 0)
	
	# Déterminer le format de l'image selon le type de texture
	var img_format = Image.FORMAT_RGBAF
	
	# Textures RGBA8 (colorées)
	if tex_id in ["temperature_colored", "precipitation_colored", "clouds", "ice_caps"]:
		img_format = Image.FORMAT_RGBA8
	# Textures R32F (vapeur)
	elif tex_id in ["vapor", "vapor_temp"]:
		img_format = Image.FORMAT_RF
	# Textures RGBA32F (par défaut)
	
	var img := Image.create_from_data(
		resolution.x,
		resolution.y,
		false,
		img_format,
		data
	)
	return img

# === NETTOYAGE ===
func _exit_tree() -> void:
	# Vérifier que le RenderingDevice est toujours valide
	if not rd:
		print("⚠️ RenderingDevice déjà libéré, skip cleanup")
		return
	
	# Libérer les ressources dans l'ordre inverse de création
	# 1. Uniform sets (dépendent des shaders et textures)
	for rid in uniform_sets.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	uniform_sets.clear()
	
	# 2. Pipelines (dépendent des shaders)
	for rid in pipelines.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	pipelines.clear()
	
	# 3. Shaders
	for rid in shaders.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	shaders.clear()
	
	# 4. Textures (indépendantes)
	for rid in textures.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	textures.clear()
	
	print("✅ Ressources GPU libérées proprement")
