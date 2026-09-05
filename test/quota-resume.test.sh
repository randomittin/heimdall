#!/usr/bin/env bash
# test/quota-resume.test.sh — hermetic tests for bin/lib/quota_stop.py and
# bin/heimdall-quota-resume: classifying a QUOTA-EXHAUSTION agent termination
# vs. a genuine failure, resolving the wall-clock reset to an absolute epoch,
# recording lossless git state, and the silent-unless-ready resume-hint.
#
# Every falsifier in this file runs the REAL code path with one parameter
# changed (never a mocked/neutered copy) and asserts the WRONG behavior
# appears — proving the safety mechanism is load-bearing, not decorative.
# Network/control-plane access: none. HOME/HEIMDALL_HOME are always isolated
# under a mktemp -d workdir.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PY_BIN="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
CLI="$ROOT/bin/heimdall-quota-resume"
LIB="$ROOT/bin/lib/quota_stop.py"
HOOKS="$ROOT/hooks/hooks.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
[ -n "$PY_BIN" ] || { echo "FATAL: python3 required"; exit 1; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: $CLI missing or not executable"; exit 1; }
[ -f "$HOOKS" ] || { echo "FATAL: $HOOKS missing"; exit 1; }

WORK="$(mktemp -d -t "quota-resume-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Ground truth epoch for a wall-clock local time, computed directly via
# datetime+zoneinfo (NOT via quota_stop.py's resolve_reset_epoch) — an
# independent check of the arithmetic under test, not a self-check.
epoch_for() { # <year> <month> <day> <hour24> <minute> <tz>
  "$PY_BIN" -c "
from zoneinfo import ZoneInfo
from datetime import datetime
dt = datetime($1, $2, $3, $4, $5, 0, tzinfo=ZoneInfo('$6'))
print(int(dt.timestamp()))
"
}

REAL_MSG_1="Agent terminated early due to an API error: You've hit your session limit · resets 12:40pm (Asia/Calcutta)"
REAL_MSG_2="Agent terminated early due to an API error: You've hit your usage limit · resets 5:40pm (Asia/Calcutta)"

echo "== section 1: classify() =="

out="$(printf '%s' "$REAL_MSG_1" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "quota" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_local')" = "12:40pm" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_tz')" = "Asia/Calcutta" ] \
  && ok "real msg 1 (session limit) classifies quota, exit 0" \
  || bad "real msg 1 classify — got rc=$rc out=$out"

out="$(printf '%s' "$REAL_MSG_2" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "quota" ] \
  && ok "real msg 2 (usage limit) classifies quota, exit 0" \
  || bad "real msg 2 classify — got rc=$rc out=$out"

# DEFECT (2026-09-06): the REAL text Claude Code emits omits minutes entirely
# when the reset lands on the hour — "resets 2pm", never "resets 2:00pm".
# REAL_MSG_3 is the VERBATIM production string; this must never again pass on
# a fabricated/rounded shape. REAL_MSG_4 is the same real shape WITH minutes,
# proving the fix adds a case rather than replacing one (no regression).
REAL_MSG_3="You've hit your session limit · resets 2pm (Asia/Calcutta)"
REAL_MSG_4="You've hit your session limit · resets 2:30pm (Asia/Calcutta)"

out="$(printf '%s' "$REAL_MSG_3" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "quota" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_local')" = "2pm" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_tz')" = "Asia/Calcutta" ] \
  && ok "REAL PRODUCTION STRING real msg 3 (hour-only reset, no :MM) classifies quota, exit 0" \
  || bad "real msg 3 (hour-only) classify — got rc=$rc out=$out"

out="$(printf '%s' "$REAL_MSG_4" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "quota" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_local')" = "2:30pm" ] \
  && ok "real msg 4 (minutes-present reset) still classifies quota, exit 0 (no regression)" \
  || bad "real msg 4 (minutes-present) classify — got rc=$rc out=$out"

# FALSIFIER: anchor phrase present, reset clause absent — must NOT classify
# quota. Proves the reset-clause requirement is load-bearing, not vestigial.
out="$(printf '%s' "You've hit your session limit for this billing period." | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "unknown" ] \
  && [ "$(printf '%s' "$out" | jq -r '.anchor_matched')" = "true" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_clause_matched')" = "false" ] \
  && ok "FALSIFIER: anchor-only (no reset clause) -> unknown, exit 1 (reset-clause requirement is load-bearing)" \
  || bad "FALSIFIER anchor-only — got rc=$rc out=$out"

