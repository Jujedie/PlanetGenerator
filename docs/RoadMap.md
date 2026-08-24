# PlanetGenerator — Final Development Roadmap

This document is the authoritative implementation roadmap for PlanetGenerator.
Milestones are completed in order. Work does not advance to the next milestone
until the current milestone's acceptance gate passes.

## 1. Product goals and locked constraints

PlanetGenerator will remain a standalone Godot 4.x application while the
generation system is developed and validated. After the complete application
passes its validation suite, a dedicated addon branch will package the stable,
UI-independent generator for direct use inside other Godot games.

### 1.1 Global solid-surface maps

- Maximum reference planet: Venus radius, 6,051.8 km.
- Canonical maximum grid: 30,339 × 15,170 cells.
- Projection target: equal-area.
- Cell meaning: approximately 1 pixel = 1 km².
- Storage and processing tile size: 2,048 × 2,048 pixels.
- Maximum-grid layout: 15 × 8 tiles, with cropped edge tiles.
- Every layer uses the same logical dimensions, coordinate transform, tile
  indices, edge rules, and generator version.
- Horizontal wrapping must be seamless.
- Hard generation ceiling: 5 GiB of VRAM.
- Preferred working ceiling: 4 GiB of VRAM or less.
- Identical seeds, parameters, and generator versions must produce identical
  results.

The maximum planet is represented by a logical tiled dataset, not by one
30,339-pixel-wide Godot texture.

### 1.2 Gas giants

- Gas giants generate atmospheric outputs only.
- Terrestrial precipitation, temperature, river, biome, region, resource, and
  surface-zone outputs are not generated unless a future atmospheric model
  explicitly requires an equivalent layer.
- The gas-giant path must remain deterministic, avoid dark artifacts and
  uncontrolled highlights, and support repeated generation without retained
  GPU resources.

### 1.3 Detailed local zones

- Each global solid-surface cell addresses a 1 km × 1 km local zone.
- Initial detailed-zone target: 1,024 × 1,024 samples, approximately 0.98 metres
  per local sample.
- Local generation uses absolute planet-space coordinates, shared global
  features, overlap halos, and deterministic seeds.
- Adjacent zones must be seamless and independent of request order.
- Gas giants do not expose solid-surface local zones.

### 1.4 Application and addon

- The standalone application is the reference implementation.
- All generator logic should be kept UI-independent where practical, even
  before addon extraction.
- No HTTP server, network port, or web backend will be implemented.
- After the application is complete, a dedicated addon branch will expose the
  generator through direct GDScript functions, asynchronous jobs, resources,
  and signals inside a consuming Godot game.

## 2. Development rules

- Correctness is established before performance optimization.
- Performance is measured before and after each optimization.
- Fixed benchmark seeds are retained for the lifetime of the project.
- Intermediate maps are used to identify the stage that introduces an artifact.
- Raw physical data is kept separate from display colors and cartographic
  overlays.
- Large-planet work must never rely on a full-resolution monolithic GPU texture.
- Each milestone includes deterministic regression tests where applicable.
- New code must preserve safe RenderingDevice ownership and reliable cleanup
  across cancellation, regeneration, application exit, and export.

## 3. Milestone roadmap

### Milestone 0 — Specification and roadmap

Status: complete (accepted 2026-08-18).

Deliverables:

- Locked physical scale, maximum grid, tile size, VRAM ceiling, local-zone
  contract, application-first release order, and addon strategy.
- Ordered milestones and explicit acceptance gates.

### Milestone 1 — Terrain, tectonics, crust age, and erosion correctness

Goal: make the current-resolution generator physically coherent and
deterministic before scaling it.

Status: in progress.

Current checkpoint (2026-08-19):

- Fixed benchmark seeds and an automated GPU smoke scene are present.
- Preliminary climate now feeds erosion; erosion ping-pong ownership and
  physical neighbour distances are corrected.
- Crust-age seeding, deterministic propagation, ocean-only subsidence, and the
  configured subsidence coefficient are corrected.
- Tectonic boundary relief is narrower and spatially modulated.
- Continental trenches can no longer cut through land, artificial interior
  lineaments have been removed, and continental-basin relief is continuous
  instead of being clamped to a single 150 m shelf.
- Hydraulic erosion is capped per pass and preserves a one-metre land margin
  above sea level, preventing erosion-only underwater canyons.
- Coloured and greyscale topographic PNGs now interpolate between elevation
  stops instead of quantizing broad areas into flat-looking colour shelves.
- Terrestrial and ocean administrative seed density now targets the requested
  hierarchy size. Higher tiers are adjacency-only, no longer merge unrelated
  IDs across the map seam, and their continent/ocean counts scale with radius.
