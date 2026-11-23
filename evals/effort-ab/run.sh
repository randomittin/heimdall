#!/usr/bin/env bash
# Entry point of the effort A/B (high vs medium). Flags and design: see run.py and
# docs/analysis/2026-11-23-effort-ab.md. `--dry-run` prints the schedule and command, no API calls.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run.py" "$@"
