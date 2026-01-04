extends RefCounted

class_name PlanetGenerator

signal finished
signal progress_updated(value: float, status: String)

## ============================================================================
## PLANET GENERATOR
## ============================================================================

# Constants
const BASE_EROSION_ITERATIONS = 100
const BASE_TECTONIC_YEARS     = 100_000_000
const BASE_ATMOSPHERE_STEPS   = 1000

# Original properties (unchanged)
var nom             : String
var circonference   : int
var renderProgress  : ProgressBar
var mapStatusLabel  : Label
var cheminSauvegarde: String

var avg_temperature   : float
var water_elevation   : int
var avg_precipitation : float
var elevation_modifier: int
var nb_thread         : int
var atmosphere_type   : int
var nb_avg_cases      : int
var densite_planete   : float
var erosion_iterations : int = BASE_EROSION_ITERATIONS
var tectonic_nb_years  : int = BASE_TECTONIC_YEARS
var atmosphere_steps   : int = BASE_ATMOSPHERE_STEPS

# GPU acceleration components
var gpu_orchestrator    : GPUOrchestrator = null
var use_gpu_acceleration: bool

# Generation parameters (compiled from UI)
var generation_params: Dictionary = {}

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
## @param nb_thread_param: Nombre de threads pour la génération CPU (Obsolète pour GPU).
## @param atmosphere_type_param: Enum (0=Terre, 1=Lune, etc.) définissant la densité atmosphérique.
## @param renderProgress_param: Référence à la barre de progression de l'UI.
## @param mapStatusLabel_param: Référence au label de statut de l'UI.
## @param nb_avg_cases_param: Nombre de sites de Voronoi pour les plaques tectoniques/régions.
## @param cheminSauvegarde_param: Dossier racine pour la sauvegarde temporaire.
func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, erosion_iterations: int = BASE_EROSION_ITERATIONS,
 	tectonic_nb_years: int = BASE_TECTONIC_YEARS, atmosphere_steps: int = BASE_ATMOSPHERE_STEPS, elevation_modifier_param: int = 0, nb_thread_param: int = 8, atmosphere_type_param: int = 0, 
	renderProgress_param: ProgressBar = null, mapStatusLabel_param: Label = null, nb_avg_cases_param: int = 50, cheminSauvegarde_param: String = "user://temp/", use_gpu_acceleration_param: bool = true, densite_planete: float = 5.51, seed_param: int = 0) -> void:

	# Store all parameters
	self.nom                  = nom_param
	self.circonference        = int(rayon * 2 * PI)
	self.renderProgress       = renderProgress_param

	if self.renderProgress:
		self.renderProgress.value = 0.0

	self.mapStatusLabel       = mapStatusLabel_param
	self.cheminSauvegarde     = cheminSauvegarde_param
	self.nb_avg_cases         = nb_avg_cases_param
	self.densite_planete      = densite_planete
	self.avg_temperature      = avg_temperature_param
	self.water_elevation      = water_elevation_param
	self.avg_precipitation    = avg_precipitation_param
	self.elevation_modifier   = elevation_modifier_param
	self.nb_thread            = nb_thread_param
	self.atmosphere_type      = atmosphere_type_param
	
	self.use_gpu_acceleration = use_gpu_acceleration_param

	if seed_param == 0:
		randomize()
		seed_param = randi()

	# Compile generation parameters
	_compile_generation_params(seed_param)
	
	# Initialize GPU system
	_init_gpu_system()

## Compile et normalise les paramètres de génération pour le GPU.
##
## Cette méthode transforme les entrées utilisateur (UI) en un dictionnaire de constantes physiques
## strictes utilisables par le [GPUOrchestrator].
## Elle calcule notamment la densité de l'atmosphère, la gravité de surface et le rayon planétaire.
##
## @return Dictionary: Un dictionnaire contenant 'seed', 'planet_radius', 'atmo_density', 'gravity', etc.
func _compile_generation_params(seed_param: int) -> void:
	"""
	Compile all generation parameters into a single dictionary
	This is passed to the GPU orchestrator and shaders
	"""
	
	generation_params = {
		"seed"              : seed_param,
		"planet_name"       : nom,
		"planet_radius"     : circonference / (2.0 * PI),
		"planet_density"    : densite_planete, # Earth-like density in g/cm³
		"planet_type"       : atmosphere_type,
		"resolution"        : Vector2i(circonference, circonference / 2),
		"base_temp"         : avg_temperature,
		"sea_level"         : float(water_elevation),
		"global_humidity"   : avg_precipitation,
		"terrain_scale"     : float(elevation_modifier),
		"nb_cases_regions"  : nb_avg_cases,
		"erosion_iterations": erosion_iterations,
		"tectonic_years"    : tectonic_nb_years,
		"atmosphere_steps"  : atmosphere_steps
	}
	
	print("[PlanetGenerator] Parameters compiled:")
	print("  Seed: ", generation_params["seed"])

