#!/usr/bin/env bash
# test/quick-ask.test.sh
#
# H3 `quick-ask` (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md): cap ask-v1, the sealed read-only action `quick-ask`, the laptop switch
# `hmd app remote-asks on|off|status` (off by default), the state.asks slice, answers composed in code from the dashboards store's current
# panel values -- never a producer, never a connector, never the inbox, never a number the panels do not hold.
# test/lib/quick_ask_driver.py holds the in-process checks; this script
#
#   1  runs them against the real bin/lib (every check must pass: switch off refusal, caps-missing, exact key sets, wrong-project, the
#      closed op set a model can choose from, exact numbers, compare computed in code, no-tile, the 2-line / 140-character cap, the secret
#      scrub, the 6 a minute and 60 a day limits, busy, timeout, state gating, read-only spies, ids-only audit, the switch CLI), and
#   2  runs them against a COPY of bin/lib with one or two mutations each -- the named check must FAIL, so the suite is falsifiable,
#   3  checks the wiring by text: the relay client lists the cap, applies the slice per phone and sends the state again on a result;
#      heimdall-app routes `remote-asks` and prints its status line.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, the model is a script in it (HMD_DASH_MODEL_BIN), no relay client is touched and
# nothing is signalled. The wire half (the real bin/heimdall-relay-client sealing these frames) is test/quick-ask-e2e.test.sh and
# test/relay-contract-fixtures.test.sh (the caps list in the sealed state frame).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO/test/lib/quick_ask_driver.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "quick-ask (cap ask-v1, action quick-ask, switch remote-asks, state.asks, read-only answers composed in code)"

for f in "$DRIVER" "$REPO/bin/lib/companion_quick_ask.py" "$REPO/bin/lib/companion_ui_controls.py" "$REPO/bin/lib/companion_dashboards.py"; do
  if [ ! -e "$f" ]; then printf 'FATAL: required file missing: %s\n' "$f" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done
for tool in python3 grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then printf 'FATAL: required tool missing: %s\n' "$tool" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done

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
if [ "$(grep -c '^ok \|^FAIL ' "$OUT")" -lt 30 ]; then bad "the driver ran fewer than 30 checks: $(tail -3 "$TMPROOT/real.err")"; fi

# replace OLD with NEW in FILE, exactly once (a mutation target that moved is a failure of the suite, not a silent pass)
mutate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("mutation target found %d times: %r" % (text.count(old), old[:60]))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PYEOF
}

# 2. a copy of bin/lib with up to TWO edits; the named check must fail on it
mutant() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" file2="${6:-}" old2="${7:-}" new2="${8:-}" copy="$TMPROOT/m-$RANDOM/bin/lib" out
  mkdir -p "$copy" && cp -R "$REPO/bin/lib/." "$copy/"
  if ! mutate "$copy/$file" "$old" "$new" || { [ -n "$file2" ] && ! mutate "$copy/$file2" "$old2" "$new2"; }; then
    bad "mutant [$label]: could not be applied (the code it mutates moved)"; return
  fi
  out="$(python3 "$DRIVER" "$copy" 2>&1)"
  if printf '%s\n' "$out" | grep -q "^FAIL $want"; then ok "mutant [$label] makes check '$want' fail"; else bad "mutant [$label] was NOT caught by '$want'"; fi
}

Q=companion_quick_ask.py
C=companion_ui_controls.py
mutant "drop the asks switch gate" $C 'if gated is not None and not _switch_on(gated):' 'if False:' switch-off-refuses
mutant "ignore the phone's caps" $C 'if cap is not None and (caps is None or cap not in caps):' 'if False:' caps-missing
# the exact key set is enforced twice (the dispatcher, then parse_params): both layers must go before an extra key gets through
mutant "accept an extra param" $C 'if not set(spec["required"]) <= keys or not keys <= set(spec["required"]) | set(spec["optional"]):' \
  'if not set(spec["required"]) <= keys:' keysets $Q 'set(body) != {"project", "text"} or ' ''
mutant "skip the dashboards switch" $Q 'if not _switch_on("dashboards"):' 'if False:' dashboards-off-refuses
mutant "skip the project check" $Q 'if fields["project"] not in project_names(root):' 'if False:' wrong-project
mutant "accept a secret-shaped question" $Q 'and not _panels().secret_shaped(v)' 'and True' secret-question-refused
mutant "let a secret-shaped tile text into the prompt" $Q '    if _panels().secret_shaped(text):
        return ""' '    if False:
        return ""' secret-in-tile-never-leaves
