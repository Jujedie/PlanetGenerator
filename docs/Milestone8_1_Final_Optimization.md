# Milestone 8.1 — Final General Optimization

M8.1 is the last pass before 1.0 and is constrained by M8: generated data must not change.

Implemented low-risk optimizations:

- validate the shared local `RenderingDevice` only once per process instead of creating a throw-away validation texture for every generation;
- cache per-RID texture byte sizes used by VRAM telemetry, avoiding repeated `texture_get_format()` queries during phase/readback sampling;
- reuse SHA-256 results across ExportCatalog → PlanetManifest → PlanetProject when the file size/mtime fingerprint is unchanged;
- reuse the same checksum cache for tiled resume validation and remember hashes of tiles immediately after an atomic write;
- avoid re-hashing a tile that was just successfully written merely to prove the expected layer exists;
- keep tiled read caches on a tiny FIFO without allocating `Dictionary.keys()` arrays at every eviction;
- keep the checksum cache bounded so long batch/tiled runs cannot turn the optimization into a memory leak.

`FinalOptimizationGuard` compares an M8 baseline `release_candidate_report.json` with a post-M8.1 report. It requires identical deterministic layer hashes and rejects performance regressions above the configured tolerance. The guard reports median wall/sync/readback/export times and peak RAM/VRAM.

A final 1.0 candidate should therefore be tested in this order:

1. run M8 and save the baseline report;
2. apply M8.1;
3. rerun the identical M8 plan on the same machine;
4. compare both reports with `FinalOptimizationGuard`;
5. release only if M8 passes and the optimization guard passes.

### Acceptance hashes remain authoritative

The M8 release validator deliberately invalidates a cached checksum before it verifies each exported layer. This keeps the final acceptance gate byte-authoritative even on filesystems with coarse modification timestamps. The cache is used to remove redundant hashing elsewhere, never to weaken release validation.
