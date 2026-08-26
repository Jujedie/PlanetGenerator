extends RefCounted

class_name PlanetGenerator

signal finished
signal generation_progress(phase: String, completed: int, total: int)
signal generation_cancelled(reason: String)

## ============================================================================
## PLANET GENERATOR
## ============================================================================

var nom             : String
var circonference   : int
var mapStatusLabel  : Label
var cheminSauvegarde: String
var _generation_output_root: String


# GPU acceleration components
var gpu_orchestrator    : GPUOrchestrator = null
var use_gpu_acceleration: bool            = true
var use_tiled_global_generation: bool     = false
var tiled_pipeline: TiledGlobalSimulationPipeline = null
var _tiled_thread: Thread = null
var _tiled_output_root: String = ""
var _monolithic_job_active: bool = false
var _cached_display_maps: Array[String] = []
var _cached_export_files: Dictionary = {}
var _cancel_mutex: Mutex = Mutex.new()
var _cancel_requested: bool = false
var _cancel_reason: String = ""

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
	self.generation_params    = generation_param.duplicate(true)
	self.generation_params["planet_name"] = nom_param

	self.mapStatusLabel       = mapStatusLabel_param
	self.cheminSauvegarde     = cheminSauvegarde_param
	self._generation_output_root = cheminSauvegarde_param
	
	# Initialize GPU system
	_init_gpu_system()


## Initialise le sous-système de rendu GPU.
##
## Instancie le [GPUContext] (si nécessaire) et configure le [GPUOrchestrator]
## avec les paramètres compilés. Prépare les textures (VRAM) et les pipelines de shaders.
##
## @return bool: `true` si l'initialisation Vulkan/RenderingDevice a réussi, `false` sinon.
func _init_gpu_system() -> void:
	"""Configure the backend without touching Vulkan on the main/UI thread."""
	var global_dimensions: Vector2i = generation_params.get(
		"global_dimensions", generation_params.get("resolution", Vector2i(1024, 512))
	)
	use_tiled_global_generation = bool(generation_params.get("tiled_global_generation", false))
	use_tiled_global_generation = use_tiled_global_generation or TiledGlobalGenerator.should_use_tiled(global_dimensions)
	# Gas giants keep their dedicated atmospheric path; Milestone 5's maximum
	# tiled contract applies to solid-surface planets.
	if int(generation_params.get("planet_type", 0)) == 6:
		use_tiled_global_generation = false
	use_gpu_acceleration = true
	if use_tiled_global_generation:
		_tiled_output_root = cheminSauvegarde.path_join("tiled_dataset")
		print("[PlanetGenerator] Maximum-scale tiled generation enabled: ", global_dimensions)
	else:
		print("[PlanetGenerator] Monolithic GPU backend configured for background execution: ", generation_params["resolution"])

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
		print("[PlanetGenerator] Queuing tiled global generation on background GPU worker...")
		tiled_pipeline = TiledGlobalSimulationPipeline.new(generation_params, _tiled_output_root)
		tiled_pipeline.phase_started.connect(_on_tiled_phase_started)
		tiled_pipeline.tile_progress.connect(_on_tiled_tile_progress)
		if not GPUGenerationWorker.submit(_run_tiled_generation_worker.bind(_generation_request_id)):
			push_error("[PlanetGenerator] Unable to queue tiled generation worker")
			tiled_pipeline = null
			return false
		return true
	if _monolithic_job_active:
		push_warning("[PlanetGenerator] Monolithic generation is already running")
		return false
	_cancel_mutex.lock()
	_cancel_requested = false
	_cancel_reason = ""
	_cancel_mutex.unlock()
	_cached_display_maps.clear()
	_cached_export_files.clear()
	_monolithic_job_active = true
	print("[PlanetGenerator] Queuing monolithic GPU generation on background worker...")
	if not GPUGenerationWorker.submit(_run_monolithic_generation_worker.bind(_generation_request_id)):
		_monolithic_job_active = false
		push_error("[PlanetGenerator] Unable to queue background GPU generation")
		return false
	return true

