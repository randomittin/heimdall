#!/usr/bin/env bash
# bloat.sh — BLOAT sentinel (spec H-3 harness, drives the H-2 Bloat Gate).
#
# Job: the post-wave bloat check. Two layers, in order:
#
#   1. DETERMINISTIC engine (bin/bloat-gate) — the real numbers (spec H-2): dead
#      code, duplication %, complexity, dependency creep, LOC budget, measured on
#      NEW code in the wave's diff range. NO LLM in these numbers. Each axis
#      degrades gracefully (status:skipped, tool named) if its tool is absent —
#      never faked. This produces the authoritative report.json.
#
#   2. LLM simplification layer (soft gate) — a fresh-context background instance
#      gets ONLY the diff + acceptance criteria and returns the JSON contract
#      {simplifiable:bool, top_2_suggestions:[...]}. If simplifiable, the wave
#      gets ONE mandatory simplification pass (no infinite golf loop), then we
#      proceed. The scorer is wired via env HEIMDALL_BLOAT_SCORER (a command that
#      takes --diff/--criteria and prints the JSON contract). Absent => the soft
#      layer is honestly skipped; the deterministic verdict still stands.
#
# This sentinel's report.json is the H-2 gate report (gate_id "bloat") produced
# by bin/bloat-gate, with the LLM layer's verdict folded into metrics.llm and the
# simplification delta recorded for the scorecard.
#
# Inputs:
#   --repo     repo root to analyze (required).
#   --diff     git range for the wave's new code (e.g. "HEAD~1..HEAD").
#   --base/--head  alternative to --diff (defaults base=HEAD~1, head=HEAD).
#   --criteria acceptance-criteria ids (comma-separated) passed to the LLM scorer.
#   --estimate plan LOC estimate (forwarded to the LOC-budget axis).
#   --mode     strict|standard|off (forwarded; else config/.planning/bloat.json).
#   --report   where to write report.json.
#
# Usage:
#   bloat.sh --repo <root> [--diff <range>] [--criteria <ids>] [--estimate <n>] \
#            [--mode <m>] [--report <out>]
#
# Exit codes: 0 = pass/skipped; 1 = fail; 2 = usage/IO error.
set -euo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
SENT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=lib/report.sh
. "$SENT_DIR/lib/report.sh"

# Locate bin/bloat-gate: sibling bin/ of the sentinels dir (repo layout), else PATH.
REPO_ROOT_GUESS="$(cd "$SENT_DIR/.." && pwd)"
BLOAT_GATE="$REPO_ROOT_GUESS/bin/bloat-gate"
[ -x "$BLOAT_GATE" ] || BLOAT_GATE="$(command -v bloat-gate 2>/dev/null || true)"

GATE_ID="bloat"

REPO=""
DIFF=""
BASE=""
HEAD_REF=""
CRITERIA=""
ESTIMATE="${HEIMDALL_LOC_EST:-}"
MODE=""
REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?--repo needs a path}"; shift 2 ;;
    --diff)     DIFF="${2:?--diff needs a value}"; shift 2 ;;
    --base)     BASE="${2:?--base needs a ref}"; shift 2 ;;
    --head)     HEAD_REF="${2:?--head needs a ref}"; shift 2 ;;
    --criteria) CRITERIA="${2:?--criteria needs a value}"; shift 2 ;;
    --estimate) ESTIMATE="${2:?--estimate needs a number}"; shift 2 ;;
    --mode)     MODE="${2:?--mode needs a value}"; shift 2 ;;
    --report)   REPORT="${2:?--report needs a path}"; shift 2 ;;
    -h|--help)  sed -n '2,46p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] || { echo "error: --repo is required" >&2; exit 2; }
[ -d "$REPO" ] || { echo "error: --repo not a dir: $REPO" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }
: "${REPORT:=$REPO/.planning/spawns/reports/bloat.report.json}"

# Resolve the range for the LLM scorer + diff capture.
if [ -n "$DIFF" ]; then
  RANGE="$DIFF"
else
  RANGE="${BASE:-HEAD~1}..${HEAD_REF:-HEAD}"
fi

# ── Layer 1: deterministic engine (authoritative numbers) ─────────────
if [ -z "$BLOAT_GATE" ]; then
  metrics="$(jq -nc '{layer:"none",reason:"bin/bloat-gate not found next to sentinels/ nor on PATH"}')"
  sentinel_report "$REPORT" "$GATE_ID" "skipped" "$metrics" \
    "Bloat engine bin/bloat-gate is not installed. Honest skip — NOT a pass. Restore bin/bloat-gate."
  exit 0
fi

DET_ARGS=(--repo "$REPO" --report "$REPORT")
[ -n "$DIFF" ]     && DET_ARGS+=(--diff "$DIFF")
[ -z "$DIFF" ] && [ -n "$BASE" ]     && DET_ARGS+=(--base "$BASE")
[ -z "$DIFF" ] && [ -n "$HEAD_REF" ] && DET_ARGS+=(--head "$HEAD_REF")
[ -n "$ESTIMATE" ] && DET_ARGS+=(--estimate "$ESTIMATE")
[ -n "$MODE" ]     && DET_ARGS+=(--mode "$MODE")

