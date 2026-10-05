#!/usr/bin/env bash
# test/heimdall-controls-relay.test.sh
#
# The relay half of the phone's remote controls: the sealed `command` frames (interrupt, save-checkpoint, hook-toggle,
# fallback-mode) driven through the REAL bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for
# the Cloudflare relay; the paired phone is `fake-relay.py device ...`, sealing with the real bin/lib/hmd_relay_e2e.py).
# The dispatcher itself (bin/lib/companion_ui_controls.py) is exercised in depth, through the direct route, by
# test/heimdall-controls.test.sh; this suite proves the SEALED transport reaches it and is as strict as the other commands:
#
#   0  every sealed state frame lists `controls-v1` in its caps and carries the `controls` key (no absolute path in it)
#   1  save-checkpoint -> {ok:true, of_seq, result:{written_at}} and the checkpoint file is written
#   2  hook-toggle: an allowlisted id -> {ok:true, result:{id, enabled}} and hooks-disabled moves; a locked id ->
#      not-allowed; an unknown action -> not-implemented (both acked within the ack window)
#   3  fallback-mode: switch without confirm -> confirm-required and nothing written; off -> ok (unchanged)
#   4  interrupt while the session is idle -> not-running, nothing written
#   5  rid: the same rid twice -> the second ack carries dup:true
#   6  a frame NOT sealed under the paired session key (a forgery) -> decrypt-failed and nothing changes; a genuine frame
#      whose seq was already used is rejected by the replay guard and nothing changes
#   7  after all of that abuse a genuine send-message still returns {ok:true, id}
#   8  the audit log has one line per command with device = 8 hex of the bound key (never "direct"), via relay, no params
#      outside the whitelist
#   9  none of those commands was refused `rate-limited`: the suite spends the overall budget on a schedule (below)
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are a temp dir, every process this suite starts is reaped on EXIT, every wait is a
# bounded poll. No live relay client is ever signalled: the one this suite starts is its own.
#
# The one thing it cannot make hermetic is the clock. The dispatcher's overall budget (bin/lib/companion_ui_controls.py
# _GLOBAL_RATE: a burst of 5, then one more command every 6 s) is a token bucket in the relay client's own memory, and 9 of
# this suite's 14 frames are charged to it (an unknown action, a rid repeat, a forgery, a replayed seq and send-message are
# all refused before the budget). Nothing is shared with any other suite or run -- the bucket dies with the client -- but
# the suite used to stay inside it only while python3 start-up and its own polls were slow enough to space the commands
# out: on a quicker box (python3 not behind a pyenv shim, ~20 ms a start instead of ~170) the 6th charged command came back
# `rate-limited` and so did every one after it (3b, 4, 5 red). So a charged command goes through send_charged, which holds
# the 6th and every later one until the bucket is certain to hold a token again; the burst and the refill are read from the
# module itself, so a retuned limit retunes the schedule.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_CLIENT="$REPO/bin/heimdall-relay-client"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-controls-relay (sealed control commands through the real relay client)"

for f in "$RELAY_CLIENT" "$FAKE_RELAY" "$E2E_MOD" "$REPO/bin/lib/companion_ui_controls.py"; do
  if [ ! -e "$f" ]; then printf 'FATAL: required file missing: %s\n' "$f" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done
for tool in python3 jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then printf 'FATAL: required tool missing: %s\n' "$tool" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
export HEIMDALL_FALLBACK_PROBE_TIMEOUT=1
export HMD_UI_COMPANION_PANELS=0
export HMD_UI_CONTROL_DEADLINE_S=8   # the operator knob at its ceiling (the ack window is 8 s): a loaded box must not flake a slow CLI
mkdir -p "$HOME/.claude"
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR HMD_UI_CONTROLS CLAUDE_CODE_ENTRYPOINT HMD_AGENT_TYPE HMD_JUDGMENT

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# The overall control budget the schedule below is built from, "<burst>:<whole seconds per token>", read from the module itself.
BUDGET="$(python3 - "$REPO/bin/lib/companion_ui_controls.py" <<'PYEOF' 2>/dev/null
import math, sys
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location("companion_ui_controls", sys.argv[1])
mod = module_from_spec(spec); spec.loader.exec_module(mod)
burst, per_s = mod._GLOBAL_RATE
print("%d:%d" % (burst, math.ceil(1.0 / per_s - 1e-9)))
PYEOF
)"
BUDGET_BURST="${BUDGET%%:*}"
BUDGET_EVERY_S="${BUDGET##*:}"
case "$BUDGET" in
  ''|:*|*:|*[!0-9:]*|*:*:*)
    printf 'FATAL: cannot read the overall control budget (_GLOBAL_RATE) from bin/lib/companion_ui_controls.py\n' >&2
    printf '\n0 passed, 1 failed\n'; exit 1 ;;
