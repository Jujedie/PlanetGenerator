extends RefCounted


class_name PlanetGenerator

var nom: String
signal finished
var circonference			: int
var renderProgress			: ProgressBar
var cheminSauvegarde		: String

# Paramètres de génération
var avg_temperature   : float
var water_elevation   : int
var avg_precipitation : float
var elevation_modifier: int
var nb_thread         : int
var atmosphere_type   : int
var nb_avg_cases      : int

# Images générées
var elevation_map    : Image
var elevation_map_alt: Image
var precipitation_map: Image
var temperature_map  : Image
var region_map  : Image
var water_map   : Image
var banquise_map: Image
var biome_map   : Image
var oil_map     : Image
var ressource_map: Image
var nuage_map   : Image
var final_map   : Image

var preview: Image

# Constantes pour la conversion cylindrique
var cylinder_radius: float

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, elevation_modifier_param: int = 0, nb_thread_param : int = 8, atmosphere_type_param: int = 0, renderProgress_param: ProgressBar = null, nb_avg_cases_param : int = 50, cheminSauvegarde_param: String = "user://temp/") -> void:
	self.nom = nom_param
	
	self.circonference			=  int(rayon * 2 * PI)
	self.renderProgress			= renderProgress_param
	self.renderProgress.value	= 0.0
	self.cheminSauvegarde		= cheminSauvegarde_param
	self.nb_avg_cases           = nb_avg_cases_param

	self.avg_temperature    = avg_temperature_param
	self.water_elevation    = water_elevation_param
	self.avg_precipitation  = avg_precipitation_param
	self.elevation_modifier = elevation_modifier_param
	self.nb_thread          = nb_thread_param
	self.atmosphere_type    = atmosphere_type_param
	
	# Rayon du cylindre pour la projection
	self.cylinder_radius = self.circonference / (2.0 * PI)

# Convertit les coordonnées 2D en coordonnées 3D cylindriques pour un bruit continu horizontalement
func get_cylindrical_coords(x: int, y: int) -> Vector3:
	var angle = (float(x) / float(self.circonference)) * 2.0 * PI
	var cx = cos(angle) * cylinder_radius
	var cz = sin(angle) * cylinder_radius
	var cy = float(y)
	return Vector3(cx, cy, cz)

# Wrap horizontal pour les coordonnées x
func wrap_x(x: int) -> int:
	return posmod(x, self.circonference)

func generate_planet():
	print("\nGénération de la carte finale\n")
	var thread_final = Thread.new()
	thread_final.start(generate_final_map)

	thread_final.wait_to_finish()

	print("\nGénération de la carte du pétrole\n")
	var thread_oil = Thread.new()
	thread_oil.start(generate_oil_map)

	print("\nGénération de la carte des ressources\n")
	var thread_ressource = Thread.new()
	thread_ressource.start(generate_ressource_map)

	print("\nGénération de la carte des nuages\n")
	var thread_nuage = Thread.new()
	thread_nuage.start(generate_nuage_map)

	print("\nGénération de la carte topographique\n")
	var thread_elevation = Thread.new()
	thread_elevation.start(generate_elevation_map)

	print("\nGénération de la carte des précipitations\n")
	var thread_precipitation = Thread.new()
	thread_precipitation.start(generate_precipitation_map)

	thread_elevation.wait_to_finish()

	print("\nGénération de la carte des mers\n")
	var thread_water = Thread.new()
	thread_water.start(generate_water_map)

	thread_precipitation.wait_to_finish()
	thread_water.wait_to_finish()

	print("\nGénération de la carte des regions\n")
	var thread_region = Thread.new()
	thread_region.start(generate_region_map)

	print("\nGénération de la carte des températures moyennes\n")
	var thread_temperature = Thread.new()
	thread_temperature.start(generate_temperature_map)

	thread_temperature.wait_to_finish()

	print("\nGénération de la carte de la banquise\n")
	var thread_banquise = Thread.new()
	thread_banquise.start(generate_banquise_map)

	thread_banquise.wait_to_finish()

	print("\nGénération de la carte des biomes\n")
	var thread_biome = Thread.new()
	thread_biome.start(generate_biome_map)

	thread_oil.wait_to_finish()
	thread_ressource.wait_to_finish()
	thread_biome.wait_to_finish()
	thread_region.wait_to_finish()

	generate_preview()

	print("\n===================")
	print("Génération Terminée\n")
	emit_signal("finished")

