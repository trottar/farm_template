#!/usr/bin/env python3
"""Generate plain-text bin-index lists for mc-single-arm farm submissions."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create one-integer-per-line bin list.")
    parser.add_argument("output", help="Output text file path")
    parser.add_argument("--start", type=int, default=0, help="First bin index (inclusive)")
    parser.add_argument("--count", type=int, help="Number of bins to emit")
    parser.add_argument(
        "--edges-file",
        type=Path,
        help="JSON file containing a dict of kin -> edge-array; count is inferred as len(edges)-1",
    )
    parser.add_argument("--kin", help="Kinematic key to select when using --edges-file")
    return parser.parse_args()


def resolve_count(args: argparse.Namespace) -> int:
    if args.count is not None:
        return args.count

    if args.edges_file and args.kin:
        edges_by_kin = json.loads(args.edges_file.expanduser().read_text(encoding="utf-8"))
        if args.kin not in edges_by_kin:
            valid = ", ".join(sorted(edges_by_kin.keys()))
            raise SystemExit(f"--kin '{args.kin}' not found in edges file. Valid keys: {valid}")

        edges = edges_by_kin[args.kin]
        if len(edges) < 2:
            raise SystemExit(f"Need at least two edges for {args.kin}; found {len(edges)}")
        return len(edges) - 1

    raise SystemExit("Either --count or both --edges-file and --kin are required")


def main() -> int:
    args = parse_args()
    if args.start < 0:
        raise SystemExit("--start must be >= 0")

    count = resolve_count(args)
    if count <= 0:
        raise SystemExit("bin count must be > 0")

    out_path = Path(args.output).expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines = [f"{idx}\n" for idx in range(args.start, args.start + count)]
    out_path.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote {count} bins to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
