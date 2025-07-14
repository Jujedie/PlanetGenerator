extends Node2D

var planetGenerator : PlanetGenerator
var maps            : Array[String]
var map_index       : int = 0

func _ready() -> void:
	var sldRayonPlanetaire = $Node2D/Control/sldRayonPlanetaire
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = "Rayon Planétaire : "+str(sldRayonPlanetaire.value)
	
	var sldTempMoy = $Node2D/Control/sldTempMoy
	label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = "Température Moyenne : "+str(sldTempMoy.value)
	
	var sldHautEau = $Node2D/Control/sldHautEau
	label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = "Elevation des mers : "+str(sldHautEau.value)
	
	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	label.text = "Précipitation Moyenne : "+str(sldPrecipitationMoy.value)+" | 0 <-> 1\n"

	var sldPercentEau = $Node2D/Control/sldPercentEau
	label = $Node2D/Control/sldPercentEau/Node2D/Label
	label.text = "Pourcentage d'eau : "+str(sldPercentEau.value)+" | 0 <-> 1\n"

	var sldElevation = $Node2D/Control/sldElevation
	label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = "Elevation bonus : "+str(sldElevation.value)

	var sldThread = $Node2D/Control/sldThread
	label = $Node2D/Control/sldThread/Node2D/Label
	label.text = "Nombre de thread : "+str(sldThread.value)


func _on_sld_rayon_planetaire_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldRayonPlanetaire
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = "Rayon Planétaire : "+str(sld.value)


func _on_sld_temp_moy_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldTempMoy
	var label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = "Température Moyenne : "+str(sld.value)


func _on_sld_haut_eau_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldHautEau
	var label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = "Elevation des mers : "+str(sld.value)


func _on_sld_precipitation_moy_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldPrecipitationMoy
	var label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	var value_str = str(sld.value)
	if len(value_str) != 4:
		value_str = value_str + "0"
	label.text = "Précipitation Moyenne : "+value_str+" | 0 <-> 1"


func _on_sld_percent_eau_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldPercentEau
	var label = $Node2D/Control/sldPercentEau/Node2D/Label
	var value_str = str(sld.value)
	if len(value_str) != 4:
		value_str = value_str + "0"
	label.text = "Pourcentage d'eau : "+value_str+" | 0 <-> 1"


func _on_sld_elevation_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldElevation
	var label = $Node2D/Control/sldElevation/Node2D/Label
	label.text = "Elevation bonus : "+str(sld.value)

func _on_sld_thread_value_changed(value: float) -> void:	
	var sld = $Node2D/Control/sldThread
	var label = $Node2D/Control/sldThread/Node2D/Label
	label.text = "Nombre de thread : "+str(sld.value)


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

	var renderProgress = $Node2D/Control/renderProgress

	planetGenerator = PlanetGenerator.new(nom.text, sldRayonPlanetaire.value, sldTempMoy.value, sldHautEau.value, sldPrecipitationMoy.value, sldElevation.value , sldThread.value, typePlanete.get_selected_id(), renderProgress )

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
