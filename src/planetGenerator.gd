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
var river_map   : Image
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

	# Génération du pétrole APRÈS elevation_map et water_map (dépendances)
	print("\nGénération de la carte du pétrole\n")
	var thread_oil = Thread.new()
	thread_oil.start(generate_oil_map)

	# Génération des ressources APRÈS water_map pour éviter les ressources dans l'eau
	print("\nGénération de la carte des ressources\n")
	var thread_ressource = Thread.new()
	thread_ressource.start(generate_ressource_map)

	print("\nGénération de la carte des températures moyennes\n")
	var thread_temperature = Thread.new()
	thread_temperature.start(generate_temperature_map)

	thread_temperature.wait_to_finish()

	print("\nGénération de la carte des rivières/lacs\n")
	var thread_river = Thread.new()
	thread_river.start(generate_river_map)

	thread_river.wait_to_finish()

	print("\nGénération de la carte des regions\n")
	var thread_region = Thread.new()
	thread_region.start(generate_region_map)

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

	print("\nSauvegarde de la carte des rivières/lacs")
	save_image(self.river_map, "river_map.png", self.cheminSauvegarde)

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

	# Bruit principal pour les bassins sédimentaires (grandes structures géologiques)
	var noise_basin = FastNoiseLite.new()
	noise_basin.seed = randi()
	noise_basin.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_basin.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_basin.frequency = 1.0 / float(self.circonference)
	noise_basin.fractal_octaves = 5
	noise_basin.fractal_gain = 0.5
	noise_basin.fractal_lacunarity = 2.0

	# Bruit pour les gisements locaux (poches de pétrole)
	var noise_deposit = FastNoiseLite.new()
	noise_deposit.seed = randi()
	noise_deposit.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise_deposit.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_deposit.frequency = 5.0 / float(self.circonference)
	noise_deposit.fractal_octaves = 4
	noise_deposit.fractal_gain = 0.6
	noise_deposit.fractal_lacunarity = 2.5
	noise_deposit.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise_deposit.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2

	# Bruit pour les failles géologiques (où le pétrole peut s'accumuler)
	var noise_fault = FastNoiseLite.new()
	noise_fault.seed = randi()
	noise_fault.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_fault.frequency = 2.5 / float(self.circonference)
	noise_fault.fractal_octaves = 3
	noise_fault.fractal_gain = 0.4

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise_basin, [noise_deposit, noise_fault, self.atmosphere_type != 3], x1, x2, oil_calcul))
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(5)
	self.oil_map = img

