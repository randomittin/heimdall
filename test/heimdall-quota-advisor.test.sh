#!/usr/bin/env bash
# test/heimdall-quota-advisor.test.sh — hermetic acceptance for
# bin/heimdall-quota-advisor: the HONEST, NEVER-AUTO-SWITCHING advisor for a
# genuine Claude quota/session-limit exhaustion.
#
# Falsifiability (AGENTS.md): every "fires" assertion is paired with a
# "stays silent" counterpart on text missing exactly one required signal —
# proving the check is load-bearing, not decorative. HOME and all state
# paths are isolated under mktemp -d; no network, no live control plane,
# nothing written outside $WORK.
#
#   bash test/heimdall-quota-advisor.test.sh    (exit 0 = all cases pass)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-quota-advisor"
HMD="$ROOT/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: $CLI missing or not executable"; exit 1; }
[ -x "$HMD" ] || { echo "FATAL: $HMD missing or not executable"; exit 1; }

WORK="$(mktemp -d -t "quota-advisor-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export HOME="$WORK/home"; mkdir -p "$HOME"

echo "heimdall-quota-advisor.test.sh"

# Realistic termination text in the exact shape bin/lib/quota_stop.py's own
# regex requires (anchor phrase + "resets H:MMam/pm (TZ)") — the SAME
# classifier bin/heimdall-quota-resume already relies on. Numbers echo this
# task's own observed evidence (6pm / 11pm resets).
MSG_6PM="Agent terminated early due to an API error: You've hit your session limit · resets 6:00pm (America/New_York)"
MSG_11PM="Agent terminated early due to an API error: You've hit your usage limit · resets 11:00pm (America/Los_Angeles)"

echo "== section 1: check FIRES on a real exhaustion string =="

out1="$("$CLI" check --text "$MSG_6PM")"; rc1=$?
echo "---- quoted output (fires, 6pm case) ----"
printf '%s\n' "$out1"
echo "---- end quoted output ----"
if [ "$rc1" = 0 ] && [ -n "$out1" ] && printf '%s' "$out1" | grep -q "QUOTA EXHAUSTED"; then
  ok "check fires on a real exhaustion string (exit 0, non-empty)"
else
  bad "check should have fired on a real exhaustion string — rc=$rc1 out=$out1"
fi

out2="$("$CLI" check --text "$MSG_11PM")"; rc2=$?
if [ "$rc2" = 0 ] && printf '%s' "$out2" | grep -q "QUOTA EXHAUSTED"; then
  ok "check fires on a second real exhaustion string (11pm reset)"
else
  bad "check should have fired on the 11pm exhaustion string — rc=$rc2"
fi

echo "== section 2: check STAYS SILENT otherwise (fail-open) =="

# FALSIFIER 2a: anchor phrase only, no reset clause — must NOT fire. Proves
# this tool did not loosen the shared classifier's two-signal requirement.
out3="$("$CLI" check --text "You have hit your session limit for this billing period." 2>&1)"; rc3=$?
echo "---- quoted output (silent, anchor-only case) ----"
printf '[EMPTY OR: %s]\n' "$out3"
echo "---- end quoted output ----"
if [ "$rc3" != 0 ] && [ -z "$out3" ]; then
  ok "check stays silent on anchor-only text (no reset clause) — exit nonzero, no output"
else
  bad "check should stay silent on anchor-only text — rc=$rc3 out=$out3"
fi

# FALSIFIER 2b: a generic, unrelated HTTP rate-limit message.
out4="$("$CLI" check --text "HTTP 429 Too Many Requests: rate limit exceeded, retry after 30 seconds" 2>&1)"; rc4=$?
if [ "$rc4" != 0 ] && [ -z "$out4" ]; then
  ok "check stays silent on an unrelated generic rate-limit message"
else
  bad "check should stay silent on unrelated rate-limit text — rc=$rc4 out=$out4"
fi

# FALSIFIER 2c: empty input.
out5="$(printf '' | "$CLI" check 2>&1)"; rc5=$?
if [ "$rc5" != 0 ] && [ -z "$out5" ]; then
  ok "check stays silent on empty input"
else
  bad "check should stay silent on empty input — rc=$rc5 out=$out5"
fi

echo "== section 3: honesty ORDER — zero-risk option is not buried =="

line_wait="$(printf '%s\n' "$out1" | grep -n "WAIT FOR THE RESET" | head -1 | cut -d: -f1)"
line_tier="$(printf '%s\n' "$out1" | grep -n "SWITCH TO A CHEAPER TIER" | head -1 | cut -d: -f1)"
line_key="$(printf '%s\n' "$out1" | grep -n "BRING YOUR OWN API KEY" | head -1 | cut -d: -f1)"
line_router="$(printf '%s\n' "$out1" | grep -n "THIRD-PARTY ROUTERS" | head -1 | cut -d: -f1)"
if [ -n "$line_wait" ] && [ -n "$line_tier" ] && [ -n "$line_key" ] && [ -n "$line_router" ] \
   && [ "$line_wait" -lt "$line_tier" ] && [ "$line_tier" -lt "$line_key" ] && [ "$line_key" -lt "$line_router" ]; then
  ok "options print in honesty order: wait < tier-switch < own-key < third-party-router"
