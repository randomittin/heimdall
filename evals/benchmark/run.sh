#!/usr/bin/env bash
# run.sh — 3-arm benchmark runner for one arm × one task × one run-index.
#
# SPEND GATE: execution is blocked until RJ's stranger-test pass is confirmed.
# Pass --confirm-spend to actually invoke a model arm. Without it, this script
# prints the GATED message and exits 0 (safe for CI pre-check).
#
# Usage:
#   run.sh --arm <raw|superx|heimdall> --task <task-id> --run <1|2|3> \
#          [--model <model-id>] [--interventions N] [--confirm-spend]
#
# Outputs (appended):
#   results.jsonl   — one JSON record per invocation
#   results.md      — markdown table row appended
#
# See harness.sh for the orchestrator that loops all arms × tasks × runs.
# See BENCHMARKS.template.md for the full results table structure.
#
# HONESTY PRINCIPLE: publish every measured cell, including ones where a
# given arm loses. See evals/benchmark/README.p3.md for context.
set -euo pipefail

# ── resolve repo root ──
SELF="$0"
if command -v readlink &>/dev/null; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
BENCH_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_DIR="$(cd "$BENCH_DIR/../.." && pwd)"
TASKS_DIR="$BENCH_DIR/tasks"
RESULTS_JSONL="$BENCH_DIR/results.jsonl"
RESULTS_MD="$BENCH_DIR/results.md"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# ── args ──
ARM=""
TASK_ID=""
RUN_INDEX=""
MODEL=""
INTERVENTIONS=0
CONFIRM_SPEND=0

usage() {
  grep '^# ' "$SELF" | sed 's/^# //'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arm)            ARM="${2:?--arm needs raw|superx|heimdall}"; shift 2 ;;
    --task)           TASK_ID="${2:?--task needs a task id}"; shift 2 ;;
    --run)            RUN_INDEX="${2:?--run needs 1|2|3}"; shift 2 ;;
    --model)          MODEL="${2:?--model needs a model id}"; shift 2 ;;
    --interventions)  INTERVENTIONS="${2:?--interventions needs N}"; shift 2 ;;
    --confirm-spend)  CONFIRM_SPEND=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$ARM" ]        || { echo "error: --arm required" >&2; exit 2; }
[ -n "$TASK_ID" ]    || { echo "error: --task required" >&2; exit 2; }
[ -n "$RUN_INDEX" ]  || { echo "error: --run required" >&2; exit 2; }

case "$ARM" in raw|superx|heimdall) ;; *) echo "error: --arm must be raw|superx|heimdall" >&2; exit 2 ;; esac
case "$RUN_INDEX" in 1|2|3) ;; *) echo "error: --run must be 1, 2, or 3" >&2; exit 2 ;; esac
case "$INTERVENTIONS" in (*[!0-9]*|"") echo "error: --interventions must be a non-negative integer" >&2; exit 2 ;; esac

# ── SPEND GATE ──
if [ "$CONFIRM_SPEND" -eq 0 ]; then
  echo "GATED: awaiting RJ stranger-test pass — no token spend"
  echo "  arm=$ARM  task=$TASK_ID  run=$RUN_INDEX"
  echo "  Re-run with --confirm-spend once the gate is lifted."
  exit 0
fi

