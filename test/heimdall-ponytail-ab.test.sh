#!/usr/bin/env bash
# test/heimdall-ponytail-ab.test.sh — acceptance for the ponytail A/B telemetry harness.
#
# Proves the harness end-to-end on SYNTHETIC FIXTURES ONLY — NO real model call, NO
# network, NO token spend. --dry validates wiring + emits the schema; --summary is
# exercised over hand-built JSONL fixtures with KNOWN numbers so every computed
# figure is exactly predictable (the token-meter test's philosophy, applied here).
#
# Asserted:
#   (a) --dry exits 0 and prints the on/off pass-rate summary shape.
#   (b) the emitted JSONL schema has the 3 headline fields (loc, tokens,
#       acceptance_pass) present for BOTH modes (on AND off).
#   (c) the summary prints acceptance-pass-rate for ladder ON and ladder OFF.
#   (d) the BLANK / n=0 case reports blank (never a fabricated number) — no "%"
#       rate is printed when there are zero runs.
#   (e) --summary over a KNOWN fixture computes the right pass-rate on/off and the
#       right mean LOC + token deltas (the real measurement math).
#   (f) the UNDER-DELIVERY guard fires: when ON's pass-rate is BELOW OFF's, the
#       summary flags "UNDER-DELIVERY / too aggressive" (the spec's headline check).
#   (g) --summary over an EMPTY JSONL reports blank / n=0, exit 0 (no made-up rate).
#   (h) the ladder toggle is REAL: build_coder_cmd emits a longer prompt with the
#       ladder ON than OFF (the injected write-time ruleset is genuine bytes).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AB="$ROOT/bin/heimdall-ponytail-ab"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -x "$AB" ] || { echo "FATAL: heimdall-ponytail-ab not executable at $AB" >&2; exit 2; }

WORK="$(mktemp -d -t "ponytail-ab-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# Strip ANSI color so assertions match on plain text.
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

# ── (a) --dry exits 0 and produces output ─────────────────────────────────────
set +e
DRY_OUT="$("$AB" --dry 2>&1)"; DRY_RC=$?
set -e
DRY_TXT="$(printf '%s' "$DRY_OUT" | strip)"
if [ "$DRY_RC" -eq 0 ] && [ -n "$DRY_TXT" ]; then
  ok "(a) --dry exits 0 and prints output"
else
  bad "(a) --dry did not exit 0 (rc=$DRY_RC)"; printf '%s\n' "$DRY_TXT"
fi

# ── (b) emitted JSONL schema has the 3 headline fields for BOTH modes ─────────
SCHEMA="$ROOT/evals/ponytail-ab/schema.sample.jsonl"
if [ -f "$SCHEMA" ]; then
  N_ON="$(jq -c 'select(.mode=="on")  | select(has("loc") and has("tokens") and has("acceptance_pass"))' "$SCHEMA" | wc -l | tr -d ' ')"
  N_OFF="$(jq -c 'select(.mode=="off") | select(has("loc") and has("tokens") and has("acceptance_pass"))' "$SCHEMA" | wc -l | tr -d ' ')"
  if [ "$N_ON" -ge 1 ] && [ "$N_OFF" -ge 1 ]; then
    ok "(b) schema sample has loc+tokens+acceptance_pass for BOTH modes (on=$N_ON, off=$N_OFF)"
  else
    bad "(b) schema missing the 3 fields for a mode (on=$N_ON, off=$N_OFF)"; cat "$SCHEMA"
  fi
else
  bad "(b) schema sample not written: $SCHEMA"
fi

# ── (c) dry summary prints pass-rate for ladder ON and ladder OFF ─────────────
if printf '%s\n' "$DRY_TXT" | grep -q 'acceptance-pass-rate  ladder ON' \
   && printf '%s\n' "$DRY_TXT" | grep -q 'acceptance-pass-rate  ladder OFF'; then
  ok "(c) summary prints acceptance-pass-rate for ladder ON and ladder OFF"
else
  bad "(c) summary missing an on/off pass-rate line"; printf '%s\n' "$DRY_TXT"
fi

# ── (d) BLANK / n=0: dry has no runs => the ON pass-rate line carries no "%" ──
ON_LINE="$(printf '%s\n' "$DRY_TXT" | grep 'acceptance-pass-rate  ladder ON' | head -1)"
OFF_LINE="$(printf '%s\n' "$DRY_TXT" | grep 'acceptance-pass-rate  ladder OFF' | head -1)"
if printf '%s' "$ON_LINE" | grep -q 'n=0' && ! printf '%s' "$ON_LINE" | grep -q '%' \
   && printf '%s' "$OFF_LINE" | grep -q 'n=0' && ! printf '%s' "$OFF_LINE" | grep -q '%'; then
  ok "(d) blank/n=0 case reports blank — no fabricated % rate with zero runs"
else
  bad "(d) blank case not honest (on='$ON_LINE' off='$OFF_LINE')"
fi

