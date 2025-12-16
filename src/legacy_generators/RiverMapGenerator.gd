extends MapGenerator

class_name RiverMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	randomize()
	var height = int(planet.circonference / 2)
	var img = Image.create(planet.circonference, height, false, Image.FORMAT_RGBA8)
	
	img.fill(Color.hex(0x00000000))
	
	if planet.atmosphere_type == 3:
		return img
	
	var base_seed = randi()
	
	var source_noise = FastNoiseLite.new()
	source_noise.seed = base_seed
	source_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	source_noise.frequency = 6.0 / float(planet.circonference)
	source_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	source_noise.fractal_octaves = 3
	
	var meander_noise = FastNoiseLite.new()
	meander_noise.seed = base_seed + 2
	meander_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	meander_noise.frequency = 25.0 / float(planet.circonference)
	
	var lake_noise = FastNoiseLite.new()
	lake_noise.seed = base_seed + 3
	lake_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	lake_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	lake_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	lake_noise.frequency = 6.0 / float(planet.circonference)
	
	# Trouver les sources
	var sources: Array = []
	var step = max(3, planet.circonference / 256)
	var source_threshold = 0.25
	
	for x in range(0, planet.circonference, step):
		for y in range(0, height, step):
			if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			
			var temp = Enum.getTemperatureViaColor(planet.temperature_map.get_pixel(x, y))
			if temp <= -10:
				continue
			
			var elevation = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
			var precipitation = planet.precipitation_map.get_pixel(x, y).r
			
			if elevation < planet.water_elevation + 100:
				continue
			
			var coords = get_cylindrical_coords(x, y)
			var noise_val = source_noise.get_noise_3d(coords.x, coords.y, coords.z)
			if noise_val < source_threshold:
				continue
			
			var altitude_score = (elevation - planet.water_elevation) / 1000.0
			var score = altitude_score * (precipitation + 0.3) * (noise_val + 0.5)
			
			var river_size = 0
			if elevation > 2000 and precipitation > 0.5:
				river_size = 2
			elif elevation > 500 or precipitation > 0.4:
				river_size = 1
			
			sources.append({
				"x": x, 
				"y": y, 
				"score": score, 
				"elevation": elevation,
				"river_size": river_size,
				"temperature": temp,
				"precipitation": precipitation
			})
	
	sources.sort_custom(func(a, b): return a.score > b.score)
	
	var selected_sources: Array = []
	var min_distance = max(10, planet.circonference / 60)
	var max_rivers = max(40, planet.circonference / 25)
	
	for source in sources:
		if selected_sources.size() >= max_rivers:
			break
		
		var too_close = false
		for existing in selected_sources:
			var dx = abs(source.x - existing.x)
			dx = min(dx, planet.circonference - dx)
			var dy = abs(source.y - existing.y)
			if sqrt(dx * dx + dy * dy) < min_distance:
				too_close = true
				break
		
		if not too_close:
			selected_sources.append(source)
	
	for source in selected_sources:
		_trace_river_to_ocean(img, source, meander_noise, height)
	
	_generate_lakes(img, lake_noise, height)
	
	return img

