#!/usr/bin/env python3
"""Generic SWIF failure diagnosis helper for template workflows."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

ACTIVE_STATES = {"attempting", "running", "submitted", "pending", "queued", "ready", "dispatched"}
SUCCESS_STATES = {"succeeded", "success", "complete", "completed", "done"}
FAILED_STATES = {"failed", "problem", "aborted", "cancelled", "canceled", "held", "killed", "timeout", "timed_out"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Diagnose SWIF workflow failures from JSON status output.")
    parser.add_argument("workflow", help="SWIF workflow name")
    parser.add_argument("--swif2-bin", default="swif2", help="SWIF2 executable")
    parser.add_argument("--status-json", type=Path, help="Optional captured SWIF JSON status payload")
    parser.add_argument("--show-unknown-keys", type=int, default=3, help="Print key samples for unknown-state jobs")
    return parser.parse_args()


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def _normalized_key(key: str) -> str:
    return "".join(ch for ch in key.lower() if ch.isalnum())


def flatten_items(obj: Any, prefix: str = "", depth: int = 0, max_depth: int = 2) -> Iterable[tuple[str, Any]]:
    if isinstance(obj, dict):
        for key, value in obj.items():
            key_text = str(key)
            path = f"{prefix}.{key_text}" if prefix else key_text
            yield path, value
            if depth < max_depth and isinstance(value, (dict, list)):
                yield from flatten_items(value, path, depth + 1, max_depth)
    elif isinstance(obj, list):
        for i, value in enumerate(obj):
            path = f"{prefix}[{i}]" if prefix else f"[{i}]"
            yield path, value
            if depth < max_depth and isinstance(value, (dict, list)):
                yield from flatten_items(value, path, depth + 1, max_depth)


def extract_state(job: dict[str, Any]) -> str:
    candidates: list[str] = []
    for key_path, value in flatten_items(job):
        if not isinstance(value, str) or not value.strip():
            continue
        nk = _normalized_key(key_path)
        if any(token in nk for token in ("jobstate", "status", "state", "phase")):
            candidates.append(value.strip().lower())

    if not candidates:
        return "unknown"

    preferred = [
        value for value in candidates if any(token in value for token in ("attempt", "run", "pend", "queue", "fail", "success", "complete", "hold", "cancel", "abort", "time"))
    ]
    return preferred[0] if preferred else candidates[0]


def classify(state: str) -> str:
    if state in SUCCESS_STATES or any(state.startswith(prefix) for prefix in ("succeed", "complete", "done")):
        return "success"
    if state in ACTIVE_STATES or any(state.startswith(prefix) for prefix in ("attempt", "run", "pend", "queue", "dispatch", "ready")):
        return "active"
    if state in FAILED_STATES or any(state.startswith(prefix) for prefix in ("fail", "problem", "abort", "cancel", "hold", "kill", "time")):
        return "failed"
    return "unknown"


def extract_name(job: dict[str, Any]) -> str:
    for key_path, value in flatten_items(job, max_depth=1):
        if not isinstance(value, str) or not value.strip():
            continue
        nk = _normalized_key(key_path)
        if "jobname" in nk or nk.endswith("name"):
            return value
    return "<unknown>"


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
    unknown_jobs: list[dict[str, Any]] = []

    for job in jobs:
        state = extract_state(job)
        raw_states[state] += 1
        bucket = classify(state)
        bucket_counts[bucket] += 1
        if bucket == "failed":
            failures.append(job)
        elif bucket == "unknown":
            unknown_jobs.append(job)

    print(f"Workflow: {args.workflow}")
    print(f"Total jobs: {len(jobs)}")
    print("State buckets:")
    for key in ("active", "success", "failed", "unknown"):
        print(f"  {key}: {bucket_counts.get(key, 0)}")

    print("\nRaw state counts:")
    for state, count in sorted(raw_states.items()):
        print(f"  {state}: {count}")

    if failures:
        print(f"\nFailed jobs: {len(failures)}")
        for job in failures[:50]:
            print(f"  - {extract_name(job)}: state={extract_state(job)}")
        if len(failures) > 50:
            print(f"  ... truncated ({len(failures) - 50} more)")
    else:
        print("\nNo failed jobs detected.")

    if unknown_jobs and args.show_unknown_keys > 0:
        print(f"\nUnknown-state key samples (first {min(args.show_unknown_keys, len(unknown_jobs))} jobs):")
        for job in unknown_jobs[: args.show_unknown_keys]:
            keys = sorted({path for path, _ in flatten_items(job, max_depth=1)})
            print(f"  - {extract_name(job)} keys: {', '.join(keys[:20])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
