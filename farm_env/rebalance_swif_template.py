#!/usr/bin/env python3
"""Template entrypoint for SWIF rebalancing summary."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from rebalance_swif import main


if __name__ == "__main__":
    raise SystemExit(main())
