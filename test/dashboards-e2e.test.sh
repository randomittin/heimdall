#!/usr/bin/env bash
# test/dashboards-e2e.test.sh
#
# Custom dashboards, END TO END (hmdapp docs/HANDOFF-TO-HEIMDALL-custom-dashboards.md DD1-DD8 as one flow). Every other dashboards suite
# drives one half against fakes of the other; this one wires them together with nothing in between but the transport:
#
#   a fake phone seals `dashboard-request create` for a tile hmd has never seen --> the REAL bin/heimdall-relay-client (via
#   test/lib/fake-relay.py) --> the producer loop the client starts by itself while `hmd app remote-dashboards` is on --> the generator
#   (its model call is an env-pointed fake hmd-exec returning one fixed {shape, producer}) --> needs-confirm, the six digits in the
#   sealed state frame --> `hmd dash confirm` on a pty with the code (refused without a terminal and with a wrong code) --> the
#   producer runs against a temp sqlite connector --> the sealed state frame to the phone carries the panel data.
#   Also: a phone WITHOUT dash-v1 never sees state.dashboards and cannot ask; the switch off ends the loop and refuses requests; the
#   switch on starts it again; stopping the client takes the loop with it.
#
# test/lib/dashboards_e2e.py holds the scenario (test/lib/view_phone.py is the phone). Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp
# tree, no credential of any kind, the only processes signalled are the ones the scenario started itself (never a live relay client),
# every wait is a bounded poll.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO="$REPO/test/lib/dashboards_e2e.py"
PASS=0
FAIL=0

echo "dashboards-e2e (phone -> relay client -> generator -> laptop confirmation -> producer -> panel, sealed end to end)"

for f in "$SCENARIO" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py" "$REPO/bin/heimdall-relay-client" "$REPO/bin/heimdall" \
         "$REPO/bin/lib/dashboard_producers.py" "$REPO/bin/lib/dashboard_host.py" "$REPO/bin/lib/companion_dashboards.py"; do
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
if [ "$PASS" -lt 25 ]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL the scenario ran fewer than 25 checks (%s): it did not get through\n' "$PASS"
fi

# The suite must be able to go red: a copy of bin/ and sentinels/ with ONE defect, run only as far as step 3 (or the step named last), must
# fail the named check (the scenario honours DASH_E2E_STOP_AFTER=3 and =3f for exactly this).
echo "== mutants: the wiring that starts the loop, and the rule that keeps the phone's caps, are what make the named check pass =="
mutant() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" stop="${6:-3}" copy res
  copy="$(mktemp -d)"
  cp -R "$REPO/bin" "$REPO/sentinels" "$copy/"
  if ! python3 - "$copy/$file" "$old" "$new" <<'PYEOF'
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
  res="$(DASH_E2E_STOP_AFTER="$stop" python3 "$SCENARIO" "$copy/bin/heimdall-relay-client" 2>&1 </dev/null)"
  if printf '%s\n' "$res" | grep -q "^  FAIL $want"; then
    PASS=$((PASS + 1)); printf '  ok   mutant [%s] makes check %s fail\n' "$label" "$want"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL mutant [%s] was NOT caught by %s\n' "$label" "$want"
  fi
  rm -rf "$copy"
}
mutant "the state cache never tells the host" sentinels/hmd-ui.py \
  '        observe_dash(self._dash, state)' '        _ = self._dash' "3b\."
mutant "the loop is started without --parent" bin/lib/dashboard_host.py \
  '"run", "--parent", str(os.getpid())]' '"run"]' "3c\."
mutant "a same-device device_bound forgets the caps again" bin/heimdall-relay-client \
  $'                if device_pub == self.device_pub:\n' \
  $'                if device_pub == self.device_pub:\n                    self._adopt_device_caps(None)\n' "3d\." 3f
mutant "another device's device_bound keeps the caps" bin/heimdall-relay-client \
  $'                self._adopt_device_caps(None)  # a different device: nothing the paired phone listed is kept for it\n' \
  $'                _ = device_pub\n' "3e\." 3f

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
