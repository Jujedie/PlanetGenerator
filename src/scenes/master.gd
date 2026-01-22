extends Node2D

# --- Core Variables ---
var planetGenerator: PlanetGenerator
var maps: Array[String]
var map_index: int = 0
var langue: String = "fr"

# --- Constants ---
const MAP_NAME_TO_KEY = {
	"topographie_map.png": "MAP_TOPOGRAPHIE",
	"topographie_map_grey.png": "MAP_TOPOGRAPHIE_GREY",
	"eaux_map.png": "MAP_EAUX",
	"plaques_map.png": "MAP_PLAQUES",
	"plaques_bordures_map.png": "MAP_PLAQUES_BORDURES",
	"nuage_map.png": "MAP_CLOUDS",
	"precipitation_map.png": "MAP_PRECIPITATION",
	"temperature_map.png": "MAP_TEMPERATURE",
	"water_map.png": "MAP_WATER",
	"river_map.png": "MAP_RIVERS",
	"biome_map.png": "MAP_BIOMES",
	"final_map.png": "MAP_FINAL",
	"region_map.png": "MAP_REGIONS",
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

	# 2. UI Initialization
	maj_labels()

# ============================================================================
# GENERATION LOGIC
# ============================================================================

func _on_btn_comfirme_pressed() -> void:
	# UI Gather Data
	var nom          = $Node2D/Control/planeteName/LineEdit
	var lblMapStatus = $Node2D/Control/renderProgress/Node2D/lblMapStatus

	# Reset state
	maps      = []
	map_index = 0
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = null

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
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
		update_map_label()
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

	# 2. Re-enable UI
	_set_buttons_enabled(true)

func _set_buttons_enabled(enabled: bool) -> void:
	$Node2D/Control/btnComfirmer/btnComfirme.disabled = !enabled
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = !enabled
	$Node2D/Control/btnSuivant/btnSuivant.disabled = !enabled
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled = !enabled

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
	var _seed = $Node2D/Control/sldSeed.value
	if _seed == 0:
		randomize()
		_seed = randi()
	
	var circonference = int($Node2D/Control/sldRayonPlanetaire.value) * 2 * PI
	var typePlanete         = $Node2D/Control/typePlanete/ItemList.get_selected_id()
	if typePlanete == -1:
		typePlanete = 0  # Default to Earth-like if none selected

	var generation_params = {
		"seed"              : _seed,
		"nb_thread"         : $Node2D/Control/sldThread.value,

		# Planet properties
		"planet_radius"     : circonference / (2.0 * PI),
		"planet_density"    : $Node2D/Control/sldDensitePlanetaire.value,
		"planet_type"       : typePlanete, # 0: Earth-like, 1: Thin, 2: Thick
		"resolution"        : Vector2i(circonference, circonference / 2),
		"avg_temperature"   : $Node2D/Control/sldTemperatureMoyenne.value,
		
		# Erosion and tectonics
		"terrain_scale"     : $Node2D/Control/sldElevation.value, # 0
		"erosion_iterations" : $Node2D/Control/sldErosionIterations.value, # 100
		"erosion_rate"       : $Node2D/Control/sldErosionRate.value, # 0.05
		"rain_rate"          : $Node2D/Control/sldRainRate.value, # 0.005
		"evap_rate"          : $Node2D/Control/sldEvapRate.value, # 0.02
		"flow_rate"          : $Node2D/Control/sldFlowRate.value, # 0.25
		"deposition_rate"    : $Node2D/Control/sldDepositionRate.value, # 0.05
		"capacity_multiplier": $Node2D/Control/sldCapacityMultiplier.value, # 1.0
		"flux_iterations"    : $Node2D/Control/sldFluxIterations.value, # 10
		"base_flux"          : $Node2D/Control/sldBaseFlux.value, #1.0
		"propagation_rate"   : $Node2D/Control/sldPropagationRate.value, # 0.8
		"spreading_rate"    : $Node2D/Control/sldSpreadingRate.value, # 50.0
		"max_crust_age"     : $Node2D/Control/sldMaxCrustAge.value, # 200.0
		"subsidence_coeff"  : $Node2D/Control/sldSubsidenceCoefficient.value, # 2800.0

		# Craters
		"crater_density"     : $Node2D/Control/sldCraterDensity.value, # 0.5
		"crater_max_radius"  : min(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 0.08,
		"crater_min_radius"  : $Node2D/Control/sldCraterMinRadius.value, # 3.0
		"crater_depth_ratio" : $Node2D/Control/sldCraterDepthRatio.value, # 0.25
		"crater_ejecta_extent": $Node2D/Control/sldCraterEjectaExtent.value, # 2.5
		"crater_ejecta_decay": $Node2D/Control/sldCraterEjectaDecay.value, # 3.0
		"crater_azimuth_var" : $Node2D/Control/sldCraterAzimuthVar.value, # 0.3

		# Clouds
		"cloud_coverage"    : $Node2D/Control/sldCloudCoverage.value, # 0.5
		"cloud_density"     : $Node2D/Control/sldCloudDensity.value,  # 0.8

		# Ice caps
		"ice_probability" : $Node2D/Control/sldIceProbability.value, # 0.9

		# Water bodies
		"ocean_ratio"       : $Node2D/Control/sldOceanRatio.value,  # Pourcentage couverture océanique 70.0
		"global_humidity"   : $Node2D/Control/sldHumiditeGlobale.value, # 0.5
		"sea_level"         : $Node2D/Control/sldNiveauEau.value, # 0.0
		"saltwater_min_size" : $Node2D/Control/sldSaltwaterMinSize.value, # 1000
		"freshwater_max_size": min($Node2D/Control/sldFreshwaterMaxSize.value,$Node2D/Control/sldSaltwaterMinSize.value), # 999
		"lake_threshold"     : $Node2D/Control/sldLakeThreshold.value, # 5.0

		"river_iterations"   : $Node2D/Control/sldRiverIterations.value, # 2000
		"river_min_altitude" : $Node2D/Control/sldRiverMinAltitude.value, # 20.0
		"river_min_precipitation": $Node2D/Control/sldRiverMinPrecipitation.value, # 0.08
		"river_threshold"    : $Node2D/Control/sldRiverThreshold.value, # 1.0
		"river_base_flux"    : $Node2D/Control/sldRiverBaseFlux.value, # 1.0

		# Regions
		"nb_cases_regions"      : $Node2D/Control/sldNbCasesRegions.value, # 50
		"region_cost_flat" : $Node2D/Control/sldRegionCostFlat.value, # 1.0
		"region_cost_hill" : $Node2D/Control/sldRegionCostHill.value, # 2.0
		"region_cost_river": $Node2D/Control/sldRegionCostRiver.value, # 3.0
		"region_river_threshold" : $Node2D/Control/sldRegionRiverThreshold.value, # 1.0
		"region_budget_variation": $Node2D/Control/sldRegionBudgetVariation.value, # 0.5
		"region_noise_strength"  : $Node2D/Control/sldRegionNoiseStrength.value, # 0.5
		"region_iterations"	     : max(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 2,

		# Regions Ocean 
		"nb_cases_ocean_regions": $Node2D/Control/sldNbCasesOceanRegions.value, # 100
		"ocean_cost_flat"   : $Node2D/Control/sldOceanCostFlat.value, # 1.0
		"ocean_cost_deeper" : $Node2D/Control/sldOceanCostDeeper.value, # 2.0
		"ocean_noise_strength" : $Node2D/Control/sldOceanNoiseStrength.value, # 0.5
		"ocean_iterations"	   : max(Vector2i(circonference, circonference / 2).x, Vector2i(circonference, circonference / 2).y) * 2,

		# Resources
		"petrole_probability"  : $Node2D/Control/sldPetroleProbability.value, # 0.025
		"petrole_deposit_size" : $Node2D/Control/sldPetroleDepositSize.value, # 200.0
		"global_richness"      : $Node2D/Control/sldGlobalRichness.value, # 1.0
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
	var lbl = $Node2D/Control/renderProgress/Node2D/lblMapStatus
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
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
		update_map_label()

# ============================================================================
# SLIDER CALLBACKS
# ============================================================================

func _on_sld_rayon_planetaire_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = tr("RAYON_PLANET").format({"val": str(value)})

func _on_sld_temp_moy_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = tr("AVG_TEMP").format({"val": str(value)})

func _on_sld_haut_eau_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = tr("WATER_ELEVATION").format({"val": str(value)})

func _on_sld_precipitation_moy_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	var value_str = str(value)
	if len(value_str) != 4: value_str += "0"
	label.text = tr("AVG_PRECIPITATION").format({"val": value_str})

func _on_sld_percent_eau_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldPercentEau/Node2D/Label
	var value_str = str(value)
	if len(value_str) != 4: value_str += "0"
	label.text = tr("WATER_ELEVATION").format({"val": value_str})

func _on_sld_elevation_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = tr("BONUS_ELEVATION").format({"val": str(value)})

func _on_sld_thread_value_changed(value: float) -> void:    
	var label = $Node2D/Control/sldThread/Node2D/Label
	label.text = tr("THREAD_NUMBER").format({"val": str(value)})

func _on_sld_nb_cases_regions_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldNbCasesRegions/Node2D/Label
	label.text = tr("NB_CASE_REGION").format({"val": str(value)})

func _on_sld_ocean_ratio_value_changed(value: float) -> void:
	var label = $Node2D/Control/sldOceanRatio/Node2D/Label
	label.text = tr("OCEAN_RATIO").format({"val": str(int(value))})

func maj_labels() -> void:
	_on_sld_rayon_planetaire_value_changed($Node2D/Control/sldRayonPlanetaire.value)
	_on_sld_temp_moy_value_changed($Node2D/Control/sldTempMoy.value)
	_on_sld_haut_eau_value_changed($Node2D/Control/sldHautEau.value)
	_on_sld_precipitation_moy_value_changed($Node2D/Control/sldPrecipitationMoy.value)
	_on_sld_elevation_value_changed($Node2D/Control/sldElevation.value)
	_on_sld_thread_value_changed($Node2D/Control/sldThread.value)
	_on_sld_nb_cases_regions_value_changed($Node2D/Control/sldNbCasesRegions.value)
	# Slider optionnel - vérifier existence avant appel
	if has_node("Node2D/Control/sldOceanRatio"):
		_on_sld_ocean_ratio_value_changed($Node2D/Control/sldOceanRatio.value)

# ============================================================================
# LANGUAGE & SYSTEM
# ============================================================================

func _on_btn_french_pressed() -> void: _change_lang("fr")
func _on_btn_english_pressed() -> void: _change_lang("en")
func _on_btn_german_pressed() -> void: _change_lang("de")
func _on_btn_russian_pressed() -> void: _change_lang("ru")

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
	$Node2D/Control/planeteName/LineEdit.text = random_name
	
	# Sliders
	_randomize_slider($Node2D/Control/sldNbCasesRegions, true)
	_randomize_slider($Node2D/Control/sldRayonPlanetaire, true)
	_randomize_slider($Node2D/Control/sldTempMoy, true)
	_randomize_slider($Node2D/Control/sldHautEau, true)
	_randomize_slider($Node2D/Control/sldPrecipitationMoy, false)
	_randomize_slider($Node2D/Control/sldElevation, true)
	
	# Type
	var typePlanete = $Node2D/Control/typePlanete/ItemList
	typePlanete.select(randi() % typePlanete.item_count)
	
	maj_labels()

func _randomize_slider(slider: Slider, is_int: bool) -> void:
	if is_int:
		slider.value = randi_range(int(slider.min_value / slider.step), int(slider.max_value / slider.step)) * int(slider.step)
	else:
		slider.value = randf_range(slider.min_value, slider.max_value)
