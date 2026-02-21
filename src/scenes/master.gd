extends Node2D

# --- Core Variables ---
var planetGenerator: PlanetGenerator
var maps: Array[String]
var map_index: int = 0
var langue: String = "fr"

# --- Constants ---
const BASE_PATH_SLIDERS = "ImageFrame/Control General/Control_Parameters/SC Parameters/Parameters_tree"

const CATEGORIES_PATHS = {
	"GENERAL" : BASE_PATH_SLIDERS+"/General_Categorie/MarginContainer/Parameters/",
	"EROSION" : BASE_PATH_SLIDERS+"/Erosion_Tectonic_Categorie/MarginContainer/Erosion_Tectonic_parameters/",
	"CRATER" : BASE_PATH_SLIDERS+"/Crater_Categorie/MarginContainer/Crater_parameters/",
	"EAU" : BASE_PATH_SLIDERS+"/Eau_Categorie/MarginContainer/Eaux_parameters/",
	"NUAGE" : BASE_PATH_SLIDERS+"/Nuages_Categorie/MarginContainer/nuage_parameters/",
	"REGION" : BASE_PATH_SLIDERS+"/Region_Categorie/MarginContainer/Region_parameters/",
	"OCEAN" : BASE_PATH_SLIDERS+"/Region_Ocean_Categorie/MarginContainer/Region_Ocean_parameters/",
	"RESSOURCES" : BASE_PATH_SLIDERS+"/Ressources_Categorie/MarginContainer/Ressources_parameters/",
}

const MAP_NAME_TO_KEY = {
	"topographie_map.png": "MAP_TOPOGRAPHIE",
	"topographie_map_grey.png": "MAP_TOPOGRAPHIE_GREY",
	"eaux_map.png": "MAP_EAUX",
	"plaques_map.png": "MAP_PLAQUES",
	"plaques_bordures_map.png": "MAP_PLAQUES_BORDURES",
	"clouds_map.png": "MAP_CLOUDS",
	"precipitation_map.png": "MAP_PRECIPITATION",
	"temperature_map.png": "MAP_TEMPERATURE",
	"water_map.png": "MAP_WATER",
	"river_map.png": "MAP_RIVERS",
	"ice_caps_map.png": "MAP_ICE",
	"biome_map.png": "MAP_BIOMES",
	"final_map.png": "MAP_FINAL",
	"region_map.png": "MAP_REGIONS",
	"ocean_region_map.png": "MAP_OCEAN_REGIONS",
	"preview.png": "MAP_PREVIEW",
	"petrole_map.png": "MAP_PETROLE",
	"ressource_map.png": "MAP_RESOURCES",
}

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready() -> void:
	# 1. Language Setup
	if OS.get_locale_language() != "fr":
		langue = "en"
	TranslationServer.set_locale(langue)

	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")

	# 2. UI Initialization
	maj_labels()

# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	# UI Gather Data
	var nom          = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit")
	var lblMapStatus = $"ImageFrame/LabelNomMap"

	# Reset state
	maps      = []
	map_index = 0
	$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = load("res://data/img/UI/no_data.png")

	# Initialize Generator
	planetGenerator = PlanetGenerator.new(
		nom.text, 
		_compile_generation_params(),
		"user://temp/",
		lblMapStatus,
	)
	
	# Connect Signal
	planetGenerator.finished.connect(_on_planetGenerator_finished)

	print("Génération de la planète : " + nom.text)

	planetGenerator.generate_planet()

	# Disable UI
	_set_buttons_enabled(false)

func _on_planetGenerator_finished() -> void:
	call_deferred("_on_planetGenerator_finished_main")

func _on_planetGenerator_finished_main() -> void:
	# 1. Update 2D Maps (Standard Logic)
	maps = planetGenerator.getMaps()
	map_index = 0
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = tex
		update_map_label()
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

	# 2. Re-enable UI
	_set_buttons_enabled(true)

func _set_buttons_enabled(enabled: bool) -> void:
	$"ImageFrame/Control General/btnGenerer".disabled = !enabled
	$"ImageFrame/Control General/btnSauvegarder".disabled = !enabled
	$"ImageFrame/Control General/btnRandomiser".disabled  = !enabled
	$"ImageFrame/btnSuivant".disabled   = !enabled
	$"ImageFrame/btnPrecedent".disabled = !enabled

