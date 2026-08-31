# Planet Generator Godot Addon — Complete Documentation

**Addon:** `3.1.0-addon.1`  
**Public API:** `2`  
**Core/standalone baseline:** Planet Generator `3.1.0`  
**Source commit:** `76c1513c49539716f541dac67294ce29479b57de`  
**Godot target:** `4.7+`

This is the complete integration manual for the Godot addon edition of Planet Generator. It covers installation, the public API, all generation parameters, standalone preset import, output policy, resource-map export, async jobs, exact per-cell getters, output layout, testing, migration, performance, and known limitations.

The addon runs the generation core directly inside the consuming Godot project. It does not require the standalone Planet Generator UI.


## 0.1. Planet Generator 3.1.0 core synchronization

Addon `3.1.0-addon.1` is synchronized with standalone commit
`76c1513c49539716f541dac67294ce29479b57de`.

The 3.1.0 core update adds:

- canonical zero/sentinel initialization for disabled hydrology on airless and sterile worlds;
- full-range dry-relief coloring for topographic and cartographic maps, without treating negative dry elevations as oceans;
- more geological resource morphology using anisotropic lenses, lodes, ridged veins and branching structures;
- correct planet-type propagation into the resource phase;
- a preset-aware export stage plan that skips outputs before costly readback/conversion/compression work;
- stale presentation-output pruning when an exact/reused destination is exported with a smaller preset;
- reuse of the authoritative CPU hydrology mask for both administrative phases;
- paired river-map conversion and fewer redundant integrity readbacks;
- export-preset-aware integrity requirements plus validation of disabled-hydrology defaults.

These changes do not alter the public addon API version. Addon-specific runtime query data remains additive to the upstream export pipeline.

---

## 1. Requirements

Actual generation uses compute shaders through a local Godot `RenderingDevice`.

- Godot **4.7+**.
- GPU/driver capable of creating a local `RenderingDevice`.
- Use **Forward+** or **Mobile** for real generation.
- Compatibility/OpenGL can load the addon and run non-GPU contract checks, but it cannot execute the compute generation pipeline.
- No HTTP/TCP/UDP/WebSocket service is used. The API is direct GDScript.

---

## 2. Installation

Copy:

```text
addons/planet_generator/
```

into the root of your Godot project.

Enable **Planet Generator** in:

```text
Project -> Project Settings -> Plugins
```

The plugin registers the internal runtime autoload:

```text
PlanetGeneratorServiceRuntime
```

Normal game code uses the public global class:

```gdscript
PlanetGeneratorService
```

Verify:

```gdscript
print(PlanetGeneratorService.get_version())          # 3.1.0-addon.1
print(PlanetGeneratorService.get_api_version())      # 2
print(PlanetGeneratorService.is_runtime_available()) # true
```

---

## 3. Supported public classes

| Class | Responsibility |
| --- | --- |
| `PlanetGeneratorService` | Static facade for generation, loading, cancellation, capabilities and one-off cell queries. |
| `PlanetGenerationTemplate` | Serializable planet-generation parameters. |
| `PlanetGenerationSpec` | Execution and export policy. |
| `PlanetGenerationJob` | Async job/progress/cancellation handle. |
| `PlanetGenerationResult` | Generated maps, metadata, tiles and exact cell data. |

Anything prefixed `PG...` is internal implementation detail and should not be referenced by a consuming game.

---

## 4. Quick start

```gdscript
func create_world() -> void:
    var template := PlanetGeneratorService.create_template("Earth-like")
    template.planet_name = "Kepler"
    template.seed = 123456

    var spec := PlanetGenerationSpec.from_template(template)
    spec.runtime_profile = PlanetGenerationSpec.PROFILE_RUNTIME

    var job := PlanetGeneratorService.generate_planet(spec)

    job.progress.connect(
        func(phase: String, completed: int, total: int, ratio: float):
            print("%s %.1f%%" % [phase, ratio * 100.0])
    )

    var result := await job.wait_for_result()
    if result == null:
        push_error("Generation failed: %s" % [job.error])
        return

    print(result.output_root)
    var final_texture := result.load_layer_texture("final_map")
```

Generation work is queued through one persistent GPU worker rather than creating a new `RenderingDevice` for every request.

