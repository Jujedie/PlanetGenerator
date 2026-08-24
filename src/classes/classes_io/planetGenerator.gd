extends RefCounted

class_name PlanetGenerator

signal finished

## ============================================================================
## PLANET GENERATOR
## ============================================================================

var nom             : String
var circonference   : int
var mapStatusLabel  : Label
var cheminSauvegarde: String


# GPU acceleration components
var gpu_orchestrator    : GPUOrchestrator = null
var use_gpu_acceleration: bool            = true
var use_tiled_global_generation: bool     = false
var tiled_pipeline: TiledGlobalSimulationPipeline = null
var _tiled_thread: Thread = null
var _tiled_output_root: String = ""
var _local_macro_sampler: GlobalMacroSampler = null

# Generation parameters (compiled from UI)
var generation_params: Dictionary = {}
var _cleaned_up: bool = false
var _generation_request_id: int = 0

## Constructeur de la classe PlanetGenerator.
##
## Initialise les paramètres de simulation et lie les références de l'interface utilisateur.
## Ne lance pas la génération (voir [method generate_planet]).
##
## @param nom_param: Le nom de la planète (utilisé pour les fichiers de sauvegarde).
## @param rayon: Rayon de la texture en pixels (ex: 1024). Définit la circonférence (2*PI*R).
## @param avg_temperature_param: Température moyenne globale en degrés (base pour le climat).
## @param water_elevation_param: Niveau de la mer (offset ou niveau absolu).
## @param avg_precipitation_param: Facteur global d'humidité (0.0 à 1.0).
## @param elevation_modifier_param: Multiplicateur d'altitude pour le relief (Terrain Scale).
## Le nombre de workers CPU est résolu automatiquement pour l'export PNG ; il
## ne contrôle jamais la file de génération GPU.
## @param atmosphere_type_param: Enum (0=Terre, 1=Lune, etc.) définissant la densité atmosphérique.
## @param renderProgress_param: Référence à la barre de progression de l'UI.
## @param mapStatusLabel_param: Référence au label de statut de l'UI.
## @param nb_avg_cases_param: Nombre de sites de Voronoi pour les plaques tectoniques/régions.
## @param cheminSauvegarde_param: Dossier racine pour la sauvegarde temporaire.
func _init(nom_param: String, generation_param : Dictionary, cheminSauvegarde_param: String = "user://temp/", mapStatusLabel_param: Label = null):

	"""
	PlanetGenerator constructor
	Initializes all parameters and references
	Does NOT start generation (see generate_planet)
	"""

	# Store all parameters
	self.nom                  = nom_param
	self.generation_params    = generation_param

	self.mapStatusLabel       = mapStatusLabel_param
	self.cheminSauvegarde     = cheminSauvegarde_param
	
	# Initialize GPU system
	_init_gpu_system()


## Initialise le sous-système de rendu GPU.
##
## Instancie le [GPUContext] (si nécessaire) et configure le [GPUOrchestrator]
## avec les paramètres compilés. Prépare les textures (VRAM) et les pipelines de shaders.
##
## @return bool: `true` si l'initialisation Vulkan/RenderingDevice a réussi, `false` sinon.
func _init_gpu_system() -> void:
	"""Initialize the monolithic preview path or the maximum-scale tiled path."""
	var global_dimensions: Vector2i = generation_params.get(
		"global_dimensions", generation_params.get("resolution", Vector2i(1024, 512))
	)
	use_tiled_global_generation = bool(generation_params.get("tiled_global_generation", false))
	use_tiled_global_generation = use_tiled_global_generation or TiledGlobalGenerator.should_use_tiled(global_dimensions)
	# Gas giants keep their dedicated atmospheric path; Milestone 5's maximum
	# tiled contract applies to solid-surface planets.
	if int(generation_params.get("planet_type", 0)) == 6:
		use_tiled_global_generation = false
	if use_tiled_global_generation:
		use_gpu_acceleration = true
		_tiled_output_root = cheminSauvegarde.path_join("tiled_dataset")
		print("[PlanetGenerator] Maximum-scale tiled generation enabled: ", global_dimensions)
		return

	var gpu_context = GPUContext.new(generation_params["resolution"])
	if not gpu_context or not gpu_context.rd:
		push_warning("[PlanetGenerator] GPUContext or RD not available")
		use_gpu_acceleration = false
		return
	gpu_orchestrator = GPUOrchestrator.new(gpu_context, generation_params["resolution"], generation_params)
	print("[PlanetGenerator] GPU acceleration enabled: ", generation_params["resolution"])