func oil_calcul(img: Image, noise_basin, noises, x : int, y : int) -> void:
	var noise_deposit = noises[0]
	var noise_fault = noises[1]
	var has_atmosphere = noises[2]
	
	# Pas de pétrole sans atmosphère (pas de vie organique historique)
	if not has_atmosphere:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))
		return
	
	var coords = get_cylindrical_coords(x, y)
	var height = self.circonference / 2
	
	# Obtenir l'élévation - le pétrole se forme dans les bassins sédimentaires
	var elevation = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var is_water = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	
	# Facteur d'élévation - le pétrole est plus probable:
	# - Sous les océans peu profonds (plateaux continentaux)
	# - Dans les basses terres et bassins
	# - Moins probable en haute montagne
	var elevation_factor : float
	if is_water:
		# Sous l'eau: plus probable près des côtes (plateaux continentaux)
		var depth = self.water_elevation - elevation
		if depth < 500:  # Plateau continental
			elevation_factor = 0.9
		elif depth < 2000:  # Pente continentale
			elevation_factor = 0.5
		else:  # Plaine abyssale - moins de sédiments organiques
			elevation_factor = 0.2
	else:
		# Sur terre: bassins et plaines sont favorables
		var alt_above_water = elevation - self.water_elevation
		if alt_above_water < 200:  # Plaines côtières
			elevation_factor = 0.85
		elif alt_above_water < 500:  # Plaines
			elevation_factor = 0.7
		elif alt_above_water < 1500:  # Collines
			elevation_factor = 0.4
		else:  # Montagnes
			elevation_factor = 0.1
	
	# Bruit de bassin sédimentaire (grandes zones)
	var basin_value = noise_basin.get_noise_3d(coords.x, coords.y, coords.z)
	basin_value = (basin_value + 1.0) / 2.0
	
	# Bruit de gisement (poches locales)
	var deposit_value = noise_deposit.get_noise_3d(coords.x, coords.y, coords.z)
	deposit_value = (deposit_value + 1.0) / 2.0
	
	# Bruit de faille géologique (accumulation le long des failles)
	var fault_value = abs(noise_fault.get_noise_3d(coords.x, coords.y, coords.z))
	var fault_bonus = 0.0
	if fault_value > 0.4 and fault_value < 0.6:  # Près d'une faille
		fault_bonus = 0.3 * (1.0 - abs(fault_value - 0.5) * 5.0)
	
	# Combiner tous les facteurs
	var oil_probability = basin_value * 0.4 + deposit_value * 0.3 + fault_bonus
	oil_probability = oil_probability * elevation_factor
	
	# Seuil pour déterminer la présence de pétrole
	if oil_probability > 0.35:
		img.set_pixel(x, y, Color.hex(0x000000FF))  # Pétrole présent
	else:
		img.set_pixel(x, y, Color.hex(0xFFFFFFFF))  # Pas de pétrole


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

	# Bruit principal - grandes masses d'air humides/sèches
	var noise_main = FastNoiseLite.new()
	noise_main.seed = randi()
	noise_main.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_main.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_main.frequency = 2.5 / float(self.circonference)
	noise_main.fractal_octaves = 6
	noise_main.fractal_gain = 0.55
	noise_main.fractal_lacunarity = 2.0

	# Bruit de détail pour les variations locales
	var noise_detail = FastNoiseLite.new()
	noise_detail.seed = randi()
	noise_detail.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_detail.frequency = 6.0 / float(self.circonference)
	noise_detail.fractal_octaves = 4
	noise_detail.fractal_gain = 0.5
	noise_detail.fractal_lacunarity = 2.0

	# Bruit cellulaire pour créer des zones de pluie irrégulières
	var noise_cells = FastNoiseLite.new()
	noise_cells.seed = randi()
	noise_cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise_cells.frequency = 4.0 / float(self.circonference)
	noise_cells.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise_cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE

	var range = circonference / (self.nb_thread / 2)
	var threadArray = []
	for i in range(0, (self.nb_thread / 2), 1):
		var x1 = i * range
		var x2 = self.circonference if i == ((self.nb_thread / 2) - 1) else (i + 1) * range
		var thread = Thread.new()
		threadArray.append(thread)
		thread.start(thread_calcul.bind(img, noise_main, [noise_detail, noise_cells], x1, x2, precipitation_calcul))
	
	for thread in threadArray:
		thread.wait_to_finish()

	self.addProgress(10)
	self.precipitation_map = img

func precipitation_calcul(img: Image, noise_main, noises, x : int, y : int) -> void:
	var coords = get_cylindrical_coords(x, y)
	var noise_detail = noises[0]
	var noise_cells = noises[1]
	
	var height = self.circonference / 2
	
	# Latitude normalisée (0 à l'équateur, 1 aux pôles)
	var latitude = abs((float(y) / float(height)) - 0.5) * 2.0
	
	# Bruit principal - zones de haute/basse pression atmosphérique
	var main_value = noise_main.get_noise_3d(coords.x, coords.y, coords.z)
	main_value = (main_value + 1.0) / 2.0
	
	# Bruit de détail
	var detail_value = noise_detail.get_noise_3d(coords.x, coords.y, coords.z)
	detail_value = (detail_value + 1.0) / 2.0
	
	# Bruit cellulaire pour créer des fronts météo
	var cell_value = noise_cells.get_noise_3d(coords.x, coords.y, coords.z)
	cell_value = (cell_value + 1.0) / 2.0
	
	# Combiner les bruits de manière organique
	var base_precip = main_value * 0.6 + detail_value * 0.25 + cell_value * 0.15
	
	# Légère influence de la latitude (moins prononcée pour éviter les bandes)
	# Équateur légèrement plus humide, subtropiques légèrement plus secs
	var lat_influence = 1.0
	if latitude < 0.2:
		# Zone équatoriale - un peu plus humide
		lat_influence = 1.0 + 0.15 * (1.0 - latitude / 0.2)
	elif latitude > 0.25 and latitude < 0.4:
		# Zone subtropicale - un peu plus sèche
		var t = (latitude - 0.25) / 0.15
		lat_influence = 1.0 - 0.2 * sin(t * PI)
	elif latitude > 0.85:
		# Pôles - plus secs
		lat_influence = 1.0 - 0.3 * (latitude - 0.85) / 0.15
	
	# Appliquer l'influence de latitude de manière subtile
	var value = base_precip * lat_influence
	
	# Appliquer le modificateur global de précipitation
	value = value * (0.4 + self.avg_precipitation * 0.6)
	
	# Clamper le résultat
	value = clamp(value, 0.0, 1.0)

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


