# Planet Generator

**Planet Generator** is a procedural planet-generation application built with **Godot 4**.  
It generates global, equirectangular planetary datasets and cartographic maps using a GPU-oriented pipeline, with asynchronous execution so the interface remains responsive during generation.

The project currently focuses on the **standalone generator**. Its architecture has been progressively refactored so the simulation, parameter model, project I/O, export system and UI are cleanly separated in preparation for a future reusable **Planet Generator Core / Godot addon**.

> **Development status:** the standalone feature set and release-validation infrastructure are implemented, but Planet Generator should not be treated as a final 1.0 release until the remaining target-hardware release gates and regression checks pass.

---

## What Planet Generator does

Planet Generator can create several classes of procedural worlds from a seed and a configurable set of physical and cartographic parameters.

For terrestrial worlds, the current pipeline can generate and combine:

- base topography and tectonic structure;
- oceanic crust age;
- optional cratering depending on world conditions;
- climate data;
- precipitation and cloud coverage;
- hydrology and drainage;
- lakes and rivers;
- ice caps;
- biomes;
- land administrative regions;
- maritime administrative regions;
- natural resources;
- physical/cartographic final maps;
- overlays and diagnostic layers.

Gas giants use a separate atmospheric generation pipeline rather than the terrestrial surface pipeline.

All global maps use an **equirectangular projection** with horizontal longitude wrapping. Recent biome generation also uses periodic selection/border noise so biome territories remain continuous across the `0° / 360°` seam.

---

## Current architecture

The current project no longer uses the old monolithic UI architecture.

### High-level structure

```text
                         ┌─────────────────────────┐
                         │         Master          │
                         │    thin orchestrator    │
                         └────────────┬────────────┘
                                      │
                 ┌────────────────────┼────────────────────┐
                 │                    │                    │
                 ▼                    ▼                    ▼
      ┌──────────────────┐  ┌────────────────────┐  ┌──────────────────┐
      │ ParameterWorkspace│  │ReferenceViewer     │  │BatchGeneration   │
      │                  │  │Workspace            │  │Runner            │
      └─────────┬────────┘  └────────────────────┘  └──────────────────┘
                │
                ▼
      ┌──────────────────────┐
      │ Parameter Schema /   │
      │ Templates / Presets  │
      └──────────┬───────────┘
                 │
                 ▼
      ┌──────────────────────┐
      │   PlanetGenerator    │
      │ asynchronous facade  │
      └──────────┬───────────┘
                 │
                 ▼
      ┌──────────────────────┐
      │ GPU Orchestrator /   │
      │ RenderingDevice      │
      └──────────────────────┘
```

### `Master`

`master.tscn` is intentionally minimal. `Master` is primarily responsible for:

- switching workspaces;
- starting/cancelling generation;
- wiring high-level signals;
- displaying generation state;
- handing completed data to the viewer;
- coordinating save/load/export actions;
- coordinating batch runs.

It is **not** the authoritative owner of every UI control or every generation parameter.

### Modular workspaces

The main interface is split into reusable components:

- **`ParameterWorkspace`** — parameters, planet templates, randomization, export policy and batch controls;
- **`ReferenceViewerWorkspace`** — generated-map display, base-layer/overlay selection, zoom, pan and inspection;
- **`BatchGenerationRunner`** — sequential multi-seed generation and benchmark reporting.

This is the supported architecture. The previous `ImageFrame/ImageMenu/...` style hierarchy and old static parameter/viewer UI are retired.

---

## Data-driven parameters

Generation controls are created dynamically from the parameter schema rather than being manually hard-coded into `master.tscn`.

The schema is centered around:

```text
src/scenes/planet_parameter_schema.gd
```

A parameter definition contains information such as:

```gdscript
{
    "key": "planet_radius",
    "category": "GENERAL",
    "kind": "slider",
    "label": "PLANET_RADIUS",
    "unit": " km",
    "default": 150.0,
    "min": 150.0,
    "max": 1500.0,
    "step": 50.0
}
```

