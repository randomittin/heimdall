#!/usr/bin/env bash
# test/heimdall-app-relay-push-ws.test.sh -- part 3/3 of the heimdall-app-relay acceptance suite:
# scenarios W-Z (ordering and digest rules, push registration over sealed commands, a stale-seq command
# answered not dropped, hmd's leg as a hibernatable WebSocket). Split out of
# test/heimdall-app-relay.test.sh (see its header); the shared prelude is test/lib/app-relay-common.sh.

# shellcheck disable=SC2034  # RELAY_SUITE_TITLE is read by test/lib/app-relay-common.sh (sourced next), never in this file
RELAY_SUITE_TITLE="heimdall-app-relay (bin/heimdall-relay-client + hmd app connect --relay oracle) -- part 3/3: push registration, WebSocket leg"
# shellcheck source=/dev/null  # sibling helper test/lib/app-relay-common.sh; not followed (no -x)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/app-relay-common.sh"

# ── Scenario W: the ordering and digest rules, deterministically. Drives
# send_hmd_frame and _tick_once with a stub transport that can hold one frame
# type's POST until released -- threads, no network, no sleeping for a race to
# resolve. What the real-client scenarios above show end to end, one rule at a time ─
if [ "$E2E_PRESENT" = true ]; then
  W_OUT="$TMPROOT/w.out"
  python3 - "$RELAY_CLIENT_RUN" >"$W_OUT" 2>"$TMPROOT/w.err" <<'PYEOF'
import argparse
import contextlib
import io
import os
import sys
import tempfile
import threading
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path = sys.argv[1]
loader = SourceFileLoader("hmd_relay_client_order_harness", client_path)
mod = module_from_spec(spec_from_loader(loader.name, loader))
loader.exec_module(mod)
results = {}


class Stub:
    """Stands in for RelayClient.send_frame_envelope: records every call, holds the POSTs of the
    type named by `hold` until `release` is set, answers the rest from `outcomes` (None: the POST
    failed, False: relay answered, no phone attached, True: delivered; default True)."""

    def __init__(self, hold=None, outcomes=()):
        self.hold = hold
        self.release = threading.Event()
        self.entered = {"state": threading.Event(), "ack": threading.Event()}
        self.calls = []  # (type, seq)
        self.outcomes = list(outcomes)
        self.lock = threading.Lock()

    def __call__(self, type_, nonce, ciphertext, seq, **kwargs):
        with self.lock:
            self.calls.append((type_, seq))
        self.entered[type_].set()
        if type_ == self.hold:
            self.release.wait(10)
        with self.lock:
            outcome = self.outcomes.pop(0) if self.outcomes else True
        return outcome, 321


class Cache:
    """Stands in for StateCache: whatever (state, digest) it holds now."""

    def __init__(self, digest="d1"):
        self.digest = digest

    def latest(self):
        return {"n": self.digest}, self.digest


class Waits:
    """Stands in for RelayClient.stop_event: records every wait, never sleeps, never stops."""

    def __init__(self):
        self.waits = []

    def is_set(self):
        return False

    def wait(self, timeout=None):
        self.waits.append(timeout)
        return False


def make_client(repo, stub):
    args = argparse.Namespace(relay="http://127.0.0.1:1", repo=repo, ui_port=0, public_host=None,
                              status_file=os.path.join(repo, "status.json"), tick_s=2.0)
    client = mod.RelayClient(args)
    client.session_id = "sess-order"
    client.token = "token-order"
    client.session_key = os.urandom(32)
    client.send_frame_envelope = stub
    client.cache = Cache()
    return client


def start(target, *args):
    t = threading.Thread(target=target, args=args, daemon=True)
    t.start()
    return t


def finished_within(thread, seconds):
    thread.join(seconds)
    return not thread.is_alive()


def csv(values):
    return ",".join(str(v) for v in values)


def case_w1(repo):
    """an ack POSTed while a state POST is held is not held with it"""
    stub = Stub(hold="state")
    client = make_client(repo, stub)
    state = start(client.send_hmd_frame, "state", {"state": {}})
    stub.entered["state"].wait(5)
    began = time.monotonic()
    ack = start(client.send_hmd_frame, "ack", {"ok": True, "of_seq": 1})
    done = finished_within(ack, 2.0)
    results["w1_ack_done_while_state_held"] = done
    results["w1_ack_under_500ms"] = done and (time.monotonic() - began) < 0.5
    stub.release.set()
    state.join(5)
    ack.join(5)
    results["w1_calls"] = csv("%s=%d" % c for c in stub.calls)


def case_w2(repo):
    """a state frame takes no seq and sends nothing while an ack is in flight, retries included"""
    stub = Stub(hold="ack")
    client = make_client(repo, stub)
    ack = start(client.send_hmd_frame, "ack", {"ok": True, "of_seq": 1})
    stub.entered["ack"].wait(5)
    state = start(client.send_hmd_frame, "state", {"state": {}})
    time.sleep(0.4)
    results["w2_state_sent_early"] = any(c[0] == "state" for c in stub.calls)
    results["w2_next_seq_while_ack_held"] = client.hmd_seq
    stub.release.set()
    ack.join(5)
    state.join(5)
    results["w2_calls"] = csv("%s=%d" % c for c in stub.calls)


def case_w3(repo):
    """a state frame an ack overtook is not recorded as sent: the next tick re-sends it"""
    stub = Stub(hold="state")
    client = make_client(repo, stub)
    tick = start(client._tick_once)
    stub.entered["state"].wait(5)
    ack = start(client.send_hmd_frame, "ack", {"ok": True, "of_seq": 1})
    results["w3_ack_done_while_state_held"] = finished_within(ack, 2.0)
    stub.release.set()
    tick.join(5)
    ack.join(5)
    results["w3_digest_after_overtake"] = client.last_sent_digest
    stub.hold = None
    client._tick_once()
    results["w3_calls"] = csv("%s=%d" % c for c in stub.calls)
    results["w3_digest_after_resend"] = client.last_sent_digest


def case_w4(repo):
    """failed POSTs are re-sent on every tick, after a bounded backoff that a success resets"""
    stub = Stub(outcomes=[None] * 5 + [True])
    client = make_client(repo, stub)
    client.stop_event = Waits()
    for _ in range(6):
        client._tick_once()
    results["w4_calls"] = len(stub.calls)
    results["w4_waits"] = csv("%.2f" % w for w in client.stop_event.waits)
    results["w4_digest_after_success"] = client.last_sent_digest
    client._tick_once()
    results["w4_calls_after_unchanged_tick"] = len(stub.calls)
    client.cache.digest = "d2"
    stub.outcomes = [None, True]
    client._tick_once()
    client._tick_once()
    results["w4_wait_after_reset"] = "%.2f" % client.stop_event.waits[-1] if client.stop_event.waits else "none"
    results["w4_digest_after_second"] = client.last_sent_digest


def case_w5(repo):
    """delivered=false (no phone attached) is an answer, not a failure: recorded, never retried"""
    stub = Stub(outcomes=[False])
    client = make_client(repo, stub)
    client.stop_event = Waits()
    client._tick_once()
    client._tick_once()
    results["w5_calls"] = len(stub.calls)
    results["w5_digest"] = client.last_sent_digest
    results["w5_waits"] = len(client.stop_event.waits)


def case_w6(repo):
    """a device_bound arriving while a state POST is in flight still forces the next tick to re-send"""
    stub = Stub(hold="state")
    client = make_client(repo, stub)
    priv, pub = mod.E2E.generate_keypair()
    pub_b64 = mod.E2E.pub_b64(pub)
    client.device_pub = mod.E2E.pub_from_b64(pub_b64)
    tick = start(client._tick_once)
    stub.entered["state"].wait(5)
    client._handle_envelope({"sender": "relay", "type": "device_bound",
                             "payload": {"device_pubkey": pub_b64, "bound_at": 1}})
    stub.release.set()
    tick.join(5)
    results["w6_digest_after_rebind"] = client.last_sent_digest
    stub.hold = None
    client._tick_once()
    results["w6_calls"] = csv("%s=%d" % c for c in stub.calls)


with contextlib.redirect_stdout(io.StringIO()):
    for case in (case_w1, case_w2, case_w3, case_w4, case_w5, case_w6):
        with tempfile.TemporaryDirectory() as repo:
            try:
                case(repo)
            except Exception as e:  # a case that crashes is a result of its own, not the end of the others
                results[case.__name__ + "_crashed"] = "%s: %s" % (type(e).__name__, e)
for key, value in results.items():
    print("RESULT %s %s" % (key, value))