---

## 5. `PlanetGeneratorService` reference

### Information

```gdscript
PlanetGeneratorService.get_version() -> String
PlanetGeneratorService.get_api_version() -> int
PlanetGeneratorService.get_capabilities() -> Dictionary
PlanetGeneratorService.is_runtime_available() -> bool
PlanetGeneratorService.supports_detailed_local_zones() -> bool
```

`supports_detailed_local_zones()` currently returns `false`.

### Templates/specs

```gdscript
PlanetGeneratorService.get_template_names() -> Array[String]
PlanetGeneratorService.create_template(preset_name := "Earth-like") -> PlanetGenerationTemplate
PlanetGeneratorService.create_spec(preset_name := "Earth-like") -> PlanetGenerationSpec
```

### Generation

```gdscript
PlanetGeneratorService.generate_planet(
    request: Variant,
    output_root: String = "",
    exact_output: bool = false
) -> PlanetGenerationJob
```

Accepted requests include a `PlanetGenerationSpec`, `PlanetGenerationTemplate`, compatible `Dictionary`, or supported preset path.

### Job control

```gdscript
PlanetGeneratorService.get_job(job_id: String) -> PlanetGenerationJob
PlanetGeneratorService.cancel_job(job_id: String, reason := "user") -> bool
PlanetGeneratorService.cancel_all(reason := "service_shutdown") -> void
```

### Existing worlds

```gdscript
PlanetGeneratorService.load_planet(path_or_directory: String) -> PlanetGenerationResult
```

### One-off cell query

```gdscript
PlanetGeneratorService.query_planet_cell(
    path_or_directory: String,
    global_cell: Vector2i,
    include_river_biome: bool = true
) -> Dictionary
```

For repeated queries, load the planet once instead.

### Lifecycle

```gdscript
PlanetGeneratorService.shutdown()
```

---

## 6. Service-wide signals

```gdscript
var runtime := PlanetGeneratorService.get_runtime()

if runtime:
    runtime.job_started.connect(_on_job_started)
    runtime.job_completed.connect(_on_job_completed)
    runtime.job_failed.connect(_on_job_failed)
    runtime.job_cancelled.connect(_on_job_cancelled)
```

Use this only for service-wide observation. Normal generation should continue through `PlanetGeneratorService`.

---

## 7. `PlanetGenerationTemplate`

Create:

```gdscript
var template := PlanetGenerationTemplate.from_preset("Earth-like")
```

Helpers:

```gdscript
PlanetGenerationTemplate.defaults()
PlanetGenerationTemplate.smart_random()
template.to_dictionary()
template.apply_dictionary(values)
template.validated_values()
template.validation_report()
template.duplicate_template()
```

JSON:

```gdscript
template.save_json("user://templates/world.json")
var loaded := PlanetGenerationTemplate.load_json("user://templates/world.json")
```

Godot resource:

```gdscript
template.save_resource("user://templates/world.tres")
var loaded := PlanetGenerationTemplate.load_resource("user://templates/world.tres")
```

---

## 8. Complete parameter reference

Values are validated/clamped against the addon's canonical schema.

### General

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `seed` | 0.0 | 0.0 … 1000000000000.0 | 1.0 | — |
| `planet_name` | "" | — | — | — |
| `planet_radius` | 150.0 | 150.0 … 1500.0 | 50.0 | km |
| `planet_density` | 5.51 | 0.5 … 10.0 | 0.01 | g/cm³ |
| `planet_type` | 0 | 0 … 6 | — | — |
| `avg_temperature` | 21.0 | -273.0 … 500.0 | 1.0 | °C |
| `export_worker_count` | 0.0 | 0.0 … 16.0 | 1.0 | — |

