extends RefCounted

## Classe abstraite pour les générateurs de cartes.
## Toutes les cartes héritent de cette classe et implémentent generate().
class_name MapGenerator

var planet: PlanetGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	self.planet = planet_ref

## Méthode abstraite à implémenter par les sous-classes
func generate() -> Image:
	push_error("MapGenerator.generate() doit être implémentée par la sous-classe")
	return null

## Fonction helper pour paralléliser le calcul sur tous les threads
func parallel_generate(img: Image, noises, calcul_function: Callable) -> void:
	var height = int(planet.circonference / 2)
	var thread_count = planet.nb_thread
	var rows_per_thread = int(ceil(height / float(thread_count)))
	
	var threadArray = []
	for i in range(thread_count):
		var y1 = i * rows_per_thread
		var y2 = min((i + 1) * rows_per_thread, height)
		if y1 >= height:
			break
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(_thread_worker.bind(img, noises, y1, y2, calcul_function))
	
	for thread in threadArray:
		thread.wait_to_finish()

func _thread_worker(img: Image, noises, y1: int, y2: int, calcul_function: Callable) -> void:
	for y in range(y1, y2):
		for x in range(planet.circonference):
			calcul_function.call(img, noises, x, y)

## Convertit les coordonnées 2D en coordonnées 3D cylindriques pour un bruit continu horizontalement
func get_cylindrical_coords(x: int, y: int) -> Vector3:
	var angle = (float(x) / float(planet.circonference)) * 2.0 * PI
	var cx = cos(angle) * planet.cylinder_radius
	var cz = sin(angle) * planet.cylinder_radius
	var cy = float(y)
	return Vector3(cx, cy, cz)

## Wrap horizontal pour les coordonnées x
func wrap_x(x: int) -> int:
	return posmod(x, planet.circonference)

## Crée une image vide aux dimensions de la planète
func create_image() -> Image:
	return Image.create(planet.circonference, planet.circonference / 2, false, Image.FORMAT_RGBA8)