esac

wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do grep -Eq "$re" "$file" 2>/dev/null && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

# wait_for_ack_of_seq FILE KEY_B64 SEQ [SECS] [ONLY_OK] -> the plaintext of the first hmd frame whose of_seq is SEQ
wait_for_ack_of_seq() {
  local file="$1" key_b64="$2" want="$3" secs="${4:-10}" only_ok="${5:-0}"
  python3 - "$file" "$key_b64" "$want" "$secs" "$E2E_MOD" "$only_ok" <<'PYEOF'
import sys, json, time, base64
from importlib.util import spec_from_file_location, module_from_spec
file_path, key_b64, want_s, secs_s, e2e_path, only_ok = sys.argv[1:7]
want = int(want_s)
deadline = time.time() + float(secs_s)
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec); spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
while True:
    try:
        lines = open(file_path, "r", encoding="utf-8").readlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") != "hmd":
            continue
        try:
            obj = json.loads(e2e.open_(key, env["seq"], "hmd", env.get("nonce"), env.get("ciphertext")).decode("utf-8"))
        except Exception:
            continue
        if obj.get("of_seq") == want and (only_ok != "1" or obj.get("ok") is True):
            sys.stdout.write(json.dumps(obj) + "\n"); sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PYEOF
}

# newest_state FILE KEY_B64 [SECS] -> the plaintext {"caps","state"} of the newest sealed state frame (waits for one)
newest_state() {
  python3 - "$1" "$2" "${3:-15}" "$E2E_MOD" <<'PYEOF'
import sys, json, time, base64
from importlib.util import spec_from_file_location, module_from_spec
file_path, key_b64, secs_s, e2e_path = sys.argv[1:5]
deadline = time.time() + float(secs_s)
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec); spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
while True:
    newest = None
    try:
        lines = open(file_path, "r", encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") == "hmd" and env.get("type") == "state":
            try:
                newest = json.loads(e2e.open_(key, env["seq"], "hmd", env.get("nonce"), env.get("ciphertext")).decode("utf-8"))
            except Exception:
                continue
    if newest is not None and "controls" in newest.get("state", {}):
        sys.stdout.write(json.dumps(newest) + "\n"); sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.3)
PYEOF
}

REPO_T="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
( cd "$REPO_T" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true
REPO_T="$(cd "$REPO_T" && pwd -P)"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PORT_RELAY="$(free_port)"
PORT_UI="$(free_port)"
LOG="$TMPROOT/log"; CTL="$TMPROOT/ctl"
mkdir -p "$LOG" "$CTL"

python3 "$FAKE_RELAY" serve "$PORT_RELAY" --log "$LOG" --ctl "$CTL" >"$TMPROOT/srv.out" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_RELAY))==0 else 1)" && break
  sleep 0.1
done

DEV_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
DEV_PRIV_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .priv_b64)"
DEV_PUB_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .pub_b64)"
printf '%s' "$DEV_PUB_B64" > "$CTL/bind-device"

CLIENT_OUT="$TMPROOT/client.out"
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_RELAY" --repo "$REPO_T" --ui-port "$PORT_UI" >"$CLIENT_OUT" 2>"$TMPROOT/client.err" &
PIDS+=("$!")
if wait_for "$CLIENT_OUT" '"event":"pair_init"' 10 && wait_for "$CLIENT_OUT" '"event":"device_bound"' 10; then
  ok "setup: the real relay client paired and bound the fake device"
