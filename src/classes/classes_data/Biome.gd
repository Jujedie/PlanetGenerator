extends RefCounted

class_name Biome

const NULL = null

var nom: String
var couleur: Color
var couleur_vegetation: Color

var interval_temp		  : Array[int]
var interval_precipitation: Array[float]
var interval_elevation    : Array[int]
var water_need			  : bool
var type_planete          : Array
var is_eau_douce           : bool
var is_river               : bool  # Si true, ce biome n'apparaît que sur river_map

func _init(nom_param: String, couleur_param: Color, couleur_vegetation_param: Color, interval_temp_param: Array[int], interval_precipitation_param: Array[float], interval_elevation_param: Array[int], water_need_param: bool, type_planete_param: Array = [0], is_eau_douce_param: bool = false, is_river_param: bool = false) -> void:
	self.nom     = nom_param
	self.couleur = couleur_param
	self.couleur_vegetation = couleur_vegetation_param

	self.interval_temp          = interval_temp_param
	self.interval_precipitation = interval_precipitation_param
	self.interval_elevation     = interval_elevation_param
	self.water_need             = water_need_param
	self.type_planete           = type_planete_param
	self.is_eau_douce			= is_eau_douce_param
	self.is_river				= is_river_param

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
func get_type_planete() -> Array:
	return self.type_planete

func isRiver() -> bool:
	return self.is_river
func isEauDouce() -> bool:
	return self.is_eau_douce

func set_interval_elevation(interval_elevation_param: Array[int]):
	self.interval_elevation = interval_elevation_param
func set_interval_temp(interval_temp_param: Array[int]):
	self.interval_temp = interval_temp_param
func set_interval_precipitation(interval_precipitation_param: Array[float]):
	self.interval_precipitation = interval_precipitation_param
func set_water_need(water_need_param: bool):
	self.water_need = water_need_param
func set_nom(nom_param: String):
	self.nom = nom_param
func set_couleur(couleur_param: Color):
	self.couleur = couleur_param
func set_couleur_vegetation(couleur_vegetation_param: Color):
	self.couleur_vegetation = couleur_vegetation_param
func set_type_planete(type_planete_param: Array):
	self.type_planete = type_planete_param
func set_is_river(is_river_param: bool):
	self.is_river = is_river_param
func set_is_eau_douce(is_eau_douce_param: bool):
	self.is_eau_douce = is_eau_douce_param