# FALSIFIER: reset clause present, anchor phrase absent — must NOT classify
# quota. Proves the anchor requirement is load-bearing, not vestigial.
out="$(printf '%s' "Nightly job finished; next run resets 5:40pm (Asia/Calcutta)." | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "unknown" ] \
  && [ "$(printf '%s' "$out" | jq -r '.anchor_matched')" = "false" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_clause_matched')" = "true" ] \
  && ok "FALSIFIER: reset-clause-only (no anchor) -> unknown, exit 1 (anchor requirement is load-bearing)" \
  || bad "FALSIFIER reset-clause-only — got rc=$rc out=$out"

# False-positive guard: a generic, unrelated HTTP rate-limit message must
# never be mistaken for a Claude quota stop.
out="$(printf '%s' "HTTP 429 Too Many Requests: rate limit exceeded, retry after 30 seconds" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "unknown" ] \
  && ok "unrelated generic rate-limit text classifies unknown (no false positive)" \
  || bad "generic rate-limit text — got rc=$rc out=$out"

out="$(printf '%s' "" | "$PY_BIN" "$LIB" classify)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "unknown" ] \
  && ok "empty text classifies unknown, exit 1, no crash" \
  || bad "empty text classify — got rc=$rc out=$out"

echo "== section 2: resolve_reset_epoch() =="

# 2a: target later today -> resolves today, no roll.
NOW_2A="$(epoch_for 2026 1 15 17 0 Asia/Calcutta)"
EXPECT_2A="$(epoch_for 2026 1 15 17 40 Asia/Calcutta)"
out="$("$PY_BIN" "$LIB" resolve --hour 5 --minute 40 --ampm pm --tz Asia/Calcutta --now "$NOW_2A")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.reset_epoch')" = "$EXPECT_2A" ] \
  && [ "$(printf '%s' "$out" | jq -r '.rolled_to_tomorrow')" = "false" ] \
  && ok "2a: target later today resolves today, rolled=false" \
  || bad "2a — expected epoch=$EXPECT_2A got out=$out"

# 2b: target already passed today (well beyond default skew) -> rolls to tomorrow.
NOW_2B="$(epoch_for 2026 1 15 18 0 Asia/Calcutta)"
EXPECT_2B="$(epoch_for 2026 1 16 17 40 Asia/Calcutta)"
out="$("$PY_BIN" "$LIB" resolve --hour 5 --minute 40 --ampm pm --tz Asia/Calcutta --now "$NOW_2B")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.reset_epoch')" = "$EXPECT_2B" ] \
  && [ "$(printf '%s' "$out" | jq -r '.rolled_to_tomorrow')" = "true" ] \
  && ok "2b: target already passed today rolls to tomorrow" \
  || bad "2b — expected epoch=$EXPECT_2B got out=$out"

# 2c FALSIFIER: now = target + 1 second. skew=0 (naive) wrongly rolls a whole
# day out on 1s of clock noise; skew=120 (real default) correctly does not.
# Same real `resolve` subcommand, same input, only --skew differs — proves
# the tolerance parameter is load-bearing, not decorative.
TARGET_2C="$(epoch_for 2026 1 15 17 40 Asia/Calcutta)"
NOW_2C=$((TARGET_2C + 1))
out_naive="$("$PY_BIN" "$LIB" resolve --hour 5 --minute 40 --ampm pm --tz Asia/Calcutta --now "$NOW_2C" --skew 0)"
out_real="$("$PY_BIN" "$LIB" resolve --hour 5 --minute 40 --ampm pm --tz Asia/Calcutta --now "$NOW_2C" --skew 120)"
[ "$(printf '%s' "$out_naive" | jq -r '.rolled_to_tomorrow')" = "true" ] \
  && [ "$(printf '%s' "$out_real" | jq -r '.rolled_to_tomorrow')" = "false" ] \
  && ok "FALSIFIER: skew=0 wrongly rolls on 1s noise; skew=120 (default) does not — tolerance is load-bearing" \
  || bad "FALSIFIER skew — naive=$out_naive real=$out_real"

