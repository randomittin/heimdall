#!/usr/bin/env bash
# test/heimdall-ui-relay-paths.test.sh
#
# Oracle for A5 of hmdapp's docs/HANDOFF-TO-HEIMDALL-product-asks.md ("A5 (2026-10-01,
# from on-device testing) -- keep repo-relative edit paths over the relay"): the state
# bin/heimdall-relay-client seals for the paired phone keeps REPO-RELATIVE paths, because
# that leg is end-to-end encrypted (the relay sees ciphertext only) -- the reason public
# mode reduces every path to a basename (an --allow-host / Tailscale Funnel listener that
# anyone can reach) does not apply to it. Never an absolute path either way.
#
# Contract under test (each assertion below cites it):
#   R1  relay profile (transport.bind == "relay", built IN-PROCESS by the relay client): an
#       absolute path token below the served repo root -> its repo-relative part
#       ("src/app/x.ts"), wherever it sits in a string leaf; the root itself, anything
#       outside it, and ~/ tokens -> basename (never an absolute path); emails -> [email]
#   R2  the public profile (transport.public_host set, bind loopback -- hmd ui behind
#       --allow-host) is UNCHANGED: every absolute token -> basename
#   R3  loopback (no public_host, bind loopback) is unredacted, byte for byte
#   R4  the relay profile never depends on public_host being set (state leaves the machine
#       either way) -- fail closed
#   R5  both redaction call sites honour the profile: collect_state(), and the panels
#       re-collected inside StateCache.refresh(publish=True)
#   R6  end to end: the REAL relay client + REAL E2E crypto against test/lib/fake-relay.py;
#       the decrypted first state frame carries the relay profile
# That an HTTP caller can NOT select the relay profile (nor switch the public one off) is
# proven against a live --allow-host server in test/heimdall-ui-allowhost.test.sh, Group K.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR live in one sandbox, the session-id env that keys
# edit-tracker's ledger is unset (so the ledger this file plants at
# $TMPDIR/heimdall-edits/default.log is the one both the in-process collector and the
# relay-client subprocess read), and heimdall-fallback's network probe is short-circuited.
# The sandbox path is short and low-entropy on purpose: the panel writer refuses
# secret-SHAPED strings and a fixture path must never be mistaken for one.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="$REPO/bin/heimdall-ui"
UI_PY="$REPO/sentinels/hmd-ui.py"
RELAY_CLIENT="$REPO/bin/heimdall-relay-client"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-relay-paths (A5: repo-relative paths over the E2E relay; public profile unchanged)"

for f in "$UI" "$UI_PY" "$RELAY_CLIENT" "$FAKE_RELAY" "$E2E_MOD"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n\n0 passed, 1 failed\n' "$f"
    exit 1
  fi
done
for tool in jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n\n0 passed, 1 failed\n' "$tool"
    exit 1
  fi
done

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d /tmp/hmd-relay-paths.XXXXXX)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SESSION_ID

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

FIX="$TMPROOT/repo"
OTHER="$TMPROOT/other"
mkdir -p "$HOME/.claude" "$HEIMDALL_HOME" "$FIX/src/app" "$OTHER/lib" "$TMPDIR/heimdall-edits"
# hmd-ui canonicalises the repo with realpath, which resolves /tmp (and /var) through
# macOS's /private symlink; every path this file plants must use that physical form.
FIX_REAL="$(cd "$FIX" && pwd -P)"
OTHER_REAL="$(cd "$OTHER" && pwd -P)"
REPO_BASE="$(basename "$FIX_REAL")"

# The edit ledger is per Claude session and records absolute paths: two in-repo files (one
# edited twice), one file outside the repo.
cat > "$TMPDIR/heimdall-edits/default.log" <<EOF
1000|Edit|$FIX_REAL/src/app/x.ts
1001|Write|$FIX_REAL/README.md
1002|Edit|$FIX_REAL/src/app/x.ts
1003|Edit|$OTHER_REAL/lib/y.ts
EOF

# One kv panel whose values exercise every token shape the redaction has to get right.
DATA_JSON="$TMPROOT/a5-probe.json"
cat > "$DATA_JSON" <<EOF
{"rows":[["file","$FIX_REAL/src/app/x.ts"],
         ["prose","blocked by $FIX_REAL/src/app/x.ts now"],
         ["dir","$FIX_REAL/src/app/"],
         ["root","$FIX_REAL"],
         ["mail","someone@example.com"],
         ["home","~/private-notes"],
         ["evil","$FIX_REAL-evil/z.ts"],
         ["dotdot","$FIX_REAL/../outside/w.ts"]]}
EOF
if ! PANEL_OUT="$(HEIMDALL_WATCH_ROOT="$FIX" "$UI" panel set a5-probe --type kv --title "A5 probe" --data-json "$DATA_JSON" 2>&1)"; then
  printf 'FATAL: could not publish the fixture panel: %s\n\n0 passed, 1 failed\n' "$PANEL_OUT"
  exit 1
