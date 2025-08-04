extends RefCounted

class_name Region

static var colors : Array[Color] = [
	Color.hex(0x672323FF),
	Color.hex(0x4f1919FF),
	Color.hex(0x341111FF),
	Color.hex(0x670f0fFF),
	Color.hex(0x4f0c0cFF),
	Color.hex(0x3b0909FF),
	Color.hex(0x793d3dFF),
	Color.hex(0x5d2f2fFF),
	Color.hex(0x412121FF),
	Color.hex(0x442075FF),
	Color.hex(0x34175aFF),
	Color.hex(0x291345FF),
	Color.hex(0x503475FF),
	Color.hex(0x422c60FF),
	Color.hex(0x2d1f41FF),
	Color.hex(0x242c5aFF),
	Color.hex(0x1e2448FF),
	Color.hex(0x151934FF),
	Color.hex(0x1a3d53FF),
	Color.hex(0x153141FF),
	Color.hex(0x112834FF),
	Color.hex(0x134f39FF),
	Color.hex(0x103e2cFF),
	Color.hex(0x0d3727FF),
	Color.hex(0x6b5f16FF),
	Color.hex(0x6b5f16FF),
	Color.hex(0x4c430fFF),
	Color.hex(0x913926FF),
	Color.hex(0x833424FF),
	Color.hex(0x753122FF)
]

var color : Color
var ensVoisins : Array[Region]
var cases : Array[Array]
var nbCaseLeft : int
var isComplete : bool


func _init(nbCaseLeft: int) -> void:
	self.nbCaseLeft = nbCaseLeft
	self.color = color
	self.ensVoisins = []
	self.cases = []
	self.isComplete = false


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

func setColorCases(img: Image) -> void:
	for case in self.cases:
		var x = case[0]
		var y = case[1]
		if img.get_pixel(x, y) != self.color:
			img.set_pixel(x, y, self.color)

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

func is_complete() -> bool:
	return self.nbCaseLeft == 0

func is_potential_complete(ensCases: Dictionary) -> bool:
	if self.isComplete:
		return true
	else :
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
