#!/usr/bin/env bash
# reproduce.sh: re-run the false-green suite's local study (Study B, judge calibration) from scratch
# and regenerate the summary from the raw rows. Preregistration: evals/benchmark/false-green/PREREG.md.
#
#   evals/benchmark/reproduce.sh [--dry-run] [--write] [--out DIR] [--jobs N]
#
#   (no flags)  re-run into a scratch directory, regenerate the summary there and compare it with the
#               committed results.json. Exit 0 when identical, 1 when not (the engine or an instrument
#               changed since the committed run: the diff is printed). Nothing committed is touched.
#   --dry-run   print the plan (task count, candidate count, judges, cost) and exit 0; executes nothing.
#   --write     write the raw rows, ENV.json and results.json into the committed locations: this is how
#               the committed data was produced.
#   --out DIR   keep the regenerated rows and summary in DIR instead of a scratch directory.
#   --jobs N    judge N candidates in parallel (default 4).
#
# Study B needs bash, node, python3, jq and perl, uses no network and costs $0.00. Study A (real agents)
# is paid and is never run from here: `bin/benchmark run --suite false-green --agent NAME --dry` prints
# its plan and cost bound; committed Study A rows, if any, are re-summarized with the fresh Study B rows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BENCH="$ROOT/bin/benchmark"
SUITE="$ROOT/evals/benchmark/false-green"
MODE=compare; OUT=""; JOBS=4

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry; shift ;;
    --write)   MODE=write; shift ;;
    --out)     OUT="${2:?--out needs a directory}"; shift 2 ;;
    --jobs)    JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "reproduce.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*) echo "reproduce.sh: --jobs needs a positive number" >&2; exit 2 ;; esac

if [ "$MODE" = dry ]; then
  bash "$BENCH" run --dry --suite false-green --out "${OUT:-$SUITE/results}"
  echo "  study A:     not part of reproduce.sh (paid): bin/benchmark run --suite false-green --agent NAME --dry"
  exit 0
fi

bash "$BENCH" validate --suite false-green

if [ "$MODE" = write ]; then
  bash "$BENCH" run --suite false-green --out "$SUITE/results" --jobs "$JOBS"
  bash "$BENCH" summarize --json --suite false-green --in "$SUITE/results" --out "$SUITE/results.json" >/dev/null
  echo "reproduce.sh: wrote $SUITE/results/*.jsonl, ENV.json and results.json"
  exit 0
fi

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/fg-reproduce.XXXXXX")"
  trap 'rm -rf "$OUT"' EXIT
fi
mkdir -p "$OUT"
bash "$BENCH" run --suite false-green --out "$OUT/results" --jobs "$JOBS"
for arm in alone runhmd; do
  if [ -f "$SUITE/results/$arm.jsonl" ]; then cp "$SUITE/results/$arm.jsonl" "$OUT/results/$arm.jsonl"; fi
done
bash "$BENCH" summarize --json --suite false-green --in "$OUT/results" --out "$OUT/results.json" >/dev/null

if [ ! -f "$SUITE/results.json" ]; then
  echo "reproduce.sh: no committed results.json to compare with; regenerated summary: $OUT/results.json"
  exit 0
fi
if cmp -s "$OUT/results.json" "$SUITE/results.json"; then
  echo "reproduce.sh: MATCH: the regenerated summary is byte-identical to the committed results.json"
  exit 0
fi
echo "reproduce.sh: MISMATCH: the regenerated summary differs from the committed results.json:" >&2
diff "$SUITE/results.json" "$OUT/results.json" | head -40 >&2 || true
exit 1