### Erosion & tectonics

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `terrain_scale` | 150.0 | 0.0 … 10000.0 | 50.0 | m |
| `erosion_iterations` | 100.0 | 1.0 … 5000.0 | 1.0 | — |
| `erosion_rate` | 0.05 | 0.01 … 1.0 | 0.01 | — |
| `rain_rate` | 0.005 | 0.001 … 1.0 | 0.001 | — |
| `evap_rate` | 0.02 | 0.01 … 1.0 | 0.01 | — |
| `flow_rate` | 0.25 | 0.01 … 1.0 | 0.01 | — |
| `deposition_rate` | 0.05 | 0.01 … 1.0 | 0.01 | — |
| `capacity_multiplier` | 1.0 | 0.5 … 10.0 | 0.5 | — |
| `flux_iterations` | 10.0 | 10.0 … 100.0 | 10.0 | — |
| `base_flux` | 100.0 | 1.0 … 1000.0 | 1.0 | — |
| `propagation_rate` | 0.8 | 0.1 … 1.0 | 0.1 | — |
| `spreading_rate` | 50.0 | 1.0 … 500.0 | 1.0 | — |
| `max_crust_age` | 200.0 | 1.0 … 5000.0 | 1.0 | Myr |
| `subsidence_coeff` | 2800.0 | 20.0 … 10000.0 | 20.0 | m/Myr |

### Craters

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `crater_density` | 0.5 | 0.1 … 1.0 | 0.1 | — |
| `crater_min_radius` | 3.0 | 1.0 … 100.0 | 1.0 | km |
| `crater_max_radius` | 24.0 | 4.0 … 250.0 | 1.0 | km |
| `crater_depth_ratio` | 0.25 | 0.01 … 1.0 | 0.01 | — |
| `crater_ejecta_extent` | 2.5 | 0.1 … 2.5 | 0.1 | — |
| `crater_ejecta_decay` | 3.0 | 0.5 … 10.0 | 0.5 | — |
| `crater_azimuth_var` | 0.3 | 0.1 … 1.0 | 0.1 | — |

### Water & climate

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `ocean_ratio` | 55.0 | 0.0 … 100.0 | 0.1 | % |
| `ice_probability` | 0.9 | 0.0 … 1.0 | 0.1 | % |
| `global_humidity` | 0.5 | 0.0 … 1.0 | 0.1 | % |
| `sea_level` | 0.0 | -5000.0 … 5000.0 | 50.0 | m |
| `freshwater_max_size` | 1000.0 | 0.0 … 1000.0 | 10.0 | km² |
| `lake_threshold` | 20.0 | 0.0 … 100.0 | 0.5 | — |

### Clouds

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `cloud_coverage` | 0.5 | 0.1 … 1.0 | 0.1 | % |
| `cloud_density` | 0.8 | 0.1 … 1.0 | 0.1 | % |

### Administrative regions

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `nb_cases_regions` | 50.0 | 15.0 … 500.0 | 5.0 | — |
| `region_cost_flat` | 1.0 | 1.0 … 10.0 | 1.0 | — |
| `region_cost_hill` | 2.0 | 1.0 … 10.0 | 1.0 | — |
| `region_cost_river` | 3.0 | 1.0 … 10.0 | 1.0 | — |
| `region_river_threshold` | 1.0 | 1.0 … 10.0 | 0.5 | — |
| `region_budget_variation` | 0.5 | 0.1 … 1.0 | 0.1 | — |
| `region_noise_strength` | 0.5 | 0.1 … 1.0 | 0.1 | — |

### Ocean regions

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `nb_cases_ocean_regions` | 100.0 | 15.0 … 500.0 | 5.0 | — |
| `ocean_cost_flat` | 1.0 | 1.0 … 10.0 | 1.0 | — |
| `ocean_cost_deeper` | 2.0 | 1.0 … 10.0 | 1.0 | — |
| `ocean_noise_strength` | 0.5 | 0.1 … 1.0 | 0.1 | — |

### Gas giant

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `gas_giant_num_bands` | 12.0 | 6.0 … 24.0 | 1.0 | — |
| `gas_giant_jet_strength` | 4.0 | 0.5 … 10.0 | 0.1 | — |
| `gas_giant_eddy_strength` | 2.5 | 0.5 … 8.0 | 0.1 | — |
| `gas_giant_advection_dt` | 1.4 | 0.4 … 2.5 | 0.05 | — |
| `gas_giant_advection_iterations` | 40.0 | 12.0 … 120.0 | 4.0 | — |
| `gas_giant_target_sharpen` | 1.18 | 1.0 … 1.5 | 0.01 | — |

### Resources

