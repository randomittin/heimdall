#!/usr/bin/env bash
# test/heimdall-phone-deny-relay.test.sh
#
# The relay half of A4's deny-only round: the sealed `decide` command, driven through the REAL
# bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for the Cloudflare
# relay; the paired phone is played by `fake-relay.py device ...`, which seals with the real
# bin/lib/hmd_relay_e2e.py -- nothing about the client is mocked).
#
# Wire shape under test (docs/HANDOFF-TO-HEIMDALL-product-asks.md A4's POST /api/decide, carried
# as a relay command the way `send-message` is):
#     command  {"action":"decide","params":{"id":"p-<8 hex>","decision":"deny"}}
#     ack ok   {"ok":true,"of_seq":N,"id":"p-<8 hex>","decision":"deny"}
#     ack no   {"ok":false,"of_seq":N,"detail":"unknown-id"|"already-decided"|"expired"|
#                                               "allow-not-permitted"|"bad-decision"|"decrypt-failed"}
#
# The properties, asserted head-on:
#   0. a pending request reaches the phone in the sealed state frame (`approvals`, the doc's six
#      keys, nothing else) and leaves it once decided;
#   1. a deny from the paired device lands in the decision store and is acked ok with the id;
#   2. a replay of that deny (fresh seq) is `already-decided`;
#   3. an `allow` is refused (`allow-not-permitted`), writes nothing, the request stays pending;
#   4. an unknown id is `unknown-id`; malformed params are `bad-decision`; nothing is written;
#   5. a frame NOT sealed under the paired session key (a forgery) is `decrypt-failed` and changes
#      nothing -- only sealed E2E commands from the bound device count;
#   6. a genuine frame whose seq was already used is rejected by the replay guard and changes nothing;
#   7. after all of that abuse a genuine deny still works;
#   9. the vocabulary is closed: nothing but `decide` + `deny` does anything -- an `approve`
#      decision value, an `approve` action and a `stop` action are all refused and change nothing;
#  10. the whole loop, nothing stubbed: the real bin/heimdall-phone-deny raises a request, the phone
#      sees it in the sealed state frame, a sealed deny is acked ok and the hook blocks the action;
#      and when the window runs out untouched a late sealed deny is acked `expired`.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are a temp dir, every process this suite starts is reaped on
# EXIT, every wait is a bounded poll.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_CLIENT="$REPO/bin/heimdall-relay-client"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"
DEC_LIB="$REPO/bin/lib/companion_ui_decisions.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-phone-deny-relay (sealed decide command through the real relay client)"

for f in "$RELAY_CLIENT" "$FAKE_RELAY" "$E2E_MOD" "$DEC_LIB"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID

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

wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Decrypts every sender=hmd envelope in FILE and prints the plaintext of the first whose of_seq is
# WANT (one JSON line); exit 1 on timeout. of_seq lives inside the sealed payload, so an ack can
# only be found by opening each frame. With ONLY_OK=1 an ack that is not {ok:true} is skipped --
# the way to tell a genuine command's ack from an earlier forgery's that carries the same of_seq.
wait_for_ack_of_seq() {
  local file="$1" key_b64="$2" want="$3" secs="${4:-10}" only_ok="${5:-0}"
  python3 - "$file" "$key_b64" "$want" "$secs" "$E2E_MOD" "$only_ok" <<'PYEOF'
import sys, json, time, base64
from importlib.util import spec_from_file_location, module_from_spec

file_path, key_b64, want_s, secs_s, e2e_path, only_ok = sys.argv[1:7]
want = int(want_s)
deadline = time.time() + float(secs_s)
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
while True:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") != "hmd":
            continue
        try:
            plaintext = e2e.open_(key, env["seq"], "hmd", env.get("nonce"), env.get("ciphertext"))
            obj = json.loads(plaintext.decode("utf-8"))
        except Exception:
            continue
        if obj.get("of_seq") == want and (only_ok != "1" or obj.get("ok") is True):
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PYEOF
}

