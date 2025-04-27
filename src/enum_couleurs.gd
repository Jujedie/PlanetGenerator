extends Node

# Définition des couleurs pour chaque biome avec des informations supplémentaires
var COULEURS_BIOMES = {
    "NAPPE_GLACIAIRE": {
        "couleur": Color.hex(0xE0E0E0),
        "interval_temp": [-273, -20],
        "interval_precipitation": [0.0, 0.1],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TUNDRA": {
        "couleur": Color.hex(0x5AC9EC),
        "interval_temp": [-20, 0],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_BOREAL": {
        "couleur": Color.hex(0x275D6E),
        "interval_temp": [0, 10],
        "interval_precipitation": [0.2, 0.4],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TUNDRA_ALPINE": {
        "couleur": Color.hex(0x78ABC1),
        "interval_temp": [-10, 5],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 500,
        "water_need": false
    },
    "PRAIRIE": {
        "couleur": Color.hex(0x6CA868),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_TEMPEREE": {
        "couleur": Color.hex(0x47AD40),
        "interval_temp": [10, 25],
        "interval_precipitation": [0.3, 0.6],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_TROPICALE": {
        "couleur": Color.hex(0x2F572C),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.6, 1.0],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_SUBTROPICAL_TROPICAL": {
        "couleur": Color.hex(0x427D3E),
        "interval_temp": [15, 30],
        "interval_precipitation": [0.4, 0.8],
        "elevation_minimal": 0,
        "water_need": false
    },
    "MEDITERRANEEN": {
        "couleur": Color.hex(0x634167),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0,
        "water_need": false
    },
    "SAVANNE": {
        "couleur": Color.hex(0xCFAD5F),
        "interval_temp": [20, 30],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "SAVANNE_ARBUSTIVE": {
        "couleur": Color.hex(0xBC9741),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT_ARIDE": {
        "couleur": Color.hex(0x7D3F25),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT_SEMI_ARIDE": {
        "couleur": Color.hex(0xCDB274),
        "interval_temp": [25, 40],
        "interval_precipitation": [0.05, 0.1],
        "elevation_minimal": 0,
        "water_need": false
    },
    "TERRES_BRULEES": {
        "couleur": Color.hex(0x1B1B1B),
        "interval_temp": [40, 60],
        "interval_precipitation": [0.0, 0.02],
        "elevation_minimal": 0,
        "water_need": false
    },
    "FORET_MONTAGNEUSES": {
        "couleur": Color.hex(0x5AABD3),
        "interval_temp": [5, 15],
        "interval_precipitation": [0.2, 0.6],
        "elevation_minimal": 1000,
        "water_need": false
    },
    "STEPPES_SECHE": {
        "couleur": Color.hex(0x9F8F6C),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0,
        "water_need": false
    },
    "STEPPES_TEMPEREE": {
        "couleur": Color.hex(0xFFCB58),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0,
        "water_need": false
    },
    "DESERT": {
        "couleur": Color.hex(0xAA5F3D),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0,
        "water_need": false
    },
    "EAU": {
        "couleur": Color.hex(0x1E90FF),
        "interval_temp": [-21, 100],
        "interval_precipitation": [0.0, 1.0],
        "elevation_minimal": 0,
        "water_need": true
    },
    "GLACIER": {
        "couleur": Color.hex(0xA9D6E5),
        "interval_temp": [-273, -21],
        "interval_precipitation": [0.0, 1.0],
        "elevation_minimal": 2000,
        "water_need": false
    },
}

# Définition des couleurs pour les élévations
var COULEURS_ELEVATIONS = {
    0: Color.hex(0x232323)   , # 0m et moins - Noir
    100: Color.hex(0x282828) , # 100m - Gris très foncé
    200: Color.hex(0x2E2E2E) , # 200m - Gris foncé
    300: Color.hex(0x353535) , # 300m - Gris
    400: Color.hex(0x3C3C3C) , # 400m - Gris moyen
    500: Color.hex(0x434343) , # 500m - Gris clair
    600: Color.hex(0x4A4A4A) , # 600m - Gris plus clair
    700: Color.hex(0x525252) , # 700m - Gris encore plus clair
    800: Color.hex(0x5C5C5C) , # 800m - Gris très clair
    900: Color.hex(0x666666) , # 900m - Presque blanc
    1000: Color.hex(0x717171), # 1000m - Blanc
    1500: Color.hex(0x7D7D7D), # 1500m - Glaciers
    2000: Color.hex(0x888888), # 2000m - Glaciers plus foncés
    2500: Color.hex(0xA5A5A5)  # 2500m et plus - Glaciers encore plus foncés
}

var COULEURS_TEMPERATURE = {
    -100: Color.hex(0x4B0082), # Violet très froid
    -50:  Color.hex(0x483D8B), # Indigo froid
    -20:  Color.hex(0x0000FF), # Bleu froid
    0:  Color.hex(0x00FFFF),  # Cyan (froid modéré)
    10: Color.hex(0x00FF00),  # Vert (tempéré)
    20: Color.hex(0x7FFF00),  # Vert clair (chaud modéré)
    30: Color.hex(0xFFFF00),  # Jaune (chaud)
    40: Color.hex(0xFF4500),  # Orange (très chaud)
    50: Color.hex(0xFF0000),  # Rouge (extrême)
    100: Color.hex(0x202020)  # Rose (extrême chaud)
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
    
    for biome in corresponding_biome:
        if randf() < 0.5:
            return COULEURS_BIOMES[biome]["couleur"]
    
    return Color.hex(0xFFFFFF)