| Key | Default | Valid range | Step | Unit / meaning |
| --- | ---: | ---: | ---: | --- |
| `petrole_probability` | 0.025 | 0.001 … 1.0 | 0.001 | % |
| `petrole_deposit_size` | 200.0 | 1.0 … 400.0 | 1.0 | km² |
| `global_richness` | 1.0 | 0.5 … 10.0 | 0.5 | — |

### Planet types

| Value | Type |
| ---: | --- |
| `0` | Terran |
| `1` | Toxic |
| `2` | Volcanic |
| `3` | No atmosphere |
| `4` | Dead |
| `5` | Sterile |
| `6` | Gas giant |

A seed of `0` is replaced with a randomized seed when the spec is compiled.

---

## 9. `PlanetGenerationSpec`

```gdscript
var spec := PlanetGenerationSpec.from_template(template)
```

| Property | Default | Meaning |
| --- | --- | --- |
| `template` | — | Planet-generation parameters. |
| `runtime_profile` | `RUNTIME` | High-level generation profile. |
| `output_root` | `user://planet_generator/generated` | Base or final output path. |
| `output_mode` | `unique_subdirectory` | Parent-folder mode or exact-folder mode. |
| `export_preset` | `auto` | Export catalog policy. |
| `export_enabled_keys` | `[]` | Keys retained by `custom`. |
| `run_integrity_checks` | `true` | Run integrity checks. |
| `export_cartographic_map` | `true` | Request cartographic map where profile permits. |
| `export_grid_overlay` | `true` | Request grid overlay where profile permits. |
| `export_runtime_query_data` | `true` | Persist exact typed-query data. |
| `cartography_grid_alpha` | `166` | Grid opacity (`0..255`). |
| `experimental_tiled_generation` | `false` | Experimental tiled path. |

Compile without generating:

```gdscript
var report := spec.compile()

if report.ok:
    var params: Dictionary = report.params
else:
    push_error(str(report.errors))
```

---

## 10. Runtime profiles

| Profile | `auto` export | Intended use |
| --- | --- | --- |
| `FULL` | `complete` | Full persistent output, including resources. |
| `RUNTIME` | `minimal` | Lightweight in-game generation. |
| `SERVER` | `minimal` | Backend/headless-oriented; cartographic/grid presentation disabled. |
| `EDITOR` | `development` | Diagnostic/development output. |

An explicit `spec.export_preset` overrides the automatic profile choice.

---

## 11. Standalone `.planetGeneratorParam` import

```gdscript
var spec := PlanetGeneratorService.load_preset(
    "D:/PlanetGeneratorPresets/test.planetGeneratorParam"
)

if spec == null:
    push_error("Invalid preset")
    return
```

Or directly:

```gdscript
var job := PlanetGeneratorService.generate_planet(
    "D:/PlanetGeneratorPresets/test.planetGeneratorParam"
)
```

The standalone `_ui.export_preset` value is preserved.

This matters for resource maps: if the standalone file contains `"standard"`, then the addon receives `"standard"` too. To force resources, override **after loading**:

```gdscript
spec.export_preset = "complete"
```

---

## 12. Export presets

| Preset | Output behavior |
| --- | --- |
| `minimal` | `final_map`, `cartographic`, `eaux_map`, `river_map`, `biome_colored`; no resources/debug. |
| `standard` | Normal user-facing maps; no resource maps and no debug-only layers. |
| `complete` | Normal/gameplay maps **plus resource maps**; debug-only layers excluded. |
| `development` | All outputs including debug/diagnostic layers. |
| `custom` | Only `export_enabled_keys` plus mandatory metadata. |
| `auto` | Resolves from `runtime_profile`. |

### Export all resource maps

```gdscript
var spec := PlanetGeneratorService.load_preset(
    "res://presets/test.planetGeneratorParam"
)

spec.export_preset = "complete"
```

### Export selected resources only

```gdscript
spec.export_preset = "custom"
spec.export_enabled_keys = [
    "final_map",
    "biome_colored",
    "fer_map",
    "cuivre_map",
    "or_map",
    "uranium_map",
    "petrole_map",
]
```

Use string keys from the public API. Do not depend on internal `PGExportCatalog` constants.

---

## 13. Resource maps

The current generator exports **116 resource-related PNG maps** when using `complete`/`development`:

