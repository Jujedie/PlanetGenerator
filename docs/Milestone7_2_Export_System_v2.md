# Milestone 7.2 — Export System v2

Exports are now organized into stable `maps/`, `maps/resources/`, `overlays/` and `debug/` folders. `export_catalog.json` records the selected preset, relative paths and SHA-256 checksums. Planet/project manifests are written after layout so their paths remain valid.

Presets are `minimal`, `standard`, `complete`, `development` and `custom`. Filtering affects presentation files only; it never changes authoritative simulation results or the integrity pass.

## Preset policy

- `minimal`: final map, cartographic map, water, rivers, biomes and metadata.
- `standard`: normal user-facing maps and overlays, excluding resource maps and debug-only layers.
- `complete`: everything from Standard plus all resource maps; debug-only layers remain excluded.
- `development`: everything from Complete plus diagnostic/debug layers.
- `custom`: only explicitly enabled presentation keys, while mandatory metadata is always retained.

Resource classification is path-aware because resource keys are dynamic (`aluminium_map`, `fer_map`, etc.). Both legacy `ressource/` paths and canonical `maps/resources/` paths are recognized.
