extends Node

# Définition des couleurs pour chaque biome avec des informations supplémentaires
var COULEURS_BIOMES = {
    "NAPPE_GLACIAIRE": {
        "couleur": Color.hex(0xE0E0E0),
        "interval_temp": [-50, -20],
        "interval_precipitation": [0.0, 0.1],
        "elevation_minimal": 0
    },
    "TUNDRA": {
        "couleur": Color.hex(0x5AC9EC),
        "interval_temp": [-20, 0],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0
    },
    "FORET_BOREAL": {
        "couleur": Color.hex(0x275D6E),
        "interval_temp": [0, 10],
        "interval_precipitation": [0.2, 0.4],
        "elevation_minimal": 0
    },
    "TUNDRA_ALPINE": {
        "couleur": Color.hex(0x78ABC1),
        "interval_temp": [-10, 5],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 500
    },
    "PRAIRIE": {
        "couleur": Color.hex(0x6CA868),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0
    },
    "FORET_TEMPEREE": {
        "couleur": Color.hex(0x47AD40),
        "interval_temp": [10, 25],
        "interval_precipitation": [0.3, 0.6],
        "elevation_minimal": 0
    },
    "FORET_TROPICALE": {
        "couleur": Color.hex(0x2F572C),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.6, 1.0],
        "elevation_minimal": 0
    },
    "FORET_SUBTROPICAL_TROPICAL": {
        "couleur": Color.hex(0x427D3E),
        "interval_temp": [15, 30],
        "interval_precipitation": [0.4, 0.8],
        "elevation_minimal": 0
    },
    "MEDITERRANEEN": {
        "couleur": Color.hex(0x634167),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.1, 0.3],
        "elevation_minimal": 0
    },
    "SAVANNE": {
        "couleur": Color.hex(0xCFAD5F),
        "interval_temp": [20, 30],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0
    },
    "SAVANNE_ARBUSTIVE": {
        "couleur": Color.hex(0xBC9741),
        "interval_temp": [20, 35],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0
    },
    "DESERT_ARIDE": {
        "couleur": Color.hex(0x7D3F25),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0
    },
    "DESERT_SEMI_ARIDE": {
        "couleur": Color.hex(0xCDB274),
        "interval_temp": [25, 40],
        "interval_precipitation": [0.05, 0.1],
        "elevation_minimal": 0
    },
    "TERRES_BRULEES": {
        "couleur": Color.hex(0x1B1B1B),
        "interval_temp": [40, 60],
        "interval_precipitation": [0.0, 0.02],
        "elevation_minimal": 0
    },
    "FORET_MONTAGNEUSES": {
        "couleur": Color.hex(0x5AABD3),
        "interval_temp": [5, 15],
        "interval_precipitation": [0.2, 0.6],
        "elevation_minimal": 1000
    },
    "STEPPES_SECHE": {
        "couleur": Color.hex(0x9F8F6C),
        "interval_temp": [15, 25],
        "interval_precipitation": [0.05, 0.15],
        "elevation_minimal": 0
    },
    "STEPPES_TEMPEREE": {
        "couleur": Color.hex(0xFFCB58),
        "interval_temp": [10, 20],
        "interval_precipitation": [0.1, 0.2],
        "elevation_minimal": 0
    },
    "DESERT": {
        "couleur": Color.hex(0xAA5F3D),
        "interval_temp": [30, 50],
        "interval_precipitation": [0.0, 0.05],
        "elevation_minimal": 0
    }
}

# Définition des couleurs pour les élévations
var COULEURS_ELEVATIONS = {
    0: Color.hex(0x232323),       # 0m - Noir
    100: Color.hex(0x282828),    # 100m - Gris très foncé
    200: Color.hex(0x2E2E2E),    # 200m - Gris foncé
    300: Color.hex(0x353535),    # 300m - Gris
    400: Color.hex(0x3C3C3C),    # 400m - Gris moyen
    500: Color.hex(0x434343),    # 500m - Gris clair
    600: Color.hex(0x4A4A4A),    # 600m - Gris plus clair
    700: Color.hex(0x525252),    # 700m - Gris encore plus clair
    800: Color.hex(0x5C5C5C),    # 800m - Gris très clair
    900: Color.hex(0x666666),    # 900m - Presque blanc
    1000: Color.hex(0x717171),   # 1000m - Blanc
    1500: Color.hex(0x7D7D7D),   # 1500m - Glaciers
    2000: Color.hex(0x888888),   # 2000m - Glaciers plus foncés
    2500: Color.hex(0xA5A5A5)    # 2500m et plus - Glaciers encore plus foncés
}