- 115 named resource/mineral layers.
- 1 separate petroleum layer: `petrole_map`.

Canonical directory:

```text
<planet output>/maps/resources/
```

Example access:

```gdscript
if result.has_layer("fer_map"):
    var iron := result.load_layer_image("fer_map")
    var sample := result.sample_layer_color("fer_map", Vector2i(500, 300))
```

Resource PNGs use the resource's configured color multiplied by generated intensity; transparent pixels mean absence.

The typed runtime dataset currently does not expose `get_resource_at()`. Resource gameplay access is through exported resource layers.

### `petrole_map`

### Complete resource key list

### Ultra-abundant

`silicium_map`, `aluminium_map`, `fer_map`, `calcium_map`, `magnesium_map`, `potassium_map`

### Very common

`titane_map`, `phosphate_map`, `manganese_map`, `soufre_map`, `charbon_map`, `calcaire_map`

### Common

`baryum_map`, `strontium_map`, `zirconium_map`, `vanadium_map`, `chrome_map`, `nickel_map`, `zinc_map`, `cuivre_map`, `sel_map`, `fluorine_map`

### Moderately rare

`cobalt_map`, `lithium_map`, `niobium_map`, `plomb_map`, `bore_map`, `thorium_map`, `graphite_map`

### Rare

`etain_map`, `beryllium_map`, `arsenic_map`, `germanium_map`, `uranium_map`, `molybdene_map`, `tungstene_map`, `antimoine_map`, `tantale_map`

### Very rare

`argent_map`, `cadmium_map`, `mercure_map`, `selenium_map`, `indium_map`, `bismuth_map`, `tellure_map`

### Extremely rare / precious metals

`or_map`, `platine_map`, `palladium_map`, `rhodium_map`, `iridium_map`, `osmium_map`, `ruthenium_map`, `rhenium_map`

### Rare earth elements

`cerium_map`, `lanthane_map`, `neodyme_map`, `yttrium_map`, `praseodyme_map`, `samarium_map`, `gadolinium_map`, `dysprosium_map`, `erbium_map`, `europium_map`, `terbium_map`, `holmium_map`, `thulium_map`, `ytterbium_map`, `lutetium_map`, `scandium_map`

### Hydrocarbons / solid fuels (excluding petroleum)

`gaz_naturel_map`, `lignite_map`, `anthracite_map`, `tourbe_map`, `schiste_bitumineux_map`, `methane_hydrate_map`

### Gemstones

`diamant_map`, `emeraude_map`, `rubis_map`, `saphir_map`, `topaze_map`, `amethyste_map`, `opale_map`, `turquoise_map`, `grenat_map`, `peridot_map`, `jade_map`, `lapis_lazuli_map`

### Industrial minerals / rocks

`quartz_map`, `feldspath_map`, `mica_map`, `argile_map`, `kaolin_map`, `gypse_map`, `talc_map`, `bauxite_map`, `marbre_map`, `granit_map`, `ardoise_map`, `gres_map`, `sable_map`, `gravier_map`, `basalte_map`, `obsidienne_map`, `pierre_ponce_map`, `amiante_map`, `vermiculite_map`, `perlite_map`, `bentonite_map`, `zeolite_map`

### Special minerals / elements

`hafnium_map`, `gallium_map`, `cesium_map`, `rubidium_map`, `helium_map`, `terres_rares_melangees_map`

---

## 14. Output directories

### Unique-subdirectory mode

```gdscript
spec.output_root = "user://planet_generator/generated"
spec.output_mode = PlanetGenerationSpec.OUTPUT_UNIQUE_SUBDIRECTORY
```

Produces a child directory similar to:

```text
<planet>_<seed>_<job-id>/
```

### Exact-directory mode

```gdscript
spec.output_root = "D:/MyGame/GeneratedPlanets/Earth"
spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY
```

Convenience form:

```gdscript
var job := PlanetGeneratorService.generate_planet(
    spec,
    "D:/MyGame/GeneratedPlanets/Earth",
    true
)
```

Exact mode rejects dangerous or unrelated non-empty targets such as filesystem roots, the project root, or `user://` itself.

---

## 15. Typical output layout

