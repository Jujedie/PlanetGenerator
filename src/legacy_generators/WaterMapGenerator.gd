extends MapGenerator

class_name WaterMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 1.0 / float(planet.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5

	parallel_generate(img, [noise], _calcul)
	return img

func _calcul(img: Image, noises, x: int, y: int) -> void:
	if planet.atmosphere_type == 3:
		img.set_pixel(x, y, Color.hex(0x000000FF))
		return

	var noise = noises[0]
	var coords = get_cylindrical_coords(x, y)
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	value = abs(value)

	var elevation_val = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
			
	if elevation_val <= planet.water_elevation:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))
