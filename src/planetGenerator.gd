extends RefCounted

class_name PlanetGenerator

signal finished

# Propriétés de la planète
var nom: String
var circonference: int
var renderProgress: ProgressBar
var cheminSauvegarde: String

# Paramètres de génération
var avg_temperature: float
var water_elevation: int
var avg_precipitation: float
var elevation_modifier: int
var nb_thread: int
var atmosphere_type: int
var nb_avg_cases: int

# Images générées
var elevation_map: Image
var elevation_map_alt: Image
var precipitation_map: Image
var temperature_map: Image
var region_map: Image
var water_map: Image
var banquise_map: Image
var biome_map: Image
var oil_map: Image
var ressource_map: Image
var nuage_map: Image
var river_map: Image
var final_map: Image
var preview: Image

# Constantes pour la conversion cylindrique
var cylinder_radius: float

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5, elevation_modifier_param: int = 0, nb_thread_param: int = 8, atmosphere_type_param: int = 0, renderProgress_param: ProgressBar = null, nb_avg_cases_param: int = 50, cheminSauvegarde_param: String = "user://temp/") -> void:
	self.nom = nom_param
	self.circonference = int(rayon * 2 * PI)
	self.renderProgress = renderProgress_param
	self.renderProgress.value = 0.0
	self.cheminSauvegarde = cheminSauvegarde_param
	self.nb_avg_cases = nb_avg_cases_param

	self.avg_temperature = avg_temperature_param
	self.water_elevation = water_elevation_param
	self.avg_precipitation = avg_precipitation_param
	self.elevation_modifier = elevation_modifier_param
	self.nb_thread = nb_thread_param
	self.atmosphere_type = atmosphere_type_param
	
	self.cylinder_radius = self.circonference / (2.0 * PI)

func generate_planet():
	print("\n=== Début de la génération de la planète ===\n")
	
	# 1. Carte finale (image vide pour commencer)
	print("1/12 - Génération de la carte finale...")
	self.final_map = Image.create(self.circonference, self.circonference / 2, false, Image.FORMAT_RGBA8)
	addProgress(10)
	
	# 2. Carte des nuages
	print("2/12 - Génération de la carte des nuages...")
	var nuage_gen = NuageMapGenerator.new(self)
	self.nuage_map = nuage_gen.generate()
	addProgress(5)
	
	# 3. Carte topographique
	print("3/12 - Génération de la carte topographique...")
	var elevation_gen = ElevationMapGenerator.new(self)
	self.elevation_map = elevation_gen.generate()
	self.elevation_map_alt = elevation_gen.get_elevation_map_alt()
	addProgress(10)
	
	# 4. Carte des précipitations
	print("4/12 - Génération de la carte des précipitations...")
	var precipitation_gen = PrecipitationMapGenerator.new(self)
	self.precipitation_map = precipitation_gen.generate()
	addProgress(10)
	
	# 5. Carte des mers
	print("5/12 - Génération de la carte des mers...")
	var water_gen = WaterMapGenerator.new(self)
	self.water_map = water_gen.generate()
	addProgress(10)
	
	# 6. Carte du pétrole
	print("6/12 - Génération de la carte du pétrole...")
	var oil_gen = OilMapGenerator.new(self)
	self.oil_map = oil_gen.generate()
	addProgress(5)
	
	# 7. Carte des ressources
	print("7/12 - Génération de la carte des ressources...")
	var ressource_gen = RessourceMapGenerator.new(self)
	self.ressource_map = ressource_gen.generate()
	addProgress(5)
	
	# 8. Carte des températures
	print("8/12 - Génération de la carte des températures...")
	var temperature_gen = TemperatureMapGenerator.new(self)
	self.temperature_map = temperature_gen.generate()
	addProgress(10)
	
	# 9. Carte des rivières/lacs
	print("9/12 - Génération de la carte des rivières/lacs...")
	var river_gen = RiverMapGenerator.new(self)
	self.river_map = river_gen.generate()
	addProgress(5)
	
	# 10. Carte de la banquise
	print("10/12 - Génération de la carte de la banquise...")
	var banquise_gen = BanquiseMapGenerator.new(self)
	self.banquise_map = banquise_gen.generate()
	addProgress(5)
	
	# 11. Carte des régions
	print("11/12 - Génération de la carte des régions...")
	var region_gen = RegionMapGenerator.new(self)
	self.region_map = region_gen.generate()
	addProgress(10)
	
	# 12. Carte des biomes
	print("12/12 - Génération de la carte des biomes...")
	var biome_gen = BiomeMapGenerator.new(self)
	self.biome_map = biome_gen.generate()
	addProgress(25)
	
	# Génération de la prévisualisation
	print("\nGénération de la prévisualisation...")
	generate_preview()

	print("\n===================")
	print("Génération Terminée")
	print("===================\n")
	emit_signal("finished")

func generate_preview() -> void:
	self.preview = Image.create(self.circonference / 2, self.circonference / 2, false, Image.FORMAT_RGBA8)

	var radius = self.circonference / 4
	var center = Vector2(self.circonference / 4, self.circonference / 4)

	for x in range(self.preview.get_width()):
		for y in range(self.preview.get_height()):
			var pos = Vector2(x, y)
			if pos.distance_to(center) <= radius:
				var base_color = self.final_map.get_pixel(x, y)
				if self.nuage_map.get_pixel(x, y) != Color.hex(0x00000000):
					var cloud_alpha = 0.7
					var cloud_color = Color(1.0, 1.0, 1.0, cloud_alpha)
					var blended = base_color.lerp(cloud_color, cloud_alpha)
					blended.a = 1.0
					self.preview.set_pixel(x, y, blended)
				else:
					self.preview.set_pixel(x, y, base_color)
			else:
				self.preview.set_pixel(x, y, Color.TRANSPARENT)

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

func getMaps() -> Array[String]:
	deleteImagesTemps()

	return [
		save_image(self.elevation_map, "elevation_map.png"),
		save_image(self.elevation_map_alt, "elevation_map_alt.png"),
		save_image(self.nuage_map, "nuage_map.png"),
		save_image(self.oil_map, "oil_map.png"),
		save_image(self.ressource_map, "ressource_map.png"),
		save_image(self.precipitation_map, "precipitation_map.png"),
		save_image(self.temperature_map, "temperature_map.png"),
		save_image(self.water_map, "water_map.png"),
		save_image(self.river_map, "river_map.png"),
		save_image(self.biome_map, "biome_map.png"),
		save_image(self.final_map, "final_map.png"),
		save_image(self.region_map, "region_map.png"),
		save_image(self.preview, "preview.png")
	]

func is_ready() -> bool:
	return self.elevation_map != null and self.precipitation_map != null and self.temperature_map != null and self.water_map != null and self.river_map != null and self.biome_map != null and self.final_map != null and self.region_map != null and self.nuage_map != null and self.oil_map != null and self.banquise_map != null and self.preview != null

func addProgress(value) -> void:
	if self.renderProgress != null:
		self.renderProgress.call_deferred("set_value", self.renderProgress.value + value)

static func save_image(image: Image, file_name: String, file_path = null) -> String:
	if file_path == null:
		var img_path = "user://temp/" + file_name
		if DirAccess.open("user://temp/") == null:
			DirAccess.make_dir_absolute("user://temp/")

		image.save_png(img_path)
		print("Saved: ", img_path)
		return img_path
		
	if not file_path.ends_with("/"):
		file_path += "/"
	
	var dir = DirAccess.open(file_path)
	if dir == null:
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
