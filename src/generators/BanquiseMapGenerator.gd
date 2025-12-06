extends MapGenerator

class_name BanquiseMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()
	parallel_generate(img, null, _calcul)
	return img

func _calcul(img: Image, _noises, x: int, y: int) -> void:
	if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		if Enum.getTemperatureViaColor(planet.temperature_map.get_pixel(x, y)) < 0.0 and randf() < 0.9:
			img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
		else:
			img.set_pixel(x, y, Color.hex(0x000000FF))
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))
