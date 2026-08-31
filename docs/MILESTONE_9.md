# Milestone 9 — Core / Addon extraction

This package implements the post-1.0 Milestone 9 direction: **one engine, multiple frontends**.

## 9.1 Core extraction

**Implemented in this addon package.**

- Stable generator/GPU/export/data classes are copied into `addons/planet_generator/runtime/`.
- No standalone scene or UI class is required by the runtime.
- Shader and cartographic data paths are addon-local.
- Internal classes use the `PG` prefix to reduce collisions with a consuming game.
- The generic standalone `Enum` autoload dependency is replaced by the internal `PGPlanetData` static data class.
- Per-job output roots replace the standalone global temp-directory cleanup.

## 9.2 Stable public API

**Implemented.**

The host game calls only:

- `PlanetGeneratorService.generate_planet(...)`
- `PlanetGeneratorService.load_planet(...)`
- `PlanetGeneratorService.cancel_job(...)`
- `PlanetGeneratorService.shutdown()`
- public Template / Spec / Job / Result classes.

The backend `RenderingDevice`, GPU RIDs, shader pipelines and exporter implementation are not part of the public contract.

## 9.3 Shared Template API

**Implemented.**

`PlanetGenerationTemplate` is a `Resource` containing the canonical parameter schema. It supports:

- built-in presets;
- defaults;
- smart random generation;
- validation/clamping;
- dictionary import/export;
- JSON import/export;
- normal Godot Resource (`.tres`/`.res`) save/load.

This is the intended shared format for both a standalone frontend and game code.

## 9.4 Headless / backend usage

**API implemented; hardware-dependent runtime validation remains required.**

The addon has no dependency on visible UI nodes. `SERVER` disables presentation-oriented cartographic/grid exports by default. However, Planet Generator's compute path still needs a local `RenderingDevice`; whether a truly headless process can create it depends on the platform/driver.

No network service is added.

## 9.5 Runtime Data API

**Implemented for the current core.**

`PlanetGenerationResult` exposes:

- project and planet manifests;
- exported layer paths;
- `Image` and `Texture2D` loading;
- global cell sampling;
- grid dimensions;
- tile extraction;
- existing tiled-payload reads;
- reload of an already-generated planet.

The current core finishes by exporting authoritative results; this addon does not claim a zero-copy live-GPU-RID public API.

## 9.6 Tile / region streaming

**Current-core capability exposed, not algorithmically expanded.**

- Global map tiles can be requested from completed layer images.
- Existing tiled datasets can be read by layer / LOD / tile.
- The existing experimental tiled generation path and its production guard are preserved exactly instead of silently switching algorithms.

The old historical roadmap's detailed **1 km² local-zone generator is absent from the current 3.1.0 source baseline**. M9 does not fake it. Capability discovery reports `detailed_local_zones = false`.

## 9.7 Runtime modes

**Implemented.**

- `FULL`
- `RUNTIME`
- `SERVER`
- `EDITOR`

They select sensible output defaults and remain overrideable through the explicit export preset.

## 9.8 Standalone uses Core

**API boundary prepared; standalone migration is intentionally not bundled into this addon ZIP.**

The parameter compiler that used to live in the standalone `Master` node has been reproduced in `PlanetGenerationSpec.compile()`, and the canonical template is frontend-independent. The standalone repository can now be migrated to instantiate this same public API in a follow-up source integration without making the distributed addon depend on standalone scenes.

## 9.9 Addon packaging and independent tests

**Implemented for package/static contract; GPU acceptance remains target-machine work.**

- Godot editor-plugin layout (`addons/planet_generator/plugin.cfg`).
- `@tool` `EditorPlugin` registers/removes the internal `PlanetGeneratorServiceRuntime` autoload while `PlanetGeneratorService` remains the public global class.
- Addon-only ZIP distribution.
- Independent clean-project contract smoke test.
- Static packaging validation checks addon-local paths, shader completeness, public classes, UI/network isolation, and autoload setup.

### Runtime acceptance still to execute on target hardware

The package cannot honestly claim these without running Godot/Vulkan on a target machine:

1. enable plugin in a clean Godot 4.7+ project;
2. run `tests/addon_contract_test.gd`;
3. generate one fixed-seed terrestrial world and compare its authoritative hashes with the standalone 3.1.0 baseline;
4. generate a gas giant and compare baseline output;
5. cancel during major phases and regenerate;
6. run repeated jobs and confirm the shared RenderingDevice/GPU queue remains reusable.