`ParameterWorkspace` builds the corresponding controls and exposes the current parameter snapshot to the generator.

This allows the project to:

- add parameters without rebuilding the main scene;
- hide irrelevant parameter categories depending on planet type;
- keep templates and UI synchronized;
- reuse the same parameter contract in the future addon/backend;
- avoid making widgets the authoritative simulation state.

The project treats GDScript warnings strictly, so Variant-returning APIs should be cast or typed explicitly where required.

---

## Planet types

The current generator contains **seven main planet-type pipelines/configurations**:

| Type | Pipeline |
| --- | --- |
| Terran / Default | Full terrestrial surface pipeline |
| Toxic | Terrestrial pipeline with toxic world data/palette |
| Volcanic | Terrestrial pipeline with volcanic world data/palette |
| No Atmosphere / Airless | Terrestrial surface pipeline without normal atmospheric behavior |
| Dead | Terrestrial pipeline with dead-world configuration |
| Sterile | Terrestrial pipeline with sterile-world configuration |
| Gas Giant | Separate atmospheric gas-giant pipeline |

The non-gas terrestrial types now share the same physical final-map composition path instead of falling back to a flat biome-only render.

That final terrestrial composition can include:

```text
smoothed biome material
+ continuous elevation/climate surface
+ bathymetry
+ terrain lighting
+ rivers
+ ice overlays
```

while preserving the identity and palette of the selected planet type.

Gas giants remain separate and export their atmospheric final map rather than terrestrial surface layers.

---

## Built-in templates and presets

Planet templates live in the parameter workspace and are applied through the common parameter model.

The project includes presets for common terrestrial configurations and specialized worlds. Recent presets include:

- Earth-like;
- Archipelago;
- Supercontinent;
- Ocean World;
- Dry/Frozen/Mars-like configurations;
- High Tectonics;
- Low Relief;
- Volcanic World;
- Lava Ocean;
- Dead World;
- Irradiated Wasteland;
- Gas Giant;
- Hot Jupiter;
- Ice Giant;
- Storm Giant.

Gas-giant presets can configure parameters such as:

- atmospheric band count;
- jet strength;
- eddy strength;
- advection step;
- advection iterations;
- cloud-contrast retention.

The template system is designed to become the shared parameter contract between the standalone application and the future addon.

---

## Generation pipeline

### Terrestrial worlds

A normal terrestrial generation follows the physical pipeline coordinated by the GPU orchestrator.

The exact phases vary with planet type and enabled features, but the current system includes stages equivalent to:

```text
Base elevation / tectonics
        ↓
Oceanic crust age
        ↓
Cratering when applicable
        ↓
Pre-erosion climate
        ↓
Surface hydrology / erosion preparation
        ↓
Climate / precipitation / clouds
        ↓
Hydrology, lakes, drainage and rivers
        ↓
Ice caps
        ↓
Biome classification + smoothing
        ↓
Land administration
        ↓
Ocean administration
        ↓
Resources
        ↓
Final physical/cartographic rendering
        ↓
Integrity / project metadata / export
```

Generation is seed-driven and the release tests compare authoritative layer hashes to guard determinism.

### Hydrology

Hydrology is one of the most computation-heavy parts of the terrestrial pipeline.

The current design preserves exact drainage behavior and includes:

- surface preparation;
- Priority-Flood based depression handling;
- horizontal seam wrapping;
- lake/water-component handling;
- deterministic D8 flow direction;
- conservative flow accumulation;
- river-source and river-class generation;
- river biome/type mapping.

The hydrology/admin hot path has been optimized without intentionally changing the authoritative result, including native packed-array conversions, reduced per-pixel decoding and batched GPU command recording.

### Administrative regions

The project generates both:

- land administrative regions;
- ocean/maritime administrative regions.

Important data contracts include:

- land is determined from the water mask, not only from elevation;
- disconnected components must not silently share the same administrative component identity;
- administrative colors/IDs are kept byte-distinct;
- water administration must cover the generated water surface;
- the equirectangular seam is treated as a real horizontal neighbor relation.

