# Milestone 7.1 — Reloadable Planet Projects

Every export now writes `planet_project.json`. It records the planet identity, stable generation parameters, version, layer paths and SHA-256 hashes. `PlanetProject.load_project()` resolves those paths and rejects broken/newer projects.

The main UI receives a **LOAD PLANET** button. Loading a project releases the active generator and opens the already-generated PNG layers without re-running tectonics, erosion, climate or hydrology.

Metadata JSON is explicitly filtered out of the legacy map carousel, fixing the old behavior where manifests could be handed to `Image.load()` as if they were PNGs.