func _trace_river_to_ocean(img: Image, source: Dictionary, meander_noise: FastNoiseLite, height: int) -> void:
	var x = source.x
	var y = source.y
	var river_size = source.river_size
	var temp = source.temperature
	var precipitation = source.precipitation
	
	# Utiliser le biome rivière approprié selon le type de planète et la taille
	var river_biome = Enum.getRiverBiomeBySize(int(temp), planet.atmosphere_type, river_size)
	var river_color: Color
	if river_biome != null:
		river_color = river_biome.get_couleur()
		# Debug: vérifier que le bon biome est utilisé
		if x == source.x and y == source.y:
			print("River biome: ", river_biome.get_nom(), " for type: ", planet.atmosphere_type, " color: ", river_color.to_html())
	else:
		river_color = _get_river_color_by_size(river_size)
		print("FALLBACK used for type: ", planet.atmosphere_type)
	
	var visited: Dictionary = {}
	var max_steps = planet.circonference * 3
	var steps_since_descent = 0
	var last_elevation = source.elevation
	
	var split_chance = 0.03 + precipitation * 0.05
	
	for step in range(max_steps):
		if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			break
		
		var key = str(x) + "_" + str(y)
		if visited.has(key):
			break
		visited[key] = true
		
		img.set_pixel(x, y, river_color)
		
		var current_elev = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
		
		if current_elev < last_elevation:
			steps_since_descent = 0
		else:
			steps_since_descent += 1
		last_elevation = current_elev
		
		if steps_since_descent > 50:
			var lake_biome = Enum.getLakeBiome(int(temp), planet.atmosphere_type)
			var lake_color = lake_biome.get_couleur() if lake_biome != null else _get_lake_color(temp)
			img.set_pixel(x, y, lake_color)
			break
		
		var directions = [
			Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)
		]
		
		var candidates: Array = []
		var ocean_candidate = null
		
		for dir in directions:
			var nx = wrap_x(x + dir.x)
			var ny = y + dir.y
			
			if ny < 0 or ny >= height:
				continue
			
			var nkey = str(nx) + "_" + str(ny)
			if visited.has(nkey):
				continue
			
			if planet.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
				ocean_candidate = {"dir": dir, "nx": nx, "ny": ny}
				break
			
			var elev = Enum.getElevationViaColor(planet.elevation_map.get_pixel(nx, ny))
			var descent = current_elev - elev
			
			var tolerance = 20 + steps_since_descent * 5
			
			if descent >= -tolerance:
				var score = descent
				if elev < current_elev:
					score += 10
				var coords = get_cylindrical_coords(nx, ny)
				var meander = meander_noise.get_noise_3d(coords.x, coords.y, coords.z)
				score += meander * 5
				
				candidates.append({
					"dir": dir, 
					"elev": elev, 
					"descent": descent, 
					"score": score,
					"nx": nx, 
					"ny": ny
				})
		
		if ocean_candidate != null:
			x = ocean_candidate.nx
			y = ocean_candidate.ny
			img.set_pixel(x, y, river_color)
			break
		
		if candidates.size() == 0:
			var lake_biome = Enum.getLakeBiome(int(temp), planet.atmosphere_type)
			var lake_color = lake_biome.get_couleur() if lake_biome != null else _get_lake_color(temp)
			img.set_pixel(x, y, lake_color)
			break
		
		candidates.sort_custom(func(a, b): return a.score > b.score)
		
		if candidates.size() >= 2 and step > 5 and randf() < split_chance:
			var tributary_source = {
				"x": candidates[1].nx,
				"y": candidates[1].ny,
				"river_size": 0,
				"temperature": temp,
				"precipitation": precipitation * 0.6,
				"elevation": candidates[1].elev
			}
			_trace_tributary(img, tributary_source, meander_noise, height, visited.duplicate())
		
		var best = candidates[0]
		
		if candidates.size() > 1 and randf() < 0.15 and abs(candidates[0].score - candidates[1].score) < 20:
			best = candidates[1]
		
		x = best.nx
		y = best.ny

func _trace_tributary(img: Image, source: Dictionary, meander_noise: FastNoiseLite, height: int, parent_visited: Dictionary) -> void:
	var x = source.x
	var y = source.y
	var _temp = source.temperature
	
	# Utiliser le biome rivière approprié (taille 0 = affluent)
	var tributary_biome = Enum.getRiverBiomeBySize(int(_temp), planet.atmosphere_type, 0)
	var river_color = tributary_biome.get_couleur() if tributary_biome != null else _get_river_color_by_size(0)
	var visited = parent_visited
	var max_steps = 100
	var steps_since_descent = 0
	var last_elevation = source.elevation
	
	for step in range(max_steps):
		if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			break
		
		var key = str(x) + "_" + str(y)
		if visited.has(key):
			break
		visited[key] = true
		
		if img.get_pixel(x, y) != Color.hex(0x00000000):
			break
		
		img.set_pixel(x, y, river_color)
		
		var current_elev = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
		
		if current_elev < last_elevation:
			steps_since_descent = 0
		else:
			steps_since_descent += 1
		last_elevation = current_elev
		
		if steps_since_descent > 20:
			break
		
		var directions = [
			Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)
		]
		
		var best_dir = Vector2i(0, 0)
		var best_score = -99999
		
		for dir in directions:
			var nx = wrap_x(x + dir.x)
			var ny = y + dir.y
			
			if ny < 0 or ny >= height:
				continue
			
			var nkey = str(nx) + "_" + str(ny)
			if visited.has(nkey):
				continue
			
			if img.get_pixel(nx, ny) != Color.hex(0x00000000):
				best_dir = dir
				best_score = 99999
				break
			
			if planet.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
				best_dir = dir
				best_score = 99999
				break
			
			var elev = Enum.getElevationViaColor(planet.elevation_map.get_pixel(nx, ny))
			var descent = current_elev - elev
			
			if descent >= -10:
				var score = descent
				var coords = get_cylindrical_coords(nx, ny)
				score += meander_noise.get_noise_3d(coords.x, coords.y, coords.z) * 3
				
				if score > best_score:
					best_score = score
					best_dir = dir
		
		if best_dir == Vector2i(0, 0):
			break
		
		x = wrap_x(x + best_dir.x)
		y = clamp(y + best_dir.y, 0, height - 1)

