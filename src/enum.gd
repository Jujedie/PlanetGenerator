extends Node

const ALTITUDE_MAX = 2500

# Définir des couleurs réaliste pour le rendu final et des couleurs distinctes
var BIOMES = [
	Biome.new("Banquise", Color.hex(0xFF), Color.hex(0xf0f0f0FF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Rivière/Cours d’eau", Color.hex(0xFF), Color.hex(0x4a688aFF), [0, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Océan ouvert", Color.hex(0xFF), Color.hex(0x486385FF), [-2, 30], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Lac/Étang", Color.hex(0xFF), Color.hex(0x455f80FF), [0, 30], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Zone côtière (littorale)", Color.hex(0xFF), Color.hex(0x425b7aFF), [0, 30], [0.0, 1.0], [-1000, 0], true),

	Biome.new("Zone humide (marais/marécage)", Color.hex(0xFF), Color.hex(0x568472FF), [5, 30], [0.75, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Récif corallien", Color.hex(0xFF), Color.hex(0x3f5875FF), [20, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true),
	Biome.new("Lagune salée", Color.hex(0xFF), Color.hex(0x517b6bFF), [10, 60], [0.0, 1.0], [-10, 500], true),
	Biome.new("Cheminée hydrothermale", Color.hex(0xFF), Color.hex(0x364b63FF), [2, 500], [0.0,1.0],[-ALTITUDE_MAX, ALTITUDE_MAX], true),


	Biome.new("Désert cryogénique mort", Color.hex(0xFF), Color.hex(0x111111FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Glacier", Color.hex(0xFF), Color.hex(0xe6e6e6FF), [-150, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert artique", Color.hex(0xFF), Color.hex(0xebebebFF), [-150, -50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Calotte glaciaire polaire", Color.hex(0xFF), Color.hex(0xe0e0e0FF), [-100, -50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Toundra", Color.hex(0xFF), Color.hex(0xb4894eFF), [-50, 15], [0.0, 1.0], [-ALTITUDE_MAX, 750], false),
	Biome.new("Toundra alpine", Color.hex(0xFF), Color.hex(0xaf854bFF), [-50, 15], [0.0, 1.0], [750, ALTITUDE_MAX], false),
	Biome.new("Taïga (forêt boréale)", Color.hex(0xFF), Color.hex(0x394f36FF), [-10, 20], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt de montagne", Color.hex(0xFF), Color.hex(0x3a5637FF), [-5, 20], [0.4, 1.0], [400, ALTITUDE_MAX], false),
	
	Biome.new("Forêt tempérée", Color.hex(0xFF), Color.hex(0x3b6336FF), [0, 25], [0.4, 1.0], [-ALTITUDE_MAX, 400], false),
	Biome.new("Prairie", Color.hex(0xFF), Color.hex(0x41753bFF), [0, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Méditerranée", Color.hex(0xFF), Color.hex(0xFF), [15, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),	
	Biome.new("Steppes sèches", Color.hex(0xFF), Color.hex(0xccaa62FF), [-5, 30], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Steppes tempérées", Color.hex(0xFF), Color.hex(0xc7a65fFF), [-5, 25], [0.36, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt tropicale", Color.hex(0xFF), Color.hex(0x2d4929FF), [25, 35], [0.75, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane", Color.hex(0xFF), Color.hex(0xccbf62FF), [20, 35], [0.0, 0.45], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane d'arbres", Color.hex(0xFF), Color.hex(0xc8bb56FF), [20, 35], [0.15, 0.6], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert semi-aride", Color.hex(0xFF), Color.hex(0xbda367FF), [25, 50], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert", Color.hex(0xFF), Color.hex(0xb89e63FF), [30, 60], [0.0, 0.2], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert aride", Color.hex(0xFF), Color.hex(0xb39a60FF), [20, 70], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert mort", Color.hex(0xFF), Color.hex(0xaf965aFF), [450, 500], [0.0, 1.0], [-2500, 2500], false)
]



# Définition des couleurs pour les élévations
var COULEURS_ELEVATIONS = {
	-ALTITUDE_MAX: Color.hex(0x010101FF), # 2250m et moins 
	-2000: Color.hex(0x050505FF), # 2000m 
	-1500: Color.hex(0x0A0A0AFF), # 1500m 
	-1000: Color.hex(0x0F0F0FFF), # 1000m 
	-500: Color.hex(0x141414FF),  # 500m 
	-400: Color.hex(0x181818FF),  # 400m 
	-300: Color.hex(0x1C1C1CFF),  # 300m 
	-200: Color.hex(0x1E1E1EFF),  # 200m 
	-100: Color.hex(0x202020FF),  # 100m 

	0: Color.hex(0x232323FF)   , # 0m et moins

	100: Color.hex(0x282828FF) , # 100m 
	200: Color.hex(0x2E2E2EFF) , # 200m 
	300: Color.hex(0x353535FF) , # 300m 
	400: Color.hex(0x3C3C3CFF) , # 400m 
	500: Color.hex(0x434343FF) , # 500m 
	600: Color.hex(0x4A4A4AFF) , # 600m 
	700: Color.hex(0x525252FF) , # 700m 
	800: Color.hex(0x5C5C5CFF) , # 800m
	900: Color.hex(0x666666FF) , # 900m
	1000: Color.hex(0x717171FF), # 1000m
	1500: Color.hex(0x7D7D7DFF), # 1500m
	2000: Color.hex(0x888888FF), # 2000m 
	ALTITUDE_MAX: Color.hex(0xA5A5A5FF)  # 2500m et plus
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
	50: Color.hex(0xc8240eFF),  # Rouge (extrême)
	60: Color.hex(0xbf220dFF),  # Rouge (extrême)
	70: Color.hex(0xb5200dFF),  # Rouge (extrême)
	80: Color.hex(0xac1f0cFF),  # Rouge (extrême)
	90: Color.hex(0xa21d0bFF),  # Rouge (extrême)
	100: Color.hex(0x6e1408FF)  # Noir 
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

func getBiomeColor(elevation_val : int, precipitation_val : float, temperature_val : int, is_water : bool) -> Color:
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
	
	randomize()
	var chance = randf()
	var step = (1 - chance) / corresponding_biome.size()

	corresponding_biome.shuffle()

	for biome in corresponding_biome:
		randomize()
		if randf() < chance or biome == corresponding_biome[len(corresponding_biome) - 1]:
			return biome.get_couleur()
		chance += step
	
	return Color.hex(0xFF0000FF)
