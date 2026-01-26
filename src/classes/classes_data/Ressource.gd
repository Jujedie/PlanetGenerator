extends RefCounted

class_name Ressource

var nom        : String
var couleur    : Color
var probabilite: float
var taille     : float  # Taille moyenne du gisement

func _init(nom_param: String, couleur_param: Color, probabilite_param: float, taille_param: float = 100.0) -> void:
	self.nom = nom_param
	self.couleur = couleur_param
	self.probabilite = probabilite_param
	self.taille = taille_param

func getColor() -> Color:
		return self.couleur
		
func getProbabilite() -> float:
		return self.probabilite
		
func getTaille() -> float:
		return self.taille