```text
<planet>/
├── planet_project.json
├── planet_manifest.json
├── export_catalog.json
├── integrity_report.json
├── maps/
│   ├── final_map.png
│   ├── biome_colored.png
│   ├── eaux_map.png
│   ├── river_map.png
│   └── resources/
│       ├── petrole_map.png
│       ├── fer_map.png
│       └── ...
├── overlays/
│   └── ...
└── runtime_data/
    ├── runtime_data_manifest.json
    ├── surface_elevation.r32f
    ├── temperature.r32f
    ├── precipitation.r32f
    ├── biome_id.r32ui
    ├── river_biome_id.r32ui
    ├── water_type.r8ui
    ├── region_id.r32ui
    └── ocean_region_id.r32ui
```

Optional maps depend on planet type and export policy. Use `get_layer_keys()`/`has_layer()` rather than assuming a file exists.

---

## 16. `PlanetGenerationJob`

Signals:

```gdscript
signal progress(phase: String, completed: int, total: int, ratio: float)
signal state_changed(state: int)
signal completed(result: PlanetGenerationResult)
signal failed(error: Dictionary)
signal cancelled(reason: String)
signal finished(job: PlanetGenerationJob)
```

States:

```text
QUEUED
RUNNING
CANCELLING
COMPLETED
FAILED
CANCELLED
```

Methods:

```gdscript
job.cancel(reason := "user")
job.is_done()
job.succeeded()
job.get_progress_ratio()
await job.wait_for_result()
```

---

## 17. Map/layer access

```gdscript
result.get_layer_keys() -> Array[String]
result.has_layer(layer_key: String) -> bool
result.get_layer_path(layer_key: String) -> String
result.load_layer_image(layer_key: String, use_cache := true) -> Image
result.load_layer_texture(layer_key: String, use_cache := true) -> Texture2D
result.sample_layer_color(layer_key: String, global_cell: Vector2i) -> Color
result.extract_global_tile(layer_key: String, tile: Vector2i, tile_size := 2048) -> Image
result.get_grid_dimensions() -> Vector2i
result.get_tile_count(tile_size := 2048) -> Vector2i
result.read_tiled_payload(layer_key: String, lod: int, tile: Vector2i) -> PackedByteArray
```

PNG sampling wraps X and clamps Y.

---

## 18. Exact typed cell-query API

For terrestrial worlds, exact runtime query data is enabled by default:

```gdscript
spec.export_runtime_query_data = true
```

Check:

```gdscript
result.has_runtime_data()
result.get_runtime_data_layers()
result.get_runtime_data_manifest()
```

### Elevation

```gdscript
result.get_height_at(cell)
result.get_elevation_at(cell)            # alias
result.get_surface_elevation_at(cell)
result.get_sea_level_m()
```

`get_height_at()` is metres relative to configured sea level. Negative values are below sea level.

### Climate

```gdscript
result.get_temperature_at(cell)   # °C
result.get_precipitation_at(cell) # normalized 0..1 proxy
result.get_humidity_at(cell)      # alias of same current climate channel
```

Precipitation is not millimetres/year.

### Water

```gdscript
result.get_water_type_at(cell)
result.is_water_at(cell)
result.get_water_at(cell)
```

Constants:

```gdscript
PlanetGenerationResult.WATER_LAND       # 0
PlanetGenerationResult.WATER_SALTWATER  # 1
PlanetGenerationResult.WATER_FRESHWATER # 2
```

### Biomes

```gdscript
result.get_biome_id_at(cell)
result.get_river_biome_id_at(cell)
result.get_ground_biome_at(cell)
result.get_river_biome_at(cell)
result.get_biome_at(cell, true)
result.get_biome_name_at(cell, true)
result.get_biome_display_name_at(cell, true)
```

River biome takes precedence when `include_river` is true.

### Regions

```gdscript
result.get_region_id_at(cell)
result.get_region_at(cell)          # alias
result.get_ocean_region_id_at(cell)
result.get_ocean_region_at(cell)    # alias
```

Unavailable IDs return:

```gdscript
PlanetGenerationResult.INVALID_ID # -1
```

### Full cell dictionary

