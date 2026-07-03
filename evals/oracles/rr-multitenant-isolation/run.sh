#!/usr/bin/env bash
# run.sh — rr-multitenant-isolation oracle gate, structured-contract front end (spec 2A).
#
# THE CROSS-TENANT-DENIAL ORACLE. The whole multi-tenant isolation story as a single
# gate: two tenants (A, B) each set up their own creds/installation/queue, and EVERY
# cross-tenant attack from the W0 ledger §3 RED-line table
# (docs/specs/2026-07-03-rr-isolation-invariants.md) MUST be DENIED. This gate goes RED
# the instant ANY isolation gate is dropped — that is the meta-proof the gates are
# load-bearing, not decorative.
#
# The graded subject (--input) is a CANDIDATE isolation module: an ES module exporting
# `default function evaluate(attackId)` returning "DENY" | "ALLOW" for each cross-tenant
# attack. The acceptance oracle (--truth, default fixtures/golden/acceptance.json) is
# the fixed {attackId -> "DENY"} truth table, applied identically to the golden
# candidate and to every gate-dropped mutant. grade.mjs runs the candidate over every
# attack and emits its raw decisions; THIS script is the single source of diff-truth: it
# zips candidate decisions against the acceptance expecteds and reports the FIRST attack
# that returned ALLOW (the cross-tenant attack that SUCCEEDED) as first_divergence
# {file, step, expected:"DENY", actual}.
#
#   report.json = {                              # spec H-1 — 8 fields
#     "gate_id":          "rr-multitenant-isolation",
#     "status":           "pass" | "fail",
#     "first_divergence": { file, step, expected, actual } | null,
#     "metrics":          { attacks_total, attacks_checked, first_breach, feature },
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
#   --input  <path>   Candidate isolation module to grade (ES module exporting default
#                     evaluate(attackId)). Default: fixtures/golden/candidate.mjs.
#   --truth  <path>   Acceptance oracle (fixed {attackId -> DENY} table). Default:
#                     fixtures/golden/acceptance.json. Weakening this file (dropping an
#                     attack case) is exactly how test/heimdall-rr-isolation-oracle.test.sh
#                     proves the acceptance table does the work: a weakened oracle lets
#                     the mutant that only flips that case SURVIVE, dropping the falsify
#                     score below 1.0.
#   --report <path>   Where to WRITE report.json. Default: gate-dir report.json.
#
# Exit: 0 pass, 1 fail, 2 usage/IO error (ungradable — no valid report).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_ID="rr-multitenant-isolation"
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
[ -f "$INPUT" ]  || die "candidate module missing: $INPUT"

# ── attacks_total; an oracle with ZERO attacks is ungradable (no false-green over
#    nothing — same law as emulator-gb's R-6 empty-stream refusal). ────────────────
attacks_total="$(jq -r '(.cases // []) | length' "$TRUTH" 2>/dev/null || echo 0)"
case "$attacks_total" in ''|*[!0-9]*) attacks_total=0 ;; esac

emit_error() {
  local step="$1" exp="$2" act="$3" hint="$4"
  local haid wave ts tmp
  haid="${HEIMDALL_HAID:-haid:local}"; wave="${HEIMDALL_WAVE:-}"; ts="$(date -u +%FT%TZ)"
  mkdir -p "$(dirname "$REPORT")"; tmp="$(mktemp)"
  jq -n --arg gate_id "$GATE_ID" --arg file "$GATE_ID" --arg step "$step" \
        --arg expected "$exp" --arg actual "$act" \
        --argjson attacks_total "$attacks_total" --arg hint "$hint" \
        --arg haid "$haid" --arg wave "$wave" --arg ts "$ts" \
    '{gate_id:$gate_id, status:"error",
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:{attacks_total:$attacks_total, attacks_checked:0, first_breach:null, feature:"rr-multitenant-isolation"},
      fix_hint:$hint, haid:$haid, wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp"
  mv "$tmp" "$REPORT"
}

if [ "$attacks_total" -lt 1 ]; then
  emit_error "acceptance oracle" "attacks_total>=1" "attacks_total=$attacks_total" \
    "The acceptance oracle has zero cross-tenant attacks; grading isolation over nothing proves nothing (false-green). Provide a --truth acceptance.json with >=1 attack case."
  printf '%s: error (empty acceptance oracle) -> %s\n' "$GATE_ID" "$REPORT" >&2
  exit 2
fi

# ── Expected {attackId, decision} lines from the acceptance oracle, in case order ──
exp_lines=()
while IFS= read -r line; do exp_lines+=("$line"); done < <(jq -r '.cases[] | "\(.n)\t\(.expected)"' "$TRUTH")

# ── Run the candidate over every attack via grade.mjs; capture its raw decisions ──
got_file="$(mktemp)"
trap 'rm -f "$got_file"' EXIT
node "$GRADER" "$INPUT" "$TRUTH" >"$got_file" 2>/dev/null || true

