extends RefCounted
class_name GPUContext

# Conserver un seul device Vulkan local pour toute l'application. Certains
# pilotes imposent une limite pratique au nombre de créations/destructions
# successives, même quand tous les RIDs ont été correctement libérés.
static var _shared_rd: RenderingDevice = null
static var _shared_rd_validated: bool = false

# === CONSTANTES DE CONFIGURATION ===
const FORMAT_STATE = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const FORMAT_RGBA8 = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
const FORMAT_RGBA8UI = RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
const FORMAT_R32F = RenderingDevice.DATA_FORMAT_R32_SFLOAT
const FORMAT_R32UI = RenderingDevice.DATA_FORMAT_R32_UINT
const FORMAT_RG32I = RenderingDevice.DATA_FORMAT_R32G32_SINT

# Milestone 3 lifecycle contract. Textures are grouped by their last kind of
# consumer so temporary simulation state can be discarded before CPU export.
const TEXTURE_LIFECYCLE := {
	"permanent": ["geo"],
	"next_phase": [
		"climate", "plates", "river_flux", "water_mask", "region_map",
		"ocean_region_map", "biome_id", "river_biome_id", "ocean_reachable",
	],
	"temporary": [
		"temp_buffer", "crust_age", "crust_age_temp", "geo_temp", "flux_temp",
		"vapor", "vapor_temp", "water_component",
		"river_sources", "flow_direction",
		"region_map_temp", "region_cost",
		"region_cost_temp", "ocean_region_map_temp", "ocean_region_cost",
		"ocean_region_cost_temp", "administrative_edge_cost", "biome_id_temp", "biome_colored_temp",
		"gas_velocity", "gas_dye_a", "gas_dye_b",
	],
	"export_only": [
		"temperature_colored", "precipitation_colored", "clouds", "ice_caps",
		"petrole", "resources", "region_colored", "ocean_region_colored",
		"biome_colored", "final_map", "water_colored",
	],
	"debug_only": [],
}

const TERRESTRIAL_EXPORT_TEXTURES := [
	"geo", "plates", "river_flux", "flow_direction", "water_mask", "region_map",
	# Milestone 6 reads the authoritative biome IDs to render palette-driven
	# cartography after prepare_for_export(). Keeping only biome_colored made the
	# cartographic exporter silently skip every terrestrial planet.
	"biome_id", "ocean_region_map", "river_biome_id", "ocean_reachable",
	"temperature_colored", "precipitation_colored", "clouds", "ice_caps",
	"petrole", "resources", "region_colored", "ocean_region_colored",
	"biome_colored", "final_map", "water_colored",
]
const GAS_EXPORT_TEXTURES := ["final_map"]

# IDs des textures GPU utilisées dans la pipeline
# geo : GeoTexture (RGBA32F) - R=height, G=bedrock, B=sediment, A=water_height
# climate : ClimateTexture (RGBA32F) - R=temperature, G=humidity, B=windX, A=windY
# temp_buffer : Buffer temporaire pour ping-pong
# plates : PlateTexture (RGBA32F) - R=plate_id, G=velocity_x, B=velocity_y, A=convergence_type
# crust_age : CrustAgeTexture (RGBA32F) - R=distance_km, G=age_ma, B=subsidence, A=valid
# crust_age_temp : Buffer ping-pong du Jump Flooding. Une seconde texture est
# obligatoire : lire et écrire la même image pendant une passe JFA rend le
# résultat dépendant de l'ordre d'exécution des workgroups GPU.
static var TextureID : Array[String] = ["geo", "climate", "temp_buffer", "plates", "crust_age", "crust_age_temp"]

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
# clouds : (RGBA8) - nuages en alpha droit (RGB=blanc, A=opacité, ciel transparent)
# ice_caps : (RGBA8) - banquise maritime uniquement (alpha=concentration)
static var TextureID_Climat : Array[String] = ["vapor", "vapor_temp", "temperature_colored", "precipitation_colored", "clouds", "ice_caps"]

# Textures Étape 5 - Ressources & Pétrole
# petrole : (RGBA8) - carte de pétrole (noir/transparent)
# resources : (RGBA8UI) - R=resource_id, G=intensity, B=cluster_id, A=presence
static var TextureID_Resources : Array[String] = ["petrole", "resources"]

