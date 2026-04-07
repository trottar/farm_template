#!/usr/bin/env python3
"""Inspect workflow jobs and summarize SWIF states with robust key handling."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

ACTIVE_STATES = {
    "attempting",
    "running",
    "submitted",
    "pending",
    "queued",
    "ready",
    "dispatched",
}
SUCCESS_STATES = {"succeeded", "success", "complete", "completed", "done"}
FAILED_STATES = {
    "failed",
    "problem",
    "aborted",
    "cancelled",
    "canceled",
    "held",
    "killed",
    "timeout",
    "timed_out",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Diagnose SWIF workflow failures from JSON status output.")
    parser.add_argument("workflow", help="SWIF workflow name")
    parser.add_argument("--swif2-bin", default="swif2", help="SWIF2 executable")
    parser.add_argument(
        "--status-json",
        type=Path,
        help="Optional path to pre-fetched `swif2 status ... -display json` payload (for offline debugging)",
    )
    return parser.parse_args()


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def first_non_empty(job: dict[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        value = job.get(key)
        if value is not None and str(value).strip() != "":
            return str(value)
    return ""


def extract_state(job: dict[str, Any]) -> str:
    raw = first_non_empty(
        job,
        (
            "status",
            "job_state",
            "state",
            "jobStatus",
            "phase",
            "job_phase",
        ),
    )
    return raw.strip().lower() if raw else "unknown"


def classify(state: str) -> str:
    if state in SUCCESS_STATES:
        return "success"
    if state in ACTIVE_STATES:
        return "active"
    if state in FAILED_STATES:
        return "failed"
    return "unknown"


def load_jobs(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.status_json:
        payload = json.loads(args.status_json.expanduser().read_text(encoding="utf-8"))
    else:
        cmd = [args.swif2_bin, "status", args.workflow, "-jobs", "-display", "json"]
        result = run(cmd)
        if result.returncode != 0:
            if result.stdout:
                print(result.stdout.rstrip())
            if result.stderr:
                print(result.stderr.rstrip(), file=sys.stderr)
            raise SystemExit(result.returncode)
        payload = json.loads(result.stdout or "{}")

    jobs = payload.get("jobs", []) if isinstance(payload, dict) else []
    return [job for job in jobs if isinstance(job, dict)]


def main() -> int:
    args = parse_args()
    jobs = load_jobs(args)

    raw_states = Counter()
    bucket_counts = Counter()
    failures: list[dict[str, Any]] = []

    for job in jobs:
        state = extract_state(job)
        raw_states[state] += 1
        bucket = classify(state)
        bucket_counts[bucket] += 1
        if bucket == "failed":
            failures.append(job)

    print(f"Workflow: {args.workflow}")
    print(f"Total jobs: {len(jobs)}")
    print("State buckets:")
    for key in ("active", "success", "failed", "unknown"):
        print(f"  {key}: {bucket_counts.get(key, 0)}")

    print("\nRaw state counts:")
    for state, count in sorted(raw_states.items()):
        print(f"  {state}: {count}")

    if not failures:
        print("\nNo failed jobs detected.")
        return 0

    print(f"\nFailed jobs: {len(failures)}")
    for job in failures[:50]:
        name = first_non_empty(job, ("job_name", "name", "jobName")) or "<unknown>"
        state = extract_state(job)
        detail = first_non_empty(job, ("problem", "exit_code", "exitCode", "error"))
        print(f"  - {name}: state={state} {detail}")
    if len(failures) > 50:
        print(f"  ... truncated ({len(failures) - 50} more)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