sys.exit(0)
PYEOF
  W_RC=$?

  if [ "$W_RC" -eq 0 ] && ! grep -q '^RESULT case_w[0-9]*_crashed ' "$W_OUT"; then
    ok "scenario W: ordering/digest harness ran to completion, no case crashed"
  else
    bad "scenario W: ordering/digest harness exited $W_RC or a case crashed -- $(grep '_crashed ' "$W_OUT" | head -3) $(tail -3 "$TMPROOT/w.err")"
  fi

  check_res "$W_OUT" w1_ack_done_while_state_held True "W/w1: an ack sent while a state POST is held completes without waiting for it"
  check_res "$W_OUT" w1_ack_under_500ms True "W/w1: ...in under 500 ms"
  check_res "$W_OUT" w1_calls "state=1,ack=2" "W/w1: ...the state frame took seq 1, the ack seq 2 (seq stays strictly increasing)"

  check_res "$W_OUT" w2_state_sent_early False "W/w2: a state frame sends nothing while an ack is in flight"
  check_res "$W_OUT" w2_next_seq_while_ack_held 2 "W/w2: ...and has not even taken a seq (an ack's retries are never overtaken by a newer frame)"
  check_res "$W_OUT" w2_calls "ack=1,state=2" "W/w2: ...it takes seq 2 only once the ack is done"

  check_res "$W_OUT" w3_ack_done_while_state_held True "W/w3: the ack completed while the older state POST was held"
  check_res "$W_OUT" w3_digest_after_overtake None "W/w3: the state frame the ack overtook is NOT recorded as sent"
  check_res "$W_OUT" w3_calls "state=1,ack=2,state=3" "W/w3: ...the next tick re-sends it under a seq above the ack's"
  check_res "$W_OUT" w3_digest_after_resend d1 "W/w3: ...and that re-send is recorded"

  check_res "$W_OUT" w4_calls 6 "W/w4: five failed POSTs and a success -> six sends of the same digest (a failed POST is re-sent, not forgotten)"
  check_res "$W_OUT" w4_waits "0.25,1.00,2.00,5.00,5.00" "W/w4: ...with a bounded backoff 0.25, 1, 2, 5 s then held at 5 s"
  check_res "$W_OUT" w4_digest_after_success d1 "W/w4: the digest is recorded only once a POST got an answer"
  check_res "$W_OUT" w4_calls_after_unchanged_tick 6 "W/w4: ...and an unchanged digest is then not sent again (INV-22)"
  check_res "$W_OUT" w4_wait_after_reset "0.25" "W/w4: a success resets the backoff to its first step"
  check_res "$W_OUT" w4_digest_after_second d2 "W/w4: ...and the next digest is recorded after its retry"

  check_res "$W_OUT" w5_calls 1 "W/w5: delivered=false is one send, then silence -- it is not a failure and must not retry"
  check_res "$W_OUT" w5_digest d1 "W/w5: ...its digest is recorded as sent"
  check_res "$W_OUT" w5_waits 0 "W/w5: ...with no backoff"

  check_res "$W_OUT" w6_digest_after_rebind None "W/w6: a device_bound that lands mid-POST still re-arms the next tick (the POST's success does not overwrite it)"
  check_res "$W_OUT" w6_calls "state=1,state=2" "W/w6: ...so the state is sent again after the rebind"
  if [ ! -s "$TMPROOT/w.err" ]; then
    ok "W: the harness wrote nothing to stderr"
  else
    bad "W: the harness wrote to stderr: $(head -5 "$TMPROOT/w.err")"
  fi
else
  skip "scenario W (frame ordering, digest rules): bin/lib/hmd_relay_e2e.py absent -- needs real seal"
fi

# ── Scenario X: push registration over sealed commands (hmdapp's docs/HANDOFF-TO-HEIMDALL-push-notifications.md PN2
# and section 5 of its spec). The REAL client against the fake relay: every state frame lists push-v1 in its caps; the
# phone's sealed register_push / app_state / unregister_push are acked with the spec's exact shapes and land in
# <repo>/.heimdall/app/push.json (file 0600, directory 0700); malformed ones are refused with the spec's detail and
# write nothing; registrations an earlier session left behind are gone at the first device_bound, while a same-device
# repeat keeps them and a different device's frame is refused; and the Expo token is in no byte of stdout, stderr, the
# event log, the status file or the relay's request log. The token is assembled at run time (no token-shaped literal
# is committed). test/companion-push-store.test.sh covers the store and every refusal in-process; this is the same
# wire through a real process. X2: HMD_PUSH=0 withdraws the cap and the commands ack push-disabled ──────────────────
# shellcheck disable=SC2153  # REPO is assigned by the sourced test/lib/app-relay-common.sh (not followed without -x)
PUSH_STORE_LIB="$REPO/bin/lib/companion_push_store.py"

x_json_same() {  # x_json_same ACTUAL EXPECTED -- true when the two JSON texts are the same value
  python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null
}

# push_state_of REPO -- what the store reads from REPO, as one JSON line; a well-formed ISO-8601 UTC timestamp is shown as ISO
push_state_of() {
  python3 - "$1" "$PUSH_STORE_LIB" <<'PYEOF'
import json, re, sys
from importlib.util import module_from_spec, spec_from_file_location

repo, path = sys.argv[1:3]
spec = spec_from_file_location("companion_push_store", path)
store = module_from_spec(spec)
spec.loader.exec_module(store)
state = store.load(repo)
iso = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
shown = lambda v: "ISO" if isinstance(v, str) and iso.fullmatch(v) else v
state["app_state_at"] = shown(state["app_state_at"])
for entry in state["tokens"]:
    entry["registered_at"] = shown(entry["registered_at"])
print(json.dumps(state, sort_keys=True))
PYEOF
}

# state_caps_of FRAMES_FILE KEY_B64 -- the caps (JSON) of the newest state frame the relay received
state_caps_of() {
  python3 - "$1" "$2" "$E2E_MOD" <<'PYEOF'
import base64, json, sys
from importlib.util import module_from_spec, spec_from_file_location

frames, key_b64, e2e_path = sys.argv[1:4]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
caps = None
for line in open(frames, encoding="utf-8"):
    try:
        env = json.loads(line)
    except ValueError:
        continue
    if env.get("sender") == "hmd" and env.get("type") == "state":
        caps = json.loads(e2e.unpack_plaintext(e2e.open_(key, env["seq"], "hmd", env["nonce"], env["ciphertext"])))["caps"]
if caps is None:
    sys.exit(1)
print(json.dumps(caps))
PYEOF
}

# command_events_of CLIENT_OUT -- [[action, ok, detail], ...] of every `command` line the client printed, or KEYS-BAD
# when one of them carries anything beyond event/action/ok/detail
command_events_of() {
  python3 - "$1" <<'PYEOF'
import json, sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("event") != "command":
        continue
    if set(e) != {"event", "action", "ok", "detail"}:
        print("KEYS-BAD")
        sys.exit(0)
    rows.append([e["action"], e["ok"], e["detail"]])
print(json.dumps(rows))
PYEOF
}

x_reg_json() {  # x_reg_json TOKEN VERSION -- a register_push command carrying TOKEN
  printf '{"action":"register_push","params":{"v":%s,"provider":"expo","token":"%s","platform":"ios","ref":"%s","label":"api server","events":["question","approval","finished","error","gate_red"]}}' "$2" "$1" "$X_REF"
}
x_unreg_json() {  # x_unreg_json REF
  printf '{"action":"unregister_push","params":{"ref":"%s"}}' "$1"
}
x_redact() { printf '%s' "${1//"$PUSH_TOKEN_X"/<token>}"; }

# x_start_session TAG REPO [COMMAND WORDS...] -- starts a fake relay and the REAL client for REPO, the optional command
# words (an `env ...`) placed in front of it, waits for the pairing, and leaves what the caller needs in XS_*: paths
# XS_LOG XS_CTL XS_OUT XS_ERR, XS_SID, XS_KEY (the session key the phone derives), XS_DEV_PUB, and the pids XS_CLIENT XS_SRV
x_start_session() {
  local tag="$1" repo="$2" port_relay port_ui dev_json dev_priv hmd_pub
  shift 2
  XS_LOG="$TMPROOT/$tag.log"; XS_CTL="$TMPROOT/$tag.ctl"; XS_OUT="$TMPROOT/$tag.client.out"; XS_ERR="$TMPROOT/$tag.client.err"
  mkdir -p "$XS_LOG" "$XS_CTL"
  for flag in ${XS_CTL_FLAGS:-}; do : > "$XS_CTL/$flag"; done  # ctl files that must exist before the client's first connect
  port_relay="$(free_port)"; port_ui="$(free_port)"
  # shellcheck disable=SC2086  # XS_RELAY_ARGS is a deliberately word-split list of extra relay flags
  python3 "$FAKE_RELAY" serve "$port_relay" --log "$XS_LOG" --ctl "$XS_CTL" ${XS_RELAY_ARGS:-} >"$TMPROOT/$tag.srv.out" 2>&1 &
  XS_SRV=$!
  PIDS+=("$XS_SRV")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$port_relay))==0 else 1)" && break
    sleep 0.1
  done
  dev_json="$(python3 "$FAKE_RELAY" device keygen)"
  dev_priv="$(printf '%s' "$dev_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  XS_DEV_PUB="$(printf '%s' "$dev_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$XS_DEV_PUB" > "$XS_CTL/bind-device"
  "$@" "$RELAY_CLIENT_RUN" --relay "${XS_SCHEME:-http}://127.0.0.1:$port_relay" --repo "$repo" --ui-port "$port_ui" >"$XS_OUT" 2>"$XS_ERR" &
  XS_CLIENT=$!
  PIDS+=("$XS_CLIENT")
  wait_for "$XS_OUT" '"event":"pair_init"' 10 || true
  XS_SID="$(python3 -c "
