# Planet Generator — Roadmap v2

## Implemented foundation
- M1–M3: global generator, hydrology and optimization foundation.
- M4: canonical equal-area coordinates.
- M5/5b: tiled maximum-scale generation.
- M6/6b/6c: palette-driven cartography and separate grid overlay.

## Final feature milestones

### M7 — Global Data Integrity
Read-only post-generation validation of canonical dimensions, land/water coverage, administrative topology and sizes, hydrology, seam behavior, export dimensions and administrative colors. Writes `integrity_report.json`.

### M7.1 — Reloadable Planet Projects
Persist a versioned `planet_project.json`, checksums and relative layer paths. Load a completed planet without rerunning physical simulation.

### M7.2 — Export System v2
Stable `maps/`, `maps/resources/`, `overlays/`, `debug/` layout, `export_catalog.json`, and Minimal/Standard/Complete/Development/Custom policies.

### M7.3 — Final UI/UX functional pass
Visible generation state, progress contract, memory estimate, safe cancellation semantics and valid control states.

### M7.4 — Advanced Map Viewer
Switch base maps, blend overlays, opacity, zoom/pan/reset and canonical coordinate inspection with a dynamic UI crosshair.

### M7.5 — Planet Templates & Presets
Coherent world templates and correlated SMART RANDOM generation while preserving the legacy unrestricted randomizer.

### M7.6 — Batch Generation / Benchmark
Sequential multi-seed generation through the normal pipeline with integrity checks, timing/RAM/VRAM metrics and `batch_report.json`.

### M7.7 — Final UI Polish
Responsive utility panels, non-obstructive layout, tooltips, shortcuts, planet-type aware controls and consistent feedback.

## Release milestones (not part of the current patch series)

### M8 — Release Stabilization
**Implemented acceptance harness; target-hardware execution required before release.** No new simulation features. Full regression inventory, 50 consecutive generations, all planet types, deterministic layer hashes, cancellation/cleanup/recovery tests, export/project validation, memory-drift analysis, package-resource validation and an opt-in maximum Venus-like tiled hardware gate. Writes `release_candidate_report.json`.

### M8.1 — Final General Optimization
**Implemented; benchmark comparison still requires target-hardware execution.** Reuses the M8 baseline to optimize repeated RenderingDevice validation, VRAM telemetry, file hashing and tiled resume/write verification without changing simulation algorithms. `FinalOptimizationGuard` requires identical deterministic layer hashes and rejects measured performance regressions beyond tolerance.

Planet Generator 1.0 is cut only after M8.1 passes its regression and performance gates.