## Compile et normalise les paramètres de génération pour le GPU.
##
## Cette méthode transforme les entrées utilisateur (UI) en un dictionnaire de constantes physiques
## strictes utilisables par le [GPUOrchestrator].
## Elle calcule notamment la densité de l'atmosphère, la gravité de surface et le rayon planétaire.
##
## @return Dictionary: Un dictionnaire contenant 'seed', 'planet_radius', 'atmo_density', 'gravity', etc.
func _compile_generation_params() -> Dictionary:
	"""
	Compile all generation parameters into a single dictionary
	This is passed to the GPU orchestrator and shaders
	"""
	var _seed = get_node(BASE_PATH_SLIDERS+"/PanelSeed/seed/LineEdit").value
	if _seed == 0:
		randomize()
		_seed = randi()
	
	var circonference = int(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit").value) * 2 * PI
	var typePlanete   = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Type_Param/LineEdit").get_selected_id()
	if typePlanete == -1:
		typePlanete = 0  # Default to Earth-like if none selected

	var generation_params = {
		"seed"              : _seed,
		"nb_thread"         : get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/LineEdit").value,

		# Planet properties
		"planet_radius"     : circonference / (2.0 * PI),
		"planet_density"    : get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit").value,
		"planet_type"       : typePlanete, # 0: Earth-like, 1: Thin, 2: Thick
		"resolution"        : Vector2i(circonference, circonference / 2),
		"avg_temperature"   : get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit").value,
		
		# Erosion and tectonics
		"terrain_scale"      : get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit").value, # 0
		"erosion_iterations" : get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit").value, # 100
		"erosion_rate"       : get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit").value, # 0.05
		"rain_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit").value, # 0.005
		"evap_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit").value, # 0.02
		"flow_rate"          : get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit").value, # 0.25
		"deposition_rate"    : get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit").value, # 0.05
		"capacity_multiplier": get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit").value, # 1.0
		"flux_iterations"    : get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit").value, # 10
		"base_flux"          : get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit").value, #1.0
		"propagation_rate"   : get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit").value, # 0.8
		"spreading_rate"    : get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit").value, # 50.0
		"max_crust_age"     : get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit").value, # 200.0
		"subsidence_coeff"  : get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit").value, # 2800.0

		# Craters
		"crater_density"     : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit").value, # 0.5
		"crater_max_radius"  : min(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 0.08,
		"crater_min_radius"  : min(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit").value, min(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 0.08),
		"crater_depth_ratio" : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit").value, # 0.25
		"crater_ejecta_extent": get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit").value, # 2.5
		"crater_ejecta_decay" : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit").value, # 3.0
		"crater_azimuth_var"  : get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit").value, # 0.3

		# Clouds
		"cloud_coverage"    : get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit").value, # 0.5
		"cloud_density"     : get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit").value,  # 0.8

		# Ice caps
		"ice_probability" : get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit").value, # 0.9

		# Water bodies
		"ocean_ratio"       : get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit").value,  # Pourcentage couverture océanique 70.0
		"global_humidity"   : get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit").value, # 0.5
		"sea_level"         : get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit").value, # 0.0
		"saltwater_min_size" : get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value+1, # 1000
		"freshwater_max_size": get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value, # 999
		"lake_threshold"     : get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit").value, # 5.0

		"river_iterations"   : get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit").value, # 2000
		# Nouveau système de rivières : les seuils sont définis par défaut dans orchestrator.gd
		# river_affluent_threshold = 50.0, river_riviere_threshold = 200.0, river_fleuve_threshold = 800.0
		# river_precip_scale = 1.0 (utiliser River_Base_Flux_Param comme proxy si besoin)

		# Regions
		"nb_cases_regions" : get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit").value, # 50
		"region_cost_flat" : get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit").value, # 1.0
		"region_cost_hill" : get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit").value, # 2.0
		"region_cost_river": get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit").value, # 3.0
		"region_river_threshold" : get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit").value, # 1.0
		"region_budget_variation": get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit").value, # 0.5
		"region_noise_strength"  : get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit").value, # 0.5
		"region_iterations"	     : max(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 2,

		# Regions Ocean 
		"nb_cases_ocean_regions": get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit").value, # 100
		"ocean_cost_flat"   : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit").value, # 1.0
		"ocean_cost_deeper" : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit").value, # 2.0
		"ocean_noise_strength" : get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit").value, # 0.5
		"ocean_iterations"	   : max(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 2,

		# Resources
		"petrole_probability"  : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit").value, # 0.025
		"petrole_deposit_size" : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit").value, # 200.0
		"global_richness"      : get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit").value, # 1.0
	}
	
	print("[PlanetGenerator] Parameters compiled:")
	print("  Seed: ", generation_params["seed"])

	return generation_params


# ============================================================================
# UI NAVIGATION & HELPERS
# ============================================================================

func get_map_display_name(file_path: String) -> String:
	var file_name = file_path.get_file()
	if MAP_NAME_TO_KEY.has(file_name):
		return tr(MAP_NAME_TO_KEY[file_name])
	return file_name

func update_map_label() -> void:
	if maps.is_empty():
		return
	var lbl = $"ImageFrame/LabelNomMap"
	lbl.text = get_map_display_name(maps[map_index])

func _on_btn_suivant_pressed() -> void:
	if maps.is_empty(): return 
	map_index = (map_index + 1) % maps.size()
	_load_current_map()

func _on_btn_precedant_pressed() -> void:
	if maps.is_empty(): return 
	map_index -= 1
	if map_index < 0: map_index = maps.size() - 1
	_load_current_map()

func _load_current_map() -> void:
	var img = Image.new()
	if img.load(maps[map_index]) == OK:
		var tex = ImageTexture.create_from_image(img)
		$"ImageFrame/ImageMenu/Control Images/Frame Map/Map".texture = tex
		update_map_label()

func _on_fold_button_pressed(cible : String) -> void:
	print("Node : ", get_node(cible))
	var margin_container = get_node(cible) as MarginContainer
	margin_container.visible = !margin_container.visible

# ============================================================================
# SLIDER CALLBACKS
# ============================================================================

func _set_slider_label(slider_label: Label, tr_key: String, value, unit: String = "") -> void:
	print("Setting slider label for ", tr_key, " to value: ", str(value) + unit)
	slider_label.text = tr(tr_key).format({"val": str(value) + unit})


func _on_range_change_terrain_scale(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/Label"), "TERRAIN_SCALE", get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit").value, " m")
func _on_range_change_thread_number(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/Label"), "THREAD_NUMBER", get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/LineEdit").value)
func _on_range_change_ocean_ratio(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/Label"), "OCEAN_RATIO", get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit").value, "%")
func _on_range_change_planet_radius(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/Label"), "PLANET_RADIUS", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit").value, " km")
func _on_range_change_planet_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/Label"), "PLANET_DENSITY", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit").value, " g/cm³")
func _on_range_change_planet_temperature_avg(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/Label"), "PLANET_TEMPERATURE_AVG", get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit").value, " °C")