import json
for line in open('$XS_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  hmd_pub="$(python3 -c "
import json
for line in open('$XS_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"
  wait_for "$XS_OUT" '"event":"device_bound"' 10 || true
  XS_KEY="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$dev_priv" --hmd-pub-b64 "$hmd_pub" --session-id "$XS_SID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"
}

if [ "$E2E_PRESENT" = true ]; then
  X_REF="9f3c2a1b7d4e6f80"
  PUSH_TOKEN_X="Exponent""PushToken[$(python3 -c 'print("xX9_-" * 5)')]"
  PUSH_TOKEN_OLD_X="Exponent""PushToken[$(python3 -c 'print("o" * 22)')]"
  X_ENTRY="{\"events\":[\"approval\",\"error\",\"finished\",\"gate_red\",\"question\"],\"label\":\"api server\",\"platform\":\"ios\",\"ref\":\"$X_REF\",\"registered_at\":\"ISO\",\"token\":\"$PUSH_TOKEN_X\"}"

  # what an EARLIER session left behind: a registration, and the app state its phone reported
  REPO_X="$(make_repo)"
  python3 - "$REPO_X" "$PUSH_STORE_LIB" "$PUSH_TOKEN_OLD_X" <<'PYEOF'
import sys
from importlib.util import module_from_spec, spec_from_file_location

repo, path, token = sys.argv[1:4]
spec = spec_from_file_location("companion_push_store", path)
store = module_from_spec(spec)
spec.loader.exec_module(store)
store.register(repo, token, "ios", ref="aaaaaaaaaaaaaaaa", label="last session", events=["error"])
store.set_app_state(repo, "foreground")
PYEOF
  if [ "$(push_state_of "$REPO_X" | python3 -c 'import json,sys; s=json.load(sys.stdin); print(len(s["tokens"]), s["app_state"])')" = "1 foreground" ]; then
    ok "scenario X: an earlier session's registration and reported app state are on disk before this session starts"
  else
    bad "scenario X: the seed registration did not land -- the clearing check below would prove nothing"
  fi

  x_start_session X "$REPO_X" env -u HMD_PUSH
  SID_X="$XS_SID"; KEY_X="$XS_KEY"; DEV_PUB_X="$XS_DEV_PUB"; LOG_X="$XS_LOG"; CTL_X="$XS_CTL"; OUT_X="$XS_OUT"
  CLIENT_X="$XS_CLIENT"; SRV_X="$XS_SRV"
  EVENT_LOG_X="$REPO_X/.heimdall/app/relay-events.jsonl"
  if wait_for "$OUT_X" '"event":"device_bound"' 1 && [ -n "$SID_X" ] && [ -n "$KEY_X" ]; then
    ok "scenario X: relay-client paired (session key derivable)"
  else
    bad "scenario X: relay-client never paired -- the rest of X cannot run: $(tail -3 "$XS_ERR" 2>/dev/null)"
  fi

  if x_json_same "$(push_state_of "$REPO_X")" '{"app_state":"unknown","app_state_at":null,"tokens":[]}'; then
    ok "X: the first device_bound cleared the registration and the app state an earlier session left behind"
  else
    bad "X: the earlier session's registration survived the first device_bound: $(x_redact "$(push_state_of "$REPO_X")")"
  fi

  if wait_for_count "$LOG_X/frames.ndjson" 1 '"type":"state"' 10; then
    X_CAPS="$(state_caps_of "$LOG_X/frames.ndjson" "$KEY_X")"
    if x_json_same "$X_CAPS" '["ask-v1","controls-v1","dash-alert-v1","dash-v1","login-v1","push-digest-v1","push-tile-alert-v1","push-v1","resync","view-v1","z-zlib"]'; then
      ok "X: the state frame the relay received lists controls-v1, push-v1, push-digest-v1 and push-tile-alert-v1 beside login-v1, resync, view-v1 and z-zlib in its caps"
    else
      bad "X: state frame caps are not [ask-v1, controls-v1, dash-alert-v1, dash-v1, login-v1, push-digest-v1, push-tile-alert-v1, push-v1, resync, view-v1, z-zlib]: $X_CAPS"
    fi
  else
    bad "X: no state frame ever reached the relay"
  fi

  # every command is sealed up front; each is moved into the relay's ctl dir only when it is wanted
  x_prepare() { prepare_device_action "$TMPROOT/x.cmd.$1.json" "$SID_X" "$KEY_X" "$1" "$2"; }
  x_queue() { mv "$TMPROOT/x.cmd.$1.json" "$CTL_X/$(printf '%03d' "$1").json"; }
  x_ack() { wait_for_ack_of_seq "$LOG_X/frames.ndjson" "$KEY_X" "$1" 10; }
  x_prepare 1 "$(x_reg_json "$PUSH_TOKEN_X" 1)"
  x_prepare 2 '{"action":"app_state","params":{"state":"active"}}'
  x_prepare 3 '{"action":"app_state","params":{"state":"background"}}'
  x_prepare 4 "$(x_reg_json nope 1)"
  x_prepare 5 "$(x_reg_json "$PUSH_TOKEN_X" 2)"
  x_prepare 6 '{"action":"app_state","params":{"state":"inactive"}}'
  x_prepare 7 '{"action":"register_push","params":"x"}'
  x_prepare 8 "$(x_unreg_json XYZ)"
  x_prepare 9 "$(x_unreg_json "$X_REF")"
  x_prepare 10 "$(x_unreg_json "$X_REF")"

  x_queue 1; X_ACK="$(x_ack 1)"
  if x_json_same "$X_ACK" "{\"ok\":true,\"of_seq\":1,\"ref\":\"$X_REF\",\"events\":[\"approval\",\"error\",\"finished\",\"gate_red\",\"question\"]}"; then
    ok "X: register_push is acked {ok, of_seq, ref, events (sorted)}"
  else
    bad "X: register_push ack is not the spec's shape: $X_ACK"
  fi
  X_NOW="$(push_state_of "$REPO_X")"
  if x_json_same "$X_NOW" "{\"app_state\":\"unknown\",\"app_state_at\":null,\"tokens\":[$X_ENTRY]}"; then
    ok "X: the registration is in push.json -- token, platform, ref, label, sorted events, an ISO registered_at"
  else
    bad "X: push.json after register_push is not what was registered: $(x_redact "$X_NOW")"
  fi
  X_PERMS="$(python3 -c 'import os,stat,sys; print(*(oct(stat.S_IMODE(os.stat(p).st_mode))[2:] for p in sys.argv[1:]))' \
    "$REPO_X/.heimdall/app" "$REPO_X/.heimdall/app/push.json")"
  if [ "$X_PERMS" = "700 600" ]; then
    ok "X: .heimdall/app is 0700 and push.json 0600"
  else
    bad "X: permissions are '$X_PERMS', expected '700 600' (directory, file)"
  fi
  if grep -qF -- "$PUSH_TOKEN_X" "$REPO_X/.heimdall/app/push.json"; then
    ok "X: the token is in push.json (so the 'in no log' check below is not vacuous)"
  else
    bad "X: the token is not in push.json -- the leak check below would prove nothing"
  fi

  x_queue 2; X_ACK="$(x_ack 2)"
  X_NOW="$(push_state_of "$REPO_X")"
  if x_json_same "$X_ACK" '{"ok":true,"of_seq":2}' \
     && x_json_same "$X_NOW" "{\"app_state\":\"foreground\",\"app_state_at\":\"ISO\",\"tokens\":[$X_ENTRY]}"; then
    ok "X: app_state active is acked bare and stored as foreground with a timestamp, the registration untouched"
  else
    bad "X: app_state active -- ack $X_ACK, store $(x_redact "$X_NOW")"
  fi
  x_queue 3; X_ACK="$(x_ack 3)"
  X_AFTER_BACKGROUND="$(push_state_of "$REPO_X")"
  if x_json_same "$X_ACK" '{"ok":true,"of_seq":3}' \
     && x_json_same "$X_AFTER_BACKGROUND" "{\"app_state\":\"background\",\"app_state_at\":\"ISO\",\"tokens\":[$X_ENTRY]}"; then
    ok "X: app_state background is acked bare and stored as background"
  else
    bad "X: app_state background -- ack $X_ACK, store $(x_redact "$X_AFTER_BACKGROUND")"
  fi

  # a same-device repeat device_bound (a stream reconnect) keeps the registration; another device's frame is refused
  x_device_bound() {  # x_device_bound NUM PUB_B64 -- the relay's own (unencrypted) device_bound frame for that device key
    python3 -c "
import json, sys
env = {'v': 1, 'session_id': sys.argv[1], 'seq': 0, 'sender': 'relay', 'type': 'device_bound',
       'nonce': None, 'ciphertext': None, 'payload': {'device_pubkey': sys.argv[2], 'bound_at': 1758700001}}
with open(sys.argv[3], 'w', encoding='utf-8') as f:
    json.dump(env, f)
" "$SID_X" "$2" "$TMPROOT/x.bound.$1.json" && mv "$TMPROOT/x.bound.$1.json" "$CTL_X/$1.json"
  }
  x_device_bound 020 "$DEV_PUB_X"
  if wait_for_count "$OUT_X" 2 '"event":"device_bound"' 10 \
     && [ "$(push_state_of "$REPO_X")" = "$X_AFTER_BACKGROUND" ]; then
    ok "X: a repeat device_bound for the same phone leaves the registration and the app state alone"
  else
    bad "X: a same-device device_bound lost or changed the registration: $(x_redact "$(push_state_of "$REPO_X")")"
  fi
  X_OTHER_PUB="$(python3 "$FAKE_RELAY" device keygen | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  x_device_bound 021 "$X_OTHER_PUB"
  if wait_for_event "$OUT_X" error "differs from the already latched" 10 \
     && [ "$(push_state_of "$REPO_X")" = "$X_AFTER_BACKGROUND" ]; then
    ok "X: a device_bound for a DIFFERENT phone is refused by the latch and touches nothing"
  else
    bad "X: a different-device device_bound was not refused, or it changed the registration"
  fi

  # the malformed ones, queued together: each is refused with the spec's detail code, none writes anything
  for n in 4 5 6 7 8; do x_queue "$n"; done
  X_SAME=yes
  X_BADACKS=""
  for spec in "4 bad-token" "5 bad-version" "6 bad-state" "7 bad-params" "8 bad-ref"; do
    read -r n code <<<"$spec"
    X_ACK="$(x_ack "$n")"
    x_json_same "$X_ACK" "{\"ok\":false,\"of_seq\":$n,\"detail\":\"$code\"}" || { X_SAME=no; X_BADACKS="$X_BADACKS $X_ACK"; }
  done
  if [ "$X_SAME" = yes ] && [ "$(push_state_of "$REPO_X")" = "$X_AFTER_BACKGROUND" ]; then
    ok "X: a bad token, a bad version, a bad state, params that are not an object and a malformed ref are each refused with the spec's detail and write nothing"
  else
    bad "X: refusals were not the spec's (or a refusal wrote something):$X_BADACKS"
  fi

  x_queue 9; X_ACK="$(x_ack 9)"
  X_NOW="$(push_state_of "$REPO_X")"
  if x_json_same "$X_ACK" "{\"ok\":true,\"of_seq\":9,\"ref\":\"$X_REF\",\"removed\":true}" \
     && x_json_same "$X_NOW" '{"app_state":"background","app_state_at":"ISO","tokens":[]}'; then
    ok "X: unregister_push is acked {ok, of_seq, ref, removed:true} and the registration is gone"
  else
    bad "X: unregister_push -- ack $X_ACK, store $(x_redact "$X_NOW")"
  fi
  x_queue 10; X_ACK="$(x_ack 10)"
  if x_json_same "$X_ACK" "{\"ok\":true,\"of_seq\":10,\"ref\":\"$X_REF\",\"removed\":false}"; then
    ok "X: unregister_push again is idempotent: ok, removed:false"
  else
    bad "X: a second unregister_push was not {ok:true, removed:false}: $X_ACK"
  fi

  X_EVENTS="$(command_events_of "$OUT_X")"
  if x_json_same "$X_EVENTS" '[["register_push",true,null],["app_state",true,null],["app_state",true,null],["register_push",false,"bad-token"],["register_push",false,"bad-version"],["app_state",false,"bad-state"],["register_push",false,"bad-params"],["unregister_push",false,"bad-ref"],["unregister_push",true,null],["unregister_push",true,null]]'; then
    ok "X: the client's command lines name the action, the verdict and the detail -- and nothing else"
  else
    bad "X: command lines are not the expected action/ok/detail sequence: $X_EVENTS"
  fi

  X_LEAKS=""
  for f in "$OUT_X" "$XS_ERR" "$EVENT_LOG_X" "$REPO_X/.heimdall/app/relay.json" "$LOG_X/requests.log" "$TMPROOT/X.srv.out"; do
    [ -e "$f" ] || continue
    if grep -qF -e "$PUSH_TOKEN_X" -e "api server" -e "$X_REF" "$f"; then X_LEAKS="$X_LEAKS $(basename "$f")"; fi
  done
  if [ -z "$X_LEAKS" ] && [ -s "$EVENT_LOG_X" ]; then
    ok "X: the token, the label and the ref appear in no stdout, stderr, event-log, status-file or relay-request-log byte"
  else
    bad "X: a push secret reached:${X_LEAKS:- (nothing -- but the event log is empty, so the check proved nothing)}"
  fi

  kill "$CLIENT_X" 2>/dev/null; wait "$CLIENT_X" 2>/dev/null
  kill "$SRV_X" 2>/dev/null; wait "$SRV_X" 2>/dev/null

  # ── X2: HMD_PUSH=0, the operator's kill switch ──
  REPO_X2="$(make_repo)"
  x_start_session X2 "$REPO_X2" env HMD_PUSH=0
  SID_X="$XS_SID"; KEY_X="$XS_KEY"; LOG_X="$XS_LOG"; CTL_X="$XS_CTL"; CLIENT_X2="$XS_CLIENT"; SRV_X2="$XS_SRV"
  if wait_for "$XS_OUT" '"event":"device_bound"' 1 && [ -n "$SID_X" ] && [ -n "$KEY_X" ]; then
    ok "scenario X2 (HMD_PUSH=0): relay-client paired (session key derivable)"
  else
    bad "scenario X2: relay-client never paired -- the rest of X2 cannot run: $(tail -3 "$XS_ERR" 2>/dev/null)"
  fi
  if wait_for_count "$LOG_X/frames.ndjson" 1 '"type":"state"' 10; then
    X_CAPS="$(state_caps_of "$LOG_X/frames.ndjson" "$KEY_X")"
    if x_json_same "$X_CAPS" '["ask-v1","controls-v1","dash-alert-v1","dash-v1","login-v1","resync","view-v1","z-zlib"]'; then
      ok "X2: with HMD_PUSH=0 the state frame no longer lists push-v1 (controls-v1, login-v1 and view-v1 are untouched)"
    else
      bad "X2: state frame caps with HMD_PUSH=0 are not [ask-v1, controls-v1, dash-alert-v1, dash-v1, login-v1, resync, view-v1, z-zlib]: $X_CAPS"
    fi
  else
    bad "X2: no state frame ever reached the relay"
  fi
  x_prepare 1 "$(x_reg_json "$PUSH_TOKEN_X" 1)"
  x_prepare 2 '{"action":"app_state","params":{"state":"active"}}'
  x_prepare 3 "$(x_unreg_json "$X_REF")"
  X2_SAME=yes
  for n in 1 2 3; do
    x_queue "$n"
    X_ACK="$(x_ack "$n")"
    x_json_same "$X_ACK" "{\"ok\":false,\"of_seq\":$n,\"detail\":\"push-disabled\"}" || X2_SAME=no
  done
  if [ "$X2_SAME" = yes ] && [ ! -e "$REPO_X2/.heimdall/app/push.json" ]; then
    ok "X2: register_push, app_state and unregister_push are each acked push-disabled, and nothing is written"
  else
    bad "X2: HMD_PUSH=0 did not answer push-disabled everywhere, or it wrote push.json"
  fi
  kill "$CLIENT_X2" 2>/dev/null; wait "$CLIENT_X2" 2>/dev/null
  kill "$SRV_X2" 2>/dev/null; wait "$SRV_X2" 2>/dev/null
else
  skip "scenario X (push registration over sealed commands): bin/lib/hmd_relay_e2e.py absent -- needs real seal"
fi

# ── Scenario Y: a command frame refused for a non-increasing seq is ANSWERED, not dropped (hmdapp's
# docs/analysis/2026-10-04-heimdall-golive-readiness.md: the phone could not tell a refused command from a lost one). The replay
# guard (INV-14/15) never acts on a frame whose seq is not above the last device seq hmd accepted. A frame of that kind that
# OPENS under the session key is answered with a sealed refusal {ok:false, of_seq:<its seq>, detail:non-increasing-seq,
# last:<last device seq accepted>} so the phone can seal the command again above `last`; one that does not open stays silent
# and uses up nothing (audit #5); each distinct stale seq is refused once, and no more than STALE_REFUSAL_BURST refusals go
# out in any STALE_REFUSAL_WINDOW_S. The REAL client against the fake relay: Y1 the refusal and its shape, Y2 the phone's
# re-seal at last+1, Y3 a frame that does not open, Y4 a flood ─────────────────────────────────────────────────────────
y_inbox_texts() {  # y_inbox_texts REPO -- the text of every inbox record, one per line, oldest first
  python3 - "$1/.heimdall/ui/inbox.jsonl" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                print(json.loads(line)["text"])
PYEOF
}

# y_prepare_flood DIR SESSION_ID KEY_B64 FIRST_SEQ COUNT FIRST_NUM -- seals COUNT send-message commands, at FIRST_SEQ and every seq
# after it, as the paired device: one complete relay envelope per file in DIR, named FIRST_NUM, FIRST_NUM+1, ... (.json). Queues nothing.
y_prepare_flood() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$E2E_MOD" <<'PYEOF'
import base64, json, os, sys
from importlib.util import module_from_spec, spec_from_file_location

out_dir, sid, key_b64, first_seq, count, first_num, e2e_path = sys.argv[1:8]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
os.makedirs(out_dir, exist_ok=True)
for i in range(int(count)):
    seq = int(first_seq) + i
    body = json.dumps({"action": "send-message", "params": {"text": "y flood %d" % seq}})
    nonce, ciphertext = e2e.seal(key, seq, "device", body.encode("utf-8"))
    env = {"v": 1, "session_id": sid, "seq": seq, "sender": "device", "type": "command",
           "nonce": nonce, "ciphertext": ciphertext, "payload": None}
    with open(os.path.join(out_dir, "%03d.json" % (int(first_num) + i)), "w", encoding="utf-8") as f:
        json.dump(env, f, sort_keys=True, separators=(",", ":"))
PYEOF
}

