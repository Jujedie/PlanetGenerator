# Milestone 7 — Global Data Integrity

Planet Generator now runs a read-only integrity pass after the normal export while authoritative GPU textures are still available.

The pass checks canonical dimensions, raw layer byte formats, land/water administrative coverage, wrap-aware department connectivity, department size contracts, hydrology value domains, exported PNG dimensions and the global administrative color namespace. It writes `integrity_report.json` next to `planet_manifest.json`.

The checker never repairs the planet. A failure therefore points back to the generation or normalization phase that produced the invalid data.

Small disconnected physical domains that cannot be merged across land/water are counted separately as topological size exceptions; reusing one administrative ID for disconnected components is always an error.
