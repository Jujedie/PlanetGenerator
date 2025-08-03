extends Node2D

var planetGenerator : PlanetGenerator
var maps			: Array[String]
var map_index		: int = 0
var langue			: String = "fr"

func _ready() -> void:
	if OS.get_locale_language() != "fr":
		langue = "en"

	TranslationServer.set_locale(langue)

	# Initialisation des paramètres de la planète
	maj_labels()

func _on_sld_rayon_planetaire_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldRayonPlanetaire
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = tr("RAYON_PLANET").format({"val": str(sld.value)})


func _on_sld_temp_moy_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldTempMoy
	var label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = tr("AVG_TEMP").format({"val": str(sld.value)})


func _on_sld_haut_eau_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldHautEau
	var label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = tr("WATER_ELEVATION").format({"val": str(sld.value)})


func _on_sld_precipitation_moy_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldPrecipitationMoy
	var label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	var value_str = str(sld.value)
	if len(value_str) != 4:
		value_str = value_str + "0"
	label.text = tr("AVG_PRECIPITATION").format({"val": value_str})


func _on_sld_percent_eau_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldPercentEau
	var label = $Node2D/Control/sldPercentEau/Node2D/Label
	var value_str = str(sld.value)
	if len(value_str) != 4:
		value_str = value_str + "0"
	label.text = tr("WATER_ELEVATION").format({"val": value_str})


func _on_sld_elevation_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldElevation
	var label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = tr("BONUS_ELEVATION").format({"val": str(sld.value)})

func _on_sld_thread_value_changed(value: float) -> void:	
	var sld = $Node2D/Control/sldThread
	var label = $Node2D/Control/sldThread/Node2D/Label
	label.text = tr("THREAD_NUMBER").format({"val": str(sld.value)})


func _on_sld_nb_cases_regions_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldNbCasesRegions
	var label = $Node2D/Control/sldNbCasesRegions/Node2D/Label
	label.text = tr("NB_CASE_REGION").format({"val": str(sld.value)})

func _on_btn_comfirme_pressed() -> void:
	var nom = $Node2D/Control/planeteName/LineEdit
	print("\nNom de la planète : "+nom.text)
	var sldRayonPlanetaire = $Node2D/Control/sldRayonPlanetaire
	print("\nRayon Planétaire : "+str(sldRayonPlanetaire.value))
	var sldTempMoy = $Node2D/Control/sldTempMoy
	print("\nTempérature Moyenne : "+str(sldTempMoy.value))
	var sldHautEau = $Node2D/Control/sldHautEau
	print("\nElevation des mers : "+str(sldHautEau.value))
	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	print("\nPrécipitation Moyenne : "+str(sldPrecipitationMoy.value)+"\n")
	var sldElevation = $Node2D/Control/sldElevation
	print("\nElevation bonus : "+str(sldElevation.value))
	var sldThread = $Node2D/Control/sldThread
	print("\nNombre de thread : "+str(sldThread.value))
	var typePlanete = $Node2D/Control/typePlanete/ItemList
	print("\nType d'atmosphère : "+typePlanete.get_item_text(typePlanete.get_selected_id()))

	if typePlanete.get_selected_id() == -1:
		typePlanete.select(0)

	maps      = []
	map_index = 0
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = null

	var renderProgress = $Node2D/Control/renderProgress

	planetGenerator = PlanetGenerator.new(nom.text, sldRayonPlanetaire.value, sldTempMoy.value, sldHautEau.value, sldPrecipitationMoy.value, sldElevation.value , sldThread.value, typePlanete.get_selected_id(), renderProgress)

	var echelle = 100.0 / sldRayonPlanetaire.value
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.scale = Vector2(echelle, echelle)
	planetGenerator.finished.connect(_on_planetGenerator_finished)

	print("Génération de la planète : "+nom.text)

	var thread = Thread.new()
	thread.start(planetGenerator.generate_planet)

	$Node2D/Control/btnComfirmer/btnComfirme.disabled      = true
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = true
	$Node2D/Control/btnSuivant/btnSuivant.disabled         = true
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled     = true


func _on_planetGenerator_finished() -> void:
	call_deferred("_on_planetGenerator_finished_main")

