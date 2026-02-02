extends Node

const ALTITUDE_MAX = 25000

# IDs des types de planètes
const TYPE_TERRAN = 0       # Défaut (Terre)
const TYPE_TOXIC = 1        # Toxique
const TYPE_VOLCANIC = 2     # Volcanique
const TYPE_NO_ATMOS = 3     # Sans Atmosphère
const TYPE_DEAD = 4         # Mort / Irradié
const TYPE_STERILE = 5      # Stérile
const TYPE_GAZEUZE = 6      # Gazeuze (Non utilisé pour l'instant)

# NOTE SUR LES DONNÉES :
# Température : En degrés Celsius (approximatif pour la logique du jeu)
# Précipitation : 0.0 (Sec) à 1.0 (Humide/Saturé)

var BIOMES = [
	# ==========================================================================
	# TYPE 0 : TERRAN (Terre réaliste)
	# ==========================================================================

	# --- OCÉANS & BATHYMÉTRIE ---
	# Plus on descend, plus c'est sombre et froid.
	Biome.new("Abysses", Color.hex(0x050a14FF), Color.hex(0x050a14FF), [-5, 4], [0.0, 1.0], [-ALTITUDE_MAX, -6000], true, [TYPE_TERRAN]),
	Biome.new("Plaine Abyssale", Color.hex(0x0f1e3cFF), Color.hex(0x0f1e3cFF), [-2, 10], [0.0, 1.0], [-6000, -2000], true, [TYPE_TERRAN]),
	Biome.new("Océan Profond", Color.hex(0x1a3666FF), Color.hex(0x1a3666FF), [5, 25], [0.0, 1.0], [-2000, -200], true, [TYPE_TERRAN]),
	Biome.new("Plateau Continental", Color.hex(0x2d5aa3FF), Color.hex(0x2d5aa3FF), [10, 30], [0.0, 1.0], [-200, -50], true, [TYPE_TERRAN]),
	
	# --- CÔTES & EAUX PEU PROFONDES ---
	Biome.new("Récif Corallien", Color.hex(0x00a896FF), Color.hex(0x40e0d0FF), [24, 35], [0.0, 1.0], [-50, -2], true, [TYPE_TERRAN]),
	Biome.new("Lagon Tropical", Color.hex(0x40e0d0FF), Color.hex(0x40e0d0FF), [24, 35], [0.0, 1.0], [-20, 0], true, [TYPE_TERRAN]),
	Biome.new("Fjord Glacé", Color.hex(0x2f4f4fFF), Color.hex(0x2f4f4fFF), [-20, 5], [0.0, 1.0], [-200, 0], true, [TYPE_TERRAN]),
	Biome.new("Littoral / Plage", Color.hex(0xe3d9a6FF), Color.hex(0x8fbc8fFF), [10, 35], [0.0, 1.0], [-5, 5], false, [TYPE_TERRAN]),
	Biome.new("Mangrove (Salée)", Color.hex(0x566e3dFF), Color.hex(0x2e8b57FF), [25, 40], [0.6, 1.0], [-2, 5], true, [TYPE_TERRAN]), # Eau salée/saumâtre
	Biome.new("Delta Fluvial", Color.hex(0x5d76cbFF), Color.hex(0x4ca3ddFF), [15, 35], [0.7, 1.0], [-5, 5], true, [TYPE_TERRAN], true), # Eau douce/saumâtre

	# --- TERRES : CLIMATS FROIDS (Polaires & Alpins) ---
	Biome.new("Calotte Glaciaire", Color.hex(0xf0f8ffFF), Color.hex(0xffffffFF), [-90, -15], [0.2, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_TERRAN]),
	Biome.new("Désert Polaire", Color.hex(0xcddcebFF), Color.hex(0xcddcebFF), [-90, -10], [0.0, 0.2], [0, ALTITUDE_MAX], false, [TYPE_TERRAN]),
	Biome.new("Toundra", Color.hex(0x8a9a5bFF), Color.hex(0x556b2fFF), [-15, 5], [0.2, 0.6], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Toundra Alpine", Color.hex(0x708090FF), Color.hex(0xa9a9a9FF), [-20, 10], [0.0, 1.0], [2500, ALTITUDE_MAX], false, [TYPE_TERRAN]),
	Biome.new("Taïga (Forêt Boréale)", Color.hex(0x2f4f4fFF), Color.hex(0x103025FF), [-10, 15], [0.4, 0.8], [0, 2500], false, [TYPE_TERRAN]),
	Biome.new("Prairie Alpine (Alpage)", Color.hex(0x8cb04eFF), Color.hex(0x658c35FF), [0, 15], [0.4, 0.8], [1500, 3000], false, [TYPE_TERRAN]),
	Biome.new("Forêt de montagne", Color.hex(0x4f8a40FF), Color.hex(0x3f533cFF), [-15, 20], [0.0, 1.0], [300, ALTITUDE_MAX], false, [TYPE_TERRAN]),

	# --- TERRES : CLIMATS TEMPÉRÉS ---
	Biome.new("Forêt Tempérée (Décidue)", Color.hex(0x228b22FF), Color.hex(0x006400FF), [5, 22], [0.4, 0.7], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Forêt de Séquoias", Color.hex(0x5c4033FF), Color.hex(0x2e8b57FF), [10, 20], [0.6, 0.9], [0, 1500], false, [TYPE_TERRAN]), # Humide et tempéré
	Biome.new("Forêt Humide (Rainforest)", Color.hex(0x004225FF), Color.hex(0x013220FF), [10, 25], [0.7, 1.0], [0, 1500], false, [TYPE_TERRAN]),
	Biome.new("Prairie Verdoyante", Color.hex(0x7cfc00FF), Color.hex(0x32cd32FF), [10, 25], [0.3, 0.6], [0, 1500], false, [TYPE_TERRAN]),
	Biome.new("Maquis Méditerranéen", Color.hex(0x808000FF), Color.hex(0x556b2fFF), [15, 30], [0.1, 0.4], [0, 1000], false, [TYPE_TERRAN]),
	Biome.new("Steppes sèches", Color.hex(0xc2b280FF), Color.hex(0x8b4513FF), [-5, 25], [0.1, 0.35], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Steppes tempérées", Color.hex(0xc2b280FF), Color.hex(0x8b4513FF), [-5, 25], [0.1, 0.35], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Marécage Tempéré", Color.hex(0x556b2fFF), Color.hex(0x2f4f4fFF), [10, 25], [0.8, 1.0], [0, 100], true, [TYPE_TERRAN], true), # Eau douce

	# --- TERRES : CLIMATS CHAUDS & ARIDES ---
	Biome.new("Jungle Tropicale", Color.hex(0x006400FF), Color.hex(0x004d00FF), [25, 45], [0.6, 1.0], [0, 1500], false, [TYPE_TERRAN]),
	Biome.new("Bambouseraie", Color.hex(0x76894cFF), Color.hex(0x567d46FF), [20, 35], [0.6, 0.9], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Savane", Color.hex(0xe9ddafFF), Color.hex(0x808000FF), [25, 40], [0.2, 0.5], [0, 2000], false, [TYPE_TERRAN]),
	Biome.new("Brousse (Bush)", Color.hex(0xbdb76bFF), Color.hex(0x6b8e23FF), [25, 40], [0.1, 0.3], [0, 1500], false, [TYPE_TERRAN]),
	Biome.new("Désert semi-aride", Color.hex(0xbe9e5cFF), Color.hex(0xbca46cFF), [25, 50], [0.0, 0.4], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_TERRAN]),
	Biome.new("Désert de Sable", Color.hex(0xedc9afFF), Color.hex(0xd2b48cFF), [30, 60], [0.0, 0.1], [0, 1500], false, [TYPE_TERRAN]),
	Biome.new("Désert Rocheux (Badlands)", Color.hex(0xcd853fFF), Color.hex(0x8b4513FF), [20, 50], [0.0, 0.2], [500, 2500], false, [TYPE_TERRAN]),
	Biome.new("Désert Extrême", Color.hex(0x6e3825FF), Color.hex(0xab986dFF), [70, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false),
	
	# --- EAUX DOUCES INTÉRIEURES (Surface) ---
	Biome.new("Oasis", Color.hex(0x98fb98FF), Color.hex(0x228b22FF), [30, 50], [0.8, 1.0], [-500, 500], true, [TYPE_TERRAN], true), # Eau douce
	Biome.new("Cénote (Gouffre)", Color.hex(0x1e5959FF), Color.hex(0x00ced1FF), [20, 35], [0.5, 1.0], [-1000, 0], true, [TYPE_TERRAN], true), # Eau douce
	Biome.new("Bayou (Marais Chaud)", Color.hex(0x4b5320FF), Color.hex(0x556b2fFF), [25, 35], [0.8, 1.0], [0, 50], true, [TYPE_TERRAN], true), # Eau douce

	# --- RIVIÈRES & LACS (Type 0 - Requis pour river_map) ---
	# Données ajustées : les rivières ont une tolérance large d'altitude et de température
	Biome.new("Rivière", Color.hex(0x4A90D9FF), Color.hex(0x3f5978FF), [-30, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),
	Biome.new("Fleuve", Color.hex(0x3E7FC4FF), Color.hex(0x3f5978FF), [-20, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),
	Biome.new("Affluent", Color.hex(0x6BAAE5FF), Color.hex(0x3e5675FF), [-30, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),
	Biome.new("Lac d'eau douce", Color.hex(0x5BA3E0FF), Color.hex(0x3c5472FF), [0, 45], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),
	Biome.new("Lac gelé", Color.hex(0xd0f0ffFF), Color.hex(0xaecbd6FF), [-50, 0], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),
	Biome.new("Rivière glaciaire", Color.hex(0xa4d8e8FF), Color.hex(0x7caebdFF), [-30, 10], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TERRAN], true, true),


	# ==========================================================================
	# TYPE 1 : TOXIQUE (Vénusien / Pollué)
	# ==========================================================================
	
	# --- AQUATIQUE TOXIQUE ---
	Biome.new("Océan Acide", Color.hex(0x4b6e4bFF), Color.hex(0x2f4f2fFF), [10, 80], [0.0, 1.0], [-ALTITUDE_MAX, -500], true, [TYPE_TOXIC]),
	Biome.new("Lagon de Boue Toxique", Color.hex(0x6b8c42FF), Color.hex(0x556b2fFF), [20, 60], [0.0, 1.0], [-500, 0], true, [TYPE_TOXIC]),

	# --- TERRESTRE TOXIQUE ---
	Biome.new("Désert de Soufre", Color.hex(0xe3e359FF), Color.hex(0xcaca4bFF), [40, 100], [0.0, 0.2], [0, ALTITUDE_MAX], false, [TYPE_TOXIC]),
	Biome.new("Forêt Fongique (Champignons)", Color.hex(0x483d8bFF), Color.hex(0x8a2be2FF), [20, 50], [0.5, 1.0], [0, 2000], false, [TYPE_TOXIC]),
	Biome.new("Plaines de Spores", Color.hex(0x8fbc8fFF), Color.hex(0x2e8b57FF), [10, 40], [0.3, 0.7], [0, 1500], false, [TYPE_TOXIC]),
	Biome.new("Marécages Acides", Color.hex(0x7cfc00FF), Color.hex(0x32cd32FF), [20, 60], [0.8, 1.0], [-100, 500], true, [TYPE_TOXIC]),
	Biome.new("Glacier Vert (Méthane)", Color.hex(0x00ff7fFF), Color.hex(0x00fa9aFF), [-150, -50], [0.0, 1.0], [0, ALTITUDE_MAX], false, [TYPE_TOXIC]),

	# --- RIVIÈRES TOXIQUES ---
	Biome.new("Rivière Acide", Color.hex(0x7fff00FF), Color.hex(0x32cd32FF), [10, 80], [0.1, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TOXIC], true, true),
	Biome.new("Fleuve Radioactif", Color.hex(0x32cd32FF), Color.hex(0x006400FF), [10, 80], [0.2, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TOXIC], true, true),
	Biome.new("Affluent Contaminé", Color.hex(0x90ee90FF), Color.hex(0x228b22FF), [10, 80], [0.1, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TOXIC], true, true),
	Biome.new("Lac d'Acide", Color.hex(0x00ff00FF), Color.hex(0x008000FF), [10, 90], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_TOXIC], true, true),


	# ==========================================================================
	# TYPE 2 : VOLCANIQUE (Mustafar / Io)
	# ==========================================================================

	# --- AQUATIQUE (LAVE) ---
	# Note : "L'océan" ici est de la lave ou du magma très chaud
	Biome.new("Océan de Magma", Color.hex(0xff4500FF), Color.hex(0x8b0000FF), [800, 2000], [0.0, 1.0], [-ALTITUDE_MAX, -1000], true, [TYPE_VOLCANIC]),
	Biome.new("Mer de Lave en Fusion", Color.hex(0xff8c00FF), Color.hex(0xff0000FF), [600, 1500], [0.0, 1.0], [-1000, 0], true, [TYPE_VOLCANIC]),
	Biome.new("Croûte Basaltique Refroidie", Color.hex(0x1c1c1cFF), Color.hex(0x2f2f2fFF), [100, 400], [0.0, 1.0], [-200, 100], false, [TYPE_VOLCANIC]),

	# --- TERRESTRE VOLCANIQUE ---
	Biome.new("Plaines de Cendres", Color.hex(0x696969FF), Color.hex(0x808080FF), [20, 200], [0.0, 0.3], [0, 2000], false, [TYPE_VOLCANIC]),
	Biome.new("Champs de Geysers", Color.hex(0xd3d3d3FF), Color.hex(0xf5f5f5FF), [100, 300], [0.5, 1.0], [500, 1500], true, [TYPE_VOLCANIC]),
	Biome.new("Volcan Actif (Sommet)", Color.hex(0x8b0000FF), Color.hex(0x000000FF), [200, 1000], [0.0, 1.0], [2000, ALTITUDE_MAX], false, [TYPE_VOLCANIC]),
	Biome.new("Obsidienne (Verre Volcanique)", Color.hex(0x000000FF), Color.hex(0x191970FF), [50, 200], [0.0, 1.0], [1000, 3000], false, [TYPE_VOLCANIC]),
	Biome.new("Désert de Soufre Jaune", Color.hex(0xffff00FF), Color.hex(0xbdb76bFF), [50, 150], [0.0, 0.2], [500, 2500], false, [TYPE_VOLCANIC]),

	# --- RIVIÈRES DE LAVE (Requis pour river_map) ---
	Biome.new("Rivière de Lave", Color.hex(0xff4500FF), Color.hex(0xcd3700FF), [300, 1500], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_VOLCANIC], true, true),
	Biome.new("Fleuve de Magma", Color.hex(0xff0000FF), Color.hex(0x8b0000FF), [400, 2000], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_VOLCANIC], true, true),
	Biome.new("Lac de Lave", Color.hex(0xd2691eFF), Color.hex(0x8b4513FF), [300, 1200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_VOLCANIC], true, true),


	# ==========================================================================
	# TYPE 3 : SANS ATMOSPHÈRE (Lune / Mercure)
	# ==========================================================================

	# Pas d'eau liquide, pas de végétation réelle, contrastes extrêmes
	Biome.new("Mare (Mer Lunaire - Basalte)", Color.hex(0x1a1a1aFF), Color.hex(0x1a1a1aFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, -1000], false, [TYPE_NO_ATMOS]),
	Biome.new("Régolithe Gris", Color.hex(0x808080FF), Color.hex(0x808080FF), [-200, 200], [0.0, 1.0], [-1000, 1000], false, [TYPE_NO_ATMOS]),
	Biome.new("Cratère d'Impact", Color.hex(0x404040FF), Color.hex(0x2f2f2fFF), [-200, 200], [0.0, 1.0], [-2000, -500], false, [TYPE_NO_ATMOS]),
	Biome.new("Hauts Plateaux Lunaires", Color.hex(0xd3d3d3FF), Color.hex(0xd3d3d3FF), [-200, 200], [0.0, 1.0], [1000, ALTITUDE_MAX], false, [TYPE_NO_ATMOS]),
	Biome.new("Glace de Cratère Polaire", Color.hex(0xe0ffffFF), Color.hex(0xe0ffffFF), [-273, -150], [0.0, 1.0], [-2000, 0], false, [TYPE_NO_ATMOS]), # Glace éternelle à l'ombre

	# ==========================================================================
	# TYPE 4 : MORT / POST-APOCALYPTIQUE (Fallout / Mars terraformé échoué)
	# ==========================================================================
	
	# --- AQUATIQUE MORT ---
	Biome.new("Océan Mort (Gris)", Color.hex(0x464646FF), Color.hex(0x2f4f4fFF), [-10, 40], [0.0, 1.0], [-ALTITUDE_MAX, -200], true, [TYPE_DEAD]),
	Biome.new("Marécage Luminescent", Color.hex(0x00fa9aFF), Color.hex(0x2e8b57FF), [10, 30], [0.0, 1.0], [-200, 50], true, [TYPE_DEAD], true, true),
	
	# --- TERRESTRE MORT ---
	Biome.new("Terres Désolées (Wasteland)", Color.hex(0x5d5d5dFF), Color.hex(0x4b3621FF), [-20, 50], [0.0, 0.3], [0, 2000], false, [TYPE_DEAD]),
	Biome.new("Désert de Sel", Color.hex(0xfffaf0FF), Color.hex(0xffe4e1FF), [0, 60], [0.0, 0.1], [-500, 500], false, [TYPE_DEAD]),
	Biome.new("Forêt Morte (Arbres Noirs)", Color.hex(0x2f2f2fFF), Color.hex(0x000000FF), [-10, 40], [0.2, 0.6], [0, 1500], false, [TYPE_DEAD]),
	Biome.new("Cratère Nucléaire", Color.hex(0x2f4f2fFF), Color.hex(0x00ff00FF), [-50, 100], [0.0, 1.0], [-500, 500], false, [TYPE_DEAD]),
	Biome.new("Plaines de Cendres Grises", Color.hex(0x696969FF), Color.hex(0x808080FF), [-30, 30], [0.0, 0.2], [0, 3000], false, [TYPE_DEAD]),

	# --- RIVIÈRES MORTES ---
	Biome.new("Rivière de Boue", Color.hex(0x8b4513FF), Color.hex(0x5c4033FF), [-10, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_DEAD], true, true),
	Biome.new("Fleuve Pollué", Color.hex(0x556b2fFF), Color.hex(0x2f4f2fFF), [-10, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_DEAD], true, true),
	Biome.new("Lac Irradié", Color.hex(0xadff2fFF), Color.hex(0x7cfc00FF), [-10, 50], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], true, [TYPE_DEAD], true, true),

	# ==========================================================================
	# TYPE 5 : STÉRILE
	# ==========================================================================

	# Pas d'eau liquide, pas de végétation réelle, contrastes extrêmes
	Biome.new("Désert Stérile", Color.hex(0x7f7f7fFF), Color.hex(0x7f7f7fFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_STERILE]),
	Biome.new("Plaine Rocheuse", Color.hex(0x5a5a5aFF), Color.hex(0x5a5a5aFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_STERILE]),
	Biome.new("Montagnes Rocheuses", Color.hex(0x4a4a4aFF), Color.hex(0x4a4a4aFF), [-200, 200], [0.0, 1.0], [5000, ALTITUDE_MAX], false, [TYPE_STERILE]),
	Biome.new("Vallées Profondes", Color.hex(0x3a3a3aFF), Color.hex(0x3a3a3aFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, -5000], false, [TYPE_STERILE]),
	Biome.new("Désert de Pierre", Color.hex(0x6a6a6aFF), Color.hex(0x6a6a6aFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_STERILE]),
	Biome.new("Glaciers Stériles", Color.hex(0xccccccFF), Color.hex(0xccccccFF), [-200, -50], [0.0, 1.0], [0, ALTITUDE_MAX], false, [TYPE_STERILE]),
	Biome.new("Plateaux Érodés", Color.hex(0x5f5f5fFF), Color.hex(0x5f5f5fFF), [-200, 200], [0.0, 1.0], [2000, 8000], false, [TYPE_STERILE]),
	Biome.new("Cratères Secs", Color.hex(0x4f4f4fFF), Color.hex(0x4f4f4fFF), [-200, 200], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_STERILE]),
	
	# ==========================================================================
	# TYPE 6 : GAZEUSE
	# ==========================================================================

	# Pas de surface solide ni d'eau liquide, biomes non applicables
	Biome.new("Atmosphère Gazeuse", Color.hex(0x000000FF), Color.hex(0x000000FF), [-273, 500], [0.0, 1.0], [-ALTITUDE_MAX, ALTITUDE_MAX], false, [TYPE_GAZEUZE])

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

	0: Color.hex(0xd5eaf6FF),

	20: Color.hex(0x95b1abFF),
	50: Color.hex(0x90ada6FF),
	100: Color.hex(0x8aa8a2FF),
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
	0.4: Color.hex(0x521ac1FF),
	0.5: Color.hex(0x2c1bc5FF),
	0.6: Color.hex(0x1d33d3F),
	0.7: Color.hex(0x2439dbFF),
	0.8: Color.hex(0x1c49ceFF),
	0.9: Color.hex(0x1f4fe0FF),
	1.0: Color.hex(0x315de3FF)
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

# ============================================================================
# SYSTÈME DE BIOMES GPU
# ============================================================================
# Construit un buffer SSBO pour les biomes GPU (exclut rivières et calottes)
# Structure alignée std430 pour GLSL :
# - header : biome_count (uint), padding x3 (12 bytes)
# - BiomeData[] : couleur (vec4), temp_min/max, humid_min/max, elev_min/max, water_need, planet_mask
# ============================================================================

## Filtre les biomes pour le GPU (exclut rivières et calottes glaciaires)
func get_biomes_for_gpu() -> Array:
	var filtered = []
	for biome in BIOMES:
		# Exclure les rivières
		if biome.isRiver():
			continue
		filtered.append(biome)
	return filtered

## Construit un PackedByteArray aligné std430 pour le SSBO des biomes
## Structure par biome (32 bytes alignés):
## - color: vec4 (16 bytes) - RGBA couleur du biome
## - temp_min: float (4 bytes)
## - temp_max: float (4 bytes)
## - humid_min: float (4 bytes)
## - humid_max: float (4 bytes)
## - elev_min: float (4 bytes)
## - elev_max: float (4 bytes)
## - water_need: uint (4 bytes)
## - planet_type_mask: uint (4 bytes)
## Total: 48 bytes par biome (aligné sur 16 bytes pour std430)
func build_biomes_gpu_buffer() -> PackedByteArray:
	var filtered_biomes = get_biomes_for_gpu()
	var biome_count = filtered_biomes.size()
	
	# Header: biome_count (4 bytes) + 3x padding (12 bytes) = 16 bytes
	# Biomes: 48 bytes par biome
	var header_size = 16
	var biome_size = 48
	var total_size = header_size + biome_count * biome_size
	
	var buffer = PackedByteArray()
	buffer.resize(total_size)
	buffer.fill(0)
	
	# Écrire le header
	buffer.encode_u32(0, biome_count)
	# padding1, padding2, padding3 déjà à 0
	
	# Écrire chaque biome
	var offset = header_size
	for biome in filtered_biomes:
		# Couleur (vec4 - 16 bytes)
		var color = biome.get_couleur()
		buffer.encode_float(offset + 0, color.r)
		buffer.encode_float(offset + 4, color.g)
		buffer.encode_float(offset + 8, color.b)
		buffer.encode_float(offset + 12, color.a)
		
		# Température min/max (8 bytes)
		var temp = biome.get_interval_temp()
		buffer.encode_float(offset + 16, float(temp[0]))
		buffer.encode_float(offset + 20, float(temp[1]))
		
		# Humidité min/max (8 bytes)
		var precip = biome.get_interval_precipitation()
		buffer.encode_float(offset + 24, precip[0])
		buffer.encode_float(offset + 28, precip[1])
		
		# Élévation min/max (8 bytes)
		var elev = biome.get_interval_elevation()
		buffer.encode_float(offset + 32, float(elev[0]))
		buffer.encode_float(offset + 36, float(elev[1]))
		
		# water_need (4 bytes)
		var water_need: int = 1 if biome.get_water_need() else 0
		buffer.encode_u32(offset + 40, water_need)
		
		# planet_type_mask (4 bytes) - bitmask des types valides
		var planet_types = biome.get_type_planete()
		var mask: int = 0
		for pt in planet_types:
			mask |= (1 << pt)
		buffer.encode_u32(offset + 44, mask)
		
		offset += biome_size
	
	print("[Enum] ✅ Buffer biomes GPU construit: ", biome_count, " biomes, ", total_size, " bytes")
	return buffer

## Retourne le nombre de biomes filtrés pour le GPU
func get_biome_gpu_count() -> int:
	return get_biomes_for_gpu().size()

## Retourne l'ID GPU d'un biome par son nom (pour debug)
func get_biome_gpu_id_by_name(biome_name: String) -> int:
	var filtered = get_biomes_for_gpu()
	for i in range(filtered.size()):
		if filtered[i].get_nom() == biome_name:
			return i
	return -1

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