# Textures Étape 2.5 - Classification des Eaux & Rivières
# water_mask : (R8) - Type d'eau : 0=terre, 1=eau salée, 2=eau douce
# water_component : (RG32I) - Coordonnées seed JFA pour composantes connexes
# river_sources : (R32UI) - IDs des sources de rivières (legacy)
# river_flux : (R32F) - Intensité du flux des rivières
# flow_direction : (R8UI) - Direction d'écoulement D8 (0-7, 255=puits)
# ocean_reachable : (R8UI) - Connectivité à l'océan (0=non, 1=oui)
static var TextureID_Water : Array[String] = ["water_mask", "water_component", "river_sources", "river_flux", "river_biome_id", "flow_direction", "ocean_reachable"]

# Textures Étape 4 - Régions administratives
# region_map : (R32UI) - ID de région par pixel (0xFFFFFFFF = non assigné)
# region_cost : (R32F) - Coût accumulé depuis le seed (pour Dijkstra)
# region_cost_temp : (R32F) - Buffer ping-pong pour propagation
# region_colored : (RGBA8) - Couleur finale des régions pour export
static var TextureID_Region : Array[String] = ["region_map", "region_cost", "region_cost_temp", "region_colored"]

# Textures Étape 4.1 - Biomes
# biome_id : (R32UI) - ID du biome par pixel
# biome_id_temp : (R32UI) - Buffer ping-pong pour lissage
# biome_colored : (RGBA8) - Couleur finale du biome pour export/final_map
# biome_colored_temp : (RGBA8) - Buffer ping-pong pour lissage
static var TextureID_Biome : Array[String] = ["biome_id", "biome_id_temp", "biome_colored", "biome_colored_temp"]

# Textures Étape 6 - Final Map & Water Colored
# final_map : (RGBA8) - Carte finale combinée (biome + rivières + relief + cryosphère)
# water_colored : (RGBA8) - Carte colorée des eaux (eau salée/douce)
static var TextureID_Final : Array[String] = ["final_map", "water_colored"]

# === MEMBRES ===
var rd: RenderingDevice
var textures: Dictionary = {}
var shaders: Dictionary = {}
var pipelines: Dictionary = {}
var uniform_sets: Dictionary = {}
var resolution: Vector2i
var _cleaned_up: bool = false
var _gpu_commands_pending: bool = false
var _gpu_work_in_flight: bool = false
var _deferred_free_rids: Array[RID] = []
var _texture_byte_size_cache: Dictionary = {}
var metrics: Dictionary = {}

func _init(resolution_param: Vector2i) -> void:
	self.resolution = resolution_param
	reset_metrics()

	if _shared_rd:
		rd = _shared_rd
	else:
		rd = RenderingServer.create_local_rendering_device()
		if rd:
			_shared_rd = rd
	
	if not rd:
		push_error("❌ FATAL: Impossible de créer le RenderingDevice local")
		push_error("  Causes possibles:")
		push_error("    - GPU ne supporte pas Vulkan/Metal")

		push_error("    - Drivers graphiques obsolètes")
		push_error("    - Godot lancé en mode headless sans GPU")
		return
	
	# Validate the shared local device only once. Creating a throw-away texture
	# for every PlanetGenerator was measurable overhead in 50-run release tests
	# and did not add safety after the device had already passed validation.
	if not _shared_rd_validated:
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
			if _shared_rd == rd:
				_shared_rd = null
			rd.free()
			rd = null
			return
		rd.free_rid(test_texture)
		_shared_rd_validated = true
		print("✅ RenderingDevice validé et fonctionnel")
	else:
		print("✅ RenderingDevice partagé déjà validé")

	# Créer les textures de travail
	_initialize_textures()
	_sample_memory_peaks()

func reset_metrics() -> void:
	metrics = {
		"queued_compute_lists": 0,
		"submit_count": 0,
		"sync_count": 0,
		"sync_time_ms": 0.0,
		"readback_count": 0,
		"readback_time_ms": 0.0,
		"readback_bytes": 0,
		"peak_vram_bytes": 0,
		"peak_system_ram_bytes": 0,
		"released_texture_bytes": 0,
		"texture_size_cache_hits": 0,
		"texture_size_cache_misses": 0,
	}