fi

# chk LABEL FILTER FILE [jq args...]: ok when FILTER is true over FILE.
chk() {
  local label="$1" filter="$2" file="$3"
  shift 3
  if jq -e "$@" "$filter" "$file" >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label -- got: $(jq -c "$@" "$filter" "$file" 2>&1 | head -c 300)"
  fi
}

# ═══ Part 1 -- in-process: collect_state() and StateCache under each transport ═════
PY_OUT="$TMPROOT/inproc.json"
python3 - "$UI_PY" "$FIX_REAL" >"$PY_OUT" 2>"$TMPROOT/inproc.err" <<'PYEOF'
import importlib.util, json, sys

ui_py, root = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("hmd_ui", ui_py)
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def view(state):
    rows = {}
    for panel in state.get("panels") or []:
        if panel.get("id") == "a5-probe":
            rows = {k: v for k, v in panel["data"]["rows"]}
    return {"edits": (state.get("edits") or {}).get("paths"), "repo": state.get("repo"),
            "rows": rows, "transport": state.get("transport")}


transports = {
    "loopback":    {"bind": "loopback", "public_host": None, "trust_proxy": False},
    "public":      {"bind": "loopback", "public_host": "demo.tail1234.ts.net", "trust_proxy": False},
    "relay":       {"bind": "relay", "public_host": "relay.example", "trust_proxy": False, "port": 1},
    "relay_nopub": {"bind": "relay", "public_host": None, "trust_proxy": False, "port": 1},
}
out = {name: view(ui.collect_state(root, t)) for name, t in transports.items()}
for name in ("public", "relay"):
    state, _digest = ui.StateCache(root, transports[name]).refresh(publish=True)
    out["cache_" + name] = view(state)
print(json.dumps(out))
PYEOF
if [ ! -s "$PY_OUT" ]; then
  printf 'FATAL: in-process harness produced no output: %s\n\n0 passed, 1 failed\n' "$(cat "$TMPROOT/inproc.err")"
  exit 1
fi

chk "R1 relay: edits.paths = repo-relative for in-repo files, basename for the out-of-repo one" \
    '.relay.edits == ["src/app/x.ts","README.md","y.ts"]' "$PY_OUT"
chk "R1 relay: no edits.paths entry is absolute or climbs out ('/' or '..' prefix)" \
    '.relay.edits | all(.[]; (startswith("/") or startswith("..")) | not)' "$PY_OUT"
chk "R1 relay: an in-repo absolute token in a string leaf -> its repo-relative part" \
    '.relay.rows.file == "src/app/x.ts"' "$PY_OUT"
chk "R1 relay: ... also when it sits mid-sentence" \
    '.relay.rows.prose == "blocked by src/app/x.ts now"' "$PY_OUT"
chk "R1 relay: a trailing-slash directory token -> 'src/app'" \
    '.relay.rows.dir == "src/app"' "$PY_OUT"
chk "R1 relay: the repo root itself (state.repo, a bare root token) -> its basename, never empty or '.'" \
    '.relay.repo == $b and .relay.rows.root == $b' "$PY_OUT" --arg b "$REPO_BASE"
chk "R1 relay: a ~/ token -> basename" \
    '.relay.rows.home == "private-notes"' "$PY_OUT"
chk "R1 relay: a sibling whose name merely STARTS with the root name (<root>-evil/z.ts) is outside -> 'z.ts'" \
    '.relay.rows.evil == "z.ts"' "$PY_OUT"
chk "R1 relay: <root>/../outside/w.ts escapes the repo -> basename 'w.ts'" \
    '.relay.rows.dotdot == "w.ts"' "$PY_OUT"
chk "R1 relay: emails are still scrubbed -> '[email]'" \
    '.relay.rows.mail == "[email]"' "$PY_OUT"
chk "R1 relay: transport.bind is echoed unchanged" \
    '.relay.transport.bind == "relay"' "$PY_OUT"

chk "R2 public: edits.paths unchanged (repo-relative in-repo, basename outside)" \
    '.public.edits == ["src/app/x.ts","README.md","y.ts"]' "$PY_OUT"
chk "R2 public: an in-repo absolute token -> basename 'x.ts' (the repo-relative part is NOT kept for a public listener)" \
    '.public.rows.file == "x.ts"' "$PY_OUT"
chk "R2 public: mid-sentence token -> basename" \
    '.public.rows.prose == "blocked by x.ts now"' "$PY_OUT"
chk "R2 public: a trailing-slash directory token -> 'app'" \
    '.public.rows.dir == "app"' "$PY_OUT"
chk "R2 public: state.repo and a bare root token -> basename" \
    '.public.repo == $b and .public.rows.root == $b' "$PY_OUT" --arg b "$REPO_BASE"
chk "R2 public: ~/, evil-sibling and dotdot tokens -> basenames; email -> [email]" \
    '.public.rows.home == "private-notes" and .public.rows.evil == "z.ts" and .public.rows.dotdot == "w.ts" and .public.rows.mail == "[email]"' "$PY_OUT"

