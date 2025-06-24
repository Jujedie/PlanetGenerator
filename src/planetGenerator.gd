extends RefCounted

class_name PlanetGenerator

var nom: String
signal finished
var circonference   : int
var renderProgress  : ProgressBar
var cheminSauvegarde: String

# Paramètres de génération
var avg_temperature   : float
var water_elevation   : int    # l'élévation de l'eau par rapport à la terre [-oo,+oo]
var avg_precipitation : float  # entre 0 et 1
var percent_eau_monde : float
var elevation_modifier: int
var nb_thread         : int

# Images générées
var elevation_map    : Image
var precipitation_map: Image
var temperature_map  : Image
var water_map   : Image
var banquise_map: Image
var biome_map   : Image
var oil_map     : Image
var final_map   : Image

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, percent_eau_monde_param: float = 0.7, elevation_modifier_param: int = 0, nb_thread_param : int = 8, renderProgress: ProgressBar = null, cheminSauvegarde_param: String = "res://data/img/temp/") -> void:
	self.nom = nom_param
	
	self.circonference        =  int(rayon * 2 * PI)
	self.renderProgress       = renderProgress
	self.renderProgress.value = 0.0
	self.cheminSauvegarde     = cheminSauvegarde_param

	self.avg_temperature   = avg_temperature_param
	self.water_elevation   = water_elevation_param
	self.avg_precipitation = avg_precipitation_param
	self.percent_eau_monde = percent_eau_monde_param
	self.elevation_modifier= elevation_modifier_param
	self.nb_thread         = nb_thread_param

	

func generate_planet():
	print("\nGénération de la carte finale\n")
	var thread_final = Thread.new()
	thread_final.start(generate_final_map)

	print("\nGénération de la carte du pétrole\n")
	var thread_oil = Thread.new()
	thread_oil.start(generate_oil_map)

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

	print("\nGénération de la carte des températures moyennes\n")
	var thread_temperature = Thread.new()
	thread_temperature.start(generate_temperature_map)

	thread_temperature.wait_to_finish()

	print("\nGénération de la carte de la banquise\n")
	var thread_banquise = Thread.new()
	thread_banquise.start(generate_banquise_map)

	print("\nGénération de la carte des biomes\n")
	var thread_biome = Thread.new()
	thread_biome.start(generate_biome_map)

	thread_biome.wait_to_finish()

	print("\n===================")
	print("Génération Terminée\n")
	emit_signal("finished")

func save_maps():
	print("\nSauvegarde de la carte finale")
	save_image(self.final_map, "final_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte topographique")
	save_image(self.elevation_map, "elevation_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des précipitations")
	save_image(self.precipitation_map, "precipitation_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des températures moyennes")
	save_image(self.temperature_map, "temperature_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des mers")
	save_image(self.water_map, "water_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte de la banquise")
	save_image(self.banquise_map, "banquise_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte des biomes")
	save_image(self.biome_map, "biome_map.png", self.cheminSauvegarde)

	print("\nSauvegarde de la carte du pétrole")
	save_image(self.oil_map, "oil_map.png", self.cheminSauvegarde)


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

	var noise3 = FastNoiseLite.new()
	noise3.seed = randi()
	noise3.noise_type = FastNoiseLite.TYPE_PERLIN
	noise3.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise3.frequency = 1.504 / float(self.circonference)
	noise3.fractal_octaves = 6
	noise3.fractal_gain = 0.85
	noise3.fractal_lacunarity = 3.0

	var noiseTectonic = FastNoiseLite.new()
	noiseTectonic.seed = randi()
	noiseTectonic.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	noiseTectonic.fractal_type = FastNoiseLite.FRACTAL_FBM
	noiseTectonic.frequency = 0.5 / float(self.circonference)
	noiseTectonic.fractal_octaves = 6
	noiseTectonic.fractal_gain = 0.5
	noiseTectonic.fractal_lacunarity = 4.0

	print("Génération de la carte")
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, [ noise, noise2, noise3], noiseTectonic, x1, x2, elevation_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()
			
	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.elevation_map = img

func elevation_calcul(img: Image,noise, noise2, x : int,y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	var value2 = noise2[0].get_noise_2d(float(x), float(y))
	var elevation = ceil(value * (1680 + clamp(value2, 0.0, 1.0) * elevation_modifier))
	if elevation > 600:
		print("Elevation : ", elevation, " - Value: ", value, " - Value2: ", value2)

	if elevation >= 600:
		value = noise2[1].get_noise_2d(float(x), float(y))
		if value < 0.0:
			value = value * -1.0 
		print("Elevation positive : ", elevation, " - Value2: ", value)
		elevation = elevation + ceil(value * Enum.ALTITUDE_MAX)
	elif elevation <= -600:
		value = noise2[1].get_noise_2d(float(x), float(y))
		if value > 0.0:
			value = value * -1.0
		elevation = elevation + ceil(value * Enum.ALTITUDE_MAX)

	var color = Enum.getElevationColor(elevation)

	img.set_pixel(x, y, color)


func generate_oil_map() -> void:
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
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise, x1, x2, oil_calcul))
	# Wait for all threads to finish after starting them all
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.oil_map = img

func oil_calcul(img: Image,noise, _noise2, x : int,y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	value = clamp(value, 0.0, 1.0)

	if value > 0.25:
		img.set_pixel(x, y, Color.hex(0x000000FF))  # Oil color
	else:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))  # Non-oil area


func generate_banquise_map() -> void:
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
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise, x1, x2, banquise_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.banquise_map = img

