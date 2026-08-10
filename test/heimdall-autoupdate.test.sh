#!/usr/bin/env bash
# heimdall-autoupdate.test.sh — the SessionStart auto-updater: opt-out, throttle, semver
# decide, status, and the non-blocking safety contract.
#
# NETWORK IS STUBBED. Every test injects the "latest" version via HEIMDALL_LATEST_OVERRIDE
# and uses HEIMDALL_AUTOUPDATE_DRYRUN=1 so the apply DECIDES but never detaches a real
# curl|bash — the suite NEVER hits GitHub and NEVER mutates any install. The would-apply /
# current / no-op decision is read back from the secret-free autoupdate.log.
#
# WHAT IT PROVES (each with a falsifier — a wrong build goes RED):
#   A. OPT-OUT honored first:
#      A1. HEIMDALL_NO_AUTOUPDATE=1 with latest>installed → NO apply (would-be upgrade suppressed).
#      A2. the opt-out FILE (${HOME}/.heimdall/no-autoupdate) → NO apply.
#      A3. FALSIFIER: same latest>installed WITHOUT opt-out → would-apply (proves A1/A2 gate it).
#   B. THROTTLE:
#      B1. a FRESH stamp (within interval) → check SKIPS (no apply even though newer).
#      B2. a STALE stamp (older than interval) → check RUNS (would-apply).
#      B3. --force ignores a fresh stamp → would-apply anyway.
#   C. SEMVER decide (stubbed latest):
#      C1. latest > installed → would-apply.
#      C2. latest == installed → no-op (no apply, "current").
#      C3. latest < installed → no-op (never downgrade).
#   D. STATUS (read-only — never applies):
#      D1. prints installed / latest / pending:yes when newer; no log apply written.
#      D2. pending:no when equal.
#   E. SAFETY:
#      E1. a check is FAST (time-bounded) and exits 0 even with the network forced
#          unreachable (no override, curl/git pointed at a black hole).
#      E2. an UNKNOWN subcommand exits non-zero (argument hygiene).
#
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin/heimdall-autoupdate"

