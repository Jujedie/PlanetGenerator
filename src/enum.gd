extends Node

const ALTITUDE_MAX = 25000

# Définir des couleurs réaliste pour le rendu final et des couleurs distinctes
var BIOMES = [
	# Biomes Défauts

	#	Biomes aquatiques
	Biome.new("Banquise", Color.hex(0xbfbebbFF), Color.hex(0xe8e8e8FF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Océan", Color.hex(0x25528aFF), Color.hex(0x466181FF), [-21, 100], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Lac", Color.hex(0x4584d2FF), Color.hex(0x3d5571FF), [0, 100], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Zone côtière (littorale)", Color.hex(0x2860a5FF), Color.hex(0x445f7eFF), [0, 100], [0.0, 1.0], [-1000, 0], true),

	Biome.new("Zone humide (marais/marécage)", Color.hex(0x389bbaFF), Color.hex(0x3e5774FF), [5, 100], [0.0, 1.0], [-20, 20], true),
	Biome.new("Récif corallien", Color.hex(0x4f8a91FF), Color.hex(0x405a77FF), [20, 35], [0.0, 1.0], [-500, 0], true),
	Biome.new("Lagune salée", Color.hex(0x3a666bFF), Color.hex(0x405a77FF), [10, 100], [0.0, 1.0], [-10, 500], true),

	#	Biomes terrestres
	Biome.new("Désert cryogénique mort", Color.hex(0xdddfe3FF), Color.hex(0xd9d9d9FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Glacier", Color.hex(0xc7cdd6FF), Color.hex(0xe3e3e3FF), [-150, -10], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert artique", Color.hex(0xabb2beFF), Color.hex(0xebebebFF), [-150, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Calotte glaciaire polaire", Color.hex(0x949ca9FF), Color.hex(0xdededeFF), [-100, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Toundra", Color.hex(0xcbb15fFF), Color.hex(0xbaa269FF), [-20, 4], [0.0, 1.0], [-ALTITUDE_MAX, 300], false),
	Biome.new("Toundra alpine", Color.hex(0xb79e50FF), Color.hex(0xbca46cFF), [-20, 4], [0.0, 1.0], [300, ALTITUDE_MAX], false),
	Biome.new("Taïga (forêt boréale)", Color.hex(0x476b3eFF), Color.hex(0x3a4d38FF), [0, 10], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt de montagne", Color.hex(0x4f8a40FF), Color.hex(0x3f533cFF), [-15, 20], [0.0, 1.0], [300, ALTITUDE_MAX], false),
	
	Biome.new("Forêt tempérée", Color.hex(0x65c44eFF), Color.hex(0x435940FF), [5, 25], [0., 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Prairie", Color.hex(0x8fe07cFF), Color.hex(0x485f45FF), [5, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Méditerranée", Color.hex(0x4a6247FF), Color.hex(0x536b4fFF), [15, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),	
	Biome.new("Steppes sèches", Color.hex(0x9f9075FF), Color.hex(0xb89f65FF), [26, 40], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Steppes tempérées", Color.hex(0x83765fFF), Color.hex(0x596349FF), [5, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt tropicale", Color.hex(0x1b5a21FF), Color.hex(0x485f45FF), [15, 25], [0.5, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane", Color.hex(0xa27442FF), Color.hex(0xb89f65FF), [20, 35], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane d'arbres", Color.hex(0x946b3eFF), Color.hex(0xbca46cFF), [20, 25], [0.36, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert semi-aride", Color.hex(0xbe9e5cFF), Color.hex(0xbca46cFF), [26, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert", Color.hex(0x945724FF), Color.hex(0xbaa269FF), [35, 60], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert aride", Color.hex(0x83492bFF), Color.hex(0xb89f65FF), [35, 70], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert mort", Color.hex(0x6e3825FF), Color.hex(0xab986dFF), [70, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),


	# Biomes Toxique

	#	Biomes aquatiques
	Biome.new("Banquise toxique", Color.hex(0x48d63bFF), Color.hex(0xb0beabFF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [1]),
	Biome.new("Océan toxique", Color.hex(0x329b837FF), Color.hex(0x3b6e61FF), [-21, 100], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [1]),
	Biome.new("Marécages acides", Color.hex(0x359b3aFF), Color.hex(0x356458FF), [5, 100], [0.0, 1.0], [-20, ALTITUDE_MAX], true, [1]),

	#	Biomes terrestres
	Biome.new("Déserts de soufre", Color.hex(0x788d29FF), Color.hex(0x848d63FF), [-273, 50], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),
	Biome.new("Glaciers toxiques", Color.hex(0xadcb45FF), Color.hex(0xc3cba8FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),
	Biome.new("Toundra toxique", Color.hex(0x83944bFF), Color.hex(0x8e986eFF), [-150, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),
	Biome.new("Forêts fongiques extrêmes", Color.hex(0x317536FF), Color.hex(0x59755bFF), [0, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),
	Biome.new("Plaines toxiques", Color.hex(0x378d3eFF), Color.hex(0x678a6aFF), [5, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),
	Biome.new("Solfatares", Color.hex(0x3d7542FF), Color.hex(0x606e61FF), [36, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [1]),


	# Biomes Volcaniques

	#	Biomes aquatiques
	Biome.new("Champs de Lave Refroidis", Color.hex(0xb76b0eFF), Color.hex(0x3b312bFF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [2]),
	Biome.new("Champs de lave", Color.hex(0xd69617FF), Color.hex(0xc44217FF), [-21, 100], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [2]),
	Biome.new("Lacs de magma", Color.hex(0xb7490eFF), Color.hex(0xb3370eFF), [0, 100], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2]),

	#	Biomes terrestres
	Biome.new("Déserts de cendres", Color.hex(0xdd7d13FF), Color.hex(0x4c3229FF), [-273, 50], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Plaines de roches", Color.hex(0xcf7410FF), Color.hex(0x4c413eFF), [-273, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Montagnes volcaniques", Color.hex(0x9b6326FF), Color.hex(0x3b3533FF), [-20, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Plaines volcaniques", Color.hex(0x98540aFF), Color.hex(0x534a47FF), [5, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Terrasses minérales", Color.hex(0x945511FF), Color.hex(0x413a38FF), [20, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Volcans actifs", Color.hex(0x5d4428FF), Color.hex(0x642d1aFF), [45, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),
	Biome.new("Fumerolles et sources chaudes", Color.hex(0x483825FF), Color.hex(0x2d2b2aFF), [70, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [2]),


	# Biomes Morts

	#	Biomes aquatiques
	Biome.new("Banquise morte", Color.hex(0xd9d1ccFF), Color.hex(0xcbc8c5FF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [3]),
	Biome.new("Marécages luminescents", Color.hex(0x619f63FF), Color.hex(0x4c6e4dFF), [0, 100], [0.0, 1.0], [-100, ALTITUDE_MAX], true, [4]),
	Biome.new("Océan mort", Color.hex(0x49794aFF), Color.hex(0x374f38FF), [-21, 100], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [4]),

	#	Biomes terrestres
	Biome.new("Désert de sel", Color.hex(0xd9cba0FF), Color.hex(0xc4b893FF), [-273, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),
	Biome.new("Plaines de cendres", Color.hex(0x292826FF), Color.hex(0x53504bFF), [0, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),
	Biome.new("Cratères nucléaires", Color.hex(0x343331FF), Color.hex(0x484641FF), [5, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),
	Biome.new("Terres désolées", Color.hex(0x807969FF), Color.hex(0x56544fFF), [20, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),
	Biome.new("Forêts mutantes", Color.hex(0x867048FF), Color.hex(0x7c6c4dFF), [45, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),
	Biome.new("Plaines de poussière", Color.hex(0xa98c59FF), Color.hex(0x8a7650FF), [70, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [4]),


	# Biomes Sans Atmosphères

	#	Biomes terrestres 
	Biome.new("Déserts rocheux nus", Color.hex(0x75736fFF), Color.hex(0x4f4d4aFF), [-273, 200], [0.0, 0.1], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [3]),
	Biome.new("Régolithes criblés de cratères", Color.hex(0x676662FF), Color.hex(0x4a4845FF), [-273, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [3]),
	Biome.new("Fosses d’impact", Color.hex(0x5d5c59FF), Color.hex(0x474543FF), [-273, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [3])
]

# Définition des couleurs pour les élévations
var COULEURS_ELEVATIONS = {
	-ALTITUDE_MAX: Color.hex(0x2491ffbFF),
	-20000: Color.hex(0x2994ffFF),
	-8000: Color.hex(0x2e96ffFF),
	-4000: Color.hex(0x3399ffFF),
	-2000: Color.hex(0x389cffFF),
	-1500: Color.hex(0x3d9effFF),
	-1000: Color.hex(0x42a1ffFF),
	-500: Color.hex(0x4da6ffFF),
	-400: Color.hex(0x57abffFF),
	-300: Color.hex(0x61b0ffFF),
	-200: Color.hex(0x70b8ffFF),
	-100: Color.hex(0x85c2ffFF),
	-50: Color.hex(0x99ccffFF),
	-20: Color.hex(0xa8d4ffFF),

	0: Color.hex(0x526b3fFF),

	20: Color.hex(0x567042FF),
	50: Color.hex(0x597444FF),
	100: Color.hex(0x5b7746FF),
	200: Color.hex(0x5e7a48FF),
	300: Color.hex(0x62814bFF),
	400: Color.hex(0x67874fFF),
	500: Color.hex(0x6c8d53FF),
	600: Color.hex(0x808d53FF),
	700: Color.hex(0x889155FF),
	800: Color.hex(0x919457FF),
	900: Color.hex(0x96995aFF),
	1000: Color.hex(0x9b9e5dFF),
	1500: Color.hex(0xa19e5fFF),
	2000: Color.hex(0xa3a160FF),
	4000: Color.hex(0x9e995dFF),
	8000: Color.hex(0x99945aFF),
	12000: Color.hex(0x948f57FF),
	16000: Color.hex(0x8f8a54FF),
	20000: Color.hex(0x8a8551FF),
	24000: Color.hex(0x85804eFF),
	ALTITUDE_MAX: Color.hex(0x7d794aFF) 
}

var COULEURS_ELEVATIONS_GREY = {
	-ALTITUDE_MAX: Color.hex(0x353535FF),
	-20000: Color.hex(0x3c3c3cFF),
	-8000: Color.hex(0x434343FF),
	-4000: Color.hex(0x4a4a4aFF),
	-2000: Color.hex(0x515151FF),
	-1500: Color.hex(0x5a5a5aFF),
	-1000: Color.hex(0x636363FF),
	-500: Color.hex(0x6c6c6cFF),
	-400: Color.hex(0x757575FF),
	-300: Color.hex(0x7e7e7eFF),
	-200: Color.hex(0x878787FF),
	-100: Color.hex(0x909090FF),
	-50: Color.hex(0x999999FF),
	-20: Color.hex(0xa2a2a2FF),

	0: Color.hex(0xabababFF),

	20: Color.hex(0xb4b4b4FF),
	50: Color.hex(0xbdbdbdFF),
	100: Color.hex(0xc6c6c6FF),
	200: Color.hex(0xcdcdcdFF),
	300: Color.hex(0xd4d4d4FF),
	400: Color.hex(0xdbdbdbFF),
	500: Color.hex(0xe2e2e2FF),
	600: Color.hex(0xe9e9e9FF),
	700: Color.hex(0xf0f0f0FF),
	800: Color.hex(0xf5f5f5FF),
	900: Color.hex(0xf8f8f8FF),
	1000: Color.hex(0xfafafaFF),
	1500: Color.hex(0xfcfcfcFF),
	2000: Color.hex(0xfdfdfdFF),
	4000: Color.hex(0xfefefeFF),
	8000: Color.hex(0xffffffFF),
	12000: Color.hex(0xffffffFF),
	16000: Color.hex(0xffffffFF),
	20000: Color.hex(0xffffffFF),
	24000: Color.hex(0xffffffFF),
	ALTITUDE_MAX: Color.hex(0xffffffFF)
}

var COULEURS_TEMPERATURE = {
	-200: Color.hex(0x478fe6FF),
	-150: Color.hex(0x4D007AFF),
	-100: Color.hex(0x4B0082FF),
	-90: Color.hex(0x560094FF),
	-80: Color.hex(0x5c009eFF),
	-70: Color.hex(0x6200a8FF),
	-60: Color.hex(0x6800b3FF),
	-50: Color.hex(0x3c00b3FF),
	-45: Color.hex(0x3f00bdFF),
	-35: Color.hex(0x4200c7FF),
	-25: Color.hex(0x4600d1FF),
	-20: Color.hex(0x4900dbFF),
	-15: Color.hex(0x3c467bFF),
	-10: Color.hex(0x47518dFF),
	-5: Color.hex(0x4a58a3FF),

	0: Color.hex(0x4e5cb0FF),

	5: Color.hex(0x267228FF),
	10: Color.hex(0x267728FF),
	15: Color.hex(0x278029FF),
	20: Color.hex(0x268428FF),
	25: Color.hex(0xdac00fFF),
	30: Color.hex(0xd4b90fFF),
	35: Color.hex(0xda820fFF),
	40: Color.hex(0xd27d0fFF),
	45: Color.hex(0xc8780eFF),
	50: Color.hex(0xc8240eFF),
	60: Color.hex(0xbf220dFF),
	70: Color.hex(0xb5200dFF),
	80: Color.hex(0xac1f0cFF),
	90: Color.hex(0xa21d0bFF),
	100: Color.hex(0x6e1408FF),
	150: Color.hex(0xb41861FF),
	200: Color.hex(0xba172bFF)
}

var COULEUR_PRECIPITATION = {
	0.0: Color.hex(0xb118b4FF),
	0.1: Color.hex(0x8d1490FF),
	0.2: Color.hex(0x6c16a2FF),
	0.3: Color.hex(0x4a18afFF),
	0.4: Color.hex(0x2c1bc5FF),
	0.5: Color.hex(0x1d33d3FF),
	0.7: Color.hex(0x1f4fe0FF),
	1.0: Color.hex(0x3583e3FF)
}

func getElevationColor(elevation: int, grey_version : bool = false) -> Color:
	if not grey_version:
		for key in COULEURS_ELEVATIONS.keys():
			if elevation <= key:
				return COULEURS_ELEVATIONS[key]
		return COULEURS_ELEVATIONS[ALTITUDE_MAX]
	else:
		for key in COULEURS_ELEVATIONS_GREY.keys():
			if elevation <= key:
				return COULEURS_ELEVATIONS_GREY[key]
		return COULEURS_ELEVATIONS_GREY[ALTITUDE_MAX]

func getElevationViaColor(color: Color) -> int:
	for key in COULEURS_ELEVATIONS.keys():
		if COULEURS_ELEVATIONS[key] == color:
			return key
	return 0

func getTemperatureColor(temperature: float) -> Color:
	for key in COULEURS_TEMPERATURE.keys():
		if temperature <= key:
			return COULEURS_TEMPERATURE[key]
	return COULEURS_TEMPERATURE[100]

func getTemperatureViaColor(color: Color) -> float:
	for key in COULEURS_TEMPERATURE.keys():
		if COULEURS_TEMPERATURE[key] == color:
			return key
	return 0.0

func getBiome(type_planete : int, elevation_val : int, precipitation_val : float, temperature_val : int, is_water : bool, img_biome: Image, x:int, y:int) -> Biome:
	var corresponding_biome : Array[Biome] = []

	for biome in BIOMES:
		if (elevation_val >= biome.get_interval_elevation()[0] and
			elevation_val <= biome.get_interval_elevation()[1] and
			temperature_val >= biome.get_interval_temp()[0] and
			temperature_val <= biome.get_interval_temp()[1] and
			precipitation_val >= biome.get_interval_precipitation()[0] and
			precipitation_val <= biome.get_interval_precipitation()[1] and
			is_water == biome.get_water_need() and 
			type_planete in biome.get_type_planete()):
			corresponding_biome.append(biome)
		
	var taille = corresponding_biome.size()
	
	var most_common_biome = getMostCommonSurroundingBiome(getSuroundingBiomes(img_biome, x, y))

	randomize()
	var chance = randf()
	
	if most_common_biome in corresponding_biome:
		if chance <= 0.5:
			return most_common_biome
	if taille > 0 :
		return corresponding_biome[randi() % taille]
	
	return Biome.new("Aucun", Color.hex(0xFF0000FF), Color.hex(0xFF0000FF), [0, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false)

func getSuroundingBiomes(img_biome: Image, x:int, y:int) -> Array:
	var surrounding_biomes = []
	
	for i in range(-1, 2):
		for j in range(-1, 2):
			if i == 0 and j == 0:
				continue
			var new_x = x + i
			var new_y = y + j
			if new_x >= 0 and new_x < img_biome.get_width() and new_y >= 0 and new_y < img_biome.get_height():
				var color = img_biome.get_pixel(new_x, new_y)
				for biome in BIOMES:
					if biome.get_couleur() == color:
						surrounding_biomes.append(biome)
						break
	
	return surrounding_biomes

func getMostCommonSurroundingBiome(biomes : Array) -> Biome:
	var biome_count = {}
	for biome in biomes:
		if biome.get_nom() in biome_count:
			biome_count[biome.get_nom()] += 1
		else:
			biome_count[biome.get_nom()] = 1
	
	var most_common_biome = ""
	var max_count = 0
	for biome_name in biome_count.keys():
		if biome_count[biome_name] > max_count:
			max_count = biome_count[biome_name]
			most_common_biome = biome_name
	
	for biome in BIOMES:
		if biome.get_nom() == most_common_biome:
			return biome
	
	return Biome.NULL

func getPrecipitationColor(precipitation: float) -> Color:
	for key in COULEUR_PRECIPITATION.keys():
		if precipitation <= key:
			return COULEUR_PRECIPITATION[key]
	return COULEUR_PRECIPITATION[1.0]

func getBanquiseBiome( typePlanete : int) -> Biome:
	for biome in BIOMES:
		if typePlanete in biome.get_type_planete():
			if biome.get_nom().find("Banquise") != -1 or biome.get_nom().find("Refroidis") != -1:
				return biome
	return Biome.NULL