### Rivers

`river_map` and `river_type_map` describe the same river presence mask.

`river_type_map` changes classification/color information, but must not invent additional river pixels that do not exist in `river_map`.

---

## Gas-giant pipeline

Gas giants do not run the normal terrestrial surface simulation.

Their atmospheric renderer uses dedicated compute stages including concepts such as:

```text
velocity initialization
dye / atmospheric field initialization
advection
band / jet / eddy evolution
final atmospheric composition
```

A gas-giant export is intentionally atmospheric-focused. It may still contain project/export metadata, but it does not produce the normal terrestrial map set.

---

## GPU generation and asynchronous execution

Planet Generator uses a local Godot **`RenderingDevice`** and compute shaders for the GPU-oriented parts of the pipeline.

Generation is executed through an asynchronous worker path so long-running simulations do not freeze the main UI.

The current runtime architecture also includes:

- safe generation request epochs;
- cancellation at safe boundaries;
- GPU cleanup after generation;
- shared RenderingDevice validation;
- VRAM/system-RAM metrics;
- cached texture-size telemetry;
- reduced redundant GPU/readback work.

---

## Large planets and tiled generation

Large global worlds can use the tiled pipeline rather than requiring every authoritative layer to exist as one full-resolution in-memory texture.

The tiled architecture provides:

- canonical global dimensions;
- deterministic tile coordinates;
- tile halos where required;
- per-layer tile storage;
- checksums;
- resume/integrity support;
- bounded tile read caches;
- reduced full-resolution VRAM pressure.

The release harness includes an optional very-large, Venus-like hardware validation path. This gate is intentionally opt-in because it must be executed on the real target Vulkan hardware and can require substantial runtime and disk space.

---

## Map viewer

The advanced viewer is implemented in `ReferenceViewerWorkspace`.

Current functionality includes:

- direct base-map selection;
- independent overlay selection;
- overlay opacity;
- zoom;
- pan;
- reset view;
- pixel/cell inspection;
- crosshair;
- coordinate/value display;
- keyboard cycling between maps;
- responsive layout.

Zoom is centered toward the mouse position rather than always zooming around the map center.

### Keyboard shortcuts

Current UI shortcuts include:

| Shortcut | Action |
| --- | --- |
| `V` | Switch between Parameters and Map Viewer |
| `B` | Open/toggle Batch from the parameter workspace |
| `Left`, `A` or `Q` | Previous base map |
| `Right` or `D` | Next base map |
| `Shift` + previous/next shortcuts | Cycle viewer overlays |
| `Ctrl+0` | Reset viewer zoom/pan |
| `Esc` | Close the Batch panel |

The parameter preview also supports base-map cycling.

---

## Responsive and localized UI

The standalone UI targets a logical **1600×900** workspace and uses fractional stretch scaling so the application can be resized below the reference size without integer-scaling clipping.

The UI is designed to recompute geometry after:

- window resizing;
- theme changes;
- font-scale changes;
- translation changes.

The current translation infrastructure includes English, French and German UI content.

---

## Save and reload planet projects

A completed generation can be persisted as a reloadable planet project.

The project format is centered around:

```text
planet_project.json
```

and uses versioned metadata, relative paths and checksums.

The goal of a loaded project is to reopen a completed planet and its generated layers **without rerunning the full physical simulation**.

This allows the standalone to:

- inspect an existing planet;
- reopen its viewer layers;
- validate stored files;
- re-export data according to another export policy;
- keep generation metadata associated with the planet.

---

## Export system v2

Exports use a stable catalog/metadata model instead of being only a loose collection of PNG files.

The canonical logical layout is:

```text
<planet>/
├── maps/
│   └── resources/
├── overlays/
├── debug/
├── integrity_report.json
├── export_catalog.json
├── manifest.json
└── planet_project.json
```

The exact files present depend on the planet type and selected export policy.

