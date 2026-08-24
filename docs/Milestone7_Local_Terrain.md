# Milestone 7 — Deterministic local terrain

Each solid global cell addresses a **1 km × 1 km** high-resolution zone. The
recommended gameplay resolution is 1024² (~0.98 m/sample); tests may use lower
resolutions because the coordinate contract is resolution-independent.

## Macro inputs

M7 reads elevation, climate (temperature + precipitation/humidity), hydrology,
biome, tectonic context and resources. These are **constraints**, not enlarged
copies. Administrative layers are excluded from physical generation.

The M5 tiled dataset is read directly through `GlobalMacroSampler`; a maximum
planet therefore does not need to reconstruct monolithic global textures before
a local zone can be requested.

## Authoritative local layers

- `height` — R32F metres
- `normals` — RGBA8 encoded XYZ
- `slope` — R32F radians
- `water_depth` — R32F metres
- `water_mask` — R8 (0 dry, 1 salt/standing, 2 fresh/standing, 3 refined river)
- `flow` — RGBA8 (encoded XY direction, strength, coast proximity)
- `soil_type` — R8 enum
- `soil_moisture` — R8 normalized
- `soil_depth` — R32F metres
- `rock_type` — R8 enum
- `surface_material` — R8 enum
- `vegetation_density` — R8 normalized
- `resources` — RGBA8 locally refined resource channels
- `snow_ice` — R8 normalized
- `spawn_mask` — R8 normalized suitability
- `hazard` — R8 normalized terrain/environment hazard

`LocalSurfaceCatalog` defines stable soil, rock and surface IDs.

## Seam contract

All procedural detail is sampled in absolute metre-space. Continuous global
macro fields are evaluated from global coordinates, including samples outside a
requested zone when normals are computed. Therefore the right edge of `(x,y)`
is byte-identical to the left edge of `(x+1,y)`, and the same applies vertically.
Generation order does not affect results.

## Cache and previews

`LocalZoneCache` stores raw image payloads with SHA-256 checksums and a versioned
contract. `LocalZoneDebugExporter` can emit human-readable PNGs for height,
water, soil, surface, vegetation, resources, snow/ice and hazards. Those PNGs
are debug/tooling products; cached raw layers remain authoritative.
