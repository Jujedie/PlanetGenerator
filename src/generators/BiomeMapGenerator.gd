extends MapGenerator

class_name BiomeMapGenerator

func _init(planet_ref: PlanetGenerator) -> void:
	super._init(planet_ref)

func generate() -> Image:
	var img = create_image()
	
	var biome_noise = FastNoiseLite.new()
	biome_noise.seed = randi()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	biome_noise.frequency = 4.0 / float(planet.circonference)
	biome_noise.fractal_octaves = 3
	biome_noise.fractal_gain = 0.4
	biome_noise.fractal_lacunarity = 2.0
	
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = randi()
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.frequency = 25.0 / float(planet.circonference)
	detail_noise.fractal_octaves = 4
	detail_noise.fractal_gain = 0.5
	detail_noise.fractal_lacunarity = 2.0
	
	var width = planet.circonference
	var height = int(planet.circonference / 2)
	
	# Première passe : génération initiale des biomes
	for x in range(width):
		for y in range(height):
			_biome_calcul_initial(img, biome_noise, x, y)
	
	# Deuxième passe : lissage
	_smooth_biome_map(img, width, height)
	
	# Troisième passe : ajouter de l'irrégularité aux bordures
	_add_border_irregularity(img, detail_noise, width, height)
	
	# Appliquer les couleurs finales
	for x in range(width):
		for y in range(height):
			_apply_final_colors(img, x, y)

	return img

func _biome_calcul_initial(img: Image, noise: FastNoiseLite, x: int, y: int) -> void:
	var elevation_val = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
	var precipitation_val = planet.precipitation_map.get_pixel(x, y).r
	var temperature_val = Enum.getTemperatureViaColor(planet.temperature_map.get_pixel(x, y))
	var is_water = planet.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	var is_river = planet.river_map.get_pixel(x, y) != Color.hex(0x00000000)

	var biome
	if planet.banquise_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		biome = Enum.getBanquiseBiome(planet.atmosphere_type)
	elif is_river:
		biome = Enum.getRiverBiome(temperature_val, precipitation_val, planet.atmosphere_type)
	else:
		var noise_val = (noise.get_noise_2d(float(x), float(y)) + 1.0) / 2.0
		biome = Enum.getBiomeByNoise(planet.atmosphere_type, elevation_val, precipitation_val, temperature_val, is_water, noise_val)

	if biome == null:
		img.set_pixel(x, y, Color.hex(0xFF00FFFF))
		push_warning("Null biome at position (%d, %d)" % [x, y])
	else:
		img.set_pixel(x, y, biome.get_couleur())

func _smooth_biome_map(img: Image, width: int, height: int) -> void:
	var temp_img = img.duplicate()
	
	for _pass in range(2):
		for x in range(width):
			for y in range(height):
				var current_color = temp_img.get_pixel(x, y)
				var current_biome = Enum.getBiomeByColor(current_color)
				
				if current_biome != null and (current_biome.get_river_lake_only() or current_biome.get_nom() == "Banquise" or current_biome.get_nom().begins_with("Banquise")):
					continue
				
				var neighbor_counts = {}
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx = posmod(x + dx, width)
						var ny = clampi(y + dy, 0, height - 1)
						var n_color = temp_img.get_pixel(nx, ny)
						var key = n_color.to_html()
						if key in neighbor_counts:
							neighbor_counts[key] += 1
						else:
							neighbor_counts[key] = 1
				
				var max_count = 0
				var best_color = current_color
				for color_key in neighbor_counts:
					if neighbor_counts[color_key] > max_count:
						max_count = neighbor_counts[color_key]
						best_color = Color.html(color_key)
				
				if max_count >= 5:
					var best_biome = Enum.getBiomeByColor(best_color)
					if best_biome != null and not best_biome.get_river_lake_only():
						img.set_pixel(x, y, best_color)
		
		temp_img = img.duplicate()

func _add_border_irregularity(img: Image, noise: FastNoiseLite, width: int, height: int) -> void:
	var temp_img = img.duplicate()
	
	for x in range(width):
		for y in range(height):
			var current_color = temp_img.get_pixel(x, y)
			var current_biome = Enum.getBiomeByColor(current_color)
			
			if current_biome != null and (current_biome.get_river_lake_only() or current_biome.get_nom().begins_with("Banquise")):
				continue
			
			var is_border = false
			var neighbor_biomes = []
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx = posmod(x + dx, width)
					var ny = clampi(y + dy, 0, height - 1)
					var n_color = temp_img.get_pixel(nx, ny)
					if n_color != current_color:
						is_border = true
						var n_biome = Enum.getBiomeByColor(n_color)
						if n_biome != null and not n_biome.get_river_lake_only():
							neighbor_biomes.append(n_color)
			
			if is_border and neighbor_biomes.size() > 0:
				var noise_val = noise.get_noise_2d(float(x), float(y))
				if noise_val > 0.4:
					var index = int((noise_val + 1.0) / 2.0 * neighbor_biomes.size()) % neighbor_biomes.size()
					img.set_pixel(x, y, neighbor_biomes[index])

func _apply_final_colors(img: Image, x: int, y: int) -> void:
	var biome_color = img.get_pixel(x, y)
	var biome = Enum.getBiomeByColor(biome_color)
	
	var color_final: Color
	
	if biome == null:
		var elevation_val = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
		var elevation_color = Enum.getElevationColor(elevation_val, true)
		color_final = elevation_color
	else:
		var biome_nom = biome.get_nom()
		var is_banquise = biome_nom.begins_with("Banquise") or biome_nom.find("Refroidis") != -1
		
		if is_banquise:
			color_final = biome.get_couleur_vegetation()
		else:
			var elevation_val = Enum.getElevationViaColor(planet.elevation_map.get_pixel(x, y))
			var elevation_color = Enum.getElevationColor(elevation_val, true)
			color_final = elevation_color * biome.get_couleur_vegetation()
	
	color_final.a = 1.0
	planet.final_map.set_pixel(x, y, color_final)
