extends Node

## Singleton gérant le RenderingDevice et les ressources GPU
class_name GPUContext

# === CONSTANTES DE CONFIGURATION ===
const RESOLUTION_WIDTH = 2048   # Équirectangulaire 2:1
const RESOLUTION_HEIGHT = 1024
const FORMAT_STATE = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT  # RGBAF32

# Identifiants des textures packed
enum TextureID {
	GEOPHYSICAL_STATE,  # R=Lithosphère, G=Eau, B=Sédiments, A=Dureté
	ATMOSPHERIC_STATE,  # R=Température, G=Humidité, B=Pression, A=Nuages
	PLATE_DATA,         # R=PlateID, G=VectorX, B=VectorY, A=Stress
	TEMP_BUFFER         # Buffer temporaire pour ping-pong
}

# === MEMBRES ===
var rd: RenderingDevice
var textures: Dictionary = {}  # TextureID -> RID
var shaders: Dictionary = {}   # String -> RID (shader compilé)
var pipelines: Dictionary = {} # String -> RID (compute pipeline)
var uniform_sets: Dictionary = {} # String -> RID

# Singleton instance
static var instance: GPUContext = null

# === INITIALISATION ===
func _init() -> void:
	if instance != null:
		push_error("GPUContext doit être un singleton unique")
		return
	instance = self
	
func _ready() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Impossible de créer le RenderingDevice")
		return
	
	_initialize_textures()
	_load_shaders()
	print("✓ GPUContext initialisé: %dx%d" % [RESOLUTION_WIDTH, RESOLUTION_HEIGHT])

# === CRÉATION DES TEXTURES ===
func _initialize_textures() -> void:
	var format := RDTextureFormat.new()
	format.width = RESOLUTION_WIDTH
	format.height = RESOLUTION_HEIGHT
	format.format = FORMAT_STATE
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |      # Compute shader write
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |     # Fragment shader read
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT  # Readback CPU
	)
	
	# Créer les 4 textures principales
	for tex_id in TextureID.values():
		var data := PackedByteArray()
		data.resize(RESOLUTION_WIDTH * RESOLUTION_HEIGHT * 16)  # 4 floats * 4 bytes
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format, view, [data])
		textures[tex_id] = rid
		
	print("✓ Textures GPU créées (4x %d KB)" % (data.size() / 1024))

# === CHARGEMENT DES SHADERS ===
func _load_shaders() -> void:
	# On chargera les .glsl compilés en SPIR-V ici
	# Pour l'instant, on crée juste les entrées du dictionnaire
	shaders["tectonic_init"] = null
	shaders["tectonic_propagate"] = null
	shaders["atmosphere_advect"] = null
	shaders["atmosphere_diffuse"] = null
	shaders["erosion_flux"] = null
	shaders["erosion_transport"] = null

# === HELPER: COMPILER UN SHADER ===
func compile_shader(glsl_path: String, shader_name: String) -> bool:
	var file = FileAccess.open(glsl_path, FileAccess.READ)
	if not file:
		push_error("Shader introuvable: " + glsl_path)
		return false
	
	var source_code = file.get_as_text()
	file.close()
	
	# Godot 4 nécessite SPIR-V compilé. On suppose un .spv précompilé
	var spirv_path = glsl_path.replace(".glsl", ".spv")
	var spirv_file = FileAccess.open(spirv_path, FileAccess.READ)
	if not spirv_file:
		push_error("SPIR-V manquant: " + spirv_path)
		return false
	
	var spirv_data = spirv_file.get_buffer(spirv_file.get_length())
	spirv_file.close()
	
	var shader_spirv := RDShaderSPIRV.new()
	shader_spirv.set_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE, spirv_data)
	
	var shader_rid := rd.shader_create_from_spirv(shader_spirv)
	if not shader_rid.is_valid():
		push_error("Échec compilation: " + shader_name)
		return false
	
	shaders[shader_name] = shader_rid
	pipelines[shader_name] = rd.compute_pipeline_create(shader_rid)
	print("✓ Shader compilé: " + shader_name)
	return true

# === HELPER: CRÉER UN UNIFORM SET ===
func create_uniform_set(shader_name: String, bindings: Array[Dictionary]) -> RID:
	"""
	bindings: Array de {binding: int, texture: TextureID, access: RD.BARRIER_MASK_*}
	"""
	var uniforms := []
	
	for bind in bindings:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = bind.binding
		
		var texture_rid = textures[bind.texture]
		uniform.add_id(texture_rid)
		uniforms.append(uniform)
	
	var set_rid := rd.uniform_set_create(uniforms, shaders[shader_name], 0)
	uniform_sets[shader_name] = set_rid
	return set_rid

# === DISPATCH COMPUTE ===
func dispatch_compute(shader_name: String, groups_x: int, groups_y: int = 1, groups_z: int = 1) -> void:
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipelines[shader_name])
	rd.compute_list_bind_uniform_set(compute_list, uniform_sets[shader_name], 0)
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, groups_z)
	rd.compute_list_end()
	rd.submit()
	rd.sync()  # Bloque jusqu'à la fin

# === BARRIÈRE DE SYNCHRONISATION ===
func barrier(mask: int = RenderingDevice.BARRIER_MASK_ALL_BARRIERS) -> void:
	rd.barrier(mask)

# === READBACK TEXTURE ===
func readback_texture(tex_id: TextureID) -> Image:
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
		rd.free_rid(rid)
	for rid in shaders.values():
		if rid: rd.free_rid(rid)
	for rid in pipelines.values():
		if rid: rd.free_rid(rid)
	for rid in uniform_sets.values():
		rd.free_rid(rid)
	print("✓ Ressources GPU libérées")
