#!/usr/bin/env python3
"""Run Planet Generator's M1–M8.1 regression scenes as isolated Godot processes.

Usage:
    python tools/run_m8_regression_suite.py /path/to/godot
    python tools/run_m8_regression_suite.py /path/to/godot --headless

Each legacy regression scene is isolated because many of them intentionally call
get_tree().quit(). The resulting JSON can be supplied to ReleaseCandidateRunner
as `regression_report_path`.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import time

SCENES = [
    "res://tests/milestone_1_smoke.tscn",
    "res://tests/milestone_2_hydrology.tscn",
    "res://tests/milestone_3_optimization.tscn",
    "res://tests/milestone_4_coordinates.tscn",
    "res://tests/milestone_5_tiling.tscn",
    "res://tests/milestone_5_full_tiling.tscn",
    "res://tests/milestone_6_cartography.tscn",
    "res://tests/milestone_7_integrity.tscn",
    "res://tests/milestone_7_1_planet_project.tscn",
    "res://tests/milestone_7_2_export_system.tscn",
    "res://tests/milestone_7_3_ui_progress.tscn",
    "res://tests/milestone_7_4_map_viewer.tscn",
    "res://tests/milestone_7_5_templates.tscn",
    "res://tests/milestone_7_6_batch.tscn",
    "res://tests/milestone_7_7_ui_polish.tscn",
    "res://tests/milestone_8_release_stabilization.tscn",
    "res://tests/milestone_8_1_optimization.tscn",
]


def _output_text(value: object) -> str:
    """Return subprocess output as UTF-8 text without depending on Windows ACP."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _write_report(path: pathlib.Path, results: list[dict[str, object]]) -> None:
    completed = len(results)
    report = {
        "regression_report_version": 1,
        "result": "PASS" if completed == len(SCENES) and all(bool(r.get("ok", False)) for r in results) else "FAIL",
        "completed_tests": completed,
        "expected_tests": len(SCENES),
        "tests": results,
    }
    path.write_text(json.dumps(report, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("godot", help="Godot 4 executable")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--output", default="m8_regression_report.json")
    args = parser.parse_args()

    project = pathlib.Path(__file__).resolve().parents[1]
    out = pathlib.Path(args.output)
    if not out.is_absolute():
        out = project / out
    results: list[dict[str, object]] = []
    for index, scene in enumerate(SCENES, 1):
        cmd = [args.godot, "--path", str(project)]
        if args.headless:
            cmd.append("--headless")
        cmd.append(scene)
        started = time.perf_counter()
        print(f"[{index:02d}/{len(SCENES)}] RUN  {scene}", flush=True)
        try:
            proc = subprocess.run(
                cmd,
                cwd=project,
                text=True,
                encoding="utf-8",
                errors="replace",
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=args.timeout,
            )
            output = _output_text(proc.stdout)
            fatal_markers = (
                "SCRIPT ERROR",
                "Assertion failed",
                "Parse Error",
                "Compile Error",
                "ERROR: Failed to load script",
                "FATAL",
            )
            # M1-M6 predate the explicit "...: PASS" convention and signal
            # success through get_tree().quit(0). Requiring a literal PASS in
            # stdout therefore creates false failures for valid legacy tests.
            ok = proc.returncode == 0 and not any(m in output for m in fatal_markers)
            result = {
                "scene": scene,
                "ok": ok,
                "returncode": proc.returncode,
                "elapsed_ms": (time.perf_counter() - started) * 1000.0,
                "output_tail": output[-8000:],
            }
        except subprocess.TimeoutExpired as exc:
            result = {
                "scene": scene,
                "ok": False,
                "timeout": True,
                "elapsed_ms": (time.perf_counter() - started) * 1000.0,
                "output_tail": _output_text(exc.stdout)[-8000:],
            }
        except KeyboardInterrupt:
            result = {
                "scene": scene,
                "ok": False,
                "interrupted": True,
                "elapsed_ms": (time.perf_counter() - started) * 1000.0,
                "output_tail": "Interrupted by user.",
            }
            results.append(result)
            print(f"[{index:02d}/{len(SCENES)}] INTERRUPTED {scene}", flush=True)
            break
        results.append(result)
        _write_report(out, results)
        print(f"[{index:02d}/{len(SCENES)}] {'PASS' if result['ok'] else 'FAIL'} {scene}", flush=True)
        if not bool(result.get("ok", False)):
            tail = str(result.get("output_tail", "")).strip()
            if tail:
                print("--- Godot output tail ---", flush=True)
                print(tail, flush=True)
                print("--- end output tail ---", flush=True)

    _write_report(out, results)
    report = json.loads(out.read_text(encoding="utf-8"))
    print(f"Report: {out}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
