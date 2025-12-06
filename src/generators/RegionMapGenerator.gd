extends MapGenerator

class_name RegionMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	var img = create_image()
	_region_calcul(img)
	return img

func _region_calcul(img: Image) -> void:
	var cases_done: Dictionary = {}
	var current_region: Region = null

	for x in range(0, planet.circonference):
		for y in range(0, planet.circonference / 2):
			if not (cases_done.has(x) and cases_done[x].has(y)):
				if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
					img.set_pixel(x, y, Color.hex(0x161a1fFF))
					if not cases_done.has(x):
						cases_done[x] = {}
					cases_done[x][y] = null
					continue
				else:
					var avg_block = (randi() % (planet.nb_avg_cases)) + (planet.nb_avg_cases / 4)
					current_region = Region.new(avg_block)
					_region_creation(img, [x, y], cases_done, current_region)
			else:
				continue

func _region_creation(img: Image, start_pos: Array[int], cases_done: Dictionary, current_region: Region) -> void:
	var frontier = [start_pos]
	var origin = Vector2(start_pos[0], start_pos[1])
	var noise_cache: Dictionary = {}

	while frontier.size() > 0 and not current_region.is_complete():
		# Pré-calculer le bruit pour chaque élément (déterministe par position)
		for f in frontier:
			var key = str(f[0]) + "_" + str(f[1])
			if not noise_cache.has(key):
				noise_cache[key] = randf() * 10.0
		
		frontier.sort_custom(func(a, b):
			var ax = a[0]
			var bx = b[0]
			var ox = origin.x
			var dx_a = min(abs(ax - ox), planet.circonference - abs(ax - ox))
			var dx_b = min(abs(bx - ox), planet.circonference - abs(bx - ox))
			var key_a = str(a[0]) + "_" + str(a[1])
			var key_b = str(b[0]) + "_" + str(b[1])
			var da = sqrt(dx_a * dx_a + (a[1] - origin.y) * (a[1] - origin.y)) + noise_cache.get(key_a, 0.0)
			var db = sqrt(dx_b * dx_b + (b[1] - origin.y) * (b[1] - origin.y)) + noise_cache.get(key_b, 0.0)
			return da < db
		)

		var pos = frontier.pop_front()
		var x = wrap_x(pos[0])
		var y = pos[1]

		if cases_done.has(x) and cases_done[x].has(y):
			continue

		if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			img.set_pixel(x, y, Color.hex(0x161a1fFF))
			if not cases_done.has(x):
				cases_done[x] = {}
			cases_done[x][y] = null
			continue

		current_region.addCase([x, y])
		if not cases_done.has(x):
			cases_done[x] = {}
		cases_done[x][y] = current_region

		for dir in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
			var nx = wrap_x(x + dir[0])
			var ny = y + dir[1]
			if ny >= 0 and ny < planet.circonference / 2:
				if not (cases_done.has(nx) and cases_done[nx].has(ny)):
					frontier.append([nx, ny])

	if current_region.cases.size() <= 10:
		var target_region: Region = null

		for pos in current_region.cases:
			var x = pos[0]
			var y = pos[1]

			for dir in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
				var nx = wrap_x(x + dir[0])
				var ny = y + dir[1]
				if ny >= 0 and ny < planet.circonference / 2:
					if cases_done.has(nx) and cases_done[nx].has(ny):
						var neighbor_region = cases_done[nx][ny]
						if neighbor_region != null and neighbor_region != current_region:
							target_region = neighbor_region
							break
			if target_region != null:
				break

		if target_region != null:
			for pos in current_region.cases:
				var x = pos[0]
				var y = pos[1]
				target_region.addCase(pos)
				cases_done[x][y] = target_region
			target_region.setColorCases(img)
		else:
			var new_region = Region.new(current_region.cases.size())
			for pos in current_region.cases:
				var x = pos[0]
				var y = pos[1]
				new_region.addCase(pos)
				if not cases_done.has(x):
					cases_done[x] = {}
				cases_done[x][y] = new_region
			new_region.setColorCases(img)
	else:
		current_region.setColorCases(img)
