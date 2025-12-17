extends Node
class_name GPUContext

# === CONSTANTES DE CONFIGURATION ===
const RESOLUTION_WIDTH = 128
const RESOLUTION_HEIGHT = 64
const FORMAT_STATE = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT

enum TextureID {
	GEOPHYSICAL_STATE,
	ATMOSPHERIC_STATE,
	PLATE_DATA,
	TEMP_BUFFER
}

# === MEMBRES ===
var rd: RenderingDevice
var textures: Dictionary = {}
var shaders: Dictionary = {}
var pipelines: Dictionary = {}
var uniform_sets: Dictionary = {}

static var instance: GPUContext = null

# === INITIALISATION CORRIGÉE ===
func _init() -> void:
	if instance != null:
		push_error("GPUContext doit être un singleton unique")
		return
	instance = self
	
func _ready() -> void:
	# 🔥 FIX CRITIQUE : Utilisation d'un RenderingDevice LOCAL (thread-safe)
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		push_error("❌ Impossible de créer le RenderingDevice local")
		return
	
	_initialize_textures()
	print("✅ GPUContext initialisé (LOCAL RD): %dx%d" % [RESOLUTION_WIDTH, RESOLUTION_HEIGHT])

func get_vram_usage() -> String:
	var total_bytes = 0
	for tex_id in textures:
		total_bytes += RESOLUTION_WIDTH * RESOLUTION_HEIGHT * 16
	return "VRAM: %.2f MB" % (total_bytes / 1024.0 / 1024.0)

# === CRÉATION DES TEXTURES ===
func _initialize_textures() -> void:
	var format := RDTextureFormat.new()
	format.width = RESOLUTION_WIDTH
	format.height = RESOLUTION_HEIGHT
	format.format = FORMAT_STATE
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer les 4 textures
	for tex_id in TextureID.values():
		var data = PackedByteArray()
		data.resize(RESOLUTION_WIDTH * RESOLUTION_HEIGHT * 16)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture ID:", tex_id)
			continue
			
		textures[tex_id] = rid
	
	print("✅ Textures GPU créées (4x %d KB)" % (RESOLUTION_WIDTH * RESOLUTION_HEIGHT * 16 / 1024))

# === CHARGEMENT DES SHADERS (SÉCURISÉ) ===
func load_compute_shader(glsl_path: String, shader_name: String) -> bool:
	# 🔥 VALIDATION DU FICHIER
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
	
	shaders[shader_name] = shader_rid
	pipelines[shader_name] = rd.compute_pipeline_create(shader_rid)
	
	print("✅ Shader compilé: " + shader_name)
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

# === BARRIÈRE ===
func barrier(mask: int = RenderingDevice.BARRIER_MASK_ALL_BARRIERS) -> void:
	rd.barrier(mask)

# === READBACK TEXTURE ===
func readback_texture(tex_id: TextureID) -> Image:
	if not textures.has(tex_id):
		push_error("❌ Texture introuvable: ", tex_id)
		return null
	
	var data := rd.texture_get_data(textures[tex_id], 0)
	var img := Image.create_from_data(
		RESOLUTION_WIDTH,
		RESOLUTION_HEIGHT,
		false,
		Image.FORMAT_RGBAF,
		data
	)
	return img

# === NETTOYAGE ===
func _exit_tree() -> void:
	for rid in textures.values():
		if rid.is_valid():
			rd.free_rid(rid)
	for rid in shaders.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	for rid in pipelines.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	for rid in uniform_sets.values():
		if rid and rid.is_valid():
			rd.free_rid(rid)
	
	print("✅ Ressources GPU libérées")