else
  bad "setup: relay client never reached device_bound: $(cat "$TMPROOT/client.err" 2>/dev/null)"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
SID="$(jq -r 'select(.event=="pair_init") | .qr.session_id' "$CLIENT_OUT" | head -1)"
HMD_PUB="$(jq -r 'select(.event=="pair_init") | .qr.hmd_pubkey' "$CLIENT_OUT" | head -1)"
KEY_B64="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB" --session-id "$SID" | jq -r .key_b64)"
WRONG_KEY_B64="$(python3 -c 'import base64; print(base64.b64encode(bytes(range(32))).decode())')"

CTL_N=0
send_cmd() {
  local seq="$1" text="$2" key="${3:-$KEY_B64}" sealed nonce ct
  sealed="$(python3 "$FAKE_RELAY" device seal --key-b64 "$key" --seq "$seq" --sender device --text "$text")"
  nonce="$(printf '%s' "$sealed" | jq -r .nonce_b64)"
  ct="$(printf '%s' "$sealed" | jq -r .ciphertext_b64)"
  CTL_N=$((CTL_N + 1))
  python3 "$FAKE_RELAY" device envelope --session-id "$SID" --seq "$seq" --sender device \
    --type command --nonce "$nonce" --ciphertext "$ct" > "$CTL/$(printf '%03d' "$CTL_N").json"
}
ack_of() { wait_for_ack_of_seq "$LOG/frames.ndjson" "$KEY_B64" "$1" 10; }
cmd_json() { jq -cn --arg a "$1" --argjson p "$2" '{action:$a, params:$p}'; }

# send_charged SEQ TEXT [KEY] -> send_cmd for a command that reaches a handler, so is charged to the overall budget (see the
# header). The first BUDGET_BURST go out at once; the Nth after that waits for BUDGET_T0 + (N - burst) * seconds-per-token on
# time.monotonic() -- the clock the bucket itself runs on, one value for every process. BUDGET_T0 is taken when the first
# charged command's ack was read, so it is never earlier than the charge that emptied the first token: the bucket holds at
# least what this assumes, whatever the box's speed. A frame refused before the budget (unknown action, rid repeat,
# forgery, replay, send-message) is a plain send_cmd.
CHARGED=0
BUDGET_T0=""
mono_now() { python3 -c 'import time; print(repr(time.monotonic()))'; }
send_charged() {
  CHARGED=$((CHARGED + 1))
  if [ "$CHARGED" -gt "$BUDGET_BURST" ]; then
    if [ -z "$BUDGET_T0" ]; then printf 'FATAL: charged command #%s sent before BUDGET_T0 was taken\n' "$CHARGED" >&2; printf '\n0 passed, 1 failed\n'; exit 1; fi
    python3 - "$BUDGET_T0" "$(( BUDGET_EVERY_S * (CHARGED - BUDGET_BURST) ))" <<'PYEOF'
import sys, time
until = float(sys.argv[1]) + float(sys.argv[2])
while True:
    left = until - time.monotonic()
    if left <= 0:
        break
    time.sleep(min(0.25, left))
PYEOF
  fi
  send_cmd "$@"
}
HEADS_BEFORE="$(git -C "$REPO_T" rev-parse HEAD)"

# 0. the cap and the controls key ride every sealed state frame
ST="$(newest_state "$LOG/frames.ndjson" "$KEY_B64" 20)"
if printf '%s' "$ST" | jq -e '.caps | index("controls-v1")' >/dev/null 2>&1 \
   && printf '%s' "$ST" | jq -e '.state.controls.v == 1 and (.state.controls.actions | index("hook-toggle")) and .state.controls.enabled == true' >/dev/null 2>&1; then
  ok "0a. the sealed state frame lists controls-v1 in its caps and carries state.controls (v 1, enabled)"
else
  bad "0a. caps/controls missing from the sealed state frame: $(printf '%s' "$ST" | jq -c '{caps, controls: .state.controls}' 2>/dev/null | cut -c1-300)"