# =============================================================================
# GÉNÉRATION DES RIVIÈRES / FLEUVES / LACS
# =============================================================================

func generate_river_map() -> void:
	randomize()
	var height = int(self.circonference / 2)
	var img = Image.create(self.circonference, height, false, Image.FORMAT_RGBA8)
	
	# Remplir avec transparent
	img.fill(Color.hex(0x00000000))
	
	# Ne pas générer de rivières sur planètes sans atmosphère
	if self.atmosphere_type == 3:
		self.river_map = img
		self.addProgress(5)
		return
	
	var base_seed = randi()
	
	# Bruit pour déterminer les sources de rivières
	var source_noise = FastNoiseLite.new()
	source_noise.seed = base_seed
	source_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	source_noise.frequency = 6.0 / float(self.circonference)
	source_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	source_noise.fractal_octaves = 3
	
	# Bruit pour les méandres
	var meander_noise = FastNoiseLite.new()
	meander_noise.seed = base_seed + 2
	meander_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	meander_noise.frequency = 25.0 / float(self.circonference)
	
	# Bruit pour les lacs
	var lake_noise = FastNoiseLite.new()
	lake_noise.seed = base_seed + 3
	lake_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	lake_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	lake_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	lake_noise.frequency = 6.0 / float(self.circonference)
	
	# =========================================================================
	# ÉTAPE 1: Trouver les sources de rivières
	# On cherche des points en altitude avec de bonnes précipitations
	# =========================================================================
	var sources : Array = []
	var step = max(3, self.circonference / 256)
	var source_threshold = 0.25  # Seuil plus bas pour plus de rivières
	
	for x in range(0, self.circonference, step):
		for y in range(0, height, step):
			# Pas sur l'eau (océan)
			if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			
			# Température > 0°C (sauf glaciers qui fondent)
			var temp = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
			if temp <= -10:  # Permettre fonte glaciaire
				continue
			
			var elevation = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var precipitation = self.precipitation_map.get_pixel(x, y).r
			
			# Les sources doivent être en altitude (> 100m au-dessus du niveau de la mer)
			if elevation < self.water_elevation + 100:
				continue
			
			# Vérifier le bruit
			var coords = get_cylindrical_coords(x, y)
			var noise_val = source_noise.get_noise_3d(coords.x, coords.y, coords.z)
			if noise_val < source_threshold:
				continue
			
			# Score: favorise haute altitude + bonnes précipitations
			var altitude_score = (elevation - self.water_elevation) / 1000.0
			var score = altitude_score * (precipitation + 0.3) * (noise_val + 0.5)
			
			# Taille de rivière basée sur l'altitude et les précipitations
			var river_size = 0
			if elevation > 2000 and precipitation > 0.5:
				river_size = 2  # Fleuve
			elif elevation > 500 or precipitation > 0.4:
				river_size = 1  # Rivière moyenne
			# else: affluent
			
			sources.append({
				"x": x, 
				"y": y, 
				"score": score, 
				"elevation": elevation,
				"river_size": river_size,
				"temperature": temp,
				"precipitation": precipitation
			})
	
	# Trier par score et espacer les sources
	sources.sort_custom(func(a, b): return a.score > b.score)
	
	var selected_sources : Array = []
	var min_distance = max(10, self.circonference / 60)  # Moins d'espacement = plus de rivières
	var max_rivers = max(40, self.circonference / 25)    # Plus de rivières
	
	for source in sources:
		if selected_sources.size() >= max_rivers:
			break
		
		var too_close = false
		for existing in selected_sources:
			var dx = abs(source.x - existing.x)
			dx = min(dx, self.circonference - dx)
			var dy = abs(source.y - existing.y)
			if sqrt(dx * dx + dy * dy) < min_distance:
				too_close = true
				break
		
		if not too_close:
			selected_sources.append(source)
	
	# =========================================================================
	# ÉTAPE 2: Tracer chaque rivière avec un algorithme amélioré
	# =========================================================================
	for source in selected_sources:
		trace_river_to_ocean(img, source, meander_noise, height)
	
	# =========================================================================
	# ÉTAPE 3: Générer les lacs
	# =========================================================================
	generate_lakes(img, lake_noise, height)
	
	self.addProgress(5)
	self.river_map = img


