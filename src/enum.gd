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
	-ALTITUDE_MAX: Color.hex(0x4c7b9eFF),
	-20000: Color.hex(0x5081a6FF),
	-8000: Color.hex(0x5c99c4FF),
	-6000: Color.hex(0x5f9dc8FF),
	-4000: Color.hex(0x62a0cbFF),
	-3000: Color.hex(0x64a3cdFF),
	-2000: Color.hex(0x67a5d0FF),
	-1750: Color.hex(0x6facd5FF),
	-1500: Color.hex(0x6caad3FF),
	-1250: Color.hex(0x6facd5FF),
	-1000: Color.hex(0x76b2d8FF),
	-750: Color.hex(0x7bb5daFF),
	-500: Color.hex(0x87bddfFF),
	-450: Color.hex(0x90c3e2FF),
	-400: Color.hex(0x99c8e5FF),
	-350: Color.hex(0xa2cde8FF),
	-300: Color.hex(0xaad2ebFF),
	-250: Color.hex(0xb1d7edFF),
	-200: Color.hex(0xb7daefFF),
	-150: Color.hex(0xbdddf0FF),
	-100: Color.hex(0xc3e0f2FF),
	-50: Color.hex(0xc8e3f4FF),
	-20: Color.hex(0xcee7f5FF),

	0: Color.hex(0x729e8bFF),

	20: Color.hex(0x79a294FF),
	50: Color.hex(0x7fad98FF),
	100: Color.hex(0x89b5a0FF),
	150: Color.hex(0x85a59eFF),
	200: Color.hex(0x89aaa6FF),
	250: Color.hex(0x92b1aaFF),
	300: Color.hex(0x90a9a0FF),
	350: Color.hex(0x9db6afFF),
	400: Color.hex(0xa1bcaaFF),
	450: Color.hex(0x8e9f98FF),
	500: Color.hex(0x87968cFF),
	550: Color.hex(0xc2c5b3FF),
	600: Color.hex(0xd1c9b5FF),
	650: Color.hex(0xc3b9a9FF),
	700: Color.hex(0xcbc0afFF),
	750: Color.hex(0xb6aea1FF),
	800: Color.hex(0xaba598FF),
	850: Color.hex(0x9f9e94FF),
	900: Color.hex(0xae9e8eFF),
	950: Color.hex(0x918476FF),
	1000: Color.hex(0x989284FF),
	1500: Color.hex(0xcdd0caFF),
	1750: Color.hex(0xa7aea3FF),
	2000: Color.hex(0xbbc9c4FF),
	3000: Color.hex(0xa8b6afFF),
	4000: Color.hex(0xedeef5FF),
	6000: Color.hex(0xf3f4f9FF),
	8000: Color.hex(0xf7f8fcFF),
	12000: Color.hex(0xfafbffFF),
	16000: Color.hex(0xfcfdffFF),
	20000: Color.hex(0xfdffffFF),
	24000: Color.hex(0xfeffffFF),
	ALTITUDE_MAX: Color.hex(0xffffffFF) 
}