## Met à jour le label de statut dans l'interface utilisateur.
##
## Cette méthode est thread-safe et utilise [method Object.call_deferred] pour
## manipuler l'UI depuis un thread de génération.
##
## @param map_key: La clé de traduction correspondant à l'étape actuelle (ex: "MAP_TECTONIC").
func update_map_status(map_key: String) -> void:
	"""Update UI status label"""
	if mapStatusLabel != null:
		var map_name = tr(map_key)
		var text = tr("CREATING").format({"map": map_name})
		mapStatusLabel.call_deferred("set_text", text)

# ============================================================================
# MAIN GENERATION ENTRY POINT
# ============================================================================

## ============================================================================
## GPU GENERATION - RENDER THREAD SAFE VERSION
## ============================================================================

## Point d'entrée principal de la génération.
##
## Démarre le processus de génération. Selon la configuration interne, 
## cette méthode initie la séquence GPU ([method generate_planet_gpu]).
func generate_planet() -> bool:
	"""Entry point - routes to the bounded tiled path or legacy GPU path."""
	if _cleaned_up or not use_gpu_acceleration:
		print("[PlanetGenerator] Cancelling generation: GPU acceleration not available")
		return false
	_generation_request_id += 1
	if use_tiled_global_generation:
		if _tiled_thread != null and _tiled_thread.is_started():
			push_warning("[PlanetGenerator] Tiled generation is already running")
			return false
		print("[PlanetGenerator] Starting tiled global generation...")
		tiled_pipeline = TiledGlobalSimulationPipeline.new(generation_params, _tiled_output_root)
		_tiled_thread = Thread.new()
		var err := _tiled_thread.start(_run_tiled_generation_worker.bind(_generation_request_id))
		if err != OK:
			push_error("[PlanetGenerator] Unable to start tiled generation worker: %s" % err)
			_tiled_thread = null
			return false
		return true
	if gpu_orchestrator:
		print("[PlanetGenerator] Starting GPU generation (render thread)...")
		call_deferred("_generate_planet_gpu_deferred", _generation_request_id)
		return true
	return false

func _run_tiled_generation_worker(request_id: int) -> void:
	var report: Dictionary = {}
	if tiled_pipeline != null:
		report = tiled_pipeline.generate()
	call_deferred("_complete_tiled_generation", request_id, report)

func _complete_tiled_generation(request_id: int, report: Dictionary) -> void:
	if _tiled_thread != null and _tiled_thread.is_started():
		_tiled_thread.wait_to_finish()
	_tiled_thread = null
	if request_id != _generation_request_id or _cleaned_up:
		return
	if bool(report.get("ok", false)):
		print("[PlanetGenerator] Tiled global generation complete: ", report.get("manifest", ""))
		emit_signal("finished")
	else:
		push_error("[PlanetGenerator] Tiled generation failed: %s" % report.get("reason", "unknown"))

func cancel_generation(reason: String = "user") -> void:
	if tiled_pipeline != null:
		tiled_pipeline.cancel(reason)
	elif gpu_orchestrator != null and gpu_orchestrator.has_method("request_cancel"):
		gpu_orchestrator.request_cancel(reason)

