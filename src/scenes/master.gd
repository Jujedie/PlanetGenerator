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
	"petrole_map.png": "MAP_PETROLE",
	"ressource_map.png": "MAP_RESOURCES",
	"precipitation_map.png": "MAP_PRECIPITATION",
	"temperature_map.png": "MAP_TEMPERATURE",
	"water_map.png": "MAP_WATER",
	"river_map.png": "MAP_RIVERS",
	"biome_map.png": "MAP_BIOMES",
	"final_map.png": "MAP_FINAL",
	"region_map.png": "MAP_REGIONS",
	"preview.png": "MAP_PREVIEW"
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
	var nom                 = $Node2D/Control/planeteName/LineEdit
	var sldNbCasesRegions   = $Node2D/Control/sldNbCasesRegions
	var sldRayonPlanetaire  = $Node2D/Control/sldRayonPlanetaire
	var sldTempMoy          = $Node2D/Control/sldTempMoy
	var sldHautEau          = $Node2D/Control/sldHautEau
	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	var sldElevation        = $Node2D/Control/sldElevation
	var sldThread           = $Node2D/Control/sldThread
	var typePlanete         = $Node2D/Control/typePlanete/ItemList
	
	# Slider optionnel pour ratio océan/continent (défaut 70% si absent)
	var ocean_ratio_val = 70.0
	if has_node("Node2D/Control/sldOceanRatio"):
		ocean_ratio_val = $Node2D/Control/sldOceanRatio.value
	
	#var sldErosionIterations = $Node2D/Control/sldErosionIterations
	#var sldTectonicYears     = $Node2D/Control/sldTectonicYears
	#var sldAtmosphereSteps   = $Node2D/Control/sldAtmosphereSteps
	#var sldDensitePlanetes   = $Node2D/Control/sldDensitePlanetes
	#var sldSeed			  = $Node2D/Control/sldSeed
 
	if typePlanete.get_selected_id() == -1:
		typePlanete.select(0)

	# Reset state
	maps      = []
	map_index = 0
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = null

	var renderProgress = $Node2D/Control/renderProgress
	var lblMapStatus   = $Node2D/Control/renderProgress/Node2D/lblMapStatus

	# Initialize Generator
	planetGenerator = PlanetGenerator.new(
		nom.text, 
		sldRayonPlanetaire.value, 
		sldTempMoy.value, 
		sldHautEau.value, 
		sldPrecipitationMoy.value, 
		# Placeholders until sld are created
		100, # sldErosionIterations.value,
		100_000_000, # sldTectonicYears.value,
		1000, # sldAtmosphereSteps.value,
		sldElevation.value, 
		sldThread.value, 
		typePlanete.get_selected_id(), 
		renderProgress, 
		lblMapStatus, 
		sldNbCasesRegions.value,
		"user://temp/",
		5.51, # Default density (Earth-like)
		0, # Random seed by default
		ocean_ratio_val # Ocean coverage percentage (40-90%)
	)

	var echelle = 100.0 / sldRayonPlanetaire.value
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.scale = Vector2(echelle, echelle)
	
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
	if planetGenerator != null :
		var prompt_instance = load("res://data/scn/prompt.tscn").instantiate()
		$Node2D/Control.add_child(prompt_instance)
		prompt_instance.position = Vector2i(200, 125)
		prompt_instance.get_child(2).get_child(0).pressed.connect(_on_prompt_confirmed)

func _on_prompt_confirmed() -> void:
	var prompt = $Node2D/Control.get_child(-1)
	var input_line_edit = prompt.get_child(1).get_child(1)
	var input = input_line_edit.text
	input_line_edit.editable = false
	prompt.get_child(2).get_child(0).disabled = true
	prompt.get_child(2).get_child(1).disabled = true
	if input != "":
		if planetGenerator.nom == "":
			planetGenerator.nom = "Planète Générée"
		planetGenerator.cheminSauvegarde = input + "/" + planetGenerator.nom 
		planetGenerator.save_maps()
		print("Planète sauvegardée dans : ", planetGenerator.cheminSauvegarde)
	else:
		print("Aucun chemin de sauvegarde spécifié.")
	prompt.queue_free()

func _on_btn_randomise_pressed() -> void:
	randomize()
	
	# Name
	var prefixes = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross"]
	var suffixes = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "b", "c", "d"]
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
