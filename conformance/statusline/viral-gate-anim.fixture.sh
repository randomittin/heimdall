#!/usr/bin/env bash
# PARITY-ROW: statusline:viral-gate-anim — net-new inline gate animation
#   (sentinels/hmd-gate-anim.sh). No superx baseline; new viral surface. On a TTY
#   it animates the watchman (scanning pulse -> deny flash / pass sparkle); on a
#   non-TTY (CI, pipe) it MUST collapse to a single clean final frame so logs stay
#   readable.
# ASSERT: piped (non-TTY) pass/deny/scan each exit 0 and print exactly one final
#   frame (4 sigil rows + 1 caption, no animation beats); deny caption contains
#   "BIFRÖST CLOSED" exactly once; pass caption contains "proven".
ROW="statusline:viral-gate-anim"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

ANIM="$PLUGIN_ROOT/sentinels/hmd-gate-anim.sh"
assert_file "$ANIM" "hmd-gate-anim.sh present"

SEED="rj-a3f9"; GATE="oracle/falsify"

# run piped (stdout is not a tty) so the script takes its non-interactive path
run() { bash "$ANIM" "$1" "$GATE" "$SEED"; }
strip() { sed -E 's/\x1b\[[0-9;]*m//g'; }

for V in pass deny scan; do
  RAW="$(run "$V")"; EC=$?
  PLAIN="$(printf '%s' "$RAW" | strip)"
  LN="$(printf '%s\n' "$RAW" | grep -c '')"
  assert_exit 0 "$EC" "$V: exits 0 on non-TTY"
  # one final frame = 4 sigil rows + 1 caption row, nothing animated
  if [ "$LN" = 5 ]; then ok "$V: one final frame (4 sigil rows + 1 caption)"
  else bad "$V: printed $LN lines (want 5 = one frame)"; fi
done

# deny: the screenshot moment, exactly once (no 3-beat flash on non-TTY)
DENY="$(run deny | strip)"
assert_contains "$DENY" "BIFRÖST CLOSED" "deny: caption says BIFRÖST CLOSED"
DC="$(grep -oF 'BIFRÖST CLOSED' <<<"$DENY" | grep -c '')"
if [ "$DC" = 1 ]; then ok "deny: exactly one BIFRÖST CLOSED frame (no TTY beats)"
else bad "deny: BIFRÖST CLOSED appears $DC times (want 1)"; fi

# pass: the proven beat
PASS="$(run pass | strip)"
assert_contains "$PASS" "proven" "pass: caption says proven"

finish