# Decrypts the sealed `state` frames the client publishes and waits until the NEWEST one's
# `approvals` slice does (MODE=has) / does not (MODE=lacks) carry request WANT, or (MODE=summary)
# carries one whose summary is WANT. Prints the matching entry as one JSON line (has, summary), or
# the whole slice (lacks); exit 1 on timeout. Only frames not yet seen are opened, so a long log does
# not make every poll quadratic.
wait_for_approvals_state() {
  local file="$1" key_b64="$2" mode="$3" want="$4" secs="${5:-15}"
  python3 - "$file" "$key_b64" "$mode" "$want" "$secs" "$E2E_MOD" <<'PYEOF'
import sys, json, time, base64
from importlib.util import spec_from_file_location, module_from_spec

file_path, key_b64, mode, want, secs_s, e2e_path = sys.argv[1:7]
deadline = time.time() + float(secs_s)
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
seen_lines = 0
while True:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    fresh, seen_lines = lines[seen_lines:], len(lines)
    newest = None
    for line in fresh:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") == "hmd" and env.get("type") == "state":
            newest = env
    if newest is not None:
        try:
            plain = e2e.open_(key, newest["seq"], "hmd", newest.get("nonce"), newest.get("ciphertext"))
            slice_ = json.loads(plain.decode("utf-8"))["state"].get("approvals")
        except Exception:
            slice_ = None
        if isinstance(slice_, list):
            field = "summary" if mode == "summary" else "id"
            mine = [e for e in slice_ if isinstance(e, dict) and e.get(field) == want]
            if mode in ("has", "summary") and mine:
                sys.stdout.write(json.dumps(mine[0]) + "\n")
                sys.exit(0)
            if mode == "lacks" and not mine:
                sys.stdout.write(json.dumps(slice_) + "\n")
                sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.3)
PYEOF
}

# new_request <repo> -> prints a fresh pending request id and keeps it heartbeating (as the hook
# would) until the suite ends.
new_request() {
  local repo="$1" out
  out="$(python3 - "$DEC_LIB" "$repo" <<'PYEOF'
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("dec", sys.argv[1])
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
rec = D.request(sys.argv[2], "Bash", "git push origin main", 120)
beat = ("import importlib.util,sys,time\n"
        "s=importlib.util.spec_from_file_location('dec',sys.argv[1]);D=importlib.util.module_from_spec(s);s.loader.exec_module(D)\n"
        "while True:\n    D.heartbeat(sys.argv[2],sys.argv[3]);time.sleep(0.5)\n")
p = subprocess.Popen([sys.executable, "-c", beat, sys.argv[1], sys.argv[2], rec["id"]],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(rec["id"], p.pid)
PYEOF
)"
  PIDS+=("${out#* }")
  printf '%s' "${out%% *}"
}

decision_file_exists() { [ -e "$1/.heimdall/ui/approvals/$2.decision" ]; }
is_pending() {
  python3 - "$DEC_LIB" "$1" "$2" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dec", sys.argv[1])
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
sys.exit(0 if sys.argv[3] in [e["id"] for e in D.pending(sys.argv[2])] else 1)
PYEOF
}

REPO_T="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
( cd "$REPO_T" && git init -q . 2>/dev/null \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true

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
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_RELAY" --repo "$REPO_T" --ui-port "$PORT_UI" \
  >"$CLIENT_OUT" 2>"$TMPROOT/client.err" &
CLIENT_PID=$!
PIDS+=("$CLIENT_PID")

if wait_for "$CLIENT_OUT" '"event":"pair_init"' 10 && wait_for "$CLIENT_OUT" '"event":"device_bound"' 10; then
  ok "setup: the real relay client paired and bound the fake device"
else
  bad "setup: relay client never reached device_bound: $(cat "$TMPROOT/client.err" 2>/dev/null)"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

SID="$(jq -r 'select(.event=="pair_init") | .qr.session_id' "$CLIENT_OUT" | head -1)"
HMD_PUB="$(jq -r 'select(.event=="pair_init") | .qr.hmd_pubkey' "$CLIENT_OUT" | head -1)"
KEY_B64="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB" --session-id "$SID" | jq -r .key_b64)"
WRONG_KEY_B64="$(python3 -c 'import base64; print(base64.b64encode(bytes(range(32))).decode())')"

CTL_N=0
# send_cmd <seq> <plaintext-json> [key-b64]: seal as the device and queue the frame for the relay
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
ack_of_ok() { wait_for_ack_of_seq "$LOG/frames.ndjson" "$KEY_B64" "$1" 10 1; }
decide_json() { jq -cn --arg id "$1" --arg d "$2" '{action:"decide", params:{id:$id, decision:$d}}'; }