# ── (e) --summary over a KNOWN fixture computes the right numbers ──────────────
# Two tasks, two modes. KNOWN values:
#   T1: on{loc10,tok100,pass true}   off{loc20,tok200,pass true}
#   T2: on{loc 5,tok 50,pass false}  off{loc30,tok300,pass true}
# Expected:
#   pass-rate ON  = 1/2 = 50%      pass-rate OFF = 2/2 = 100%
#   mean LOC delta (off-on)   = ((20-10)+(30-5))/2 = (10+25)/2 = 17.5
#   mean token delta (off-on) = ((200-100)+(300-50))/2 = (100+250)/2 = 175
FIX="$WORK/known.jsonl"
{
  printf '%s\n' '{"metric":"ponytail-ab","task":"T1","mode":"on","ladder":true,"loc":10,"tokens":100,"acceptance_pass":true}'
  printf '%s\n' '{"metric":"ponytail-ab","task":"T1","mode":"off","ladder":false,"loc":20,"tokens":200,"acceptance_pass":true}'
  printf '%s\n' '{"metric":"ponytail-ab","task":"T2","mode":"on","ladder":true,"loc":5,"tokens":50,"acceptance_pass":false}'
  printf '%s\n' '{"metric":"ponytail-ab","task":"T2","mode":"off","ladder":false,"loc":30,"tokens":300,"acceptance_pass":true}'
} > "$FIX"
SUM_TXT="$("$AB" --summary "$FIX" 2>&1 | strip)"
E_ON="$(printf '%s\n'  "$SUM_TXT" | grep 'acceptance-pass-rate  ladder ON'  | head -1)"
E_OFF="$(printf '%s\n' "$SUM_TXT" | grep 'acceptance-pass-rate  ladder OFF' | head -1)"
E_LOC="$(printf '%s\n' "$SUM_TXT" | grep 'mean LOC delta'   | head -1)"
E_TOK="$(printf '%s\n' "$SUM_TXT" | grep 'mean token delta' | head -1)"
if printf '%s' "$E_ON"  | grep -q '50%'  && printf '%s' "$E_OFF" | grep -q '100%' \
   && printf '%s' "$E_LOC" | grep -q '17.5' && printf '%s' "$E_TOK" | grep -q '175'; then
  ok "(e) --summary computes pass-rate on=50% off=100%, mean LOC delta 17.5, token delta 175"
else
  bad "(e) --summary math wrong (on='$E_ON' off='$E_OFF' loc='$E_LOC' tok='$E_TOK')"; printf '%s\n' "$SUM_TXT"
fi

# ── (f) UNDER-DELIVERY guard fires when ON pass-rate < OFF pass-rate ───────────
if printf '%s\n' "$SUM_TXT" | grep -qi 'UNDER-DELIVERY'; then
  ok "(f) under-delivery guard fires when ladder ON pass-rate drops below OFF (the headline check)"
else
  bad "(f) under-delivery guard did not fire on a 50%<100% drop"; printf '%s\n' "$SUM_TXT"
fi

# ── (g) --summary over an EMPTY JSONL => blank / n=0, exit 0 ──────────────────
EMPTY="$WORK/empty.jsonl"; : > "$EMPTY"
set +e
EMP_OUT="$("$AB" --summary "$EMPTY" 2>&1)"; EMP_RC=$?
set -e
EMP_TXT="$(printf '%s' "$EMP_OUT" | strip)"
EMP_ON="$(printf '%s\n' "$EMP_TXT" | grep 'acceptance-pass-rate  ladder ON' | head -1)"
if [ "$EMP_RC" -eq 0 ] && printf '%s' "$EMP_ON" | grep -q 'n=0' && ! printf '%s' "$EMP_ON" | grep -q '%'; then
  ok "(g) --summary over empty JSONL => blank/n=0, exit 0 (no fabricated rate)"
else
  bad "(g) empty summary not blank/exit0 (rc=$EMP_RC on='$EMP_ON')"; printf '%s\n' "$EMP_TXT"
fi

# ── (h) the ladder toggle is REAL: ON prompt is strictly LONGER than OFF ──────
# Source the harness in a subshell to reach build_coder_cmd, then compare the
# assembled prompt byte-length across the two env values. A longer ON prompt
# proves the injected write-time ruleset is genuine (the toggle is not faked).
LEN_ON="$(
  HEIMDALL_LAZY_LADDER=1 bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    eval "$(sed -n "/^ladder_preamble()/,/^}/p; /^ladder_active()/,/^}/p; /^build_coder_cmd()/,/^}/p" "$0")"
    MODEL=""; PLUGIN_DIR="/x"
    build_coder_cmd "do a thing"
    printf "%s" "${CODER_CMD[*]}" | wc -c
  ' "$AB"
)"
LEN_OFF="$(
  HEIMDALL_LAZY_LADDER=0 bash -c '
    set -euo pipefail
    eval "$(sed -n "/^ladder_preamble()/,/^}/p; /^ladder_active()/,/^}/p; /^build_coder_cmd()/,/^}/p" "$0")"
    MODEL=""; PLUGIN_DIR="/x"
    build_coder_cmd "do a thing"
    printf "%s" "${CODER_CMD[*]}" | wc -c
  ' "$AB"
)"
LEN_ON="$(printf '%s' "$LEN_ON" | tr -d ' ')"
LEN_OFF="$(printf '%s' "$LEN_OFF" | tr -d ' ')"
if [ "${LEN_ON:-0}" -gt "${LEN_OFF:-0}" ]; then
  ok "(h) ladder toggle is real: ON prompt ($LEN_ON bytes) > OFF prompt ($LEN_OFF bytes)"
else
  bad "(h) ladder toggle not real: ON=$LEN_ON OFF=$LEN_OFF (expected ON longer)"
fi

echo
echo "  heimdall-ponytail-ab tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
