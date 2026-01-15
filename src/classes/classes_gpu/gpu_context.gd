extends Node
class_name GPUContext

# === CONSTANTES DE CONFIGURATION ===
const FORMAT_STATE = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const FORMAT_RGBA8 = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
const FORMAT_R32F = RenderingDevice.DATA_FORMAT_R32_SFLOAT
const FORMAT_R32UI = RenderingDevice.DATA_FORMAT_R32_UINT
const FORMAT_RG32I = RenderingDevice.DATA_FORMAT_R32G32_SINT

# IDs des textures GPU utilisées dans la pipeline
# geo : GeoTexture (RGBA32F) - R=height, G=bedrock, B=sediment, A=water_height
# climate : ClimateTexture (RGBA32F) - R=temperature, G=humidity, B=windX, A=windY
# temp_buffer : Buffer temporaire pour ping-pong
# plates : PlateTexture (RGBA32F) - R=plate_id, G=velocity_x, B=velocity_y, A=convergence_type
# crust_age : CrustAgeTexture (RGBA32F) - R=distance_km, G=age_ma, B=subsidence, A=valid
static var TextureID : Array[String] = ["geo", "climate", "temp_buffer", "plates", "crust_age"]

# Textures Étape 2 - Érosion Hydraulique
# geo_temp : Buffer ping-pong pour GeoTexture pendant l'érosion (RGBA32F)
# river_flux : Carte de flux pour détection des rivières (R32F)
# flux_temp : Buffer ping-pong pour flux_accumulation (R32F)
static var TextureID_Erosion : Array[String] = ["geo_temp", "river_flux", "flux_temp"]

# Textures Étape 3 - Atmosphère & Climat
# vapor : VaporTexture (R32F) - densité de vapeur d'eau pour simulation fluide
# vapor_temp : VaporTempTexture (R32F) - buffer ping-pong pour advection
# temperature_colored : (RGBA8) - couleur température pour export direct
# precipitation_colored : (RGBA8) - couleur précipitation pour export direct
# clouds : (RGBA8) - nuages blanc/transparent
# ice_caps : (RGBA8) - banquise blanc/transparent
static var TextureID_Climat : Array[String] = ["vapor", "vapor_temp", "temperature_colored", "precipitation_colored", "clouds", "ice_caps"]

# Textures Étape 5 - Ressources & Pétrole
# petrole : (RGBA8) - carte de pétrole (noir/transparent)
# resources : (RGBA32F) - R=resource_id, G=intensity, B=cluster_id, A=has_resource
static var TextureID_Resources : Array[String] = ["petrole", "resources"]

# Textures Étape 2.5 - Classification des Eaux & Rivières
# water_mask : (R8) - Type d'eau : 0=terre, 1=eau salée, 2=eau douce
# water_component : (RG32I) - Coordonnées seed JFA pour composantes connexes
# water_component_temp : (RG32I) - Buffer ping-pong JFA
# river_sources : (R32UI) - IDs des sources de rivières
# river_flux : (R32F) - Intensité du flux des rivières
# river_flux_temp : (R32F) - Buffer ping-pong pour propagation
static var TextureID_Water : Array[String] = ["water_mask", "water_component", "water_component_temp", "river_sources", "river_flux", "river_flux_temp"]

# Textures Étape 4 - Régions administratives
# region_map : (R32UI) - ID de région par pixel (0xFFFFFFFF = non assigné)
# region_cost : (R32F) - Coût accumulé depuis le seed (pour Dijkstra)
# region_cost_temp : (R32F) - Buffer ping-pong pour propagation
# region_colored : (RGBA8) - Couleur finale des régions pour export
static var TextureID_Region : Array[String] = ["region_map", "region_cost", "region_cost_temp", "region_colored"]

# === MEMBRES ===
var rd: RenderingDevice
var textures: Dictionary = {}
var shaders: Dictionary = {}
var pipelines: Dictionary = {}
var uniform_sets: Dictionary = {}
var resolution: Vector2i