# 0. a pending request reaches the phone inside the sealed state frame -- the doc's six keys, no more
P1="$(new_request "$REPO_T")"
APPR="$(wait_for_approvals_state "$LOG/frames.ndjson" "$KEY_B64" has "$P1" 20)"
if printf '%s' "$APPR" | jq -e --arg id "$P1" \
     'keys == ["expires_at","id","requested_at","risk","summary","tool"] and .id == $id and .tool == "Bash" and .summary == "git push origin main" and .risk == "high"' >/dev/null 2>&1; then
  ok "0. the pending request is in the sealed state frame's approvals slice with exactly the doc's six keys"
else
  bad "0. approvals entry missing or wrong shape in the sealed state frame: ${APPR:-<no frame>}"
fi

# 1. a deny from the paired device is recorded and acked ok
send_cmd 1 "$(decide_json "$P1" deny)"
ACK="$(ack_of 1)"
if printf '%s' "$ACK" | jq -e --arg id "$P1" '.ok == true and .id == $id and .decision == "deny" and .of_seq == 1' >/dev/null 2>&1; then
  ok "1. decide/deny from the paired device -> ack {ok:true, id, decision:deny}"
else
  bad "1. deny ack wrong: $ACK"
fi
if decision_file_exists "$REPO_T" "$P1" && ! is_pending "$REPO_T" "$P1"; then
  ok "1b. the decision landed in the store (0600 .decision file) and the request left pending()"
else
  bad "1b. decision file missing, or the request is still pending"
fi
if SLICE="$(wait_for_approvals_state "$LOG/frames.ndjson" "$KEY_B64" lacks "$P1" 20)"; then
  ok "1c. the next sealed state frame no longer lists the decided request (approvals: $SLICE)"
else
  bad "1c. the decided request is still in the sealed state frame's approvals slice"
fi

# 2. a replay of the deny with a fresh seq is already-decided
send_cmd 2 "$(decide_json "$P1" deny)"
ACK="$(ack_of 2)"
if printf '%s' "$ACK" | jq -e '.ok == false and .detail == "already-decided" and (has("id") | not)' >/dev/null 2>&1; then
  ok "2. a replayed deny (new seq) -> {ok:false, detail:already-decided}"
else
  bad "2. replay ack wrong: $ACK"
fi

# 3. allow is refused and writes nothing
P2="$(new_request "$REPO_T")"
send_cmd 3 "$(decide_json "$P2" allow)"
ACK="$(ack_of 3)"
if printf '%s' "$ACK" | jq -e '.ok == false and .detail == "allow-not-permitted"' >/dev/null 2>&1; then
  ok "3. decide/allow -> {ok:false, detail:allow-not-permitted}"
else
  bad "3. allow ack wrong: $ACK"
fi
if ! decision_file_exists "$REPO_T" "$P2" && is_pending "$REPO_T" "$P2"; then
  ok "3b. the refused allow wrote no decision; the request is still pending (the phone cannot approve)"
else
  bad "3b. an allow left a decision behind or removed the pending request"
fi

# 4. unknown id, malformed params
send_cmd 4 "$(decide_json p-00000000 deny)"
ACK="$(ack_of 4)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "unknown-id"' >/dev/null 2>&1 \
  && ok "4. an unknown id -> detail unknown-id" || bad "4. unknown-id ack wrong: $ACK"
send_cmd 5 "$(jq -cn --arg id "$P2" '{action:"decide", params:{id:$id}}')"
ACK="$(ack_of 5)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "4b. params without a decision -> detail bad-decision" || bad "4b. missing-decision ack wrong: $ACK"
send_cmd 6 '{"action":"decide","params":"deny"}'
ACK="$(ack_of 6)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "4c. params that is not an object -> detail bad-decision" || bad "4c. non-object params ack wrong: $ACK"
send_cmd 7 '{"action":"decide"}'
ACK="$(ack_of 7)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "4d. no params at all -> detail bad-decision" || bad "4d. no-params ack wrong: $ACK"
send_cmd 8 "$(jq -cn --arg id "$P2" '{action:"decide", params:{id:$id, decision:7}}')"
ACK="$(ack_of 8)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "4e. a non-string decision -> detail bad-decision" || bad "4e. non-string decision ack wrong: $ACK"
if ! decision_file_exists "$REPO_T" "$P2" && is_pending "$REPO_T" "$P2"; then
  ok "4f. none of the malformed commands touched the pending request"