func save_maps():
	print("\nSauvegarde de la carte finale")
	save_image(self.final_map, "final_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte topographique")
	save_image(self.elevation_map, "elevation_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte topographique alternative")
	save_image(self.elevation_map_alt, "elevation_map_alt.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des précipitations")
	save_image(self.precipitation_map, "precipitation_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des températures moyennes")
	save_image(self.temperature_map, "temperature_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des mers")
	save_image(self.water_map, "water_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des biomes")
	save_image(self.biome_map, "biome_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte du pétrole")
	save_image(self.oil_map, "oil_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des ressources")
	save_image(self.ressource_map, "ressource_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des nuages")
	save_image(self.nuage_map, "nuage_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte de prévisualisation")
	save_image(self.preview, "preview.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des régions")
	save_image(self.region_map, "region_map.png", self.cheminSauvegarde)

	print("\nSauvegarde terminée")

func generate_nuage_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )
	var base_seed = randi()

	# Bruit cellulaire pour formes circulaires
	var cell_noise = FastNoiseLite.new()
	cell_noise.seed = base_seed
	cell_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	cell_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cell_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cell_noise.frequency = 6.0 / float(self.circonference)
	
	# Bruit de forme pour varier les nuages
	var shape_noise = FastNoiseLite.new()
	shape_noise.seed = base_seed + 1
	shape_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	shape_noise.frequency = 4.0 / float(self.circonference)
	shape_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	shape_noise.fractal_octaves = 4
	shape_noise.fractal_gain = 0.5
	
	# Bruit de détail pour bords irréguliers
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = base_seed + 2
	detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency = 15.0 / float(self.circonference)
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 3

	var noises = [cell_noise, shape_noise, detail_noise]

	var range_size = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range_size
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range_size
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noises[0], noises, x1, x2, nuage_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(5)
	self.nuage_map = img

func nuage_calcul(img: Image, _noise, noises, x : int, y : int) -> void:
	var coords = get_cylindrical_coords(x, y)
	
	var cell_noise = noises[0]
	var shape_noise = noises[1]
	var detail_noise = noises[2]
	
	# Valeur cellulaire - crée des formes rondes
	var cell_val = cell_noise.get_noise_3d(coords.x, coords.y, coords.z)
	cell_val = 1.0 - abs(cell_val)  # Inverser pour avoir des blobs
	
	# Forme générale
	var shape_val = shape_noise.get_noise_3d(coords.x, coords.y, coords.z)
	shape_val = (shape_val + 1.0) / 2.0  # Normaliser 0-1
	
	# Détail des bords
	var detail_val = detail_noise.get_noise_3d(coords.x, coords.y, coords.z) * 0.15
	
	# Combiner
	var cloud_val = cell_val * 0.6 + shape_val * 0.4 + detail_val
	
	# Seuil pour créer les nuages
	var threshold = 0.55
	
	if cloud_val > threshold:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))  # Blanc pur
	else:
		img.set_pixel(x, y, Color.hex(0x00000000))  # Transparent


func generate_elevation_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )
	self.elevation_map_alt = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 2.0 / float(self.circonference)
	noise.fractal_octaves = 8
	noise.fractal_gain = 0.75
	noise.fractal_lacunarity = 2.0

	var noise2 = FastNoiseLite.new()
	noise2.seed = randi()
	noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise2.frequency = 2.0 / float(self.circonference)
	noise2.fractal_octaves = 8
	noise2.fractal_gain = 0.75
	noise2.fractal_lacunarity = 2.0

	var noise3 = FastNoiseLite.new()
	noise3.seed = randi()
	noise3.noise_type = FastNoiseLite.TYPE_PERLIN
	noise3.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise3.frequency = 1.504 / float(self.circonference)
	noise3.fractal_octaves = 6
	noise3.fractal_gain = 0.85
	noise3.fractal_lacunarity = 3.0

	var tectonic_mountain_noise = FastNoiseLite.new()
	tectonic_mountain_noise.seed = randi()
	tectonic_mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tectonic_mountain_noise.frequency = 0.4 / float(self.circonference)
	tectonic_mountain_noise.fractal_gain = 0.55
	tectonic_mountain_noise.fractal_octaves = 10

	var tectonic_canyon_noise = FastNoiseLite.new()
	tectonic_canyon_noise.seed = randi()
	tectonic_canyon_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tectonic_canyon_noise.frequency = 0.4 / float(self.circonference)
	tectonic_canyon_noise.fractal_gain = 0.55
	tectonic_canyon_noise.fractal_octaves = 4

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(
			img, 
			noise, 
			[noise2, noise3, tectonic_mountain_noise, tectonic_canyon_noise], 
			x1, x2, 
			elevation_calcul
		))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(10)
	self.elevation_map = img

