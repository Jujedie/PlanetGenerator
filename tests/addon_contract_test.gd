extends Node

var _failures: Array[String] = []

func _ready() -> void:
    _check(PlanetGeneratorService.get_api_version() == 2, "API version must be 2")
    _check(PlanetGeneratorService.is_runtime_available(), "PlanetGeneratorServiceRuntime autoload must be available")
    _check(PlanetGeneratorService.get_runtime() != null, "public PlanetGeneratorService facade must resolve its runtime")
    _check(not PlanetGeneratorService.get_version().is_empty(), "addon version must be present")
    _check(PGAddonInfo.UPSTREAM_VERSION == "3.1.0", "addon must report standalone core 3.1.0")
    _check(PGAddonInfo.SOURCE_COMMIT == "76c1513c49539716f541dac67294ce29479b57de",
        "addon must report the synchronized standalone commit")

    if RenderingServer.get_rendering_device() == null:
        print("[Planet Generator Addon] WARNING: no global RenderingDevice. Contract tests can pass, but GPU generation requires Forward+ or Mobile rather than Compatibility.")

    var capabilities := PlanetGeneratorService.get_capabilities()
    _check(bool(capabilities.get("planet_generation", false)), "planet generation capability")
    _check(bool(capabilities.get("serializable_templates", false)), "template capability")
    _check(bool(capabilities.get("standalone_preset_import", false)), "standalone preset import capability")
    _check(bool(capabilities.get("exact_output_directory", false)), "exact output directory capability")
    _check(bool(capabilities.get("typed_cell_queries", false)), "typed cell-query capability")
    _check(bool(capabilities.get("runtime_query_data", false)), "runtime query-data capability")
    _check(bool(capabilities.get("direct_path_cell_query", false)), "direct path cell-query capability")
    _check(not bool(capabilities.get("network_service", true)), "network service must remain disabled")

    # Regression test for addon.6: prepare_for_export() used to release the
    # authoritative RGBA32F climate texture before PGRuntimeDataWriter could
    # persist temperature_c and precipitation.
    _check(PGGPUContext.TERRESTRIAL_EXPORT_TEXTURES.has("climate"),
        "climate texture must survive prepare_for_export for runtime query-data export")

    var template := PlanetGeneratorService.create_template("Earth-like")
    _check(template != null, "Earth-like template must be available")
    template.planet_name = "Contract Test"
    template.seed = 42
    var validation := template.validation_report()
    _check(bool(validation.get("ok", false)), "default preset must validate")

    var json_path := "user://planet_generator_addon_contract_template.json"
    _check(template.save_json(json_path) == OK, "template JSON save")
    var loaded := PlanetGenerationTemplate.load_json(json_path)
    _check(loaded != null, "template JSON load")
    if loaded != null:
        _check(loaded.seed == 42, "template seed JSON round-trip")
        _check(loaded.planet_name == "Contract Test", "template name JSON round-trip")
    DirAccess.remove_absolute(json_path)

    # Standalone 3.x compatibility: the standalone stores canonical values at
    # the JSON root and keeps export policy in _ui.
    var standalone_path := "user://planet_generator_addon_contract.planetGeneratorParam"
    var standalone_payload := template.to_dictionary()
    standalone_payload["seed"] = 1337
    standalone_payload["planet_name"] = "Standalone Import"
    standalone_payload["_meta"] = {"version": 2, "name": "Standalone Contract"}
    standalone_payload["_ui"] = {"export_preset": "complete"}
    var standalone_file := FileAccess.open(standalone_path, FileAccess.WRITE)
    _check(standalone_file != null, "standalone preset fixture creation")
    if standalone_file != null:
        standalone_file.store_string(JSON.stringify(standalone_payload, "\t"))
        standalone_file.close()
    var imported_spec := PlanetGeneratorService.load_preset(standalone_path)
    _check(imported_spec != null, "standalone .planetGeneratorParam import")
    if imported_spec != null:
        _check(imported_spec.template != null, "standalone import template")
        _check(imported_spec.template.seed == 1337, "standalone import seed")
        _check(imported_spec.template.planet_name == "Standalone Import", "standalone import planet name")
        _check(imported_spec.export_preset == "complete", "standalone export preset preservation")
        imported_spec.output_root = "user://planet_generator_contract/exact"
        imported_spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY
        var imported_compiled := imported_spec.compile()
        _check(bool(imported_compiled.get("ok", false)), "imported standalone spec must compile")
    DirAccess.remove_absolute(standalone_path)

    # Validate the exact real preset bundled with this development package.
    _test_real_standalone_preset_contract()

    var spec := PlanetGenerationSpec.from_template(template)
    spec.runtime_profile = PlanetGenerationSpec.PROFILE_RUNTIME
    var compiled := spec.compile()
    _check(bool(compiled.get("ok", false)), "spec must compile")
    if bool(compiled.get("ok", false)):
        var params: Dictionary = compiled["params"]
        _check(params.get("resolution", Vector2i.ZERO) is Vector2i, "compiled resolution type")
        _check(str(params.get("projection", "")) == PGPlanetGridContract.PROJECTION_ID, "grid projection contract")
        _check(str(params.get("cartography_palette_path", "")).begins_with("res://addons/planet_generator/"), "addon-local palette path")
        _check(bool(params.get("export_runtime_query_data", false)), "runtime query data enabled by default")

    _test_runtime_query_contract()

    var shader_paths := [
        "res://addons/planet_generator/runtime/shaders/compute/topographie/base_elevation.glsl",
        "res://addons/planet_generator/runtime/shaders/compute/final_map.glsl",
        "res://addons/planet_generator/runtime/shaders/compute/export/export_final_map.glsl",
        "res://addons/planet_generator/runtime/shaders/compute/water/disabled_hydrology_clear.glsl",
    ]
    for shader_path in shader_paths:
        _check(FileAccess.file_exists(shader_path), "shader exists: %s" % shader_path)

    if _failures.is_empty():
        print("[Planet Generator Addon] contract smoke test: PASS")
        get_tree().quit(0)
    else:
        for failure in _failures:
            push_error("[Planet Generator Addon] " + failure)
        get_tree().quit(1)



