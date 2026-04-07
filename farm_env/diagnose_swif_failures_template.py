#!/usr/bin/env python3
"""Inspect workflow jobs and summarize non-success SWIF states."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Diagnose SWIF workflow failures from JSON status output.")
    parser.add_argument("workflow", help="SWIF workflow name")
    parser.add_argument("--swif2-bin", default="swif2", help="SWIF2 executable")
    return parser.parse_args()


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def main() -> int:
    args = parse_args()
    cmd = [args.swif2_bin, "status", args.workflow, "-jobs", "-display", "json"]
    result = run(cmd)
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        return result.returncode

    payload = json.loads(result.stdout or "{}")
    jobs = payload.get("jobs", []) if isinstance(payload, dict) else []

    statuses = Counter()
    problematic: list[dict] = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        status = str(job.get("status") or "UNKNOWN")
        statuses[status] += 1
        if status.upper() not in {"SUCCEEDED", "SUCCESS", "COMPLETE", "COMPLETED"}:
            problematic.append(job)

    print(f"Workflow: {args.workflow}")
    print(f"Total jobs: {sum(statuses.values())}")
    print("Status counts:")
    for status, count in sorted(statuses.items()):
        print(f"  {status}: {count}")

    if not problematic:
        print("\nNo failed/problematic jobs found.")
        return 0

    print(f"\nProblematic jobs: {len(problematic)}")
    for job in problematic[:50]:
        name = job.get("job_name", "<unknown>")
        status = job.get("status", "UNKNOWN")
        problem = job.get("problem") or job.get("exit_code") or ""
        print(f"  - {name}: status={status} {problem}")

    if len(problematic) > 50:
        print(f"  ... truncated ({len(problematic) - 50} more)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
