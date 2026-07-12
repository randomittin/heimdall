#!/usr/bin/env bash
#
# session-farewell.test.sh — acceptance for the viral session-END "watchman
# sleeps" farewell (sentinels/hmd-farewell.sh) and its WIRING into the SessionEnd
# hook. The session-START wake already exists (print_banner + narrate_launch_wakeup);
# this is its missing counterpart — a memorable, screenshottable close.
#
# Guarantees proved:
#   1. PASTE-CLEAN NON-TTY  — piped stdout emits ZERO ANSI escapes + exit 0, so it
#      pastes into GitHub/HN/Slack as text.
#   2. BRAND CLOSE          — carries the "watchman sleeps" moment + the
#      "shipped proven" tagline (the unproven -> proven brand voice).
#   3. REAL STATS, NEVER FAKED — with a session edit ledger present it reports the
#      REAL count; with NO ledger it reports NO fabricated number (tagline only).
#   4. FAST                 — the farewell print completes well under 1s (it is on
#      the session-exit path; the heavy reel/summary stays backgrounded).
#   5. WIRED @ SessionEnd   — the ACTUAL SessionEnd hook command invokes
#      hmd-farewell.sh (extracted from hooks/hooks.json).
#   6. SYNTAX               — bash -n clean.
#
# Usage:  test/session-farewell.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
FAREWELL="$REPO/sentinels/hmd-farewell.sh"
HOOKS="$REPO/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "session-farewell harness  repo=$REPO"
echo "--------------------------------------------------------------------"

# ── 6. SYNTAX ──
if bash -n "$FAREWELL" 2>/dev/null; then ok "hmd-farewell.sh is bash -n clean"; else bad "hmd-farewell.sh has a syntax error"; fi

# Run the farewell PIPED (non-TTY) under a clean session ledger.
OUT="$(CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1)"; RC=$?

# ── 1. PASTE-CLEAN + exit 0 ──
[ "$RC" -eq 0 ] && ok "farewell (piped) exits 0" || bad "farewell exit $RC (want 0)"
ESC="$(printf '%s' "$OUT" | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')"
[ "$ESC" -eq 0 ] && ok "farewell (piped) emits ZERO ANSI escapes (paste-clean)" || bad "farewell piped leaked $ESC ANSI bytes"

# ── 2. BRAND CLOSE ──
printf '%s' "$OUT" | grep -qi 'watchman sleeps' && ok "carries the 'watchman sleeps' moment" || bad "missing 'watchman sleeps'"
printf '%s' "$OUT" | grep -qi 'shipped proven' && ok "carries the 'shipped proven' tagline" || bad "missing 'shipped proven' tagline"
printf '%s' "$OUT" | grep -q 'HEIMDALL' && ok "carries the HEIMDALL wordmark" || bad "missing HEIMDALL wordmark"

# ── 3. REAL STATS, NEVER FAKED ──
# COLD-LEDGER ISOLATION (fixes a cold/warm flake): edit-tracker AND
# parallelism-tracker both key their state by $TMPDIR + $CLAUDE_SESSION_ID, so the
# AMBIENT session in which this suite runs can legitimately carry real edits/agents.
# A truthful stat from a warm tracker is NOT a fabrication — asserting "zero digits"
# against $OUT therefore raced (green on a cold ledger, red once the ambient trackers
# had seeded any agent/edit). Run the "no ledger" close in a PRISTINE sandbox (its own
# TMPDIR/HEIMDALL_HOME/HOME + a fresh session id) so the ledger is provably empty; then
# every stat is >=0 and DROPPED, so no number is fabricated into the receipt (mirrors
# the farewell's own zero-stats drop). Reproduce the old red with a warm ambient run.
COLD_TMP="$(mktemp -d 2>/dev/null || echo /tmp/farewell-cold-$$)"
mkdir -p "$COLD_TMP/tmp" "$COLD_TMP/hmd" "$COLD_TMP/home" 2>/dev/null || true
OUT_COLD="$(TMPDIR="$COLD_TMP/tmp" HEIMDALL_HOME="$COLD_TMP/hmd" HOME="$COLD_TMP/home" \
  CLAUDE_SESSION_ID="farewell-cold-$$" CLAUDE_PLUGIN_ROOT="$REPO" \
  bash "$FAREWELL" </dev/null 2>&1)"
rm -rf "$COLD_TMP" 2>/dev/null || true
if printf '%s' "$OUT_COLD" | grep -qE '[0-9]+ (file|agent)'; then
  bad "farewell invented a stat with a cold (empty) session ledger"
else
  ok "cold ledger -> no fabricated stat (>=0 stats dropped, tagline-only close)"
