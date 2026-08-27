#!/usr/bin/env python3
"""Run Planet Generator's M1–M7.7 regression scenes as isolated Godot processes.

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
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("godot", help="Godot 4 executable")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--output", default="m8_regression_report.json")
    args = parser.parse_args()

    project = pathlib.Path(__file__).resolve().parents[1]
    results = []
    for index, scene in enumerate(SCENES, 1):
        cmd = [args.godot, "--path", str(project)]
        if args.headless:
            cmd.append("--headless")
        cmd.append(scene)
        started = time.perf_counter()
        try:
            proc = subprocess.run(
                cmd,
                cwd=project,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=args.timeout,
            )
            output = proc.stdout or ""
            fatal_markers = ("SCRIPT ERROR", "Assertion failed", "Parse Error", "FATAL")
            ok = proc.returncode == 0 and "PASS" in output and not any(m in output for m in fatal_markers)
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
                "output_tail": (exc.stdout or "")[-8000:] if isinstance(exc.stdout, str) else "",
            }
        results.append(result)
        print(f"[{index:02d}/{len(SCENES)}] {'PASS' if result['ok'] else 'FAIL'} {scene}")

    report = {
        "regression_report_version": 1,
        "result": "PASS" if all(r["ok"] for r in results) else "FAIL",
        "tests": results,
    }
    out = pathlib.Path(args.output)
    if not out.is_absolute():
        out = project / out
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Report: {out}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