func elevation_calcul(img: Image, noise, noises, x: int, y: int) -> void:
	var noise2 = noises[0]
	var noise3 = noises[1]
	var tectonic_mountain_noise = noises[2]
	var tectonic_canyon_noise = noises[3]

	var coords = get_cylindrical_coords(x, y)
	
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	var value2 = noise2.get_noise_3d(coords.x, coords.y, coords.z)
	var elevation = ceil(value * (3500 + clamp(value2, 0.0, 1.0) * elevation_modifier))

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
	self.elevation_map_alt.set_pixel(x, y, color)


func generate_oil_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 3.0 / float(self.circonference)
	noise.fractal_octaves = 9
	noise.fractal_gain = 0.85
	noise.fractal_lacunarity = 4.0

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, self.atmosphere_type != 3, x1, x2, oil_calcul))
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(5)
	self.oil_map = img

func oil_calcul(img: Image, noise, noise2, x : int, y : int) -> void:
	var coords = get_cylindrical_coords(x, y)
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	value = clamp(value, 0.0, 1.0)

	if value > 0.25 and noise2:
		img.set_pixel(x, y, Color.hex(0x000000FF))
	else:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))


func generate_banquise_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, null, null, x1, x2, banquise_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(5)
	self.banquise_map = img

func banquise_calcul(img: Image,_noise, _noise2, x : int,y : int) -> void:
	if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		if Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y)) < 0.0 and randf() < 0.9:
			img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
		else:
			img.set_pixel(x, y, Color.hex(0x000000FF))
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))


func generate_precipitation_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 2.0 / float(self.circonference)
	noise.fractal_octaves = 9
	noise.fractal_gain = 0.85
	noise.fractal_lacunarity = 4.0

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise, x1, x2, precipitation_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(10)
	self.precipitation_map = img

func precipitation_calcul(img: Image, noise, _noise2, x : int,y : int) -> void:
	var coords = get_cylindrical_coords(x, y)
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	value = clamp((value + self.avg_precipitation * value / 2.0), 0.0, 1.0)

	img.set_pixel(x, y, Enum.getPrecipitationColor(value))


func generate_water_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, 0, x1, x2, water_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(10)
	self.water_map = img

func water_calcul(img: Image, noise, _noise2, x : int, y : int) -> void:
	if self.atmosphere_type == 3:
		img.set_pixel(x, y, Color.hex(0x000000FF))
		return
	
	randomize()

	var coords = get_cylindrical_coords(x, y)
	var value = noise.get_noise_3d(coords.x, coords.y, coords.z)
	value = abs(value)

	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			
	if elevation_val <= self.water_elevation:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))


func generate_region_map() -> void:

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	region_calcul(img)

	self.addProgress(10)
	self.region_map = img

func region_calcul(img: Image) -> void:
	var cases_done : Dictionary = {}
	var current_region : Region = null

	for x in range(0, self.circonference):
		for y in range(0, self.circonference / 2):
			if not (cases_done.has(x) and cases_done[x].has(y)):
				if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
					img.set_pixel(x, y, Color.hex(0x161a1fFF))
					if not cases_done.has(x):
						cases_done[x] = {}
					cases_done[x][y] = null
					continue
				else :
					var avg_block = (randi() % (self.nb_avg_cases)) + (self.nb_avg_cases / 4)
					current_region = Region.new(avg_block)

					region_creation(img, [x, y], cases_done, current_region)
			else:
				continue

