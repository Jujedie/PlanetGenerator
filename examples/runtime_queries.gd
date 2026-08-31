extends Node

func inspect_planet(path: String, cell: Vector2i) -> void:
    var planet := PlanetGeneratorService.load_planet(path)
    if planet == null:
        push_error("Could not load Planet Generator output.")
        return

    print("Grid: ", planet.get_grid_dimensions())
    print("Runtime data: ", planet.has_runtime_data())
    print("Height m: ", planet.get_height_at(cell))
    print("Temperature C: ", planet.get_temperature_at(cell))
    print("Precipitation proxy: ", planet.get_precipitation_at(cell))
    print("Biome: ", planet.get_biome_name_at(cell))
    print("Water: ", planet.get_water_at(cell))
    print("Land region: ", planet.get_region_id_at(cell))
    print("Ocean region: ", planet.get_ocean_region_id_at(cell))
    print("All cell data: ", planet.get_cell_data(cell))
