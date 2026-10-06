#!/usr/bin/env bash
# test/heimdall-dashboards.test.sh
#
# Custom dashboards, the PROTOCOL half (hmdapp docs/HANDOFF-TO-HEIMDALL-custom-dashboards.md DD1-DD3, DD7): the cap, the third expand
# switch, the sealed `dashboard-request` action and every key set and refusal it has (a `create` for a tile hmd has never seen is
# accepted, refine / set-refresh / refresh / remove on an unknown id are not), the tile store and the `state.dashboards` slice, panel
# publishing through the shared validator, the audit line and timeline record, the same tiles drawn READ-ONLY in `hmd ui`, and the
# function boundary the producer side (bin/lib/dashboard_producers.py: generator, runtime, `hmd dash`) calls.
# test/lib/dashboards_driver.py holds the in-process checks; this script
#
#   1  runs them against the real bin/lib (every check must pass), and
#   2  runs them against a COPY of bin/lib (or of sentinels/) with one mutation each -- the named check must FAIL, so the suite is
#      falsifiable: drop the switch check; accept `dashboard_request` (underscore); accept an extra param; skip the `project` check;
#      refuse a `create` for an unseen tile; let a producer run with fingerprint != confirmed_fp; let a rejected panel replace the good
#      one; put the producer plan into the state; put the confirmation code in the desktop view; ignore the phone's caps; hand the
#      slice to a phone that never listed dash-v1; add a mutating route, or a control, to the desktop view,
#   3  starts a REAL `hmd ui` server over a seeded tile store and proves the desktop view: the same tiles with their numbers, no
#      code, no statement, no control in the page, no route that can create / edit / remove a tile -- and the same probe, against a
#      server whose direct route is handed the phone's caps, must FAIL (a tile gets created),
#   4  checks the wiring by text: the relay client, hmd-ui and heimdall-app each carry their hook.
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir (the driver and every server make their own), every process this suite starts is
# reaped on EXIT, every wait is a bounded poll, nothing else is signalled and no relay client is touched. The wire half (a real
# bin/heimdall-relay-client sealing these frames) rides test/heimdall-controls-relay.test.sh's harness and
# test/relay-contract-fixtures.test.sh (the caps list in the sealed state frame).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO/test/lib/dashboards_driver.py"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-dashboards (cap dash-v1, action dashboard-request, tile store, state.dashboards, panel publishing, audit, read-only hmd ui)"

for f in "$DRIVER" "$REPO/bin/lib/companion_dashboards.py" "$REPO/bin/lib/companion_ui_controls.py" "$REPO/bin/heimdall-ui"; do
  if [ ! -e "$f" ]; then printf 'FATAL: required file missing: %s\n' "$f" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done
for tool in python3 jq curl git; do
  if ! command -v "$tool" >/dev/null 2>&1; then printf 'FATAL: required tool missing: %s\n' "$tool" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done

TMPROOT="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

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

# 2a. a copy of bin/lib with up to TWO edits; the named check must fail on it
mutant() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" file2="${6:-}" old2="${7:-}" new2="${8:-}" copy="$TMPROOT/m-$RANDOM/bin/lib" out
  mkdir -p "$copy" && cp -R "$REPO/bin/lib/." "$copy/"
  if ! mutate "$copy/$file" "$old" "$new" || { [ -n "$file2" ] && ! mutate "$copy/$file2" "$old2" "$new2"; }; then
    bad "mutant [$label]: could not be applied (the code it mutates moved)"; return
  fi
  out="$(python3 "$DRIVER" "$copy" 2>&1)"
  if printf '%s\n' "$out" | grep -q "^FAIL $want"; then ok "mutant [$label] makes check '$want' fail"; else bad "mutant [$label] was NOT caught by '$want'"; fi
}