## Wrapper pour l'exécution différée de la génération GPU.
##
## Permet d'appeler [method generate_planet_gpu] via [method call_deferred]
## pour s'assurer que certaines initialisations contextuelles se font sur le thread principal
## avant de basculer sur le RenderingDevice.
func _generate_planet_gpu_deferred(request_id: int) -> void:
	"""
	GPU generation executed on render thread
	Called via call_deferred from generate_planet()
	"""
	
	if (
		request_id != _generation_request_id
		or _cleaned_up
		or not use_gpu_acceleration
		or not is_instance_valid(gpu_orchestrator)
	):
		print("[PlanetGenerator] Ignoring cancelled deferred GPU generation")
		return

	# Keep the validated orchestrator alive for the synchronous simulation.
	var orchestrator := gpu_orchestrator

	# === INITIAL LOGGING ===
	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION (RENDER THREAD)")
	print("=".repeat(60))
	
	# === FULL SIMULATION ===
	# Execute simulation synchronously on render thread
	orchestrator.run_simulation()

	# A cancelled/replaced request must not notify the UI as completed.
	if request_id != _generation_request_id or _cleaned_up:
		return
	
	# === EXPORT ===
	print("=".repeat(60))
	print("GENERATION COMPLETE")
	print("=".repeat(60) + "\n")
	
	emit_signal("finished")

# ============================================================================
# GPU GENERATION PIPELINE
# ============================================================================

## Exécute la pipeline de génération complète sur GPU (Compute Shaders).
##
## C'est le coeur du nouveau système. Elle exécute séquentiellement :
## 1. Tectonique des plaques (Voronoi + Drift).
## 2. Érosion hydraulique et thermique (Simulation itérative).
## 3. Simulation atmosphérique (Pression, Température).
## 4. Rapatriement des données (Readback).
##
## Émet le signal [signal finished] une fois terminé.
func generate_planet_gpu():
	"""
	GPU-accelerated generation pipeline
	Phase 1: Initialize → Phase 2: Simulate → Phase 3: Export → Phase 4: Visualize
	"""
	
	# === INITIAL LOGGING ===
	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION")
	print("=".repeat(60))
	print("Planet: ", nom)
	print("Resolution: ", generation_params["resolution"])
	print("Seed: ", generation_params["seed"])
	print("=".repeat(60) + "\n")
	
	# === FULL SIMULATION ===
	print("Running full GPU simulation...")
	
	gpu_orchestrator.run_simulation()
	
	# === EXPORT MAPS ===
	print("\n" + "=".repeat(60))
	print("GENERATION COMPLETE")
	print("Total time: ", Time.get_ticks_msec() / 1000.0, " seconds")
	print("=".repeat(60) + "\n")
	
	emit_signal("finished")

## Récupère les textures depuis la VRAM et les convertit en Images CPU.
##
## Appelle [method GPUOrchestrator.get_final_heightmap] et autres getters
## pour extraire les données brutes (PackedByteArray) du GPU et remplir les variables
## membres (elevation_map, water_map, etc.) de cette classe.
func _export_gpu_maps() -> void:
	"""
	Export GPU textures to PNG files using PlanetExporter
	"""
	
	var gpu_context = gpu_orchestrator.gpu
	
	# CRITICAL: Ensure all GPU work is complete
	if not gpu_context or not gpu_context.rd:
		push_error("[PlanetGenerator] GPUContext or RD not available for export")
		return
	
	gpu_context.sync_for_cpu("planet_export")
	
	# Validate texture RIDs
	for texture in gpu_context.textures.values():
		if not texture or texture.is_valid() == false:
			push_error("[PlanetGenerator] ❌ Missing texture RID during export")
			return
	
	print("[PlanetGenerator] Exporting textures...")
	for tex_id in gpu_context.textures.keys():
		print("  Texture ID: ", tex_id, " RID: ", gpu_context.textures[tex_id])
	
	# Create exporter and export all maps
	var exporter = PlanetExporter.new()
	var exported_files = exporter.export_maps(gpu_context, "user://temp/", generation_params)
	
	# Load exported images into legacy properties
	for map_type in exported_files:
		var file_path = exported_files[map_type]
		var img = Image.new()
		
		if img.load(file_path) == OK:
			match map_type:
				"elevation":
					self.elevation_map = img
				"elevation_alt":
					self.elevation_map_alt = img
			
			print("[PlanetGenerator] Loaded ", map_type, ": ", img.get_width(), "x", img.get_height())
		else:
			push_warning("[PlanetGenerator] Failed to load ", map_type, " from ", file_path)
	
	print("[PlanetGenerator] Maps exported to user://temp/")

