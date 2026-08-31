# Milestone 5 completion patch — tiled global pipeline

This patch adds the maximum-scale solid-surface generation path that was absent
from the first Milestone 5 infrastructure patch.

## Runtime contract

- `PlanetGenerator` automatically selects tiled generation when a monolithic
  working set would exceed the preferred 4 GiB estimate or a texture edge would
  exceed the safe 8192-pixel bound.
- A solid planet is generated phase-by-phase as 2048 × 2048 core tiles.
- Neighbourhood phases reconstruct only the required halo from completed tiles
  on disk. They never reconstruct the full planet in RAM or VRAM.
- Erosion is processed in chunks of at most 128 iterations. Each chunk uses a
  halo equal to its iteration count, then crops the core. Therefore results do
  not depend on tile boundaries.
- Terrain and climate randomness is addressed by absolute global coordinates.
- Hydrology uses a bounded global macro-routing grid (<=512 cells wide) plus
  local D8 refinement. This carries drainage context across tiles without a
  full-resolution global texture.
- Every completed core tile is atomically persisted before active GPU resources
  are released.
- Generation can be cancelled from the main thread while the single tiled GPU
  worker is active. Completed atomic tiles remain valid and are reused on the
  next run.
- Raw tiled layers are exported as a dataset. Display rendering remains the
  responsibility of Milestone 6.

## Stored layers

`height`, `plates`, `climate`, `water_mask`, `river_flux`, `flow_direction`,
`biome_id`, `region_map`, `ocean_region_map`, and `resources`, plus the optional
pre-erosion `height_base` cache.

## Validation

`tests/milestone_5_full_tiling.tscn` runs the same small planet with two
independent tile sizes and requires the authoritative raw layers to be byte
identical. It also validates Venus tile count/budget selection and cancellation.
A real Venus-scale runtime remains a Milestone 8 hardware acceptance test.
