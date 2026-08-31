extends Node

func _ready() -> void:
    var template := PlanetGeneratorService.create_template("Earth-like")
    template.planet_name = "Addon Example"
    template.seed = 123456

    var spec := PlanetGenerationSpec.from_template(template)
    spec.runtime_profile = PlanetGenerationSpec.PROFILE_RUNTIME

    var job := PlanetGeneratorService.generate_planet(spec)
    job.progress.connect(_on_generation_progress)
    var result := await job.wait_for_result()

    if result == null:
        push_error("Planet generation failed: %s" % [job.error])
        return

    print("Planet created in ", result.output_root)
    print("Layers: ", result.get_layer_keys())

    if result.has_runtime_data():
        var cell := Vector2i(result.get_grid_dimensions().x / 2, result.get_grid_dimensions().y / 2)
        var data := result.get_cell_data(cell)
        print("Cell ", cell, ": ", data)
        print("Height (m above/below sea level): ", result.get_height_at(cell))
        print("Biome: ", result.get_biome_at(cell).get("display_name", "unknown"))

func _on_generation_progress(phase: String, completed: int, total: int, ratio: float) -> void:
    print("%s %d/%d (%.1f%%)" % [phase, completed, total, ratio * 100.0])