chk "R3 loopback: nothing is redacted (repo, in-repo token, email, out-of-repo edit path)" \
    '.loopback.repo == $r and .loopback.rows.file == ($r + "/src/app/x.ts") and .loopback.rows.mail == "someone@example.com" and .loopback.edits[2] == ($o + "/lib/y.ts")' \
    "$PY_OUT" --arg r "$FIX_REAL" --arg o "$OTHER_REAL"

chk "R4 bind=relay with public_host=null still redacts (fail closed) and uses the relay profile" \
    '.relay_nopub.rows.file == "src/app/x.ts" and .relay_nopub.rows.mail == "[email]" and (.relay_nopub.repo | contains("/") | not)' "$PY_OUT"

chk "R5 StateCache.refresh(publish=True) re-redacts the re-collected panels with the SAME profile (relay -> repo-relative)" \
    '.cache_relay.rows.file == "src/app/x.ts" and .cache_relay.rows.mail == "[email]"' "$PY_OUT"
chk "R5 ... and for a public transport -> basename" \
    '.cache_public.rows.file == "x.ts" and .cache_public.rows.mail == "[email]"' "$PY_OUT"

# ═══ Part 2 -- end to end: the real relay client, real E2E crypto, fake relay ═════════
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

PORT_R="$(free_port)"
LOG_R="$TMPROOT/r.log"; CTL_R="$TMPROOT/r.ctl"
mkdir -p "$LOG_R" "$CTL_R"
python3 "$FAKE_RELAY" serve "$PORT_R" --log "$LOG_R" --ctl "$CTL_R" >"$TMPROOT/r.srv.out" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_R))==0 else 1)" && break
  sleep 0.1
done

# The device key must be on disk BEFORE the client's first stream connection: the fake
# relay sends device_bound on that very first connect.
DEV_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
DEV_PRIV_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .priv_b64)"
DEV_PUB_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .pub_b64)"
printf '%s' "$DEV_PUB_B64" > "$CTL_R/bind-device"

CLIENT_OUT="$TMPROOT/r.client.out"
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_R" --repo "$FIX" --ui-port 1 \
  >"$CLIENT_OUT" 2>"$TMPROOT/r.client.err" &
PIDS+=("$!")

STATE_R="$TMPROOT/r.state.json"
GOT_STATE=false
if wait_for "$CLIENT_OUT" '"event":"pair_init"' 15; then
  SID_R="$(jq -r 'select(.event=="pair_init") | .qr.session_id' "$CLIENT_OUT" | head -1)"
  HMD_PUB_R="$(jq -r 'select(.event=="pair_init") | .qr.hmd_pubkey' "$CLIENT_OUT" | head -1)"
  KEY_R="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_R" --session-id "$SID_R" | jq -r .key_b64)"
  python3 - "$LOG_R/frames.ndjson" "$KEY_R" "$E2E_MOD" "$STATE_R" <<'PYEOF'
import base64, json, sys, time
from importlib.util import module_from_spec, spec_from_file_location

frames, key_b64, e2e_path, out_path = sys.argv[1:5]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
deadline = time.time() + 25
while time.time() < deadline:
    try:
        with open(frames, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") != "hmd" or env.get("type") != "state":
            continue
        plain = e2e.open_(key, env["seq"], "hmd", env["nonce"], env["ciphertext"])
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(json.loads(plain.decode("utf-8"))["state"]))
        sys.exit(0)
    time.sleep(0.2)
sys.exit(1)
PYEOF
  [ "$?" -eq 0 ] && [ -s "$STATE_R" ] && GOT_STATE=true
fi

if [ "$GOT_STATE" = true ]; then
  chk "R6 e2e: the decrypted relay state frame's edits.paths are repo-relative (basename only for the out-of-repo file)" \
      '.edits.paths == ["src/app/x.ts","README.md","y.ts"]' "$STATE_R"
  chk "R6 e2e: panel text carries the repo-relative part and a scrubbed email" \
      '(.panels[] | select(.id=="a5-probe") | .data.rows | map({(.[0]): .[1]}) | add) as $r | $r.file == "src/app/x.ts" and $r.prose == "blocked by src/app/x.ts now" and $r.mail == "[email]"' "$STATE_R"
  chk "R6 e2e: state.repo is a bare name and transport.bind is relay" \
      '(.repo | contains("/") | not) and .transport.bind == "relay"' "$STATE_R"
  chk "R6 e2e: no edits path, repo or probe-panel value contains the sandbox path (no absolute path leaves the machine)" \
      '[.edits.paths[], .repo, (.panels[] | select(.id=="a5-probe") | .data.rows[][1])] | all(.[]; contains($t) | not)' \
      "$STATE_R" --arg t "$TMPROOT"
else
  bad "R6 e2e: no decrypted state frame from the real relay client -- client stderr: $(head -c 400 "$TMPROOT/r.client.err" 2>/dev/null)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