func trace_river_to_ocean(img: Image, source: Dictionary, meander_noise: FastNoiseLite, height: int) -> void:
	var x = source.x
	var y = source.y
	var river_size = source.river_size
	var temp = source.temperature
	var precipitation = source.precipitation
	
	var river_color = get_river_color_by_size(river_size)
	
	var visited : Dictionary = {}
	var max_steps = self.circonference * 3  # Beaucoup plus de steps permis
	var steps_since_descent = 0  # Compteur pour détecter les plateaux
	var last_elevation = source.elevation
	
	# Probabilité de bifurcation augmente avec les précipitations
	var split_chance = 0.03 + precipitation * 0.05  # 3% à 8%
	
	for step in range(max_steps):
		# Vérifier si on a atteint l'océan
		if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			# Succès! La rivière a rejoint l'océan
			break
		
		# Éviter les boucles
		var key = str(x) + "_" + str(y)
		if visited.has(key):
			break
		visited[key] = true
		
		# Dessiner le pixel
		img.set_pixel(x, y, river_color)
		
		# Récupérer l'élévation actuelle
		var current_elev = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
		
		# Détecter si on descend
		if current_elev < last_elevation:
			steps_since_descent = 0
		else:
			steps_since_descent += 1
		last_elevation = current_elev
		
		# Si on est bloqué sur un plateau trop longtemps, créer un lac
		if steps_since_descent > 50:
			img.set_pixel(x, y, get_lake_color(temp))
			break
		
		# =====================================================================
		# Chercher la meilleure direction
		# =====================================================================
		var directions = [
			Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)
		]
		
		var candidates : Array = []
		var ocean_candidate = null
		
		for dir in directions:
			var nx = wrap_x(x + dir.x)
			var ny = y + dir.y
			
			if ny < 0 or ny >= height:
				continue
			
			# Vérifier si déjà visité
			var nkey = str(nx) + "_" + str(ny)
			if visited.has(nkey):
				continue
			
			# Priorité: océan
			if self.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
				ocean_candidate = {"dir": dir, "nx": nx, "ny": ny}
				break
			
			var elev = Enum.getElevationViaColor(self.elevation_map.get_pixel(nx, ny))
			var descent = current_elev - elev
			
			# Calculer un score pour chaque direction
			# On accepte même les légères montées pour traverser les plateaux
			var tolerance = 20 + steps_since_descent * 5  # Plus on est bloqué, plus on tolère
			
			if descent >= -tolerance:
				# Bonus si on descend vraiment
				var score = descent
				# Bonus si on se rapproche de l'eau (approximation par élévation basse)
				if elev < current_elev:
					score += 10
				# Petit bonus aléatoire pour les méandres
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
		
		# Si on a trouvé l'océan, y aller directement
		if ocean_candidate != null:
			x = ocean_candidate.nx
			y = ocean_candidate.ny
			img.set_pixel(x, y, river_color)
			break
		
		# Si aucun candidat, créer un lac et arrêter
		if candidates.size() == 0:
			img.set_pixel(x, y, get_lake_color(temp))
			break
		
		# Trier par score (meilleure descente + méandres)
		candidates.sort_custom(func(a, b): return a.score > b.score)
		
		# =====================================================================
		# Bifurcation (création d'affluents)
		# =====================================================================
		if candidates.size() >= 2 and step > 5 and randf() < split_chance:
			# Créer un affluent vers la 2ème meilleure direction
			var tributary_source = {
				"x": candidates[1].nx,
				"y": candidates[1].ny,
				"river_size": 0,  # Toujours un affluent
				"temperature": temp,
				"precipitation": precipitation * 0.6,
				"elevation": candidates[1].elev
			}
			# Tracer l'affluent (récursif mais avec moins de potentiel)
			trace_tributary(img, tributary_source, meander_noise, height, visited.duplicate())
		
		# Choisir la direction principale
		var best = candidates[0]
		
		# Parfois prendre une direction alternative pour les méandres
		if candidates.size() > 1 and randf() < 0.15 and abs(candidates[0].score - candidates[1].score) < 20:
			best = candidates[1]
		
		x = best.nx
		y = best.ny


