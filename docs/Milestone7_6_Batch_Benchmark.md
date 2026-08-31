# Milestone 7.6 — Batch Generation / Benchmark

The parameter workspace now exposes a Batch / Benchmark panel with planet count, first seed, start/cancel and translated status. The default batch is 10 planets; the release acceptance run remains 50.

`BatchGenerationRunner` runs planets sequentially through the normal asynchronous `PlanetGenerator` path. Every run gets a dedicated `seed_<n>` project directory, integrity checks are forced, and `batch_report.json` records success, integrity, elapsed time and available peak RAM/VRAM metrics.

The runner does not keep a second GPU simulation path. `PlanetGenerator.last_performance_report` snapshots orchestrator metrics before GPU resources are released, so benchmark results remain available after the normal worker cleanup.
