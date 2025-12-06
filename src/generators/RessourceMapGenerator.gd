extends MapGenerator

class_name RessourceMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var img = create_image()

	var width = planet.circonference
	var height = int(planet.circonference / 2)
	for x in range(0, width):
		for y in range(0, height):
			if planet.water_map != null and planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			_calcul_ressource(img, x, y)

	return img

func _calcul_ressource(img: Image, x: int, y: int) -> void:
	var deposit = Ressource.copy(Enum.getRessourceByProbabilite())
	if deposit == null:
		return

	deposit.addCase([x, y])
	img.set_pixel(x, y, deposit.couleur)

	var attempts = 0
	var max_attempts = max(10, deposit.getNbCaseLeft() * 2)
	var cases = deposit.getCases()
	while not deposit.is_complete() and attempts < max_attempts:
		attempts += 1

		var base = cases[randi() % cases.size()]
		var nx = base[0] + (randi() % 3) - 1
		var ny = base[1] + (randi() % 3) - 1

		if nx < 0 or nx >= img.get_width() or ny < 0 or ny >= img.get_height():
			continue
		
		if planet.water_map != null and planet.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
			continue
		
		if img.get_pixel(nx, ny) != Color.hex(0x00000000):
			continue

		deposit.addCase([nx, ny])
		img.set_pixel(nx, ny, deposit.couleur)