func _test_real_standalone_preset_contract() -> void:
    var real_preset_path := "res://addons/planet_generator/tests/fixtures/test.planetGeneratorParam"
    _check(FileAccess.file_exists(real_preset_path), "real uploaded standalone preset fixture exists")
    var spec := PlanetGeneratorService.load_preset(real_preset_path)
    _check(spec != null, "real uploaded .planetGeneratorParam import")
    if spec == null:
        return
    _check(spec.template != null, "real uploaded preset template")
    if spec.template == null:
        return
    _check(is_equal_approx(spec.template.avg_temperature, 21.0), "real preset avg_temperature")
    _check(is_equal_approx(spec.template.planet_radius, 150.0), "real preset radius")
    _check(spec.template.planet_type == 0, "real preset Terran planet type")
    _check(is_equal_approx(spec.template.ocean_ratio, 55.0), "real preset ocean ratio")
    _check(spec.template.seed == 0, "real preset preserves seed=0 random-seed request")
    _check(spec.export_preset == "standard", "real preset preserves standalone export policy")
    var compiled := spec.compile()
    _check(bool(compiled.get("ok", false)), "real uploaded preset compiles")
    if bool(compiled.get("ok", false)):
        var params: Dictionary = compiled.get("params", {}) as Dictionary
        _check(params.get("resolution", Vector2i.ZERO) == Vector2i(752, 376), "real preset canonical 752x376 dimensions")
        _check(int(params.get("seed", 0)) != 0, "real preset resolves seed=0 to a concrete generation seed")
        _check(str(params.get("export_preset", "")) == "standard", "real preset compiled export policy")