func _run_tiled_generation_worker(request_id: int) -> void:
	var report: Dictionary = {}
	if tiled_pipeline != null:
		report = tiled_pipeline.generate()
	call_deferred("_complete_tiled_generation", request_id, report)

func _complete_tiled_generation(request_id: int, report: Dictionary) -> void:
	if request_id != _generation_request_id or _cleaned_up:
		return
	if bool(report.get("ok", false)):
		print("[PlanetGenerator] Tiled global generation complete: ", report.get("manifest", ""))
		emit_signal("finished")
	elif bool(report.get("cancelled", false)):
		emit_signal("generation_cancelled", str(report.get("reason", "user")))
	else:
		push_error("[PlanetGenerator] Tiled generation failed: %s" % report.get("reason", "unknown"))

func _on_monolithic_phase_started(phase: String, index: int, total: int) -> void:
	# Orchestrator signals are emitted on the GPU worker. Bounce UI-facing
	# progress to the main loop instead of emitting into the scene tree here.
	call_deferred("_emit_monolithic_progress", phase, index - 1, total)

func _emit_monolithic_progress(phase: String, completed: int, total: int) -> void:
	if _cleaned_up:
		return
	emit_signal("generation_progress", phase, completed, maxi(total, 1))

func _on_tiled_phase_started(phase: String) -> void:
	call_deferred("_emit_tiled_progress", phase, 0, 1)

func _on_tiled_tile_progress(phase: String, _tile: Vector2i, completed: int, total: int) -> void:
	call_deferred("_emit_tiled_progress", phase, completed, total)

func _emit_tiled_progress(phase: String, completed: int, total: int) -> void:
	emit_signal("generation_progress", phase, completed, maxi(total, 1))

func cancel_generation(reason: String = "user") -> void:
	_cancel_mutex.lock()
	_cancel_requested = true
	_cancel_reason = reason
	_cancel_mutex.unlock()
	if tiled_pipeline != null:
		tiled_pipeline.cancel(reason)

func _worker_cancel_probe() -> Dictionary:
	_cancel_mutex.lock()
	var result := {
		"cancelled": _cancel_requested or _cleaned_up,
		"reason": "cleanup" if _cleaned_up else _cancel_reason,
	}
	_cancel_mutex.unlock()
	return result

func _run_monolithic_generation_worker(request_id: int) -> void:
	# This entire method executes on GPUGenerationWorker's persistent thread.
	# The local RenderingDevice is therefore initialized, used, read back and
	# exported without blocking Godot's scene-tree/main thread.
	if request_id != _generation_request_id or _cleaned_up:
		call_deferred("_complete_monolithic_generation", request_id, false, [], "cancelled")
		return

	call_deferred("_emit_monolithic_progress", "gpu_initialization", 0, 1)
	var gpu_context := GPUContext.new(generation_params["resolution"])
	if not gpu_context or not gpu_context.rd:
		call_deferred("_complete_monolithic_generation", request_id, false, [], "gpu_unavailable")
		return

	var orchestrator := GPUOrchestrator.new(
		gpu_context, generation_params["resolution"], generation_params
	)
	if not orchestrator or not orchestrator.rd:
		if orchestrator:
			orchestrator.cleanup()
		call_deferred("_complete_monolithic_generation", request_id, false, [], "orchestrator_unavailable")
		return
	gpu_orchestrator = orchestrator
	orchestrator.cancellation_probe = _worker_cancel_probe
	orchestrator.phase_started.connect(_on_monolithic_phase_started)

	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION (BACKGROUND WORKER)")
	print("=".repeat(60))
	orchestrator.run_simulation()

	var cancel_state := _worker_cancel_probe()
	if orchestrator.was_cancelled or bool(cancel_state.get("cancelled", false)):
		var reason := orchestrator.cancellation_reason()
		if reason.is_empty():
			reason = str(cancel_state.get("reason", "user"))
		orchestrator.cleanup()
		if gpu_orchestrator == orchestrator:
			gpu_orchestrator = null
		call_deferred("_complete_monolithic_generation", request_id, false, [], reason)
		return

	# Export is part of generation from the user's perspective and used to block
	# the UI for several additional seconds in getMaps(). Keep it on the worker.
	call_deferred("_emit_monolithic_progress", "export", 13, 14)
	deleteImagesTemps()
	var exported_files := orchestrator.export_all_maps(cheminSauvegarde)
	cancel_state = _worker_cancel_probe()
	if bool(cancel_state.get("cancelled", false)):
		var export_cancel_reason := str(cancel_state.get("reason", "user"))
		orchestrator.cleanup()
		if gpu_orchestrator == orchestrator:
			gpu_orchestrator = null
		call_deferred("_complete_monolithic_generation", request_id, false, [], export_cancel_reason)
		return
	var display_maps: Array[String] = PlanetProject.display_maps_from_layers(exported_files)
	_cached_export_files = exported_files.duplicate(true)
	_cached_display_maps = display_maps.duplicate()
	# The UI consumes exported CPU files, not live GPU RIDs. Release per-planet
	# resources here, on the worker that owns the local RenderingDevice, while
	# keeping GPUContext's shared device alive for the next generation.
	orchestrator.cleanup()
	if gpu_orchestrator == orchestrator:
		gpu_orchestrator = null
	call_deferred("_complete_monolithic_generation", request_id, true, display_maps, "")