# 2b. a copy of sentinels/ (the desktop view's server and page) with one edit; the static route / page check must fail on it
ui_mutant() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" copy="$TMPROOT/u-$RANDOM" out
  mkdir -p "$copy" && cp -R "$REPO/sentinels/." "$copy/"
  if ! mutate "$copy/$file" "$old" "$new"; then bad "mutant [$label]: could not be applied (the code it mutates moved)"; return; fi
  out="$(HMD_UI_DIR="$copy" python3 "$DRIVER" "$REPO/bin/lib" 2>&1)"
  if printf '%s\n' "$out" | grep -q "^FAIL $want"; then ok "mutant [$label] makes check '$want' fail"; else bad "mutant [$label] was NOT caught by '$want'"; fi
}

mutant "drop the switch check" companion_ui_controls.py \
  'if sw is None or not sw.switch_enabled(spec["switch"]):
        return None, None, spec["policy"].get("off_detail", "not-allowed")' \
  'if False:
        return None, None, spec["policy"].get("off_detail", "not-allowed")' switch-off-refuses
mutant "accept dashboard_request (underscore)" companion_dashboards.py 'ACTION = "dashboard-request"' 'ACTION = "dashboard_request"' underscore-is-not-implemented \
  companion_ui_controls.py 'NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,39}")' 'NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,39}")'
mutant "accept an extra param" companion_dashboards.py \
  'if not set(required) <= keys or not keys <= set(required) | set(optional):' 'if not set(required) <= keys:' keysets
mutant "skip the project check" companion_dashboards.py 'if fields["project"] not in project_names(root):' 'if False:' wrong-project
mutant "refuse a create for an unseen tile" companion_dashboards.py \
  '    elif len(_all_tiles(root)) >= MAX_TILES:
        return False, "too-many-tiles", {}' \
  '    elif True:
        return False, "unknown-tile", {}
    elif len(_all_tiles(root)) >= MAX_TILES:
        return False, "too-many-tiles", {}' create-accepts-unseen-tile-ids
mutant "run a producer with fingerprint != confirmed_fp" companion_dashboards.py \
  'tile["fingerprint"] == tile["confirmed_fp"] and isinstance(tile.get("proposal"), dict)' 'isinstance(tile.get("proposal"), dict)' confirmed-producers-exact
mutant "an error/timeout tile never retries" companion_dashboards.py \
  'tile["detail"] in ("producer-failed", "timeout", "rejected-panel")' 'tile["detail"] in ("producer-failed", "rejected-panel")' failed-tiles-retry-under-backoff
mutant "an import with the confirmed fingerprint goes live unconfirmed" companion_dashboards.py \
  'if tile["confirmed_fp"] == fp and tile["origin"] != "import":' 'if tile["confirmed_fp"] == fp:' import-with-the-confirmed-fingerprint-still-needs-confirm
mutant "let a rejected panel replace the good one" companion_dashboards.py \
  'tile.update(phase="error", detail="rejected-panel")' 'tile.update(phase="error", detail="rejected-panel", panel=dict(candidate) if isinstance(candidate, dict) else None)' publish-goes-through-the-validator
mutant "put the producer plan into the state" companion_dashboards.py \
  '"producer_label": _label(tile), "confirm": None,' '"producer_label": _label(tile), "proposal": tile.get("proposal"), "confirm": None,' no-proposal-or-statement-anywhere
mutant "put the confirmation code in the desktop view" companion_dashboards.py \
  'if phone else {"expires_at": expires}' 'if True else {"expires_at": expires}' desktop-view-has-panels-but-no-code
mutant "ignore the phone's caps" companion_ui_controls.py \
  'if cap is not None and (caps is None or cap not in caps):' 'if False:' caps-missing
mutant "hand the slice to a phone without dash-v1" companion_dashboards.py \
  'listed = isinstance(device_caps, (set, frozenset, list, tuple)) and CAP_DASH in device_caps' 'listed = True' overlay-gating
ui_mutant "a POST route that can reach the controls under a dashboards path" hmd-ui.py \
  '        elif path == "/api/control":
            self._handle_control()
' \
  '        elif path == "/api/control":
            self._handle_control()
        elif path == "/api/dashboards":
            self._handle_control()
' desktop-has-no-mutating-route
ui_mutant "the direct route handed the phone's caps" hmd-ui.py \
  'device_id="direct", seq=None, transport="direct")' 'device_id="direct", seq=None, transport="direct", caps={"dash-v1"})' desktop-has-no-mutating-route