else
  bad "option order is wrong or a section is missing: wait=$line_wait tier=$line_tier key=$line_key router=$line_router"
fi

echo "== section 4: the OmniRoute safety boundary holds in the actual text =="

if printf '%s' "$out1" | grep -q "OmniRoute" && printf '%s' "$out1" | grep -q "github.com/diegosouzapw/OmniRoute"; then
  ok "OmniRoute is named, with its real URL"
else
  bad "OmniRoute is not named with its URL — the honest-disclosure requirement is not met"
fi
if printf '%s' "$out1" | grep -q "docs/analysis/2026-08-23-omniroute-assessment.md"; then
  ok "the risk assessment doc is linked by path"
else
  bad "the assessment doc path is missing from the advisory"
fi
if printf '%s' "$out1" | grep -qi "suspended"; then
  ok "the account-risk sentence is present (blunt, not legalese)"
else
  bad "no account-risk sentence found"
fi
if printf '%s' "$out1" | grep -qi "will not install or configure"; then
  ok "explicitly refuses to install/configure OmniRoute (naming, not wiring)"
else
  bad "missing the explicit will-not-install-or-configure statement"
fi
if printf '%s' "$out1" | grep -qi "never switches providers on its own"; then
  ok "explicit never-auto-switch statement present"
else
  bad "missing the never-auto-switch statement"
fi

# Negative assertions: the dangerous modes must never be offered as
# something to turn on.
if printf '%s' "$out1" | grep -qiE "enable (the )?(tier.?1|mitm|root-ca)"; then
  bad "advisory appears to OFFER TO ENABLE a dangerous OmniRoute mode — safety boundary breached"
else
  ok "advisory never offers to enable Tier-1 subscription-reuse or MITM decrypt modes"
fi
if printf '%s' "$out1" | grep -qiE "npm (i|install)|git clone|omniroute (config|setup|install)"; then
  bad "advisory contains install/setup instructions for OmniRoute — must only NAME it"
else
  ok "advisory contains no install/setup instructions for OmniRoute"
fi

echo "== section 5: reset countdown is REAL arithmetic, not a fabricated string =="

# Cross-check via an INDEPENDENT epoch computation (python3 + zoneinfo, not
# this tool's own code) — a real check, not the code checking itself.
NOW_FIXED="$(python3 -c "
from zoneinfo import ZoneInfo
from datetime import datetime
print(int(datetime(2026, 1, 15, 10, 0, 0, tzinfo=ZoneInfo('America/New_York')).timestamp()))
")"
EXPECT_EPOCH="$(python3 -c "
from zoneinfo import ZoneInfo
from datetime import datetime
print(int(datetime(2026, 1, 15, 18, 0, 0, tzinfo=ZoneInfo('America/New_York')).timestamp()))
")"
EXPECT_REMAIN_MIN=$(( (EXPECT_EPOCH - NOW_FIXED) / 60 ))
EXPECT_H=$((EXPECT_REMAIN_MIN / 60)); EXPECT_M=$((EXPECT_REMAIN_MIN % 60))

out_fixed="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_FIXED" "$CLI" check --text "$MSG_6PM")"
if printf '%s' "$out_fixed" | grep -q "about ${EXPECT_H}h ${EXPECT_M}m from now"; then
  ok "countdown matches an independently computed epoch (about ${EXPECT_H}h ${EXPECT_M}m)"
else
  bad "countdown does not match independent computation — got: $(printf '%s' "$out_fixed" | grep 'Resets ')"
fi

echo "== section 5b: advise --reason is a working alias of check --text (the exact repro that failed) =="

out1b="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_FIXED" "$CLI" advise --reason "$MSG_6PM")"; rc1b=$?
if [ "$rc1b" = 0 ] && [ "$out1b" = "$out_fixed" ]; then
  ok "advise --reason == check --text, byte-identical (advise is a real, wired verb)"
else
  bad "advise --reason should be byte-identical to check --text — rc=$rc1b"
fi

echo "== section 6: an unresolvable reset time still fires, honestly =="

BADTZ_MSG="Agent terminated early due to an API error: You've hit your session limit · resets 5:40pm (Not/ARealZone)"
out_badtz="$("$CLI" check --text "$BADTZ_MSG")"; rc_badtz=$?
if [ "$rc_badtz" = 0 ] && printf '%s' "$out_badtz" | grep -q "countdown unavailable"; then
  ok "unresolvable timezone still fires (real quota stop) with an honest countdown-unavailable line"
else
  bad "unresolvable-tz case failed — rc=$rc_badtz out=$out_badtz"
fi

echo "== section 7: tier headroom is LIVE data when available, honest fallback otherwise =="

REPO_NODATA="$WORK/repo-nodata"; mkdir -p "$REPO_NODATA/.planning"
out_nodata="$(cd "$REPO_NODATA" && "$CLI" check --text "$MSG_6PM")"
if printf '%s' "$out_nodata" | grep -q "This repo already defaults coding work to sonnet"; then
  ok "no metrics.jsonl -> honest static fallback line (not a fabricated live percentage)"
