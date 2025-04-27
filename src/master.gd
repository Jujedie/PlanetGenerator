extends Node2D

func _ready() -> void:
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = "Rayon Planétaire : 0 | 0 <-> 1"
	label = $Node2D/Control/sldTempMoy/Node2D/Label
	label.text = "Température Moyenne : -273"
	label = $Node2D/Control/sldHautEau/Node2D/Label
	label.text = "Elevation des mers : -100"
	label = $Node2D/Control/sldPrecipitationMoy/Node2D/Label
	label.text = "Précipitation Moyenne : 0 | 0 <-> 1"
	pass

func _on_sld_rayon_planetaire_value_changed(value: float) -> void:
	var sld = $Node2D/Control/sldRayonPlanetaire
	var label = $Node2D/Control/sldRayonPlanetaire/Node2D/Label
	label.text = "Rayon Planétaire : "+str(sld.value)+" | 0 <-> 1"


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
	label.text = "Précipitation Moyenne : "+str(sld.value)+" | 0 <-> 1"
