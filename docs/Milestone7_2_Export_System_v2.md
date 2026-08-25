# Milestone 7.2 — Export System v2

Exports are now organized into stable `maps/`, `maps/resources/`, `overlays/` and `debug/` folders. `export_catalog.json` records the selected preset, relative paths and SHA-256 checksums. Planet/project manifests are written after layout so their paths remain valid.

Presets are `minimal`, `standard`, `complete`, `development` and `custom`. Filtering affects presentation files only; it never changes authoritative simulation results or the integrity pass.