func trace_tributary(img: Image, source: Dictionary, meander_noise: FastNoiseLite, height: int, parent_visited: Dictionary) -> void:
	# Trace un affluent (version simplifiée, moins longue, pas de sous-bifurcations)
	var x = source.x
	var y = source.y
	var _temp = source.temperature
	
	var river_color = get_river_color_by_size(0)  # Couleur affluent
	var visited = parent_visited  # Hérite des pixels visités du parent
	var max_steps = 100  # Affluents plus courts
	var steps_since_descent = 0
	var last_elevation = source.elevation
	
	for step in range(max_steps):
		if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
			break
		
		var key = str(x) + "_" + str(y)
		if visited.has(key):
			break
		visited[key] = true
		
		# Ne pas écraser une rivière existante (on rejoint)
		if img.get_pixel(x, y) != Color.hex(0x00000000):
			break
		
		img.set_pixel(x, y, river_color)
		
		var current_elev = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
		
		if current_elev < last_elevation:
			steps_since_descent = 0
		else:
			steps_since_descent += 1
		last_elevation = current_elev
		
		if steps_since_descent > 20:
			break
		
		# Chercher la direction de descente
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
			
			# Rejoindre une rivière existante = bonus énorme
			if img.get_pixel(nx, ny) != Color.hex(0x00000000):
				best_dir = dir
				best_score = 99999
				break
			
			if self.water_map.get_pixel(nx, ny) == Color.hex(0xFFFFFFFF):
				best_dir = dir
				best_score = 99999
				break
			
			var elev = Enum.getElevationViaColor(self.elevation_map.get_pixel(nx, ny))
			var descent = current_elev - elev
			
			if descent >= -10:  # Tolérance limitée pour affluents
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


func get_river_color_by_size(size: int) -> Color:
	# Retourne la couleur selon la taille et le type de planète
	match self.atmosphere_type:
		1:  # Toxique
			match size:
				0: return Color.hex(0x7ADB79FF)  # Affluent toxique
				1: return Color.hex(0x5BC45AFF)  # Rivière acide
				2: return Color.hex(0x48B847FF)  # Fleuve toxique
		2:  # Volcanique
			match size:
				0: return Color.hex(0xFF8533FF)  # Affluent de lave
				1: return Color.hex(0xFF6B1AFF)  # Rivière de lave
				2: return Color.hex(0xE85A0FFF)  # Fleuve de magma
		4:  # Mort
			match size:
				0: return Color.hex(0x6A8A6BFF)  # Affluent pollué
				1: return Color.hex(0x5A7A5BFF)  # Rivière stagnante
				2: return Color.hex(0x4A6A4BFF)  # Fleuve pollué
		_:  # Défaut (0)
			match size:
				0: return Color.hex(0x6BAAE5FF)  # Affluent
				1: return Color.hex(0x4A90D9FF)  # Rivière
				2: return Color.hex(0x3E7FC4FF)  # Fleuve
	return Color.hex(0x4A90D9FF)