func _test_runtime_query_contract() -> void:
    var root := "user://planet_generator_addon_runtime_contract"
    PGRuntimeDataWriter.remove_existing(root)
    DirAccess.make_dir_recursive_absolute(root)

    var dimensions := Vector2i(2, 1)
    var writer := PGRuntimeDataWriter.new()
    _check(writer.begin(root, dimensions, {
        "sea_level": 20.0,
        "planet_type": 0,
        "projection": PGPlanetGridContract.PROJECTION_ID,
    }), "runtime writer begin")

    var geo := PackedByteArray()
    geo.resize(2 * 16)
    geo.encode_float(0, 120.0)
    geo.encode_float(16, -30.0)
    _check(writer.write_height_from_geo(geo), "runtime height write")

    var climate := PackedByteArray()
    climate.resize(2 * 16)
    climate.encode_float(0, 12.5)
    climate.encode_float(4, 0.7)
    climate.encode_float(16, -2.0)
    climate.encode_float(20, 0.2)
    _check(writer.write_climate_from_rgba32f(climate), "runtime climate write")

    var biome := PackedByteArray()
    biome.resize(8)
    biome.encode_u32(0, 0)
    biome.encode_u32(4, 1)
    _check(writer.write_u32_layer("biome_id", "biome_id.r32ui", biome, "contract"), "runtime biome write")

    var river := PackedByteArray()
    river.resize(8)
    river.encode_u32(0, 0xFFFFFFFF)
    river.encode_u32(4, 0xFFFFFFFF)
    _check(writer.write_u32_layer("river_biome_id", "river_biome_id.r32ui", river, "contract"), "runtime river biome write")

    var water := PackedByteArray()
    water.resize(2)
    water[0] = 0
    water[1] = 1
    _check(writer.write_u8_layer("water_type", "water_type.r8ui", water, "contract"), "runtime water write")

    var region := PackedByteArray()
    region.resize(8)
    region.encode_u32(0, 7)
    region.encode_u32(4, 0xFFFFFFFF)
    _check(writer.write_u32_layer("region_id", "region_id.r32ui", region, "contract"), "runtime region write")

    var ocean_region := PackedByteArray()
    ocean_region.resize(8)
    ocean_region.encode_u32(0, 0xFFFFFFFF)
    ocean_region.encode_u32(4, 3)
    _check(writer.write_u32_layer("ocean_region_id", "ocean_region_id.r32ui", ocean_region, "contract"), "runtime ocean region write")

    var runtime_manifest := writer.finish()
    _check(not runtime_manifest.is_empty(), "runtime manifest write")

    # Minimal reloadable project fixture, so the path-based public API is also
    # covered without invoking the GPU generator.
    var project_path := root.path_join("planet_project.json")
    var project_file := FileAccess.open(project_path, FileAccess.WRITE)
    _check(project_file != null, "runtime project fixture creation")
    if project_file != null:
        project_file.store_string(JSON.stringify({
            "planet_project_version": PGPlanetProject.PROJECT_VERSION,
            "generator_version": PGAddonInfo.VERSION,
            "planet_name": "Runtime Contract",
            "seed": 1,
            "planet_type": 0,
            "root": ".",
            "parameters": {"sea_level": 20.0, "planet_type": 0},
            "layers": {
                "runtime_data_manifest": {
                    "path": "runtime_data/runtime_data_manifest.json",
                    "sha256": "",
                    "kind": "metadata",
                },
            },
        }, "  "))
        project_file.close()

    var result := PlanetGenerationResult.new()
    result.output_root = root
    result.parameters = {"sea_level": 20.0, "planet_type": 0}
    result.layers["runtime_data_manifest"] = runtime_manifest
    _check(result.has_runtime_data(), "runtime result data detection")
    _check(is_equal_approx(result.get_surface_elevation_at(Vector2i(0, 0)), 120.0), "surface elevation getter")
    _check(is_equal_approx(result.get_height_at(Vector2i(0, 0)), 100.0), "sea-relative height getter")
    _check(is_equal_approx(result.get_temperature_at(Vector2i(0, 0)), 12.5), "temperature getter")
    _check(is_equal_approx(result.get_precipitation_at(Vector2i(0, 0)), 0.7), "precipitation getter")
    _check(result.get_water_type_at(Vector2i(1, 0)) == PlanetGenerationResult.WATER_SALTWATER, "water getter")
    _check(result.get_region_id_at(Vector2i(0, 0)) == 7, "region getter")
    _check(result.get_region_id_at(Vector2i(1, 0)) == -1, "region no-data conversion")
    _check(result.get_ocean_region_id_at(Vector2i(1, 0)) == 3, "ocean region getter")
    _check(not result.get_biome_at(Vector2i(0, 0)).is_empty(), "biome getter")
    _check(not result.get_biome_name_at(Vector2i(0, 0)).is_empty(), "biome name getter")
    _check(not result.get_biome_display_name_at(Vector2i(0, 0)).is_empty(), "biome display-name getter")
    var cell := result.get_cell_data(Vector2i(0, 0))
    _check(bool(cell.get("runtime_data_available", false)), "cell aggregate runtime flag")
    _check(is_equal_approx(float(cell.get("height_m", NAN)), 100.0), "cell aggregate height")
    _check(not str(cell.get("biome_name", "")).is_empty(), "cell aggregate biome name")

    var by_path := PlanetGeneratorService.query_planet_cell(root, Vector2i(0, 0))
    _check(bool(by_path.get("runtime_data_available", false)), "direct path cell query")
    _check(is_equal_approx(float(by_path.get("height_m", NAN)), 100.0), "direct path cell-query height")

    result.clear_caches()
    PGRuntimeDataWriter.remove_existing(root)
    if FileAccess.file_exists(project_path):
        DirAccess.remove_absolute(project_path)
    if DirAccess.dir_exists_absolute(root):
        DirAccess.remove_absolute(root)

func _check(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)
