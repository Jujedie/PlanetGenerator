extends Node

const ALTITUDE_MAX = 25000

# Définir des couleurs réaliste pour le rendu final et des couleurs distinctes
var BIOMES = [
	Biome.new("Banquise", Color.hex(0xbfbebbFF), Color.hex(0xf0f0f0FF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Rivière/Cours d’eau", Color.hex(0x5b98e3FF), Color.hex(0x4a688aFF), [0, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Océan", Color.hex(0x25528aFF), Color.hex(0x486385FF), [-21, 90], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Lac/Étang", Color.hex(0x4584d2FF), Color.hex(0x455f80FF), [0, 30], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Zone côtière (littorale)", Color.hex(0x2860a5FF), Color.hex(0x425b7aFF), [0, 30], [0.0, 1.0], [-1000, 0], true),

	Biome.new("Zone humide (marais/marécage)", Color.hex(0x389bbaFF), Color.hex(0x568472FF), [5, 30], [0.75, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Récif corallien", Color.hex(0x4f8a91FF), Color.hex(0x3f5875FF), [20, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Lagune salée", Color.hex(0x3a666bFF), Color.hex(0x517b6bFF), [10, 60], [0.0, 1.0], [-10, 500], true),
	Biome.new("Cheminée hydrothermale", Color.hex(0x264e8dFF), Color.hex(0x364b63FF), [2, 500], [0.0,1.0],[-ALTITUDE_MAX, -1000], true),

	Biome.new("Désert cryogénique mort", Color.hex(0xdddfe3FF), Color.hex(0x111111FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Glacier", Color.hex(0xc7cdd6FF), Color.hex(0xe6e6e6FF), [-150, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert artique", Color.hex(0xabb2beFF), Color.hex(0xebebebFF), [-150, -50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Calotte glaciaire polaire", Color.hex(0x949ca9FF), Color.hex(0xe0e0e0FF), [-100, -50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Toundra", Color.hex(0xcbb15fFF), Color.hex(0xb4894eFF), [-50, 15], [0.0, 1.0], [-ALTITUDE_MAX, 750], false),
	Biome.new("Toundra alpine", Color.hex(0xb79e50FF), Color.hex(0xaf854bFF), [-50, 15], [0.0, 1.0], [750, ALTITUDE_MAX], false),
	Biome.new("Taïga (forêt boréale)", Color.hex(0x476b3eFF), Color.hex(0x394f36FF), [-10, 20], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt de montagne", Color.hex(0x4f8a40FF), Color.hex(0x3a5637FF), [-5, 20], [0.4, 1.0], [400, ALTITUDE_MAX], false),
	
	Biome.new("Forêt tempérée", Color.hex(0x65c44eFF), Color.hex(0x3b6336FF), [0, 25], [0.4, 1.0], [-ALTITUDE_MAX, 400], false),
	Biome.new("Prairie", Color.hex(0x8fe07cFF), Color.hex(0x425a3fFF), [0, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Méditerranée", Color.hex(0x7c61cbFF), Color.hex(0x536b4fFF), [15, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),	
	Biome.new("Steppes sèches", Color.hex(0x9f9075FF), Color.hex(0xccaa62FF), [-5, 30], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Steppes tempérées", Color.hex(0x83765fFF), Color.hex(0xc7a65fFF), [-5, 25], [0.36, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt tropicale", Color.hex(0x1b5a21FF), Color.hex(0x2d4929FF), [25, 35], [0.75, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane", Color.hex(0xa27442FF), Color.hex(0xccbf62FF), [20, 35], [0.0, 0.45], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane d'arbres", Color.hex(0x946b3eFF), Color.hex(0xc8bb56FF), [20, 35], [0.15, 0.6], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert semi-aride", Color.hex(0xbe9e5cFF), Color.hex(0xbda367FF), [25, 50], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert", Color.hex(0x945724FF), Color.hex(0xb89e63FF), [30, 60], [0.0, 0.2], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert aride", Color.hex(0x83492bFF), Color.hex(0xb39a60FF), [20, 70], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert mort", Color.hex(0x6e3825FF), Color.hex(0xaf965aFF), [450, 500], [0.0, 1.0], [-2500, 2500], false)
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

var COULEURS_TEMPERATURE = {
	-200: Color.hex(0x4A0070FF),
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
	100: Color.hex(0x6e1408FF)
}

func getElevationColor(elevation: int) -> Color:
	for key in COULEURS_ELEVATIONS.keys():
		if elevation <= key:
			return COULEURS_ELEVATIONS[key]
	return COULEURS_ELEVATIONS[ALTITUDE_MAX]

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

func getBiome(elevation_val : int, precipitation_val : float, temperature_val : int, is_water : bool, img_biome: Image, x:int, y:int) -> Biome:
	var corresponding_biome : Array[Biome] = []

	for biome in BIOMES:
		if (elevation_val >= biome.get_interval_elevation()[0] and
			elevation_val <= biome.get_interval_elevation()[1] and
			temperature_val >= biome.get_interval_temp()[0] and
			temperature_val <= biome.get_interval_temp()[1] and
			precipitation_val >= biome.get_interval_precipitation()[0] and
			precipitation_val <= biome.get_interval_precipitation()[1] and
			is_water == biome.get_water_need()):
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
