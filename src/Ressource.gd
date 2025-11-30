extends RefCounted

class_name Ressource

var nom        : String
var couleur    : Color
var probabilite: float
var cases      : Array[Array]
var avgSilonTaille: int
var nbCaseLeft    : int
var isComplete    : bool

func _init(nom: String, couleur_param: Color, probabilite_param: float, avgSilonTaille: int) -> void:
		self.nom = nom
		self.couleur = couleur_param
		self.probabilite = probabilite_param
		self.cases = []

		randomize()
		self.avgSilonTaille = avgSilonTaille
		self.nbCaseLeft = randi() % ((int)(avgSilonTaille / 2.0)) + (int)((avgSilonTaille / 2.0))
		self.isComplete = false

func getColor() -> Color:
		return self.color
func getCases() -> Array[Array]:
		return self.cases
func getProbabilite() -> float:
		return self.probabilite
func getAvgSilonTaille() -> float:
		return self.avgSilonTaille
func getNbCaseLeft() -> int:
		return self.nbCaseLeft


func addCase(case: Array) -> void:
		if not self.cases.has(case):
				self.cases.append(case)
				self.nbCaseLeft -= 1

func setColorCases(img: Image) -> void:
		for case in self.cases:
				var x = case[0]
				var y = case[1]
				if img.get_pixel(x, y) != self.color:
						img.set_pixel(x, y, self.color)


func is_complete() -> bool:
		return self.nbCaseLeft == 0

func is_potential_complete(ensCases: Dictionary) -> bool:
		if self.isComplete:
				return true
		else:
			if self.cases.size() == 0:
					return false

			for case in self.cases:
					var x = case[0]
					var y = case[1]
					for dx in [-1, 0, 1]:
							for dy in [-1, 0, 1]:
									if dx == 0 and dy == 0:
											continue
									var nx = x + dx
									var ny = y + dy

									if not ensCases.has(nx) or not ensCases[nx].has(ny):
											return false

			self.isComplete = true
			return true

static func copy(ressource: Ressource) -> Ressource:
		var new_ressource = Ressource.new(ressource.nom, ressource.couleur, ressource.probabilite, ressource.avgSilonTaille)
		new_ressource.cases = ressource.cases.duplicate()
		new_ressource.nbCaseLeft = ressource.nbCaseLeft
		new_ressource.isComplete = ressource.isComplete
		return new_ressource