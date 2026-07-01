#!/usr/bin/env bash
# run.sh — ponytail-underdelivery oracle gate, structured-contract front end (spec 2A).
#
# THE UNDER-DELIVERY GUARD. The user's #1 fear about adopting ponytail's lazy-
# ladder: an agent reads rung 1 ("does this need to exist? -> skip") as license
# to hollow out the hard part, silently drop a required criterion, or call a
# terse-but-broken thing "lazy=done." The defense is NOT a prompt — it is that
# THIS gate is non-bypassable. A candidate implementation of a feature only
# PASSES when it satisfies the feature's fixed acceptance ORACLE at EVERY case.
# Minimalism can shrink the diff; it can NEVER make a failing acceptance pass by
# being terse.
#
# The graded subject (--input) is a CANDIDATE implementation: an ES module
# exporting `default function roman(n)` (integer 1..3999 -> Roman numeral). The
# acceptance oracle (--truth, default fixtures/golden/acceptance.json) is the
# fixed {n -> expected} truth table, applied identically to the golden candidate
# and to every under-delivery mutant. grade.mjs runs the candidate over every
# case and emits its raw outputs; THIS script is the single source of diff-truth:
# it zips candidate output against acceptance expecteds and reports the FIRST
# failing case as first_divergence {file, step, expected, actual}.
#
#   report.json = {                              # spec H-1 — 8 fields
#     "gate_id":          "ponytail-underdelivery",
#     "status":           "pass" | "fail",
#     "first_divergence": { file, step, expected, actual } | null,
#     "metrics":          { cases_total, cases_compared, first_fail_case, feature },
#     "fix_hint":         string,
#     "haid":             string,                 # env HEIMDALL_HAID else "haid:local"
#     "wave":             string | null,          # env HEIMDALL_WAVE else null
#     "ts":               string                  # date -u +%FT%TZ
#   }
#
# Consumers (bin/falsify, bin/corpus) read report.json — never this stdout.
#
# Usage:
#   run.sh [--input <candidate.mjs>] [--truth <acceptance.json>] [--report <out>]
#
#   --input  <path>   Candidate implementation to grade (ES module exporting
#                     default roman(n)). Default: fixtures/golden/candidate.mjs.
#   --truth  <path>   Acceptance oracle (fixed {n,expected} table). Default:
#                     fixtures/golden/acceptance.json. Weakening this file (e.g.
#                     dropping the subtractive / thousands cases) is exactly how
#                     test/heimdall-underdelivery-guard.test.sh proves the gate's
#                     strength does the work: a weakened oracle lets an under-
#                     delivery mutant SURVIVE, dropping the falsify score below 1.0.
#   --report <path>   Where to WRITE report.json. Default: gate-dir report.json.
#
# Exit: 0 pass, 1 fail, 2 usage/IO error (ungradable — no valid report).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_ID="ponytail-underdelivery"
GRADER="$HERE/grade.mjs"

INPUT="$HERE/fixtures/golden/candidate.mjs"
TRUTH="$HERE/fixtures/golden/acceptance.json"
REPORT="$HERE/report.json"

die() { printf 'run.sh: %s\n' "$*" >&2; exit 2; }

command -v jq   >/dev/null 2>&1 || die "jq is required to emit report.json"
command -v node >/dev/null 2>&1 || die "node is required to run the candidate through grade.mjs"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)  INPUT="${2:?--input needs a path}";   shift 2 ;;
    --truth)  TRUTH="${2:?--truth needs a path}";   shift 2 ;;
    --report) REPORT="${2:?--report needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

[ -f "$GRADER" ] || die "grader missing: $GRADER"
[ -f "$TRUTH" ]  || die "acceptance oracle missing: $TRUTH"
[ -f "$INPUT" ]  || die "candidate implementation missing: $INPUT"

# ── cases_total; an oracle with ZERO cases is ungradable (no false-green over
#    nothing — same law as emulator-gb's R-6 empty-stream refusal). ────────────
cases_total="$(jq -r '(.cases // []) | length' "$TRUTH" 2>/dev/null || echo 0)"
case "$cases_total" in ''|*[!0-9]*) cases_total=0 ;; esac

emit_error() {
  local step="$1" exp="$2" act="$3" hint="$4"
  local haid wave ts tmp
  haid="${HEIMDALL_HAID:-haid:local}"; wave="${HEIMDALL_WAVE:-}"; ts="$(date -u +%FT%TZ)"
  mkdir -p "$(dirname "$REPORT")"; tmp="$(mktemp)"
  jq -n --arg gate_id "$GATE_ID" --arg file "$GATE_ID" --arg step "$step" \
        --arg expected "$exp" --arg actual "$act" \
        --argjson cases_total "$cases_total" --arg hint "$hint" \
        --arg haid "$haid" --arg wave "$wave" --arg ts "$ts" \
    '{gate_id:$gate_id, status:"error",
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:{cases_total:$cases_total, cases_compared:0, first_fail_case:null, feature:"roman"},
      fix_hint:$hint, haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp"
  mv "$tmp" "$REPORT"
}