fi
if ! printf '%s' "$ST" | jq -c '.state.controls' | grep -Eq '/(Users|home|private|tmp|var)/|@'; then ok "0b. no absolute path or e-mail anywhere in the relayed controls key"; else bad "0b. a path or e-mail leaked into state.controls"; fi

# 1. save-checkpoint
send_charged 1 "$(cmd_json save-checkpoint '{"rid":"c1"}')"
ACK="$(ack_of 1)"
BUDGET_T0="$(mono_now)"   # the first charge happened before this ack was read: every later charge is scheduled from here
if printf '%s' "$ACK" | jq -e '.ok == true and .of_seq == 1 and (.result.written_at | type == "number")' >/dev/null 2>&1 && [ -s "$REPO_T/.planning/CHECKPOINT.md" ] \
   && [ "$(git -C "$REPO_T" rev-parse HEAD)" = "$HEADS_BEFORE" ]; then
  ok "1. save-checkpoint -> {ok:true, of_seq:1, result:{written_at}}; the file is written, nothing is committed"
else
  bad "1. save-checkpoint ack: $ACK"
fi

# 2. hook-toggle, a locked id, an unknown action
send_charged 2 "$(cmd_json hook-toggle '{"id":"parallel-gate","enabled":false,"rid":"h1"}')"
ACK="$(ack_of 2)"
if printf '%s' "$ACK" | jq -e '.ok == true and .of_seq == 2 and .result == {"id":"parallel-gate","enabled":false}' >/dev/null 2>&1 && [ "$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)" = "parallel-gate" ]; then
  ok "2a. hook-toggle (parallel-gate, off) -> {ok:true, result:{id, enabled:false}} and hooks-disabled holds exactly it"
else
  bad "2a. hook-toggle ack: $ACK / $(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)"
fi
send_charged 3 "$(cmd_json hook-toggle '{"id":"stub-gate","enabled":false}')"
ACK="$(ack_of 3)"
if printf '%s' "$ACK" | jq -e '.ok == false and .of_seq == 3 and .detail == "not-allowed"' >/dev/null 2>&1 && [ "$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)" = "parallel-gate" ]; then
  ok "2b. a locked id -> {ok:false, detail:not-allowed} and hooks-disabled is unchanged"
else
  bad "2b. locked-id ack: $ACK"
fi
send_cmd 4 "$(cmd_json rm-rf '{}')"
ACK="$(ack_of 4)"
if printf '%s' "$ACK" | jq -e '.ok == false and .of_seq == 4 and .detail == "not-implemented"' >/dev/null 2>&1; then ok "2c. an unknown action -> {ok:false, detail:not-implemented}"; else bad "2c. unknown-action ack: $ACK"; fi
send_charged 5 "$(cmd_json hook-toggle '{"id":"parallel-gate","enabled":true,"rid":"h2"}')"
ack_of 5 >/dev/null

# 3. fallback-mode
send_charged 6 "$(cmd_json fallback-mode '{"mode":"switch"}')"
ACK="$(ack_of 6)"
if printf '%s' "$ACK" | jq -e '.ok == false and .detail == "confirm-required"' >/dev/null 2>&1 && [ ! -e "$REPO_T/.heimdall/fallback.json" ]; then
  ok "3a. fallback-mode switch without confirm -> confirm-required and nothing written"
else
  bad "3a. switch-without-confirm ack: $ACK"
fi
send_charged 7 "$(cmd_json fallback-mode '{"mode":"off"}')"
ACK="$(ack_of 7)"
if printf '%s' "$ACK" | jq -e '.ok == true and .detail == "unchanged" and .result == {"mode":"off"}' >/dev/null 2>&1; then ok "3b. fallback-mode off while off -> ok, unchanged"; else bad "3b. off ack: $ACK"; fi

# 4. interrupt while idle
send_charged 8 "$(cmd_json interrupt '{"rid":"i1"}')"
ACK="$(ack_of 8)"
if printf '%s' "$ACK" | jq -e '.ok == false and .detail == "not-running"' >/dev/null 2>&1 && [ ! -e "$REPO_T/.heimdall/ui/stop-request.json" ]; then
  ok "4. interrupt with no running turn -> {ok:false, detail:not-running}, no stop request written"