ui_mutant "a control and a request in the desktop renderer" hmd-ui.html \
  'function renderDashPanels(d, nowS) {
    var host = el("dashpanels");' \
  'function renderDashPanels(d, nowS) {
    fetch("/api/control", { method: "POST" });
    var host = el("dashpanels");' desktop-has-no-mutating-route

# 3. the desktop view over a REAL hmd ui server and a seeded tile store (read-only: nothing on it can create, edit or remove a tile)
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# desktop_probe LABEL TREE -> `ok NAME` / `FAIL NAME` lines; TREE holds bin/ and sentinels/ (the real repo, or a mutated copy)
desktop_probe() {
  local label="$1" tree="$2" home repo port out url auth base code before after bad_routes spec m path i
  home="$(mktemp -d "$TMPROOT/desk.XXXXXX")"
  repo="$home/repo"; mkdir -p "$repo" "$home/h" "$home/.claude"
  ( cd "$repo" && git init -q . >/dev/null 2>&1 ) || true
  repo="$(cd "$repo" && pwd -P)"
  if ! HOME="$home" HEIMDALL_HOME="$home/h" python3 - "$tree/bin/lib" "$repo" <<'PYEOF'
import sys, time
from importlib.util import module_from_spec, spec_from_file_location
lib, root = sys.argv[1:3]
def load(name):
    spec = spec_from_file_location(name, "%s/%s.py" % (lib, name)); mod = module_from_spec(spec); spec.loader.exec_module(mod); return mod
sw, d = load("companion_remote_switches"), load("companion_dashboards")
sw.set_switch("dashboards", True)
prop = {"shape": {"type": "number"}, "producer": {"kind": "sql", "connector": "shop-db", "statement": "SELECT count(*) AS n FROM customers", "columns": ["n"]}}
def tile(tid, intent):
    with d._locked(root):
        d._write_tile(root, d._new_tile({"tile_id": tid, "dashboard_id": "d-2b2b2b2b", "screen_id": "s-3c3c3c3c", "text": intent}, time.time()))
    assert d.register_proposal(root, tid, "q-" + tid[2:], prop) == (True, None)
tile("t-1a1a1a1a", "daily new customers")
assert d.confirm_tile(root, "t-1a1a1a1a", d.get_tile(root, "t-1a1a1a1a")["fingerprint"]) == (True, None)
assert d.publish_panel(root, "t-1a1a1a1a", {"title": "New customers", "type": "number", "data": {"value": 42}}) == (True, None)
tile("t-4d4d4d4d", "orders waiting on you")
PYEOF
  then echo "FAIL seed"; return; fi
  port="$(free_port)"; out="$home/server.out"
  ( cd "$repo" && exec env HOME="$home" HEIMDALL_HOME="$home/h" HEIMDALL_WATCH_ROOT="$repo" HMD_UI_COMPANION_PANELS=0 \
      HEIMDALL_FALLBACK_ASSUME_REACHABLE=0 HEIMDALL_FALLBACK_PROBE_TIMEOUT=1 "$tree/bin/heimdall-ui" --repo "$repo" --port "$port" --no-open ) >"$out" 2>&1 &
  PIDS+=("$!")
  url=""; i=0
  while [ "$i" -lt 200 ]; do
    url="$(grep -E "^http://127\.0\.0\.1:$port/\?(t|token)=[A-Za-z0-9_-]+\$" "$out" 2>/dev/null | head -1)"
    [ -n "$url" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ -z "$url" ]; then echo "FAIL server-start"; return; fi
  auth="${url#*\?}"; base="http://127.0.0.1:$port"
  store_sum() { ( cd "$repo/.heimdall/ui/dashboards" 2>/dev/null && find . -type f ! -name '.lock' ! -name rev | sort | xargs shasum 2>/dev/null ); }

  code="$(curl -s --max-time 90 -o "$home/state.json" -w '%{http_code}' "$base/api/state?$auth")"
  if [ "$code" = 200 ] && jq -e '.dashboards.enabled == true and (.dashboards.tiles | length) == 2
        and (.dashboards.tiles[] | select(.tile_id == "t-1a1a1a1a") | .panel.data.value == 42 and .phase == "live")
        and (.dashboards.tiles[] | select(.tile_id == "t-4d4d4d4d") | .phase == "needs-confirm" and (.confirm | keys) == ["expires_at"])' \
        "$home/state.json" >/dev/null 2>&1 && ! grep -Eq 'SELECT|"statement"|"proposal"' "$home/state.json"; then
    echo "ok state-shows-the-same-tiles"
  else echo "FAIL state-shows-the-same-tiles"; fi

  curl -s --max-time 30 -o "$home/page.html" "$base/?$auth"
  if grep -q 'id="p-dashboards"' "$home/page.html" && grep -q 'id="dashpanels"' "$home/page.html" \
     && ! awk '/<section id="p-dashboards"/,/<\/section>/' "$home/page.html" | grep -Eiq '<(button|input|form|select|textarea)|contenteditable|onclick'; then
    echo "ok page-draws-them-without-controls"
  else echo "FAIL page-draws-them-without-controls"; fi

  before="$(store_sum)"
  code="$(curl -s --max-time 30 -o "$home/ctl.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          --data '{"action":"dashboard-request","params":{"rid":"q-0000beef","op":"create","dashboard_id":"d-2b2b2b2b","screen_id":"s-3c3c3c3c","tile_id":"t-9e9e9e9e","project":"'"$(basename "$repo")"'","text":"sneak a tile in"}}' \
          "$base/api/control?$auth")"
  after="$(store_sum)"
  if [ "$code" = 403 ] && jq -e '.ok == false and .detail == "caps-missing"' "$home/ctl.json" >/dev/null 2>&1 \
     && [ "$before" = "$after" ] && [ ! -e "$repo/.heimdall/ui/dashboards/d-2b2b2b2b/t-9e9e9e9e.json" ]; then
    echo "ok control-cannot-create"
  else echo "FAIL control-cannot-create"; fi

  bad_routes=""
  for spec in "POST /api/dashboards" "POST /api/tiles" "POST /api/dashboards/t-1a1a1a1a" "PUT /api/dashboards" "DELETE /api/dashboards/t-1a1a1a1a" \
              "PATCH /api/state" "PUT /api/state" "DELETE /api/state" "GET /api/dashboards" "GET /api/dashboards/t-1a1a1a1a"; do
    m="${spec%% *}"; path="${spec#* }"
    code="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X "$m" -H 'Content-Type: application/json' --data '{}' "$base$path?$auth")"
    case "$code" in 2*) bad_routes="$bad_routes $spec=$code" ;; esac
  done
  if [ -z "$bad_routes" ] && [ "$before" = "$(store_sum)" ]; then echo "ok no-other-route-answers"; else echo "FAIL no-other-route-answers$bad_routes"; fi
}

