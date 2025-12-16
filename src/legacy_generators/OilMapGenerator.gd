extends MapGenerator

class_name OilMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()

	# Bruit principal pour les bassins sédimentaires
	var noise_basin = FastNoiseLite.new()
	noise_basin.seed = randi()
	noise_basin.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_basin.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_basin.frequency = 1.0 / float(planet.circonference)
	noise_basin.fractal_octaves = 5
	noise_basin.fractal_gain = 0.5
	noise_basin.fractal_lacunarity = 2.0

	# Bruit pour les gisements locaux
	var noise_deposit = FastNoiseLite.new()
	noise_deposit.seed = randi()
	noise_deposit.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise_deposit.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_deposit.frequency = 5.0 / float(planet.circonference)
	noise_deposit.fractal_octaves = 4
	noise_deposit.fractal_gain = 0.6
	noise_deposit.fractal_lacunarity = 2.5
	noise_deposit.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise_deposit.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2

	# Bruit pour les failles géologiques
	var noise_fault = FastNoiseLite.new()
	noise_fault.seed = randi()
	noise_fault.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_fault.frequency = 2.5 / float(planet.circonference)
	noise_fault.fractal_octaves = 3
	noise_fault.fractal_gain = 0.4

	var noises = [noise_basin, noise_deposit, noise_fault, planet.atmosphere_type != 3]
	parallel_generate(img, noises, _calcul)

	return img

func _calcul(img: Image, noises, x: int, y: int) -> void:
	var noise_basin = noises[0]
	var noise_deposit = noises[1]
	var noise_fault = noises[2]
	var has_atmosphere = noises[3]
	
	if not has_atmosphere:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
		return
	
	var coords = get_cylindrical_coords(x, y)

	var elevation = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
	var is_water = planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	
	var elevation_factor: float
	if is_water:
		var depth = planet.water_elevation - elevation
		if depth < 500:
			elevation_factor = 0.9
		elif depth < 2000:
			elevation_factor = 0.5
		else:
			elevation_factor = 0.2
	else:
		var alt_above_water = elevation - planet.water_elevation
		if alt_above_water < 200:
			elevation_factor = 0.85
		elif alt_above_water < 500:
			elevation_factor = 0.7
		elif alt_above_water < 1500:
			elevation_factor = 0.4
		else:
			elevation_factor = 0.1
	
	var basin_value = noise_basin.get_noise_3d(coords.x, coords.y, coords.z)
	basin_value = (basin_value + 1.0) / 2.0
	
	var deposit_value = noise_deposit.get_noise_3d(coords.x, coords.y, coords.z)
	deposit_value = (deposit_value + 1.0) / 2.0
	
	var fault_value = abs(noise_fault.get_noise_3d(coords.x, coords.y, coords.z))
	var fault_bonus = 0.0
	if fault_value > 0.4 and fault_value < 0.6:
		fault_bonus = 0.3 * (1.0 - abs(fault_value - 0.5) * 5.0)
	
	var oil_probability = basin_value * 0.4 + deposit_value * 0.3 + fault_bonus
	oil_probability = oil_probability * elevation_factor
	
	if oil_probability > 0.35:
		img.set_pixel(x, y, Color.hex(0x000000FF))
	else:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