func submit_gpu_work() -> void:
	if not rd:
		return
	# compute_list_end() has queued the command list on the local device. Keep
	# collecting lists until a CPU dependency requires one real submit+sync.
	_gpu_commands_pending = true
	metrics["queued_compute_lists"] = int(metrics.get("queued_compute_lists", 0)) + 1

func release_rid(rid: RID) -> void:
	if not rd or not rid.is_valid():
		return
	_forget_rid_metrics(rid)
	if _gpu_commands_pending or _gpu_work_in_flight:
		_deferred_free_rids.append(rid)
	else:
		rd.free_rid(rid)

func _flush_deferred_frees() -> void:
	var freed_ids: Dictionary = {}
	for rid in _deferred_free_rids:
		var rid_id: int = rid.get_id()
		if rid.is_valid() and not freed_ids.has(rid_id):
			rd.free_rid(rid)
			freed_ids[rid_id] = true
	_deferred_free_rids.clear()

func _free_unique_rids(rids: Array) -> void:
	var freed_ids: Dictionary = {}
	for rid in rids:
		if not rid or not rid.is_valid():
			continue
		var rid_id: int = rid.get_id()
		if freed_ids.has(rid_id):
			continue
		_forget_rid_metrics(rid)
		rd.free_rid(rid)
		freed_ids[rid_id] = true

func _free_valid_uniform_sets() -> void:
	var freed_ids: Dictionary = {}
	for rid in uniform_sets.values():
		if not rid or not rid.is_valid() or not rd.uniform_set_is_valid(rid):
			continue
		var rid_id: int = rid.get_id()
		if freed_ids.has(rid_id):
			continue
		rd.free_rid(rid)
		freed_ids[rid_id] = true

## Waits only at a real CPU dependency (readback, CPU solver, export, cleanup).
func sync_for_cpu(reason: String = "cpu_dependency") -> void:
	if not rd or (not _gpu_commands_pending and not _gpu_work_in_flight):
		return
	if _gpu_commands_pending:
		rd.submit()
		_gpu_commands_pending = false
		_gpu_work_in_flight = true
		metrics["submit_count"] = int(metrics.get("submit_count", 0)) + 1
	var started_usec := Time.get_ticks_usec()
	rd.sync()
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_gpu_work_in_flight = false
	metrics["sync_count"] = int(metrics.get("sync_count", 0)) + 1
	metrics["sync_time_ms"] = float(metrics.get("sync_time_ms", 0.0)) + elapsed_ms
	metrics["last_sync_reason"] = reason
	_flush_deferred_frees()
	_sample_memory_peaks()

func get_vram_usage_bytes() -> int:
	var total_bytes := 0
	for texture_rid in textures.values():
		if not texture_rid or not texture_rid.is_valid():
			continue
		total_bytes += _texture_size_bytes(texture_rid)
	return total_bytes

func _texture_size_bytes(texture_rid: RID) -> int:
	var rid_id := texture_rid.get_id()
	if _texture_byte_size_cache.has(rid_id):
		metrics["texture_size_cache_hits"] = int(metrics.get("texture_size_cache_hits", 0)) + 1
		return int(_texture_byte_size_cache[rid_id])
	metrics["texture_size_cache_misses"] = int(metrics.get("texture_size_cache_misses", 0)) + 1
	var texture_format := rd.texture_get_format(texture_rid)
	var byte_size := texture_format.width * texture_format.height * _bytes_per_pixel(texture_format.format)
	_texture_byte_size_cache[rid_id] = byte_size
	return byte_size

func _forget_rid_metrics(rid: RID) -> void:
	if rid.is_valid():
		_texture_byte_size_cache.erase(rid.get_id())

func get_vram_usage() -> String:
	return "VRAM: %.2f MB" % (get_vram_usage_bytes() / 1024.0 / 1024.0)

func get_metrics_snapshot() -> Dictionary:
	_sample_memory_peaks()
	var snapshot := metrics.duplicate(true)
	snapshot["current_vram_bytes"] = get_vram_usage_bytes() if rd else 0
	snapshot["texture_count"] = textures.size()
	return snapshot

