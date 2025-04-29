extends RefCounted

class_name PlanetGenerator

# TO DO REMOVE INSTANCE PARAMETERS FROM INSTANCE METHODS

var nom: String
var circonference    : int

# Paramètres de génération
var avg_temperature  : float
var water_elevation  : int    # l'élévation de l'eau par rapport à la terre [-oo,+oo]
var avg_precipitation: float  # entre 0 et 1

# Images générées
var elevation_map    : Image
var precipitation_map: Image
var temperature_map  : Image
var water_map   : Image
var biome_map   : Image
var geopo_map   : Image

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5):
	self.nom = nom_param
	
	self.circonference     =  int(rayon * 2 * PI)

	self.avg_temperature   = avg_temperature_param
	self.water_elevation   = water_elevation_param
	self.avg_precipitation = avg_precipitation_param

func generate_planet():
	print("Génération de la carte topographique")
	self.elevation_map = generate_elevation_map()

	print("Génération de la carte des précipitations")
	self.precipitation_map = generate_precipitation_map()

	print("Génération de la carte des températures moyennes")
	self.temperature_map = generate_temperature_map()

	print("Génération de la carte des mers")
	self.water_map = generate_water_map()

	print("Génération de la carte des biomes")
	self.biome_map = generate_biome_map()

	print("Génération de la carte géopolitique")
	self.geopo_map = generate_geopolitical_map()

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

func generate_elevation_map() -> Image:
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

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var value = noise.get_noise_2d(float(x), float(y))
			var elevation = ceil(value * 2500.0)
			var color = Couleurs.getElevationColor(elevation)

			img.set_pixel(x, y, color)
			print("x:", x, " y:", y, " elevation_val:", elevation)

	return img

func generate_precipitation_map() -> Image:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var value = noise.get_noise_2d(float(x), float(y))
			value = clamp(value, 0.0, 1.0)
			img.set_pixel(x, y, Color(value, value, value))
			print("x:", x, " y:", y, " precipitation_val:", value)

	return img

func generate_temperature_map() -> Image:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 1.0 / float(self.circonference)
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 0.5

	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var lat  = float(y) / self.circonference/2
			var temp = self.avg_temperature + (noise.get_noise_2d(float(x), float(y)) * 20.0) - (lat * 20.0)
			var color= Couleurs.getTemperatureColor(temp)
			img.set_pixel(x, y, color)
			print("x:", x, " y:", y, " temperature_val:", temp)

	return img

func generate_water_map() -> Image:
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
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var value = noise.get_noise_2d(float(x), float(y))
			value = clamp(value, 0.0, 1.0)

			var elevation_val = Couleurs.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			if elevation_val <= self.water_elevation and value < 0.5:
				img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
			else:
				img.set_pixel(x, y, Color.hex(0x000000FF))
			print("x:", x, " y:", y, " water_val:", value)

	return img

func generate_biome_map() -> Image:
	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)
	
	print("Génération de la carte")
	for x in range(self.circonference):
		for y in range(self.circonference / 2):

			var elevation_val = Couleurs.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var precipitation_val = self.precipitation_map.get_pixel(x, y).r
			var temperature_val = Couleurs.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
			var is_water = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)

			var biome_color = Couleurs.getBiomeColor(elevation_val, precipitation_val, temperature_val, is_water)
			img.set_pixel(x, y, biome_color)
			print("x:", x, " y:", y, " biome_val:", biome_color)

	return img

# Génère une carte géopolitique simple basée sur zones colorées aléatoirement
func generate_geopolitical_map() -> Image:
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
	return img

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
