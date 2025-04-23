extends Node

# Définition des couleurs pour chaque biome avec des valeurs hexadécimales
var COULEURS_BIOMES = {
    "NAPPE_GLACIAIRE": Color.hex(0xE0E0E0),
    "TUNDRA": Color.hex(0x5AC9EC),
    "FORET_BOREAL": Color.hex(0x275D6E),
    "TUNDRA_ALPINE": Color.hex(0x78ABC1),
    "PRAIRIE": Color.hex(0x6CA868),
    "FORET_TEMPEREE": Color.hex(0x47AD40),
    "FORET_TROPICALE": Color.hex(0x2F572C),
    "FORET_SUBTROPICAL_TROPICAL": Color.hex(0x427D3E),
    "MEDITERRANEEN": Color.hex(0x634167),
    "SAVANNE": Color.hex(0xCFAD5F),
    "SAVANNE_ARBUSTIVE": Color.hex(0xBC9741),
    "DESERT_ARIDE": Color.hex(0x7D3F25),
    "DESERT_SEMI_ARIDE": Color.hex(0xCDB274),
    "TERRES_BRULEES": Color.hex(0x1B1B1B),
    "FORET_MONTAGNEUSES": Color.hex(0x5AABD3),
    "STEPPES_SECHE": Color.hex(0x9F8F6C),
    "STEPPES_TEMPEREE": Color.hex(0xFFCB58),
    "DESERT": Color.hex(0xAA5F3D)
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