# ============================================================================
# PUBLIC API FOR EXTERNAL COMPONENTS
# ============================================================================

## Récupère les identifiants de texture (RID) du GPU.
##
## Utile pour le débogage ou pour afficher les textures directement dans un Viewport
## sans repasser par le CPU (via Texture2DRD).
##
## @return Dictionary: Un dictionnaire { "geo": RID, "atmo": RID, ... }.
func get_gpu_texture_rids() -> Dictionary:
	"""
	Get GPU texture RIDs for direct 3D binding
	
	Returns:
		Dictionary with keys: "geo", "atmo"
	"""
	if not gpu_orchestrator:
		return {}
	
	var gpu_context = gpu_orchestrator.gpu
	if not gpu_context or not gpu_context.rd:
		return {}
	
	# Return texture RIDs from GPU context texturesID

	var texture_rids = {}
	for tex_id in gpu_context.textures.keys():
		texture_rids[tex_id] = gpu_context.textures[tex_id]

	return texture_rids

## Exporte toutes les cartes générées vers un dossier spécifique.
##
## @param directory_path: Le chemin absolu ou relatif (user://) du dossier de destination.
## @return bool: `true` si toutes les sauvegardes ont réussi.
func export_to_directory(output_dir: String) -> void:
	"""Export monolithic PNGs or copy the completed raw tiled dataset."""
	print("[PlanetGenerator] Exporting to: ", output_dir)
	if use_tiled_global_generation and tiled_pipeline != null:
		if not tiled_pipeline.export_dataset(output_dir):
			push_warning("[PlanetGenerator] Tiled export skipped: dataset is incomplete")
	elif use_gpu_acceleration and gpu_orchestrator:
		var exporter = PlanetExporter.new()
		exporter.export_maps(gpu_orchestrator.gpu, output_dir, generation_params)
	else:
		push_warning("[PlanetGenerator] Export skipped: generation resources are unavailable")
	print("[PlanetGenerator] Export complete")

## Generate one deterministic high-resolution 1 km² local terrain zone.
## Administrative layers never influence this result. On maximum-scale planets
## the macro sampler reads the authoritative M5 tile store instead of requiring
## monolithic textures to be rebuilt in RAM/VRAM.
func generate_local_zone(global_cell: Vector2i, resolution: int = LocalZoneGenerator.DEFAULT_RESOLUTION,
		use_cache: bool = true) -> Dictionary:
	if _cleaned_up:
		return {}
	var sampler: GlobalMacroSampler = _local_macro_sampler
	if sampler == null or not sampler.is_valid():
		if use_tiled_global_generation:
			sampler = GlobalMacroSampler.from_tiled_dataset(_tiled_output_root, generation_params)
		elif gpu_orchestrator != null and gpu_orchestrator.gpu != null:
			sampler = GlobalMacroSampler.from_gpu(gpu_orchestrator.gpu, generation_params)
		if sampler != null and sampler.is_valid():
			_local_macro_sampler = sampler
	if sampler == null or not sampler.is_valid():
		push_warning("[PlanetGenerator] Local zone unavailable: global authoritative layers are not ready")
		return {}
	var cache: LocalZoneCache = null
	if use_cache:
		cache = LocalZoneCache.new(cheminSauvegarde.path_join("local_zones"))
	return LocalZoneGenerator.generate_zone(global_cell, sampler, generation_params, resolution, cache)