func _complete_monolithic_generation(request_id: int, ok: bool, display_maps: Array, reason: String) -> void:
	if request_id != _generation_request_id:
		return
	_monolithic_job_active = false
	if _cleaned_up:
		return
	if ok:
		_cached_display_maps.clear()
		for path in display_maps:
			_cached_display_maps.append(str(path))
		emit_signal("generation_progress", "complete", 1, 1)
		emit_signal("finished")
	elif reason == "cancelled" or reason == "cleanup" or reason == "user":
		emit_signal("generation_cancelled", reason)
	else:
		push_error("[PlanetGenerator] Background generation failed: %s" % reason)
		emit_signal("generation_cancelled", reason)

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
	elif use_gpu_acceleration and not _cached_export_files.is_empty():
		_copy_cached_exports(output_dir)
	else:
		push_warning("[PlanetGenerator] Export skipped: generation resources are unavailable")
	print("[PlanetGenerator] Export complete")

func _copy_cached_exports(output_dir: String) -> void:
	# Preserve the complete M7.2 project layout (maps/, overlays/, debug/,
	# manifests, integrity report, resources) instead of flattening file names.
	if not PlanetTileStore.copy_tree(_generation_output_root, output_dir):
		push_warning("[PlanetGenerator] Failed to copy generated project %s -> %s" % [
			_generation_output_root, output_dir
		])


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
	_cancel_mutex.lock()
	_cancel_requested = true
	_cancel_reason = "cleanup"
	_cleaned_up = true
	_cancel_mutex.unlock()
	if tiled_pipeline != null:
		tiled_pipeline.cancel("cleanup")
	if tiled_pipeline != null:
		tiled_pipeline.cleanup()
		tiled_pipeline = null
	# A running monolithic job observes _cleaned_up through its cancellation
	# probe and releases its GPU resources on the worker at the next safe phase
	# boundary. Completed jobs have already released their per-planet RIDs.
	use_gpu_acceleration = false

## Retourne la liste des chemins de fichiers des cartes générées.
##
## Nettoie d'abord les fichiers temporaires existants, sauvegarde les nouvelles cartes,
## et retourne les chemins. Utilisé par le [Master] node pour charger les textures.
##
## @return Array[String]: Liste des chemins complets vers les fichiers PNG générés.
func getMaps() -> Array[String]:
	"""Return maps already exported by the background generation worker."""
	if _cleaned_up or use_tiled_global_generation:
		return []
	return _cached_display_maps.duplicate()

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