func banquise_calcul(img: Image,noise, _noise2, x : int,y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	value = abs(value)

	if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		if Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y)) < 0.0 and value > 0.05:
			img.set_pixel(x, y, Color.hex(0xFFFFFFFF))  # Ice color
		else:
			img.set_pixel(x, y, Color.hex(0x000000FF))  # Non-ice area
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))  # Non-ice area


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

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.precipitation_map = img

func precipitation_calcul(img: Image,noise, _noise2, x : int,y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	value = clamp((value + self.avg_precipitation * value / 2.0), 0.0, 1.0)

	img.set_pixel(x, y, Color(value, value, value))


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
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise, x1, x2, water_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.water_map = img

func water_calcul(img: Image,noise, _noise2, x : int,y : int) -> void:
		var cptCase = 0
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

	var noise2 = FastNoiseLite.new()
	noise2.seed = randi()
	noise2.noise_type = FastNoiseLite.TYPE_PERLIN
	noise2.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise2.frequency = 2.0 / float(self.circonference)
	noise2.fractal_octaves = 8
	noise2.fractal_gain = 0.75
	noise2.fractal_lacunarity = 2.0

	print("Génération de la carte")
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise2, x1, x2, temperature_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.temperature_map = img

func temperature_calcul(img: Image,noise, noise2, x : int,y : int) -> void:
	# Latitude-based temperature adjustment
	var latitude = abs((y / (self.circonference / 2.0)) - 0.5) * 2.0  # Normalized latitude (0 at equator, 1 at poles)
	var latitude_temp = -7.5 * latitude + 7.5 * (1-latitude) + self.avg_temperature

	# Altitude-based temperature adjustment
	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var altitude_temp = 0.0

	if elevation_val > self.water_elevation:
		altitude_temp = -0.065 * (elevation_val - self.water_elevation)  # Temperature decreases by 6.5°C per 100m
	elif elevation_val < self.water_elevation and self.water_map.get_pixel(x, y) != Color.hex(0xFFFFFFFF):
		altitude_temp = -0.02 * (self.water_elevation - elevation_val)  # Temperature increases by 6.5°C per 100m
	
	# Noise-based randomness
	var noise_value = noise.get_noise_2d(float(x), float(y))
	var noise_temp_factor = noise_value * (self.avg_temperature / 1.5) 
	noise_value = noise2.get_noise_2d(float(x), float(y))
	noise_temp_factor += noise_value * (self.avg_temperature / 3)

	# Calculate final temperature
	var temp = latitude_temp + altitude_temp + noise_temp_factor

	if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		temp = temp - 5.6

	# Get color based on temperature
	var color = Enum.getTemperatureColor(temp)

	img.set_pixel(x, y, color)


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
	var range = circonference / self.nb_thread
	var threadArray = []
	for i in range(0, self.nb_thread, 1):
		var x1 = i * range
		var x2 = self.circonference if i == (self.nb_thread - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, noise, x1, x2, biome_calcul))
	# Wait for all threads to finish after starting them all
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(38)
	self.biome_map = img

func biome_calcul(img: Image,_noise, _noise2, x : int,y : int) -> void:
	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var precipitation_val = self.precipitation_map.get_pixel(x, y).r
	var temperature_val = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
	var is_water = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)

	var biome = Enum.getBiome(elevation_val, precipitation_val, temperature_val, is_water, img, x, y)

	img.set_pixel(x, y, biome.get_couleur())
	self.final_map.set_pixel(x, y, biome.get_couleur_vegetation())


func thread_calcul(img: Image, noise: FastNoiseLite, misc_value , x1: int, x2: int, function : Callable) -> void:
	for x in range(x1, x2):
		for y in range(self.circonference / 2):
			function.call(img, noise, misc_value, x, y)


func generate_final_map() -> void:
	pass
	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Fin de la génération de la carte")
	self.addProgress(2)
	self.final_map = img

func getMaps() -> Array[String]:
	deleteImagesTemps()

	return [
		save_image(self.elevation_map,"elevation_map.png"),
		save_image(self.oil_map,"oil_map.png"),
		save_image(self.precipitation_map,"precipitation_map.png"),
		save_image(self.temperature_map,"temperature_map.png"),
		save_image(self.water_map,"water_map.png"),
		save_image(self.banquise_map,"banquise_map.png"),
		save_image(self.biome_map,"biome_map.png"),
		save_image(self.final_map,"final_map.png")
	]

func is_ready() -> bool:
	return self.elevation_map != null and self.precipitation_map != null and self.temperature_map != null and self.water_map != null and self.biome_map != null and self.final_map != null

func addProgress(value) -> void:
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

static func save_image(image: Image, file_name : String, file_path: String = "res://data/img/temp/") -> String:
	if not file_path.ends_with("/"):
		file_path += "/"
	
	var dir = DirAccess.open(file_path)
	if dir == null && file_path == "res://data/img/temp/":
		dir = DirAccess.open("res://data/img/")
		dir.make_dir("temp")
		dir = DirAccess.open("res://data/img/temp/")
	else :
		DirAccess.make_dir_absolute(file_path)
		dir = DirAccess.open(file_path)

	var img_path = file_path + file_name
	image.save_png(img_path)
	print("Saved: ", img_path)
	return img_path

static func deleteImagesTemps():
	var dir = DirAccess.open("res://data/img/temp/")
	if dir == null:
		dir = DirAccess.open("res://data/img/")
		dir.make_dir("temp")
		dir = DirAccess.open("res://data/img/temp/")

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