mutant "drop the 24 h window" $Q 'if len(stamps) >= DAY_MAX:' 'if False:' day-cap
mutant "drop the per-minute bucket" $Q 'RATE = ((6, 6 / 60.0),)' 'RATE = ((600000, 6000.0),)' rate-limit-per-minute
mutant "no in-flight bound" $Q 'if sum(1 for r in rows if r["phase"] == "working") >= INFLIGHT_MAX:' 'if False:' busy
mutant "open the op set" $Q 'ARITY = {"value": 1, "change": 1, "compare": 2, "no-tile": 0}' 'ARITY = {"value": 1, "change": 1, "compare": 2, "no-tile": 0, "run": 1}' closed-op-set
mutant "believe a tile the chooser was not given" $Q 'all(isinstance(i, str) and i in known for i in ids)' 'all(isinstance(i, str) for i in ids)' closed-op-set
mutant "put the values in the prompt" $Q '"change": _dec(c["data"].get("delta")) is not None} for c in cands]' \
  '"change": _dec(c["data"].get("delta")) is not None, "value": c["data"].get("value")} for c in cands]' prompt-carries-no-values
mutant "compare adds instead of subtracting" $Q '_fmt(a - b, fmt, signed=True)' '_fmt(a + b, fmt, signed=True)' compare-computed-in-code
mutant "answer from a tile that is not live" $Q 'if tile.get("phase") == "live" and isinstance(data, dict)' 'if isinstance(data, dict)' no-tile-without-model-call
mutant "no title shrinking and no length guard" $Q 'if len(text) <= ANSWER_MAX:' 'if True:' answer-two-lines-max \
  $Q 'if (len(text) > ANSWER_MAX or' 'if (False or'
mutant "hand the slice to a phone without ask-v1" $Q 'listed = isinstance(device_caps, (set, frozenset, list, tuple)) and CAP_ASK in device_caps' 'listed = True' overlay-gating
mutant "keep the results after the switch went off" $Q '            _RESULTS.pop(root, None)
' '            pass
' off-hides-results
mutant "touch the dashboards store during an ask" $Q '    cands = candidates(root)
    if not cands:' '    cands = candidates(root)
    _sibling("companion_dashboards")._touch(root)
    if not cands:' read-only-spy

# 3. the wiring, by text
RC="$REPO/bin/heimdall-relay-client"
grep -q 'ASK.CAP_ASK' "$RC" && grep -q '_asks_overlay(self._dashboards_overlay' "$RC" && grep -q 'ASK.set_on_change(self.root, self._rearm_state)' "$RC" \
  && grep -q 'caps=self.device_caps' "$RC" && ok "relay client: cap listed, slice applied per phone, state re-sent when a result lands, phone caps passed to dispatch" \
  || bad "relay client wiring missing"
grep -q '"asks"' "$RC" && ok 'the "asks" key is wired in bin/heimdall-relay-client' || bad 'no "asks" key wiring in the relay client'
if grep -q '"asks"' "$REPO/sentinels/hmd-ui.py"; then bad 'hmd-ui carries an "asks" key: answers must never be in the base state'; else ok 'hmd-ui (the base state and its SSE digest) carries no asks key: answers live only in the phone'"'"'s own frames'; fi
grep -q 'remote-asks' "$REPO/bin/heimdall-app" && grep -q 'companion_quick_ask.py" status-line' "$REPO/bin/heimdall-app" \
  && ok "heimdall-app: remote-asks routed, status line printed" || bad "heimdall-app wiring missing"
grep -q '"ask-v1"' "$REPO/bin/lib/companion_quick_ask.py" && grep -q '"quick-ask"' "$REPO/bin/lib/companion_quick_ask.py" \
  && grep -q 'remote-asks.json' "$REPO/bin/lib/companion_remote_switches.py" && ok "acceptance greps: cap, action name, switch file" || bad "acceptance greps failed"
if grep -Eq 'subprocess|os\.system|eval\(|exec\(' "$REPO/bin/lib/companion_quick_ask.py"; then bad "companion_quick_ask.py starts a process itself (it may only reuse dashboard_producers.run_model)"; else ok "companion_quick_ask.py has no process spawn of its own: the model call is dashboard_producers.run_model"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
