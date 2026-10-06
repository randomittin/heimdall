#!/usr/bin/env bash
# test/dashboard-alerts.test.sh -- H1 + H2 of hmdapp's docs/HANDOFF-TO-HEIMDALL-watch.md: threshold alerts on a number tile
# (bin/lib/dashboard_alerts.py, cap dash-alert-v1) and the push kind `tile_alert` (the registry in bin/lib/companion_push.py).
#
#   1  the battery (test/lib/dashboard_alerts_battery.py) against the REAL modules: set / clear round trip, every refusal, the state key
#      only with the cap, edge-triggered fire once per crossing, hold_s, re-arm + the 60 minute floor and the 6-a-day cap (injected clock),
#      a failed run neither fires nor re-arms, a string value never alerts, 10 alerts then too-many-alerts, set/clear rate limit, the push
#      (loopback fake Expo only: allowlisted keys, no number unless with_value, the H2 constants, limits, served once), a phone that did not
#      ask for the kind gets nothing, the registration (old app unaffected, a kind without its cap is bad-events), audit without values,
#      the idle exemption (300 s floor, 30 day pause)
#   2  mutants: bin/lib is copied, ONE deliberate defect is patched into the copy, and the NAMED assertion must go red for each
#
# Hermetic: HOME / HEIMDALL_HOME / the repo are temp dirs; the only network is a loopback FakeExpo; no real push is ever sent and no live
# relay client is signalled. Secret-shaped strings are assembled at runtime.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATTERY="$REPO/test/lib/dashboard_alerts_battery.py"
PASS=0
FAIL=0
N=0

echo "dashboard-alerts (H1 alerts on number tiles, H2 push kind tile_alert)"

for f in "$BATTERY" "$REPO/bin/lib/dashboard_alerts.py" "$REPO/test/lib/push_test_lib.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

tally() {
  local out="$1" line
  while IFS= read -r line; do
    case "$line" in
      "ok "*) N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "${line#ok }" ;;
      "bad "*) N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "${line#bad }" ;;
      "   "*|*Traceback*|*Error*) printf '%s\n' "$line" ;;
    esac
  done <<<"$out"
}

echo "== 1. the battery =="
OUT="$(python3 "$BATTERY" 2>&1 </dev/null)"
RC=$?
tally "$OUT"
if [ "$RC" -ne 0 ]; then
  N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. the battery exited %d\n' "$N" "$RC"
fi

echo "== 2. mutants: each deliberate defect must fail its named assertion =="
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# mutant NAME FILE OLD NEW EXPECTED-FAILING-ASSERTION-SUBSTRING
mutant() {
  local name="$1" file="$2" old="$3" new="$4" expect="$5" lib="$TMPROOT/$1"
  cp -R "$REPO/bin/lib" "$lib"
  if ! python3 - "$lib/$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
if s.count(old) != 1:
    sys.exit(1)
open(path, "w").write(s.replace(old, new))
PY
  then
    N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. mutant %s could not be built\n' "$N" "$name"
    return
  fi
  local out
  out="$(python3 "$BATTERY" --lib "$lib" 2>&1 </dev/null)"
  if printf '%s\n' "$out" | grep -F "bad " | grep -qF "$expect"; then
    N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. mutant %s turns "%s" red\n' "$N" "$name" "$expect"
  else
    N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. mutant %s survived: "%s" stayed green\n' "$N" "$name" "$expect"
  fi
}

mutant fires-every-true-run dashboard_alerts.py 'if a["armed"] and now - a["true_since"]' 'if now - a["true_since"]' "no second push while the value stays below"
mutant ignores-hold dashboard_alerts.py 'now - a["true_since"] >= a["hold_s"]' 'True' "a false run in between restarts the hold"
mutant rearms-without-floor dashboard_alerts.py '(last is None or now - last >= REARM_GAP_S)' 'True' "recovery inside 60 minutes of the last push does not re-arm"
mutant no-daily-cap dashboard_alerts.py 'if a["fired"]["n"] < DAILY_MAX:' 'if True:' "the 7th crossing of the UTC day is dropped"
mutant leaks-value dashboard_alerts.py '    if alert["with_value"]:
        fmt' '    if True:
        fmt' "the spooled event holds no number unless with_value"
mutant no-cap-check dashboard_alerts.py 'if caps is None or CAP_ALERTS not in caps:' 'if False:' "a phone that did not list dash-alert-v1 is caps-missing"
mutant no-push-check dashboard_alerts.py '        if not _push_ready(root):
            return _refuse(kit, root, tile_id, "push-off")' '        if False:
            return _refuse(kit, root, tile_id, "push-off")' "set-alert with no push registration asking for tile_alert is push-off"
mutant default-includes-kind companion_push.py '"events": frozenset(wanted) if wanted else _PUSH_KINDS}' '"events": frozenset(wanted) if wanted else _PUSH_KINDS | frozenset(_EXT)}' "a device that did not list tile_alert in its events is sent nothing"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