func region_creation(img: Image, start_pos: Array[int], cases_done: Dictionary, current_region: Region) -> void:
	var frontier = [start_pos]
	var origin = Vector2(start_pos[0], start_pos[1])

	while frontier.size() > 0 and not current_region.is_complete():
		frontier.sort_custom(func(a, b):
			# Distance torique pour le tri
			var ax = a[0]
			var bx = b[0]
			var ox = origin.x
			var dx_a = min(abs(ax - ox), self.circonference - abs(ax - ox))
			var dx_b = min(abs(bx - ox), self.circonference - abs(bx - ox))
			var da = sqrt(dx_a * dx_a + (a[1] - origin.y) * (a[1] - origin.y)) + randf() * 10.0
			var db = sqrt(dx_b * dx_b + (b[1] - origin.y) * (b[1] - origin.y)) + randf() * 10.0
			return da < db
		)

		var pos = frontier.pop_front()
		var x = wrap_x(pos[0])  # Toujours wrapper x
		var y = pos[1]

		if cases_done.has(x) and cases_done[x].has(y):
			continue

		if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			img.set_pixel(x, y, Color.hex(0x161a1fFF))
			if not cases_done.has(x):
				cases_done[x] = {}
			cases_done[x][y] = null
			continue

		current_region.addCase([x, y])  # Stocker avec x wrappé
		if not cases_done.has(x):
			cases_done[x] = {}
		cases_done[x][y] = current_region

		# Voisins avec wrap horizontal
		for dir in [[-1,0],[1,0],[0,-1],[0,1]]:
			var nx = wrap_x(x + dir[0])
			var ny = y + dir[1]
			if ny >= 0 and ny < self.circonference / 2:
				if not (cases_done.has(nx) and cases_done[nx].has(ny)):
					frontier.append([nx, ny])

	if current_region.cases.size() <= 10:
		var target_region : Region = null

		for pos in current_region.cases:
			var x = pos[0]  # Déjà wrappé
			var y = pos[1]

			for dir in [[-1,0],[1,0],[0,-1],[0,1]]:
				var nx = wrap_x(x + dir[0])
				var ny = y + dir[1]
				if ny >= 0 and ny < self.circonference / 2:
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

func generate_ressource_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)

	var width = self.circonference
	var height = int(self.circonference / 2)
	for x in range(0, width):
		for y in range(0, height):
			if self.water_map != null and self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			# créer/étendre un gisement à partir de cette case
			ressource_calcul(img, x, y)

	self.addProgress(5)
	self.ressource_map = img


func ressource_calcul(img: Image, x : int,y : int) -> void:
	var deposit = Ressource.copy(Enum.getRessourceByProbabilite())
	if deposit == null:
		return

	deposit.addCase([x, y])
	img.set_pixel(x, y, deposit.couleur)

	# Étendre le gisement aléatoirement autour du point initial
	var attempts = 0
	var max_attempts = max(10, deposit.getNbCaseLeft() * 2)
	var cases = deposit.getCases()
	while not deposit.is_complete() and attempts < max_attempts:
		attempts += 1

		var base = cases[randi() % cases.size()]
		var nx = base[0] + (randi() % 3) - 1
		var ny = base[1] + (randi() % 3) - 1

		# Vérifier limites
		if nx < 0 or nx >= img.get_width() or ny < 0 or ny >= img.get_height():
			continue
		
		# Vérifier que ce n'est pas de l'eau
		if self.water_map != null and self.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
			continue
		
		if img.get_pixel(nx, ny) != Color.hex(0x00000000):
			continue

		deposit.addCase([nx, ny])
		img.set_pixel(nx, ny, deposit.couleur)

