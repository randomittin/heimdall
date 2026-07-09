#!/usr/bin/env bash
# run.sh — issue-collection differential oracle, STRUCTURED CONTRACT entry point
# (REPORT-CONTRACT.md spec 2A). The orchestrator / protocol / ledger / bin/falsify
# consume the TYPED report.json this writes — they NEVER parse this script's stdout.
#
# WHAT IT DOES. Grade ONE fixture through the domain's single source of diff-truth
# (differential.py). A fixture is either:
#   • kind "differential" (the golden): feed the SAME issue_v1 stream to BOTH the impl
#     (bin/lib/cp_issue_aggregate) and the INDEPENDENT reference
#     (reference/aggregate_ref.py), normalize each to the served/suppressed/
#     excluded_security partition, and diff. status=pass iff they agree.
#   • kind "mutant": recompute the CORRECT partition from the fixture's stream via the
#     INDEPENDENT reference, then diff it against the fixture's `corrupted` partition
#     (the output a buggy impl would emit, breaking ONE invariant). A genuine defect
#     diverges -> status=fail -> the mutant is KILLED.
#
# differential.py is the SAME diff-truth gate.sh drives over seeded streams at
# benchmark time and that bin/falsify applies to fixtures. This script translates its
# verdict into the 8-field report.json and exits 0 on pass / 1 on fail / 2 on IO
# error (no valid report producible).
#
# Report schema (shared across all gates, spec H-1 — 8 fields): gate_id, status,
# first_divergence {file,step,expected,actual}|null, metrics, fix_hint, haid, wave, ts.
#
# Usage:
#   run.sh [--input <fixture-path>] [--report <out-path>]
#     --input   fixture to grade (default: fixtures/golden/differential.json).
#     --report  where to WRITE report.json (default: <domain>/report.json).
#
# Exit codes: 0 = PASS (status=pass); 1 = FAIL (status=fail); 2 = usage/IO error.
set -euo pipefail

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
fi
ORACLE_DIR="$(cd "$(dirname "$SELF")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "error: python3 is required" >&2; exit 2; }

GATE_ID="issue-collection"
DIFF="$ORACLE_DIR/differential.py"
DEFAULT_INPUT="$ORACLE_DIR/fixtures/golden/differential.json"
DEFAULT_REPORT="$ORACLE_DIR/report.json"

usage() { sed -n '2,30p' "$SELF"; }

INPUT=""
REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input)  INPUT="${2:?--input needs a fixture path}"; shift 2 ;;
    --report) REPORT="${2:?--report needs an output path}"; shift 2 ;;
    --truth)  shift 2 ;;   # accepted for contract symmetry; this gate derives its
                           # truth from the fixture stream via the reference, so a
                           # separate truth file is not used (and never an X-vs-X diff).
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

# ── Grade the fixture through the single source of diff-truth ──
# differential.py grade emits {status, first_divergence, metrics}; exit 0/1/2.
GRADE="$("$PY" "$DIFF" grade --input "$INPUT" 2>/dev/null)" || true
if [ -z "$GRADE" ] || ! jq -e . >/dev/null 2>&1 <<<"$GRADE"; then
  echo "error: differential engine produced no gradable result for $INPUT" >&2
  exit 2
fi

STATUS="$(jq -r '.status // empty' <<<"$GRADE")"
HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
TS="$(date -u +%FT%TZ)"

write_pass() {
  local metrics="$1" hint="$2"
  jq -n --arg gate_id "$GATE_ID" --arg status "pass" \
        --argjson metrics "$metrics" --arg fix_hint "$hint" \
        --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
     '{gate_id:$gate_id, status:$status, first_divergence:null, metrics:$metrics,
       fix_hint:$fix_hint, haid:$haid,
       wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$REPORT"
}

write_fail() {
  local step="$1" expected="$2" actual="$3" metrics="$4" hint="$5"
  jq -n --arg gate_id "$GATE_ID" --arg status "fail" --arg file "$GATE_ID" \
        --arg step "$step" --arg expected "$expected" --arg actual "$actual" \
        --argjson metrics "$metrics" --arg fix_hint "$hint" \
        --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
     '{gate_id:$gate_id, status:$status,
       first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
       metrics:$metrics, fix_hint:$fix_hint, haid:$haid,
       wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$REPORT"
}

METRICS="$(jq -c '.metrics // {}' <<<"$GRADE")"

case "$STATUS" in
  pass)
    write_pass "$METRICS" \
      "Impl aggregate equals the independent reference on the served/suppressed/excluded_security partition at every bucket — no action needed."
    echo "report: $REPORT  (status=pass)"
    exit 0
    ;;
  fail)
    STEP="$(jq -r '.first_divergence.step // "partition"' <<<"$GRADE")"
    EXP="$(jq -r '.first_divergence.expected // ""' <<<"$GRADE")"
    ACT="$(jq -r '.first_divergence.actual // ""' <<<"$GRADE")"
    write_fail "$STEP" "$EXP" "$ACT" "$METRICS" \
      "Impl aggregate diverges from the independent reference. Re-derive the k-anon partition from INVARIANTS.md: distinct-team count (not rows) >= ISSUE_K_ANONYMITY_MIN(=10) to SERVE (INV-B); sub-threshold buckets SUPPRESSED with teams only; security_sensitive records EXCLUDED at any k (INV-F); the bucket key MUST include signature_hash."
    echo "report: $REPORT  (status=fail)"
    exit 1
    ;;
  error|*)
    STEP="$(jq -r '.first_divergence.step // "ungradable input"' <<<"$GRADE")"
    EXP="$(jq -r '.first_divergence.expected // ""' <<<"$GRADE")"
    ACT="$(jq -r '.first_divergence.actual // ""' <<<"$GRADE")"
    echo "error: fixture is ungradable ($STEP): expected $EXP, got $ACT" >&2
    exit 2
    ;;
esac