# 2d: unknown timezone fails closed, non-empty error, never guesses.
out="$("$PY_BIN" "$LIB" resolve --hour 5 --minute 40 --ampm pm --tz Not/ARealZone --now "$NOW_2A")"; rc=$?
err="$(printf '%s' "$out" | jq -r '.error')"
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] && [ -n "$err" ] && [ "$err" != "null" ] \
  && ok "2d: unknown timezone fails closed with a non-empty error" \
  || bad "2d — got rc=$rc out=$out"

# 2e: out-of-range hour (13 on a 12-hour clock) fails closed — trust-boundary
# validation, not silently reinterpreted via modulo into a different hour.
out="$("$PY_BIN" "$LIB" resolve --hour 13 --minute 40 --ampm pm --tz Asia/Calcutta --now "$NOW_2A")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] \
  && ok "2e: out-of-range hour (13) fails closed (trust-boundary validation)" \
  || bad "2e — got rc=$rc out=$out"

# 2f: DST correctness. America/New_York springs forward 2025-03-09 02:00->03:00.
# now=01:00 EST (before transition, UTC-5); target=04:00 same calendar day,
# which falls AFTER the transition (EDT, UTC-4). If the code used a fixed
# offset for the whole day instead of re-deriving it from the target's own
# date, this would land an hour off. epoch_for() constructs the target
# datetime directly (independent of resolve_reset_epoch's replace()+roll
# logic) so this is a real cross-check, not the code checking itself.
NOW_2F="$(epoch_for 2025 3 9 1 0 America/New_York)"
EXPECT_2F="$(epoch_for 2025 3 9 4 0 America/New_York)"
out="$("$PY_BIN" "$LIB" resolve --hour 4 --minute 0 --ampm am --tz America/New_York --now "$NOW_2F")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.reset_epoch')" = "$EXPECT_2F" ] \
  && [ "$(printf '%s' "$out" | jq -r '.rolled_to_tomorrow')" = "false" ] \
  && ok "2f: DST spring-forward transition resolves to the correct UTC instant" \
  || bad "2f — expected epoch=$EXPECT_2F got out=$out"

echo "== section 3: detect() pipeline =="

out="$(printf '%s' "$REAL_MSG_1" | "$PY_BIN" "$LIB" detect --now "$NOW_2A")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "quota" ] \
  && [ "$(printf '%s' "$out" | jq -r '.resolved')" = "true" ] \
  && [ "$(printf '%s' "$out" | jq -r '.reset_epoch')" != "null" ] \
  && ok "detect(): quota text + frozen now resolves in one call" \
  || bad "detect quota — got rc=$rc out=$out"

out="$(printf '%s' "totally unrelated text" | "$PY_BIN" "$LIB" detect --now "$NOW_2A")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r '.class')" = "unknown" ] \
  && [ "$(printf '%s' "$out" | jq -r '.resolved')" = "false" ] \
  && ok "detect(): unrelated text classifies unknown, no resolution attempted" \
  || bad "detect unrelated — got rc=$rc out=$out"

echo "== section 4: record =="

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" checkout -q -b work
printf 'a\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "work commit"
printf 'b\n' > "$REPO/b.txt"  # left uncommitted

HH1="$WORK/.heimdall-home-1"
rec_out="$(HEIMDALL_HOME="$HH1" HEIMDALL_QUOTA_NOW_EPOCH="$NOW_2A" "$CLI" record --repo "$REPO" --text "$REAL_MSG_1")"; rc=$?
state1="$REPO/.planning/QUOTA-STOP.json"
[ "$rc" = 0 ] && [ -f "$state1" ] \
  && [ "$(jq -r '.branch' "$state1")" = "work" ] \
  && [ "$(jq -r '.uncommitted_count' "$state1")" = "1" ] \
  && [ "$(jq -r '.commits_ahead_of_main' "$state1")" = "1" ] \
  && [ "$(jq -r '.reset_tz' "$state1")" = "Asia/Calcutta" ] \
  && [ "$(jq -r '.status' "$state1")" = "waiting" ] \
  && [ -s "$HH1/quota-stop.ndjson" ] \
  && ok "record: quota text captures branch/uncommitted/ahead-of-main + audit log" \
  || bad "record quota text — rc=$rc state=$(cat "$state1" 2>/dev/null) hh=$(ls "$HH1" 2>/dev/null)"

