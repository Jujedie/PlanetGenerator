extends Node

func _ready() -> void:
    var spec := PlanetGeneratorService.load_preset(
        "res://addons/planet_generator/tests/fixtures/test.planetGeneratorParam"
    )
    if spec == null:
        push_error("Could not load Planet Generator preset.")
        return

    # Standalone presets preserve their export policy; override after loading.
    spec.export_preset = "complete"
    spec.export_runtime_query_data = true
    spec.output_root = "user://planet_generator/examples/complete_resource_export"
    spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

    var job := PlanetGeneratorService.generate_planet(spec)
    job.progress.connect(
        func(phase: String, _completed: int, _total: int, ratio: float):
            print("[Planet Generator] %s %.1f%%" % [phase, ratio * 100.0])
    )

    var result := await job.wait_for_result()
    if result == null:
        push_error("Generation failed: %s" % [job.error])
        return

    print("Output: ", result.output_root)
    print("Iron map: ", result.has_layer("fer_map"))
    print("Petroleum map: ", result.has_layer("petrole_map"))

    var size := result.get_grid_dimensions()
    var cell := Vector2i(size.x / 2, size.y / 2)
    print(result.get_cell_data(cell))
