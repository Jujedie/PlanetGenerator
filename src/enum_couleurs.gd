extends Node

# Définition des couleurs pour chaque biome avec des informations supplémentaires
var COULEURS_BIOMES = {
    "NAPPE_GLACIAIRE": {
        "couleur": Color.hex(0xE0E0E0FF),
        "interval_temp": [-273, -20],
        "interval_precipitation": [0.0, 0.1],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TUNDRA": {
        "couleur": Color.hex(0x5AC9ECFF),
        "interval_temp": [-20, 0],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_BOREAL": {
        "couleur": Color.hex(0x275D6EFF),
        "interval_temp": [0, 10],
        "interval_precipitation": [0.2, 0.4],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TUNDRA_ALPINE": {
        "couleur": Color.hex(0x78ABC1FF),
        "interval_temp": [-10, 5],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 500,
        "water_need": false
    },
    "PRAIRIE": {
        "couleur": Color.hex(0x6CA868FF),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_TEMPEREE": {
        "couleur": Color.hex(0x47AD40FF),
        "interval_temp": [10, 25],
        "interval_precipitation": [0.3, 0.6],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_TROPICALE": {
        "couleur": Color.hex(0x2F572CFF),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.6, 1.0],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_SUBTROPICAL_TROPICAL": {
        "couleur": Color.hex(0x427D3EFF),
        "interval_temp": [15, 30],
        "interval_precipitation": [0.4, 0.8],
        "elevation_minimal": 0,
        "water_need": false
    },
    "MEDITERRANEEN": {
        "couleur": Color.hex(0x634167FF),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0,
        "water_need": false
    },
    "SAVANNE": {
        "couleur": Color.hex(0xCFAD5FFF),
        "interval_temp": [20, 30],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "SAVANNE_ARBUSTIVE": {
        "couleur": Color.hex(0xBC9741FF),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT_ARIDE": {
        "couleur": Color.hex(0x7D3F25FF),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT_SEMI_ARIDE": {
        "couleur": Color.hex(0xCDB274FF),
        "interval_temp": [25, 40],
        "interval_precipitation": [0.05, 0.1],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TERRES_BRULEES": {
        "couleur": Color.hex(0x1B1B1BFF),
        "interval_temp": [40, 60],
        "interval_precipitation": [0.0, 0.02],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_MONTAGNEUSES": {
        "couleur": Color.hex(0x5AABD3FF),
        "interval_temp": [5, 15],
        "interval_precipitation": [0.2, 0.6],
        "elevation_minimal": 1000,
        "water_need": false
    },
    "STEPPES_SECHE": {
        "couleur": Color.hex(0x9F8F6CFF),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0,
        "water_need": false
    },
    "STEPPES_TEMPEREE": {
        "couleur": Color.hex(0xFFCB58FF),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT": {
        "couleur": Color.hex(0xAA5F3DFF),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0,
        "water_need": false
    },
    "EAU": {
        "couleur": Color.hex(0x1E90FFFF),
        "interval_temp": [-21, 100],
        "interval_precipitation": [0.0, 1.0],
        "elevation_minimal": 0,
        "water_need": true
    },
    "GLACIER": {
        "couleur": Color.hex(0xA9D6E5FF),
        "interval_temp": [-273, -21],
        "interval_precipitation": [0.0, 1.0],
        "elevation_minimal": 2000,
        "water_need": false
    },
}

# Définition des couleurs pour les élévations
var COULEURS_ELEVATIONS = {
    -2250: Color.hex(0x010101FF), # 2250m et moins 
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
    2500: Color.hex(0xA5A5A5FF)  # 2500m et plus
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
    100: Color.hex(0x202020FF)  # Rose (extrême chaud)
}

func getElevationColor(elevation: int) -> Color:
    for key in COULEURS_ELEVATIONS.keys():
        if elevation <= key:
            return COULEURS_ELEVATIONS[key]
    return COULEURS_ELEVATIONS[2500]

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
    var corresponding_biome : Array[String] = []
    for biome in COULEURS_BIOMES.keys():
        var biome_data = COULEURS_BIOMES[biome]
        if (elevation_val >= biome_data["elevation_minimal"] and
            temperature_val >= biome_data["interval_temp"][0] and
            temperature_val <= biome_data["interval_temp"][1] and
            precipitation_val >= biome_data["interval_precipitation"][0] and
            precipitation_val <= biome_data["interval_precipitation"][1] and
            biome_data["water_need"] == is_water):
            corresponding_biome.append(biome)
    
    var chance = 0.5
    var step = 0.5 / corresponding_biome.size()

    corresponding_biome.shuffle()

    for biome in corresponding_biome:
        if randf() < chance or biome == corresponding_biome[len(corresponding_biome) - 1]:
            return COULEURS_BIOMES[biome]["couleur"]
        chance += step
    
    return Color.hex(0xFFFFFFF)