func _on_range_change_erosion_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/Label"), "EROSION_ITERATIONS", get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit").value)
func _on_range_change_erosion_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/Label"), "EROSION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit").value)
func _on_range_change_rain_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/Label"), "RAIN_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit").value)
func _on_range_change_evap_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/Label"), "EVAP_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit").value)
func _on_range_change_flow_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/Label"), "FLOW_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit").value)

func _on_range_change_deposition_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/Label"), "DEPOSITION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit").value)
func _on_range_change_capacity_multiplier(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/Label"), "CAPACITY_MULTIPLIER", get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit").value)
func _on_range_change_flux_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/Label"), "FLUX_ITERATIONS", get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit").value)
func _on_range_change_base_flux(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/Label"), "BASE_FLUX", get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit").value)
func _on_range_change_propagation_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/Label"), "PROPAGATION_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit").value)
func _on_range_change_spreading_rate(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/Label"), "SPREADING_RATE", get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit").value)
func _on_range_change_max_crust_age(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/Label"), "MAX_CRUST_AGE", get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit").value, " Myr")
func _on_range_change_subsidence_coefficient(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/Label"), "SUBSIDENCE_COEFFICIENT", get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit").value, " m/Myr")


func _on_range_change_crater_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/Label"), "CRATER_DENSITY", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit").value)
func _on_range_change_crater_min_radius(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/Label"), "CRATER_MIN_RADIUS", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit").value, " km")
func _on_range_change_crater_depth_ratio(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/Label"), "CRATER_DEPTH_RATIO", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit").value)
func _on_range_change_crater_ejecta_extent(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/Label"), "CRATER_EJECTA_EXTENT", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit").value)
func _on_range_change_crater_ejecta_decay(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/Label"), "CRATER_EJECTA_DECAY", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit").value)
func _on_range_change_crater_azimuth_var(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/Label"), "CRATER_AZIMUTH_VAR", get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit").value)


