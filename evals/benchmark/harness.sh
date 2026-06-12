#!/usr/bin/env bash
# harness.sh — orchestrate 3-arm × 5-task × 3-run benchmark.
#
# SPEND GATE: without --confirm-spend this script prints the GATED message and
# exits 0. No models are invoked, no tokens are spent.
#
# The gate must be lifted manually by RJ after the stranger-test pass.
# Approved budget: ~600k tokens across the full 3×5×3=45-run matrix.
#
# Usage:
#   harness.sh [--arm raw|superx|heimdall|all] [--task <id>|all] \
#              [--runs 1|2|3] [--model-raw <id>] [--model-superx <id>] \
#              [--model-heimdall <id>] [--confirm-spend] [--dry]
#
# Flags:
#   --arm <arm|all>        which arm(s) (default: all → raw superx heimdall)
#   --task <id|all>        which task(s) (default: all 5)
#   --runs N               how many runs per arm × task (default: 3, max: 3)
#   --model-raw <id>       model id for the raw arm     (default: see model-pins.json)
#   --model-superx <id>    model id for the superx arm  (default: see model-pins.json)
#   --model-heimdall <id>  model id for the heimdall arm (default: see model-pins.json)
#   --confirm-spend        REQUIRED to actually invoke any model
#   --dry                  print execution plan, exit (no models, no spend)
#   -h|--help              show help
#
# After all runs complete, harness.sh calls summarize.sh to compute medians + ranges
# and write the final BENCHMARKS.template.md with real numbers.
set -euo pipefail

SELF="$0"
if command -v readlink &>/dev/null; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
BENCH_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RUN_SH="$BENCH_DIR/run.sh"
TASKS_DIR="$BENCH_DIR/tasks"
MODEL_PINS="$BENCH_DIR/model-pins.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -x "$RUN_SH" ] || { echo "error: run.sh not executable: $RUN_SH" >&2; exit 1; }

# ── defaults ──
ARMS="all"
ONLY_TASK="all"
NUM_RUNS=3
MODEL_RAW=""
MODEL_SUPERX=""
MODEL_HEIMDALL=""
CONFIRM_SPEND=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --arm)            ARMS="${2:?--arm needs raw|superx|heimdall|all}"; shift 2 ;;
    --task)           ONLY_TASK="${2:?--task needs a task id or all}"; shift 2 ;;
    --runs)           NUM_RUNS="${2:?--runs needs 1|2|3}"; shift 2 ;;
    --model-raw)      MODEL_RAW="${2:?--model-raw needs a model id}"; shift 2 ;;
    --model-superx)   MODEL_SUPERX="${2:?--model-superx needs a model id}"; shift 2 ;;
    --model-heimdall) MODEL_HEIMDALL="${2:?--model-heimdall needs a model id}"; shift 2 ;;
    --confirm-spend)  CONFIRM_SPEND=1; shift ;;
    --dry)            DRY=1; shift ;;
    -h|--help) grep '^# ' "$SELF" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$NUM_RUNS" in 1|2|3) ;; *) echo "error: --runs must be 1, 2, or 3" >&2; exit 2 ;; esac

# resolve arm list
resolve_arms() {
  case "$ARMS" in
    all)     echo "raw superx heimdall" ;;
    raw|superx|heimdall) echo "$ARMS" ;;
    *) echo "error: --arm must be raw|superx|heimdall|all" >&2; exit 2 ;;
  esac
}

# resolve task list
resolve_tasks() {
  if [ "$ONLY_TASK" = "all" ]; then
    find "$TASKS_DIR" -maxdepth 1 -name '*.json' | sort | xargs -I{} jq -r '.id' {}
  else
    echo "$ONLY_TASK"
  fi
}

