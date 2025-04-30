extends Node

const ALTITUDE_MAX = 2500

# Définition des couleurs pour chaque biome avec des informations supplémentaires
var BIOMES = [
	Biome.new("Banquise", Color.hex(0xE0FFFFFF), [-273, 0], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Cheminée hydrothermale", Color.hex(0xFF4500FF), [2, 500], [0.0,1.0],[-ALTITUDE_MAX, -1000], true),
	Biome.new("Lagune salée", Color.hex(0xFFD700FF), [10, 60], [0.0, 1.0], [-10, 500], true),
	Biome.new("Océan ouvert", Color.hex(0x1e90FFFF), [-2, 30], [0.0, 1.0], [-ALTITUDE_MAX, 0], true),
	Biome.new("Zone côtière (littorale)", Color.hex(0x20B2AAFF), [0, 30], [0.0, 1.0], [-1000, 0], true),
	Biome.new("Désert cryogénique mort", Color.hex(0x111111FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Glacier", Color.hex(0xDDEEFF), [-150, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert artique", Color.hex(0x3A3A8DFF), [-150, -50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Calotte glaciaire polaire", Color.hex(0xE0FFFFFF), [-50, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Toundra", Color.hex(0xA9BA9DFF), [-40, 12], [0.0, 1.0], [-ALTITUDE_MAX, 750], false),
	Biome.new("Toundra alpine", Color.hex(0xB0B8A0FF), [-40, 10], [0.0, 1.0], [750, ALTITUDE_MAX], false),
	Biome.new("Forêt de montagne", Color.hex(0x2E8B57FF), [0, 20], [0.4, 1.0], [400, ALTITUDE_MAX], false),
	Biome.new("Taïga (forêt boréale)", Color.hex(0x0B6623FF), [-10, 18], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt tempérée déciduelle", Color.hex(0x228B22FF), [5, 25], [0.4, 1.0], [-ALTITUDE_MAX, 400], false),
	Biome.new("Steppes sèches", Color.hex(0xD2B48CFF), [-5, 30], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Steppes tempérées", Color.hex(0xC2B280FF), [-5, 25], [0.36, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Savane", Color.hex(0xA67B5BFF), [20, 35], [0.0, 0.45], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert aride", Color.hex(0xEDC9AFFF), [30, 60], [0.0, 0.2], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert semi-aride", Color.hex(0xEBD6AEFF), [25, 50], [0.0, 0.35], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert (général)", Color.hex(0xF5DEB3FF), [20, 70], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt tropicale humide", Color.hex(0x007F33FF), [25, 40], [0.75, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Zone humide (marais/marécage)", Color.hex(0x4C9A2AFF), [5, 30], [0.75, 1.0], [-2500, 2500], true),
	Biome.new("Rivière/Cours d’eau", Color.hex(0x4169E1FF), [0, 25], [0.0, 1.0], [-2500, 2500], true),
	Biome.new("Lac/Étang", Color.hex(0x1E90FFFF), [0, 30], [0.4, 1.0], [-2500, 2500], true),
	Biome.new("Récif corallien", Color.hex(0xFF7F50FF), [20, 35], [0.0, 1.0], [-2500, 2500], true),
	Biome.new("Exosphère ionisée (upper exosphere)", Color.hex(0x8B008BFF), [450, 500], [0.0, 1.0], [-2500, 2500], false)
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
	-100: Color.hex(0x4B0082FF), # Violet très froid
	-50:  Color.hex(0x483D8BFF), # Indigo froid
	-20:  Color.hex(0x0000FFFF), # Bleu froid
	0:  Color.hex(0x00FFFFFF),  # Cyan (froid modéré)
	10: Color.hex(0x00FF00FF),  # Vert (tempéré)
	20: Color.hex(0x7FFF00FF),  # Vert clair (chaud modéré)
	30: Color.hex(0xFFFF00FF),  # Jaune (chaud)
	40: Color.hex(0xFF4500FF),  # Orange (très chaud)
	50: Color.hex(0xFF0000FF),  # Rouge (extrême)
	100: Color.hex(0x202020FF)  # Noir 
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
		if (elevation_val >= biome.get_elevation_minimal() and
			elevation_val <= biome.get_elevation_maximal() and
			temperature_val >= biome.get_interval_precipitation()[0] and
			temperature_val <= biome.get_interval_precipitation()[1] and
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
