extends RefCounted

class_name Region

static var colors : Array[Color] = [
	Color(0.894, 0.102, 0.110),
	Color(0.216, 0.494, 0.722),
	Color(0.302, 0.686, 0.290),
	Color(0.596, 0.306, 0.639),
	Color(1.000, 0.498, 0.000),
	Color(1.000, 1.000, 0.200),
	Color(0.651, 0.337, 0.157),
	Color(0.969, 0.506, 0.749),
	Color(0.600, 0.600, 0.600),
	Color(0.737, 0.741, 0.133),
	Color(0.090, 0.745, 0.811),
	Color(0.992, 0.682, 0.380),
	Color(0.419, 0.239, 0.600),
	Color(0.694, 0.349, 0.157),
	Color(0.984, 0.603, 0.600),
	Color(0.549, 0.337, 0.294),
	Color(0.890, 0.466, 0.760),
	Color(0.498, 0.498, 0.000),
	Color(0.737, 0.560, 0.560),
	Color(0.184, 0.800, 0.800),
	Color(0.800, 0.922, 0.773),
	Color(0.580, 0.403, 0.741),
	Color(0.929, 0.694, 0.125),
	Color(0.400, 0.400, 0.400),
	Color(0.600, 0.600, 0.200),
	Color(0.200, 0.600, 0.600),
	Color(0.800, 0.400, 0.400),
	Color(0.400, 0.800, 0.400),
	Color(0.400, 0.400, 0.800),
	Color(0.800, 0.800, 0.400),
	Color(0.400, 0.800, 0.800),
	Color(0.800, 0.400, 0.800),
	Color(0.600, 0.200, 0.600),
	Color(0.200, 0.600, 0.200),
	Color(0.600, 0.600, 0.800),
	Color(0.800, 0.600, 0.600),
	Color(0.600, 0.800, 0.600),
	Color(0.600, 0.600, 0.400),
	Color(0.400, 0.600, 0.600),
	Color(0.600, 0.400, 0.600)
]

var color : Color
var ensVoisins : Array[Region]
var cases : Array[Array]
var nbCaseLeft : int


func _init(nbCaseLeft: int) -> void:
	self.nbCaseLeft = nbCaseLeft
	self.color = color
	self.ensVoisins = []
	self.cases = []


func getColor() -> Color:
	return self.color
func getEnsVoisins() -> Array[Region]:
	return self.ensVoisins
func getCases() -> Array[Array]:
	return self.cases
func getNbCaseLeft() -> int:
	return self.nbCaseLeft


func addCase(case: Array) -> void:
	if not self.cases.has(case):
		self.cases.append(case)
		self.nbCaseLeft -= 1

func addVoisin(voisin: Region) -> void:
	if not self.ensVoisins.has(voisin):
		self.ensVoisins.append(voisin)


func majColor() -> void:
	var forbidden_colors = []
	for i in range(0, self.ensVoisins.size()):
		if self.ensVoisins[i].color != Color(0, 0, 0):
			forbidden_colors.append(self.ensVoisins[i].color)
	
	var available_colors = []
	for i in range(0, colors.size()):
		if not forbidden_colors.has(colors[i]):
			available_colors.append(colors[i])

	self.color = colors[randi_range(0, available_colors.size() - 1)]

func majNeighbors(ensCases: Dictionary) -> void:
	for case in self.cases:
		var x = case[0]
		var y = case[1]
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if ensCases.has(x + dx) and ensCases[x + dx].has(y + dy):
					var voisin = ensCases[x + dx][y + dy]
					if voisin != null and voisin != self:
						self.addVoisin(voisin)
						voisin.addVoisin(self)

	majColor()

func isComplete() -> bool:
	return self.nbCaseLeft == 0