extends Node2D

var planetGenerator : PlanetGenerator
var map_actuelle    : Image
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
	print("Nom de la planète : "+nom.text)
	var sldRayonPlanetaire = $Node2D/Control/sldRayonPlanetaire
	print("Rayon Planétaire : "+str(sldRayonPlanetaire.value))
	var sldTempMoy = $Node2D/Control/sldTempMoy
	print("Température Moyenne : "+str(sldTempMoy.value))
	var sldHautEau = $Node2D/Control/sldHautEau
	print("Elevation des mers : "+str(sldHautEau.value))
	var sldPrecipitationMoy = $Node2D/Control/sldPrecipitationMoy
	print("Précipitation Moyenne : "+str(sldPrecipitationMoy.value)+"\n")
	var sldPercentEau = $Node2D/Control/sldPercentEau
	print("Pourcentage d'eau : "+str(sldPercentEau.value))
	var sldElevation = $Node2D/Control/sldElevation
	print("Elevation bonus : "+str(sldElevation.value))
	var sldThread = $Node2D/Control/sldThread
	print("Nombre de thread : "+str(sldThread.value))

	var renderProgress = $Node2D/Control/renderProgress
	print("Render Progress : ")
	print(renderProgress)
	planetGenerator = PlanetGenerator.new(nom.text, sldRayonPlanetaire.value, sldTempMoy.value, sldHautEau.value, sldPrecipitationMoy.value, sldPercentEau.value, sldElevation.value , sldThread.value, renderProgress )
	
	print("Génération de la planète : "+nom.text)
	planetGenerator.generate_planet()
	maps = planetGenerator.getMaps()

	print()
	
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = load(maps[map_index])

func _on_btn_sauvegarder_pressed() -> void:
	planetGenerator.save_planet()

func _on_btn_suivant_pressed() -> void:
	map_index += 1
	if map_index >= maps.size():
		map_index = 0
	
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = load(maps[map_index])

func _on_btn_precedant_pressed() -> void:
	map_index -= 1
	if map_index < 0:
		map_index = maps.size() - 1
	
	$Node2D/Control/SubViewportContainer/SubViewport/Fond/Map.texture = load(maps[map_index])