func _get_river_color_by_size(size: int) -> Color:
	match planet.atmosphere_type:
		1:  # Toxique
			match size:
				0: return Color.hex(0x7ADB79FF)
				1: return Color.hex(0x5BC45AFF)
				2: return Color.hex(0x48B847FF)
		2:  # Volcanique
			match size:
				0: return Color.hex(0xFF8533FF)
				1: return Color.hex(0xFF6B1AFF)
				2: return Color.hex(0xE85A0FFF)
		4:  # Mort
			match size:
				0: return Color.hex(0x6A8A6BFF)
				1: return Color.hex(0x5A7A5BFF)
				2: return Color.hex(0x4A6A4BFF)
		_:  # Défaut
			match size:
				0: return Color.hex(0x6BAAE5FF)
				1: return Color.hex(0x4A90D9FF)
				2: return Color.hex(0x3E7FC4FF)
	return Color.hex(0x4A90D9FF)

func _get_lake_color(temp: float) -> Color:
	match planet.atmosphere_type:
		1:
			if temp < 0:
				return Color.hex(0xB8E6B7FF)
			return Color.hex(0x6ED96DFF)
		2:
			return Color.hex(0xFF9944FF)
		4:
			return Color.hex(0x6B8B6CFF)
		_:
			if temp < 0:
				return Color.hex(0xA8D4E6FF)
			return Color.hex(0x5BA3E0FF)

func _generate_lakes(img: Image, lake_noise: FastNoiseLite, height: int) -> void:
	var lake_candidates: Array = []
	
	for x in range(0, planet.circonference):
		for y in range(0, height):
			if img.get_pixel(x, y) != Color.hex(0x00000000):
				continue
			
			if planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			
			var precipitation = planet.precipitation_map.get_pixel(x, y).r
			if precipitation < 0.4:
				continue
			
			var temp = Enum.getTemperatureViaColor(planet.temperature_map.get_pixel(x, y))
			
			var coords = get_cylindrical_coords(x, y)
			var lake_val = lake_noise.get_noise_3d(coords.x, coords.y, coords.z)
			lake_val = 1.0 - abs(lake_val)
			
			if lake_val > 0.78:
				var elevation = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
				lake_candidates.append({"x": x, "y": y, "elevation": elevation, "temp": temp})
	
	for candidate in lake_candidates:
		var start_elev = candidate.elevation
		
		var is_valid_lake = true
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx = wrap_x(candidate.x + dx)
				var ny = candidate.y + dy
				if ny < 0 or ny >= height:
					continue
				
				if planet.water_map.get_pixel(nx, ny) != Color.hex(0xFFFFFFFF):
					var neighbor_elev = Enum.getElevationViaColor(planet.elevation_map.get_pixel(nx, ny))
					if neighbor_elev < start_elev - 50:
						is_valid_lake = false
						break
			if not is_valid_lake:
				break
		
		if is_valid_lake:
			var lake_biome = Enum.getLakeBiome(int(candidate.temp), planet.atmosphere_type)
			var lake_color = lake_biome.get_couleur() if lake_biome != null else _get_lake_color(candidate.temp)
			img.set_pixel(candidate.x, candidate.y, lake_color)
