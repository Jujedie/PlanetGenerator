extends RefCounted

class_name Ressource

var nom        : String
var couleur    : Color
var probabilite: float

func _init(nom_param: String, couleur_param: Color, probabilite_param: float) -> void:
	self.nom = nom_param
	self.couleur = couleur_param
	self.probabilite = probabilite_param

func getColor() -> Color:
		return self.color
func getProbabilite() -> float:
		return self.probabilite