func _on_range_change_ice_probability(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/Label"), "ICE_PROBABILITY", get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit").value, "%")
func _on_range_change_global_humidity(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/Label"), "GLOBAL_HUMIDITY", get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit").value, "%")
func _on_range_change_sea_level(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/Label"), "SEA_LEVEL", get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit").value, " m")
func _on_range_change_freshwater_max_size(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/Label"), "FRESHWATER_MAX_SIZE", get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit").value, " km²")
func _on_range_change_lake_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/Label"), "LAKE_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit").value)
func _on_range_change_river_iterations(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/Label"), "RIVER_ITERATIONS", get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit").value)
func _on_range_change_river_affluent_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/Label"), "RIVER_AFFLUENT_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/LineEdit").value)
func _on_range_change_river_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/Label"), "RIVER_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/LineEdit").value)
func _on_range_change_river_fleuve_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/Label"), "RIVER_FLEUVE_THRESHOLD", get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/LineEdit").value)

func _on_range_change_cloud_coverage(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/Label"), "CLOUD_COVERAGE", get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit").value, "%")
func _on_range_change_cloud_density(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/Label"), "CLOUD_DENSITY", get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit").value, "%")


func _on_range_change_nb_cases_regions(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/Label"), "NB_CASES_REGIONS", get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit").value)
func _on_range_change_region_cost_flat(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/Label"), "REGION_COST_FLAT", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit").value)
func _on_range_change_region_cost_hill(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/Label"), "REGION_COST_HILL", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit").value)
func _on_range_change_region_cost_river(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/Label"), "REGION_COST_RIVER", get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit").value)
func _on_range_change_region_river_threshold(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/Label"), "REGION_RIVER_THRESHOLD", get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit").value)
func _on_range_change_region_budget_variation(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/Label"), "REGION_BUDGET_VARIATION", get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit").value)
func _on_range_change_region_noise_strength(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/Label"), "REGION_NOISE_STRENGTH", get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit").value)


func _on_range_change_nb_cases_ocean_regions(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/Label"), "NB_CASES_OCEAN_REGIONS", get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit").value)
func _on_range_change_ocean_cost_flat(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/Label"), "OCEAN_COST_FLAT", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit").value)
func _on_range_change_ocean_cost_deeper(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/Label"), "OCEAN_COST_DEEPER", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit").value)
func _on_range_change_ocean_noise_strength(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/Label"), "OCEAN_NOISE_STRENGTH", get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit").value)
func _on_range_change_petrole_probability(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/Label"), "PETROLE_PROBABILITY", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit").value, "%")
func _on_range_change_petrole_deposit_size(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/Label"), "PETROLE_DEPOSIT_SIZE", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit").value, " km²")
func _on_range_change_global_richness(_value = 0) -> void:
	_set_slider_label(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/Label"), "GLOBAL_RICHNESS", get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit").value)

func maj_labels() -> void:
	# TODO : REPLACE THE NODE PATH WITH CORRECT ONES
	_on_range_change_thread_number()
	_on_range_change_planet_radius()
	_on_range_change_planet_density()
	_on_range_change_planet_temperature_avg()

	_on_range_change_terrain_scale()
	_on_range_change_erosion_iterations()
	_on_range_change_erosion_rate()
	_on_range_change_rain_rate()
	_on_range_change_evap_rate()
	_on_range_change_flow_rate()
	_on_range_change_deposition_rate()
	_on_range_change_capacity_multiplier()
	_on_range_change_flux_iterations()
	_on_range_change_base_flux()
	_on_range_change_propagation_rate()
	_on_range_change_spreading_rate()
	_on_range_change_max_crust_age()
	_on_range_change_subsidence_coefficient()
	
	_on_range_change_crater_density()
	_on_range_change_crater_min_radius()
	_on_range_change_crater_depth_ratio()
	_on_range_change_crater_ejecta_extent()
	_on_range_change_crater_ejecta_decay()
	_on_range_change_crater_azimuth_var()

	_on_range_change_ocean_ratio()
	_on_range_change_ice_probability()
	_on_range_change_global_humidity()
	_on_range_change_sea_level()
	_on_range_change_freshwater_max_size()
	_on_range_change_lake_threshold()
	_on_range_change_river_iterations()
	_on_range_change_river_affluent_threshold()
	_on_range_change_river_threshold()
	_on_range_change_river_fleuve_threshold()

	_on_range_change_cloud_coverage()
	_on_range_change_cloud_density()
	_on_range_change_nb_cases_regions()
	_on_range_change_region_cost_flat()
	_on_range_change_region_cost_hill()
	_on_range_change_region_cost_river()
	_on_range_change_region_river_threshold()
	_on_range_change_region_budget_variation()
	_on_range_change_region_noise_strength()

	_on_range_change_nb_cases_ocean_regions()
	_on_range_change_ocean_cost_flat()
	_on_range_change_ocean_cost_deeper()
	_on_range_change_ocean_noise_strength()

	_on_range_change_petrole_probability()
	_on_range_change_petrole_deposit_size()
	_on_range_change_global_richness()
	
