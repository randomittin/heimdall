#!/usr/bin/env bash
# run.sh — team-checkpoint differential oracle, STRUCTURED CONTRACT entry point
# (REPORT-CONTRACT.md spec 2A). bin/falsify + the orchestrator consume the TYPED report.json
# this writes — they NEVER parse this script's stdout.
#
# Grade ONE fixture through the single source of diff-truth (differential.py):
#   kind "differential" (golden): fold the SAME stream through the impl (checkpoint_share) AND
#     the INDEPENDENT reference (reference.py), normalize to served/excluded_security, diff.
#     status=pass iff they agree.
#   kind "mutant": recompute the CORRECT partition from the fixture stream via the INDEPENDENT
#     reference, diff it against the fixture's `corrupted` partition. A genuine defect diverges
#     -> status=fail -> KILLED.
#
# Report schema (spec H-1 — 8 fields): gate_id, status, first_divergence{file,step,expected,
# actual}|null, metrics, fix_hint, haid, wave, ts.
#
# Usage: run.sh [--input <fixture>] [--truth <ignored>] [--report <out>]
# Exit: 0 pass, 1 fail, 2 usage/IO error.
set -euo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
ORACLE_DIR="$(cd "$(dirname "$SELF")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "error: python3 is required" >&2; exit 2; }

GATE_ID="team-checkpoint"
DIFF="$ORACLE_DIR/differential.py"
DEFAULT_INPUT="$ORACLE_DIR/fixtures/golden/differential.json"
DEFAULT_REPORT="$ORACLE_DIR/report.json"

usage() { sed -n '2,26p' "$SELF"; }

INPUT=""; REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input)  INPUT="${2:?--input needs a fixture path}"; shift 2 ;;
    --report) REPORT="${2:?--report needs an output path}"; shift 2 ;;
    --truth)  shift 2 ;;   # accepted for contract symmetry; this gate derives truth from the
                           # fixture stream via the reference (never an X-vs-X diff).
    -h|--help) usage; exit 0 ;;
    --*) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)   echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

INPUT="${INPUT:-$DEFAULT_INPUT}"
REPORT="${REPORT:-$DEFAULT_REPORT}"
[ -f "$DIFF" ]  || { echo "error: differential engine missing: $DIFF" >&2; exit 2; }
[ -f "$INPUT" ] || { echo "error: input not found: $INPUT" >&2; exit 2; }
mkdir -p "$(dirname "$REPORT")"

GRADE="$("$PY" "$DIFF" grade --input "$INPUT" 2>/dev/null)" || true
if [ -z "$GRADE" ] || ! jq -e . >/dev/null 2>&1 <<<"$GRADE"; then
  echo "error: differential engine produced no gradable result for $INPUT" >&2
  exit 2
fi

STATUS="$(jq -r '.status // empty' <<<"$GRADE")"
METRICS="$(jq -c '.metrics // {}' <<<"$GRADE")"
HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
TS="$(date -u +%FT%TZ)"

write_pass() {
  jq -n --arg gate_id "$GATE_ID" --argjson metrics "$METRICS" \
        --arg fix_hint "$1" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:"pass", first_divergence:null, metrics:$metrics,
      fix_hint:$fix_hint, haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}' \
    >"$REPORT"
}
write_fail() {
  local step="$1" exp="$2" act="$3" hint="$4"
  jq -n --arg gate_id "$GATE_ID" --arg file "$GATE_ID" --arg step "$step" \
        --arg expected "$exp" --arg actual "$act" --argjson metrics "$METRICS" \
        --arg fix_hint "$hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:"fail",
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:$metrics, fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$REPORT"
}

case "$STATUS" in
  pass)
    write_pass "Impl roster fold equals the independent reference on the served/excluded_security partition — INV-A..INV-G hold."
    echo "report: $REPORT (status=pass)"
    exit 0 ;;
  fail)
    STEP="$(jq -r '.first_divergence.step // "partition"' <<<"$GRADE")"
    EXP="$(jq -r '.first_divergence.expected // ""' <<<"$GRADE")"
    ACT="$(jq -r '.first_divergence.actual // ""' <<<"$GRADE")"
    write_fail "$STEP" "$EXP" "$ACT" \
      "Roster fold diverges from the independent reference. Re-derive from INVARIANTS.md: consent-off records SKIPPED (INV-D); security-sensitive records EXCLUDED + counted at any k (INV-C); a secret/abs-path/body record DROPPED (INV-A/INV-B); the served set keyed by HAID must match row-for-row (INV-G)."
    echo "report: $REPORT (status=fail)"
    exit 1 ;;
  *)
    STEP="$(jq -r '.first_divergence.step // "ungradable input"' <<<"$GRADE")"
    echo "error: fixture is ungradable ($STEP)" >&2
    exit 2 ;;
esac