# Critical negative-space test: record REFUSES non-quota text and writes
# NOTHING. This is what eliminates the infinite-retry risk on a genuine
# failure — the absence of a file is the safety property, not a message.
REPO2="$WORK/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main >/dev/null 2>&1
git -C "$REPO2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
rec_out2="$(HEIMDALL_HOME="$WORK/.heimdall-home-2" "$CLI" record --repo "$REPO2" --text "some unrelated tool crashed with a stack trace" 2>&1)"; rc2=$?
state2="$REPO2/.planning/QUOTA-STOP.json"
[ "$rc2" != 0 ] && [ ! -f "$state2" ] \
  && ok "record REFUSES non-quota text: nonzero exit AND no QUOTA-STOP.json written" \
  || bad "record non-quota text should refuse — rc=$rc2 state_exists=$([ -f "$state2" ] && echo yes || echo no) out=$rec_out2"

# record on quota text with a syntactically valid but non-existent timezone:
# classifies quota (both signals present) but resolution fails — state IS
# written (this is a genuine quota stop, just an unresolvable one) with
# resolved=false, and record still exits 0 (there is a real record to act on,
# just not an automatically-computed ready time).
REPO3="$WORK/repo3"
mkdir -p "$REPO3"
git -C "$REPO3" init -q -b main >/dev/null 2>&1
git -C "$REPO3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
BADTZ_MSG="Agent terminated early due to an API error: You've hit your session limit · resets 5:40pm (Not/ARealZone)"
rec_out3="$(HEIMDALL_HOME="$WORK/.heimdall-home-3" "$CLI" record --repo "$REPO3" --text "$BADTZ_MSG" 2>&1)"; rc3=$?
state3="$REPO3/.planning/QUOTA-STOP.json"
[ "$rc3" = 0 ] && [ -f "$state3" ] \
  && [ "$(jq -r '.resolved' "$state3")" = "false" ] \
  && [ "$(jq -r '.status' "$state3")" = "waiting" ] \
  && [ "$(jq -r '.resolve_error' "$state3")" != "null" ] \
  && ok "record: quota+unresolvable-tz still writes a waiting record with resolved=false" \
  || bad "record unresolvable tz — rc=$rc3 state=$(cat "$state3" 2>/dev/null)"

echo "== section 5: status =="

# no record at all
REPO4="$WORK/repo4"
mkdir -p "$REPO4"
git -C "$REPO4" init -q -b main >/dev/null 2>&1
st_out="$("$CLI" status --repo "$REPO4")"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$st_out" | grep -qi "no quota stop" \
  && ok "status: no record -> informational message, exit 0" \
  || bad "status no-record — rc=$rc out=$st_out"

# WAITING: reuse repo1's record (frozen now == the moment of recording, well
# before the resolved reset instant).
st_wait="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_2A" "$CLI" status --repo "$REPO")"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$st_wait" | grep -qi "WAITING" \
  && ok "status: before reset time -> WAITING" \
  || bad "status waiting — rc=$rc out=$st_wait"

# READY: build a fresh record whose reset resolves later TODAY (repo5), then
# query status with now frozen just after that reset instant.
REPO5="$WORK/repo5"
mkdir -p "$REPO5"
git -C "$REPO5" init -q -b main >/dev/null 2>&1
git -C "$REPO5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HEIMDALL_HOME="$WORK/.heimdall-home-5" HEIMDALL_QUOTA_NOW_EPOCH="$NOW_2A" "$CLI" record --repo "$REPO5" --text "$REAL_MSG_1" >/dev/null 2>&1
RESET_EPOCH_5="$(jq -r '.reset_epoch' "$REPO5/.planning/QUOTA-STOP.json")"
NOW_AFTER_5=$((RESET_EPOCH_5 + 60))
st_ready="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_AFTER_5" "$CLI" status --repo "$REPO5")"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$st_ready" | grep -qi "READY" \
  && ok "status: at/after reset time -> READY" \
  || bad "status ready — rc=$rc out=$st_ready"

echo "== section 6: resume-hint (silent-unless-ready contract) =="

