#!/usr/bin/env python3
"""Generate a plain-text bin-index list for mc-single-arm farm submissions."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create one-integer-per-line bin list.")
    parser.add_argument("output", help="Output text file path")
    parser.add_argument("--start", type=int, default=0, help="First bin index (inclusive)")
    parser.add_argument("--count", type=int, required=True, help="Number of bins to emit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.start < 0:
        raise SystemExit("--start must be >= 0")
    if args.count <= 0:
        raise SystemExit("--count must be > 0")

    out_path = Path(args.output).expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines = [f"{idx}\n" for idx in range(args.start, args.start + args.count)]
    out_path.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote {args.count} bins to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
