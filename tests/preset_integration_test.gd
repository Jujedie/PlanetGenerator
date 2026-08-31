extends Node

## End-to-end integration test using a real preset exported by the standalone
## Planet Generator application. Unlike addon_contract_test.gd, this test
## actually starts the GPU generation pipeline.

const PRESET_PATH := "res://addons/planet_generator/tests/fixtures/test.planetGeneratorParam"
const OUTPUT_PARENT := "user://planet_generator/preset_integration_test"

var _failures: Array[String] = []
var _last_phase: String = ""
var _last_percent_bucket: int = -1


func _ready() -> void:
    await _run_test()


func _run_test() -> void:
    print("[Planet Generator Addon] real-preset integration test: START")
    print("[Planet Generator Addon] preset: %s" % PRESET_PATH)

    _check(FileAccess.file_exists(PRESET_PATH), "uploaded standalone preset fixture must exist")
    _check(PlanetGeneratorService.is_runtime_available(), "PlanetGeneratorServiceRuntime autoload must be available")

    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _fail("No RenderingDevice is available. Run this test with Forward+ or Mobile, not Compatibility.")
        _finish()
        return

    var spec := PlanetGeneratorService.load_preset(PRESET_PATH)
    _check(spec != null, "PlanetGeneratorService.load_preset() must import the uploaded .planetGeneratorParam")
    if spec == null:
        _finish()
        return

    _check(spec.template != null, "imported preset must contain a PlanetGenerationTemplate")
    if spec.template == null:
        _finish()
        return

    # Values taken from the exact uploaded test.planetGeneratorParam fixture.
    _check(is_equal_approx(spec.template.avg_temperature, 21.0), "preset avg_temperature must be 21.0")
    _check(is_equal_approx(spec.template.planet_radius, 150.0), "preset planet_radius must be 150.0 km")
    _check(spec.template.planet_type == 0, "preset planet_type must be Terran (0)")
    _check(is_equal_approx(spec.template.ocean_ratio, 55.0), "preset ocean_ratio must be 55.0")
    _check(spec.template.seed == 0, "preset seed must remain 0 before compilation (random seed request)")
    _check(spec.export_preset == "standard", "standalone _ui.export_preset must remain 'standard'")

    spec.runtime_profile = PlanetGenerationSpec.PROFILE_RUNTIME
    spec.output_root = OUTPUT_PARENT
    spec.output_mode = PlanetGenerationSpec.OUTPUT_UNIQUE_SUBDIRECTORY
    spec.export_runtime_query_data = true

    var compiled := spec.compile()
    _check(bool(compiled.get("ok", false)), "uploaded preset must compile as a PlanetGenerationSpec")
    if not bool(compiled.get("ok", false)):
        print("[Planet Generator Addon] compile errors: %s" % str(compiled.get("errors", [])))
        _finish()
        return

    var params: Dictionary = compiled.get("params", {}) as Dictionary
    var expected_dimensions := Vector2i(752, 376)
    _check(params.get("resolution", Vector2i.ZERO) == expected_dimensions,
        "150 km preset must compile to the canonical 752x376 grid")
    _check(str(params.get("export_preset", "")) == "standard",
        "compiled generation must preserve standalone export preset 'standard'")
    _check(bool(params.get("export_runtime_query_data", false)),
        "runtime query-data export must be enabled for the integration test")
    _check(int(params.get("seed", 0)) != 0,
        "seed=0 preset must receive a concrete randomized generation seed during compilation")

    if not _failures.is_empty():
        _finish()
        return

    print("[Planet Generator Addon] preset import/compile: PASS")
    print("[Planet Generator Addon] starting real GPU generation...")

    # Pass the spec itself so this tests the exact public service route used by
    # consuming games. generate_planet() compiles a duplicate of the spec and
    # runs asynchronously.
    var job := PlanetGeneratorService.generate_planet(spec)
    _check(job != null, "generate_planet() must return a PlanetGenerationJob")
    if job == null:
        _finish()
        return

    job.progress.connect(_on_generation_progress)
    var result := await job.wait_for_result()

    _check(job.succeeded(), "generation job must complete successfully")
    if result == null:
        _fail("generation returned no PlanetGenerationResult; job error=%s" % str(job.error))
        _finish()
        return

    print("[Planet Generator Addon] generated output: %s" % result.output_root)

    _check(DirAccess.dir_exists_absolute(result.output_root), "generated output directory must exist")
    _check(FileAccess.file_exists(result.output_root.path_join("planet_project.json")),
        "planet_project.json must be exported")
    _check(result.get_grid_dimensions() == expected_dimensions,
        "generated result must expose the canonical 752x376 grid")
    _check(result.has_runtime_data(), "generated result must contain exact runtime query data")

    var runtime_layers := result.get_runtime_data_layers()
    for required_layer in [
        "surface_elevation_m",
        "temperature_c",
        "precipitation",
        "biome_id",
        "water_type",
        "region_id",
        "ocean_region_id",
    ]:
        _check(runtime_layers.has(required_layer), "runtime layer must exist: %s" % required_layer)

    var sample_cells := [
        Vector2i(0, 0),
        Vector2i(expected_dimensions.x / 4, expected_dimensions.y / 2),
        Vector2i(expected_dimensions.x / 2, expected_dimensions.y / 2),
        Vector2i(expected_dimensions.x - 1, expected_dimensions.y - 1),
    ]
    for cell in sample_cells:
        _check_cell_query(result, cell)

    # Verify persistence/reload, not only the in-memory result returned by the
    # generation job.
    var reopened := PlanetGeneratorService.load_planet(result.output_root)
    _check(reopened != null, "generated planet must reopen through PlanetGeneratorService.load_planet()")
    if reopened != null:
        _check(reopened.has_runtime_data(), "reopened planet must retain runtime query data")
        _check_cell_query(reopened, Vector2i(expected_dimensions.x / 2, expected_dimensions.y / 2))
        reopened.clear_caches()

    var direct := PlanetGeneratorService.query_planet_cell(
        result.output_root,
        Vector2i(expected_dimensions.x / 2, expected_dimensions.y / 2)
    )
    _check(bool(direct.get("available", false)), "direct path cell query must succeed on generated planet")
    _check(bool(direct.get("runtime_data_available", false)),
        "direct path cell query must use persisted runtime data")

    result.clear_caches()
    _finish()