else
  bad "4f. a malformed command changed the pending request"
fi

# 5. a forgery (sealed under a key that is not the paired session key) changes nothing
send_cmd 9 "$(decide_json "$P2" deny)" "$WRONG_KEY_B64"
ACK="$(ack_of 9)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "decrypt-failed"' >/dev/null 2>&1 \
  && ok "5. a frame not sealed under the session key -> detail decrypt-failed" || bad "5. forgery ack wrong: $ACK"
if ! decision_file_exists "$REPO_T" "$P2" && is_pending "$REPO_T" "$P2"; then
  ok "5b. the forged deny changed nothing (only the bound device's sealed commands count)"
else
  bad "5b. a forged frame produced a decision"
fi

# 6. a genuine frame replayed at a seq already used is rejected by the replay guard
send_cmd 4 "$(decide_json "$P2" deny)"
if wait_for "$CLIENT_OUT" 'non-increasing seq' 10; then
  ok "6. a sealed deny re-sent at an already-used seq -> rejected (non-increasing seq)"
else
  bad "6. the replay-guard error never appeared"
fi
sleep 1
if ! decision_file_exists "$REPO_T" "$P2" && is_pending "$REPO_T" "$P2"; then
  ok "6b. the replayed deny changed nothing"
else
  bad "6b. a replayed frame produced a decision"
fi

# 7. after all of that, a genuine deny still works (the seq the forgery tried was never burned).
# The forgery's ack also carries of_seq 9, so only an {ok:true} ack can be this command's.
send_cmd 9 "$(decide_json "$P2" deny)"
ACK="$(ack_of_ok 9)"
if printf '%s' "$ACK" | jq -e --arg id "$P2" '.ok == true and .id == $id and .decision == "deny"' >/dev/null 2>&1 && decision_file_exists "$REPO_T" "$P2"; then
  ok "7. a genuine deny after the abuse still lands (acked ok, decision recorded)"
else
  bad "7. the genuine deny after the abuse failed: ${ACK:-<no ok ack>}"
fi

if jq -e 'select(.event=="command" and .action=="decide")' "$CLIENT_OUT" >/dev/null 2>&1; then
  ok "8. the client logs each decide as a {event:command, action:decide} line"
else
  bad "8. no command/decide event line in the client's stdout"
fi

# 9. the vocabulary is closed: only {action: decide, decision: deny} does anything
P3="$(new_request "$REPO_T")"
send_cmd 10 "$(decide_json "$P3" approve)"
ACK="$(ack_of 10)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "9. decision \"approve\" -> detail bad-decision (there is no approve)" || bad "9. approve decision ack wrong: $ACK"
send_cmd 11 "$(jq -cn --arg id "$P3" '{action:"approve", params:{id:$id}}')"
ACK="$(ack_of 11)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "not-implemented"' >/dev/null 2>&1 \
  && ok "9b. action \"approve\" -> detail not-implemented" || bad "9b. approve action ack wrong: $ACK"
send_cmd 12 "$(jq -cn --arg id "$P3" '{action:"stop", params:{id:$id}}')"
ACK="$(ack_of 12)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "not-implemented"' >/dev/null 2>&1 \
  && ok "9c. action \"stop\" -> detail not-implemented (stop is deferred this round)" || bad "9c. stop action ack wrong: $ACK"
send_cmd 13 "$(decide_json "$P3" Deny)"
ACK="$(ack_of 13)"
printf '%s' "$ACK" | jq -e '.ok == false and .detail == "bad-decision"' >/dev/null 2>&1 \
  && ok "9d. decision \"Deny\" (case-varied) -> detail bad-decision (exact vocabulary)" || bad "9d. case-varied decision ack wrong: $ACK"
if ! decision_file_exists "$REPO_T" "$P3" && is_pending "$REPO_T" "$P3"; then
  ok "9e. none of the four left a decision behind; the request is still pending"
else
  bad "9e. a refused command changed the pending request"
fi

