extends RefCounted

class_name PlanetGenerator

var nom: String
var circonference    : int

# Paramètres de génération
var avg_temperature   : float
var water_elevation   : int    # l'élévation de l'eau par rapport à la terre [-oo,+oo]
var avg_precipitation : float  # entre 0 et 1
var percent_eau_monde : float
var elevation_modifier: int

# Images générées
var elevation_map    : Image
var precipitation_map: Image
var temperature_map  : Image
var water_map   : Image
var biome_map   : Image
var geopo_map   : Image

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, percent_eau_monde_param: float = 0.7, elevation_modifier_param: int = 0):
	self.nom = nom_param
	
	self.circonference     =  int(rayon * 2 * PI)

	self.avg_temperature   = avg_temperature_param
	self.water_elevation   = water_elevation_param
	self.avg_precipitation = avg_precipitation_param
	self.percent_eau_monde = percent_eau_monde_param
	self.elevation_modifier= elevation_modifier_param

func generate_planet():
	print("Génération de la carte topographique")
	generate_elevation_map()

	print("Génération de la carte des mers")
	generate_water_map()

	print("Génération de la carte des précipitations")
	generate_precipitation_map()

	print("Génération de la carte des températures moyennes")
	generate_temperature_map()

	print("Génération de la carte des biomes")
	generate_biome_map()

	print("Génération de la carte géopolitique")
	#generate_geopolitical_map()
	self.geopo_map = self.biome_map

	print("===================")
	print("Génération Terminée")

func save_maps():
	print("Sauvegarde de la carte topographique")
	save_image(self.elevation_map, "elevation_map.png")

	print("Sauvegarde de la carte des précipitations")
	save_image(self.precipitation_map, "precipitation_map.png")

	print("Sauvegarde de la carte des températures moyennes")
	save_image(self.temperature_map, "temperature_map.png")

	print("Sauvegarde de la carte des mers")
	save_image(self.water_map, "water_map.png")

	print("Sauvegarde de la carte des biomes")
	save_image(self.biome_map, "biome_map.png")

	print("Sauvegarde de la carte géopolitique")
	save_image(self.geopo_map, "geopo_map.png")

func generate_elevation_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
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

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var value = noise.get_noise_2d(float(x), float(y))
			var elevation = ceil(value * (1000 + self.water_elevation + elevation_modifier))

			if elevation >=  (1000 + self.water_elevation + elevation_modifier) - 100:
				value = noise2.get_noise_2d(float(x), float(y))
				value = clamp(value, 0.0, 1.0)
				elevation = elevation + ceil(value * Enum.ALTITUDE_MAX)
			elif elevation <= -(1000 + self.water_elevation + elevation_modifier) + 100:
				value = noise2.get_noise_2d(float(x), float(y))
				value = clamp(value, -1.0, 0.0)
				elevation = elevation + ceil(value * Enum.ALTITUDE_MAX)

			var color = Enum.getElevationColor(elevation)

			img.set_pixel(x, y, color)
			#print("x:", x, " y:", y, " elevation_val:", elevation)

	self.elevation_map = img

func generate_precipitation_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 3.0 / float(self.circonference)
	noise.fractal_octaves = 9
	noise.fractal_gain = 0.85
	noise.fractal_lacunarity = 4.0

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var value = noise.get_noise_2d(float(x), float(y))
			value = clamp(value, 0.0, 1.0) + self.avg_precipitation * value / 2.0

			img.set_pixel(x, y, Color(value, value, value))
			#print("x:", x, " y:", y, " precipitation_val:", value)

	self.precipitation_map = img

func generate_water_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5

	print("Génération de la carte")
	var cptCase = 0
	for x in range(self.circonference):
		for y in range(self.circonference / 2):
			randomize()

			var value = noise.get_noise_2d(float(x), float(y))
			value = clamp(value, 0.0, 1.0)

			var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var minCasesEau = int(self.circonference * (self.circonference / 2.0)) * self.percent_eau_monde
			
			if elevation_val <= self.water_elevation and ( cptCase < minCasesEau  or value < self.percent_eau_monde ):
				img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
			else:
				img.set_pixel(x, y, Color.hex(0x000000FF))
			
			cptCase += 1

	self.water_map = img

func generate_temperature_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 4.0 / float(self.circonference)
	noise.fractal_octaves = 14
	noise.fractal_gain = 0.25
	noise.fractal_lacunarity = 0.2

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			# Latitude-based temperature adjustment
			var latitude = abs((y / (self.circonference / 2.0)) - 0.5) * 2.0  # Normalized latitude (0 at equator, 1 at poles)
			var latitude_temp = -5.0 * latitude + 5.0 * (1-latitude) + self.avg_temperature

			# Altitude-based temperature adjustment
			var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var altitude_temp = -0.065 * (elevation_val - self.water_elevation)  # Temperature decreases by 6.5°C per 100m

			# Noise-based randomness
			var noise_value = noise.get_noise_2d(float(x), float(y))
			var noise_temp_factor = noise_value * self.avg_temperature / 1.5 

			# Calculate final temperature
			var temp = latitude_temp + altitude_temp + noise_temp_factor

			if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				temp = temp - 5.6

			# Get color based on temperature
			var color = Enum.getTemperatureColor(temp)
			img.set_pixel(x, y, color)
			#print("x:", x, " y:", y, " temperature_val:", temp)

	self.temperature_map = img

func generate_biome_map() -> void:
	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)
	
	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5
	
	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var precipitation_val = self.precipitation_map.get_pixel(x, y).r
			var temperature_val = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
			var is_water        = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)

			var biome_color = Enum.getBiomeColor(elevation_val, precipitation_val, temperature_val, is_water)
			img.set_pixel(x, y, biome_color)
			#print("x:", x, " y:", y, " biome_val:", biome_color)

	self.biome_map = img

# Génère une carte géopolitique simple basée sur zones colorées aléatoirement
func generate_geopolitical_map() -> void:
	pass
	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation des couleurs")
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var colors = [Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW, Color.ORANGE]

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var id = int(floor(float(x) / 100)) % colors.size()
			img.set_pixel(x, y, colors[id])
	self.geopo_map = img

func getMaps() -> Array[String]:
	deleteImagesTemps()

	print("Génération image map élévation.")
	return [
		save_image(self.elevation_map,"elevation_map.png"),
		save_image(self.precipitation_map,"precipitation_map.png"),
		save_image(self.temperature_map,"temperature_map.png"),
		save_image(self.water_map,"water_map.png"),
		save_image(self.biome_map,"biome_map.png"),
		save_image(self.geopo_map,"geopo_map.png")
	]

static func save_image(image: Image, file_name: String) -> String:
	var dir = DirAccess.open("res://data/img/temp")
	if dir == null:
		dir = DirAccess.open("res://data/img")
		dir.make_dir("temp")
		dir = DirAccess.open("res://data/img/temp")

	var img_path = "res://data/img/temp/" + file_name
	image.save_png(img_path)
	print("Saved: ", img_path)
	return img_path

static func deleteImagesTemps():
	var dir = DirAccess.open("res://data/img/temp")
	if dir == null:
		dir = DirAccess.open("res://data/img")
		dir.make_dir("temp")
		dir = DirAccess.open("res://data/img/temp")

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
