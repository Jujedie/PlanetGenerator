extends RefCounted

# TODO :
# - Verifier tout fonctionne | biomes manquants toxiques


class_name PlanetGenerator

var nom: String
signal finished
var circonference			: int
var renderProgress			: ProgressBar
var cheminSauvegarde		: String

# Paramètres de génération
var avg_temperature   : float
var water_elevation   : int    # l'élévation de l'eau par rapport à la terre [-oo,+oo]
var avg_precipitation : float  # entre 0 et 1
var elevation_modifier: int
var nb_thread         : int
var atmosphere_type   : int

# Images générées
var elevation_map    : Image
var elevation_map_alt: Image
var precipitation_map: Image
var temperature_map  : Image
var water_map   : Image
var banquise_map: Image
var biome_map   : Image
var oil_map     : Image
var nuage_map   : Image
var final_map   : Image

var preview: Image

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, elevation_modifier_param: int = 0, nb_thread_param : int = 8, atmosphere_type_param: int = 0, renderProgress_param: ProgressBar = null, cheminSauvegarde_param: String = "user://temp/") -> void:
	self.nom = nom_param
	
	self.circonference			=  int(rayon * 2 * PI)
	self.renderProgress			= renderProgress_param
	self.renderProgress.value	= 0.0
	self.cheminSauvegarde		= cheminSauvegarde_param

	self.avg_temperature    = avg_temperature_param
	self.water_elevation    = water_elevation_param
	self.avg_precipitation  = avg_precipitation_param
	self.elevation_modifier = elevation_modifier_param
	self.nb_thread          = nb_thread_param
	self.atmosphere_type    = atmosphere_type_param

func generate_planet():
	print("\nGénération de la carte finale\n")
	var thread_final = Thread.new()
	thread_final.start(generate_final_map)

	thread_final.wait_to_finish()

	print("\nGénération de la carte du pétrole\n")
	var thread_oil = Thread.new()
	thread_oil.start(generate_oil_map)

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


func generate_nuage_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 5 / float(self.circonference)
	noise.fractal_octaves = 8
	noise.fractal_gain = 0.85
	noise.fractal_lacunarity = 1.5

	print("Génération de la carte")
	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise, null, x1, x2, nuage_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.nuage_map = img

func nuage_calcul(img: Image, noise, _noise2, x : int, y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	value = abs(value)

	if value > 0.15:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))  # White for clouds
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))  # Black for no clouds

func generate_elevation_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)
	self.elevation_map_alt = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

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

	# Tectonic plates noises
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

	print("Génération de la carte")
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
			
	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.elevation_map = img

func elevation_calcul(img: Image, noise, noises, x: int, y: int) -> void:
	var noise2 = noises[0]
	var noise3 = noises[1]
	var tectonic_mountain_noise = noises[2]
	var tectonic_canyon_noise = noises[3]

	var value = noise.get_noise_2d(float(x), float(y))
	var value2 = noise2.get_noise_2d(float(x), float(y))
	var elevation = ceil(value * (2000 + clamp(value2, 0.0, 1.0) * elevation_modifier))

	var tectonic_mountain_val = abs(tectonic_mountain_noise.get_noise_2d(float(x), float(y)))
	if tectonic_mountain_val > 0.45 and tectonic_mountain_val < 0.55:
		elevation += 800 * (1.0 - abs(tectonic_mountain_val - 0.5) * 20.0)

	var tectonic_canyon_val = abs(tectonic_canyon_noise.get_noise_2d(float(x), float(y)))
	if tectonic_canyon_val > 0.45 and tectonic_canyon_val < 0.55:
		elevation -= 600 * (1.0 - abs(tectonic_canyon_val - 0.5) * 20.0)

	if elevation > 600:
		var value3 = clamp(noise3.get_noise_2d(float(x), float(y)), 0.0, 1.0)
		elevation = elevation + ceil(value3 * Enum.ALTITUDE_MAX)
	elif elevation <= -600:
		var value3 = clamp(noise3.get_noise_2d(float(x), float(y)), -1.0, 0.0)
		elevation = elevation + ceil(value3 * Enum.ALTITUDE_MAX)

	var color = Enum.getElevationColor(elevation)
	img.set_pixel(x, y, color)
	color = Enum.getElevationColor(elevation, true)
	self.elevation_map_alt.set_pixel(x, y, color)


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
		thread.start(thread_calcul.bind(img, noise, self.atmosphere_type != 3, x1, x2, oil_calcul))
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.oil_map = img

