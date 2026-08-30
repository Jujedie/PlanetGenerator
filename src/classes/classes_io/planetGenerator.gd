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
var last_performance_report: Dictionary = {}
# M8 release instrumentation is cached before the background worker releases
# the per-generation orchestrator. This keeps validation independent of live RIDs.
var last_export_metrics: Dictionary = {}
var last_exported_files: Dictionary = {}
var last_cancel_reason: String = ""
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
## @param nb_avg_cases_param: Nombre de sites de Voronoi pour les plaques tectoniques/régions.
## @param cheminSauvegarde_param: Dossier racine pour la sauvegarde temporaire.
func _init(nom_param: String, generation_param : Dictionary, cheminSauvegarde_param: String = "user://temp/"):

	"""
	PlanetGenerator constructor
	Initializes all parameters and references
	Does NOT start generation (see generate_planet)
	"""

	# Store all parameters
	self.nom                  = nom_param
	self.generation_params    = generation_param.duplicate(true)
	self.generation_params["planet_name"] = nom_param

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
	var planet_type := int(generation_params.get("planet_type", 0))
	var monolithic_supported := TiledGlobalGenerator.fits_monolithic_envelope(
		global_dimensions
	)
	var experimental_tiled := bool(generation_params.get(
		"experimental_tiled_generation", false
	))

	# The tiled backend does not yet preserve the same global simulation
	# invariants as the authoritative monolithic pipeline. Never route production
	# worlds into it automatically. A developer can still opt in explicitly for
	# tiled regression work via experimental_tiled_generation.
	use_tiled_global_generation = (
		planet_type != 6
		and not monolithic_supported
		and experimental_tiled
		and TiledGlobalGenerator.PRODUCTION_TILED_ENABLED
	)
	use_gpu_acceleration = monolithic_supported or use_tiled_global_generation or planet_type == 6

	if planet_type != 6 and monolithic_supported:
		generation_params["large_monolithic_lifecycle"] = (
			TiledGlobalGenerator.exceeds_preferred_monolithic_budget(global_dimensions)
		)
		generation_params["tiled_global_generation"] = false
		print(
			"[PlanetGenerator] Authoritative monolithic GPU backend configured: ",
			global_dimensions,
			" (large lifecycle=",
			generation_params["large_monolithic_lifecycle"],
			")"
		)
	elif use_tiled_global_generation:
		_tiled_output_root = cheminSauvegarde.path_join("tiled_dataset")
		print("[PlanetGenerator] Experimental tiled generation enabled: ", global_dimensions)
	elif planet_type == 6:
		use_tiled_global_generation = false
		print("[PlanetGenerator] Gas giant GPU backend configured: ", generation_params["resolution"])
	else:
		use_tiled_global_generation = false
		generation_params["tiled_global_generation"] = false
		push_error((
			"[PlanetGenerator] Resolution %s exceeds the safe monolithic GPU envelope. "
			+ "The experimental tiled backend is disabled because it does not yet preserve "
			+ "the authoritative global simulation."
		) % [global_dimensions])

func generate_planet() -> bool:
	"""Entry point - routes to the bounded tiled path or legacy GPU path."""
	last_performance_report.clear()
	last_export_metrics.clear()
	last_exported_files.clear()
	last_cancel_reason = ""
	if _cleaned_up or not use_gpu_acceleration:
		print("[PlanetGenerator] Cancelling generation: GPU acceleration not available")
		return false
	_generation_request_id += 1
	_cached_display_maps.clear()
	_cached_export_files.clear()
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
	last_performance_report = report.duplicate(true)
	last_export_metrics = report.duplicate(true)
	if bool(report.get("ok", false)):
		last_exported_files = {"tiled_dataset": _tiled_output_root}
		print("[PlanetGenerator] Experimental tiled dataset complete: ", report.get("manifest", ""))
		emit_signal("generation_progress", "complete", 1, 1)
		emit_signal("finished")
	elif bool(report.get("cancelled", false)):
		last_cancel_reason = str(report.get("reason", "user"))
		emit_signal("generation_cancelled", last_cancel_reason)
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
	var first_request := not _cancel_requested
	_cancel_requested = true
	_cancel_reason = reason
	_cancel_mutex.unlock()
	if first_request:
		print("[PlanetGenerator] Cancellation requested from UI: ", reason)
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
		last_cancel_reason = reason
		# run_simulation() exits before its normal final report when cancelled at a
		# phase checkpoint. Preserve the useful partial timing data before cleanup.
		last_performance_report = orchestrator.last_performance_report.duplicate(true)
		last_performance_report["phase_enqueue_and_cpu_ms"] = orchestrator.last_phase_timings_ms.duplicate(true)
		last_performance_report["cancelled"] = true
		last_performance_report["cancel_reason"] = reason
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
		last_cancel_reason = export_cancel_reason
		last_performance_report = orchestrator.last_performance_report.duplicate(true)
		last_performance_report["cancelled"] = true
		last_performance_report["cancel_reason"] = export_cancel_reason
		orchestrator.cleanup()
		if gpu_orchestrator == orchestrator:
			gpu_orchestrator = null
		call_deferred("_complete_monolithic_generation", request_id, false, [], export_cancel_reason)
		return
	var display_maps: Array[String] = PlanetProject.display_maps_from_layers(exported_files)
	last_performance_report = orchestrator.last_performance_report.duplicate(true)
	var export_metrics_value: Variant = last_performance_report.get("export", {})
	last_export_metrics = export_metrics_value.duplicate(true) if export_metrics_value is Dictionary else {}
	last_exported_files = exported_files.duplicate(true)
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
	elif reason == "cancelled" or reason == "cleanup" or reason == "user" or reason.begins_with("release_test_after:"):
		last_cancel_reason = reason
		emit_signal("generation_cancelled", reason)
	else:
		push_error("[PlanetGenerator] Background generation failed: %s" % reason)
		emit_signal("generation_cancelled", reason)

func export_to_directory(output_dir: String) -> Dictionary:
	"""Return/copy completed exports without requiring live GPU resources."""
	print("[PlanetGenerator] Exporting to: ", output_dir)
	if use_tiled_global_generation and tiled_pipeline != null:
		# Experimental tiled mode keeps only its raw authoritative dataset. It is
		# deliberately excluded from the production PNG path until its global
		# simulation matches the monolithic backend.
		if output_dir.simplify_path() != cheminSauvegarde.simplify_path():
			if not tiled_pipeline.export_dataset(output_dir):
				push_warning("[PlanetGenerator] Tiled export skipped: dataset is incomplete")
				return {}
		last_exported_files = {"tiled_dataset": _tiled_output_root}
		last_export_metrics = tiled_pipeline.last_report.duplicate(true)
	elif use_gpu_acceleration and not _cached_export_files.is_empty():
		if output_dir.simplify_path() != _generation_output_root.simplify_path():
			_copy_cached_exports(output_dir)
		last_exported_files = _cached_export_files.duplicate(true)
	else:
		push_warning("[PlanetGenerator] Export skipped: generation resources are unavailable")
	print("[PlanetGenerator] Export complete")
	return last_exported_files.duplicate(true)

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
	if _cleaned_up:
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
	"""Clear the temporary export tree, including nested M7.2 folders."""
	var root := "user://temp/"
	DirAccess.make_dir_recursive_absolute(root)
	_clear_directory_contents(root)


static func _clear_directory_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if dir.current_is_dir():
				_clear_directory_contents(child)
				DirAccess.remove_absolute(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
