# Planet Generator — Godot Addon

> **addon.7 runtime-data fix:** terrestrial generation now retains the authoritative `climate` GPU texture through the export lifecycle, so `temperature_c` and `precipitation` are always persisted when `export_runtime_query_data` is enabled. Planets generated with addon.6 must be regenerated to obtain those two exact raw layers.

Reusable Godot addon for **Planet Generator 3.1.0**, continuing the Milestone 9 core/addon architecture.

The addon exposes the existing validated generation engine to a consuming Godot game without loading the standalone Planet Generator UI. It is intentionally a direct in-process GDScript API: no HTTP server, sockets, ports, or external process.

## Compatibility

- Godot **4.7+** is the target API level for this addon package.
- A GPU/driver capable of creating a local `RenderingDevice` is required for actual generation. **Forward+ or Mobile is required; Godot Compatibility/OpenGL does not provide `RenderingDevice`.**
- Source baseline: Planet Generator `3.1.0`, commit `76c1513c49539716f541dac67294ce29479b57de`.
- Addon version: `3.1.0-addon.1`.

## Install

1. Copy the `addons/planet_generator/` directory into the root of your Godot project.
2. Open **Project > Project Settings > Plugins**.
3. Enable **Planet Generator**.
4. The plugin registers the internal `PlanetGeneratorServiceRuntime` autoload automatically. `PlanetGeneratorService` is a real global `class_name` static facade.

The package follows Godot's editor-plugin layout: `addons/<plugin>/plugin.cfg` plus an `@tool` `EditorPlugin`. The plugin's enable/disable hooks own registration/removal of the service autoload.

## Public API

The supported public surface is deliberately small:

- `PlanetGeneratorService` — global public `class_name` static facade. Stateful jobs are owned internally by the `PlanetGeneratorServiceRuntime` autoload.
- `PlanetGenerationTemplate` — serializable world parameters shared between code and frontend tooling.
- `PlanetGenerationSpec` — execution/output policy.
- `PlanetGenerationJob` — asynchronous progress/cancellation/result handle.
- `PlanetGenerationResult` — generated manifests, layers, textures, tiles and metadata.

Everything prefixed with `PG...` under `runtime/` is internal implementation detail and should not be called by consuming games.

## Basic generation

```gdscript
func create_world() -> void:
    var template := PlanetGeneratorService.create_template("Earth-like")
    template.planet_name = "Kepler"
    template.seed = 123456
    template.planet_radius = 150.0

    var spec := PlanetGenerationSpec.from_template(template)
    spec.runtime_profile = PlanetGenerationSpec.PROFILE_RUNTIME

    var job := PlanetGeneratorService.generate_planet(spec)
    job.progress.connect(func(phase, completed, total, ratio):
        print("%s: %.1f%%" % [phase, ratio * 100.0])
    )

    var result := await job.wait_for_result()
    if result == null:
        push_error("Planet generation failed: %s" % [job.error])
        return

    var texture := result.load_layer_texture("final_map")
    print("Generated at: ", result.output_root)
    print("Available layers: ", result.get_layer_keys())
```

## Cancellation

```gdscript
var job := PlanetGeneratorService.generate_planet(spec)
# Later:
job.cancel("player_left_world_creation")
```

The underlying GPU work still uses the project's single persistent GPU worker and one shared local `RenderingDevice`. Jobs are queued instead of creating one device per request.

## Templates: code, JSON and `.tres`

```gdscript
var template := PlanetGenerationTemplate.from_preset("Earth-like")
template.planet_name = "Runtime Template"
template.save_json("user://templates/runtime_planet.json")
template.save_resource("user://templates/runtime_planet.tres")

var from_json := PlanetGenerationTemplate.load_json("user://templates/runtime_planet.json")
var from_resource := PlanetGenerationTemplate.load_resource("user://templates/runtime_planet.tres")
```

The parameter keys are the same canonical keys used by the standalone parameter model, so a future standalone frontend can consume the same template resource rather than requiring a frontend-specific conversion.

## Import a standalone `.planetGeneratorParam` preset

Planet Generator Addon 3.1.0-addon.1 directly reads parameter presets exported by the standalone 3.x application. The standalone `_ui.export_preset` value is preserved in the resulting `PlanetGenerationSpec`.

```gdscript
var spec := PlanetGeneratorService.load_preset(
    "D:/PlanetGeneratorPresets/my_world.planetGeneratorParam"
)
if spec == null:
    push_error("Invalid Planet Generator preset")
    return

var job := PlanetGeneratorService.generate_planet(spec)
var result := await job.wait_for_result()
```