func _check_cell_query(result: PlanetGenerationResult, cell: Vector2i) -> void:
    var data := result.get_cell_data(cell)
    _check(bool(data.get("available", false)), "cell query available at %s" % str(cell))
    _check(bool(data.get("runtime_data_available", false)), "runtime cell data available at %s" % str(cell))

    var height := result.get_height_at(cell)
    var surface := result.get_surface_elevation_at(cell)
    var temperature := result.get_temperature_at(cell)
    var precipitation := result.get_precipitation_at(cell)

    _check(_is_finite_number(height), "finite sea-relative height at %s" % str(cell))
    _check(_is_finite_number(surface), "finite surface elevation at %s" % str(cell))
    _check(_is_finite_number(temperature), "finite temperature at %s" % str(cell))
    _check(_is_finite_number(precipitation), "finite precipitation at %s" % str(cell))

    var water_type := result.get_water_type_at(cell)
    _check(water_type in [
        PlanetGenerationResult.WATER_LAND,
        PlanetGenerationResult.WATER_SALTWATER,
        PlanetGenerationResult.WATER_FRESHWATER,
    ], "valid water type at %s" % str(cell))

    # Biome/region IDs may legitimately be -1 for water/no-data cells, so the
    # integration contract checks API shape and readability rather than forcing
    # a particular generated biome at a random-seed coordinate.
    _check(data.has("biome_id"), "cell data contains biome_id at %s" % str(cell))
    _check(data.has("biome_name"), "cell data contains biome_name at %s" % str(cell))
    _check(data.has("region_id"), "cell data contains region_id at %s" % str(cell))
    _check(data.has("ocean_region_id"), "cell data contains ocean_region_id at %s" % str(cell))

    print("[Planet Generator Addon] sample %s -> height=%.2fm temp=%.2fC precip=%.4f biome=%s water=%s" % [
        str(cell),
        height,
        temperature,
        precipitation,
        result.get_biome_name_at(cell),
        str(result.get_water_at(cell).get("name", "unknown")),
    ])


func _on_generation_progress(phase: String, _completed: int, _total: int, ratio: float) -> void:
    var percent := clampi(int(round(ratio * 100.0)), 0, 100)
    var bucket := int(percent / 10)
    if phase != _last_phase or bucket != _last_percent_bucket:
        _last_phase = phase
        _last_percent_bucket = bucket
        print("[Planet Generator Addon] generation: %s %d%%" % [phase, percent])


func _is_finite_number(value: float) -> bool:
    return not is_nan(value) and not is_inf(value)


func _check(condition: bool, message: String) -> void:
    if condition:
        return
    _fail(message)


func _fail(message: String) -> void:
    _failures.append(message)
    push_error("[Planet Generator Addon] " + message)


func _finish() -> void:
    if _failures.is_empty():
        print("[Planet Generator Addon] real-preset integration test: PASS")
        get_tree().quit(0)
        return

    print("[Planet Generator Addon] real-preset integration test: FAIL (%d failure(s))" % _failures.size())
    for failure in _failures:
        push_error("[Planet Generator Addon] " + failure)
    get_tree().quit(1)