func get_texture_lifecycle() -> Dictionary:
	return TEXTURE_LIFECYCLE.duplicate(true)

func _sample_memory_peaks() -> void:
	if not metrics:
		return
	var current_vram := get_vram_usage_bytes() if rd else 0
	metrics["peak_vram_bytes"] = maxi(
		int(metrics.get("peak_vram_bytes", 0)), current_vram
	)
	var current_ram := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	metrics["peak_system_ram_bytes"] = maxi(
		int(metrics.get("peak_system_ram_bytes", 0)), current_ram
	)

func _bytes_per_pixel(data_format: int) -> int:
	match data_format:
		FORMAT_STATE:
			return 16
		FORMAT_RG32I:
			return 8
		FORMAT_RGBA8, FORMAT_RGBA8UI, FORMAT_R32F, FORMAT_R32UI:
			return 4
		RenderingDevice.DATA_FORMAT_R8_UINT:
			return 1
		_:
			push_warning("Unknown texture format in VRAM accounting: " + str(data_format))
			return 16

## Drops every texture that has reached its final GPU consumer. Exporters keep
## only their required source layers, preventing stale next-phase state from
## occupying VRAM during PNG conversion.
func prepare_for_export(gas_giant: bool = false) -> Dictionary:
	sync_for_cpu("prepare_for_export")
	var released_compute_resources := (
		uniform_sets.size() + pipelines.size() + shaders.size()
	)
	# Export is CPU-only. Descriptor sets must be released before any texture
	# they reference; pipelines must be released before their shaders.
	_free_valid_uniform_sets()
	uniform_sets.clear()
	_free_unique_rids(pipelines.values())
	pipelines.clear()
	_free_unique_rids(shaders.values())
	shaders.clear()
	var keep: Array = GAS_EXPORT_TEXTURES if gas_giant else TERRESTRIAL_EXPORT_TEXTURES
	var released_names: Array[String] = []
	var before_bytes := get_vram_usage_bytes()
	for texture_name in textures.keys().duplicate():
		if texture_name in keep:
			continue
		var texture_rid: RID = textures[texture_name]
		if texture_rid.is_valid():
			_forget_rid_metrics(texture_rid)
			rd.free_rid(texture_rid)
		textures.erase(texture_name)
		released_names.append(str(texture_name))
	var released_bytes := maxi(before_bytes - get_vram_usage_bytes(), 0)
	metrics["released_texture_bytes"] = (
		int(metrics.get("released_texture_bytes", 0)) + released_bytes
	)
	return {
		"released_names": released_names,
		"released_bytes": released_bytes,
		"released_compute_resources": released_compute_resources,
		"remaining_bytes": get_vram_usage_bytes(),
	}

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
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
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
	
	# Format RGBA8UI : resource_id, intensité, cluster et présence tiennent
	# chacun dans un octet. L'ancien RGBA32F consommait 4x plus de VRAM.
	var format_rgba8ui := RDTextureFormat.new()
	format_rgba8ui.width = resolution.x
	format_rgba8ui.height = resolution.y
	format_rgba8ui.format = FORMAT_RGBA8UI
	format_rgba8ui.usage_bits = (
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
	
	# Créer texture resources (RGBA8UI - 4 bytes par pixel)
	if not textures.has("resources"):
		var data = PackedByteArray()
		data.resize(resolution.x * resolution.y * 4)
		data.fill(0)
		
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_rgba8ui, view, [data])
		
		if not rid.is_valid():
			push_error("❌ Échec création texture resources")
		else:
			textures["resources"] = rid
	
	print("✅ Textures ressources créées (1x RGBA8 + 1x RGBA8UI)")