func oil_calcul(img: Image,noise, noise2, x : int,y : int) -> void:
	var value = noise.get_noise_2d(float(x), float(y))
	value = clamp(value, 0.0, 1.0)

	if value > 0.25 and noise2:
		img.set_pixel(x, y, Color.hex(0x000000FF))
	else:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))


func generate_banquise_map() -> void:
	randomize()

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")

	print("Génération de la carte")
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

	print("Fin de la génération de la carte")
	self.addProgress(15)
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

	print("Création de l'image")
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGB8)

	print("Initialisation du bruit")
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 2.0 / float(self.circonference)
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

	img.set_pixel(x, y, Enum.getPrecipitationColor(value))


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
		thread.start(thread_calcul.bind(img, noise, 0, x1, x2, water_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(15)
	self.water_map = img

func water_calcul(img: Image,noise, _noise2, x : int,y : int) -> void:
	if self.atmosphere_type == 3:
		img.set_pixel(x, y, Color.hex(0x000000FF))
		return
	
	randomize()

	var value = noise.get_noise_2d(float(x), float(y))
	value = abs(value)

	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			
	if elevation_val <= self.water_elevation:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
	else:
		img.set_pixel(x, y, Color.hex(0x000000FF))


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
	var latitude = abs((y / (self.circonference / 2.0)) - 0.5) * 2.0  # Normalized latitude (0 at equator, 1 at poles)
	var latitude_temp = -20.5 * latitude + 7.5 * (1-latitude) + self.avg_temperature

	# Altitude-based temperature adjustment
	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var altitude_temp = 0.0

	altitude_temp = get_temperature_delta_from_altitude(elevation_val - self.water_elevation )

	# Noise-based randomness
	var noise_value = noise.get_noise_2d(float(x), float(y))
	var noise_temp_factor = noise_value * (self.avg_temperature / 1.5) 
	noise_value = noise2.get_noise_2d(float(x), float(y))
	noise_temp_factor += noise_value * (self.avg_temperature / 3)

	# Calculate final temperature
	var temp = latitude_temp + altitude_temp + noise_temp_factor

	if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		temp = temp - 5.6
	
	if temp > 100 and self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		temp = 100.0  # Cap temperature at 100°C for water areas

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

	for thread in threadArray:
		thread.wait_to_finish()

	print("Fin de la génération de la carte")
	self.addProgress(38)
	self.biome_map = img

func biome_calcul(img: Image,_noise, _noise2, x : int,y : int) -> void:
	var elevation_val     = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var precipitation_val = self.precipitation_map.get_pixel(x, y).r
	var temperature_val   = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
	var is_water          = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)

	var biome
	if self.banquise_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		biome = Enum.getBanquiseBiome(self.atmosphere_type)
	else:
		biome = Enum.getBiome(self.atmosphere_type, elevation_val, precipitation_val, temperature_val, is_water, img, x, y)

	var elevation_color = Enum.getElevationColor(elevation_val, true)
	var color_final = elevation_color * biome.get_couleur_vegetation() 
	#if self.nuage_map.get_pixel(x, y) != Color.hex(0x000000FF):
	#	color_final = Color.hex(0xFFFFFF01)

	img.set_pixel(x, y, biome.get_couleur())
	self.final_map.set_pixel(x, y, color_final)


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
		save_image(self.elevation_map_alt,"elevation_map_alt.png"),
		save_image(self.nuage_map,"nuage_map.png"),
		save_image(self.oil_map,"oil_map.png"),
		save_image(self.precipitation_map,"precipitation_map.png"),
		save_image(self.temperature_map,"temperature_map.png"),
		save_image(self.water_map,"water_map.png"),
		save_image(self.biome_map,"biome_map.png"),
		save_image(self.final_map,"final_map.png")
	]

func is_ready() -> bool:
	return self.elevation_map != null and self.precipitation_map != null and self.temperature_map != null and self.water_map != null and self.biome_map != null and self.final_map != null

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
		print("Directory 'user://temp/' does not exist, creating it.")
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
