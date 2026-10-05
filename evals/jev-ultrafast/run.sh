#!/usr/bin/env bash
# evals/jev-ultrafast/run.sh -- hmd web vs browser-use/jev-ultrafast benchmark.
# usage: bash evals/jev-ultrafast/run.sh            (hmd arm; jev arm BLOCKED unless preconditions met)
#        REPS=1 bash evals/jev-ultrafast/run.sh      (quick)
#        JEV_DIR=/path/to/clone TYPESAFE_API_KEY=... TEXT_MODEL_API_KEY=... bash evals/jev-ultrafast/run.sh
# Needs network for the live rows; fixture rows are local. Writes results.json next to this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 required" >&2; exit 2; }
exec python3 "$HERE/bench.py"