## Save human-readable PNG previews of selected local layers. The authoritative
## cached zone remains raw data; these PNGs are diagnostic/game-tooling output.
func export_local_zone_previews(zone: Dictionary, output_dir: String) -> Dictionary:
	return LocalZoneDebugExporter.export_previews(zone, output_dir)

## Sauvegarde les cartes générées dans le dossier temporaire par défaut.
func save_maps():
	"""Legacy save to default directory"""
	export_to_directory(cheminSauvegarde)


## Libère explicitement toutes les ressources GPU propres à cette planète
## avant qu'un nouveau générateur soit construit. La méthode est idempotente
## afin que remplacement et fermeture puissent tous deux l'appeler.
func cleanup() -> void:
	if _cleaned_up:
		return
	_generation_request_id += 1
	_cleaned_up = true
	_local_macro_sampler = null
	if tiled_pipeline != null:
		tiled_pipeline.cancel("cleanup")
	if _tiled_thread != null and _tiled_thread.is_started():
		_tiled_thread.wait_to_finish()
	_tiled_thread = null
	if tiled_pipeline != null:
		tiled_pipeline.cleanup()
		tiled_pipeline = null
	if gpu_orchestrator:
		gpu_orchestrator.cleanup()
		gpu_orchestrator = null
	use_gpu_acceleration = false

## Retourne la liste des chemins de fichiers des cartes générées.
##
## Nettoie d'abord les fichiers temporaires existants, sauvegarde les nouvelles cartes,
## et retourne les chemins. Utilisé par le [Master] node pour charger les textures.
##
## @return Array[String]: Liste des chemins complets vers les fichiers PNG générés.
func getMaps() -> Array[String]:
	"""Get temporary display maps. Raw tiled datasets are rendered by Milestone 6."""
	if _cleaned_up:
		return []
	if use_tiled_global_generation:
		# M5 deliberately stores raw physical tiles only; returning the manifest
		# as an image path would make the legacy UI attempt to decode JSON as PNG.
		return []
	if not is_instance_valid(gpu_orchestrator):
		push_warning("[PlanetGenerator] Cannot retrieve maps after cleanup")
		return []
	deleteImagesTemps()
	var temp_dir = "user://temp/"
	var exported_files = gpu_orchestrator.export_all_maps(temp_dir)
	var lstChemin: Array[String] = []
	for file_path in exported_files.values():
		lstChemin.append(file_path)
	return lstChemin

## Sauvegarde une image unique dans le dossier temporaire.
##
## Méthode statique utilitaire. Crée le dossier si nécessaire.
##
## @param image: L'objet Image à sauvegarder.
## @param file_name: Le nom du fichier (ex: "heightmap.png").
## @param temp_dir: Le répertoire de destination.
## @return String: Le chemin complet du fichier sauvegardé, ou une chaîne vide en cas d'erreur.
static func save_image_temp(image: Image, file_name: String, temp_dir: String) -> String:
	"""Save image to temporary directory"""
	if not image:
		return ""
	
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_recursive_absolute(temp_dir)
	
	var path = temp_dir + file_name
	image.save_png(path)
	return path

## Vide le dossier temporaire.
##
## Supprime tous les fichiers présents dans "user://temp/" pour éviter l'accumulation
## de données inutiles entre deux générations.
static func deleteImagesTemps():
	"""Clear temporary directory"""
	var dir = DirAccess.open("user://temp/")
	if dir == null:
		DirAccess.make_dir_absolute("user://temp/")
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	dir = DirAccess.open("user://temp/ressource/")
	if dir == null:
		DirAccess.make_dir_absolute("user://temp/ressource/")
		return
	
	dir.list_dir_begin()
	file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