## Initialise le sous-système de rendu GPU.
##
## Instancie le [GPUContext] (si nécessaire) et configure le [GPUOrchestrator]
## avec les paramètres compilés. Prépare les textures (VRAM) et les pipelines de shaders.
##
## @return bool: `true` si l'initialisation Vulkan/RenderingDevice a réussi, `false` sinon.
func _init_gpu_system() -> void:
	"""Initialize GPU acceleration if available"""
	
	var gpu_context = GPUContext.new(generation_params["resolution"])
	if not gpu_context or not gpu_context.rd and not gpu_context.shaders:
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
	
	emit_signal("progress_updated", renderProgress.value if renderProgress else 0.0, map_key)

## Incrémente la barre de progression.
##
## Ajoute une valeur au pourcentage actuel de génération. Thread-safe.
##
## @param value: La valeur à ajouter (ex: 10.0 pour 10%).
func addProgress(value: float) -> void:
	"""Update progress bar"""
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

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
func generate_planet():
	"""
	Entry point - routes to GPU or CPU
	GPU path now uses call_deferred for render thread safety
	"""
	
	if use_gpu_acceleration and gpu_orchestrator:
		print("[PlanetGenerator] Starting GPU generation (render thread)...")
		# Call on render thread instead of worker thread
		call_deferred("_generate_planet_gpu_deferred")
	else:
		print("[PlanetGenerator] Cancelling generation: GPU acceleration not available")

## Wrapper pour l'exécution différée de la génération GPU.
##
## Permet d'appeler [method generate_planet_gpu] via [method call_deferred]
## pour s'assurer que certaines initialisations contextuelles se font sur le thread principal
## avant de basculer sur le RenderingDevice.
func _generate_planet_gpu_deferred():
	"""
	GPU generation executed on render thread
	Called via call_deferred from generate_planet()
	"""
	
	# === INITIAL LOGGING ===
	print("\n" + "=".repeat(60))
	print("GPU-ACCELERATED PLANET GENERATION (RENDER THREAD)")
	print("=".repeat(60))
	
	# === FULL SIMULATION ===
	# Execute simulation synchronously on render thread
	gpu_orchestrator.run_simulation()
	
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
	
	gpu_context.rd.submit()
	gpu_context.rd.sync()
	
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
	var exported_files = exporter.export_maps(gpu_context.textures, "user://temp/", generation_params)
	
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
	"""
	Export all maps to specified directory
	Called from master.gd when Export button is pressed
	"""
	
	print("[PlanetGenerator] Exporting to: ", output_dir)
	
	if use_gpu_acceleration and gpu_orchestrator:
		# GPU path - use PlanetExporter
		
		var exporter = PlanetExporter.new()
		exporter.export_maps(gpu_orchestrator.gpu, output_dir, generation_params)
		
		# Cleanup GPU resources after export
		gpu_orchestrator.cleanup()
		gpu_orchestrator = null
	
	print("[PlanetGenerator] Export complete")

## Sauvegarde les cartes générées dans le dossier temporaire par défaut.
func save_maps():
	"""Legacy save to default directory"""
	export_to_directory(cheminSauvegarde)

## Retourne la liste des chemins de fichiers des cartes générées.
##
## Nettoie d'abord les fichiers temporaires existants, sauvegarde les nouvelles cartes,
## et retourne les chemins. Utilisé par le [Master] node pour charger les textures.
##
## @return Array[String]: Liste des chemins complets vers les fichiers PNG générés.
func getMaps() -> Array[String]:
	"""Get temporary map file paths for UI preview"""
	deleteImagesTemps()
	
	var temp_dir = "user://temp/"
	
	# Exporter les cartes GPU vers des fichiers PNG
	var exported_files = gpu_orchestrator.export_all_maps(temp_dir)
	
	# Convertir le dictionnaire en tableau de chemins
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

## Gestionnaire de notifications système Godot.
##
## Intercepte [constant Node.NOTIFICATION_PREDELETE] pour assurer le nettoyage
## propre des ressources GPU (via [method GPUOrchestrator.cleanup]) lors de la destruction de l'objet.
##
## @param what: L'identifiant de la notification.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if gpu_orchestrator:
			gpu_orchestrator.cleanup()
			gpu_orchestrator = null