set +e
"$BLOAT_GATE" "${DET_ARGS[@]}" >/dev/null 2>&1
DET_EXIT=$?
set -e
# 0=pass 1=fail; 2 means the engine could not produce a report — surface honestly.
if [ "$DET_EXIT" -eq 2 ] || [ ! -f "$REPORT" ]; then
  metrics="$(jq -nc --arg r "$RANGE" '{layer:"deterministic",reason:"bloat-gate could not produce a report (bad range / IO)",range:$r}')"
  sentinel_report "$REPORT" "$GATE_ID" "skipped" "$metrics" \
    "Bloat engine could not evaluate range ${RANGE} (usage/IO). Check the diff range. Honest skip — NOT a pass."
  exit 0
fi

DET_STATUS="$(jq -r '.status' "$REPORT" 2>/dev/null || echo unknown)"

# ── Layer 2: LLM simplification scorer (soft gate, ONE mandatory pass) ─
# The scorer is a fresh-context instance that sees ONLY the diff + criteria and
# returns {simplifiable:bool, top_2_suggestions:[...]}. Wired via env
# HEIMDALL_BLOAT_SCORER. Absent => honestly skipped (deterministic verdict holds).
#
# Reference wiring (documented invocation point — the real model call is the
# orchestrator's responsibility, this is the contract it must satisfy):
#   HEIMDALL_BLOAT_SCORER='<command>'   (heimdall-spawn, which this used to name, is retired)
# where <command> accepts:  <scorer> --diff <range> --criteria <ids>
# and printing a single JSON object {simplifiable:bool, top_2_suggestions:[...]}.
LLM_JSON='{"status":"skipped","reason":"no LLM scorer wired (set HEIMDALL_BLOAT_SCORER); soft simplification layer not run"}'
SIMPLIFY_DELTA=0
if [ -n "${HEIMDALL_BLOAT_SCORER:-}" ] && command -v "${HEIMDALL_BLOAT_SCORER%% *}" >/dev/null 2>&1; then
  scorer_out="$( cd "$REPO" && eval "$HEIMDALL_BLOAT_SCORER" --diff "$RANGE" --criteria "${CRITERIA:-}" 2>/dev/null )" || true
  if printf '%s' "$scorer_out" | jq -e 'has("simplifiable")' >/dev/null 2>&1; then
    simplifiable="$(printf '%s' "$scorer_out" | jq -r '.simplifiable')"
    sugg="$(printf '%s' "$scorer_out" | jq -c '.top_2_suggestions // []')"
    if [ "$simplifiable" = "true" ]; then
      # ONE mandatory simplification pass, then proceed (no infinite golf loop).
      # The pass is the orchestrator's simplifier, wired via HEIMDALL_BLOAT_SIMPLIFIER
      # (a command taking --diff/--suggestions and editing the tree in place,
      # printing the count of lines removed). Absent => the wave is FLAGGED for a
      # human/agent simplification pass (soft gate: reported, not a hard block).
      LINES_BEFORE="$(git -C "$REPO" diff --numstat "$RANGE" 2>/dev/null | awk 'NF>=2 && $1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')"
      if [ -n "${HEIMDALL_BLOAT_SIMPLIFIER:-}" ] && command -v "${HEIMDALL_BLOAT_SIMPLIFIER%% *}" >/dev/null 2>&1; then
        ( cd "$REPO" && eval "$HEIMDALL_BLOAT_SIMPLIFIER" --diff "$RANGE" --suggestions "$sugg" ) >/dev/null 2>&1 || true
        LINES_AFTER="$(git -C "$REPO" diff --numstat "$RANGE" 2>/dev/null | awk 'NF>=2 && $1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')"
        SIMPLIFY_DELTA=$(( LINES_BEFORE - LINES_AFTER ))
        [ "$SIMPLIFY_DELTA" -lt 0 ] && SIMPLIFY_DELTA=0
        LLM_JSON="$(jq -nc --argjson s "$sugg" --argjson d "$SIMPLIFY_DELTA" \
          '{status:"ran", simplifiable:true, top_2_suggestions:$s, simplification_pass:"applied", lines_removed:$d}')"
      else
        LLM_JSON="$(jq -nc --argjson s "$sugg" \
          '{status:"ran", simplifiable:true, top_2_suggestions:$s, simplification_pass:"flagged (no HEIMDALL_BLOAT_SIMPLIFIER wired) — run one mandatory simplification pass"}')"
      fi
    else
      LLM_JSON="$(jq -nc --argjson s "$sugg" '{status:"ran", simplifiable:false, top_2_suggestions:$s}')"
    fi
  else
    LLM_JSON='{"status":"skipped","reason":"LLM scorer wired but produced no parseable {simplifiable,...} verdict"}'
  fi
fi

# ── Fold the LLM verdict + simplification delta into the report ───────
# The deterministic report.json is authoritative for status (the hard numbers).
# We merge metrics.llm and update simplification_delta_lines for the scorecard,
# without changing the deterministic pass/fail verdict (the LLM layer is SOFT).
tmp="$(mktemp)"
jq --argjson llm "$LLM_JSON" --argjson delta "$SIMPLIFY_DELTA" \
   '.metrics.llm = $llm
    | .metrics.simplification_delta_lines = (($delta) + (.metrics.simplification_delta_lines // 0))' \
   "$REPORT" > "$tmp" && mv "$tmp" "$REPORT"

echo "bloat sentinel: deterministic=$DET_STATUS  llm=$(printf '%s' "$LLM_JSON" | jq -r '.status')  simplify_delta=$SIMPLIFY_DELTA  report=$REPORT" >&2

# Exit mirrors the deterministic (authoritative) verdict.
[ "$DET_STATUS" = "fail" ] && exit 1
exit 0
