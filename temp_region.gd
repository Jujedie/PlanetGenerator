@tool
extends RefCounted
class_name Region

static var nextColor = [0,0,0,255]
static var colorMutex = Mutex.new()

var color : Color
var ensVoisins : Array[Region]
var cases : Array[Vector2i]
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
