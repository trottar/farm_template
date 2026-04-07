#!/usr/bin/env python3
"""Generic SWIF rebalancing helper (summary-only template)."""

from __future__ import annotations

import argparse
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Show workflow summary to guide manual rebalancing.")
    parser.add_argument("workflow", help="SWIF workflow name")
    parser.add_argument("--swif2-bin", default="swif2", help="SWIF2 executable")
    parser.add_argument("--apply", action="store_true", help="Reserved for future auto-apply support")
    parser.add_argument("--no-run", action="store_true", help="Reserved for compatibility")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.apply:
        print("WARNING: --apply is not implemented in this template; showing summary only.")

    result = subprocess.run([args.swif2_bin, "status", args.workflow, "-summary"], text=True, capture_output=True, check=False)
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