# resolve model for arm (falls back to model-pins.json, then TODO-pin)
model_for_arm() {
  local arm="$1"
  case "$arm" in
    raw)      [ -n "$MODEL_RAW" ] && echo "$MODEL_RAW" && return ;;
    superx)   [ -n "$MODEL_SUPERX" ] && echo "$MODEL_SUPERX" && return ;;
    heimdall) [ -n "$MODEL_HEIMDALL" ] && echo "$MODEL_HEIMDALL" && return ;;
  esac
  if [ -f "$MODEL_PINS" ]; then
    jq -r --arg arm "$arm" '.[$arm].model_id // "TODO-pin"' "$MODEL_PINS"
  else
    echo "TODO-pin"
  fi
}

ARM_LIST="$(resolve_arms)"
TASK_LIST="$(resolve_tasks)"

# ── SPEND GATE (propagated to run.sh but also checked here for early exit) ──
if [ "$CONFIRM_SPEND" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  echo "GATED: awaiting RJ stranger-test pass — no token spend"
  echo ""
  echo "  This harness would run:"
  for arm in $ARM_LIST; do
    model="$(model_for_arm "$arm")"
    for task in $TASK_LIST; do
      echo "    arm=$arm  task=$task  runs=1..$NUM_RUNS  model=$model"
    done
  done
  echo ""
  echo "  Total invocations: $(echo "$ARM_LIST" | wc -w | tr -d ' ') arms × $(echo "$TASK_LIST" | wc -l | tr -d ' ') tasks × $NUM_RUNS runs"
  echo ""
  echo "  Re-run with --confirm-spend once the gate is lifted."
  exit 0
fi

# ── DRY: print plan and exit ──
if [ "$DRY" -eq 1 ]; then
  echo "harness.sh dry run — no models invoked"
  echo ""
  printf "%-3s  %-10s  %-28s  %-30s\n" "RUN" "ARM" "TASK" "MODEL"
  printf "%-3s  %-10s  %-28s  %-30s\n" "---" "----------" "----------------------------" "------------------------------"
  for arm in $ARM_LIST; do
    model="$(model_for_arm "$arm")"
    for task in $TASK_LIST; do
      for run in $(seq 1 "$NUM_RUNS"); do
        printf "%-3s  %-10s  %-28s  %-30s\n" "$run" "$arm" "$task" "$model"
      done
    done
  done
  echo ""
  total_runs=$(( $(echo "$ARM_LIST" | wc -w | tr -d ' ') * $(echo "$TASK_LIST" | wc -l | tr -d ' ') * NUM_RUNS ))
  echo "Total: $total_runs invocations"
  echo "Pass --confirm-spend (without --dry) to execute."
  exit 0
fi

# ── LIVE EXECUTION ──
echo "harness.sh: starting 3-arm benchmark (confirm-spend=YES)"
echo "  arms: $ARM_LIST"
echo "  tasks: $(echo "$TASK_LIST" | tr '\n' ' ')"
echo "  runs per cell: $NUM_RUNS"
echo ""

FAIL_COUNT=0

for arm in $ARM_LIST; do
  model="$(model_for_arm "$arm")"
  for task in $TASK_LIST; do
    for run in $(seq 1 "$NUM_RUNS"); do
      echo "→ arm=$arm  task=$task  run=$run  model=$model"
      model_flag=""
      [ "$model" != "TODO-pin" ] && model_flag="--model $model"
      # shellcheck disable=SC2086
      if ! "$RUN_SH" \
          --arm "$arm" \
          --task "$task" \
          --run "$run" \
          $model_flag \
          --confirm-spend; then
        echo "  FAILED: arm=$arm task=$task run=$run" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
      echo ""
    done
  done
done

echo ""
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "harness.sh: $FAIL_COUNT run(s) failed — check output above"
  exit 1
else
  echo "harness.sh: all runs complete"
fi

# ── summarize medians + ranges ──
SUMMARIZE="$BENCH_DIR/summarize.sh"
if [ -x "$SUMMARIZE" ]; then
  echo "running summarize.sh ..."
  "$SUMMARIZE"
else
  echo "note: summarize.sh not found or not executable — run it manually to compute medians/ranges"
fi