hint_waiting="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_2A" "$CLI" resume-hint --repo "$REPO")"
[ -z "$hint_waiting" ] \
  && ok "resume-hint: silent while WAITING (no nagging)" \
  || bad "resume-hint should be silent while waiting — got: $hint_waiting"

hint_none="$("$CLI" resume-hint --repo "$REPO4")"
[ -z "$hint_none" ] \
  && ok "resume-hint: silent when no record exists" \
  || bad "resume-hint should be silent with no record — got: $hint_none"

hint_ready="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_AFTER_5" "$CLI" resume-hint --repo "$REPO5")"
[ -n "$hint_ready" ] && printf '%s' "$hint_ready" | grep -qi "quota" \
  && ok "resume-hint: speaks up once READY, mentions quota" \
  || bad "resume-hint should speak up when ready — got: $hint_ready"

# The one deliberate exception: an unresolvable reset time is surfaced even
# though its status is technically still "waiting" forever — because silence
# would mean this record is never surfaced by any mechanism again.
hint_unresolved="$("$CLI" resume-hint --repo "$REPO3")"
[ -n "$hint_unresolved" ] && printf '%s' "$hint_unresolved" | grep -qi "manually" \
  && ok "resume-hint: the one exception — speaks up for an unresolvable reset time too" \
  || bad "resume-hint should surface unresolvable case — got: $hint_unresolved"

echo "== section 7: clear =="

cl_out="$("$CLI" clear --repo "$REPO5")"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.status' "$REPO5/.planning/QUOTA-STOP.json")" = "cleared" ] \
  && ok "clear: marks the record cleared" \
  || bad "clear — rc=$rc out=$cl_out"

st_after_clear="$("$CLI" status --repo "$REPO5")"
printf '%s' "$st_after_clear" | grep -qi "no active quota stop" \
  && ok "status after clear: reports no active quota stop" \
  || bad "status after clear — got: $st_after_clear"

hint_after_clear="$(HEIMDALL_QUOTA_NOW_EPOCH="$NOW_AFTER_5" "$CLI" resume-hint --repo "$REPO5")"
[ -z "$hint_after_clear" ] \
  && ok "resume-hint after clear: silent again" \
  || bad "resume-hint after clear should be silent — got: $hint_after_clear"

cl_noop="$("$CLI" clear --repo "$REPO4")"; rc=$?
[ "$rc" = 0 ] \
  && ok "clear on a repo with no record: safe exit-0 no-op" \
  || bad "clear no-op — rc=$rc out=$cl_noop"

echo "== section 8: hooks.json wiring =="

WIRED_CMD="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command? // empty | select(test("heimdall-quota-resume"))][0] // empty' "$HOOKS" 2>/dev/null)"
if [ -z "$WIRED_CMD" ]; then
  bad "hooks.json SessionStart wires heimdall-quota-resume (not found yet)"
else
  ok "hooks.json SessionStart wires heimdall-quota-resume"

  TMPPROJ="$WORK/wiretest-project"
  mkdir -p "$TMPPROJ"
  git -C "$TMPPROJ" init -q -b main >/dev/null 2>&1
  git -C "$TMPPROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  HH_WIRE="$WORK/.heimdall-home-wire"
  HEIMDALL_HOME="$HH_WIRE" HEIMDALL_QUOTA_NOW_EPOCH="$NOW_2A" \
    "$CLI" record --repo "$TMPPROJ" --text "$REAL_MSG_1" >/dev/null 2>&1
  WIRE_RESET_EPOCH="$(jq -r '.reset_epoch' "$TMPPROJ/.planning/QUOTA-STOP.json")"
  WIRE_NOW_AFTER=$((WIRE_RESET_EPOCH + 60))

  wire_out="$(CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$TMPPROJ" \
              HEIMDALL_HOME="$HH_WIRE" HEIMDALL_QUOTA_NOW_EPOCH="$WIRE_NOW_AFTER" \
              bash -c "$WIRED_CMD" 2>&1)"
  printf '%s' "$wire_out" | grep -qi "quota" \
    && ok "wired SessionStart command, executed verbatim, surfaces the ready hint" \
    || bad "wired command produced no quota hint — got: $wire_out"
fi

echo
echo "quota-resume.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
