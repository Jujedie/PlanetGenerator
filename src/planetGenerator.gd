extends Node

class_name PlanetGenerator

# Dimensions de l'image
var width: int = 512
var height: int = 256

# Paramètres de génération
var avg_temperature: float = 15.0
var water_elevation: float = 0.3  # entre 0 et 1
var avg_precipitation: float = 0.5  # entre 0 et 1

# Images générées
var elevation_map: Image
var biome_map: Image
var terrain_map: Image
var glacier_map: Image
var geo_map: Image

# Génère la planète
func generate_planet():
    elevation_map = generate_elevation_map()
    biome_map = generate_biome_map(elevation_map)
    terrain_map = generate_terrain_map(elevation_map)
    glacier_map = generate_glacier_map(elevation_map, avg_temperature)
    geo_map = generate_geopolitical_map()

    # Sauvegarde les images
    save_image(elevation_map, "elevation_map.png")
    save_image(biome_map, "biome_map.png")
    save_image(terrain_map, "terrain_map.png")
    save_image(glacier_map, "glacier_map.png")
    save_image(geo_map, "geo_map.png")

# Génére la carte d'élévation (bruit de Perlin + eau)
func generate_elevation_map() -> Image:
    var img = Image.create(width, height, false, Image.FORMAT_RGB8)
    var noise = FastNoiseLite.new()
    noise.seed = randi()
    noise.frequency = 4.0 / float(width)  # fréquence ajustée à la taille
    for x in width:
        for y in height:
            var value = noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
            var color = Color(value, value, value)
            if value <= water_elevation:
                color = Color(0, 0, 1)  # Océan
            img.set_pixel(x, y, color)
    return img
# Biomes en fonction de l'altitude, température et précipitations
func generate_biome_map(elevation: Image) -> Image:
    var img = elevation.duplicate()
    for x in width:
        for y in height:
            var height_val = elevation.get_pixel(x, y).r
            var biome_color: Color = Color.GREEN
            if height_val < water_elevation:
                biome_color = Color(0, 0, 1) # océan
            elif avg_temperature < 0.0:
                biome_color = Color(1, 1, 1) # neige
            elif avg_precipitation < 0.3:
                biome_color = Color(0.9, 0.8, 0.3) # désert
            img.set_pixel(x, y, biome_color)
    return img

# Carte de terrain stylisée
func generate_terrain_map(elevation: Image) -> Image:
    var img = elevation.duplicate()
    for x in width:
        for y in height:
            var val = elevation.get_pixel(x, y).r
            var color = Color(val, val * 0.7, val * 0.4)
            img.set_pixel(x, y, color)
    return img

# Génère les glaciers selon température et élévation
func generate_glacier_map(elevation: Image, temperature: float) -> Image:
    var img = Image.create(width, height, false, Image.FORMAT_RGB8)
    for x in width:
        for y in height:
            var lat = float(y) / height
            var cold_zone = abs(lat - 0.5) > 0.4 and temperature < 0
            if cold_zone and elevation.get_pixel(x, y).r > water_elevation:
                img.set_pixel(x, y, Color(0.9, 0.9, 1.0))
            else:
                img.set_pixel(x, y, Color(0, 0, 0))
    return img

# Génère une carte géopolitique simple basée sur zones colorées aléatoirement
func generate_geopolitical_map() -> Image:
    var img = Image.create(width, height, false, Image.FORMAT_RGB8)
    var rng = RandomNumberGenerator.new()
    rng.randomize()
    var colors = [Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW, Color.ORANGE]
    for x in width:
        for y in height:
            var id = int(floor(float(x) / 100)) % colors.size()
            img.set_pixel(x, y, colors[id])
    return img

# Sauvegarde une image en PNG
func save_image(image: Image, nom: String):
    var img_path = "user://" + nom
    image.save_png(img_path)
    print("Saved: ", img_path)