# === CRÉATION DES TEXTURES EAUX (Étape 2.5) ===
func initialize_water_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 2.5 (Classification des Eaux & Rivières).
	Appelé par l'orchestrateur avant la phase de classification des eaux.
	
	Textures créées:
	- water_mask (R8) : Type d'eau (0=terre, 1=salée, 2=douce)
	- water_component (RG32I) : labels temporaires des cellules d'eau
	- river_sources (R32UI) : IDs des points sources (legacy)
	- river_flux (R32F) : Flux accumulé des rivières
	- flow_direction (R8UI) : Direction d'écoulement D8 (0-7, 255=puits)
	- ocean_reachable (R8UI) : Classe de rivière exportée
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
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
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
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
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
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer water_mask (R8 - 1 byte par pixel)
	# IMPORTANT : Toujours remettre à zéro pour éviter les données obsolètes
	# entre deux générations successives
	var wm_data = PackedByteArray()
	wm_data.resize(resolution.x * resolution.y)
	wm_data.fill(0)
	if textures.has("water_mask") and textures["water_mask"].is_valid():
		# Texture existe déjà → écraser avec des zéros
		rd.texture_update(textures["water_mask"], 0, wm_data)
	else:
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r8, view, [wm_data])
		if rid.is_valid():
			textures["water_mask"] = rid
		else:
			push_error("❌ Échec création texture water_mask")
	
	# Créer water_component (RG32I - 8 bytes par pixel)
	for tex_id in ["water_component"]:
		var wc_data = PackedByteArray()
		wc_data.resize(resolution.x * resolution.y * 8)
		# Initialiser à -1 (invalide)
		for i in range(0, wc_data.size(), 4):
			wc_data.encode_s32(i, -1)
		if textures.has(tex_id) and textures[tex_id].is_valid():
			rd.texture_update(textures[tex_id], 0, wc_data)
		else:
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_rg32i, view, [wc_data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer river_sources (R32UI - 4 bytes par pixel)
	var rs_data = PackedByteArray()
	rs_data.resize(resolution.x * resolution.y * 4)
	rs_data.fill(0)
	if textures.has("river_sources") and textures["river_sources"].is_valid():
		rd.texture_update(textures["river_sources"], 0, rs_data)
	else:
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [rs_data])
		if rid.is_valid():
			textures["river_sources"] = rid
		else:
			push_error("❌ Échec création texture river_sources")
	
	# Créer river_flux (R32F - 4 bytes par pixel)
	for tex_id in ["river_flux"]:
		var rf_data = PackedByteArray()
		rf_data.resize(resolution.x * resolution.y * 4)
		rf_data.fill(0)
		if textures.has(tex_id) and textures[tex_id].is_valid():
			rd.texture_update(textures[tex_id], 0, rf_data)
		else:
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r32f, view, [rf_data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer river_biome_id (R32UI - 4 bytes par pixel, initialisé à 0xFFFFFFFF = pas de rivière)
	var rbi_data = PackedByteArray()
	rbi_data.resize(resolution.x * resolution.y * 4)
	for i in range(0, rbi_data.size(), 4):
		rbi_data.encode_u32(i, 0xFFFFFFFF)
	if textures.has("river_biome_id") and textures["river_biome_id"].is_valid():
		rd.texture_update(textures["river_biome_id"], 0, rbi_data)
	else:
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r32ui, view, [rbi_data])
		if rid.is_valid():
			textures["river_biome_id"] = rid
		else:
			push_error("❌ Échec création texture river_biome_id")

	# Créer flow_direction (R8UI - 1 byte par pixel, direction D8 : 0-7, 255=puits)
	var fd_data = PackedByteArray()
	fd_data.resize(resolution.x * resolution.y)
	fd_data.fill(255)  # 255 = DIR_SINK par défaut
	if textures.has("flow_direction") and textures["flow_direction"].is_valid():
		rd.texture_update(textures["flow_direction"], 0, fd_data)
	else:
		var view := RDTextureView.new()
		var rid := rd.texture_create(format_r8, view, [fd_data])
		if rid.is_valid():
			textures["flow_direction"] = rid
		else:
			push_error("❌ Échec création texture flow_direction")

	# Créer ocean_reachable (R8UI - 1 byte par pixel)
	for tex_id in ["ocean_reachable"]:
		var or_data = PackedByteArray()
		or_data.resize(resolution.x * resolution.y)
		or_data.fill(0)  # 0 = non connecté par défaut
		if textures.has(tex_id) and textures[tex_id].is_valid():
			rd.texture_update(textures[tex_id], 0, or_data)
		else:
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r8, view, [or_data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)

	print("✅ Textures eaux créées (3x R8 + 1x RG32I + 2x R32UI + 1x R32F)")


