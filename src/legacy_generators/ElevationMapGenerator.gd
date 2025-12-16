extends MapGenerator

class_name ElevationMapGenerator

var elevation_map_alt: Image

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()
	elevation_map_alt = create_image()

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 2.0 / float(planet.circonference)
	noise.fractal_octaves = 8
	noise.fractal_gain = 0.75
	noise.fractal_lacunarity = 2.0

	var noise2 = FastNoiseLite.new()
	noise2.seed = randi()
	noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise2.frequency = 2.0 / float(planet.circonference)
	noise2.fractal_octaves = 8
	noise2.fractal_gain = 0.75
	noise2.fractal_lacunarity = 2.0

	var noise3 = FastNoiseLite.new()
	noise3.seed = randi()
	noise3.noise_type = FastNoiseLite.TYPE_PERLIN
	noise3.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise3.frequency = 1.504 / float(planet.circonference)
	noise3.fractal_octaves = 6
	noise3.fractal_gain = 0.85
	noise3.fractal_lacunarity = 3.0

	var tectonic_mountain_noise = FastNoiseLite.new()
	tectonic_mountain_noise.seed = randi()
	tectonic_mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tectonic_mountain_noise.frequency = 0.4 / float(planet.circonference)
	tectonic_mountain_noise.fractal_gain = 0.55
	tectonic_mountain_noise.fractal_octaves = 10

	var tectonic_canyon_noise = FastNoiseLite.new()
	tectonic_canyon_noise.seed = randi()
	tectonic_canyon_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tectonic_canyon_noise.frequency = 0.4 / float(planet.circonference)
	tectonic_canyon_noise.fractal_gain = 0.55
	tectonic_canyon_noise.fractal_octaves = 4

	var noises = [noise, noise2, noise3, tectonic_mountain_noise, tectonic_canyon_noise]
	parallel_generate(img, noises, _calcul)

	return img

func get_elevation_map_alt() -> Image:
	return elevation_map_alt

func _calcul(img: Image, noises, x: int, y: int) -> void:
	var noise = noises[0]
	var noise2 = noises[1]
	var noise3 = noises[2]
	var tectonic_mountain_noise = noises[3]
	var tectonic_canyon_noise = noises[4]

	var coords = get_cylindrical_coords(x, y)
	
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	var value2 = noise2.get_noise_3d(coords.x, coords.y, coords.z)
	var elevation = ceil(value * (3500 + clamp(value2, 0.0, 1.0) * planet.elevation_modifier))

	var tectonic_mountain_val = abs(tectonic_mountain_noise.get_noise_3d(coords.x, coords.y, coords.z))
	if tectonic_mountain_val > 0.45 and tectonic_mountain_val < 0.55:
		elevation += 2500 * (1.0 - abs(tectonic_mountain_val - 0.5) * 20.0)

	var tectonic_canyon_val = abs(tectonic_canyon_noise.get_noise_3d(coords.x, coords.y, coords.z))
	if tectonic_canyon_val > 0.45 and tectonic_canyon_val < 0.55:
		elevation -= 1500 * (1.0 - abs(tectonic_canyon_val - 0.5) * 20.0)

	if elevation > 800:
		var value3 = clamp(noise3.get_noise_3d(coords.x, coords.y, coords.z), 0.0, 1.0)
		elevation = elevation + ceil(value3 * 5000)
	elif elevation <= -800:
		var value3 = clamp(noise3.get_noise_3d(coords.x, coords.y, coords.z), -1.0, 0.0)
		elevation = elevation + ceil(value3 * 5000)

	var color = Enum.getElevationColor(elevation)
	img.set_pixel(x, y, color)
	color = Enum.getElevationColor(elevation, true)
	elevation_map_alt.set_pixel(x, y, color)