The preset file can also be passed directly to `generate_planet()`:

```gdscript
var job := PlanetGeneratorService.generate_planet(
    "D:/PlanetGeneratorPresets/my_world.planetGeneratorParam"
)
```

## Exact output directory

By default, `output_root` is a **base directory** and the addon creates a unique `<planet>_<seed>_<job-id>` child directory. To use the path itself as the final export directory, set `output_mode` to `OUTPUT_EXACT_DIRECTORY`:

```gdscript
var spec := PlanetGeneratorService.load_preset(
    "D:/PlanetGeneratorPresets/my_world.planetGeneratorParam"
)
spec.output_root = "D:/MyGame/generated_planets/earth_01"
spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

var job := PlanetGeneratorService.generate_planet(spec)
var result := await job.wait_for_result()
print(result.output_root) # D:/MyGame/generated_planets/earth_01
```

For convenience, the same can be written in one call:

```gdscript
var job := PlanetGeneratorService.generate_planet(
    "D:/PlanetGeneratorPresets/my_world.planetGeneratorParam",
    "D:/MyGame/generated_planets/earth_01",
    true # exact_output
)
```

Exact mode is deliberately conservative: the addon refuses project roots, `user://` itself, filesystem/drive roots, and non-empty directories that are not already recognizable Planet Generator outputs. This prevents the generator from clearing unrelated host-game files. An empty target directory or a previous Planet Generator output directory is accepted.

## Runtime profiles

`PlanetGenerationSpec.runtime_profile` supports:

| Profile | Default export policy | Intended use |
| --- | --- | --- |
| `FULL` | `complete` | Full persistent world package, including resources |
| `RUNTIME` | `minimal` | Lightweight in-game generation |
| `SERVER` | `minimal` | Backend/headless-oriented usage; cartographic/grid presentation disabled |
| `EDITOR` | `development` | Diagnostics/debug outputs |

Any profile can override `export_preset` explicitly (`minimal`, `standard`, `complete`, `development`, or `custom`).

## Runtime data access

After a job completes:

```gdscript
var image := result.load_layer_image("final_map")
var color := result.sample_layer_color("final_map", Vector2i(100, 50))
var tile := result.extract_global_tile("final_map", Vector2i(0, 0))
var dimensions := result.get_grid_dimensions()
var tile_count := result.get_tile_count()
```

For an actual tiled dataset, `read_tiled_payload(layer_key, lod, tile)` reads the stored tile payload through the core tile store.

`PlanetGenerationResult.load_existing(path)` / `PlanetGeneratorService.load_planet(path)` reopens an existing `planet_project.json` output without regeneration.

### Important current-core boundary

The current 3.1.0 source does **not** contain the older experimental detailed 1 km² local-zone generator. This addon therefore does not fabricate `generate_local_zone()`. `PlanetGeneratorService.supports_detailed_local_zones()` returns `false` and `get_capabilities()` reports the same. Global layers/tiles remain available through the runtime result API.

Likewise, the authoritative production generator remains the monolithic GPU path for resolutions inside its safe envelope; the existing tiled global simulation code is retained only behind the same experimental/production guards as the standalone core.

## Output isolation

Each addon job writes to a unique directory under:

```text
user://planet_generator/generated/<planet>_<seed>_<job-id>/
```

or below the `PlanetGenerationSpec.output_root` you provide. The addon never clears a generic `user://temp` directory, so it cannot delete temporary data belonging to the host game.

## Lifecycle

Call this when you explicitly want to tear down Planet Generator GPU resources before changing application modes:

```gdscript
PlanetGeneratorService.shutdown()
```

The service also performs shutdown from `_exit_tree()`.

## Package layout

```text
addons/planet_generator/
├── plugin.cfg
├── plugin.gd
├── public/
│   ├── planet_generator_service.gd
│   ├── planet_generation_template.gd
│   ├── planet_generation_spec.gd
│   ├── planet_generation_job.gd
│   └── planet_generation_result.gd
└── runtime/
    ├── core/
    ├── data/
    ├── gpu/
    ├── io/
    └── shaders/compute/
```

The standalone scenes, controls, fonts, translations, dialogs, release UI and application workspaces are not distributed in the addon.

## Tests

`addons/planet_generator/tests/addon_contract_test.gd` is a no-GPU contract smoke test. Run it from the included minimal test project or copy the addon into a clean Godot 4.7+ project and execute the script after enabling the plugin.

Actual generation still needs the same Vulkan/RenderingDevice runtime validation as the standalone project; static checks cannot prove GPU/driver behavior.

See [`addons/planet_generator/docs/MILESTONE_9.md`](addons/planet_generator/docs/MILESTONE_9.md) for the extraction/acceptance matrix.

