extends Node

## Orchestre la simulation géophysique sur GPU
class_name GeoComputeOrchestrator

# === PARAMÈTRES DE SIMULATION ===
@export var num_tectonic_plates := 25
@export var planet_radius := 6371000.0  # Terre en mètres
@export var simulation_years := 100_000_000  # 100M années
@export var time_step_years := 10_000  # Pas de 10k ans

# Références
var gpu: GPUContext
var rd: RenderingDevice

# État simulation
var current_year := 0.0

# === INITIALISATION ===
func _ready() -> void:
	gpu = GPUContext.instance
	if not gpu:
		push_error("GPUContext doit être initialisé avant")
		return
	rd = gpu.rd
	
	_compile_all_shaders()
	_initialize_tectonic_seeds()
	print("✓ Orchestrateur prêt")

# === COMPILATION SHADERS ===
func _compile_all_shaders() -> void:
	var shader_dir = "res://shaders/compute/"
	
	# Liste des shaders à compiler
	var shaders = [
		"tectonic_plates.glsl",
		"orogeny.glsl", 
		"atmosphere_dynamics.glsl"
	]
	
	for shader_file in shaders:
		var shader_name = shader_file.get_basename()
		var success = gpu.compile_shader(shader_dir + shader_file, shader_name)
		if not success:
			push_error("Échec compilation: " + shader_name)

# === INITIALISATION SEEDS TECTONIQUES ===
func _initialize_tectonic_seeds() -> void:
	"""
	Génère N positions aléatoires pour les plaques.
	Écrit dans PLATE_DATA: R=PlateID, GB=Seed_UV, A=0
	"""
	randomize()
	var seed_data := PackedFloat32Array()
	seed_data.resize(2048 * 1024 * 4)  # RGBAF32
	seed_data.fill(0.0)
	
	# Générer seeds aléatoires
	for i in range(num_tectonic_plates):
		var seed_x = randf()
		var seed_y = randf()
		var pixel_x = int(seed_x * 2048)
		var pixel_y = int(seed_y * 1024)
		var idx = (pixel_y * 2048 + pixel_x) * 4
		
		seed_data[idx + 0] = float(i + 1)  # PlateID (0 = pas de plaque)
		seed_data[idx + 1] = seed_x
		seed_data[idx + 2] = seed_y
		seed_data[idx + 3] = 0.0
	
	# Upload vers GPU
	var bytes := seed_data.to_byte_array()
	rd.texture_update(gpu.textures[GPUContext.TextureID.PLATE_DATA], 0, bytes)
	
	print("✓ %d plaques initialisées" % num_tectonic_plates)

# === SIMULATION TECTONIQUE COMPLÈTE ===
func execute_tectonic_simulation() -> void:
	print("=== PHASE TECTONIQUE ===")
	
	# 1. Jump Flooding Algorithm (log2(max_dim) passes)
	var max_steps = int(ceil(log(2048) / log(2)))  # ~11 passes
	for i in range(max_steps):
		var step_size = int(pow(2, max_steps - i - 1))
		_jump_flood_pass(step_size, i)
	
	# 2. Calculer vecteurs de plaque (gradient du champ de distance)
	_compute_plate_vectors()
	
	# 3. Orogénèse sur N cycles
	var num_cycles = simulation_years / time_step_years
	for cycle in range(int(num_cycles)):
		_orogeny_cycle(time_step_years)
		current_year += time_step_years
		
		if cycle % 100 == 0:
			print("  Cycle %d / %d (%.1fM ans)" % [cycle, num_cycles, current_year / 1e6])
	
	print("✓ Tectonique terminée: %.1fM ans" % (current_year / 1e6))

# === JUMP FLOOD PASS ===
func _jump_flood_pass(step_size: int, iteration: int) -> void:
	# Créer uniform set pour ce pass
	var bindings = [
		{"binding": 0, "texture": GPUContext.TextureID.PLATE_DATA},      # Input
		{"binding": 1, "texture": GPUContext.TextureID.TEMP_BUFFER}       # Output
	]
	gpu.create_uniform_set("tectonic_plates", bindings)
	
	# Push constants
	var params = PackedByteArray()
	params.resize(16)
	params.encode_s32(0, step_size)
	params.encode_s32(4, num_tectonic_plates)
	params.encode_float(8, planet_radius)
	params.encode_u32(12, iteration)
	
	# Dispatch
	var groups_x = int(ceil(2048.0 / 16.0))
	var groups_y = int(ceil(1024.0 / 16.0))
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["tectonic_plates"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["tectonic_plates"], 0)
	rd.compute_list_set_push_constant(compute_list, params, params.size())
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()
	
	# Swap buffers (ping-pong)
	rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
	_swap_textures(GPUContext.TextureID.PLATE_DATA, GPUContext.TextureID.TEMP_BUFFER)