func _init(resolution_param: Vector2i) -> void:
	self.resolution = resolution_param
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
	
	print("✅ Textures GPU d'état créées (%d x %d KB)" % [TextureID.size(), int(resolution.x * resolution.y * 16.0 / 1024.0)])

# === CRÉATION DES TEXTURES ÉROSION (Étape 2) ===
func initialize_erosion_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 2 (Érosion Hydraulique).
	Appelé par l'orchestrateur avant la phase d'érosion.
	"""
	
	# Format RGBA32F pour geo_temp (ping-pong de GeoTexture)
	var format_rgba32f := RDTextureFormat.new()
	format_rgba32f.width = resolution.x
	format_rgba32f.height = resolution.y
	format_rgba32f.format = FORMAT_STATE  # RGBA32F
	format_rgba32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format R32F pour textures de flux
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
	
	# Créer geo_temp (RGBA32F - 16 bytes par pixel)
	if not textures.has("geo_temp"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 16)  # 16 bytes per pixel (RGBA32F)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba32f, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture geo_temp")
		else:
			textures["geo_temp"] = rid
	
	# Créer les textures de flux (R32F - 4 bytes par pixel)
	for tex_id in ["river_flux", "flux_temp"]:
		if textures.has(tex_id):
			continue  # Déjà créée
		
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)  # 4 bytes per pixel (R32F)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32f, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture flux:", tex_id)
			continue
			
		textures[tex_id] = rid
	
	print("✅ Textures érosion créées (1x RGBA32F + 2x R32F)")

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

# === CRÉATION DES TEXTURES RESSOURCES (Étape 5) ===
func initialize_resources_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 5 (Ressources & Pétrole).
	Appelé par l'orchestrateur avant la phase de génération des ressources.
	"""
	
	# Format RGBA8 pour texture de pétrole (export direct)
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
	
	# Format RGBA32F pour texture de ressources (stockage des IDs)
	var format_rgba32f := RDTextureFormat.new()
	format_rgba32f.width = resolution.x
	format_rgba32f.height = resolution.y
	format_rgba32f.format = FORMAT_STATE  # RGBA32F
	format_rgba32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer texture petrole (RGBA8 - 4 bytes par pixel)
	if not textures.has("petrole"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)  # 4 bytes per pixel (RGBA8)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba8, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture petrole")
		else:
			textures["petrole"] = rid
	
	# Créer texture resources (RGBA32F - 16 bytes par pixel)
	if not textures.has("resources"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 16)  # 16 bytes per pixel (RGBA32F)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba32f, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture resources")
		else:
			textures["resources"] = rid
	
	print("✅ Textures ressources créées (1x RGBA8 + 1x RGBA32F)")

