extends RefCounted

class_name PlanetGenerator

# TO DO REMOVE INSTANCE PARAMETERS FROM INSTANCE METHODS

var nom: String
var rayon_planetaire : int

# Paramètres de génération
var avg_temperature  : float
var water_elevation  : int    # l'élévation de l'eau par rapport à la terre [-oo,+oo]
var avg_precipitation: float  # entre 0 et 1

# Images générées
var elevation_map    : Image
var precipitation_map: Image
var temperature_map  : Image
var water_map   : Image
var biome_map   : Image
var geopo_map   : Image

func _init(nom_param: String, rayon: int = 512, avg_temperature_param: float = 15.0, water_elevation_param: int = 0, avg_precipitation_param: float = 0.5):
    self.nom = nom_param
    
    self.rayon_planetaire  = rayon

    self.avg_temperature = avg_temperature_param
    self.water_elevation = water_elevation_param
    self.avg_precipitation = avg_precipitation_param

    generate_planet()

# Génère la planète
func generate_planet():
    self.elevation_map = generate_elevation_map()
    self.precipitation_map = generate_precipitation_map()
    self.temperature_map = generate_temperature_map()
    self.water_map = generate_water_map()
    self.biome_map = generate_biome_map()
    self.geopo_map = generate_geopolitical_map()

    # Sauvegarde les images
    save_image(self.elevation_map, "elevation_map.png")
    save_image(self.precipitation_map, "precipitation_map.png")
    save_image(self.temperature_map, "temperature_map.png")
    save_image(self.biome_map, "biome_map.png")
    save_image(self.geopo_map, "geopo_map.png")

# Génère la carte d'élévation (bruit fractal pour des montagnes réalistes)
func generate_elevation_map() -> Image:
    var circonference = int(self.rayon_planetaire * 2 * PI)
    var img = Image.create(circonference, circonference / 2, false, Image.FORMAT_RGB8)

    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.noise_type = FastNoiseLite.TYPE_PERLIN
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.frequency = 2.0 / float(circonference)
    noise.fractal_octaves = 8
    noise.fractal_gain = 0.75
    noise.fractal_lacunarity = 2.0

    for x in circonference:
        for y in circonference / 2:
            var value = noise.get_noise_2d(float(x), float(y))
            var elevation = ceil(value * 2500.0)
            var color = Couleurs.getElevationColor(elevation)
            img.set_pixel(x, y, color)

    return img

# Génère la carte de précipitations (bruit de turbulence pour des variations météorologiques)
func generate_precipitation_map() -> Image:
    var circonference = self.rayon_planetaire * 2 * PI
    var img = Image.create(circonference, circonference / 2, false, Image.FORMAT_RGB8)

    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = 1.0 / float(circonference)
    noise.fractal_octaves = 4
    noise.fractal_gain = 0.5
    noise.fractal_lacunarity = 0.5

    for x in circonference:
        for y in circonference / 2:

            var value = noise.get_noise_2d(float(x), float(y))
            value = clamp(value, 0.0, 1.0)
            img.set_pixel(x, y, Color(value, value, value))

    return img

func generate_temperature_map() -> Image:
    var circonference = self.rayon_planetaire*2*PI
    var img = Image.create(circonference, circonference/2, false, Image.FORMAT_RGB8)
    
    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = 1.0 / float(circonference)
    noise.fractal_octaves = 4
    noise.fractal_gain = 0.5
    noise.fractal_lacunarity = 0.5

    for x in circonference:
        for y in circonference/2:

            var lat  = float(y) / circonference/2
            var temp = self.avg_temperature + (noise.get_noise_2d(float(x), float(y)) * 20.0) - (lat * 20.0)
            var color= Couleurs.getColorByTemperature(temp)
            img.set_pixel(x, y, color)

    return img

# Carte de terrain stylisée
func generate_water_map() -> Image:
    var circonference = self.rayon_planetaire*2*PI
    var img = Image.create(circonference, circonference/2, false, Image.FORMAT_RGB8)
    
    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.frequency = 1.0 / float(circonference)
    noise.fractal_octaves = 4
    noise.fractal_gain = 0.5
    noise.fractal_lacunarity = 0.5

    for x in circonference:
        for y in circonference/2:

            var value = noise.get_noise_2d(float(x), float(y))
            value = clamp(value, 0.0, 1.0)

            var elevation_val = Couleurs.getElevationViaColor(self.elevation_map.get_pixel(x, y))
            if elevation_val <= self.water_elevation and value < 0.5:
                img.set_pixel(x, y, Color.hex(0xFFFFFF))
            else:
                img.set_pixel(x, y, Color.hex(0x000000))

    return img

# Génère la carte des biomes en fonction de l'élévation, température et précipitations
func generate_biome_map() -> Image:
    var circonference = self.rayon_planetaire*2*PI
    var img = Image.create(circonference, circonference/2, false, Image.FORMAT_RGB8)
    
    for x in circonference:
        for y in circonference/2:

            var elevation_val = Couleurs.getElevationViaColor(self.elevation_map.get_pixel(x, y))
            var precipitation_val = self.precipitation_map.get_pixel(x, y).r
            var temperature_val = Couleurs.getTemperatureViaColor(self.temperature_map.get_pixel(x, y))
            var is_water = self.water_map.get_pixel(x, y).r == 1.0

            var biome_color = Couleurs.getBiomeColor(elevation_val, precipitation_val, temperature_val, is_water)
            img.set_pixel(x, y, biome_color)

    return img

# Génère une carte géopolitique simple basée sur zones colorées aléatoirement
func generate_geopolitical_map() -> Image:
    var circonference = self.rayon_planetaire*2*PI
    var img = Image.create(circonference, circonference/2, false, Image.FORMAT_RGB8)
    var rng = RandomNumberGenerator.new()
    rng.randomize()
    var colors = [Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW, Color.ORANGE]

    for x in circonference:
        for y in circonference/2:

            var id = int(floor(float(x) / 100)) % colors.size()
            img.set_pixel(x, y, colors[id])

    return img

# Sauvegarde une image en PNG
static func save_image(image: Image, file_name: String):
    var img_path = "user://" + file_name
    image.save_png(img_path)
    print("Saved: ", img_path)
