# Planet Generator — Godot Addon

**Version:** `3.1.0-addon.1` · **API:** `2` · **Godot:** `4.7+`

GPU procedural planet-generation addon synchronized with Planet Generator 3.1.0 for use inside other Godot projects.

## Complete documentation

Read:

**[`docs/COMPLETE_DOCUMENTATION.md`](docs/COMPLETE_DOCUMENTATION.md)**

The complete guide covers installation, all five public classes, all 56 generation parameters, standalone `.planetGeneratorParam` import, exact output paths, export profiles, all 116 resource-related maps, async jobs, runtime getters, tests, migration and limitations.



## Upstream 3.1.0 synchronization

This release ports the standalone 3.1.0 generation changes while preserving the addon API v2:

- deterministic initialization of disabled hydrology textures for airless and sterile worlds;
- correct dry-world topography/cartography coloring across the full relief range;
- irregular anisotropic mineral bodies and vein morphology instead of round resource stamps;
- corrected resource-phase planet-type selection;
- preset-aware export stage planning, stale-output pruning and reduced unnecessary GPU readbacks/PNG work;
- reuse of the authoritative hydrology water mask during land/ocean administration;
- integrity validation that understands export presets and validates the disabled-hydrology contract.

The addon-specific runtime data writer, per-cell getters, standalone preset import, exact output paths and `PlanetGeneratorService` facade remain available.

## Install

Copy `addons/planet_generator/` into the host project and enable **Planet Generator** under **Project -> Project Settings -> Plugins**.

Actual generation requires a local `RenderingDevice`; use Forward+ or Mobile rather than Compatibility/OpenGL.

## Quick example

```gdscript
var spec := PlanetGeneratorService.load_preset(
    "res://presets/test.planetGeneratorParam"
)

# Override a standalone "standard" export if resource maps are required.
spec.export_preset = "complete"

var job := PlanetGeneratorService.generate_planet(spec)
var result := await job.wait_for_result()

if result:
    print(result.get_biome_name_at(Vector2i(100, 100)))
    print(result.get_height_at(Vector2i(100, 100)))
    var iron_map := result.load_layer_image("fer_map")
```

Public classes:

- `PlanetGeneratorService`
- `PlanetGenerationTemplate`
- `PlanetGenerationSpec`
- `PlanetGenerationJob`
- `PlanetGenerationResult`

Everything prefixed `PG...` is internal.
