#!/usr/bin/env python3
"""
Generic template entrypoint for SWIF resource rebalancing.

This template intentionally reuses the current generic helper from
`farm_env/rebalance_swif.py`. If you later want a fully detached copy for
another repo, copy that helper body into this file and customize the
resource-detection logic there.
"""

from farm_env.rebalance_swif import main


if __name__ == "__main__":
    raise SystemExit(main())