func _ensure_administrative_edge_cost_texture() -> void:
	# One transient RGBA32F texture stores the four static cardinal traversal
	# costs used by both land and ocean administration. It is overwritten before
	# each phase, so one allocation is enough for both systems.
	if textures.has("administrative_edge_cost") and textures["administrative_edge_cost"].is_valid():
		return
	var format := RDTextureFormat.new()
	format.width = resolution.x
	format.height = resolution.y
	format.format = FORMAT_STATE
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	var view := RDTextureView.new()
	var rid := rd.texture_create(format, view)
	if rid.is_valid():
		textures["administrative_edge_cost"] = rid
	else:
		push_error("❌ Échec création texture administrative_edge_cost")

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
	_ensure_administrative_edge_cost_texture()
	
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
	_ensure_administrative_edge_cost_texture()
	
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

# === CRÉATION DES TEXTURES BIOMES (Étape 4.1) ===
func initialize_biome_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 4.1 (Classification des Biomes).
	Appelé par l'orchestrateur avant la phase de classification des biomes.
	
	Textures créées:
	- biome_id (R32UI) : ID du biome par pixel
	- biome_id_temp (R32UI) : Buffer ping-pong pour lissage
	- biome_colored (RGBA8) : Couleur finale du biome pour export
	- biome_colored_temp (RGBA8) : Buffer ping-pong pour lissage
	"""
	
	# Format R32UI pour IDs de biome (4 bytes par pixel)
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
	
	# Format RGBA8 pour couleur biome (4 bytes par pixel)
	var format_rgba8 := RDTextureFormat.new()
	format_rgba8.width = resolution.x
	format_rgba8.height = resolution.y
	format_rgba8.format = FORMAT_RGBA8
	format_rgba8.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	# Créer biome_id et biome_id_temp (R32UI - 4 bytes par pixel)
	for tex_id in ["biome_id", "biome_id_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			data.fill(0)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_r32ui, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	# Créer biome_colored et biome_colored_temp (RGBA8 - 4 bytes par pixel)
	for tex_id in ["biome_colored", "biome_colored_temp"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			data.fill(0)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_rgba8, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	print("✅ Textures biomes créées (2x R32UI + 2x RGBA8)")

# === CRÉATION DES TEXTURES FINAL MAP (Étape 6) ===
func initialize_final_map_textures() -> void:
	"""
	Initialise les textures spécifiques à l'étape 6 (Final Map).
	Appelé par l'orchestrateur avant la phase de génération de la carte finale.
	
	Textures créées:
	- final_map (RGBA8) : Carte finale combinée (biome + rivières + relief + cryosphère)
	- water_colored (RGBA8) : Carte colorée des eaux (eau salée/douce)
	"""
	
	# Format RGBA8 pour cartes colorées (4 bytes par pixel)
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
	
	# Créer final_map et water_colored (RGBA8 - 4 bytes par pixel)
	for tex_id in ["final_map", "water_colored"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 4)
			data.fill(0)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_rgba8, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)
	
	print("✅ Textures final map créées (2x RGBA8)")

# === CHARGEMENT DES SHADERS (SÉCURISÉ) ===
func load_compute_shader(glsl_path: String, shader_name: String) -> bool:
	# Désactiver la vérification d'existence du fichier pour compatibilité pour les versions prod
	#if not FileAccess.file_exists(glsl_path):
	#	push_error("❌ SHADER NOT FOUND: " + glsl_path)
	#	return false

	var shader_file = load(glsl_path)
	if not shader_file:
		push_error("❌ Échec chargement fichier: " + glsl_path)
		return false

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_spirv:
		push_error("❌ Pas de SPIR-V disponible: " + shader_name)
		return false

	# Surface the source-level compiler error before asking RenderingDevice to
	# create a shader from invalid bytecode. This avoids the generic
	# "errored bytecode" message hiding the actual GLSL line.
	var compile_error := shader_spirv.get_stage_compile_error(
		RenderingDevice.SHADER_STAGE_COMPUTE
	)
	if not compile_error.is_empty():
		push_error("❌ GLSL compute compilation failed [%s]:\n%s" % [
			shader_name, compile_error
		])
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
	submit_gpu_work()

# === READBACK TEXTURE ===
func readback_texture(tex_id: String) -> Image:
	if not textures.has(tex_id):
		push_error("❌ Texture introuvable: ", tex_id)
		return null
	
	var data := readback_texture_raw(tex_id)
	
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
	# Textures RGBA32F (par défaut: geo, climate, plates, crust_age)
	
	var img := Image.create_from_data(
		resolution.x,
		resolution.y,
		false,
		img_format,
		data
	)
	return img

# === CRÉATION DES TEXTURES GAZ GÉANTE MULTI-PASSES ===
func initialize_gas_giant_textures() -> void:
	"""
	Initialise les textures du pipeline gazeux multi-passes :
	- gas_velocity (RGBA32F) : champ de vélocité statique (R=vx, G=vy, B=vorticité)
	- gas_dye_a / gas_dye_b (RGBA32F) : colorant advecté en ping-pong
	"""
	var format_rgba32f := RDTextureFormat.new()
	format_rgba32f.width = resolution.x
	format_rgba32f.height = resolution.y
	format_rgba32f.format = FORMAT_STATE
	format_rgba32f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	for tex_id in ["gas_velocity", "gas_dye_a", "gas_dye_b"]:
		if not textures.has(tex_id):
			var data = PackedByteArray()
			data.resize(resolution.x * resolution.y * 16)
			data.fill(0)
			var view := RDTextureView.new()
			var rid := rd.texture_create(format_rgba32f, view, [data])
			if rid.is_valid():
				textures[tex_id] = rid
			else:
				push_error("❌ Échec création texture " + tex_id)

	print("✅ Textures gaz géante (multi-passes) créées (3x RGBA32F)")

# === READBACK TEXTURE RAW ===
func readback_texture_raw(tex_id: String) -> PackedByteArray:
	"""
	Lit les données brutes d'une texture GPU.
	Utile pour les formats non-image (R32UI, RG32I).
	"""
	if not textures.has(tex_id):
		push_error("❌ Texture introuvable: ", tex_id)
		return PackedByteArray()
	
	sync_for_cpu("readback:" + tex_id)
	var started_usec := Time.get_ticks_usec()
	var data := rd.texture_get_data(textures[tex_id], 0)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	metrics["readback_count"] = int(metrics.get("readback_count", 0)) + 1
	metrics["readback_time_ms"] = float(metrics.get("readback_time_ms", 0.0)) + elapsed_ms
	metrics["readback_bytes"] = int(metrics.get("readback_bytes", 0)) + data.size()
	_sample_memory_peaks()
	return data

# === NETTOYAGE ===
func cleanup() -> void:
	"""Libère les RIDs et la référence au RenderingDevice une seule fois."""
	if _cleaned_up:
		return
	_cleaned_up = true

	# Vérifier que le RenderingDevice est toujours valide
	if not rd:
		print("⚠️ RenderingDevice déjà libéré, nettoyage ignoré")
		return

	sync_for_cpu("cleanup")
	_flush_deferred_frees()
	
	# Libérer les ressources dans l'ordre inverse de création
	# 1. Uniform sets (dépendent des shaders et textures)
	_free_valid_uniform_sets()
	uniform_sets.clear()
	
	# 2. Pipelines (dépendent des shaders)
	_free_unique_rids(pipelines.values())
	pipelines.clear()
	
	# 3. Shaders
	_free_unique_rids(shaders.values())
	shaders.clear()
	
	# 4. Textures (indépendantes)
	_free_unique_rids(textures.values())
	textures.clear()
	_texture_byte_size_cache.clear()
	metrics["current_vram_bytes"] = 0

	# Le device partagé reste vivant pour la prochaine génération ; seule la
	# référence de ce contexte terminé est relâchée.
	rd = null
	
	print("✅ Ressources GPU libérées proprement")


## Alias conservé pour les anciens appels internes.
func _exit_tree() -> void:
	cleanup()


## À appeler uniquement après le nettoyage du dernier GPUContext actif.
static func shutdown_shared_device() -> void:
	if not _shared_rd:
		return

	# RenderingServer.create_local_rendering_device() returns an Object rather
	# than a RefCounted resource. Dropping the static reference alone therefore
	# leaves the device and its internal worker objects alive until process exit.
	var device_to_free := _shared_rd
	_shared_rd = null
	_shared_rd_validated = false
	device_to_free.free()
