#!/usr/bin/env bash
# test/quick-ask-e2e.test.sh
#
# `quick-ask` END TO END (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md H3). test/quick-ask.test.sh proves the rules in-process; this one wires
# the halves together with nothing in between but the transport:
#
#   a fake phone seals `quick-ask` --> the REAL bin/heimdall-relay-client (via test/lib/fake-relay.py) --> the dispatcher (cap ask-v1, the
#   laptop switch `hmd app remote-asks`, both switches needed) --> a worker asking an env-pointed fake hmd-exec ONE closed question -->
#   the answer composed in code from the panels the client's own producer loop published (a temp sqlite connector) --> the sealed state
#   frame's `asks` slice, matched by rid.
#   Also: a phone WITHOUT ask-v1 never sees state.asks and cannot ask; the switch off empties the slice and refuses asks; the question
#   text is in no frame, no audit line, no relay event.
#
# test/lib/quick_ask_e2e.py holds the scenario (test/lib/view_phone.py is the phone). Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp
# tree, no credential of any kind, the only processes signalled are the ones the scenario started itself (never a live relay client),
# every wait is a bounded poll.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO="$REPO/test/lib/quick_ask_e2e.py"
PASS=0
FAIL=0

echo "quick-ask-e2e (phone -> relay client -> dispatcher -> model chooser -> answer composed from the panels -> state.asks, sealed end to end)"

for f in "$SCENARIO" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py" "$REPO/bin/heimdall-relay-client" "$REPO/bin/heimdall" \
         "$REPO/bin/lib/companion_quick_ask.py" "$REPO/bin/lib/companion_dashboards.py" "$REPO/bin/lib/dashboard_producers.py"; do
  if [ ! -e "$f" ]; then printf 'FATAL: required file missing: %s\n' "$f" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done
for tool in python3 git ps; do
  if ! command -v "$tool" >/dev/null 2>&1; then printf 'FATAL: required tool missing: %s\n' "$tool" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
python3 "$SCENARIO" "$REPO/bin/heimdall-relay-client" >"$OUT" 2>&1 </dev/null
RC=$?
cat "$OUT"
PASS="$(grep -c '^  ok   ' "$OUT" || true)"
FAIL="$(grep -c '^  FAIL ' "$OUT" || true)"
if [ "$RC" -ne 0 ] && [ "$FAIL" -eq 0 ]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL the scenario exited %d without a failing assertion\n' "$RC"
fi
if [ "$PASS" -lt 30 ]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL the scenario ran fewer than 30 checks (%s): it did not get through\n' "$PASS"
fi

# The suite must be able to go red: a copy of bin/ and sentinels/ with ONE wiring defect in the relay client, run only as far as step 4
# (the scenario honours ASK_E2E_STOP_AFTER=4 for exactly this), must fail the named check.
echo "== mutants: the relay client's wiring is what makes the named check pass =="
mutant() {
  local label="$1" old="$2" new="$3" want="$4" copy res
  copy="$(mktemp -d)"
  cp -R "$REPO/bin" "$REPO/sentinels" "$copy/"
  if ! python3 - "$copy/bin/heimdall-relay-client" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("mutation target found %d times: %r" % (text.count(old), old[:60]))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PYEOF
  then
    FAIL=$((FAIL + 1)); printf '  FAIL mutant [%s]: could not be applied (the code it mutates moved)\n' "$label"; rm -rf "$copy"; return
  fi
  res="$(ASK_E2E_STOP_AFTER=4 python3 "$SCENARIO" "$copy/bin/heimdall-relay-client" 2>&1 </dev/null)"
  if printf '%s\n' "$res" | grep -q "^  FAIL $want"; then
    PASS=$((PASS + 1)); printf '  ok   mutant [%s] makes check %s fail\n' "$label" "$want"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL mutant [%s] was NOT caught by %s\n' "$label" "$want"
  fi
  rm -rf "$copy"
}
mutant "the client never applies the asks slice" \
  'self._asks_overlay(self._dashboards_overlay(self._views_overlay(self._login_overlay(state))))' \
  'self._dashboards_overlay(self._views_overlay(self._login_overlay(state)))' "3a\."
mutant "dispatch without the phone's caps" 'seq=seq, transport="relay", caps=self.device_caps)' 'seq=seq, transport="relay")' "4a\."
mutant "the client loads its own copy of the module (the results live in the other one)" \
  'ASK = CONTROLS._sibling("companion_quick_ask") if CONTROLS is not None else None' \
  'ASK = _load_module("companion_quick_ask", os.path.join(LIB_DIR, "companion_quick_ask.py"))' "4b\."

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