if [ "$E2E_PRESENT" = true ]; then
  REPO_Y="$(make_repo)"
  x_start_session Y "$REPO_Y"
  SID_Y="$XS_SID"; KEY_Y="$XS_KEY"; LOG_Y="$XS_LOG"; CTL_Y="$XS_CTL"; OUT_Y="$XS_OUT"; ERR_Y="$XS_ERR"
  CLIENT_Y="$XS_CLIENT"; SRV_Y="$XS_SRV"
  FRAMES_Y="$LOG_Y/frames.ndjson"
  Y_NUM=0
  y_queue() { Y_NUM=$((Y_NUM + 1)); mv "$1" "$CTL_Y/$(printf '%03d' "$Y_NUM").json"; }  # the relay pushes ctl files in numeric order
  y_replay() { cp "$1" "$TMPROOT/y.replay.json" && y_queue "$TMPROOT/y.replay.json"; }   # the very same bytes once more
  y_prepare() { prepare_device_action "$TMPROOT/y.cmd.$1.json" "$SID_Y" "${4:-$KEY_Y}" "$2" "$3"; }  # y_prepare NAME SEQ JSON [KEY_B64]
  if wait_for "$OUT_Y" '"event":"device_bound"' 1 && [ -n "$SID_Y" ] && [ -n "$KEY_Y" ]; then
    ok "scenario Y: relay-client paired (session key derivable)"
  else
    bad "scenario Y: relay-client never paired -- the rest of Y cannot run: $(tail -3 "$ERR_Y" 2>/dev/null)"
  fi

  # every frame is sealed up front and queued only when it is wanted
  Y_WRONG_KEY="$(python3 -c 'import base64; print(base64.b64encode(bytes(range(32))).decode())')"
  y_prepare first 5 '{"action":"send-message","params":{"text":"y first"}}'
  y_prepare lower 4 '{"action":"send-message","params":{"text":"y lower"}}'
  y_prepare forged 3 '{"action":"send-message","params":{"text":"y forged"}}' "$Y_WRONG_KEY"
  y_prepare jump 100 '{"action":"y-noop","params":{}}'
  y_prepare sentinel 101 '{"action":"y-noop","params":{}}'
  # the stale seq-4 frame with one ciphertext bit flipped: it does not open
  python3 - "$TMPROOT/y.cmd.lower.json" "$TMPROOT/y.cmd.tampered.json" <<'PYEOF'