- Administrative colours use a deterministic collision-resistant palette.
- Cloud output is a seamless straight-alpha RGBA8 texture with transparent
  clear sky and stylized clusters shaped by bands, dry belts, and storm tracks.
- Repeated terrestrial and gas-giant smoke generations are deterministic;
  gas giants exercise only their atmospheric phase and export only `final_map`.
- Duplicate state-texture allocations and final shared-device leaks found by
  the regression have been removed.
- Full-resolution visual comparison of all three terrestrial benchmark cases
  remains before this milestone can pass its acceptance gate.

Work:

1. Establish permanent benchmark seeds for a balanced terrestrial planet, a
   mountainous/dry planet, an ocean-heavy planet, and a gas giant.
2. Record per-stage duration, intermediate outputs, elevation statistics, GPU
   synchronization/readback counts, and available memory measurements.
3. Provide erosion with valid preliminary rainfall before hydraulic erosion;
   compute the final climate after erosion.
4. Correct erosion ping-pong buffer ownership so every iteration consumes the
   latest terrain state and leaves the final state in the authoritative texture.
5. Make slope and erosion calculations use a declared physical horizontal
   distance instead of assuming that one neighbour is one unit at every
   resolution.
6. Restrict spreading-ridge seeds to actual divergent oceanic boundaries.
7. Make crust-age propagation deterministic with separate read/write state.
8. Apply oceanic subsidence only to oceanic crust and make the configured
   subsidence coefficient effective.
9. Reduce continuous synthetic tectonic lineaments and prevent boundary types
   from being applied across broad plate-pair regions.
10. Verify gas-giant output selection and retain the existing stability guards
    for repeated generation.

Acceptance gate:

- Erosion produces visible and measurable terrain change.
- Continental interiors are not crossed by unexplained global trenches.
- Continental lowlands are not treated as old oceanic crust.
- The final erosion state is read by every downstream phase.
- Repeated runs with the same seed and parameters are identical.
- Gas giants export only intended atmospheric outputs.
- Available static and runtime validation passes without new shader or GDScript
  errors.

### Milestone 2 — Hydrology, lakes, and river correctness

Goal: build a conserved and hierarchical drainage system on the corrected
terrain.

Status: implementation and automated acceptance complete (2026-08-19).

Validation checkpoint:

- A deterministic Priority-Flood now converges by exhausting its priority
  queue; the former fixed 200-pass depression approximation is not used.
- D8 directions come directly from the Priority-Flood parent forest, making
  the drainage graph acyclic by construction and preserving periodic X links.
- Each land cell contributes precipitation once, followed by exact topological
  accumulation; `river_iterations` no longer affects the result.
- River hierarchy follows monotonic accumulated-flux thresholds without the
  former fixed 500-pass type-promotion loop.
- Lakes are derived from complete basin depth and filtered by a minimum
  connected area (32 cells by default), removing isolated depression speckle.
- The repeated 128 × 64 regression has identical hashes with
  `river_iterations` set to 1 and 9,999.
- At 942 × 471, all 261,110 land cells were processed with zero unresolved
  cells, zero non-polar sinks, 205 seam-crossing flow links, zero downstream
  flux/type violations, and relative mass error below 0.000000001.

Work:

- Replace fixed-pass depression filling with a convergent method.
- Calculate consistent downstream flow directions.
- Add precipitation once per cell and conserve accumulated flux.
- Remove river-layout dependence on an arbitrary propagation iteration count.
- Establish tributary, river, and major-river hierarchy.
- Separate real lakes from high-frequency one-pixel depressions.
- Preserve drainage across the horizontal planet seam.
- Ensure rivers terminate in oceans, valid lakes, or valid closed basins.

Acceptance gate:

- Flux is conserved within documented tolerances.
- River structure is stable when redundant iteration counts change.
- Tributaries converge into progressively larger rivers.
- Artificial lake speckle is removed.
- Hydrology is deterministic and horizontally seamless.

### Milestone 3 — Core optimization and resource lifecycle

Goal: optimize verified behavior before introducing maximum-scale tiling.

Status: complete (accepted 2026-08-23).

Validation checkpoint:

- Compute work now stays on one controlled local RenderingDevice queue. At the
  128 × 64 acceptance resolution, 327 dependent compute lists require only 7
  real submit/synchronization points (all at CPU solvers, readbacks, or final
  export readiness), instead of one blocking synchronization per dispatch.
- GPU, synchronization, readback, CPU conversion, PNG compression, tracked
  VRAM, system RAM, and total generation/export timings are exposed in the
  generation performance report.
- Textures have an explicit permanent/next-phase/temporary/export-only/debug
  lifecycle. After the final GPU consumer, 1,261,568 of 2,031,616 tracked VRAM
  bytes are released before export in the acceptance scenario.
