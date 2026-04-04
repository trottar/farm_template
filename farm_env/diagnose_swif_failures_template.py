#!/usr/bin/env python3
"""
Generic template entrypoint for SWIF failure diagnosis.

This template intentionally reuses the current generic helper from
`farm_env/diagnose_swif_failures.py`. If you later want a fully detached copy
for another repo, copy that helper body into this file and customize the
regexes/cache-path mapping there.
"""

from farm_env.diagnose_swif_failures import main


if __name__ == "__main__":
    raise SystemExit(main())