func get_lake_color(temp: float) -> Color:
	# Retourne la couleur du lac selon la température et le type de planète
	match self.atmosphere_type:
		1:  # Toxique
			if temp < 0:
				return Color.hex(0xB8E6B7FF)  # Lac toxique gelé
			return Color.hex(0x6ED96DFF)  # Lac d'acide
		2:  # Volcanique
			return Color.hex(0xFF9944FF)  # Lac de lave
		4:  # Mort
			return Color.hex(0x6B8B6CFF)  # Lac irradié
		_:  # Défaut
			if temp < 0:
				return Color.hex(0xA8D4E6FF)  # Lac gelé
			return Color.hex(0x5BA3E0FF)  # Lac d'eau douce


func generate_lakes(img: Image, lake_noise: FastNoiseLite, height: int) -> void:
	# Générer des lacs dans les zones appropriées
	# Les lacs ne montent pas - ils restent à leur altitude initiale
	
	var lake_candidates : Array = []
	
	for x in range(0, self.circonference):
		for y in range(0, height):
			# Ignorer si déjà une rivière
			if img.get_pixel(x, y) != Color.hex(0x00000000):
				continue
			
			# Ignorer l'eau (océan)
			if self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
				continue
			
			# Vérifier les précipitations
			var precipitation = self.precipitation_map.get_pixel(x, y).r
			if precipitation < 0.4:
				continue
			
			# Vérifier la température
			var temp = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
			
			var coords = get_cylindrical_coords(x, y)
			var lake_val = lake_noise.get_noise_3d(coords.x, coords.y, coords.z)
			lake_val = 1.0 - abs(lake_val)
			
			if lake_val > 0.78:
				var elevation = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
				lake_candidates.append({"x": x, "y": y, "elevation": elevation, "temp": temp})
	
	# Pour chaque lac potentiel, vérifier qu'il ne "monte" pas
	# Un lac ne peut s'étendre que sur des pixels de même altitude ou plus bas
	for candidate in lake_candidates:
		var start_elev = candidate.elevation
		
		# Vérifier les voisins - un lac est valide si entouré de terrain >= son altitude
		var is_valid_lake = true
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx = wrap_x(candidate.x + dx)
				var ny = candidate.y + dy
				if ny < 0 or ny >= height:
					continue
				
				# Si un voisin terrestre est plus bas, l'eau coulerait (pas un lac stable)
				if self.water_map.get_pixel(nx, ny) != Color.hex(0xFFFFFFFF):
					var neighbor_elev = Enum.getElevationViaColor(self.elevation_map.get_pixel(nx, ny))
					if neighbor_elev < start_elev - 50:  # Tolérance de 50m
						is_valid_lake = false
						break
			if not is_valid_lake:
				break
		
		if is_valid_lake:
			img.set_pixel(candidate.x, candidate.y, get_lake_color(candidate.temp))


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
	
	# Bruit pour variations régionales
	var climate_zone = noise.get_noise_3d(coords.x, coords.y, coords.z)
	
	# =========================================================================
	# MODÈLE DE TEMPÉRATURE BASÉ SUR LES DONNÉES TERRESTRES
	# Ajusté pour éviter un froid excessif aux latitudes moyennes
	# =========================================================================
	
	# Décalages par rapport à la moyenne planétaire
	var equator_offset = 8.0    # Équateur: avg + 8°C
	var pole_offset = 35.0      # Pôles: avg - 35°C (réduit de 45)
	
	# Courbe avec transition plus douce - le froid intense n'arrive qu'aux vrais pôles
	# pow(lat, 1.5) fait que le froid s'accentue surtout près des pôles
	var lat_curve = pow(lat_normalized, 1.5)
	
	# Température de base: équateur chaud, pôles froids
	var base_temp = self.avg_temperature + equator_offset * (1.0 - lat_normalized) - pole_offset * lat_curve
	
	# Variations longitudinales (±8°C - continentalité, courants océaniques)
	var longitudinal_variation = climate_zone * 8.0
	
	# Variations secondaires (±5°C - masses d'air)
	var secondary_variation = noise2.get_noise_3d(coords.x, coords.y, coords.z) * 5.0
	
	# Microclimats locaux (±3°C)
	var local_variation = noise3.get_noise_3d(coords.x, coords.y, coords.z) * 3.0
	
	# =========================================================================
	# EFFET DE L'ALTITUDE (-6.5°C / 1000m - gradient adiabatique)
	# Ne s'applique PAS sur l'eau (océan/banquise)
	# =========================================================================
	var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var is_water = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	var altitude_temp = 0.0
	
	# L'altitude n'affecte que les terres émergées
	if not is_water:
		var altitude_above_sea = max(0.0, elevation_val - self.water_elevation)
		altitude_temp = -6.5 * (altitude_above_sea / 1000.0)
		
		# Inversion thermique sous le niveau de la mer (terres sous niveau marin)
		if elevation_val < self.water_elevation:
			var depth_below_sea = self.water_elevation - elevation_val
			altitude_temp = 2.0 * (depth_below_sea / 1000.0)
	
	var temp = base_temp + longitudinal_variation + secondary_variation + local_variation + altitude_temp
	
	# =========================================================================
	# EFFET MODÉRATEUR DES OCÉANS (inertie thermique de l'eau)
	# Les océans modèrent les températures extrêmes
	# =========================================================================
	if is_water:
		temp = temp * 0.8 + self.avg_temperature * 0.2
	
	temp = clamp(temp, -80.0, 60.0)  # Limites terrestres réalistes
	var color = Enum.getTemperatureColor(temp)
	img.set_pixel(x, y, color)