# === CRÉATION DES TEXTURES EAUX (Étape 2.5) ===
func initialize_water_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 2.5 (Classification des Eaux & Rivières).
	Appelé par l'orchestrateur avant la phase de classification des eaux.
	
	Textures créées:
	- water_mask (R8) : Type d'eau (0=terre, 1=salée, 2=douce)
	- water_component / water_component_temp (RG32I) : JFA pour composantes connexes
	- river_sources (R32UI) : IDs des points sources
	- river_flux / river_flux_temp (R32F) : Flux des rivières (ping-pong)
	"""
	
	# Format R8 pour masque d'eau (1 byte par pixel)
	var format_r8 := RDTextureFormat.new()
	format_r8.width = resolution.x
	format_r8.height = resolution.y
	format_r8.format = RenderingDevice.DATA_FORMAT_R8_UINT
	format_r8.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format RG32I pour JFA composantes connexes (8 bytes par pixel)
	var format_rg32i := RDTextureFormat.new()
	format_rg32i.width = resolution.x
	format_rg32i.height = resolution.y
	format_rg32i.format = FORMAT_RG32I
	format_rg32i.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format R32UI pour sources (4 bytes par pixel)
	var format_r32ui := RDTextureFormat.new()
	format_r32ui.width = resolution.x
	format_r32ui.height = resolution.y
	format_r32ui.format = FORMAT_R32UI
	format_r32ui.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format R32F pour flux rivières (4 bytes par pixel)
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
	
	# Créer water_mask (R8 - 1 byte par pixel)
	if not textures.has("water_mask"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y)
		data.fill(0)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r8, view, [data])
		if rid.is_valid():
			textures["water_mask"] = rid
		else:
			push_error("❌ Échec création texture water_mask")
	
	# Créer water_component et water_component_temp (RG32I - 8 bytes par pixel)
	for tex_id in ["water_component", "water_component_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 8)
			# Initialiser à -1 (invalide)
			for i in range(0, data.size(), 4):
				data.encode_s32(i, -1)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_rg32i, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer river_sources (R32UI - 4 bytes par pixel)
	if not textures.has("river_sources"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		data.fill(0)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [data])
		if rid.is_valid():
			textures["river_sources"] = rid
		else:
			push_error("❌ Échec création texture river_sources")
	
	# Créer river_flux et river_flux_temp (R32F - 4 bytes par pixel)
	for tex_id in ["river_flux", "river_flux_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			data.fill(0)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r32f, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	print("✅ Textures eaux créées (1x R8 + 2x RG32I + 1x R32UI + 2x R32F)")

# === CRÉATION DES TEXTURES RÉGIONS (Étape 4) ===
func initialize_region_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 4 (Régions administratives).
	Appelé par l'orchestrateur avant la phase de génération des régions.
	
	Textures créées:
	- region_map (R32UI) : ID de région par pixel
	- region_cost / region_cost_temp (R32F) : Coûts accumulés (ping-pong Dijkstra)
	- region_colored (RGBA8) : Couleur finale pour export
	"""
	
	# Format R32UI pour IDs de région (4 bytes par pixel)
	var format_r32ui := RDTextureFormat.new()
	format_r32ui.width = resolution.x
	format_r32ui.height = resolution.y
	format_r32ui.format = FORMAT_R32UI
	format_r32ui.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format R32F pour coûts (4 bytes par pixel)
	var format_r32f := RDTextureFormat.new()
	format_r32f.width = resolution.x
	format_r32f.height = resolution.y
	format_r32f.format = FORMAT_R32F
	format_r32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format RGBA8 pour couleur finale (4 bytes par pixel)
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
	
	# Créer region_map (R32UI - 4 bytes par pixel, initialisé à 0xFFFFFFFF = non assigné)
	if not textures.has("region_map"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		# Initialiser à 0xFFFFFFFF (invalide/non assigné)
		for i in range(0, data.size(), 4):
			data.encode_u32(i, 0xFFFFFFFF)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [data])
		if rid.is_valid():
			textures["region_map"] = rid
		else:
			push_error("❌ Échec création texture region_map")
	
	# Créer region_map_temp (R32UI - pour ping-pong dans cleanup)
	if not textures.has("region_map_temp"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		# Initialiser à 0xFFFFFFFF (invalide/non assigné)
		for i in range(0, data.size(), 4):
			data.encode_u32(i, 0xFFFFFFFF)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [data])
		if rid.is_valid():
			textures["region_map_temp"] = rid
		else:
			push_error("❌ Échec création texture region_map_temp")
	
	# Créer region_cost et region_cost_temp (R32F - 4 bytes par pixel)
	for tex_id in ["region_cost", "region_cost_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			# Initialiser à une grande valeur (coût infini)
			for i in range(0, data.size(), 4):
				data.encode_float(i, 1e30)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r32f, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer region_colored (RGBA8 - 4 bytes par pixel)
	if not textures.has("region_colored"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		data.fill(0)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba8, view, [data])
		if rid.is_valid():
			textures["region_colored"] = rid
		else:
			push_error("❌ Échec création texture region_colored")
	
	print("✅ Textures régions créées (2x R32UI + 2x R32F + 1x RGBA8)")

func initialize_ocean_region_textures() -> void:
	"""
	Initialise les textures spécifiques aux régions océaniques (étape 4.5).
	Appelé par l'orchestrateur avant la phase de génération des régions océaniques.
	
	Textures créées:
	- ocean_region_map (R32UI) : ID de région océanique par pixel
	- ocean_region_map_temp (R32UI) : Buffer ping-pong pour cleanup
	- ocean_region_cost / ocean_region_cost_temp (R32F) : Coûts accumulés
	- ocean_region_colored (RGBA8) : Couleur finale pour export
	"""
	
	# Format R32UI pour IDs de région (4 bytes par pixel)
	var format_r32ui := RDTextureFormat.new()
	format_r32ui.width = resolution.x
	format_r32ui.height = resolution.y
	format_r32ui.format = FORMAT_R32UI
	format_r32ui.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format R32F pour coûts (4 bytes par pixel)
	var format_r32f := RDTextureFormat.new()
	format_r32f.width = resolution.x
	format_r32f.height = resolution.y
	format_r32f.format = FORMAT_R32F
	format_r32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Format RGBA8 pour couleur finale (4 bytes par pixel)
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
	
	# Créer ocean_region_map (R32UI)
	if not textures.has("ocean_region_map"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		for i in range(0, data.size(), 4):
			data.encode_u32(i, 0xFFFFFFFF)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [data])
		if rid.is_valid():
			textures["ocean_region_map"] = rid
		else:
			push_error("❌ Échec création texture ocean_region_map")
	
	# Créer ocean_region_map_temp (R32UI)
	if not textures.has("ocean_region_map_temp"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		for i in range(0, data.size(), 4):
			data.encode_u32(i, 0xFFFFFFFF)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [data])
		if rid.is_valid():
			textures["ocean_region_map_temp"] = rid
		else:
			push_error("❌ Échec création texture ocean_region_map_temp")
	
	# Créer ocean_region_cost et ocean_region_cost_temp (R32F)
	for tex_id in ["ocean_region_cost", "ocean_region_cost_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			for i in range(0, data.size(), 4):
				data.encode_float(i, 1e30)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r32f, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer ocean_region_colored (RGBA8)
	if not textures.has("ocean_region_colored"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		data.fill(0)
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba8, view, [data])
		if rid.is_valid():
			textures["ocean_region_colored"] = rid
		else:
			push_error("❌ Échec création texture ocean_region_colored")
	
	print("✅ Textures régions océaniques créées (2x R32UI + 2x R32F + 1x RGBA8)")

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
	if tex_id in ["temperature_colored", "precipitation_colored", "clouds", "ice_caps", "petrole", "region_colored"]:
		img_format = Image.FORMAT_RGBA8
	# Textures R32F (vapeur, flux)
	elif tex_id in ["vapor", "vapor_temp", "river_flux", "flux_temp", "water_paths", "water_paths_temp", "region_cost", "region_cost_temp"]:
		img_format = Image.FORMAT_RF
	# Textures R32UI et RG32I ne peuvent pas être converties directement en Image
	# Utiliser readback_texture_raw() pour ces formats
	# Textures RGBA32F (par défaut: geo, climate, plates, crust_age, resources)
	
	var img := Image.create_from_data(
		resolution.x,
		resolution.y,
		false,
		img_format,
		data
	)
	return img

# === READBACK TEXTURE RAW ===
func readback_texture_raw(tex_id: String) -> PackedByteArray:
	"""
	Lit les données brutes d'une texture GPU.
	Utile pour les formats non-image (R32UI, RG32I).
	"""
	if not textures.has(tex_id):
		push_error("❌ Texture introuvable: ", tex_id)
		return PackedByteArray()
	
	return rd.texture_get_data(textures[tex_id], 0)

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