- Mineral-resource state is RGBA8UI (4 bytes/cell), replacing its previous
  RGBA32F allocation (16 bytes/cell).
- Export reads and converts wide maps sequentially. The acceptance export held
  one RGBA32F CPU map at a time (131,072 bytes at 128 × 64), and mineral maps
  are materialized and compressed individually instead of retaining 115 full
  RGBA8 images simultaneously.
- The old generation-thread control is now `export_worker_count`: zero selects
  an automatic CPU policy, and an explicit value affects PNG/export CPU work
  only. It never creates additional GPU generation queues.
- Twenty consecutive 128 × 64 terrestrial generations produced the same final
  hash, released every context-owned RID after cleanup, and completed without
  retained texture, shader, pipeline, or uniform-set state.
- Milestone 1 terrain/atmosphere hashes and Milestone 2 hydrology/hierarchy
  hashes remain unchanged after batching and lifecycle optimization.

Work:

- Measure GPU simulation, synchronization, readback, CPU conversion, PNG
  compression, peak VRAM, peak system RAM, and total generation time.
- Batch dependent compute dispatches and remove unnecessary `rd.sync()` calls.
- Synchronize only at true CPU dependencies and readbacks.
- Categorize textures as permanent, next-phase, temporary, export-only, or
  debug-only; release or reuse them after their final consumer.
- Replace unnecessarily wide texture formats with R8, R16, R32F, R16UI,
  R32UI, or RGBA8 as appropriate.
- Remove simultaneous full-map RGBA32F CPU readbacks.
- Export map-by-map and later tile-by-tile.
- Replace the misleading generation-thread setting with an automatic,
  export-specific CPU worker policy.
- Keep a single controlled GPU generation queue.

Acceptance gate:

- Correctness benchmarks remain equivalent within documented tolerances.
- Synchronization and readback time are materially reduced.
- At least 20 consecutive current-resolution generations complete without
  retained VRAM, crashes, or blocked generation.
- Export memory no longer scales as multiple simultaneous RGBA32F maps.
- CPU worker count is automatic or explicitly labelled as export-only.

### Milestone 4 — Canonical coordinates and tiled layer contract

Goal: establish one authoritative coordinate and storage model for every map.

Work:

- Decouple physical radius from sampling resolution.
- Implement the equal-area logical coordinate system.
- Define world-to-global-cell and global-cell-to-world transforms.
- Define horizontal wrapping, polar behavior, tile addressing, edge cropping,
  layer formats, and no-data values.
- Define deterministic zoom/LOD downsampling rules.
- Write a versioned planet manifest containing seed, parameters, generator
  version, radius, projection, dimensions, cell area, tile size, layer formats,
  palette version, and checksums.

Acceptance gate:

- Every layer resolves a world coordinate to the same cell and tile.
- Coordinate conversions round-trip within documented precision.
- The tile set covers the logical grid exactly without gaps or overlaps.
- The maximum grid represents approximately one cell per km².

### Milestone 5 — Tiled global generation under 5 GiB

Goal: generate maximum-scale planets without monolithic textures.

Status: implementation present; full Venus-scale GPU acceptance pending runtime validation.

Work:

- Generate 2,048-pixel tiles with phase-specific overlap halos.
- Evaluate procedural fields in absolute planet coordinates.
- Crop halos only after neighbourhood-dependent processing.
- Store completed tile results outside active VRAM.
- Provide cross-tile tectonic, climate, and hydrology context.
- Implement hierarchical global drainage routing.
- Stream tile readbacks and exports.
- Reject allocations that would exceed the configured VRAM budget.
- Support cancellation and recovery without corrupting completed tiles.

Acceptance gate:

- Every phase remains below the 5 GiB hard ceiling and preferably below 4 GiB.
- No texture exceeds Godot or device dimension limits.
- Adjacent global tiles match at shared boundaries.
- Cancellation, cleanup, and regeneration leave the GPU usable.

### Milestone 6 — Cartographic rendering and colors

Goal: produce readable military-style topographic maps without baking style
into the physical simulation data.

Status: implementation present; visual/tile-seam acceptance pending runtime validation.

Work:

- Implement palette-driven terrain, water, and biome coloring.
- Add elevation contours, bathymetric contours, coastlines, subtle hillshade,
  coordinate grids, labels/markers, and zoom-dependent line widths.
- Suggested contour intervals:

| View | Minor contour | Major contour |
| --- | ---: | ---: |
| Planet | 250 m | 1,000 m |
| Regional | 50 m | 250 m |
| Local zone | 5 m | 25 m |

- Keep raw height, climate, water, biome, and region data independent of the
  selected display palette.