func generate_biome_map() -> void:
	var img = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)
	
	# Bruit principal pour sélectionner parmi les biomes valides de façon cohérente spatialement
	var biome_noise = FastNoiseLite.new()
	biome_noise.seed = randi()
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	biome_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	biome_noise.frequency = 4.0 / float(self.circonference)  # Grande échelle pour zones homogènes
	biome_noise.fractal_octaves = 3
	biome_noise.fractal_gain = 0.4
	biome_noise.fractal_lacunarity = 2.0
	
	# Bruit de détail pour ajouter de l'irrégularité aux bordures
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = randi()
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.frequency = 25.0 / float(self.circonference)  # Échelle moyenne pour détails
	detail_noise.fractal_octaves = 4
	detail_noise.fractal_gain = 0.5
	detail_noise.fractal_lacunarity = 2.0
	
	var width = self.circonference
	var height = int(self.circonference / 2)
	
	# Première passe : génération initiale des biomes
	for x in range(width):
		for y in range(height):
			biome_calcul_initial(img, biome_noise, x, y)
	
	# Deuxième passe : lissage pour homogénéiser
	smooth_biome_map(img, width, height)
	
	# Troisième passe : ajouter de l'irrégularité aux bordures
	add_border_irregularity(img, detail_noise, width, height)
	
	# Appliquer les couleurs finales
	for x in range(width):
		for y in range(height):
			apply_final_colors(img, x, y)

	self.addProgress(25)
	self.biome_map = img

func biome_calcul_initial(img: Image, noise: FastNoiseLite, x: int, y: int) -> void:
	var elevation_val     = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
	var precipitation_val = self.precipitation_map.get_pixel(x, y).r
	var temperature_val   = Enum.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
	var is_water          = self.water_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF)
	var is_river          = self.river_map.get_pixel(x, y) != Color.hex(0x00000000)

	var biome
	if self.banquise_map.get_pixel(x, y) == Color.hex(0xFFFFFFFF):
		biome = Enum.getBanquiseBiome(self.atmosphere_type)
	elif is_river:
		biome = Enum.getRiverBiome(temperature_val, precipitation_val, self.atmosphere_type)
	else:
		# Utiliser le bruit pour choisir de façon déterministe parmi les biomes valides
		var noise_val = (noise.get_noise_2d(float(x), float(y)) + 1.0) / 2.0  # 0 à 1
		biome = Enum.getBiomeByNoise(self.atmosphere_type, elevation_val, precipitation_val, temperature_val, is_water, noise_val)

	img.set_pixel(x, y, biome.get_couleur())