# === CALCUL VECTEURS PLAQUES ===
func _compute_plate_vectors() -> void:
	# TODO: Shader dédié qui calcule gradient du champ de distance
	# Pour Phase 2, on utilise les vecteurs générés dans orogeny.glsl
	pass

# === CYCLE OROGÉNÈSE ===
func _orogeny_cycle(delta_years: float) -> void:
	var bindings = [
		{"binding": 0, "texture": GPUContext.TextureID.PLATE_DATA},
		{"binding": 1, "texture": GPUContext.TextureID.GEOPHYSICAL_STATE}
	]
	gpu.create_uniform_set("orogeny", bindings)
	
	var params = PackedByteArray()
	params.resize(16)
	params.encode_float(0, 50.0)      # mountain_strength
	params.encode_float(4, -30.0)     # rift_strength
	params.encode_float(8, 0.98)      # erosion_factor
	params.encode_float(12, delta_years)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["orogeny"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["orogeny"], 0)
	rd.compute_list_set_push_constant(compute_list, params, params.size())
	rd.compute_list_dispatch(compute_list, 128, 64, 1)
	rd.compute_list_end()
	
	rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

# === SIMULATION ATMOSPHÉRIQUE ===
func execute_atmospheric_simulation(num_steps: int = 1000) -> void:
	print("=== PHASE ATMOSPHÉRIQUE ===")
	
	for step in range(num_steps):
		_atmospheric_step()
		
		if step % 100 == 0:
			print("  Step %d / %d" % [step, num_steps])
	
	print("✓ Atmosphère simulée: %d steps" % num_steps)

func _atmospheric_step() -> void:
	var bindings = [
		{"binding": 0, "texture": GPUContext.TextureID.ATMOSPHERIC_STATE},
		{"binding": 1, "texture": GPUContext.TextureID.GEOPHYSICAL_STATE},
		{"binding": 2, "texture": GPUContext.TextureID.TEMP_BUFFER}
	]
	gpu.create_uniform_set("atmosphere_dynamics", bindings)
	
	var params = PackedByteArray()
	params.resize(20)
	params.encode_float(0, 1361.0)    # solar_constant
	params.encode_float(4, 7.2921e-5) # rotation_speed (Terre)
	params.encode_float(8, 0.01)      # diffusion_rate
	params.encode_float(12, 0.7)      # condensation_threshold
	params.encode_float(16, 3600.0)   # delta_time (1h)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipelines["atmosphere_dynamics"])
	rd.compute_list_bind_uniform_set(compute_list, gpu.uniform_sets["atmosphere_dynamics"], 0)
	rd.compute_list_set_push_constant(compute_list, params, params.size())
	rd.compute_list_dispatch(compute_list, 128, 64, 1)
	rd.compute_list_end()
	
	rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
	_swap_textures(GPUContext.TextureID.ATMOSPHERIC_STATE, GPUContext.TextureID.TEMP_BUFFER)

# === HELPERS ===
func _swap_textures(tex_a: GPUContext.TextureID, tex_b: GPUContext.TextureID) -> void:
	var temp = gpu.textures[tex_a]
	gpu.textures[tex_a] = gpu.textures[tex_b]
	gpu.textures[tex_b] = temp

# === EXPORT RÉSULTATS ===
func export_all_maps(output_dir: String) -> void:
	print("=== EXPORT CARTES ===")
	
	# Récupérer textures depuis GPU
	var geo_img = gpu.readback_texture(GPUContext.TextureID.GEOPHYSICAL_STATE)
	var atmo_img = gpu.readback_texture(GPUContext.TextureID.ATMOSPHERIC_STATE)
	
	# Générer les 10 cartes requises (Phase 3 - à implémenter)
	# Pour l'instant, sauver les raw data
	geo_img.save_png(output_dir + "/geophysical_raw.png")
	atmo_img.save_png(output_dir + "/atmospheric_raw.png")
	
	print("✓ Export terminé: " + output_dir)