got_lines=()
while IFS= read -r line; do got_lines+=("$line"); done < "$got_file"

status="pass"
div_step=""; div_expected=""; div_actual=""
first_breach="null"      # JSON literal null unless an attack breaches
attacks_checked=0

# ── Load-failure: grade.mjs could not even run the candidate (import failed, no
#    evaluate export, grader crashed). That is a maximal isolation failure. FAIL. ──
first_got="${got_lines[0]:-}"
first_got_field1="${first_got%%$'\t'*}"
if [ "${#got_lines[@]}" -eq 0 ]; then
  status="fail"; div_step="module load"
  div_expected="importable module exporting default evaluate(attackId)"
  div_actual="<candidate produced no output (grader failed to load or run it)>"
  first_breach="\"module load\""
elif [ "$first_got_field1" = "__LOADERR__" ]; then
  status="fail"; div_step="module load"
  div_expected="importable module exporting default evaluate(attackId)"
  div_actual="${first_got#*$'\t'}"
  first_breach="\"module load\""
else
  # ── Zip candidate decisions against acceptance expecteds; FIRST breach wins ──
  i=0
  while [ "$i" -lt "$attacks_total" ]; do
    exp_line="${exp_lines[i]:-}"
    exp_n="${exp_line%%$'\t'*}"
    exp_val="${exp_line#*$'\t'}"
    got_line="${got_lines[i]:-}"
    if [ -z "$got_line" ] && [ "$i" -ge "${#got_lines[@]}" ]; then
      got_n="$exp_n"; got_val="<no decision for this attack>"
    else
      got_n="${got_line%%$'\t'*}"
      if [ "$got_line" = "$got_n" ]; then got_val=""; else got_val="${got_line#*$'\t'}"; fi
    fi
    attacks_checked=$(( i + 1 ))
    if [ "$got_n" != "$exp_n" ] || [ "$got_val" != "$exp_val" ]; then
      status="fail"
      div_step="$exp_n"
      div_expected="$exp_val"
      div_actual="$got_val"
      first_breach="\"$exp_n\""
      break
    fi
    i=$(( i + 1 ))
  done
fi

# ── fix_hint ──────────────────────────────────────────────────────────────────────
if [ "$status" = "pass" ]; then
  fix_hint="Every one of the ${attacks_total} cross-tenant attack(s) was DENIED — the multi-tenant isolation holds end-to-end (repo<->team authz, server-derived team_id, per-team cred/queue/installation partition, enqueue-only public surface). No isolation gate is missing."
else
  fix_hint="Cross-tenant attack '${div_step}' was NOT denied: acceptance demanded '${div_expected}', candidate returned '${div_actual}'. An isolation gate is missing or weakened — one tenant can now reach another tenant's repo/cred/queue/installation/partition. Restore the dropped gate so every attack is denied. The denial oracle is the floor; it does not move."
fi

# ── Emit the typed report.json (atomic write) ───────────────────────────────────────
HAID="${HEIMDALL_HAID:-haid:local}"
WAVE="${HEIMDALL_WAVE:-}"
TS="$(date -u +%FT%TZ)"
mkdir -p "$(dirname "$REPORT")"
tmp_report="$(mktemp)"
if [ -n "$div_step" ]; then
  jq -n \
    --arg gate_id "$GATE_ID" --arg status "$status" --arg file "$GATE_ID" \
    --arg step "$div_step" --arg expected "$div_expected" --arg actual "$div_actual" \
    --argjson attacks_total "$attacks_total" --argjson attacks_checked "$attacks_checked" \
    --argjson first_breach "$first_breach" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:$status,
      first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
      metrics:{attacks_total:$attacks_total, attacks_checked:$attacks_checked,
               first_breach:$first_breach, feature:"rr-multitenant-isolation"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
else
  jq -n \
    --arg gate_id "$GATE_ID" --arg status "$status" \
    --argjson attacks_total "$attacks_total" --argjson attacks_checked "$attacks_checked" \
    --arg fix_hint "$fix_hint" --arg haid "$HAID" --arg wave "$WAVE" --arg ts "$TS" \
    '{gate_id:$gate_id, status:$status, first_divergence:null,
      metrics:{attacks_total:$attacks_total, attacks_checked:$attacks_checked,
               first_breach:null, feature:"rr-multitenant-isolation"},
      fix_hint:$fix_hint, haid:$haid,
      wave:(if $wave=="" then null else $wave end), ts:$ts}' >"$tmp_report"
fi
mv "$tmp_report" "$REPORT"

printf '%s: %s (%d/%d attacks checked) -> %s\n' "$GATE_ID" "$status" "$attacks_checked" "$attacks_total" "$REPORT" >&2

[ "$status" = "pass" ] && exit 0 || exit 1
