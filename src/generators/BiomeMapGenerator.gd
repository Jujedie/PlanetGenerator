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
	var river_color = planet.river_map.get_pixel(x, y)
	var is_river = river_color != Color.hex(0x00000000)

	var biome
	if planet.banquise_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		biome = Enum.getBanquiseBiome(planet.atmosphere_type)
	elif is_river:
		# Utiliser directement la couleur de la river_map (déjà correctement colorée par type de planète)
		img.set_pixel(x, y, river_color)
		return
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
	
	# Pré-calculer l'ensemble des couleurs de rivières pour une vérification rapide
	var river_colors: Dictionary = {}
	for x in range(width):
		for y in range(height):
			var river_color = planet.river_map.get_pixel(x, y)
			if river_color != Color.hex(0x00000000):
				river_colors[river_color.to_html()] = true
	
	for _pass in range(2):
		for x in range(width):
			for y in range(height):
				# Vérifier directement via river_map si c'est une rivière/lac
				var is_river = planet.river_map.get_pixel(x, y) != Color.hex(0x00000000)
				if is_river:
					continue
				
				var current_color = temp_img.get_pixel(x, y)
				var current_biome = Enum.getBiomeByColor(current_color)
				
				if current_biome != null and (current_biome.get_nom() == "Banquise" or current_biome.get_nom().begins_with("Banquise")):
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
					# Vérifier que la meilleure couleur n'est pas une couleur de rivière
					if not river_colors.has(best_color.to_html()):
						img.set_pixel(x, y, best_color)
		
		temp_img = img.duplicate()

func _add_border_irregularity(img: Image, noise: FastNoiseLite, width: int, height: int) -> void:
	var temp_img = img.duplicate()
	
	# Pré-calculer l'ensemble des couleurs de rivières pour une vérification rapide
	var river_colors: Dictionary = {}
	for x in range(width):
		for y in range(height):
			var river_color = planet.river_map.get_pixel(x, y)
			if river_color != Color.hex(0x00000000):
				river_colors[river_color.to_html()] = true
	
	for x in range(width):
		for y in range(height):
			# Vérifier directement via river_map si c'est une rivière/lac
			var is_river = planet.river_map.get_pixel(x, y) != Color.hex(0x00000000)
			if is_river:
				continue
				
			var current_color = temp_img.get_pixel(x, y)
			var current_biome = Enum.getBiomeByColor(current_color)
			
			if current_biome != null and current_biome.get_nom().begins_with("Banquise"):
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
						# Vérifier si la couleur voisine n'est pas une rivière
						if not river_colors.has(n_color.to_html()):
							neighbor_biomes.append(n_color)
			
			if is_border and neighbor_biomes.size() > 0:
				var noise_val = noise.get_noise_2d(float(x), float(y))
				if noise_val > 0.4:
					var index = int((noise_val + 1.0) / 2.0 * neighbor_biomes.size()) % neighbor_biomes.size()
					img.set_pixel(x, y, neighbor_biomes[index])

func _apply_final_colors(img: Image, x: int, y: int) -> void:
	var biome_color = img.get_pixel(x, y)
	var river_color = planet.river_map.get_pixel(x, y)
	var is_river = river_color != Color.hex(0x00000000)
	
	var color_final: Color
	
	if is_river:
		# Pour les rivières, trouver le biome par sa couleur et utiliser couleur_vegetation
		var river_biome = Enum.getBiomeByColor(river_color)
		if river_biome != null:
			color_final = river_biome.get_couleur_vegetation()
		else:
			# Fallback: utiliser directement la couleur de la river_map
			color_final = river_color
	else:
		var biome = Enum.getBiomeByColor(biome_color)
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