var COULEURS_ELEVATIONS_GREY = {
	-ALTITUDE_MAX: Color.hex(0x030303FF),
	-20000: Color.hex(0x030303FF),
	-8000: Color.hex(0x030303FF),
	-6000: Color.hex(0x050505FF),
	-4000: Color.hex(0x050505FF),
	-3000: Color.hex(0x050505FF),
	-2000: Color.hex(0x080808FF),
	-1750: Color.hex(0x080808FF),
	-1500: Color.hex(0x080808FF),
	-1250: Color.hex(0x0a0a0aFF),
	-1000: Color.hex(0x0a0a0aFF),
	-750: Color.hex(0x0d0d0dFF),
	-500: Color.hex(0x0d0d0dFF),
	-450: Color.hex(0x121212FF),
	-400: Color.hex(0x121212FF),
	-350: Color.hex(0x121212FF),
	-300: Color.hex(0x121212FF),
	-250: Color.hex(0x141414FF),
	-200: Color.hex(0x171717FF),
	-150: Color.hex(0x1a1a1aFF),
	-100: Color.hex(0x1c1c1cFF),
	-50: Color.hex(0x1f1f1fFF),
	-20: Color.hex(0x212121FF),

	0: Color.hex(0x232323FF),

	20: Color.hex(0x262626FF),
	50: Color.hex(0x292929FF),
	100: Color.hex(0x2d2d2dFF),
	150: Color.hex(0x313131FF),
	200: Color.hex(0x353535FF),
	250: Color.hex(0x3a3a3aFF),
	300: Color.hex(0x3f3f3fFF),
	350: Color.hex(0x444444FF),
	400: Color.hex(0x494949FF),
	450: Color.hex(0x505050FF),
	500: Color.hex(0x575757FF),
	550: Color.hex(0x5d5d5dFF),
	600: Color.hex(0x636363FF),
	650: Color.hex(0x676767FF),
	700: Color.hex(0x6b6b6bFF),
	750: Color.hex(0x6e6e6eFF),
	800: Color.hex(0x737373FF),
	850: Color.hex(0x777777FF),
	900: Color.hex(0x7f7f7fFF),
	950: Color.hex(0x868686FF),
	1000: Color.hex(0x8f8f8fFF),
	1500: Color.hex(0x8f8f8fFF),
	1750: Color.hex(0xaeaeaeFF),
	2000: Color.hex(0xb0b0b0FF),
	3000: Color.hex(0xb3b3b3FF),
	4000: Color.hex(0xb8b8b8FF),
	6000: Color.hex(0xbdbdbdFF),
	8000: Color.hex(0xc2c2c2FF),
	12000: Color.hex(0xc7c7c7FF),
	16000: Color.hex(0xccccccFF),
	20000: Color.hex(0xd1d1d1FF),
	24000: Color.hex(0xd6d6d6FF),
	ALTITUDE_MAX: Color.hex(0xdbdbdbFF)
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
	# Probabilités basées sur l'abondance RÉELLE dans la croûte terrestre
	# Valeurs en pourcentage de la croûte terrestre (normalisées pour génération)
	# Les ressources peuvent se superposer - génération indépendante par ressource
	# Couleurs distinctives pour chaque ressource
	
	# ============================================================================
	# CATÉGORIE 1 : ULTRA-ABONDANTS (> 2% de la croûte terrestre)
	# ============================================================================
	Ressource.new("Silicium",       Color.hex(0x4A4A4AFF), 27.7, 1000),  # 27.7% croûte - Gris foncé
	Ressource.new("Aluminium",      Color.hex(0xA8A9ADFF), 8.1, 800),    # 8.1% croûte - Gris métallique
	Ressource.new("Fer",            Color.hex(0x8B4513FF), 5.0, 700),    # 5.0% croûte - Brun rouille
	Ressource.new("Calcium",        Color.hex(0xF5F5F5FF), 3.6, 650),    # 3.6% croûte - Blanc grisé
	Ressource.new("Magnésium",      Color.hex(0x9ACD32FF), 2.1, 550),    # 2.1% croûte - Vert-jaune
	Ressource.new("Potassium",      Color.hex(0xDA70D6FF), 2.0, 500),    # 2.0% croûte - Orchidée
	
	# ============================================================================
	# CATÉGORIE 2 : TRÈS COMMUNS (0.1% - 1%)
	# ============================================================================
	Ressource.new("Titane",         Color.hex(0xC4CACEAF), 0.56, 450),   # 0.56% croûte - Blanc métallique
	Ressource.new("Phosphate",      Color.hex(0x556B2FFF), 0.1, 400),    # 0.1% croûte - Vert olive foncé
	Ressource.new("Manganèse",      Color.hex(0x8B8589FF), 0.1, 380),    # 0.1% croûte - Gris rosé
	Ressource.new("Soufre",         Color.hex(0xFFFF00FF), 0.1, 400),    # 0.1% croûte - Jaune vif
	Ressource.new("Charbon",        Color.hex(0x1C1C1CFF), 0.08, 700),   # Sédimentaire organique - Noir profond
	Ressource.new("Calcaire",       Color.hex(0xF5F5DCFF), 0.08, 700),   # Sédimentaire - Beige crème
	
	# ============================================================================
	# CATÉGORIE 3 : COMMUNS (100 - 500 ppm = 0.01% - 0.05%)
	# ============================================================================
	Ressource.new("Baryum",         Color.hex(0xFFFDD0FF), 0.04, 280),   # 0.04% croûte - Crème
	Ressource.new("Strontium",      Color.hex(0xFFE4B5FF), 0.04, 260),   # 0.04% croûte - Mocassin
	Ressource.new("Zirconium",      Color.hex(0xE0E0E0FF), 0.02, 220),   # 0.02% croûte - Gris clair
	Ressource.new("Vanadium",       Color.hex(0x708090FF), 0.02, 200),   # 0.02% croûte - Gris ardoise
	Ressource.new("Chrome",         Color.hex(0xFFD700FF), 0.02, 190),   # 0.02% croûte - Chrome doré
	Ressource.new("Nickel",         Color.hex(0x727472FF), 0.01, 170),   # 0.01% croûte - Gris verdâtre
	Ressource.new("Zinc",           Color.hex(0x7D7D7DFF), 0.01, 160),   # 0.01% croûte - Gris bleuté
	Ressource.new("Cuivre",         Color.hex(0xB87333FF), 0.01, 150),   # 0.01% croûte - Orange cuivré
	Ressource.new("Sel",            Color.hex(0xFFFAFAFF), 0.01, 500),   # Évaporites - Blanc pur
	Ressource.new("Fluorine",       Color.hex(0x9966CCFF), 0.01, 180),   # Évaporite - Violet améthyste
	
	# ============================================================================
	# CATÉGORIE 4 : MODÉRÉMENT RARES (10 - 50 ppm = 0.001% - 0.005%)
	# ============================================================================
	Ressource.new("Cobalt",         Color.hex(0x0047ABFF), 0.002, 100),  # 0.002% (20 ppm) - Bleu cobalt
	Ressource.new("Lithium",        Color.hex(0xDDA0DDFF), 0.002, 90),   # 0.002% (20 ppm) - Violet pâle
	Ressource.new("Niobium",        Color.hex(0x6B8E23FF), 0.002, 85),   # 0.002% (20 ppm) - Vert olive
	Ressource.new("Plomb",          Color.hex(0x2F4F4FFF), 0.002, 80),   # 0.002% (20 ppm) - Gris ardoise
	Ressource.new("Bore",           Color.hex(0x8B0000FF), 0.001, 70),   # 0.001% (10 ppm) - Rouge foncé
	Ressource.new("Thorium",        Color.hex(0x228B22FF), 0.001, 65),   # 0.001% (10 ppm) - Vert forêt
	Ressource.new("Graphite",       Color.hex(0x333333FF), 0.001, 120),  # 0.001% (10 ppm) - Gris anthracite
	
	# ============================================================================
	# CATÉGORIE 5 : RARES (1 - 5 ppm = 0.0001% - 0.0005%)
	# ============================================================================
	Ressource.new("Étain",          Color.hex(0xD3D4D5FF), 0.0002, 50),  # 0.0002% (2 ppm) - Argent mat
	Ressource.new("Béryllium",      Color.hex(0x7FFFD4FF), 0.0002, 48),  # 0.0002% (2 ppm) - Aigue-marine
	Ressource.new("Arsenic",        Color.hex(0x696969FF), 0.0002, 45),  # 0.0002% (2 ppm) - Gris dim
	Ressource.new("Germanium",      Color.hex(0xC0C0C0FF), 0.0002, 42),  # 0.0002% (2 ppm) - Argent
	Ressource.new("Uranium",        Color.hex(0x7FFF00FF), 0.0002, 40),  # 0.0002% (2 ppm) - Vert radioactif
	Ressource.new("Molybdène",      Color.hex(0x4682B4FF), 0.0002, 38),  # 0.0002% (2 ppm) - Bleu acier
	Ressource.new("Tungstène",      Color.hex(0x36454FFF), 0.0002, 35),  # 0.0002% (2 ppm) - Gris charbon
	Ressource.new("Antimoine",      Color.hex(0xFAEBD7FF), 0.00005, 30), # 0.00005% (0.5 ppm) - Blanc antique
	Ressource.new("Tantale",        Color.hex(0x5F9EA0FF), 0.00005, 28), # 0.00005% (0.5 ppm) - Bleu cadet
	
	# ============================================================================
	# CATÉGORIE 6 : TRÈS RARES (< 0.1 ppm = < 0.00001%)
	# ============================================================================
	Ressource.new("Argent",         Color.hex(0xC0C0C0FF), 0.000007, 20),# 0.000007% (0.07 ppm) - Argent brillant
	Ressource.new("Cadmium",        Color.hex(0xFFEC8BFF), 0.000005, 18),# 0.000005% - Jaune clair
	Ressource.new("Mercure",        Color.hex(0xB0C4DEFF), 0.000005, 16),# 0.000005% - Bleu clair acier
	Ressource.new("Sélénium",       Color.hex(0xFF6347FF), 0.000005, 14),# 0.000005% - Tomate
	Ressource.new("Indium",         Color.hex(0x4B0082FF), 0.000001, 12),# 0.000001% - Indigo
	Ressource.new("Bismuth",        Color.hex(0xFF69B4FF), 0.000001, 12),# 0.000001% - Rose vif
	Ressource.new("Tellure",        Color.hex(0xCD853FFF), 0.000001, 10),# 0.000001% - Pérou
	
	# ============================================================================
	# CATÉGORIE 7 : EXTRÊMEMENT RARES (Métaux précieux < 0.001 ppm)
	# ============================================================================
	Ressource.new("Or",             Color.hex(0xFFD700FF), 0.0000004, 15),# 0.0000004% (0.004 ppm) - Or brillant
	Ressource.new("Platine",        Color.hex(0xE5E4E2FF), 0.0000001, 10),# 0.0000001% (0.001 ppm) - Blanc platine
	Ressource.new("Palladium",      Color.hex(0xCEC8C0FF), 0.0000001, 10),# 0.0000001% (0.001 ppm) - Gris perle
	Ressource.new("Rhodium",        Color.hex(0xC0C0C0FF), 0.0000001, 8), # 0.0000001% (0.001 ppm) - Argent clair
	Ressource.new("Iridium",        Color.hex(0xF0F8FFFF), 0.0000001, 8), # 0.0000001% (0.001 ppm) - Blanc Alice
	Ressource.new("Osmium",         Color.hex(0x476276FF), 0.0000001, 8), # 0.0000001% (0.001 ppm) - Bleu-gris
	Ressource.new("Ruthénium",      Color.hex(0x808080FF), 0.0000001, 8), # 0.0000001% (0.001 ppm) - Gris
	Ressource.new("Rhénium",        Color.hex(0xA9A9A9FF), 0.0000001, 6), # 0.0000001% (0.001 ppm) - Gris foncé
	
	# ============================================================================
	# CATÉGORIE 8 : TERRES RARES (Lanthanides - plus communes que l'argent)
	# ============================================================================
	Ressource.new("Cérium",         Color.hex(0xFFF8DCFF), 0.006, 40),   # 0.006% - Le plus abondant des TR
	Ressource.new("Lanthane",       Color.hex(0xFFFAF0FF), 0.003, 35),   # 0.003% - Blanc floral
	Ressource.new("Néodyme",        Color.hex(0x9370DBFF), 0.003, 35),   # 0.003% - Violet moyen (aimants)
	Ressource.new("Yttrium",        Color.hex(0x87CEFAFF), 0.0005, 28),  # 0.0005% - Bleu ciel clair
	Ressource.new("Praséodyme",     Color.hex(0xADFF2FFF), 0.0005, 26),  # 0.0005% - Vert-jaune
	Ressource.new("Samarium",       Color.hex(0xDEB887FF), 0.0005, 24),  # 0.0005% - Bois
	Ressource.new("Gadolinium",     Color.hex(0xF5DEB3FF), 0.0005, 22),  # 0.0005% - Blé
	Ressource.new("Dysprosium",     Color.hex(0xBDB76BFF), 0.0005, 20),  # 0.0005% - Kaki foncé
	Ressource.new("Erbium",         Color.hex(0xFFC0CBFF), 0.0005, 18),  # 0.0005% - Rose
	Ressource.new("Europium",       Color.hex(0xFF4500FF), 0.0001, 14),  # 0.0001% - Rouge orangé
	Ressource.new("Terbium",        Color.hex(0x32CD32FF), 0.0001, 12),  # 0.0001% - Vert lime
	Ressource.new("Holmium",        Color.hex(0xFFD700FF), 0.0001, 10),  # 0.0001% - Or clair
	Ressource.new("Thulium",        Color.hex(0x00CED1FF), 0.0001, 8),   # 0.0001% - Turquoise foncé
	Ressource.new("Ytterbium",      Color.hex(0xE6E6FAFF), 0.0001, 8),   # 0.0001% - Lavande
	Ressource.new("Lutétium",       Color.hex(0xD8BFD8FF), 0.0001, 6),   # 0.0001% - Chardon
	Ressource.new("Scandium",       Color.hex(0x00FA9AFF), 0.0001, 20),  # 0.0001% - Vert printemps
	
	# ============================================================================
	# CATÉGORIE 9 : HYDROCARBURES ET COMBUSTIBLES FOSSILES
	# NOTE: Le pétrole est géré séparément par petrole.glsl
	# ============================================================================
	Ressource.new("Gaz naturel",    Color.hex(0x87CEEBFF), 0.5, 450),    # 0.5% bassins - Bleu ciel
	Ressource.new("Lignite",        Color.hex(0x3D2B1FFF), 0.5, 500),    # 0.5% bassins - Brun foncé
	Ressource.new("Anthracite",     Color.hex(0x0C0C0CFF), 0.5, 420),    # 0.5% bassins - Noir intense
	Ressource.new("Tourbe",         Color.hex(0x5C4033FF), 1.0, 550),    # 1.0% zones humides - Brun terre
	Ressource.new("Schiste bitumineux", Color.hex(0x4A412AFF), 1.0, 400),# 1.0% zones sédimentaires - Brun olive
	Ressource.new("Méthane hydraté", Color.hex(0xADD8E6FF), 0.1, 300),   # 0.1% fonds marins - Bleu clair
	
	# ============================================================================
	# CATÉGORIE 10 : PIERRES PRÉCIEUSES ET GEMMES
	# ============================================================================
	Ressource.new("Diamant",        Color.hex(0xB9F2FFFF), 0.001, 12),   # 0.001% - Bleu cristallin
	Ressource.new("Émeraude",       Color.hex(0x50C878FF), 0.001, 10),   # 0.001% - Vert émeraude
	Ressource.new("Rubis",          Color.hex(0xE0115FFF), 0.001, 10),   # 0.001% - Rouge rubis
	Ressource.new("Saphir",         Color.hex(0x0F52BAFF), 0.001, 10),   # 0.001% - Bleu saphir
	Ressource.new("Topaze",         Color.hex(0xFFC87CFF), 0.01, 18),    # 0.01% - Orange doré
	Ressource.new("Améthyste",      Color.hex(0x9966CCFF), 0.5, 50),     # 0.5% (quartz commun) - Violet
	Ressource.new("Opale",          Color.hex(0xA8C3BCFF), 0.01, 15),    # 0.01% - Blanc nacré
	Ressource.new("Turquoise",      Color.hex(0x40E0D0FF), 0.01, 15),    # 0.01% - Turquoise
	Ressource.new("Grenat",         Color.hex(0x9B111EFF), 0.5, 55),     # 0.5% (silicate commun) - Rouge profond
	Ressource.new("Péridot",        Color.hex(0xB4C424FF), 0.01, 18),    # 0.01% - Vert-jaune
	Ressource.new("Jade",           Color.hex(0x00A86BFF), 0.01, 16),    # 0.01% - Vert jade
	Ressource.new("Lapis-lazuli",   Color.hex(0x26619CFF), 0.01, 14),    # 0.01% - Bleu profond
	
	# ============================================================================
	# CATÉGORIE 11 : MINÉRAUX INDUSTRIELS ET MATÉRIAUX DE CONSTRUCTION
	# Très abondants car forment des massifs rocheux
	# ============================================================================
	Ressource.new("Quartz",         Color.hex(0xFFFFFF99), 5.0, 900),    # 5% (silicate) - Blanc transparent
	Ressource.new("Feldspath",      Color.hex(0xFFE4E1FF), 5.0, 850),    # 5% (silicate) - Rose pâle
	Ressource.new("Mica",           Color.hex(0xD4AF37FF), 5.0, 700),    # 5% (silicate) - Or mat
	Ressource.new("Argile",         Color.hex(0xCD853FFF), 15.0, 1000),  # 15% (surface) - Brun argile
	Ressource.new("Kaolin",         Color.hex(0xFFF5EEFF), 5.0, 650),    # 5% - Blanc crème
	Ressource.new("Gypse",          Color.hex(0xF0F0F0FF), 5.0, 600),    # 5% - Gris blanc
	Ressource.new("Talc",           Color.hex(0xE0F0E0FF), 0.5, 400),    # 0.5% - Vert très pâle
	Ressource.new("Bauxite",        Color.hex(0xD2691EFF), 10.0, 550),   # 10% (altérite Al) - Chocolat
	Ressource.new("Marbre",         Color.hex(0xF8F8FFFF), 2.0, 600),    # 2% - Blanc fantôme
	Ressource.new("Granit",         Color.hex(0x808080FF), 10.0, 800),   # 10% - Gris
	Ressource.new("Ardoise",        Color.hex(0x2F4F4FFF), 2.0, 500),    # 2% - Gris ardoise
	Ressource.new("Grès",           Color.hex(0xF4A460FF), 10.0, 700),   # 10% - Sable
	Ressource.new("Sable",          Color.hex(0xC2B280FF), 15.0, 1000),  # 15% (surface) - Kaki clair
	Ressource.new("Gravier",        Color.hex(0xA0A0A0FF), 15.0, 950),   # 15% (surface) - Gris moyen
	Ressource.new("Basalte",        Color.hex(0x1C1C1CFF), 10.0, 700),   # 10% - Noir
	Ressource.new("Obsidienne",     Color.hex(0x0B0B0BFF), 2.0, 250),    # 2% - Noir brillant
	Ressource.new("Pierre ponce",   Color.hex(0xDCDCDCFF), 2.0, 280),    # 2% - Gris gainsboro
	Ressource.new("Amiante",        Color.hex(0x808000FF), 0.5, 180),    # 0.5% - Olive (dangereux)
	Ressource.new("Vermiculite",    Color.hex(0xDAA520FF), 0.5, 200),    # 0.5% - Or sombre
	Ressource.new("Perlite",        Color.hex(0xEEEEEEFF), 0.5, 220),    # 0.5% - Gris très clair
	Ressource.new("Bentonite",      Color.hex(0xD2B48CFF), 0.5, 300),    # 0.5% - Tan
	Ressource.new("Zéolite",        Color.hex(0xE0FFFFFF), 0.5, 250),    # 0.5% - Cyan clair
	
	# ============================================================================
	# CATÉGORIE 12 : MINÉRAUX SPÉCIAUX ET STRATÉGIQUES
	# ============================================================================
	Ressource.new("Hafnium",        Color.hex(0x4F4F4FFF), 0.0003, 20),  # 0.0003% - Gris foncé
	Ressource.new("Gallium",        Color.hex(0x8470FFFF), 0.0019, 25),  # 0.0019% - Bleu lavande
	Ressource.new("Césium",         Color.hex(0xFFDAB9FF), 0.0003, 15),  # 0.0003% - Pêche
	Ressource.new("Rubidium",       Color.hex(0xE6E6FAFF), 0.009, 35),   # 0.009% - Lavande
	Ressource.new("Hélium",         Color.hex(0xFFFAF0FF), 0.0000008, 80),# 0.0000008% gaz piégé - Blanc floral
	Ressource.new("Terres rares mélangées", Color.hex(0x98FB98FF), 0.01, 60) # 0.01% monazite/bastnäsite - Vert pâle
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