Acceptance gate:

- Changing palettes does not require regenerating physical data.
- Contours and hillshade remain seamless across tiles.
- Colors avoid uncontrolled brightness and retain readable terrain classes.
- Coastline, elevation, water, and grid information remain legible at each LOD.

### Milestone 7 — Seamless detailed 1 km² local zones

Goal: allow games to request deterministic high-resolution terrain for any
solid-surface global cell.

Work:

- Address a zone by planet ID, generator version, and global cell coordinate.
- Generate local data in absolute metre-space.
- Use global elevation, climate, hydrology, biome, coast, and tectonic features
  as the local macro constraints.
- Generate overlap halos and crop only after local processing.
- Run detailed erosion on regional patches rather than isolated 1 km zones.
- Refine globally defined rivers, coasts, faults, and future roads locally.
- Place vegetation, rocks, resources, and spawn data with deterministic
  world-space sampling.
- Cache versioned local-zone results.

Initial local outputs:

- Detailed height, normals, and slope.
- Refined local water depth, water presence, coast context, and flow vectors.
- Soil type (rock, gravel, sand, dirt, clay, silt, peat, volcanic, regolith, salt).
- Soil moisture and physical soil depth as independent authoritative layers.
- Rock classification and visible surface material (rock, sand, dirt, mud, grass, forest floor, peat, salt crust, snow, ice, shallow/deep water).
- Vegetation density, locally refined resource fields, snow/ice, spawn suitability, and hazard masks.
- Global precipitation, tectonic plates, river flux, and biome are macro constraints only; they are not blindly enlarged into local output maps.
- Administrative levels never participate in local physical generation.

Acceptance gate:

- A 3 × 3 group generated separately and in random order assembles without
  height, normal, hydrology, material, or object-placement seams.
- Shared boundary samples match exactly where exact equality is required.
- Repeating a request produces identical results.

### Milestone 8 — Standalone application stabilization

Goal: prove the complete generator before extracting an addon.

Work:

- Run a complete Venus-scale generation.
- Validate peak VRAM and system-RAM behavior.
- Validate deterministic global tile and local-zone hashes.
- Test cancellation and application exit during every major phase.
- Generate at least 50 planets consecutively without GPU lifecycle failures or
  increasing retained memory.
- Test all supported planet types and relevant output contracts.

Acceptance gate:

- Venus-scale generation stays below 5 GiB VRAM.
- Repeated generation, cancellation, cleanup, and export remain stable.
- The standalone application is considered the stable reference release.

### Milestone 9 — Dedicated Godot addon branch

Goal: package the proven generator for direct use inside Godot games.

This milestone begins only after Milestone 8 passes. A dedicated addon branch is
created from the validated application version.

Work:

- Package the stable core under an addon-oriented directory structure.
- Remove dependencies on application UI nodes, sliders, labels, and hard-coded
  temporary paths.
- Represent inputs with validated generation-spec resources.
- Expose asynchronous functions, jobs, resources, progress signals,
  cancellation, manifests, global-tile access, and local-zone requests.
- Preserve one safe RenderingDevice owner and one controlled GPU queue.
- Keep the standalone UI out of the distributed addon.
- Do not add HTTP, sockets, ports, or web-server infrastructure.

Representative in-game calls:

```gdscript
var planet_job = PlanetGeneratorService.generate_planet(spec)
var zone_job = PlanetGeneratorService.generate_local_zone(
    planet_id,
    Vector2i(global_x, global_y),
    1024
)
```

Acceptance gate:

- The addon can be enabled in a clean Godot 4.x game project.
- A game can generate planets and local zones through direct functions and
  signals without loading the standalone UI.
- Addon results match the validated standalone application.

### Milestone 10 — Consuming-game integration

Goal: validate real use of the addon in a game.

Work:

- Integrate the addon into a representative game project.
- Load global tiles by layer and LOD.
- Request and cache local zones during gameplay.
- Validate progress, cancellation, errors, cleanup, and save compatibility.
- Document the public resources, functions, signals, output formats, and version
  compatibility policy.

Acceptance gate:

- The game can call the generator directly without a web server or external
  process.
- Global and local data remain deterministic and seamless.
- Generation respects the same memory and lifecycle guarantees as the app.

## 4. Immediate execution order

The next implementation work is Milestone 1:

1. Establish benchmark seeds and per-stage evidence.
2. Correct erosion rainfall ordering and buffer flow.
3. Correct crust-age boundary seeding, propagation, and subsidence masking.
4. Make erosion distances resolution-aware.
5. Reduce unrealistic tectonic lineaments.
6. Run static/runtime validation and compare the fixed seeds.

Milestone 2 does not begin until the Milestone 1 acceptance gate passes.