```gdscript
var data := result.get_cell_data(Vector2i(500, 300))

print(data.height_m)
print(data.surface_elevation_m)
print(data.temperature_c)
print(data.precipitation)
print(data.biome_name)
print(data.water)
print(data.region_id)
print(data.ocean_region_id)
print(data.longitude_radians)
print(data.latitude_radians)
```

---

## 19. Projection and map coordinates

The global grid contract is:

```text
lambert_cylindrical_equal_area_v1
```

- X = longitude.
- Horizontal wrap is enabled.
- Y is proportional to `sin(latitude)`.
- Y is clamped at map limits.
- Raster ratio is approximately 2:1.
- Cell centres do not hit the exact poles.

This is **Lambert cylindrical equal-area**, not latitude-linear equirectangular projection.

---

## 20. Reopen a generated planet

```gdscript
var planet := PlanetGeneratorService.load_planet(
    "D:/MyGame/GeneratedPlanets/Earth"
)

if planet:
    print(planet.get_biome_name_at(Vector2i(500, 300)))
```

No regeneration occurs.

For repeated queries, reuse the loaded result. Runtime binary layers are accessed lazily with direct file seeks.

Release caches:

```gdscript
planet.clear_image_cache()
planet.clear_runtime_data_cache()
planet.clear_caches()
```

---

## 21. Complete integration example

```gdscript
func generate_from_standalone() -> void:
    var spec := PlanetGeneratorService.load_preset(
        "res://presets/test.planetGeneratorParam"
    )
    if spec == null:
        push_error("Preset load failed")
        return

    # Force all resource maps even if standalone exported "standard".
    spec.export_preset = "complete"

    # Use the exact requested folder.
    spec.output_root = "user://worlds/earth"
    spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

    # Keep exact height/climate/biome/water/region data.
    spec.export_runtime_query_data = true

    var job := PlanetGeneratorService.generate_planet(spec)

    job.progress.connect(
        func(phase, _completed, _total, ratio):
            print("%s %.1f%%" % [phase, ratio * 100.0])
    )

    var result := await job.wait_for_result()
    if result == null:
        push_error(str(job.error))
        return

    print("Iron map: ", result.has_layer("fer_map"))
    print("Petroleum map: ", result.has_layer("petrole_map"))

    var cell := Vector2i(100, 100)
    var data := result.get_cell_data(cell)

    print("Height: ", data.height_m)
    print("Temperature: ", data.temperature_c)
    print("Biome: ", data.biome_name)
```

---

## 22. Server/headless profile

```gdscript
spec.runtime_profile = PlanetGenerationSpec.PROFILE_SERVER
```

The addon has no standalone UI dependency, but generation is still GPU compute. A headless system must therefore still be capable of creating a compatible local `RenderingDevice`.

---

## 23. Performance guidance

- Use the plugin-owned runtime; do not instantiate internal GPU classes yourself.
- Reuse `PlanetGenerationResult` for repeated cell queries.
- Use `minimal` for lightweight runtime generation.
- Use `complete` only if all normal maps/resources are required.
- Prefer `custom` when only a few resource maps are needed.
- Clear result caches when unloading worlds.
- Generation jobs are serialized through the persistent GPU worker.

---

## 24. Tests

### Contract smoke test

```text
res://addons/planet_generator/tests/addon_contract_test.tscn
```

Checks public API contracts, preset import/compile, typed-query reader behavior, runtime registration and the climate-export regression guard.

### Real preset integration test

```text
res://addons/planet_generator/tests/preset_integration_test.tscn
```

Uses:

```text
res://addons/planet_generator/tests/fixtures/test.planetGeneratorParam
```

Fixture SHA-256:

```text
453603d5c0c77f25ec6f6d38b30973b55877b8832d198124093f6a95a72e6cf2
```

The DEV/TEST project uses the real GPU integration test as its default F5 scene.

### Planet Generator 3.1 regression test

```text
res://addons/planet_generator/tests/upstream_3_1_airless_resource_test.tscn
```

Exercises the upstream 3.1 changes through the addon-native runtime: disabled hydrology on airless/sterile-style worlds, administrative assignment on dry land, absence of petroleum on an airless world, non-trivial mineral deposit morphology, Complete export output, and the post-generation integrity checker.

Expected final line:

```text
[Planet Generator Addon] upstream 3.1 airless/resource regression: PASS
```

