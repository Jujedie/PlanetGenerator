extends RefCounted

class_name Biome

var nom: String
var couleur: Color
var couleur_vegetation: Color

var interval_temp		  : Array[int]
var interval_precipitation: Array[float]
var interval_elevation    : Array[int]
var water_need			  : bool

func _init(nom_param: String, couleur_param: Color, couleur_vegetation_param: Color, interval_temp_param: Array[int], interval_precipitation_param: Array[float], interval_elevation_param: Array[int], water_need_param: bool):
	self.nom     = nom_param
	self.couleur = couleur_param
	self.couleur_vegetation = couleur_vegetation_param

	self.interval_temp          = interval_temp_param
	self.interval_precipitation = interval_precipitation_param
	self.interval_elevation     = interval_elevation_param
	self.water_need             = water_need_param

func get_interval_elevation() ->  Array[int]:
	return self.interval_elevation
func get_interval_temp() -> Array[int]:
	return self.interval_temp
func get_interval_precipitation() -> Array[float]:
	return self.interval_precipitation
func get_water_need() -> bool:
	return self.water_need
func get_nom() -> String:
	return self.nom
func get_couleur() -> Color:
	return self.couleur
func get_couleur_vegetation() -> Color:
	return self.couleur_vegetation

func set_interval_elevation(interval_elevation: Array[int]):
	self.interval_elevation = interval_elevation
func set_interval_temp(interval_temp: Array[int]):
	self.interval_temp = interval_temp
func set_interval_precipitation(interval_precipitation: Array[float]):
	self.interval_precipitation = interval_precipitation
func set_water_need(water_need: bool):
	self.water_need = water_need
func set_nom(nom: String):
	self.nom = nom
func set_couleur(couleur: Color):
	self.couleur = couleur
func set_couleur_vegetation(couleur_vegetation: Color):
	self.couleur_vegetation = couleur_vegetation