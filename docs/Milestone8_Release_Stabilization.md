# Milestone 8 — Release Stabilization

Milestone 8 freezes feature development and adds the release-candidate acceptance harness. The normal `PlanetGenerator` pipeline is reused; there is no alternate simulation path.

The full acceptance plan covers:

- 50 consecutive generations in one process;
- every supported planet type;
- two identical seed/parameter runs with layer-hash comparison;
- safe cancellation checkpoints and an immediate recovery generation after each checkpoint;
- post-cleanup RAM drift analysis;
- per-run Global Data Integrity + export/project validation;
- packaging/resource checks;
- presence of the M1–M7.7 regression scenes;
- optional maximum Venus-like tiled generation on target hardware.

The runner writes `release_candidate_report.json`. The isolated M1–M7.7 regression suite is executed with `tools/run_m8_regression_suite.py`; its JSON report is passed as `regression_report_path`. If the regression execution report or the maximum tiled test is intentionally skipped, the best possible result is `PASS_WITH_EXTERNAL_GATES`. Planet Generator 1.0 requires both external gates and therefore a final `PASS`.

The maximum-scale test is intentionally opt-in because a 30339×15170 authoritative dataset can require substantial disk space and wall-clock time. It must be run on the actual target GPU before release.

## Maximum tiled hardware gate

The opt-in Venus-like gate validates the actual `tiled_planet_manifest.json`: canonical dimensions, non-empty tile checksums, global hydrology context, `full_resolution_texture_allocated == false`, and an estimated active VRAM peak within the configured 5 GiB limit. It remains pending until executed on target Vulkan hardware.
