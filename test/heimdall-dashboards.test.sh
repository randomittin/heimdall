#!/usr/bin/env bash
# test/heimdall-dashboards.test.sh
#
# Custom dashboards, the PROTOCOL half (hmdapp docs/HANDOFF-TO-HEIMDALL-custom-dashboards.md DD1-DD3, DD7): the cap, the third expand
# switch, the sealed `dashboard-request` action and every key set and refusal it has, the tile store and the `state.dashboards` slice,
# panel publishing through the shared validator, the audit line and timeline record, and the function boundary the producer side
# (bin/lib/dashboard_producers.py: generator, runtime, `hmd dash`) calls. test/lib/dashboards_driver.py holds the checks; this script
#
#   1  runs them against the real bin/lib (every check must pass), and
#   2  runs them against a COPY of bin/lib with one mutation each (the named check must FAIL) -- the suite is falsifiable:
#      drop the switch check; accept `dashboard_request` (underscore); accept an extra param; skip the `project` check; let a producer
#      run with fingerprint != confirmed_fp; let a rejected panel replace the good one; put the producer plan into the state; ignore
#      the phone's caps; hand the slice to a phone that never listed dash-v1.
#   3  checks the wiring by text: the relay client, hmd-ui and heimdall-app each carry their hook, and the state key is in the digest.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir (the driver makes its own), nothing is signalled, no relay client is touched.
# The wire half (a real bin/heimdall-relay-client sealing these frames) is covered by test/heimdall-controls-relay.test.sh's harness and
# test/relay-contract-fixtures.test.sh (the caps list in the sealed state frame).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO/test/lib/dashboards_driver.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-dashboards (cap dash-v1, action dashboard-request, tile store, state.dashboards, panel publishing, audit)"

for f in "$DRIVER" "$REPO/bin/lib/companion_dashboards.py" "$REPO/bin/lib/companion_ui_controls.py"; do
  if [ ! -e "$f" ]; then printf 'FATAL: required file missing: %s\n' "$f" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done
command -v python3 >/dev/null 2>&1 || { printf 'FATAL: python3 missing\n' >&2; printf '\n0 passed, 1 failed\n'; exit 1; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# 1. the real tree
OUT="$TMPROOT/real.out"
python3 "$DRIVER" "$REPO/bin/lib" >"$OUT" 2>"$TMPROOT/real.err"
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <"$OUT"
if [ "$(grep -c '^ok \|^FAIL ' "$OUT")" -lt 20 ]; then bad "the driver ran fewer than 20 checks: $(tail -3 "$TMPROOT/real.err")"; fi

# 2. mutants: a copy of bin/lib with ONE edit; the named check must fail on it
mutant() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" copy="$TMPROOT/m-$RANDOM/bin/lib" out
  mkdir -p "$copy" && cp -R "$REPO/bin/lib/." "$copy/"
  if ! python3 - "$copy/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("mutation target found %d times: %r" % (text.count(old), old[:60]))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PYEOF
  then bad "mutant [$label]: could not be applied (the code it mutates moved)"; return; fi
  out="$(python3 "$DRIVER" "$copy" 2>&1)"
  if printf '%s\n' "$out" | grep -q "^FAIL $want"; then ok "mutant [$label] makes check '$want' fail"; else bad "mutant [$label] was NOT caught by '$want'"; fi
}

mutant "drop the switch check" companion_ui_controls.py \
  'if sw is None or not sw.switch_enabled(spec["switch"]):
        return None, None, spec["policy"].get("off_detail", "not-allowed")' \
  'if False:
        return None, None, spec["policy"].get("off_detail", "not-allowed")' switch-off-refuses
mutant "accept dashboard_request (underscore)" companion_dashboards.py 'ACTION = "dashboard-request"' 'ACTION = "dashboard_request"' underscore-is-not-implemented
mutant "accept an extra param" companion_dashboards.py \
  'if not set(required) <= keys or not keys <= set(required) | set(optional):' 'if not set(required) <= keys:' keysets
mutant "skip the project check" companion_dashboards.py 'if fields["project"] not in project_names(root):' 'if False:' wrong-project
mutant "run a producer with fingerprint != confirmed_fp" companion_dashboards.py \
  'tile["fingerprint"] == tile["confirmed_fp"] and isinstance(tile.get("proposal"), dict)' 'isinstance(tile.get("proposal"), dict)' confirmed-producers-exact
mutant "let a rejected panel replace the good one" companion_dashboards.py \
  'tile.update(phase="error", detail="rejected-panel")' 'tile.update(phase="error", detail="rejected-panel", panel=dict(candidate) if isinstance(candidate, dict) else None)' publish-goes-through-the-validator
mutant "put the producer plan into the state" companion_dashboards.py \
  '"producer_label": _label(tile), "confirm": None,' '"producer_label": _label(tile), "proposal": tile.get("proposal"), "confirm": None,' no-proposal-or-statement-anywhere
mutant "ignore the phone's caps" companion_ui_controls.py \
  'if cap is not None and (caps is None or cap not in caps):' 'if False:' caps-missing
mutant "hand the slice to a phone without dash-v1" companion_dashboards.py \
  'listed = isinstance(device_caps, (set, frozenset, list, tuple)) and CAP_DASH in device_caps' 'listed = True' overlay-gating

# 3. the wiring, by text
grep -q 'DASH.CAP_DASH' "$REPO/bin/heimdall-relay-client" && grep -q '_dashboards_overlay(self._views_overlay' "$REPO/bin/heimdall-relay-client" \
  && grep -q 'caps=self.device_caps' "$REPO/bin/heimdall-relay-client" && ok "relay client: cap listed, overlay applied per phone, phone caps passed to dispatch" \
  || bad "relay client wiring missing"
grep -q '"dashboards"' "$REPO/sentinels/hmd-ui.py" "$REPO/bin/heimdall-relay-client" && ok 'the "dashboards" key is wired in sentinels/hmd-ui.py and bin/heimdall-relay-client' || bad 'no "dashboards" key wiring'
grep -q 'remote-dashboards' "$REPO/bin/heimdall-app" && grep -q 'companion_dashboards.py" status-line' "$REPO/bin/heimdall-app" \
  && ok "heimdall-app: remote-dashboards routed, status line printed" || bad "heimdall-app wiring missing"
grep -q '"dash-v1"' "$REPO/bin/lib/companion_dashboards.py" && grep -q 'dashboard-request' "$REPO/bin/lib/companion_dashboards.py" \
  && grep -q 'dashboards' "$REPO/bin/lib/companion_remote_switches.py" && ok "acceptance greps: cap, action name, switch" || bad "acceptance greps failed"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
