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

	Biome.new("Zone humide (marais/marécage)", Color.hex(0x425c7bFF), Color.hex(0x3e5774FF), [5, 100], [0.0, 1.0], [-20, 20], true),
	Biome.new("Récif corallien", Color.hex(0x4f8a91FF), Color.hex(0x425c7bFF), [20, 35], [0.0, 1.0], [-500, 0], true),
	Biome.new("Lagune salée", Color.hex(0x3a666bFF), Color.hex(0x425c7bFF), [10, 100], [0.0, 1.0], [-10, 500], true),

	# Biomes Rivières/Fleuves/Lacs - Type Défaut (0) - EXCLUSIFS À river_map
	Biome.new("Rivière", Color.hex(0x4A90D9FF), Color.hex(0x3f5978FF), [-20, 100], [0.25, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),
	Biome.new("Fleuve", Color.hex(0x3E7FC4FF), Color.hex(0x3f5978FF), [-20, 100], [0.3, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),
	Biome.new("Affluent", Color.hex(0x6BAAE5FF), Color.hex(0x3e5675FF), [-20, 100], [0.2, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),
	Biome.new("Lac d'eau douce", Color.hex(0x5BA3E0FF), Color.hex(0x3c5472FF), [-10, 100], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),
	Biome.new("Lac gelé", Color.hex(0xA8D4E6FF), Color.hex(0x526e90FF), [-50, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),
	Biome.new("Rivière glaciaire", Color.hex(0x7EC8E3FF), Color.hex(0x5e799bFF), [-30, 5], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [0], true),

	#	Biomes terrestres
	Biome.new("Désert cryogénique mort", Color.hex(0xdddfe3FF), Color.hex(0xd9d9d9FF), [-273, -150], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Glacier", Color.hex(0xc7cdd6FF), Color.hex(0xe3e3e3FF), [-150, -10], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Désert artique", Color.hex(0xabb2beFF), Color.hex(0xebebebFF), [-150, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Calotte glaciaire polaire", Color.hex(0x949ca9FF), Color.hex(0xdededeFF), [-100, -20], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Toundra", Color.hex(0xcbb15fFF), Color.hex(0x4d593bFF), [-20, 4], [0.0, 1.0], [-ALTITUDE_MAX, 300], false),
	Biome.new("Toundra alpine", Color.hex(0xb79e50FF), Color.hex(0x485337FF), [-20, 4], [0.0, 1.0], [300, ALTITUDE_MAX], false),
	Biome.new("Taïga (forêt boréale)", Color.hex(0x476b3eFF), Color.hex(0x3a4d38FF), [0, 10], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	Biome.new("Forêt de montagne", Color.hex(0x4f8a40FF), Color.hex(0x3f533cFF), [-15, 20], [0.0, 1.0], [300, ALTITUDE_MAX], false),
	
	Biome.new("Forêt tempérée", Color.hex(0x65c44eFF), Color.hex(0x435940FF), [5, 25], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
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
	Biome.new("Océan toxique", Color.hex(0x329b83FF), Color.hex(0x3b6e61FF), [-21, 100], [0.0, 1.0], [-ALTITUDE_MAX, 0], true, [1]),
	Biome.new("Marécages acides", Color.hex(0x359b3aFF), Color.hex(0x356458FF), [5, 100], [0.0, 1.0], [-20, ALTITUDE_MAX], true, [1]),

	# Biomes Rivières/Lacs - Type Toxique (1) - EXCLUSIFS à river_map
	Biome.new("Rivière acide", Color.hex(0x5BC45AFF), Color.hex(0x3d553cFF), [-20, 100], [0.25, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),
	Biome.new("Fleuve toxique", Color.hex(0x48B847FF), Color.hex(0x394e38FF), [-20, 100], [0.3, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),
	Biome.new("Affluent toxique", Color.hex(0x7ADB79FF), Color.hex(0x334532FF), [-20, 100], [0.2, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),
	Biome.new("Lac d'acide", Color.hex(0x6ED96DFF), Color.hex(0x425b41FF), [-10, 100], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),
	Biome.new("Lac toxique gelé", Color.hex(0xB8E6B7FF), Color.hex(0x4a6448FF), [-50, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),
	Biome.new("Cours d'eau contaminé", Color.hex(0x8AEB89FF), Color.hex(0x4a6448FF), [-30, 35], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [1], true),

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

	# Biomes Rivières/Lacs - Type Volcanique (2) - EXCLUSIFS à river_map
	Biome.new("Rivière de lave", Color.hex(0xFF6B1AFF), Color.hex(0xd45a15FF), [30, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),
	Biome.new("Fleuve de magma", Color.hex(0xE85A0FFF), Color.hex(0xc44b0dFF), [50, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),
	Biome.new("Affluent de lave", Color.hex(0xFF8533FF), Color.hex(0xd97029FF), [30, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),
	Biome.new("Lac de lave", Color.hex(0xFF9944FF), Color.hex(0xe08030FF), [40, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),
	Biome.new("Bassin de magma refroidi", Color.hex(0x8B4513FF), Color.hex(0x6b3510FF), [-50, 30], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),
	Biome.new("Cours de lave solidifiée", Color.hex(0xA0522DFF), Color.hex(0x804020FF), [-30, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [2], true),

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

	# Biomes Rivières/Lacs - Type Mort (4) - EXCLUSIFS à river_map
	Biome.new("Rivière stagnante", Color.hex(0x5A7A5BFF), Color.hex(0x3d553cFF), [-20, 100], [0.25, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),
	Biome.new("Fleuve pollué", Color.hex(0x4A6A4BFF), Color.hex(0x394e38FF), [-20, 100], [0.3, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),
	Biome.new("Affluent pollué", Color.hex(0x6A8A6BFF), Color.hex(0x334532FF), [-20, 100], [0.2, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),
	Biome.new("Lac irradié", Color.hex(0x6B8B6CFF), Color.hex(0x425b41FF), [-10, 100], [0.4, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),
	Biome.new("Lac de boue", Color.hex(0x8B7355FF), Color.hex(0x4a6448FF), [-10, 50], [0.3, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),
	Biome.new("Mare stagnante", Color.hex(0x7A9A7BFF), Color.hex(0x4b6448FF), [0, 40], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [4], true),

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
	-ALTITUDE_MAX: Color.hex(0x2491ffFF),
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

var RESSOURCES = [
	# Format: Ressource.new(nom, couleur, probabilité_relative, taille_moyenne_gisement)
	# Probabilités basées sur l'abondance réelle dans la croûte terrestre
	# Couleurs distinctives pour chaque ressource
	
	# === TRÈS COMMUNS (abondance croûte terrestre > 1%) ===
	Ressource.new("Fer",       Color.hex(0x8B4513FF), 0.22, 350),  # Brun rouille - 5% croûte
	Ressource.new("Aluminium", Color.hex(0xA8A9ADFF), 0.18, 280),  # Gris métallique clair - 8% croûte
	Ressource.new("Silicium",  Color.hex(0x4A4A4AFF), 0.15, 400),  # Gris foncé - 28% croûte (mais exploitable moins)
	
	# === COMMUNS (abondance 0.1% - 1%) ===
	Ressource.new("Charbon",   Color.hex(0x1C1C1CFF), 0.12, 500),  # Noir profond
	Ressource.new("Calcaire",  Color.hex(0xF5F5DCFF), 0.08, 450),  # Beige crème
	Ressource.new("Sel",       Color.hex(0xFFFAFAFF), 0.06, 350),  # Blanc pur
	Ressource.new("Cuivre",    Color.hex(0xB87333FF), 0.04, 120),  # Orange cuivré
	
	# === MODÉRÉS (abondance 0.01% - 0.1%) ===
	Ressource.new("Zinc",      Color.hex(0x7D7D7DFF), 0.025, 80),  # Gris bleuté
	Ressource.new("Plomb",     Color.hex(0x2F4F4FFF), 0.020, 70),  # Gris ardoise foncé
	Ressource.new("Nickel",    Color.hex(0x727472FF), 0.018, 60),  # Gris verdâtre
	Ressource.new("Manganèse", Color.hex(0x8B8589FF), 0.015, 90),  # Gris rosé
	
	# === RARES (abondance 0.001% - 0.01%) ===
	Ressource.new("Étain",     Color.hex(0xD3D4D5FF), 0.010, 40),  # Argent mat
	Ressource.new("Tungstène", Color.hex(0x36454FFF), 0.008, 25),  # Gris charbon
	Ressource.new("Titane",    Color.hex(0xC4CACEAF), 0.012, 55),  # Blanc métallique
	Ressource.new("Lithium",   Color.hex(0xDDA0DDFF), 0.006, 35),  # Violet pâle
	Ressource.new("Cobalt",    Color.hex(0x0047ABFF), 0.005, 20),  # Bleu cobalt
	
	# === TRÈS RARES (abondance < 0.001%) ===
	Ressource.new("Uranium",   Color.hex(0x7FFF00FF), 0.003, 15),  # Vert radioactif
	Ressource.new("Argent",    Color.hex(0xC0C0C0FF), 0.0025, 12), # Argent brillant
	Ressource.new("Or",        Color.hex(0xFFD700FF), 0.0008, 8),  # Or brillant
	Ressource.new("Platine",   Color.hex(0xE5E4E2FF), 0.0004, 4),  # Blanc platine
	Ressource.new("Diamant",   Color.hex(0xB9F2FFFF), 0.0002, 3),  # Bleu cristallin
	
	# === HYDROCARBURES (distribution géologique) ===
	Ressource.new("Pétrole",   Color.hex(0x000000FF), 0.025, 200), # Noir
	Ressource.new("Gaz naturel", Color.hex(0x87CEEBFF), 0.020, 180), # Bleu ciel
	
	# === PIERRES PRÉCIEUSES ===
	Ressource.new("Émeraude",  Color.hex(0x50C878FF), 0.0003, 2),  # Vert émeraude
	Ressource.new("Rubis",     Color.hex(0xE0115FFF), 0.0003, 2),  # Rouge rubis
	Ressource.new("Saphir",    Color.hex(0x0F52BAFF), 0.0003, 2)   # Bleu saphir
]

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
	# Comparaison approximative par distance de couleur
	# (la comparaison exacte échoue à cause des imprécisions de flottants)
	var best_key = 0
	var best_distance = 999.0
	
	for key in COULEURS_ELEVATIONS.keys():
		var ref_color = COULEURS_ELEVATIONS[key]
		var distance = sqrt(
			pow(color.r - ref_color.r, 2) +
			pow(color.g - ref_color.g, 2) +
			pow(color.b - ref_color.b, 2)
		)
		if distance < best_distance:
			best_distance = distance
			best_key = key
	
	return best_key

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

func getBiome(type_planete : int, elevation_val : int, precipitation_val : float, temperature_val : int, is_water : bool, img_biome: Image, x:int, y:int, generator = null) -> Biome:
	var corresponding_biome : Array[Biome] = []

	for biome in BIOMES:
		# Exclure les biomes exclusifs aux rivières/lacs (ils ne sont utilisés que sur river_map)
		if biome.get_river_lake_only():
			continue
		
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
	
	# Récupérer les biomes voisins et le plus courant
	var surrounding = getSuroundingBiomes(img_biome, x, y, generator)
	var most_common_biome = getMostCommonSurroundingBiome(surrounding)
	
	# Calculer le pourcentage de voisins avec le même biome pour renforcer l'homogénéité
	var same_biome_count = 0
	for b in surrounding:
		if b != null and most_common_biome != null and b.get_nom() == most_common_biome.get_nom():
			same_biome_count += 1
	
	randomize()
	var chance = randf()
	
	# Plus il y a de voisins du même biome, plus on a de chances de le choisir
	# Cela crée un effet de "blob" naturel
	if most_common_biome != null and most_common_biome in corresponding_biome:
		# Base 60% + 5% par voisin identique (max 8 voisins = 100%)
		var homogeneity_chance = 0.6 + (same_biome_count * 0.05)
		if chance <= homogeneity_chance:
			return most_common_biome
	
	if taille > 0 :
		return corresponding_biome[randi() % taille]
	
	return Biome.new("Aucun", Color.hex(0xFF0000FF), Color.hex(0xFF0000FF), [0, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false)

func getSuroundingBiomes(img_biome: Image, x:int, y:int, _generator = null) -> Array:
	var surrounding_biomes = []
	var width = img_biome.get_width()
	var height = img_biome.get_height()
	
	for i in range(-1, 2):
		for j in range(-1, 2):
			if i == 0 and j == 0:
				continue
			# Wrap horizontal pour la continuité torique
			var new_x = posmod(x + i, width)
			var new_y = y + j
			# Pas de wrap vertical (les pôles ne se rejoignent pas)
			if new_y >= 0 and new_y < height:
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
	
	# Retourner le premier biome disponible comme fallback
	if BIOMES.size() > 0:
		return BIOMES[0]
	return Biome.new("Fallback", Color.hex(0x808080FF), Color.hex(0x808080FF), [-100, 100], [0.0, 1.0], [-10000, 10000], false)

func getPrecipitationColor(precipitation: float) -> Color:
	for key in COULEUR_PRECIPITATION.keys():
		if precipitation <= key:
			return COULEUR_PRECIPITATION[key]
	return COULEUR_PRECIPITATION[1.0]

func getBiomeByNoise(type_planete: int, elevation_val: int, precipitation_val: float, temperature_val: int, is_water: bool, noise_val: float) -> Biome:
	# Trouve tous les biomes correspondants et en sélectionne un basé sur le bruit
	var corresponding_biome : Array[Biome] = []

	for biome in BIOMES:
		if biome.get_river_lake_only():
			continue
		
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
	if taille > 0:
		# Utiliser le bruit pour sélectionner de façon déterministe
		var index = int(noise_val * taille) % taille
		return corresponding_biome[index]
	
	return Biome.new("Aucun", Color.hex(0xFF0000FF), Color.hex(0xFF0000FF), [0, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false)

func getBiomeByColor(color: Color) -> Biome:
	# Trouve un biome par sa couleur
	for biome in BIOMES:
		if biome.get_couleur() == color:
			return biome
	return null

func getBanquiseBiome( typePlanete : int) -> Biome:
	for biome in BIOMES:
		if typePlanete in biome.get_type_planete():
			if biome.get_nom().find("Banquise") != -1 or biome.get_nom().find("Refroidis") != -1:
				return biome
	# Fallback: retourner un biome de glace générique
	return Biome.new("Banquise", Color.hex(0xE8F4F8FF), Color.hex(0xFFFFFFFF), [-100, 0], [0.0, 1.0], [-10000, 10000], false)

func getRiverBiome(temperature_val: int, precipitation_val: float, type_planete: int) -> Biome:
	# Chercher les biomes rivière/lac appropriés selon la température
	var best_biome : Biome = null
	var best_score : float = -1.0
	
	for biome in BIOMES:
		var nom = biome.get_nom()
		# Vérifier si c'est un biome de rivière/lac
		if nom.find("Rivière") == -1 and nom.find("Fleuve") == -1 and nom.find("Lac") == -1:
			continue
		
		# Vérifier le type de planète
		if type_planete not in biome.get_type_planete():
			continue
		
		# Vérifier la température
		var temp_range = biome.get_interval_temp()
		if temperature_val < temp_range[0] or temperature_val > temp_range[1]:
			continue
		
		# Vérifier les précipitations
		var precip_range = biome.get_interval_precipitation()
		if precipitation_val < precip_range[0] or precipitation_val > precip_range[1]:
			continue
		
		# Score basé sur la correspondance
		var temp_center = (temp_range[0] + temp_range[1]) / 2.0
		var temp_score = 1.0 - abs(temperature_val - temp_center) / max(1, temp_range[1] - temp_range[0])
		
		if temp_score > best_score:
			best_score = temp_score
			best_biome = biome
	
	# Si aucun biome trouvé, retourner un biome par défaut selon le type de planète
	if best_biome == null:
		# Chercher un biome lac/rivière pour ce type de planète
		for biome in BIOMES:
			if not biome.get_river_lake_only():
				continue
			if type_planete not in biome.get_type_planete():
				continue
			# Prendre le premier biome rivière/lac valide pour ce type
			return biome
		
		# Dernier recours: Lac gelé si froid, rivière sinon (pour type 0)
		if temperature_val < 0:
			for biome in BIOMES:
				if biome.get_nom() == "Lac gelé":
					return biome
		for biome in BIOMES:
			if biome.get_nom() == "Rivière":
				return biome
		# Fallback: créer un biome rivière générique
		return Biome.new("Rivière", Color.hex(0x4A90D9FF), Color.hex(0x4A90D9FF), [-50, 100], [0.0, 1.0], [-10000, 10000], true, [0, 1, 2, 3], true)
	
	return best_biome

func getRiverBiomeBySize(temperature_val: int, type_planete: int, size: int) -> Biome:
	# size: 0 = Affluent (petit), 1 = Rivière (moyen), 2 = Fleuve (grand)
	var size_names = {
		0: ["Affluent", "Affluent toxique", "Affluent de lave", "Affluent pollué"],
		1: ["Rivière", "Rivière acide", "Rivière de lave", "Rivière stagnante", "Rivière glaciaire", "Cours d'eau contaminé", "Cours de lave solidifiée"],
		2: ["Fleuve", "Fleuve toxique", "Fleuve de magma", "Fleuve pollué"]
	}
	
	var target_names = size_names.get(size, size_names[1])
	
	var best_biome: Biome = null
	var best_score: float = -1.0
	
	for biome in BIOMES:
		if not biome.get_river_lake_only():
			continue
		
		# Vérifier le type de planète
		if type_planete not in biome.get_type_planete():
			continue
		
		var nom = biome.get_nom()
		var is_target_size = false
		for target_name in target_names:
			if nom.begins_with(target_name) or nom == target_name:
				is_target_size = true
				break
		
		if not is_target_size:
			continue
		
		# Vérifier la température
		var temp_range = biome.get_interval_temp()
		if temperature_val < temp_range[0] or temperature_val > temp_range[1]:
			continue
		
		# Score basé sur la correspondance de température
		var temp_center = (temp_range[0] + temp_range[1]) / 2.0
		var temp_score = 1.0 - abs(temperature_val - temp_center) / max(1, temp_range[1] - temp_range[0])
		
		if temp_score > best_score:
			best_score = temp_score
			best_biome = biome
	
	# Fallback: essayer getRiverBiome standard
	if best_biome == null:
		best_biome = getRiverBiome(temperature_val, 0.5, type_planete)
	
	return best_biome

func getLakeBiome(temperature_val: int, type_planete: int) -> Biome:
	var lake_names = ["Lac", "Lac d'eau douce", "Lac gelé", "Lac d'acide", "Lac toxique gelé", "Lac de lave", "Lac irradié", "Lac de boue", "Mare stagnante", "Bassin de magma refroidi"]
	
	var best_biome: Biome = null
	var best_score: float = -1.0
	
	for biome in BIOMES:
		if not biome.get_river_lake_only():
			continue
		
		# Vérifier le type de planète
		if type_planete not in biome.get_type_planete():
			continue
		
		var nom = biome.get_nom()
		var is_lake = false
		for lake_name in lake_names:
			if nom.begins_with(lake_name) or nom == lake_name or nom.find("Lac") != -1 or nom.find("Mare") != -1 or nom.find("Bassin") != -1:
				is_lake = true
				break
		
		if not is_lake:
			continue
		
		# Vérifier la température
		var temp_range = biome.get_interval_temp()
		if temperature_val < temp_range[0] or temperature_val > temp_range[1]:
			continue
		
		# Score basé sur la correspondance de température
		var temp_center = (temp_range[0] + temp_range[1]) / 2.0
		var temp_score = 1.0 - abs(temperature_val - temp_center) / max(1, temp_range[1] - temp_range[0])
		
		if temp_score > best_score:
			best_score = temp_score
			best_biome = biome
	
	# Fallback
	if best_biome == null:
		# Chercher un lac par défaut pour ce type
		for biome in BIOMES:
			if biome.get_river_lake_only() and type_planete in biome.get_type_planete():
				if biome.get_nom().find("Lac") != -1:
					return biome
		# Dernier recours
		best_biome = getRiverBiome(temperature_val, 0.5, type_planete)
	
	return best_biome

func getRessourceByProbabilite() -> Ressource:
	var rand_val = randf()
	var cumulative_prob = 0.0
	for ressource in RESSOURCES:
		cumulative_prob += ressource.probabilite
		if rand_val <= cumulative_prob:
			return ressource
	return RESSOURCES[-1] # Retourne la dernière ressource si aucune n'a été trouvée
