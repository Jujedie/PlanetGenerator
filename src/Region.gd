extends RefCounted

class_name Region

static var colors : Array[Color] = [
	Color.hex(0x377EB8FF),
	Color.hex(0x4DAF4AFF),
	Color.hex(0x984EA3FF),
	Color.hex(0xFF7F00FF),
	Color.hex(0xFFFF33FF),
	Color.hex(0xA65628FF),
	Color.hex(0xF781BFFF),
	Color.hex(0x999999FF),
	Color.hex(0xBCBD22FF),
	Color.hex(0x17BECFFF),
	Color.hex(0xFCA85EFF),
	Color.hex(0x6B3D99FF),
	Color.hex(0xB15A28FF),
	Color.hex(0xFBAA99FF),
	Color.hex(0x8C564BFF),
	Color.hex(0xE377C2FF),
	Color.hex(0x7F7F00FF),
	Color.hex(0xBC9090FF),
	Color.hex(0x2FD0CCFF),
	Color.hex(0xCCEBC5FF),
	Color.hex(0x9467BDFF),
	Color.hex(0xEDC949FF),
	Color.hex(0x666666FF),
	Color.hex(0x999933FF),
	Color.hex(0x339999FF),
	Color.hex(0xCC6666FF),
	Color.hex(0x66CC66FF),
	Color.hex(0x6666CCFF),
	Color.hex(0xCCCC66FF),
	Color.hex(0x66CCCCFF),
	Color.hex(0xCC66CCFF),
	Color.hex(0x993399FF),
	Color.hex(0x339933FF),
	Color.hex(0x9999CCFF),
	Color.hex(0xCC9999FF),
	Color.hex(0x99CC99FF),
	Color.hex(0x999966FF),
	Color.hex(0x669999FF),
	Color.hex(0x996699FF)
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

func isComplete() -> bool:
	return self.nbCaseLeft == 0
