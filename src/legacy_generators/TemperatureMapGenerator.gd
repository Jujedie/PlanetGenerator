extends MapGenerator

class_name TemperatureMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()

	# Bruit principal pour les variations climatiques régionales
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 3.0 / float(planet.circonference)
	noise.fractal_octaves = 6
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0

	# Bruit secondaire pour les courants océaniques/masses d'air
	var noise2 = FastNoiseLite.new()
	noise2.seed = randi()
	noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise2.frequency = 1.5 / float(planet.circonference)
	noise2.fractal_octaves = 4
	noise2.fractal_gain = 0.6
	noise2.fractal_lacunarity = 2.0
	
	# Bruit pour les anomalies thermiques locales
	var noise3 = FastNoiseLite.new()
	noise3.seed = randi()
	noise3.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise3.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise3.frequency = 6.0 / float(planet.circonference)
	noise3.fractal_octaves = 3
	noise3.fractal_gain = 0.4

	var noises = [noise, noise2, noise3]
	parallel_generate(img, noises, _calcul)

	return img

func _calcul(img: Image, noises, x: int, y: int) -> void:
	var noise = noises[0]
	var noise2 = noises[1]
	var noise3 = noises[2]
	
	var lat_normalized = abs((y / (planet.circonference / 2.0)) - 0.5) * 2.0
	var coords = get_cylindrical_coords(x, y)
	var climate_zone = noise.get_noise_3d(coords.x, coords.y, coords.z)
	
	var equator_offset = 8.0
	var pole_offset = 35.0
	var lat_curve = pow(lat_normalized, 1.5)
	var base_temp = planet.avg_temperature + equator_offset * (1.0 - lat_normalized) - pole_offset * lat_curve
	
	var longitudinal_variation = climate_zone * 8.0
	var secondary_variation = noise2.get_noise_3d(coords.x, coords.y, coords.z) * 5.0
	var local_variation = noise3.get_noise_3d(coords.x, coords.y, coords.z) * 3.0
	
	var elevation_val = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
	var is_water = planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	var altitude_temp = 0.0
	
	if not is_water:
		var altitude_above_sea = max(0.0, elevation_val - planet.water_elevation)
		altitude_temp = -6.5 * (altitude_above_sea / 1000.0)
		
		if elevation_val < planet.water_elevation:
			var depth_below_sea = planet.water_elevation - elevation_val
			altitude_temp = 2.0 * (depth_below_sea / 1000.0)
	
	var temp = base_temp + longitudinal_variation + secondary_variation + local_variation + altitude_temp
	
	if is_water:
		temp = temp * 0.8 + planet.avg_temperature * 0.2
	
	temp = clamp(temp, -80.0, 60.0)
	var color = Enum.getTemperatureColor(temp)
	img.set_pixel(x, y, color)