### Export presets

The UI currently exposes these primary policies:

| Preset | Purpose |
| --- | --- |
| **Minimal** | Essential maps + project metadata |
| **Standard** | Normal user-facing map set, without resource/debug-only output |
| **Complete** | Standard + resource maps |
| **Development** | Complete + diagnostic/debug layers |
| **Custom** | Programmatic/customized selection where supported |

The export choice is preserved with saved parameter presets/templates.

Debug-only layers stay out of normal exports. For example, normal standard output keeps useful plate/river classification products while plate-border diagnostics remain development/debug-oriented.

### Integrity metadata

Generation/export can write an:

```text
integrity_report.json
```

that checks contracts such as:

- canonical dimensions;
- land/water coverage;
- administrative topology;
- administrative sizes;
- hydrology consistency;
- seam behavior;
- exported-file expectations;
- administrative color uniqueness.

A `SKIP` result means a check was not applicable or its authoritative raw layer was not present; it is not automatically equivalent to a failure.

---

## Batch generation and benchmarking

Planet Generator includes a batch/benchmark workflow that uses the **same normal asynchronous `PlanetGenerator` path** as interactive generation.

The batch system can:

- run multiple seeds sequentially;
- preserve a common base configuration;
- force integrity checks;
- collect elapsed time;
- collect GPU simulation timing;
- collect peak VRAM;
- collect peak system RAM;
- collect per-run integrity results;
- export each seed separately.

Typical output is organized under:

```text
user://batch/<batch-name>_<timestamp>/
├── <seed-1>/
├── <seed-2>/
├── ...
└── batch_report.json
```

Performance metrics are snapshotted before GPU cleanup so the runner can still report them after a generation has released its GPU resources.

---

## Release validation

The M8 release harness is designed to validate the normal generator rather than introducing a second special-case generation path.

It includes checks for:

- repeated generation in one process;
- all supported planet types;
- deterministic A/B generation;
- authoritative layer hashes;
- cancellation and recovery;
- cleanup behavior;
- RAM drift;
- project reload;
- export validity;
- integrity reports;
- required package/shader resources;
- regression scenes;
- optional maximum-size tiled hardware generation.

Typical release output:

```text
release_candidate_report.json
```

The regression launcher is:

```bash
python tools/run_m8_regression_suite.py /path/to/godot --output m8_regression_report.json
```

Use `--headless` only on systems where the selected Godot/Vulkan setup can create the required `RenderingDevice` in headless mode.

### M8.1 optimization guard

The final optimization stage intentionally avoids changing generation algorithms.

Optimizations include areas such as:

- repeated RenderingDevice validation;
- VRAM telemetry;
- checksum caching;
- tile verification;
- small tile caches;
- redundant allocations/readbacks.

`FinalOptimizationGuard` compares the optimized run against the M8 baseline and rejects changed authoritative hashes or unacceptable performance/memory regressions.

---

## Testing

The repository contains milestone/regression scenes for the major data contracts and UI behaviors.

The complete regression suite can be launched through:

```bash
python tools/run_m8_regression_suite.py /path/to/godot
```

For Windows, for example:

```powershell
python .\tools\run_m8_regression_suite.py `
  "H:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
```

Some GPU scenes should be run without `--headless` if the local driver/backend does not expose a usable RenderingDevice in headless mode.

Static checks are useful, but they do not replace runtime Vulkan/Godot validation.

---

## Running the standalone project

### Requirements

- Godot 4.x with RenderingDevice / compute-shader support;
- a Vulkan-capable GPU/driver for the GPU generation path;
- Python 3 for the regression-suite helper scripts.

The project has recently been validated around the Godot 4.7.x toolchain, but the repository's own project/export configuration remains the authoritative compatibility reference.

### Start from the editor

Open the repository as a Godot project and run the main project scene.

The application starts in the **Parameters** workspace.

Typical workflow:

1. choose a planet type or template;
2. adjust generation parameters;
3. optionally choose an export preset;
4. generate the planet;
5. follow progress/status while the asynchronous generator runs;
6. inspect the result in the Map Viewer;
7. combine a base map with an overlay if desired;
8. save/export the planet;
9. later reload the saved planet project without regenerating it.

---

## Important directories

The exact tree evolves, but the current architecture is organized around areas such as:

```text
src/
├── classes/
│   ├── classes_gpu/
│   └── classes_io/
└── scenes/