# 10. the whole loop with nothing stubbed: the REAL hook raises a request, the phone SEES it in the
# sealed state frame, DENIES it with a sealed command, and the hook blocks the action. Then the
# converse: a window that runs out untouched leaves a late sealed deny `expired` -- never an ack for
# an action that already went through.
HOOK="$REPO/bin/heimdall-phone-deny"
printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":%s,"relay":"http://127.0.0.1:%s","started_at":"t"}' \
  "$$" "$CLIENT_PID" "$PORT_UI" "$PORT_RELAY" > "$REPO_T/.heimdall/app/connect.json"
jq -cn --arg d "$REPO_T" '{hook_event_name:"PreToolUse",session_id:"s",cwd:$d,tool_name:"Bash",tool_input:{command:"git push origin e2e-deny"}}' > "$TMPROOT/e2e.payload"
env -u CLAUDE_CODE_ENTRYPOINT HMD_PHONE_DENY=1 HMD_PHONE_DENY_WINDOW_S=40 "$HOOK" --repo "$REPO_T" \
  < "$TMPROOT/e2e.payload" > "$TMPROOT/e2e.hook.out" 2> "$TMPROOT/e2e.hook.err" &
E2E_HOOK_PID=$!; PIDS+=("$E2E_HOOK_PID")
ENTRY="$(wait_for_approvals_state "$LOG/frames.ndjson" "$KEY_B64" summary "git push origin e2e-deny" 30)"
E2E_ID="$(printf '%s' "$ENTRY" | jq -r '.id // empty')"
if [ -n "$E2E_ID" ] && printf '%s' "$ENTRY" | jq -e '.tool == "Bash" and .risk == "high"' >/dev/null 2>&1; then
  ok "10. the phone sees the REAL hook's request in the sealed state frame (id $E2E_ID)"
else
  bad "10. the hook's request never reached the sealed state frame: ${ENTRY:-<none>} err=[$(cat "$TMPROOT/e2e.hook.err")] relay.json=[$(cat "$REPO_T/.heimdall/app/relay.json" 2>/dev/null)]"
fi
send_cmd 14 "$(decide_json "${E2E_ID:-p-00000000}" deny)"
ACK="$(ack_of_ok 14)"
i=0; while kill -0 "$E2E_HOOK_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if printf '%s' "$ACK" | jq -e --arg id "$E2E_ID" '.ok == true and .id == $id and .decision == "deny"' >/dev/null 2>&1 \
   && jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' "$TMPROOT/e2e.hook.out" >/dev/null 2>&1; then
  ok "10b. the sealed deny is acked ok AND the hook prints the PreToolUse deny (the action is blocked)"
else
  bad "10b. ack=[${ACK:-<none>}] hook out=[$(cat "$TMPROOT/e2e.hook.out")] err=[$(cat "$TMPROOT/e2e.hook.err")]"
fi
jq -cn --arg d "$REPO_T" '{hook_event_name:"PreToolUse",session_id:"s",cwd:$d,tool_name:"Bash",tool_input:{command:"git push origin e2e-timeout"}}' > "$TMPROOT/e2e.payload2"
env -u CLAUDE_CODE_ENTRYPOINT HMD_PHONE_DENY=1 HMD_PHONE_DENY_WINDOW_S=2 "$HOOK" --repo "$REPO_T" \
  < "$TMPROOT/e2e.payload2" > "$TMPROOT/e2e.hook2.out" 2> "$TMPROOT/e2e.hook2.err"
LATE_ID=""
for f in "$REPO_T"/.heimdall/ui/approvals/p-*.decision; do
  if jq -e '.decision == "timeout"' "$f" >/dev/null 2>&1; then LATE_ID="$(basename "$f" .decision)"; fi
done
send_cmd 15 "$(decide_json "${LATE_ID:-p-00000000}" deny)"
ACK="$(ack_of 15)"
if [ ! -s "$TMPROOT/e2e.hook2.out" ] && [ -n "$LATE_ID" ] && printf '%s' "$ACK" | jq -e '.ok == false and .detail == "expired"' >/dev/null 2>&1 \
   && jq -e '.decision == "timeout"' "$REPO_T/.heimdall/ui/approvals/$LATE_ID.decision" >/dev/null 2>&1; then
  ok "10c. window ran out untouched -> the hook printed nothing, and a late sealed deny is acked detail:expired (nothing recorded)"
else
  bad "10c. converse wrong: hook out=[$(cat "$TMPROOT/e2e.hook2.out")] late_id=[$LATE_ID] ack=[${ACK:-<none>}]"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
