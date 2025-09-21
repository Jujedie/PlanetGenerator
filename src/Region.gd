extends RefCounted

class_name Region

static var nextColor = [0,0,0,255]
static var colorMutex = Mutex.new()

var color : Color
var ensVoisins : Array[Region]
var cases : Array[Array]
var nbCaseLeft : int
var isComplete : bool


func _init(nbCaseLeft_param: int) -> void:
        self.nbCaseLeft = nbCaseLeft_param

        # Protéger l'accès concurrent à nextColor avec un mutex
        colorMutex.lock()

        self.color = Color(nextColor[0] / 255.0, nextColor[1] / 255.0, nextColor[2] / 255.0, nextColor[3] / 255.0)

        # Utiliser un pas plus grand pour créer des couleurs plus distinctes
        var step = 17  # 255/17 ≈ 15 niveaux par canal, donnant beaucoup plus de couleurs distinctes
        nextColor[0] += step
        if nextColor[0] > 255:
                nextColor[0] = nextColor[0] % 256
                nextColor[1] += step
        if nextColor[1] > 255:
                nextColor[1] = nextColor[1] % 256
                nextColor[2] += step
        if nextColor[2] > 255:
                nextColor[2] = nextColor[2] % 256

        colorMutex.unlock()

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

static func reset_color_counter() -> void:
        colorMutex.lock()
        nextColor = [0, 0, 0, 255]
        colorMutex.unlock()