shader/
└── compute/
    ├── biome/
    ├── hydrology/
    └── ...

data/
├── img/
│   └── UI/
└── translations/

tests/
tools/
docs/
```

Important components include:

```text
src/scenes/master.gd
src/scenes/planet_parameter_schema.gd

ParameterWorkspace
ReferenceViewerWorkspace

PlanetGenerator
GPUOrchestrator
GPUGenerationWorker
PlanetExporter
ExportCatalog
Planet project / manifest helpers
BatchGenerationRunner
ReleaseCandidateRunner
FinalOptimizationGuard
```

---

## Current design principles

Development should preserve the following contracts.

### One generation path

Interactive generation, batch tests and future addon calls should converge on the same authoritative generator rather than maintaining unrelated implementations.

### The UI is not the simulation state

Generation parameters belong to a serializable parameter/template model. UI controls are an editor/view over that data.

### Equirectangular wrap is real topology

The first and last map columns are neighbors. Algorithms that add noise, smooth regions, calculate climate or process borders must preserve this horizontal continuity.

### Determinism is authoritative

Performance optimizations must not silently change authoritative output for the same seed/configuration unless the change is an intentional generation change.

### PNG is an output format, not the future data API

The standalone currently exports maps and projects, but the planned reusable core will expose physical layers directly to games without forcing them through PNG files.

---

## Roadmap

### Standalone

The standalone roadmap up to release is:

```text
M1–M3   Global generator / hydrology / optimization foundation
M4      Canonical planetary coordinates
M5/5b   Tiled large-scale generation
M6      Palette-driven cartography / grid overlays
M7      Global Data Integrity
M7.1    Reloadable Planet Projects
M7.2    Export System v2
M7.3    Functional UI/UX
M7.4    Advanced Map Viewer
M7.5    Templates / presets / parameter model
M7.6    Batch / Benchmark
M7.7    Modular UI / final polish
M8      Release Stabilization
M8.1    Final General Optimization
```

M8/M8.1 provide the release and optimization infrastructure; the remaining release decision depends on passing the required runtime/hardware gates on the target machine.

### Future: reusable Core / addon

The addon is a **post-1.0 architecture goal**, not the current public runtime interface.

The intended direction is:

```text
PlanetGeneratorCore
        │
        ├── Standalone UI
        └── Godot addon / game backend
```

Planned work includes:

- extracting simulation code from standalone UI dependencies;
- a stable public generation API;
- a shared `PlanetGenerationTemplate` API;
- headless/backend generation;
- direct runtime layer access;
- tile/region streaming;
- runtime profiles such as FULL / RUNTIME / SERVER / EDITOR;
- making the standalone itself consume the public core API;
- addon packaging and independent addon tests.

The key rule is:

> **One engine, multiple frontends.**

A template produced by the standalone should eventually be consumable directly by another game, and a template produced in code should be loadable by the standalone without a frontend-specific conversion step.

---

## Contributing / development notes

When modifying the generator:

1. preserve the modular UI architecture;
2. do not reintroduce old static `master.tscn` controls;
3. add new user-facing parameters through the parameter schema/model;
4. preserve horizontal equirectangular wrapping;
5. keep gas-giant and terrestrial contracts distinct;
6. do not approximate hydrology merely for performance without an intentional design decision;
7. run the relevant milestone test;
8. run the full regression suite before release-oriented changes;
9. compare deterministic hashes for optimization-only work;
10. distinguish **static validation** from actual Godot/Vulkan runtime validation.

---

## License

See the repository license file for the current licensing terms.

v3.1.0