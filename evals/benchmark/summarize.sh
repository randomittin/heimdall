#!/usr/bin/env bash
# summarize.sh — compute median + range across 3 runs per arm x task cell.
#
# Reads results.jsonl (one JSON record per run.sh invocation).
# Writes summary.jsonl (one record per arm x task cell: median + min/max) and
# prints a human-readable table to stdout.
#
# This script reads existing data and does NOT invoke any model.
# No spend-gate flag required.
#
# Usage:
#   summarize.sh [--jsonl <path>] [--out <summary-jsonl-path>]
set -euo pipefail

SELF="$0"
if command -v readlink &>/dev/null; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
BENCH_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RESULTS_JSONL="${1:-$BENCH_DIR/results.jsonl}"
SUMMARY_JSONL="$BENCH_DIR/summary.jsonl"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

[ -f "$RESULTS_JSONL" ] || { echo "error: results.jsonl not found: $RESULTS_JSONL" >&2; exit 1; }

# For each arm x task cell, compute median and min/max of:
#   tokens.total, wall_seconds, cost_usd, bloat_lines.
# tests.passed/total: median passed / constant total per task.
# Median of 3 runs: sort 3 values, take middle (index 1).

> "$SUMMARY_JSONL"

jq -r '[.task, .arm] | @tsv' "$RESULTS_JSONL" | sort -u | while IFS=$'\t' read -r task arm; do
  jq -c \
    --arg task "$task" \
    --arg arm "$arm" \
    '
    [ .[] | select(.task == $task and .arm == $arm) ] as $runs |
    if ($runs | length) == 0 then empty else
      def med(f): (map(f) | sort) as $s | $s[($s|length / 2 | floor)];
      def minf(f): map(f) | min;
      def maxf(f): map(f) | max;
      {
        task: $task,
        arm: $arm,
        n_runs: ($runs | length),
        models: ($runs | map(.model) | unique),
        tokens_total: {
          median: ($runs | med(.tokens.total)),
          min: ($runs | minf(.tokens.total)),
          max: ($runs | maxf(.tokens.total))
        },
        tokens_input:  {
          median: ($runs | med(.tokens.input)),
          min: ($runs | minf(.tokens.input)),
          max: ($runs | maxf(.tokens.input))
        },
        tokens_output: {
          median: ($runs | med(.tokens.output)),
          min: ($runs | minf(.tokens.output)),
          max: ($runs | maxf(.tokens.output))
        },
        wall_seconds: {
          median: ($runs | med(.wall_seconds)),
          min: ($runs | minf(.wall_seconds)),
          max: ($runs | maxf(.wall_seconds))
        },
        cost_usd: {
          median: ($runs | med(.cost_usd)),
          min: ($runs | minf(.cost_usd)),
          max: ($runs | maxf(.cost_usd))
        },
        tests_passed_median: ($runs | med(.tests.passed)),
        tests_total: ($runs[0].tests.total),
        human_interventions_median: ($runs | med(.human_interventions)),
        bloat_lines: {
          median: ($runs | med(.bloat_lines)),
          min: ($runs | minf(.bloat_lines)),
          max: ($runs | maxf(.bloat_lines))
        }
      }
    end
    ' <(jq -s '.' "$RESULTS_JSONL") >> "$SUMMARY_JSONL"
done

CELLS=$(wc -l < "$SUMMARY_JSONL" | tr -d ' ')
echo "summary: $CELLS cells written to $SUMMARY_JSONL"

echo ""
printf "%-28s  %-10s  %8s  %8s  %7s  %7s  %8s\n" \
  "TASK" "ARM" "TOK(med)" "WALL(med)" "TESTS" "BLOAT" "COST(med)"
printf "%-28s  %-10s  %8s  %8s  %7s  %7s  %8s\n" \
  "----------------------------" "----------" "--------" "---------" \
  "-------" "-------" "--------"

jq -r '. | "\(.task)\t\(.arm)\t\(.tokens_total.median)\t[\(.tokens_total.min)-\(.tokens_total.max)]\t\(.wall_seconds.median)\t[\(.wall_seconds.min)-\(.wall_seconds.max)]\t\(.tests_passed_median)/\(.tests_total)\t\(.bloat_lines.median)\t\(.cost_usd.median)"' \
  "$SUMMARY_JSONL" | sort | \
while IFS=$'\t' read -r task arm tok_med tok_range wall_med wall_range tests bloat cost; do
  printf "%-28s  %-10s  %8s  %8s  %7s  %7s  %8s\n" \
    "$task" "$arm" "$tok_med" "$wall_med" "$tests" "$bloat" "$cost"
  printf "%-28s  %-10s  %8s  %8s\n" "" "" "$tok_range" "$wall_range"
done
