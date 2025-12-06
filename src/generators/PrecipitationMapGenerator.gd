extends MapGenerator

class_name PrecipitationMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()

	# Bruit principal - grandes masses d'air humides/sèches
	var noise_main = FastNoiseLite.new()
	noise_main.seed = randi()
	noise_main.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_main.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_main.frequency = 2.5 / float(planet.circonference)
	noise_main.fractal_octaves = 6
	noise_main.fractal_gain = 0.55
	noise_main.fractal_lacunarity = 2.0

	# Bruit de détail pour les variations locales
	var noise_detail = FastNoiseLite.new()
	noise_detail.seed = randi()
	noise_detail.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_detail.frequency = 6.0 / float(planet.circonference)
	noise_detail.fractal_octaves = 4
	noise_detail.fractal_gain = 0.5
	noise_detail.fractal_lacunarity = 2.0

	# Bruit cellulaire pour créer des zones de pluie irrégulières
	var noise_cells = FastNoiseLite.new()
	noise_cells.seed = randi()
	noise_cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise_cells.frequency = 4.0 / float(planet.circonference)
	noise_cells.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise_cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE

	var noises = [noise_main, noise_detail, noise_cells]
	parallel_generate(img, noises, _calcul)

	return img

func _calcul(img: Image, noises, x: int, y: int) -> void:
	var coords = get_cylindrical_coords(x, y)
	var noise_main = noises[0]
	var noise_detail = noises[1]
	var noise_cells = noises[2]
	
	# Latitude normalisée (0 à l'équateur, 1 aux pôles)
	var latitude = abs((float(y) / float(planet.circonference / 2)) - 0.5) * 2.0
	
	# Bruit principal - zones de haute/basse pression atmosphérique
	var main_value = noise_main.get_noise_3d(coords.x, coords.y, coords.z)
	main_value = (main_value + 1.0) / 2.0
	
	# Bruit de détail
	var detail_value = noise_detail.get_noise_3d(coords.x, coords.y, coords.z)
	detail_value = (detail_value + 1.0) / 2.0
	
	# Bruit cellulaire pour créer des fronts météo
	var cell_value = noise_cells.get_noise_3d(coords.x, coords.y, coords.z)
	cell_value = (cell_value + 1.0) / 2.0
	
	# Combiner les bruits de manière organique
	var base_precip = main_value * 0.6 + detail_value * 0.25 + cell_value * 0.15
	
	# Légère influence de la latitude
	var lat_influence = 1.0
	if latitude < 0.2:
		lat_influence = 1.0 + 0.15 * (1.0 - latitude / 0.2)
	elif latitude > 0.25 and latitude < 0.4:
		var t = (latitude - 0.25) / 0.15
		lat_influence = 1.0 - 0.2 * sin(t * PI)
	elif latitude > 0.85:
		lat_influence = 1.0 - 0.3 * (latitude - 0.85) / 0.15
	
	var value = base_precip * lat_influence
	value = value * (0.4 + planet.avg_precipitation * 0.6)
	value = clamp(value, 0.0, 1.0)

	img.set_pixel(x, y, Enum.getPrecipitationColor(value))