func generate_temperature_map() -> void:
	randomize()

	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	# Bruit principal pour les variations climatiques régionales
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 3.0 / float(self.circonference)
	noise.fractal_octaves = 6
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0

	# Bruit secondaire pour les courants océaniques/masses d'air
	var noise2 = FastNoiseLite.new()
	noise2.seed = randi()
	noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise2.frequency = 1.5 / float(self.circonference)
	noise2.fractal_octaves = 4
	noise2.fractal_gain = 0.6
	noise2.fractal_lacunarity = 2.0
	
	# Bruit pour les anomalies thermiques locales
	var noise3 = FastNoiseLite.new()
	noise3.seed = randi()
	noise3.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise3.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise3.frequency = 6.0 / float(self.circonference)
	noise3.fractal_octaves = 3
	noise3.fractal_gain = 0.4

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, [noise2, noise3], x1, x2, temperature_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(10)
	self.temperature_map = img

func temperature_calcul(img: Image, noise, noises, x : int, y : int) -> void:
	var noise2 = noises[0]
	var noise3 = noises[1]
	
	# Latitude normalisée (0 à l'équateur, 1 aux pôles)
	var lat_normalized = abs((y / (self.circonference / 2.0)) - 0.5) * 2.0
	
	var coords = get_cylindrical_coords(x, y)
	
	# Grande variation régionale qui brise les bandes horizontales
	# Ce bruit détermine les "zones climatiques" indépendamment de la latitude
	var climate_zone = noise.get_noise_3d(coords.x, coords.y, coords.z)
	
	# Température de base selon latitude (réduite pour laisser place aux variations)
	# Équateur: avg_temp + 10, Pôles: avg_temp - 25
	var latitude_influence = 0.6  # Réduit l'influence de la latitude
	var base_lat_temp = self.avg_temperature + 10.0 * (1.0 - lat_normalized) - 25.0 * lat_normalized
	base_lat_temp = self.avg_temperature + (base_lat_temp - self.avg_temperature) * latitude_influence
	
	# Variations longitudinales fortes (crée des zones chaudes/froides sur la même latitude)
	# C'est ce qui fait que le Sahara existe mais pas la jungle amazonienne = désert
	var longitudinal_variation = climate_zone * 20.0
	
	# Deuxième couche de variation pour plus de diversité
	var secondary_variation = noise2.get_noise_3d(coords.x, coords.y, coords.z) * 10.0
	
	# Microclimats locaux
	var local_variation = noise3.get_noise_3d(coords.x, coords.y, coords.z) * 6.0
	
	# Effet de l'altitude
	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var altitude_temp = get_temperature_delta_from_altitude(elevation_val - self.water_elevation)
	
	var temp = base_lat_temp + longitudinal_variation + secondary_variation + local_variation + altitude_temp
	
	# Effet modérateur des océans (températures moins extrêmes sur l'eau)
	if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		temp = temp * 0.6 + self.avg_temperature * 0.4
		temp -= 2.0
	
	if temp > 100 and self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		temp = 100.0

	var color = Enum.getTemperatureColor(temp)

	img.set_pixel(x, y, color)


func generate_biome_map() -> void:
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )
	
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5
	
	var range = circonference / self.nb_thread
	var threadArray = []
	for i in range(0, self.nb_thread, 1):
		var x1 = i * range
		var x2 = self.circonference if i == (self.nb_thread - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, self, x1, x2, biome_calcul))

	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(25)
	self.biome_map = img

func biome_calcul(img: Image, _noise, generator, x : int, y : int) -> void:
	var elevation_val     = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var precipitation_val = self.precipitation_map.get_pixel(x, y).r
	var temperature_val   = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
	var is_water          = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)

	var biome
	if self.banquise_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		biome = Enum.getBanquiseBiome(self.atmosphere_type)
	else:
		biome = Enum.getBiome(self.atmosphere_type, elevation_val, precipitation_val, temperature_val, is_water, img, x, y, generator)

	var elevation_color = Enum.getElevationColor(elevation_val, true)
	var color_final = elevation_color * biome.get_couleur_vegetation()
	color_final.a = 1.0

	img.set_pixel(x, y, biome.get_couleur())
	self.final_map.set_pixel(x, y, color_final)


func thread_calcul(img: Image, noise: FastNoiseLite, misc_value , x1: int, x2: int, function : Callable) -> void:
	for x in range(x1, x2):
		for y in range(self.circonference / 2):
			function.call(img, noise, misc_value, x, y)


func generate_final_map() -> void:
	pass
	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	print("Fin de la génération de la carte")
	self.addProgress(10)
	self.final_map = img