func smooth_biome_map(img: Image, width: int, height: int) -> void:
	# Créer une copie pour lire pendant qu'on écrit
	var temp_img = img.duplicate()
	
	# Nombre de passes de lissage
	for _pass in range(2):
		for x in range(width):
			for y in range(height):
				var current_color = temp_img.get_pixel(x, y)
				var current_biome = Enum.getBiomeByColor(current_color)
				
				# Ne pas lisser les biomes spéciaux (banquise, rivières)
				if current_biome != null and (current_biome.get_river_lake_only() or current_biome.get_nom() == "Banquise" or current_biome.get_nom().begins_with("Banquise")):
					continue
				
				# Compter les voisins
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
				
				# Trouver le biome voisin le plus fréquent
				var max_count = 0
				var best_color = current_color
				for color_key in neighbor_counts:
					if neighbor_counts[color_key] > max_count:
						max_count = neighbor_counts[color_key]
						best_color = Color.html(color_key)
				
				# Si >= 5 voisins ont le même biome, adopter ce biome
				if max_count >= 5:
					var best_biome = Enum.getBiomeByColor(best_color)
					# Vérifier que le biome est compatible avec les conditions locales
					if best_biome != null and not best_biome.get_river_lake_only():
						img.set_pixel(x, y, best_color)
		
		# Mettre à jour temp_img pour la prochaine passe
		temp_img = img.duplicate()

func add_border_irregularity(img: Image, noise: FastNoiseLite, width: int, height: int) -> void:
	# Ajoute de l'irrégularité aux bordures entre biomes
	var temp_img = img.duplicate()
	
	for x in range(width):
		for y in range(height):
			var current_color = temp_img.get_pixel(x, y)
			var current_biome = Enum.getBiomeByColor(current_color)
			
			# Ne pas modifier les biomes spéciaux
			if current_biome != null and (current_biome.get_river_lake_only() or current_biome.get_nom().begins_with("Banquise")):
				continue
			
			# Vérifier si on est près d'une bordure (voisins différents)
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
			
			# Si on est sur une bordure, utiliser le bruit pour décider si on change
			if is_border and neighbor_biomes.size() > 0:
				var noise_val = noise.get_noise_2d(float(x), float(y))
				# 15% de chance de changer vers un biome voisin basé sur le bruit
				if noise_val > 0.4:
					# Choisir un biome voisin basé sur le bruit
					var index = int((noise_val + 1.0) / 2.0 * neighbor_biomes.size()) % neighbor_biomes.size()
					img.set_pixel(x, y, neighbor_biomes[index])

func apply_final_colors(img: Image, x: int, y: int) -> void:
	var biome_color = img.get_pixel(x, y)
	var biome = Enum.getBiomeByColor(biome_color)
	
	if biome != null:
		var biome_nom = biome.get_nom()
		var is_banquise = biome_nom.begins_with("Banquise") or biome_nom.find("Refroidis") != -1
		
		var color_final : Color
		if is_banquise:
			# Banquise uniquement : pas d'effet d'élévation
			color_final = biome.get_couleur_vegetation()
		else:
			# Tout le reste (océans, terres) : appliquer l'élévation
			var elevation_val = Enum.getElevationViaColor(self.elevation_map.get_pixel(x, y))
			var elevation_color = Enum.getElevationColor(elevation_val, true)
			color_final = elevation_color * biome.get_couleur_vegetation()
		
		color_final.a = 1.0
		self.final_map.set_pixel(x, y, color_final)

func biome_calcul(_img: Image, _noise, _generator, _x : int, _y : int) -> void:
	# Fonction obsolète, gardée pour compatibilité
	pass

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
		save_image(self.river_map,"river_map.png"),
		save_image(self.biome_map,"biome_map.png"),
		save_image(self.final_map,"final_map.png"),
		save_image(self.region_map,"region_map.png"),
		save_image(self.preview,"preview.png")
	]

func is_ready() -> bool:
	return self.elevation_map != null and self.precipitation_map != null and self.temperature_map != null and self.water_map != null and self.river_map != null and self.biome_map != null and self.final_map != null and self.region_map != null and self.nuage_map != null and self.oil_map != null and self.banquise_map != null and self.preview != null

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
