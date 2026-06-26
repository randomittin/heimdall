#!/usr/bin/env bash
# report.sh — shared report.json writer for Heimdall sentinels (spec H-3).
#
# Every sentinel emits the SAME 8-field gate-report contract the oracle gates
# emit (evals/oracles/REPORT-CONTRACT.md, spec H-1):
#
#   { gate_id, status, first_divergence, metrics, fix_hint, haid, wave, ts }
#
# A sentinel is a background spawn that does ONE job and writes ONE report.json,
# then dies. This library is the SINGLE source of report-emission truth so every
# sentinel's report is byte-shaped identically and consumers (orchestrator,
# falsify-style readers, the ledger) parse exactly one schema.
#
# Status vocabulary (sentinel-extended over the oracle pass/fail):
#   pass    — the sentinel ran its real job and found nothing wrong.
#   fail    — the sentinel ran its real job and found a divergence/violation.
#   skipped — the sentinel could not run its real job because a required tool is
#             absent. This is HONEST degradation, never a fake pass. A skipped
#             report carries first_divergence:null and a fix_hint naming the
#             missing tool. Consumers MUST treat skipped as "did not run", never
#             as a pass.
#   partial — the sentinel hit its token/time budget before finishing; whatever
#             it did find is reported, with a flag in metrics.budget_overrun.
#
# Exit codes mirror the oracle contract and extend it:
#   0 = pass / skipped (non-blocking outcomes)   1 = fail   2 = IO/usage error
#   (partial maps to whatever the partial finding was — pass-ish 0 or fail 1.)
#
# Usage:
#   source "$(dirname "$0")/lib/report.sh"
#   sentinel_report <out-path> <gate_id> <status> <metrics-json> <fix_hint> \
#                   [<step> <expected> <actual>]
#
#   - out-path : where to WRITE report.json (parent dirs created).
#   - status   : pass | fail | skipped | partial
#   - metrics  : a JSON object string (use {} if none).
#   - step/expected/actual : present => first_divergence object; absent => null.
#
# haid  <- env HEIMDALL_HAID  else "haid:local"
# wave  <- env HEIMDALL_WAVE  else null
# ts    <- date -u +%FT%TZ

# Emit the typed report.json. Returns 0 always (writing is not the gate result;
# the caller decides the exit code from the status it passed).
sentinel_report() {
  local out="$1" gate_id="$2" status="$3" metrics="$4" fix_hint="$5"
  local step="${6:-}" expected="${7:-}" actual="${8:-}"

  command -v jq >/dev/null 2>&1 || { echo "error: jq is required to emit report.json" >&2; return 2; }

  local out_dir; out_dir="$(dirname "$out")"
  mkdir -p "$out_dir"

  local haid="${HEIMDALL_HAID:-haid:local}"
  local wave="${HEIMDALL_WAVE:-}"
  local ts; ts="$(date -u +%FT%TZ)"

  # Validate metrics is a JSON object; fall back to {} rather than write garbage.
  if ! printf '%s' "$metrics" | jq -e 'type == "object"' >/dev/null 2>&1; then
    metrics='{}'
  fi

  if [ -z "$step" ]; then
    jq -n \
      --arg gate_id "$gate_id" \
      --arg status "$status" \
      --argjson metrics "$metrics" \
      --arg fix_hint "$fix_hint" \
      --arg haid "$haid" \
      --arg wave "$wave" \
      --arg ts "$ts" \
      '{gate_id:$gate_id, status:$status, first_divergence:null, metrics:$metrics,
        fix_hint:$fix_hint, haid:$haid,
        wave:(if $wave=="" then null else $wave end), ts:$ts}' \
      >"$out"
  else
    jq -n \
      --arg gate_id "$gate_id" \
      --arg status "$status" \
      --arg file "$gate_id" \
      --arg step "$step" \
      --arg expected "$expected" \
      --arg actual "$actual" \
      --argjson metrics "$metrics" \
      --arg fix_hint "$fix_hint" \
      --arg haid "$haid" \
      --arg wave "$wave" \
      --arg ts "$ts" \
      '{gate_id:$gate_id, status:$status,
        first_divergence:{file:$file, step:$step, expected:$expected, actual:$actual},
        metrics:$metrics, fix_hint:$fix_hint, haid:$haid,
        wave:(if $wave=="" then null else $wave end), ts:$ts}' \
      >"$out"
  fi
  echo "report: $out  (status=$status)"

  # Drive the watchman HUD off the verdict (best-effort; never blocks/errors).
  # One sink covers every sentinel: pass->pass, fail->deny, else->watching.
  # gate name = gate_id with the "sentinel-" prefix stripped for a clean label.
  local _evt _verd _gate
  _evt="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hmd-gate-event.sh"
  case "$status" in pass) _verd=pass ;; fail) _verd=deny ;; *) _verd=watching ;; esac
  _gate="${gate_id#sentinel-}"
  [ -x "$_evt" ] && "$_evt" "$_verd" "$_gate" >/dev/null 2>&1 || true
}

# Map a sentinel status to the process exit code per the contract above.
sentinel_exit_code() {
  case "$1" in
    pass|skipped) echo 0 ;;
    fail)         echo 1 ;;
    partial)      echo "${2:-0}" ;;  # caller supplies the partial finding's code
    *)            echo 2 ;;
  esac
}
