extends MapGenerator

class_name NuageMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()
	
	# Pas de nuages pour les planètes sans atmosphère (3) ou volcaniques (2)
	if planet.atmosphere_type == 2 or planet.atmosphere_type == 3:
		img.fill(Color(0, 0, 0, 0))
		return img
	
	var base_seed = randi()

	# Bruit cellulaire pour formes circulaires
	var cell_noise = FastNoiseLite.new()
	cell_noise.seed = base_seed
	cell_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	cell_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cell_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cell_noise.frequency = 6.0 / float(planet.circonference)
	
	# Bruit de forme pour varier les nuages
	var shape_noise = FastNoiseLite.new()
	shape_noise.seed = base_seed + 1
	shape_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	shape_noise.frequency = 4.0 / float(planet.circonference)
	shape_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	shape_noise.fractal_octaves = 4
	shape_noise.fractal_gain = 0.5
	
	# Bruit de détail pour bords irréguliers
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = base_seed + 2
	detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency = 15.0 / float(planet.circonference)
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 3

	var noises = [cell_noise, shape_noise, detail_noise]
	parallel_generate(img, noises, _calcul)

	return img

func _calcul(img: Image, noises, x: int, y: int) -> void:
	var coords = get_cylindrical_coords(x, y)
	
	var cell_noise = noises[0]
	var shape_noise = noises[1]
	var detail_noise = noises[2]
	
	# Valeur cellulaire - crée des formes rondes
	var cell_val = cell_noise.get_noise_3d(coords.x, coords.y, coords.z)
	cell_val = 1.0 - abs(cell_val)
	
	# Forme générale
	var shape_val = shape_noise.get_noise_3d(coords.x, coords.y, coords.z)
	shape_val = (shape_val + 1.0) / 2.0
	
	# Détail des bords
	var detail_val = detail_noise.get_noise_3d(coords.x, coords.y, coords.z) * 0.15
	
	# Combiner
	var cloud_val = cell_val * 0.6 + shape_val * 0.4 + detail_val
	
	# Seuil pour créer les nuages
	var threshold = 0.55
	
	if cloud_val > threshold:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
	else:
		img.set_pixel(x, y, Color.hex(0x00000000))