## Typed per-cell runtime queries (API v2)

Starting with `3.0.0-addon.7`, the normal monolithic generator persists a compact query dataset before GPU resources are released. This is enabled by default through:

```gdscript
spec.export_runtime_query_data = true
```

A generated or reloaded `PlanetGenerationResult` exposes exact values:

```gdscript
var planet := PlanetGeneratorService.load_planet("D:/MyGame/generated_planets/earth_01")
var cell := Vector2i(500, 300)

var height_m := planet.get_height_at(cell)
var absolute_elevation_m := planet.get_surface_elevation_at(cell)
var temperature_c := planet.get_temperature_at(cell)
var precipitation := planet.get_precipitation_at(cell)
var biome := planet.get_biome_at(cell)
var biome_name := planet.get_biome_name_at(cell)
var water := planet.get_water_at(cell)
var region_id := planet.get_region_id_at(cell)
var ocean_region_id := planet.get_ocean_region_id_at(cell)
```

`get_height_at()` returns metres relative to the configured sea level. `get_surface_elevation_at()` returns the unshifted authoritative `geo.r` value. `get_precipitation_at()` is the generator's normalized climate G channel (`0..1`), used as the humidity/precipitation proxy by hydrology and biome classification; it is not millimetres of rainfall.

`get_biome_at()` returns a dictionary such as:

```gdscript
{
    "id": 17,
    "name": "Forêt de montagne",
    "display_name": "Forêt de montagne",
    "translation_key": "BIOME_FORET_DE_MONTAGNE",
    "color": "...",
    "vegetation_color": "...",
    "is_river": false,
    "water_required": false,
    "freshwater_only": false,
}
```

River cells return their river biome by default. Use `get_ground_biome_at(cell)` to ignore the river overlay, or `get_river_biome_at(cell)` to query it explicitly.

For a single gameplay lookup, `get_cell_data()` aggregates the public fields:

```gdscript
var data := planet.get_cell_data(cell)
print(data.height_m)
print(data.temperature_c)
print(data.precipitation)
print(data.biome)
print(data.biome_id)
print(data.biome_name)
print(data.water)
print(data.region_id)
```


For one-off queries, the service also accepts the generated-planet path directly:

```gdscript
var data := PlanetGeneratorService.query_planet_cell(
    "D:/MyGame/generated_planets/earth_01",
    Vector2i(500, 300)
)
print(data.height_m)
print(data.biome_name)
```

For repeated queries, prefer `load_planet()` once and reuse the returned result. This keeps the runtime-data files open lazily and avoids reparsing the project manifest for every cell.

The runtime dataset is stored in `<planet output>/runtime_data/` as exact binary scalar/categorical layers plus `runtime_data_manifest.json`. The result reader keeps file handles open lazily and seeks directly to the requested cell instead of loading complete layers into RAM. Call `result.clear_runtime_data_cache()` when you explicitly want those file handles released.

Projects generated by addon.3 or older do not contain the exact runtime dataset. `has_runtime_data()` reports this. The biome getter can still fall back to the exported biome PNG where possible, but exact height/climate/administrative IDs require a planet generated with addon.4+.

Gas giants currently have no solid-surface runtime cell dataset, so these scalar surface getters are unavailable for gas-giant results.

## PlanetGeneratorService class vs runtime autoload

Since `3.0.0-addon.7`, `PlanetGeneratorService` is a real globally registered GDScript class:

```gdscript
class_name PlanetGeneratorService
```

This makes it visible to Godot autocomplete and the global class database like `PlanetGenerationTemplate`, `PlanetGenerationSpec`, `PlanetGenerationJob`, and `PlanetGenerationResult`.

The plugin separately registers an internal autoload called `PlanetGeneratorServiceRuntime`. The different name is intentional: Godot's global class and autoload identifiers share global script-facing namespaces, so using the same name for both is avoided.

Normal game code continues to use:

```gdscript
var spec := PlanetGeneratorService.load_preset("res://earth.planetGeneratorParam")
var job := PlanetGeneratorService.generate_planet(spec, "user://earth", true)
var result := await job.wait_for_result()
```

To connect service-wide signals:

```gdscript
var runtime := PlanetGeneratorService.get_runtime()
if runtime:
    runtime.job_started.connect(_on_planet_job_started)
    runtime.job_completed.connect(_on_planet_job_completed)
```

You can verify correct installation with:

```gdscript
print(PlanetGeneratorService.get_version())
print(PlanetGeneratorService.is_runtime_available())
```

The second value must be `true` while the game is running for generation to start.