fi
# Seed a REAL edit ledger (3 files) and confirm it is reported truthfully.
ET="$REPO/bin/edit-tracker"
if [ -x "$ET" ]; then
  SID="farewell-test-$$"
  CLAUDE_SESSION_ID="$SID" "$ET" clear >/dev/null 2>&1 || true
  CLAUDE_SESSION_ID="$SID" "$ET" log Write /tmp/f1.txt >/dev/null 2>&1 || true
  CLAUDE_SESSION_ID="$SID" "$ET" log Edit  /tmp/f2.txt >/dev/null 2>&1 || true
  CLAUDE_SESSION_ID="$SID" "$ET" log Write /tmp/f3.txt >/dev/null 2>&1 || true
  OUT2="$(CLAUDE_SESSION_ID="$SID" CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1)"
  CLAUDE_SESSION_ID="$SID" "$ET" clear >/dev/null 2>&1 || true
  printf '%s' "$OUT2" | grep -qE '3 files edited' \
    && ok "reports the REAL session edit count (3 files edited)" \
    || bad "did not report the real edit count from the session ledger"
else
  ok "edit-tracker absent — real-stat path skipped (non-fatal)"
fi

# ── 4. FAST ──
S=$(date +%s.%N 2>/dev/null || echo 0)
CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null >/dev/null 2>&1
E=$(date +%s.%N 2>/dev/null || echo 0)
DUR="$(awk -v a="$S" -v b="$E" 'BEGIN{printf "%.3f", b-a}')"
awk -v d="$DUR" 'BEGIN{exit !(d < 1.0)}' \
  && ok "farewell completes fast (${DUR}s < 1.0s)" \
  || bad "farewell too slow (${DUR}s) — must stay off the blocking budget"

# ── 5. WIRED @ SessionEnd ──
if grep -q 'hmd-farewell' "$HOOKS"; then
  CMD="$(jq -r '[.hooks.SessionEnd[].hooks[].command | select(test("hmd-farewell"))][0]' "$HOOKS" 2>/dev/null)"
  [ -n "$CMD" ] && [ "$CMD" != "null" ] \
    && ok "SessionEnd hook wires the farewell (hmd-farewell.sh)" \
    || bad "hmd-farewell referenced but not in a SessionEnd command"
else
  bad "SessionEnd hook does NOT invoke hmd-farewell.sh"
fi

# ── 7. FIX 1: ONE-SHOT SIGIL-UNLOCK REVEAL ──
# bin/heimdall arms $HEIMDALL_HOME/.unlock-pending on the 3-run crossing; the NEXT
# close reveals it ONCE and drops .unlock-shown so it never repeats.
U_HOME="$(mktemp -d 2>/dev/null || echo /tmp/farewell-unlock-$$)"
mkdir -p "$U_HOME" 2>/dev/null || true
: > "$U_HOME/.unlock-pending"
U1="$(HEIMDALL_HOME="$U_HOME" CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1)"
U2="$(HEIMDALL_HOME="$U_HOME" CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1)"
printf '%s' "$U1" | grep -qi 'sigil customization unlocked' \
  && ok "unlock reveal fires once when armed" \
  || bad "unlock reveal did not fire on the armed close"
if printf '%s' "$U2" | grep -qi 'sigil customization unlocked'; then
  bad "unlock reveal repeated (must be one-shot)"
else
  ok "unlock reveal is one-shot (silent on the next close)"
fi
[ -f "$U_HOME/.unlock-shown" ] \
  && ok "unlock reveal drops a .unlock-shown marker" \
  || bad "no .unlock-shown marker written"
rm -rf "$U_HOME" 2>/dev/null || true

# ── 8. FIX 3: SHARE CTA — real artifact path, never fabricated ──
# With a FRESH reel artifact present, the close points at it; with none, it stays silent.
A_DIR="$(mktemp -d 2>/dev/null || echo /tmp/farewell-share-$$)"
mkdir -p "$A_DIR/.planning/reels" 2>/dev/null || true
: > "$A_DIR/.planning/reels/run-share.txt"
OUT_SHARE="$( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1 )"
printf '%s' "$OUT_SHARE" | grep -q 'your run card' \
  && printf '%s' "$OUT_SHARE" | grep -q '.planning/reels/run-share.txt' \
  && ok "share CTA points at the REAL fresh run-card artifact" \
  || bad "share CTA missing or wrong path for a fresh artifact"
# Stale artifact (mtime well outside the freshness window) => NOT surfaced.
touch -t 202001010000.00 "$A_DIR/.planning/reels/run-share.txt" 2>/dev/null || true
OUT_STALE="$( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1 )"
if printf '%s' "$OUT_STALE" | grep -q 'your run card'; then
  bad "share CTA surfaced a stale artifact (outside freshness window)"
else
  ok "share CTA drops stale artifacts (freshness-gated)"
fi
rm -rf "$A_DIR" 2>/dev/null || true
# No reels dir at all => print NOTHING (never a fabricated path).
N_DIR="$(mktemp -d 2>/dev/null || echo /tmp/farewell-noshare-$$)"
OUT_NOART="$( cd "$N_DIR" && CLAUDE_PLUGIN_ROOT="$REPO" bash "$FAREWELL" </dev/null 2>&1 )"
if printf '%s' "$OUT_NOART" | grep -q 'your run card'; then
  bad "share CTA fabricated a run-card path with no artifact present"
else
  ok "share CTA silent when no artifact exists (no fabricated path)"
fi
rm -rf "$N_DIR" 2>/dev/null || true

echo ""
echo "session-farewell.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