DESK="$(desktop_probe real "$REPO")"
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "desktop hmd ui: ${line#ok }" ;;
    "FAIL "*) bad "desktop hmd ui: ${line#FAIL }" ;;
  esac
done <<<"$DESK"
if [ "$(printf '%s\n' "$DESK" | grep -c '^ok ')" -ne 4 ]; then bad "desktop hmd ui: the probe did not run its four checks: $DESK"; fi

MTREE="$TMPROOT/desk-mutant"
mkdir -p "$MTREE" && cp -R "$REPO/bin" "$MTREE/bin" && cp -R "$REPO/sentinels" "$MTREE/sentinels"
if mutate "$MTREE/sentinels/hmd-ui.py" 'device_id="direct", seq=None, transport="direct")' 'device_id="direct", seq=None, transport="direct", caps={"dash-v1"})'; then
  MOUT="$(desktop_probe mutant "$MTREE")"
  if printf '%s\n' "$MOUT" | grep -q '^FAIL control-cannot-create'; then
    ok "mutant [the direct route handed the phone's caps] lets a tile be created, and the live probe 'control-cannot-create' catches it"
  else bad "mutant [the direct route handed the phone's caps] was NOT caught by the live probe"; fi
else bad "mutant [direct route + caps]: could not be applied"; fi

# 4. the wiring, by text
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