func _on_planetGenerator_finished_main() -> void:
	maps = planetGenerator.getMaps()
	map_index = 0

	$Node2D/Control/btnComfirmer/btnComfirme.disabled = false
	$Node2D/Control/btnSauvegarder/btnSauvegarder.disabled = false
	$Node2D/Control/btnSuivant/btnSuivant.disabled = false
	$Node2D/Control/btnPrecedant/btnPrecedant.disabled = false
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

func _on_btn_sauvegarder_pressed() -> void:
	if planetGenerator != null :
		var prompt_instance = load("res://data/scn/prompt.tscn").instantiate()
		$Node2D/Control.add_child(prompt_instance)
		prompt_instance.position = Vector2i(200, 125)
		prompt_instance.get_child(-1).get_child(-1).pressed.connect(_on_prompt_confirmed)

func _on_prompt_confirmed() -> void:
	var prompt = $Node2D/Control.get_child(-1)
	var input = prompt.get_child(1).get_child(1).text
	if input != "":
		planetGenerator.cheminSauvegarde = input
		planetGenerator.save_maps()
		print("Planète sauvegardée dans : ", planetGenerator.cheminSauvegarde)
	else:
		print("Aucun chemin de sauvegarde spécifié.")
	prompt.queue_free()

func _on_btn_suivant_pressed() -> void:
	if maps.is_empty():
		print("Aucune carte disponible.")
		return 

	map_index += 1
	if map_index >= maps.size():
		map_index = 0

	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])

func _on_btn_precedant_pressed() -> void:
	if maps.is_empty():
		print("Aucune carte disponible.")
		return 

	map_index -= 1
	if map_index < 0:
		map_index = maps.size() - 1
	
	var img = Image.new()
	var err = img.load(maps[map_index])
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = tex
	else:
		print("Erreur lors du chargement de l'image: ", maps[map_index])


func _on_btn_quitter_pressed() -> void:
	get_tree().quit()

func _on_btn_french_pressed() -> void:
	if langue == "fr":
		print("La langue est déjà en français.")
		return
	langue = "fr"
	TranslationServer.set_locale(langue)
	print("Langue changée en français.")
	maj_labels()

func _on_btn_english_pressed() -> void:
	if langue == "en":
		print("The language is already set to English.")
		return
	
	langue = "en"
	TranslationServer.set_locale(langue)
	print("Language changed to English.")
	maj_labels()

func _on_btn_german_pressed() -> void:
	if langue == "de":
		print("Die Sprache ist bereits auf Deutsch eingestellt.")
		return

	langue = "de"
	TranslationServer.set_locale(langue)
	print("Sprache auf Deutsch geändert.")
	maj_labels()

func _on_btn_russian_pressed() -> void:
	if langue == "ru":
		print("Язык уже установлен на русский.")
		return

	langue = "ru"
	TranslationServer.set_locale(langue)
	print("Язык изменен на русский.")
	maj_labels()

func maj_labels() -> void:
	var sldRayonPlanetaire = $Node2D/Control/sldRayonPlanetaire
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = tr("RAYON_PLANET").format({"val": str(sldRayonPlanetaire.value)})

	var sldTempMoy = $Node2D/Control/sldTempMoy
	label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = tr("AVG_TEMP").format({"val": str(sldTempMoy.value)})

	var sldHautEau = $Node2D/Control/sldHautEau
	label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = tr("WATER_ELEVATION").format({"val": str(sldHautEau.value)})

	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	label.text = tr("AVG_PRECIPITATION").format({"val": str(sldPrecipitationMoy.value)})

	var sldElevation = $Node2D/Control/sldElevation
	label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = tr("BONUS_ELEVATION").format({"val": str(sldElevation.value)})

	var sldThread = $Node2D/Control/sldThread
	label = $Node2D/Control/sldThread/Node2D/Label
	label.text = tr("THREAD_NUMBER").format({"val": str(sldThread.value)})

	var sldNbCasesRegions = $Node2D/Control/sldNbCasesRegions
	label = $Node2D/Control/sldNbCasesRegions/Node2D/Label
	label.text = tr("NB_CASE_REGION").format({"val": str(sldNbCasesRegions.value)})