[ -x "$BIN" ] || { echo "FATAL: $BIN missing/not executable" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# A throwaway HEIMDALL_HOME per case → stamp/log/opt-out file are isolated and swept.
mk_home() { mktemp -d -t "hmd-au.$(printf 'X%.0s' 1 2 3 4 5 6)"; }

# Installed version = whatever the repo's tag/manifest resolves to. Read it once so the
# tests pick latest values RELATIVE to it (no hardcoded version that rots on a bump).
INSTALLED="$("$BIN" status 2>/dev/null | sed -n 's/^installed:[[:space:]]*//p' | head -1)"
[ -n "$INSTALLED" ] || { echo "FATAL: could not resolve installed version via status" >&2; exit 2; }
# Derive a strictly-greater and strictly-lesser semver from the installed X.Y.Z.
IFS=. read -r _MA _MI _PA <<EOF
$INSTALLED
EOF
NEWER="${_MA}.${_MI}.$((_PA + 1))"
SAME="$INSTALLED"
if [ "$_PA" -gt 0 ]; then OLDER="${_MA}.${_MI}.$((_PA - 1))"; else OLDER="${_MA}.$(( _MI > 0 ? _MI - 1 : 0 )).0"; fi

echo "── heimdall-autoupdate (installed=$INSTALLED newer=$NEWER older=$OLDER) ──"

# Read the LAST log line from a home (empty if no log).
last_log() { tail -1 "$1/autoupdate.log" 2>/dev/null || true; }

# ── A. OPT-OUT honored first ────────────────────────────────────────────────────
H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_NO_AUTOUPDATE=1 HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "A1 HEIMDALL_NO_AUTOUPDATE=1 suppresses a would-be upgrade (exit 0, no apply)"
else
  bad "A1 env opt-out did not suppress apply (rc=$rc log='$(last_log "$H")')"
fi
rm -rf "$H"

H="$(mk_home)"; mkdir -p "$H"; : > "$H/no-autoupdate"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_AUTOUPDATE_DRYRUN=1 \
  "$BIN" check >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "A2 opt-out FILE suppresses a would-be upgrade"
else
  bad "A2 opt-out file did not suppress apply (rc=$rc log='$(last_log "$H")')"
fi
rm -rf "$H"

# A3 falsifier: SAME scenario, no opt-out → MUST would-apply.
H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_AUTOUPDATE_DRYRUN=1 \
  "$BIN" check >/dev/null 2>&1
if grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "A3 FALSIFIER: without opt-out the same upgrade WOULD apply (gate is real)"
else
  bad "A3 expected would-apply without opt-out (log='$(last_log "$H")')"
fi
rm -rf "$H"

# ── B. THROTTLE ─────────────────────────────────────────────────────────────────
# B1 fresh stamp → skip. Interval huge so the just-touched stamp is "fresh".
H="$(mk_home)"; mkdir -p "$H"; : > "$H/.last-update-check"
HEIMDALL_HOME="$H" HEIMDALL_UPDATE_INTERVAL=86400 HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
if ! grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "B1 fresh stamp throttles the check (no apply)"
else
  bad "B1 fresh stamp should have skipped (log='$(last_log "$H")')"
fi
rm -rf "$H"

# B2 stale stamp → run. Interval=1s, stamp aged 2h back via touch -t.
H="$(mk_home)"; mkdir -p "$H"; : > "$H/.last-update-check"
# Backdate the stamp well beyond the 1s interval (portable: touch with an old time).
touch -t 202001010000 "$H/.last-update-check" 2>/dev/null \
  || touch -d '2020-01-01' "$H/.last-update-check" 2>/dev/null || true
HEIMDALL_HOME="$H" HEIMDALL_UPDATE_INTERVAL=1 HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
if grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "B2 stale stamp lets the check run (would-apply)"
else
  bad "B2 stale stamp should have run (log='$(last_log "$H")')"
fi
rm -rf "$H"

# B3 --force ignores a fresh stamp → would-apply anyway.
H="$(mk_home)"; mkdir -p "$H"; : > "$H/.last-update-check"
HEIMDALL_HOME="$H" HEIMDALL_UPDATE_INTERVAL=86400 HEIMDALL_LATEST_OVERRIDE="$NEWER" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" --force >/dev/null 2>&1
if grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "B3 --force bypasses a fresh throttle stamp (would-apply)"
else
  bad "B3 --force should ignore the throttle (log='$(last_log "$H")')"
fi
rm -rf "$H"

# ── C. SEMVER decide ──────────────────────────────────────────────────────────────
H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" HEIMDALL_AUTOUPDATE_DRYRUN=1 \
  "$BIN" check >/dev/null 2>&1
grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null \
  && ok "C1 latest>installed → would-apply" \
  || bad "C1 expected would-apply (log='$(last_log "$H")')"
rm -rf "$H"

H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$SAME" HEIMDALL_AUTOUPDATE_DRYRUN=1 \
  "$BIN" check >/dev/null 2>&1
if ! grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null \
   && grep -q 'current' "$H/autoupdate.log" 2>/dev/null; then
  ok "C2 latest==installed → no-op (current, never reinstall)"
else
  bad "C2 equal version should be a no-op (log='$(last_log "$H")')"
fi
rm -rf "$H"

H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$OLDER" HEIMDALL_AUTOUPDATE_DRYRUN=1 \
  "$BIN" check >/dev/null 2>&1
if ! grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "C3 latest<installed → no-op (never downgrade)"
else
  bad "C3 should NOT apply a downgrade (log='$(last_log "$H")')"
fi
rm -rf "$H"

# ── D. STATUS (read-only) ─────────────────────────────────────────────────────────
H="$(mk_home)"
OUT="$(HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$NEWER" "$BIN" status 2>/dev/null)"
if grep -q "installed: $INSTALLED" <<<"$OUT" \
   && grep -q "latest:    $NEWER" <<<"$OUT" \
   && grep -q 'pending:   yes' <<<"$OUT" \
   && [ ! -f "$H/autoupdate.log" ]; then
  ok "D1 status prints installed/latest/pending:yes and applies NOTHING"
else
  bad "D1 status output wrong or it wrote a log: $OUT"
fi
rm -rf "$H"

H="$(mk_home)"
OUT="$(HEIMDALL_HOME="$H" HEIMDALL_LATEST_OVERRIDE="$SAME" "$BIN" status 2>/dev/null)"
grep -q 'pending:   no' <<<"$OUT" \
  && ok "D2 status pending:no when latest==installed" \
  || bad "D2 expected pending:no: $OUT"
rm -rf "$H"