import base64, json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    env = json.load(f)
raw = bytearray(base64.b64decode(env["ciphertext"]))
raw[0] ^= 0x01
env["ciphertext"] = base64.b64encode(bytes(raw)).decode("ascii")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(env, f, sort_keys=True, separators=(",", ":"))
PYEOF

  # the phone's seq 5 is accepted: hmd's last device seq is 5
  y_replay "$TMPROOT/y.cmd.first.json"
  Y_ACK_FIRST="$(wait_for_ack_of_seq "$FRAMES_Y" "$KEY_Y" 5 10)"
  if printf '%s' "$Y_ACK_FIRST" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
    ok "scenario Y: the phone's seq 5 is accepted (acked ok), so hmd's last device seq is 5"
  else
    bad "scenario Y: the phone's seq 5 was not accepted: '${Y_ACK_FIRST:-no ack}'"
  fi

  # silent ones first (a corrupted seq-4 frame, a seq-3 frame sealed under another key), then the seq-5 frame replayed three
  # times, then a genuine frame at the lower seq 4
  y_queue "$TMPROOT/y.cmd.tampered.json"
  y_queue "$TMPROOT/y.cmd.forged.json"
  y_replay "$TMPROOT/y.cmd.first.json"; y_replay "$TMPROOT/y.cmd.first.json"; y_replay "$TMPROOT/y.cmd.first.json"
  y_queue "$TMPROOT/y.cmd.lower.json"

  Y_REFUSAL_5="$(wait_for_refusal_ack "$FRAMES_Y" "$KEY_Y" 5 10)"
  Y_REFUSAL_4="$(wait_for_refusal_ack "$FRAMES_Y" "$KEY_Y" 4 10)"
  if [ "$Y_REFUSAL_5" = '{"detail":"non-increasing-seq","last":5,"of_seq":5,"ok":false}' ] \
     && [ "$Y_REFUSAL_4" = '{"detail":"non-increasing-seq","last":5,"of_seq":4,"ok":false}' ]; then
    ok "Y1: a replayed frame (seq 5) and a lower one (seq 4) are each answered with a sealed {detail:non-increasing-seq, last:5, of_seq, ok:false} and nothing more"
  else
    bad "Y1: no exact sealed refusal for the replay (got '${Y_REFUSAL_5:-none}') and the lower seq (got '${Y_REFUSAL_4:-none}')"
  fi

  # Y2: the phone re-seals the refused command above the `last` the refusal names
  Y_LAST_NAMED="$(printf '%s' "$Y_REFUSAL_4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["last"])' 2>/dev/null)"
  Y_LAST="${Y_LAST_NAMED:-5}"  # with no refusal to read it from the scenario still runs on; Y2 fails below
  y_prepare reseal "$((Y_LAST + 1))" '{"action":"send-message","params":{"text":"y lower"}}'
  y_queue "$TMPROOT/y.cmd.reseal.json"
  Y_ACK_RESEAL="$(wait_for_ack_of_seq "$FRAMES_Y" "$KEY_Y" "$((Y_LAST + 1))" 10)"
  if [ -n "$Y_LAST_NAMED" ] \
     && printf '%s' "$Y_ACK_RESEAL" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null \
     && [ "$(y_inbox_texts "$REPO_Y")" = "$(printf 'y first\ny lower')" ]; then
    ok "Y2: the phone's re-seal at last+1 (seq $((Y_LAST + 1))) is accepted -- acked ok and in the inbox once; no stale frame ever reached it"
  else
    bad "Y2: no refusal named a last seq to re-seal above (named '${Y_LAST_NAMED:-none}'), or the re-seal at seq $((Y_LAST + 1)) was not accepted, or a stale frame was acted on (ack '${Y_ACK_RESEAL:-none}', inbox: $(y_inbox_texts "$REPO_Y" | tr '\n' '|'))"
  fi

  # Y3: that ack is the barrier -- hmd handles frames in order -- so every earlier frame has been dealt with. The answers it
  # gave, by the seq they answer: the accepted 5, ONE refusal of the three replays of 5, the refusal of the genuine 4 (the
  # corrupted 4 before it neither drew one nor used up its allowance), the accepted 6; nothing for the forged 3.
  Y_OF_SEQS="$(sealed_acks "$FRAMES_Y" "$KEY_Y" | python3 -c 'import json,sys; print(" ".join(str(json.loads(l)["ack"]["of_seq"]) for l in sys.stdin))')"
  if [ "$Y_OF_SEQS" = "5 5 4 $((Y_LAST + 1))" ]; then
    ok "Y3: frames that do not open (a corrupted seq 4, a seq 3 sealed under another key) draw no ack and use up no refusal ($Y_OF_SEQS)"
  else
    bad "Y3: the acks answered seqs '$Y_OF_SEQS', want '5 5 4 $((Y_LAST + 1))'"
  fi

  # Y4: a flood of 40 stale frames, each a distinct seq that opens. last_device_seq goes to 100 first; the last frame (seq 101,
  # accepted) is the barrier. Bound: at most STALE_REFUSAL_BURST refusals in any STALE_REFUSAL_WINDOW_S (checked over 0.9 of it,
  # since the relay's receive stamps and the client's clock differ by a few ms); none of the 40 is acted on.
  Y_BURST="$(sed -n 's/^STALE_REFUSAL_BURST = \([0-9][0-9]*\).*/\1/p' "$RELAY_CLIENT" | head -1)"
  Y_WINDOW_S="$(sed -n 's/^STALE_REFUSAL_WINDOW_S = \([0-9][0-9.]*\).*/\1/p' "$RELAY_CLIENT" | head -1)"
  y_queue "$TMPROOT/y.cmd.jump.json"
  wait_for_ack_of_seq "$FRAMES_Y" "$KEY_Y" 100 10 >/dev/null
  y_prepare_flood "$TMPROOT/y.flood" "$SID_Y" "$KEY_Y" 10 40 500
  mv "$TMPROOT"/y.flood/*.json "$CTL_Y/"
  mv "$TMPROOT/y.cmd.sentinel.json" "$CTL_Y/900.json"
  wait_for_ack_of_seq "$FRAMES_Y" "$KEY_Y" 101 20 >/dev/null
  Y_CHECK_WINDOW="$(python3 -c 'import sys; print(float(sys.argv[1]) * 0.9)' "${Y_WINDOW_S:-1.0}")"
  read -r Y_COUNT Y_PEAK <<<"$(refusal_rate "$FRAMES_Y" "$KEY_Y" "$LOG_Y/frame-posts.log" "$Y_CHECK_WINDOW")"
  # the flood's refusals are every one after the first two (seqs 5 and 4): each names last 100, a flood seq, and nothing more
  Y_FLOOD_SHAPE="$(refusal_acks "$FRAMES_Y" "$KEY_Y" | tail -n +3 | python3 -c '
import json, sys
seen = []
for line in sys.stdin:
    ack = json.loads(line)
    if set(ack) != {"detail", "last", "of_seq", "ok"} or ack["last"] != 100 or ack["ok"] is not False \
            or not 10 <= ack["of_seq"] <= 49:
        print("BAD " + line.strip()); sys.exit(0)
    seen.append(ack["of_seq"])
print("OK" if len(seen) == len(set(seen)) else "BAD duplicate of_seq")
')"
  if [ -n "$Y_BURST" ] && [ -n "$Y_WINDOW_S" ] && [ "$((Y_COUNT - 2))" -ge 1 ] && [ "$Y_PEAK" -le "$Y_BURST" ] \
     && [ "$Y_FLOOD_SHAPE" = "OK" ] && [ "$(y_inbox_texts "$REPO_Y")" = "$(printf 'y first\ny lower')" ]; then
    ok "Y4: a flood of 40 stale frames drew $((Y_COUNT - 2)) refusals, at most $Y_PEAK in any ${Y_CHECK_WINDOW}s (bound $Y_BURST per ${Y_WINDOW_S}s); none was acted on"
  else
    bad "Y4: flood not bounded as STALE_REFUSAL_BURST='${Y_BURST:-undefined}' per STALE_REFUSAL_WINDOW_S='${Y_WINDOW_S:-undefined}' (refusals $((Y_COUNT - 2)), peak in window ${Y_PEAK:-?}, shape ${Y_FLOOD_SHAPE:-?}, inbox: $(y_inbox_texts "$REPO_Y" | tr '\n' '|'))"
  fi

  kill "$CLIENT_Y" 2>/dev/null; wait "$CLIENT_Y" 2>/dev/null
  kill "$SRV_Y" 2>/dev/null; wait "$SRV_Y" 2>/dev/null
else
  skip "scenario Y (stale-seq refusal): bin/lib/hmd_relay_e2e.py absent -- needs real seal"
fi

# ── Scenario Z: hmd's leg as a hibernatable WebSocket (relay/contract/wire.json `stream_ws`, bin/lib/hmd_relay_ws.py) ────
# hmd's GET /stream used to be one chunked NDJSON response, and an open response keeps the relay's Durable Object awake and
# billed. The same route is now also a WebSocket the object can sleep through, negotiated by the request alone (`Upgrade:
# websocket`). Every scenario above runs against a relay WITHOUT --ws -- the relay as deployed before this change, which
# ignores the Upgrade header and answers 200 NDJSON -- with a client that now asks for the upgrade by default, so all of
# them are also proof that the current client works against an old relay. Here the fake relay speaks WebSocket (--ws) and
# the stream semantics hmd relies on are checked over it: Z1 negotiation, bootstrap, a command and its ack, the stale-seq
# refusal, a forged frame, the persistent POST connections; Z2 ping/pong liveness and the idle drop; Z3 rotation; Z4 the byte
# cap; Z5 a relay that closes; Z6 a relay that ends the session; Z7 a refused upgrade and a 429; Z8 a relay that sends garbage;
# Z9 the fallbacks and the knob; Z10 wss (TLS) ──────────────────────────────────────────────────────────────────────
ws_start() {
  # ws_start TAG [COMMAND WORDS...] -- a fake relay (--ws, unless W_RELAY_ARGS says otherwise) and the REAL client on a fresh
  # repo, paired; leaves what a scenario needs in W_*
  local tag="$1" relay_args="--ws"
  shift
  [ "${W_RELAY_ARGS+set}" = set ] && relay_args="$W_RELAY_ARGS"
  W_REPO="$(make_repo)"
  W_NUM=0
  XS_RELAY_ARGS="$relay_args" x_start_session "$tag" "$W_REPO" "$@"
  W_SID="$XS_SID"; W_KEY="$XS_KEY"; W_LOG="$XS_LOG"; W_CTL="$XS_CTL"; W_OUT="$XS_OUT"; W_ERR="$XS_ERR"
  W_CLIENT="$XS_CLIENT"; W_SRV="$XS_SRV"
}
ws_stop() {
  kill "$W_CLIENT" 2>/dev/null; wait "$W_CLIENT" 2>/dev/null
  kill "$W_SRV" 2>/dev/null; wait "$W_SRV" 2>/dev/null
}
ws_command() {  # ws_command SEQ JSON [KEY_B64] -- seals one phone command and queues it as the next ctl file
  W_NUM=$((W_NUM + 1))
  prepare_device_action "$TMPROOT/ws.cmd.$W_NUM.json" "$W_SID" "${3:-$W_KEY}" "$1" "$2"
  mv "$TMPROOT/ws.cmd.$W_NUM.json" "$W_CTL/$(printf '%03d' "$W_NUM").json"
}
ws_ack() { wait_for_ack_of_seq "$W_LOG/frames.ndjson" "$W_KEY" "$1" "${2:-10}"; }  # the opened ack of device seq $1
ws_field() { python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }  # one field of a JSON line

if [ "$E2E_PRESENT" = true ]; then
  # Z1: negotiation, bootstrap, a command and its ack, the refusal, a forged frame, the POST connections
  ws_start Z1
  if wait_for "$W_OUT" '"event":"stream_open","transport":"ws"' 10 && [ "$(head -1 "$W_LOG/stream-transport.log" 2>/dev/null)" = "ws asked=yes" ]; then
    ok "Z1: the client asks for an upgrade on GET /stream, the relay answers 101, and the client reports the WebSocket"
  else
    bad "Z1: no ws stream_open (transport log: $(cat "$W_LOG/stream-transport.log" 2>/dev/null | tr '\n' ','); stderr: $(tail -2 "$W_ERR" 2>/dev/null))"
  fi
  if [ -n "$W_SID" ] && [ -n "$W_KEY" ] && grep -q '"event":"device_bound"' "$W_OUT" && ! grep -q 'token_query=y' "$W_LOG/requests.log" \
     && grep -Eq '^GET /session/.*/stream.*auth=y' "$W_LOG/requests.log"; then
    ok "Z1: the session key is bootstrapped from the device_bound message; the upgrade carried the bearer in a header, never ?token="
  else
    bad "Z1: no device_bound over the WebSocket, or the bearer was not a header"
  fi
  ws_command 1 '{"action":"send-message","params":{"text":"z1 over a websocket"}}'
  Z1_ACK="$(ws_ack 1)"
  if [ "$(printf '%s' "$Z1_ACK" | ws_field ok)" = "True" ] && [ -n "$(printf '%s' "$Z1_ACK" | ws_field id)" ] \
     && grep -q '"z1 over a websocket"' "$W_REPO/.heimdall/ui/inbox.jsonl" 2>/dev/null; then
    ok "Z1: a send-message command arrives as a WebSocket text message, lands in the inbox, and is acked {ok:true, id}"
  else
    bad "Z1: the command over the WebSocket was not acked ok / not in the inbox (ack '${Z1_ACK:-none}')"
  fi
  ws_command 1 '{"action":"send-message","params":{"text":"z1 over a websocket"}}'   # the very same frame again: the replay guard
  Z1_REFUSAL="$(wait_for_refusal_ack "$W_LOG/frames.ndjson" "$W_KEY" 1 8)"
  if [ "$Z1_REFUSAL" = '{"detail":"non-increasing-seq","last":1,"of_seq":1,"ok":false}' ] \
     && [ "$(grep -c '"z1 over a websocket"' "$W_REPO/.heimdall/ui/inbox.jsonl")" = "1" ]; then
    ok "Z1: a replayed seq is answered with the sealed refusal ack over this transport too, and acted on once"
  else
    bad "Z1: no exact refusal ack for the replay (got '${Z1_REFUSAL:-none}')"
  fi
  Z_WRONG_KEY="$(python3 -c 'import base64; print(base64.b64encode(bytes(range(32))).decode())')"
  ws_command 2 '{"action":"send-message","params":{"text":"z1 forged"}}' "$Z_WRONG_KEY"
  Z1_FORGED="$(ws_ack 2)"
  if [ "$(printf '%s' "$Z1_FORGED" | ws_field detail)" = "decrypt-failed" ] && ! grep -q '"z1 forged"' "$W_REPO/.heimdall/ui/inbox.jsonl" 2>/dev/null; then
    ok "Z1: a frame sealed under another key is acked decrypt-failed and never acted on"
  else
    bad "Z1: the forged frame was not refused as decrypt-failed (ack '${Z1_FORGED:-none}')"
  fi
  Z1_CONNS="$(python3 - "$W_LOG/frame-posts.log" <<'PYEOF'