else
  bad "expected the fallback tier line with no log present — got: $out_nodata"
fi
if printf '%s' "$out_nodata" | grep -q "2026-08-23-omniroute-assessment.md"; then
  ok "fallback cites the doc the historical 86%/14% figure actually came from"
else
  bad "fallback should cite the assessment doc for its historical figure — got: $out_nodata"
fi

REPO_DATA="$WORK/repo-data"; mkdir -p "$REPO_DATA/.planning"
{
  echo '{"ts":"2026-08-24T00:00:00Z","metric":"task","schema":1,"task_type":"code","model":"sonnet","effort":"default","outcome":"pass","final":"pass","retries":0,"escalated_to":null,"wall_secs":10,"source":"cli","session":"t1"}'
  echo '{"ts":"2026-08-24T00:01:00Z","metric":"task","schema":1,"task_type":"code","model":"sonnet","effort":"default","outcome":"pass","final":"pass","retries":0,"escalated_to":null,"wall_secs":10,"source":"cli","session":"t1"}'
  echo '{"ts":"2026-08-24T00:02:00Z","metric":"task","schema":1,"task_type":"code","model":"sonnet","effort":"default","outcome":"pass","final":"pass","retries":0,"escalated_to":null,"wall_secs":10,"source":"cli","session":"t1"}'
  echo '{"ts":"2026-08-24T00:03:00Z","metric":"task","schema":1,"task_type":"review","model":"opus","effort":"default","outcome":"pass","final":"pass","retries":0,"escalated_to":null,"wall_secs":10,"source":"cli","session":"t1"}'
  echo '{"ts":"2026-08-24T00:04:00Z","metric":"parallelism","schema":1,"agents":3}'
} > "$REPO_DATA/.planning/metrics.jsonl"
out_data="$(cd "$REPO_DATA" && "$CLI" check --text "$MSG_6PM")"
if printf '%s' "$out_data" | grep -q "already runs 75% of 4 recorded task records on sonnet"; then
  ok "metrics.jsonl present -> LIVE 75% of 4 task records (the 5th, non-task parallelism record correctly excluded)"
else
  bad "expected a live 75%-of-4 computation — got: $out_data"
fi

echo "== section 8: status reads the SAME record heimdall-quota-resume writes (no second detector) =="

REPO_QS="$WORK/repo-quota-resume"
mkdir -p "$REPO_QS"
git -C "$REPO_QS" init -q -b main >/dev/null 2>&1
git -C "$REPO_QS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

st_none="$("$CLI" status --repo "$REPO_QS")"; rc_none=$?
if [ "$rc_none" = 0 ] && [ -z "$st_none" ]; then
  ok "status: silent when no QUOTA-STOP.json record exists yet"
else
  bad "status should be silent with no record — rc=$rc_none out=$st_none"
fi

QRESUME="$ROOT/bin/heimdall-quota-resume"
if [ -x "$QRESUME" ]; then
  HEIMDALL_HOME="$WORK/.heimdall-home-qr" HEIMDALL_QUOTA_NOW_EPOCH="$NOW_FIXED" \
    "$QRESUME" record --repo "$REPO_QS" --text "$MSG_6PM" >/dev/null 2>&1

  st_waiting="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_FIXED" "$CLI" status --repo "$REPO_QS")"; rc_waiting=$?
  if [ "$rc_waiting" = 0 ] && printf '%s' "$st_waiting" | grep -q "QUOTA EXHAUSTED"; then
    ok "status fires the SAME advisory once heimdall-quota-resume has recorded a real stop"
  else
    bad "status should fire off a real QUOTA-STOP.json record — rc=$rc_waiting out=$st_waiting"
  fi

  HEIMDALL_HOME="$WORK/.heimdall-home-qr" "$QRESUME" clear --repo "$REPO_QS" >/dev/null 2>&1
  st_cleared="$("$CLI" status --repo "$REPO_QS")"; rc_cleared=$?
  if [ "$rc_cleared" = 0 ] && [ -z "$st_cleared" ]; then
    ok "status: silent again once the record has been cleared"
  else
    bad "status should be silent after clear — rc=$rc_cleared out=$st_cleared"
  fi
else
  bad "bin/heimdall-quota-resume not found — cannot verify status shares its record (unexpected on this checkout)"
fi

echo "== section 9: the bin/heimdall dispatcher arm is wired and byte-identical =="

direct_out="$("$CLI" check --text "$MSG_6PM")"
routed_out="$("$HMD" quota-advisor check --text "$MSG_6PM")"
if [ "$direct_out" = "$routed_out" ] && [ -n "$routed_out" ]; then
  ok "hmd quota-advisor check == direct bin invocation (byte-identical, dispatcher arm wired)"
else
  bad "routed output differs from direct bin output (dispatcher arm missing or broken)"
fi

echo
echo "heimdall-quota-advisor: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