# ── locate task file ──
TASK_FILE="$TASKS_DIR/${TASK_ID}.json"
[ -f "$TASK_FILE" ] || {
  echo "error: task file not found: $TASK_FILE" >&2
  echo "Available tasks:" >&2
  ls "$TASKS_DIR"/*.json 2>/dev/null | xargs -I{} jq -r '.id' {} | sed 's/^/  /' >&2
  exit 1
}

# validate task
jq -e '.id and .title and .category and .prompt and (.verify|type=="array")' "$TASK_FILE" >/dev/null 2>&1 \
  || { echo "error: task $TASK_FILE missing required fields" >&2; exit 1; }

PROMPT="$(jq -r '.prompt' "$TASK_FILE")"

# ── portable realpath ──
canonical_dir() {
  local d="$1"
  ( cd "$d" 2>/dev/null && pwd -P ) 2>/dev/null || \
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$d" 2>/dev/null
}

# ── materialize workspace ──
materialize_workspace() {
  local f="$1" ws xrun tmpl
  xrun="$(printf 'X%.0s' 1 2 3 4 5 6)"
  tmpl="${TMPDIR:-/tmp}/hmd-bench3.${xrun}"
  ws="$(mktemp -d "$tmpl")"

  if jq -e '.seed_files' "$f" >/dev/null 2>&1; then
    local ws_real
    ws_real="$(canonical_dir "$ws")" || { echo "error: cannot resolve workspace" >&2; rm -rf "$ws"; return 1; }
    while IFS= read -r relpath; do
      case "$relpath" in
        /*|*..*|*$'\n'*|"") echo "error: unsafe seed key: $relpath" >&2; rm -rf "$ws"; return 1 ;;
      esac
      local dest="$ws/$relpath" probe parent parent_real
      parent="$(dirname "$dest")"
      probe="$parent"
      while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
      parent_real="$(canonical_dir "$probe")" || { rm -rf "$ws"; return 1; }
      case "$parent_real/" in
        "$ws_real/"*) ;;
        *) echo "error: seed key escapes workspace: $relpath" >&2; rm -rf "$ws"; return 1 ;;
      esac
      mkdir -p "$parent"
      parent_real="$(canonical_dir "$parent")" || { rm -rf "$ws"; return 1; }
      case "$parent_real/" in
        "$ws_real/"*) ;;
        *) echo "error: seed key escapes workspace: $relpath" >&2; rm -rf "$ws"; return 1 ;;
      esac
      jq -r --arg k "$relpath" '.seed_files[$k]' "$f" > "$dest"
    done < <(jq -r '.seed_files | keys[]' "$f")
  fi

  (
    cd "$ws"
    git init -q
    git config user.email bench@heimdall.local
    git config user.name heimdall-bench
    if jq -e '.setup' "$f" >/dev/null 2>&1; then
      while IFS= read -r step; do
        [ "$step" = "__SEED__" ] && continue
        bash -c "$step" || { echo "setup step failed: $step" >&2; exit 1; }
      done < <(jq -r '.setup[]' "$f")
    fi
    git add -A >/dev/null 2>&1 || true
    git commit -q -m "bench baseline" >/dev/null 2>&1 || true
  ) >&2 || { rm -rf "$ws"; return 1; }

  echo "$ws"
}

# ── build arm command ──
# Sets ARM_CMD array. Each arm invokes claude differently.
# raw     : claude -p <prompt> --output-format json
# superx  : claude -p <prompt> --output-format json  (via superx wrapper — TODO: resolve binary)
# heimdall: claude --agent heimdall --plugin-dir <repo> -p /goal <prompt>
build_arm_cmd() {
  local arm="$1" prompt="$2"
  ARM_CMD=(claude --output-format json --permission-mode acceptEdits)
  [ -n "$MODEL" ] && ARM_CMD+=(--model "$MODEL")
  case "$arm" in
    raw)
      ARM_CMD+=(-p "$prompt")
      ;;
    superx)
      # superx last-tag binary. Resolved at run time via PATH or SUPERX_BIN env var.
      # If not found, error with instructions.
      local sx_bin="${SUPERX_BIN:-superx}"
      if ! command -v "$sx_bin" &>/dev/null; then
        echo "error: superx binary not found. Set SUPERX_BIN=/path/to/superx or add to PATH." >&2
        exit 1
      fi
      # superx wraps claude; pass the prompt and output-format through.
      # Exact flag interface: TODO-pin — verify against superx last-tag before running.
      ARM_CMD=("$sx_bin" --output-format json --permission-mode acceptEdits)
      [ -n "$MODEL" ] && ARM_CMD+=(--model "$MODEL")
      ARM_CMD+=(-p "$prompt")
      ;;
    heimdall)
      local goal_prompt="/goal ${prompt} — fully implemented, all tests pass, lint clean, every line real and working

${prompt}"
      ARM_CMD+=(--agent heimdall --plugin-dir "$REPO_DIR" -p "$goal_prompt")
      ;;
  esac
}

# ── run verify oracle ──
run_verify() {
  local f="$1" ws="$2"
  local pass=0 total=0 cmd
  while IFS= read -r cmd; do
    total=$((total + 1))
    if ( cd "$ws" && bash -c "$cmd" >/dev/null 2>&1 ); then
      pass=$((pass + 1))
    fi
  done < <(jq -r '.verify[]' "$f")
  VERIFY_PASS="$pass"
  VERIFY_TOTAL="$total"
}

# ── measure bloat: non-blank, non-comment lines in generated source files ──
# Reports total source lines in src/ and related dirs (excluding node_modules).
# "Bloat line" = lines written that weren't in the baseline commit.
measure_bloat() {
  local ws="$1"
  BLOAT_LINES=0
  if command -v git &>/dev/null; then
    BLOAT_LINES=$(
      cd "$ws" && \
      git diff HEAD --stat 2>/dev/null | \
      grep -E '^\s+[0-9]+ insertion' | \
      awk '{sum+=$1} END{print sum+0}'
    ) || BLOAT_LINES=0
  fi
}

# ── main execution ──
echo "benchmark run.sh: arm=$ARM task=$TASK_ID run=$RUN_INDEX confirm-spend=YES"
[ -n "$MODEL" ] && echo "  model: $MODEL"

WS="$(materialize_workspace "$TASK_FILE")"
trap 'rm -rf "$WS"' EXIT

build_arm_cmd "$ARM" "$PROMPT"

# capture wall time + invoke arm
start_ns=$(date +%s%N)
RAW_OUT=$( cd "$WS" && "${ARM_CMD[@]}" 2>/dev/null ) || true
end_ns=$(date +%s%N)

WALL_SECS=$(awk "BEGIN{printf \"%.2f\", ($end_ns - $start_ns)/1000000000}")

# parse token ledger from claude JSON output
if echo "$RAW_OUT" | jq -e '.usage' >/dev/null 2>&1; then
  TOK_IN=$(echo "$RAW_OUT"    | jq -r '(.usage.input_tokens//0)+(.usage.cache_read_input_tokens//0)+(.usage.cache_creation_input_tokens//0)')
  TOK_OUT=$(echo "$RAW_OUT"   | jq -r '.usage.output_tokens//0')
  TOK_CACHE_R=$(echo "$RAW_OUT" | jq -r '.usage.cache_read_input_tokens//0')
  TOK_CACHE_W=$(echo "$RAW_OUT" | jq -r '.usage.cache_creation_input_tokens//0')
  COST_USD=$(echo "$RAW_OUT"  | jq -r '.total_cost_usd//0')
  NUM_TURNS=$(echo "$RAW_OUT" | jq -r '.num_turns//0')
  IS_ERROR=$(echo "$RAW_OUT"  | jq -r '.is_error//false')
else
  TOK_IN=0; TOK_OUT=0; TOK_CACHE_R=0; TOK_CACHE_W=0
  COST_USD=0; NUM_TURNS=0; IS_ERROR=true
fi
TOK_TOTAL=$((TOK_IN + TOK_OUT))

run_verify "$TASK_FILE" "$WS"
measure_bloat "$WS"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── append JSONL record ──
jq -c -n \
  --arg ts "$TS" \
  --arg task "$TASK_ID" \
  --arg arm "$ARM" \
  --argjson run "$RUN_INDEX" \
  --arg model "${MODEL:-TODO-pin}" \
  --argjson tok_in "$TOK_IN" \
  --argjson tok_out "$TOK_OUT" \
  --argjson tok_cache_r "$TOK_CACHE_R" \
  --argjson tok_cache_w "$TOK_CACHE_W" \
  --argjson tok_total "$TOK_TOTAL" \
  --arg wall "$WALL_SECS" \
  --arg cost "$COST_USD" \
  --argjson turns "$NUM_TURNS" \
  --argjson vpass "$VERIFY_PASS" \
  --argjson vtotal "$VERIFY_TOTAL" \
  --argjson interventions "$INTERVENTIONS" \
  --argjson bloat "$BLOAT_LINES" \
  --argjson is_error "$IS_ERROR" \
  '{
    ts: $ts,
    task: $task,
    arm: $arm,
    run: $run,
    model: $model,
    tokens: {
      input: $tok_in,
      output: $tok_out,
      cache_read: $tok_cache_r,
      cache_write: $tok_cache_w,
      total: $tok_total
    },
    wall_seconds: ($wall|tonumber),
    cost_usd: ($cost|tonumber),
    turns: $turns,
    tests: { passed: $vpass, total: $vtotal },
    human_interventions: $interventions,
    bloat_lines: $bloat,
    claude_error: $is_error
  }' >> "$RESULTS_JSONL"

# ── append markdown row ──
echo "| $TASK_ID | $ARM | $RUN_INDEX | ${MODEL:-TODO-pin} | $TOK_TOTAL | in:$TOK_IN out:$TOK_OUT cr:$TOK_CACHE_R cw:$TOK_CACHE_W | $WALL_SECS | ${VERIFY_PASS}/${VERIFY_TOTAL} | $INTERVENTIONS | $BLOAT_LINES | |" \
  >> "$RESULTS_MD"

echo "done: $TASK_ID/$ARM/run$RUN_INDEX  tokens=$TOK_TOTAL  wall=${WALL_SECS}s  tests=${VERIFY_PASS}/${VERIFY_TOTAL}  bloat=${BLOAT_LINES}  cost=\$$COST_USD"