func generate_preview() -> void:
	self.preview = Image.create(self.circonference / 2, self.circonference / 2, false, Image.FORMAT_RGBA8 )

	var radius = self.circonference / 4
	var center = Vector2(self.circonference / 4, self.circonference / 4)

	for x in range(self.preview.get_width()):
		for y in range(self.preview.get_height()):
			var pos = Vector2(x, y)
			if pos.distance_to(center) <= radius:
				var base_color = self.final_map.get_pixel(x, y)
				if self.nuage_map.get_pixel(x, y) != Color.hex(0x00000000):
					# Mélanger nuage semi-transparent avec la couleur de base
					var cloud_alpha = 0.7  # Opacité des nuages
					var cloud_color = Color(1.0, 1.0, 1.0, cloud_alpha)
					var blended = base_color.lerp(cloud_color, cloud_alpha)
					blended.a = 1.0
					self.preview.set_pixel(x, y, blended)
				else:
					self.preview.set_pixel(x, y, base_color)
			else:
				self.preview.set_pixel(x, y, Color.TRANSPARENT)


func getMaps() -> Array[String]:
	deleteImagesTemps()

	return [
		save_image(self.elevation_map,"elevation_map.png"),
		save_image(self.elevation_map_alt,"elevation_map_alt.png"),
		save_image(self.nuage_map,"nuage_map.png"),
		save_image(self.oil_map,"oil_map.png"),
		save_image(self.ressource_map,"ressource_map.png"),
		save_image(self.precipitation_map,"precipitation_map.png"),
		save_image(self.temperature_map,"temperature_map.png"),
		save_image(self.water_map,"water_map.png"),
		save_image(self.biome_map,"biome_map.png"),
		save_image(self.final_map,"final_map.png"),
		save_image(self.region_map,"region_map.png"),
		save_image(self.preview,"preview.png")
	]

func is_ready() -> bool:
	return self.elevation_map != null and self.precipitation_map != null and self.temperature_map != null and self.water_map != null and self.biome_map != null and self.final_map != null and self.region_map != null and self.nuage_map != null and self.oil_map != null and self.banquise_map != null and self.preview != null

func addProgress(value) -> void:
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

static func save_image(image: Image, file_name : String, file_path = null) -> String:
	if file_path == null:
		var img_path = "user://temp/" + file_name
		if DirAccess.open("user://temp/" ) == null:
			DirAccess.make_dir_absolute("user://temp/" )

		image.save_png(img_path)
		print("Saved: ", img_path)
		return img_path
		
	if not file_path.ends_with("/"):
		file_path += "/"
	
	var dir = DirAccess.open(file_path)
	if dir == null :
		DirAccess.make_dir_absolute(file_path)
		dir = DirAccess.open(file_path)

	var img_path = file_path + file_name
	image.save_png(img_path)
	print("Saved: ", img_path)
	return img_path

static func deleteImagesTemps():
	var dir = DirAccess.open("user://temp/")
	if dir == null:
		DirAccess.make_dir_absolute("user://temp/")
		dir = DirAccess.open("user://temp/")
 
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func get_temperature_delta_from_altitude(altitude: float) -> float:
	var altitude_table = [
		-500, 0, 500, 1000, 1500, 2000, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9500, 10000, 10500
	]
	var temp_table = [
		18.3, 15.0, 11.8, 8.5, 5.3, 2.0, -4.5, -7.8, -11.0, -14.3, -17.5, -20.8, -24.0, -27.3, -30.7, -33.8, -37.0, -40.3, -43.5, -46.8, -50.0, -53.3
	]
	
	if altitude <= altitude_table[0]:
		return temp_table[0] - 15.0
	if altitude >= altitude_table[-1]:
		return temp_table[-1] - 15.0

	for i in range(1, altitude_table.size()):
		if altitude < altitude_table[i]:
			var alt0 = altitude_table[i-1]
			var alt1 = altitude_table[i]
			var temp0 = temp_table[i-1]
			var temp1 = temp_table[i]

			var t = (altitude - alt0) / (alt1 - alt0)
			var temp = lerp(temp0, temp1, t)
			return temp - 15.0
	return 0.0