else
  bad "4. interrupt ack: $ACK"
fi

# 5. rid
send_charged 9 "$(cmd_json hook-toggle '{"id":"ctx-meter-notice","enabled":false,"rid":"d1"}')"
ack_of 9 >/dev/null
send_cmd 10 "$(cmd_json hook-toggle '{"id":"ctx-meter-notice","enabled":false,"rid":"d1"}')"
ACK="$(ack_of 10)"
if printf '%s' "$ACK" | jq -e '.ok == true and .dup == true and .result.id == "ctx-meter-notice"' >/dev/null 2>&1; then ok "5. the same rid again -> the stored ack with dup:true"; else bad "5. dup ack: $ACK"; fi
send_charged 11 "$(cmd_json hook-toggle '{"id":"ctx-meter-notice","enabled":true,"rid":"d2"}')"
ack_of 11 >/dev/null

# 6. a forgery and a replayed seq change nothing
DIS_BEFORE="$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)"
send_cmd 12 "$(cmd_json hook-toggle '{"id":"dream-notice","enabled":false}')" "$WRONG_KEY_B64"
ACK="$(ack_of 12)"
if printf '%s' "$ACK" | jq -e '.ok == false and .detail == "decrypt-failed"' >/dev/null 2>&1 && [ "$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)" = "$DIS_BEFORE" ]; then
  ok "6a. a frame sealed under the wrong key -> decrypt-failed and nothing changed"
else
  bad "6a. forgery ack: $ACK"
fi
send_cmd 11 "$(cmd_json hook-toggle '{"id":"dream-notice","enabled":false}')"
sleep 1.5
if [ "$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)" = "$DIS_BEFORE" ] && grep -q 'non-increasing seq' "$CLIENT_OUT" "$TMPROOT/client.out" 2>/dev/null || grep -q 'non-increasing' "$CLIENT_OUT"; then
  ok "6b. a genuine frame replaying seq 11 is rejected by the replay guard and changes nothing"
else
  bad "6b. replayed seq: hooks-disabled='$(cat "$HEIMDALL_HOME/hooks-disabled" 2>/dev/null)'"
fi

# 7. a genuine send-message still works after the abuse
send_cmd 13 "$(jq -cn '{action:"send-message", params:{text:"still here"}}')"
ACK="$(wait_for_ack_of_seq "$LOG/frames.ndjson" "$KEY_B64" 13 10 1)"
if printf '%s' "$ACK" | jq -e '.ok == true and (.id | type == "string")' >/dev/null 2>&1; then ok "7. after all of that a genuine send-message still returns {ok:true, id}"; else bad "7. send-message ack: $ACK"; fi

# 8. audit
AUD="$REPO_T/.heimdall/ui/controls-audit.jsonl"
if [ -f "$AUD" ] && jq -e -s 'length >= 10 and all(.[]; (.device | test("^[0-9a-f]{8}$")) and .via == "relay" and (.seq | type == "number") and has("text") == false and has("rid") == false and ((.params | keys) - ["id","enabled","mode","confirm"]) == [])' "$AUD" >/dev/null 2>&1; then
  ok "8. the audit log holds a line per command: device = 8 hex of the bound key, via relay, the seq, whitelisted params only"
else
  bad "8. audit log: $(head -c 400 "$AUD" 2>/dev/null)"
fi

# 9. the schedule held: not one command was refused for rate (a charged frame sent with a plain send_cmd, or a retuned
#    budget the schedule did not follow, shows up here by name instead of as a cascade of unrelated acks)
if [ -f "$AUD" ] && jq -e -s 'all(.[]; .detail != "rate-limited")' "$AUD" >/dev/null 2>&1; then
  ok "9. no command was refused rate-limited: the overall budget was spent on the schedule, not on the speed of the box"
else
  bad "9. rate-limited commands in the audit log: $(jq -c 'select(.detail == "rate-limited") | {seq, action}' "$AUD" 2>/dev/null | head -c 400)"
