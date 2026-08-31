# Planet Generator Addon — Changelog

## 3.1.0-addon.1
- Synchronized the generation core with standalone Planet Generator 3.1.0 (`76c1513c49539716f541dac67294ce29479b57de`).
- Added explicit disabled-hydrology GPU initialization for airless/sterile worlds, with CPU fallback.
- Added dry-relief topography/cartography remapping so waterless negative elevations remain land-colored.
- Ported irregular anisotropic mineral-lens/vein morphology and corrected resource planet-type selection.
- Ported preset-aware export stage planning, stale-output pruning, paired river conversion and reduced readbacks.
- Reused the authoritative water mask across administrative phases.
- Updated integrity validation for export presets and canonical disabled-hydrology values.
- Added an addon-native airless/resource regression scene.
- Preserved API v2, runtime query datasets/getters, standalone preset import and exact-output support.

## 3.0.0-addon.8
- Added complete embedded addon documentation.
- Added complete 56-parameter reference.
- Documented all 116 resource-related maps and addon-side export configuration.
- Added complete-resource-export and runtime-query examples.
- Clarified projection, output policy, standalone preset overrides, testing and migration.
- Public API remains version 2.

## 3.0.0-addon.7
- Fixed climate GPU texture lifetime so `temperature_c` and `precipitation` persist correctly.
- Added climate export regression coverage.

## 3.0.0-addon.6
- Added real end-to-end generation test using a standalone `.planetGeneratorParam`.

## 3.0.0-addon.5
- Made `PlanetGeneratorService` a real global `class_name`.
- Moved stateful runtime to the separate `PlanetGeneratorServiceRuntime` autoload.

## 3.0.0-addon.4
- Added persisted runtime query data and typed per-cell getters.

## 3.0.0-addon.3
- Added standalone preset import and safe exact output directories.

## 3.0.0-addon.1–2
- Initial Milestone 9 extraction and packaging/test fixes.