# ── E. SAFETY ─────────────────────────────────────────────────────────────────────
# E1 network forced unreachable: NO override, point curl + git at a black hole, cap time.
# A check must still exit 0 and finish well under the bound. We measure wall time.
H="$(mk_home)"
t0="$(date +%s)"
# A non-resolving host + a tiny git timeout makes the network path fail fast; the script's
# own --max-time 5 caps curl. We assert the whole run is comfortably bounded (< 30s).
HEIMDALL_HOME="$H" \
  http_proxy="http://127.0.0.1:1" https_proxy="http://127.0.0.1:1" \
  GIT_TERMINAL_PROMPT=0 \
  "$BIN" check >/dev/null 2>&1
rc=$?
t1="$(date +%s)"
elapsed=$(( t1 - t0 ))
if [ "$rc" -eq 0 ] && [ "$elapsed" -lt 30 ]; then
  ok "E1 offline check exits 0 and is time-bounded (${elapsed}s < 30s)"
else
  bad "E1 offline check rc=$rc elapsed=${elapsed}s (must be 0 and bounded)"
fi
rm -rf "$H"

# E2 unknown subcommand → non-zero (argument hygiene; the hook calls a known verb).
H="$(mk_home)"
HEIMDALL_HOME="$H" "$BIN" frobnicate >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && ok "E2 unknown subcommand exits non-zero (rc=$rc)" \
  || bad "E2 unknown subcommand should be non-zero (rc=$rc)"
rm -rf "$H"

# ── F. UPDATE-CHECK CACHE: the background check WRITES the signal the statusline reads ─
# The launcher's own cache writer (bin/heimdall) is gated on an interactive TTY; the
# SessionStart background check is the ONLY updater that runs headless. It MUST publish
# $HMD_HOME/update-check.json {checked_epoch,installed,latest} so a stale install SURFACES
# (akshat/Madhavan had NO visible signal). Schema + v-prefix match the launcher's writer.
# Simulate a much-older install so the assertion is exact, not relative.
H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_INSTALLED_OVERRIDE="2.0.5" HEIMDALL_LATEST_OVERRIDE="2.0.20" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
CACHE="$H/update-check.json"
if [ -f "$CACHE" ] \
   && grep -q '"installed":"v2.0.5"' "$CACHE" 2>/dev/null \
   && grep -q '"latest":"v2.0.20"' "$CACHE" 2>/dev/null \
   && grep -Eq '"checked_epoch":[0-9]+' "$CACHE" 2>/dev/null; then
  ok "F background check publishes update-check.json (installed=v2.0.5 latest=v2.0.20) for the statusline"
else
  bad "F check did not publish the update-check cache (cache='$(cat "$CACHE" 2>/dev/null)')"
fi
rm -rf "$H"

# F2: status is READ-ONLY — it must NOT write the cache (only check/--force publish).
H="$(mk_home)"
HEIMDALL_HOME="$H" HEIMDALL_INSTALLED_OVERRIDE="2.0.5" HEIMDALL_LATEST_OVERRIDE="2.0.20" \
  "$BIN" status >/dev/null 2>&1
if [ ! -f "$H/update-check.json" ]; then
  ok "F2 status stays read-only (no cache write)"
else
  bad "F2 status wrote the cache (should be read-only)"
fi
rm -rf "$H"

# ── G. DAILY-WINDOW GUARANTEE: with the REAL default interval, a >1-day-old stamp re-checks ─
# Proves users cannot silently exceed ~1 day stale. Uses the DEFAULT interval (no override):
# a stamp aged ~25h must let the check run (would-apply the climb). A just-touched stamp
# throttling is already proven by B1; this pins the *default window* is daily, not a test value.
H="$(mk_home)"; mkdir -p "$H"; : > "$H/.last-update-check"
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null || echo 202001010000)" \
  "$H/.last-update-check" 2>/dev/null || touch -t 202001010000 "$H/.last-update-check" 2>/dev/null || true
HEIMDALL_HOME="$H" HEIMDALL_INSTALLED_OVERRIDE="2.0.5" HEIMDALL_LATEST_OVERRIDE="2.0.20" \
  HEIMDALL_AUTOUPDATE_DRYRUN=1 "$BIN" check >/dev/null 2>&1
if grep -q 'would-apply' "$H/autoupdate.log" 2>/dev/null; then
  ok "G daily-window: a >24h-old stamp re-checks under the DEFAULT interval (no silent >1-day staleness)"
else
  bad "G default-interval stamp aged 25h should re-check (log='$(last_log "$H")')"
fi
rm -rf "$H"

# ── tally ──────────────────────────────────────────────────────────────────────
echo ""
echo "── heimdall-autoupdate: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