if [ "$cases_total" -lt 1 ]; then
  emit_error "acceptance oracle" "cases_total>=1" "cases_total=$cases_total" \
    "The acceptance oracle has zero cases; grading a feature over nothing proves nothing (false-green). Provide a --truth acceptance.json with >=1 case."
  printf '%s: error (empty acceptance oracle) -> %s\n' "$GATE_ID" "$REPORT" >&2
  exit 2
fi

# ── Expected {n,expected} lines from the acceptance oracle, in case order ─────
exp_lines=()
while IFS= read -r line; do exp_lines+=("$line"); done < <(jq -r '.cases[] | "\(.n)\t\(.expected)"' "$TRUTH")

# ── Run the candidate over every case via grade.mjs; capture its raw outputs ──
got_file="$(mktemp)"
trap 'rm -f "$got_file"' EXIT
node "$GRADER" "$INPUT" "$TRUTH" >"$got_file" 2>/dev/null || true

got_lines=()
while IFS= read -r line; do got_lines+=("$line"); done < "$got_file"

status="pass"
div_step=""; div_expected=""; div_actual=""
first_fail_case="null"      # JSON literal null unless a case fails
cases_compared=0

# ── Load-failure: grade.mjs could not even run the candidate (import failed, no
#    roman export, grader crashed). That is the maximal under-delivery. FAIL. ──
first_got="${got_lines[0]:-}"
first_got_field1="${first_got%%$'\t'*}"
if [ "${#got_lines[@]}" -eq 0 ]; then
  status="fail"; div_step="module load"
  div_expected="importable module exporting default roman(n)"
  div_actual="<candidate produced no output (grader failed to load or run it)>"
  first_fail_case="\"module load\""
elif [ "$first_got_field1" = "__LOADERR__" ]; then
  status="fail"; div_step="module load"
  div_expected="importable module exporting default roman(n)"
  div_actual="${first_got#*$'\t'}"
  first_fail_case="\"module load\""
else
  # ── Zip candidate output against acceptance expecteds; FIRST mismatch wins ──
  i=0
  while [ "$i" -lt "$cases_total" ]; do
    exp_line="${exp_lines[i]:-}"
    exp_n="${exp_line%%$'\t'*}"
    exp_val="${exp_line#*$'\t'}"
    got_line="${got_lines[i]:-}"
    if [ -z "$got_line" ] && [ "$i" -ge "${#got_lines[@]}" ]; then
      got_n="$exp_n"; got_val="<no output for this case>"
    else
      got_n="${got_line%%$'\t'*}"
      if [ "$got_line" = "$got_n" ]; then got_val=""; else got_val="${got_line#*$'\t'}"; fi
    fi
    cases_compared=$(( i + 1 ))
    if [ "$got_n" != "$exp_n" ] || [ "$got_val" != "$exp_val" ]; then
      status="fail"
      div_step="roman(${exp_n})"
      div_expected="$exp_val"
      div_actual="$got_val"
      first_fail_case="\"roman(${exp_n})\""
      break
    fi
    i=$(( i + 1 ))
  done
fi

# ── fix_hint ──────────────────────────────────────────────────────────────────
if [ "$status" = "pass" ]; then
  fix_hint="Candidate satisfies the acceptance oracle at all ${cases_total} case(s) — the feature is fully delivered (subtractive notation + full 1..3999 range). Minimalism did not cause under-delivery."
else
  fix_hint="Under-delivery caught at ${div_step}: acceptance expected '${div_expected}', candidate produced '${div_actual}'. The feature is NOT fully delivered — a required capability was skipped, dropped, or broken. Ponytail's ladder trims verbosity, never requirements: build the missing behavior so every acceptance case passes. The gate is the floor; it does not move."
fi

# ── Emit the typed report.json (atomic write) ─────────────────────────────────
HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
TS="$(date -u +%FT%TZ)"
mkdir -p "$(dirname "$REPORT")"
tmp_report="$(mktemp)"
if [ -n "$div_step" ]; then
  jq -n \
    --arg gate_id "$GATE_ID" --arg status "$status" --arg file "$GATE_ID" \
    --arg step "$div_step" --arg expected "$div_expected" --arg actual "$div_actual" \
    --argjson cases_total "$cases_total" --argjson cases_compared "$cases_compared" \
    --argjson first_fail_case "$first_fail_case" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:$status,
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:{cases_total:$cases_total, cases_compared:$cases_compared,
               first_fail_case:$first_fail_case, feature:"roman"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
else
  jq -n \
    --arg gate_id "$GATE_ID" --arg status "$status" \
    --argjson cases_total "$cases_total" --argjson cases_compared "$cases_compared" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:$status, first_divergence:null,
      metrics:{cases_total:$cases_total, cases_compared:$cases_compared,
               first_fail_case:null, feature:"roman"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
fi
mv "$tmp_report" "$REPORT"

printf '%s: %s (%d/%d cases compared) -> %s\n' "$GATE_ID" "$status" "$cases_compared" "$cases_total" "$REPORT" >&2

[ "$status" = "pass" ] && exit 0 || exit 1