fi

# 10. the expand gate over the sealed transport (CP2): launch-session / pr-merge are reserved expand actions -- refused
#    not-allowed while the laptop's switches are off, recorded twice (controls-audit.jsonl AND relay-events.jsonl), never with
#    the prompt or a path, and the sealed state frame carries remote_actions + launch without a path
MARK="RELAY-PROMPT-MARKER-$$"
PAYLOAD_L="$(jq -cn --arg m "$MARK" '{rid:"L-1",repo:"r-0000",branch:"feat/x",prompt:($m + " /etc/hosts")}')"
send_charged 14 "$(cmd_json launch-session "$PAYLOAD_L")"
ACK="$(ack_of 14)"
if printf '%s' "$ACK" | jq -e '.ok == false and .of_seq == 14 and .detail == "not-allowed"' >/dev/null 2>&1; then ok "10a launch-session with the switch off -> {ok:false, detail:not-allowed}"; else bad "10a launch-session ack: $ACK"; fi
send_charged 15 "$(cmd_json pr-merge '{"rid":"M-1","number":12,"method":"squash"}')"
ACK="$(ack_of 15)"
if printf '%s' "$ACK" | jq -e '.ok == false and .of_seq == 15 and .detail == "not-allowed"' >/dev/null 2>&1; then ok "10b pr-merge with the switch off -> {ok:false, detail:not-allowed}"; else bad "10b pr-merge ack: $ACK"; fi
EVT="$REPO_T/.heimdall/app/relay-events.jsonl"
if jq -e -s '[.[] | select(.event == "remote-action")] | length == 2 and all(.[]; (.device | test("^[0-9a-f]{8}$")) and .ok == false and .detail == "not-allowed" and .repo == null and .ref == null and (.action == "launch-session" or .action == "pr-merge"))' "$EVT" >/dev/null 2>&1 \
   && jq -e -s '[.[] | select(.action == "launch-session" or .action == "pr-merge")] | length == 2 and all(.[]; .params == {} and .detail == "not-allowed" and .via == "relay" and (.seq | type == "number") and (has("rid") | not))' "$AUD" >/dev/null 2>&1; then
  ok "10c each refusal is ONE remote-action line in relay-events.jsonl (device = 8 hex of the bound key) and ONE line in controls-audit.jsonl (no params)"
else
  bad "10c logs: $(grep remote-action "$EVT" 2>/dev/null | head -c 500)"
fi
if ! grep -rq "$MARK" "$REPO_T/.heimdall" "$HEIMDALL_HOME" 2>/dev/null; then ok "10d the prompt text is in no log and no file under .heimdall"; else bad "10d the prompt text leaked to disk"; fi
i=0; ST9=""
while [ "$i" -lt 30 ]; do
  ST9="$(newest_state "$LOG/frames.ndjson" "$KEY_B64" 2)"
  printf '%s' "$ST9" | jq -e '(.state.remote_actions.recent | length) >= 2' >/dev/null 2>&1 && break
  sleep 0.5; i=$((i + 1))
done
if printf '%s' "$ST9" | jq -e '.state.remote_actions.v == 1 and .state.remote_actions.launch_enabled == false and .state.remote_actions.merge_enabled == false and (.state.remote_actions.recent | length) >= 2 and (.state.remote_actions.recent[0] | keys == ["action","at","detail","device","ok","repo_label"]) and .state.launch == {"v":1,"enabled":false}' >/dev/null 2>&1; then
  ok "10e the sealed state frame carries remote_actions (both switches off, the refusals as recent rows) and launch {v:1, enabled:false}"
else
  bad "10e state frame: $(printf '%s' "$ST9" | jq -c '{remote_actions: .state.remote_actions, launch: .state.launch}' 2>/dev/null | cut -c1-400)"
fi
if ! printf '%s' "$ST9" | jq -c '[.state.remote_actions, .state.launch]' | grep -Eq '/(Users|home|private|tmp|var)/|@'; then ok "10f no absolute path or e-mail in the relayed remote_actions / launch"; else bad "10f a path or e-mail leaked into remote_actions / launch"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