import re, sys
conns = {"ack": set(), "state": set()}
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.search(r"conn=(\d+) type=(\w+)", line)
    if m and m.group(2) in conns:
        conns[m.group(2)].add(m.group(1))
print("ok" if len(conns["ack"]) == 1 and len(conns["state"]) == 1 and conns["ack"] != conns["state"] else "bad %r" % conns)
PYEOF
)"
  if [ "$Z1_CONNS" = "ok" ] && ! grep -q '^violation' "$W_LOG/ws-client.log" 2>/dev/null; then
    ok "Z1: acks still share ONE persistent POST connection and state frames another, none of them the stream's; no frame the RFC forbids a client"
  else
    bad "Z1: POST connections changed with the transport ($Z1_CONNS), or the client broke RFC 6455 ($(grep '^violation' "$W_LOG/ws-client.log" 2>/dev/null | head -1))"
  fi
  ws_stop

  # Z2: the relay writes no keepalive on a WebSocket, so hmd pings; the runtime's pong is proof of life, silence is the idle drop
  ws_start Z2 env HMD_RELAY_STREAM_IDLE_S=2 HMD_RELAY_BACKOFF_BASE_MS=500
  if wait_for_count "$W_LOG/ws-client.log" 3 '^text ping$' 8; then
    ok "Z2: an idle client pings (3 pings inside 8 s with HMD_RELAY_STREAM_IDLE_S=2: one every idle/3)"
  else
    bad "Z2: the idle client never pinged ($(cat "$W_LOG/ws-client.log" 2>/dev/null | head -3))"
  fi
  sleep 4
  if [ "$(count_matching "$W_OUT" '"event":"stream_drop"')" = "0" ]; then
    ok "Z2: answered pings keep the stream up through twice its idle window with the relay otherwise silent"
  else
    bad "Z2: the stream dropped although every ping was answered ($(grep '"event":"stream_drop"' "$W_OUT" | head -1))"
  fi
  Z2_PINGS="$(count_matching "$W_LOG/ws-client.log" '^text ping$')"
  : > "$W_CTL/mute-pong"
  if [ -n "$(wait_for_stream_drop "$W_OUT" idle 8)" ]; then
    ok "Z2: pings that draw no pong end in stream_drop reason=idle within HMD_RELAY_STREAM_IDLE_S"
  else
    bad "Z2: a relay that stopped answering never produced an idle stream_drop"
  fi
  if [ "$(count_matching "$W_LOG/ws-client.log" '^text ping$')" -ge "$((Z2_PINGS + 2))" ] \
     && wait_for_count "$W_LOG/stream-transport.log" 2 '^ws asked=yes$' 8; then
    ok "Z2: it kept pinging until the idle drop, then reconnected over the WebSocket"
  else
    bad "Z2: no pings while the pongs were muted, or no reconnect after the idle drop"
  fi
  ws_stop

  # Z3: rotation over a WebSocket: a close frame, no backoff, the same session on the new socket
  ws_start Z3 env HMD_RELAY_STREAM_ROTATE_S=3
  Z3_DROP="$(wait_for_stream_drop "$W_OUT" rotate 8)"
  if [ -n "$Z3_DROP" ] && [ "$(printf '%s' "$Z3_DROP" | ws_field retry_ms)" = "0" ]; then
    ok "Z3: the client rotates its WebSocket at HMD_RELAY_STREAM_ROTATE_S (stream_drop reason=rotate, retry_ms=0)"
  else
    bad "Z3: no rotate stream_drop with retry_ms=0 ('${Z3_DROP:-none}')"
  fi
  if wait_for "$W_LOG/ws-client.log" '^close 1000$' 3 && wait_for_count "$W_LOG/stream-transport.log" 2 '^ws asked=yes$' 6 \
     && wait_for_count "$W_OUT" 2 '"event":"device_bound"' 6; then
    ok "Z3: the rotation ended the socket with a close frame (1000), and the new one re-bound at once"
  else
    bad "Z3: no close frame before the rotation, or no re-bind on the new socket"
  fi
  ws_stop

  # Z4: the byte cap: a message declared over it is refused from its header, then the client reconnects
  ws_start Z4 env HMD_RELAY_MAX_ENVELOPE_BYTES=2000
  : > "$W_CTL/oversized-line=4000"
  Z4_DROP="$(wait_for_stream_drop "$W_OUT" overflow 8)"
  if [ "$(printf '%s' "$Z4_DROP" | ws_field line_bytes)" = "4000" ] && [ "$(printf '%s' "$Z4_DROP" | ws_field cap_bytes)" = "2001" ]; then
    ok "Z4: a 4000-byte message over a 2000-byte envelope cap is stream_drop reason=overflow (line_bytes=4000, cap_bytes=2001)"
  else
    bad "Z4: no overflow drop naming the message ('${Z4_DROP:-none}')"
  fi
  if wait_for_count "$W_OUT" 2 '"event":"device_bound"' 10; then
    ok "Z4: the client kept running: it reconnected and re-bound after the overflow"
  else
    bad "Z4: no reconnect after the overflow drop"
  fi
  ws_stop

  # Z5: a relay that closes the socket: stream_drop reason=closed names the close code, the backoff is honoured
  ws_start Z5 env HMD_RELAY_BACKOFF_BASE_MS=500
  : > "$W_CTL/lifetime-close"
  Z5_DROP="$(wait_for_stream_drop "$W_OUT" closed 8)"
  if [ "$(printf '%s' "$Z5_DROP" | ws_field close_code)" = "1001" ] && [ "$(printf '%s' "$Z5_DROP" | ws_field retry_ms)" = "500" ] \
     && wait_for_event "$W_OUT" error "WebSocket close code 1001" 3; then
    ok "Z5: a close frame from the relay is stream_drop reason=closed with close_code=1001 and the 500 ms backoff, named in an error event"
  else
    bad "Z5: the relay's close was not reported as closed/1001/500 ('${Z5_DROP:-none}')"
  fi
  if wait_for_count "$W_OUT" 2 '"event":"device_bound"' 8; then
    ok "Z5: it reconnected and re-bound after the relay's close"
  else
    bad "Z5: no reconnect after the relay's close"
  fi
  ws_stop

  # Z6: a relay that ends the session: the session_ended message, then the close; the client exits 0 and posts nothing more
  ws_start Z6
  # cat, not `wc -l <`: a relay that has seen no frame yet has no frames.ndjson, and that is zero frames, not "" (a
  # failed `<` redirect also writes its error to the shell's stderr, past any 2>/dev/null on the command)
  Z6_BEFORE="$(cat "$W_LOG/frames.ndjson" 2>/dev/null | wc -l | tr -d ' ')"
  : > "$W_CTL/end-session"
  if wait_pid_exit "$W_CLIENT" 10; then
    wait "$W_CLIENT" 2>/dev/null; Z6_RC=$?
  else
    Z6_RC=hung
  fi
  sleep 0.5
  if [ "$Z6_RC" = "0" ] && grep -q '"event":"session_ended"' "$W_OUT" && [ "$(cat "$W_LOG/frames.ndjson" 2>/dev/null | wc -l | tr -d ' ')" = "${Z6_BEFORE:-0}" ]; then
    ok "Z6: session_ended over the WebSocket ends the client with exit 0 and no frame posted afterwards"
  else
    bad "Z6: the client did not end cleanly on session_ended over the WebSocket (rc $Z6_RC)"
  fi
  ws_stop

  # Z7: what the upgrade request can be answered before it is one: a wrong Sec-WebSocket-Accept, a 429
  XS_CTL_FLAGS="bad-accept" ws_start Z7a env HMD_RELAY_BACKOFF_BASE_MS=500
  if wait_for_event "$W_OUT" error "upgrade refused" 8 && grep -q '"event":"stream_drop","retry_ms":500' "$W_OUT" \
     && wait_for "$W_OUT" '"event":"stream_open","transport":"ws"' 8 && [ "$(count_matching "$W_OUT" '"event":"stream_open"')" = "1" ]; then
    ok "Z7: a 101 with the wrong Sec-WebSocket-Accept is an error and a backoff -- never opened, never a silent fallback -- and the retry succeeds"
  else
    bad "Z7: the wrong Sec-WebSocket-Accept was not refused and retried ($(grep -E 'upgrade refused|stream_open' "$W_OUT" | head -3))"
  fi
  ws_stop
  XS_CTL_FLAGS="rate-limit-next=1" ws_start Z7b
  if wait_for "$W_OUT" '"event":"stream_open","transport":"ws"' 10 && grep -q '"event":"device_bound"' "$W_OUT"; then
    ok "Z7: a 429 with Retry-After on the upgrade request is waited out, and the stream then opens as a WebSocket"
  else
    bad "Z7: the client did not recover from a 429 on the upgrade request"
  fi
  ws_stop

  # Z8: a relay that sends garbage: text that is not JSON, JSON that is not an object, an object that is not an envelope --
  # each a loud error, none a dead stream, and a real command after them is still acted on over the same socket
  ws_start Z8
  printf '%s' 'this is not json' > "$W_CTL/001.raw"
  printf '%s' '[]' > "$W_CTL/002.raw"
  printf '%s' '{"v":1}' > "$W_CTL/003.raw"
  W_NUM=3
  ws_command 1 '{"action":"send-message","params":{"text":"z8 after the garbage"}}'
  Z8_ACK="$(ws_ack 1)"
  if wait_for_event "$W_OUT" error "malformed frame" 3 && wait_for_event "$W_OUT" error "not a JSON object" 3 \
     && wait_for_event "$W_OUT" error "unexpected frame" 3 && [ "$(printf '%s' "$Z8_ACK" | ws_field ok)" = "True" ] \
     && [ "$(count_matching "$W_OUT" '"event":"stream_drop"')" = "0" ]; then
    ok "Z8: three kinds of garbage are three error events; the stream stays up and the command after them is acked"
  else
    bad "Z8: garbage over the WebSocket was not survived (ack '${Z8_ACK:-none}', drops $(count_matching "$W_OUT" '"event":"stream_drop"'))"
  fi
  ws_stop

  # Z9: the fallbacks and the knob. (a) a relay without the WebSocket leg answers the Upgrade request with NDJSON: the client
  # reads that and works; (b) HMD_RELAY_STREAM_TRANSPORT=ndjson never asks; (c) a value the knob does not know is auto, loudly
  W_RELAY_ARGS="" ws_start Z9a
  ws_command 1 '{"action":"send-message","params":{"text":"z9a over ndjson"}}'
  Z9A_ACK="$(ws_ack 1)"
  if [ "$(head -1 "$W_LOG/stream-transport.log" 2>/dev/null)" = "ndjson asked=yes" ] && grep -q '"event":"stream_open","transport":"ndjson"' "$W_OUT" \
     && [ "$(printf '%s' "$Z9A_ACK" | ws_field ok)" = "True" ]; then
    ok "Z9: a relay that ignores the Upgrade header streams NDJSON; the client reads it as before, reports transport=ndjson, and works"
  else
    bad "Z9: the fallback against a relay without the WebSocket leg failed ($(cat "$W_LOG/stream-transport.log" 2>/dev/null | head -1), ack '${Z9A_ACK:-none}')"
  fi
  ws_stop
  ws_start Z9b env HMD_RELAY_STREAM_TRANSPORT=ndjson
  if [ "$(head -1 "$W_LOG/stream-transport.log" 2>/dev/null)" = "ndjson asked=no" ] && grep -q '"event":"stream_open","transport":"ndjson"' "$W_OUT"; then
    ok "Z9: HMD_RELAY_STREAM_TRANSPORT=ndjson never asks for the upgrade, even of a relay that would grant it"
  else
    bad "Z9: HMD_RELAY_STREAM_TRANSPORT=ndjson still asked ($(cat "$W_LOG/stream-transport.log" 2>/dev/null | head -1))"
  fi
  ws_stop
  ws_start Z9c env HMD_RELAY_STREAM_TRANSPORT=carrier-pigeon
  if wait_for_event "$W_OUT" error "is not one of auto|ndjson" 5 && wait_for "$W_OUT" '"event":"stream_open","transport":"ws"' 8; then
    ok "Z9: an unknown HMD_RELAY_STREAM_TRANSPORT is reported and treated as auto"
  else
    bad "Z9: an unknown HMD_RELAY_STREAM_TRANSPORT was not reported / not treated as auto"
  fi
  ws_stop

  # Z10: wss. The real client over TLS to a fake relay with a throwaway certificate (trusted through SSL_CERT_FILE): the
  # upgrade, the SSLSocket reads, a command and its ack
  if command -v openssl >/dev/null 2>&1 \
     && openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMPROOT/z.key" -out "$TMPROOT/z.crt" -days 2 \
          -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1; then
    W_RELAY_ARGS="--ws --tls $TMPROOT/z.crt $TMPROOT/z.key" XS_SCHEME=https ws_start Z10 env SSL_CERT_FILE="$TMPROOT/z.crt"
    ws_command 1 '{"action":"send-message","params":{"text":"z10 over wss"}}'
    Z10_ACK="$(ws_ack 1)"
    if grep -q '"event":"stream_open","transport":"ws"' "$W_OUT" && [ "$(head -1 "$W_LOG/stream-transport.log" 2>/dev/null)" = "ws asked=yes" ] \
       && [ "$(printf '%s' "$Z10_ACK" | ws_field ok)" = "True" ]; then
      ok "Z10: over TLS the upgrade is answered 101 and a command round-trips as a WebSocket message (wss)"
    else
      bad "Z10: no WebSocket over TLS (ack '${Z10_ACK:-none}', stderr: $(tail -2 "$W_ERR" 2>/dev/null), events: $(grep -E 'error|stream_open' "$W_OUT" | head -2))"
    fi
    ws_stop
  else
    skip "Z10: openssl cannot make a throwaway certificate here -- the wss path is not exercised"
  fi
else
  skip "scenario Z (hmd's leg over a WebSocket): bin/lib/hmd_relay_e2e.py absent -- needs real seal"
fi

suite_summary