---

## 25. Migration notes

### Old service/autoload layout

When upgrading from addon.4 or older:

1. Disable the old plugin.
2. Remove the old `addons/planet_generator/`.
3. Copy the new addon.
4. Restart Godot if needed.
5. Enable the plugin.

Current naming:

```text
PlanetGeneratorService        = public class_name
PlanetGeneratorServiceRuntime = internal autoload
```

### Old generated planets

Use:

```gdscript
planet.has_runtime_data()
```

If false, regenerate with a current addon to obtain exact height/climate/region runtime data.

### addon.6 climate regression

addon.6 could lose the authoritative climate texture before runtime-data export. addon.7 fixed this; 3.1.0-addon.1 retains that fix. Worlds generated with the affected addon.6 build need regeneration for exact temperature/precipitation data.

---

## 26. Current limitations

- No current detailed local-zone generator.
- Stable production generation is the monolithic GPU path; tiled global generation remains experimental.
- Gas giants do not expose the same solid-surface typed runtime dataset.
- Resource deposits do not yet have a typed `get_resource_at()` API; use resource map layers.
- Compatibility/OpenGL cannot run compute generation.
- `get_precipitation_at()` is a normalized climate proxy, not a physical rainfall unit.

---

## 27. Package structure

```text
addons/planet_generator/
├── plugin.cfg
├── plugin.gd
├── README.md
├── docs/
│   ├── COMPLETE_DOCUMENTATION.md
│   ├── API_AND_INSTALL.md
│   ├── CHANGELOG_ADDON.md
│   └── MILESTONE_9.md
├── examples/
│   ├── basic_usage.gd
│   ├── complete_export_with_resources.gd
│   └── runtime_queries.gd
├── public/
│   ├── planet_generator_service.gd
│   ├── planet_generation_template.gd
│   ├── planet_generation_spec.gd
│   ├── planet_generation_job.gd
│   └── planet_generation_result.gd
├── runtime/
│   ├── core/
│   ├── data/
│   ├── gpu/
│   ├── io/
│   ├── service/
│   └── shaders/compute/
└── tests/
```

---

## 28. Recommended host-game pattern

Keep one generated `PlanetGenerationResult` while the world is active:

```gdscript
var current_planet: PlanetGenerationResult

func build_world(preset_path: String) -> bool:
    var spec := PlanetGeneratorService.load_preset(preset_path)
    if spec == null:
        return false

    spec.export_preset = "complete"
    spec.output_root = "user://worlds/current"
    spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

    var job := PlanetGeneratorService.generate_planet(spec)
    current_planet = await job.wait_for_result()
    return current_planet != null

func biome_at(cell: Vector2i) -> String:
    return "" if current_planet == null else current_planet.get_biome_name_at(cell)

func elevation_at(cell: Vector2i) -> float:
    return NAN if current_planet == null else current_planet.get_height_at(cell)
```

---

## 29. API stability

Public API version for this package:

```text
2
```

Stable game-facing classes:

```text
PlanetGeneratorService
PlanetGenerationTemplate
PlanetGenerationSpec
PlanetGenerationJob
PlanetGenerationResult
```

Check at startup if desired:

```gdscript
if PlanetGeneratorService.get_api_version() < 2:
    push_error("Planet Generator API v2+ required")
```

---

## 30. Quick reference

```gdscript
# Import standalone preset
var spec := PlanetGeneratorService.load_preset("res://world.planetGeneratorParam")

# Export resources too
spec.export_preset = "complete"

# Exact path
spec.output_root = "user://worlds/earth"
spec.output_mode = PlanetGenerationSpec.OUTPUT_EXACT_DIRECTORY

# Generate
var job := PlanetGeneratorService.generate_planet(spec)
var planet := await job.wait_for_result()

# Query
var biome := planet.get_biome_name_at(Vector2i(x, y))
var height_m := planet.get_height_at(Vector2i(x, y))
var temp_c := planet.get_temperature_at(Vector2i(x, y))
var cell := planet.get_cell_data(Vector2i(x, y))

# Resource map
var iron := planet.load_layer_image("fer_map")

# Cleanup
planet.clear_caches()
PlanetGeneratorService.shutdown()
```

End of complete documentation.