# ============================================================================
# LANGUAGE & SYSTEM
# ============================================================================

func _on_btn_french_pressed() -> void: _change_lang("fr")
func _on_btn_english_pressed() -> void: _change_lang("en")
func _on_btn_german_pressed() -> void: _change_lang("de")

func _change_lang(code: String) -> void:
	if langue == code: return
	langue = code
	TranslationServer.set_locale(langue)
	maj_labels()
	update_map_label()

func _on_btn_quitter_pressed() -> void:
	get_tree().quit()

# ============================================================================
# SAVE & RANDOMIZATION
# ============================================================================

func _on_btn_sauvegarder_pressed() -> void:
	var file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.title = tr("Select Export Directory")
	file_dialog.min_size = Vector2i(600, 400)
	add_child(file_dialog)
	file_dialog.popup_centered()
	file_dialog.dir_selected.connect(func(dir_path):
		if planetGenerator != null:
			if planetGenerator.nom == "":
				planetGenerator.nom = "Planète Générée"
			planetGenerator.cheminSauvegarde = dir_path + "/" + planetGenerator.nom
			planetGenerator.save_maps()
			print("Planète sauvegardée dans : ", planetGenerator.cheminSauvegarde)
		else:
			print("Aucun générateur de planète actif.")
		file_dialog.queue_free())

func _on_random_seed_pressed() -> void:
	var generation_seed = randi()
	get_node(BASE_PATH_SLIDERS+"/PanelSeed/seed/LineEdit").value = generation_seed

func _on_random_name_pressed() -> void:
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", 
	"Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", 
	"Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega",
	"Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra",
	"Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]

	var random_name = prefixes[randi() % prefixes.size()] + "-" + str(randi() % 999 + 1)

	if randf() > 0.5: random_name += " " + suffixes[randi() % suffixes.size()]

	get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit").text = random_name

func _on_btn_randomise_pressed() -> void:
	randomize()
	
	# Name
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", 
	"Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", 
	"Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega",
	"Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra",
	"Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]
	var random_name = prefixes[randi() % prefixes.size()] + "-" + str(randi() % 999 + 1)
	if randf() > 0.5: random_name += " " + suffixes[randi() % suffixes.size()]
	get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Name_Param/HBoxContainer/LineEdit").text = random_name
	
	# Sliders
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Radius_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Density_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Temperature_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["GENERAL"]+"Thread_Number_Param/LineEdit"))
	
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Terrain_Scale_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Erosions_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Erosion_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Rain_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Evap_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Flow_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Deposition_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Capacity_Multiplier_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Flux_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Base_Flux_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Propagation_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Spreading_Rate_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Max_Crust_Age_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EROSION"]+"Subsidence_Coeff_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Density_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Min_Radius_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Depth_Ratio_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Extent_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Ejecta_Decay_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["CRATER"]+"Crater_Azimuth_Var_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Ocean_Ratio_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Ice_Probability_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Global_Humidity_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Sea_Level_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Freshwater_Max_Size_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"Lake_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Iterations_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Affluent_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["EAU"]+"River_Fleuve_Threshold_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Coverage_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["NUAGE"]+"Cloud_Density_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Nb_Cases_Regions_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Flat_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_Hill_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Cost_River_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_River_Threshold_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Budget_Variation_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["REGION"]+"Region_Noise_Strength_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Nb_Cases_Ocean_Regions_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Flat_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Cost_Deeper_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["OCEAN"]+"Ocean_Noise_Strength_Param/LineEdit"))

	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Probability_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Petrole_Deposit_Size_Param/LineEdit"))
	_randomize_slider(get_node(CATEGORIES_PATHS["RESSOURCES"]+"Global_Richness_Param/LineEdit"))
	
	# Type
	var typePlanete = get_node(CATEGORIES_PATHS["GENERAL"]+"Planet_Type_Param/LineEdit")
	typePlanete.select(randi() % typePlanete.item_count)
	
	_on_random_seed_pressed()

	maj_labels()

func _randomize_slider(slider: Slider) -> void:
	var max_nb_steps = int((slider.max_value - slider.min_value) / slider.step)
	var random_step = randi() % (max_nb_steps + 1)
	slider.value = slider.min_value + float(random_step) * slider.step
