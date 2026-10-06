#!/usr/bin/env bash
# test/heimdall-app-relay.test.sh -- hermetic acceptance for bin/heimdall-relay-client
# (and bin/heimdall-app's `connect --relay` orchestration of it) against
# test/lib/fake-relay.py, a stdlib stand-in for the Cloudflare relay described in
# hmdapp's docs/HANDOFF-TO-HEIMDALL-relay.md ("Implemented relay API",
# "Envelope", "Tests", "Acceptance criteria" -- read-only inputs, never edited
# here) and docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md (the session-key
# bootstrap convention -- docs/RELAY-CLIENT-CONTRACT.md, formerly cited here,
# is retracted; see that file's own banner).
#
# This suite drives the REAL bin/heimdall-relay-client (claims 1-7) and the
# REAL `bin/heimdall app connect --relay` (claim 8) against the fake relay --
# nothing about the client or heimdall-app is mocked. Style mirrors
# test/heimdall-app.test.sh and test/heimdall-ui-panels.test.sh: numbered
# ok()/bad() cases, PASS/FAIL/SKIP tally, trap-based cleanup, a throwaway
# HOME + temp repo per scenario, free-port allocation, poll-based waits (no
# fixed sleeps standing in for a real readiness check).
#
# bin/lib/hmd_relay_e2e.py (the E2E crypto module bin/heimdall-relay-client and
# this suite's own `fake-relay.py device` subcommands both import BY PATH) is
# being built by a sibling task and may not exist yet on this branch.
# bin/heimdall-relay-client's own main() gates e2e_available() BEFORE
# pair_init, so EVERY claim that starts a real relay-client process needs
# something at that path answering e2e_available()==True. test/lib/fake-relay.py
# sends an unconditional `device_bound` frame as the FIRST line of every
# stream connection (no gated "hello" handshake), so even claims that never
# touch the device side directly (1, 5, 6, 7) exercise
# pub_from_b64/derive_session_key just by connecting. When the real module is
# absent this suite falls back to a minimal local stub (see "RELAY_CLIENT_RUN"
# below) that fakes those two calls too (never real X25519/HKDF) so claims 1,
# 5, 6 and 7 still run for real. Claims 2, 3 and 4 (state-dedup, seq/replay,
# send-message round-trip) need the REAL crypto (seal/open_ against a real
# session key) and are SKIPPED, loudly and counted, whenever the real module
# is absent -- never faked. The e2e_available grep acceptance line is skipped
# the same way. Claim 8 always runs regardless (it deliberately forces
# e2e_available()==False itself, real module or not).
#
# SPLIT (this file is part 1 of 3). The single 4.9k-line suite outgrew run-all.sh's per-suite budget: it
# TIMEOUT'd at 400 s on a loaded box while every assertion still passed. Its scenarios now live in three
# suites cut at section boundaries -- nothing dropped, every scenario moved verbatim:
#   heimdall-app-relay.test.sh          static shape + scenarios A-N (the client's core protocol, event log, status)
#   heimdall-app-relay-resilience.test.sh   scenarios O-U (IPv6 stall / connect, ack + state retry, persistent connections)
#   heimdall-app-relay-push-ws.test.sh      scenarios W-Z (ordering/digest, push registration, stale-seq refusal, WebSocket leg)
# The shared prelude (sandbox, waits, the e2e stand-in, python3 pin) is test/lib/app-relay-common.sh.

# shellcheck disable=SC2034  # RELAY_SUITE_TITLE is read by test/lib/app-relay-common.sh (sourced next), never in this file
RELAY_SUITE_TITLE="heimdall-app-relay (bin/heimdall-relay-client + hmd app connect --relay oracle) -- part 1/3: core protocol"
# shellcheck source=lib/app-relay-common.sh
# shellcheck disable=SC1091 # without -x shellcheck cannot follow any sourced file; the path above is for -x runs
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/app-relay-common.sh"

# ── 1. syntax / static shape (claims 9-12, 14) ──────────────────────────────
if [ -x "$RELAY_CLIENT" ]; then
  ok "test -x bin/heimdall-relay-client"
else
  bad "bin/heimdall-relay-client is not executable"
fi

AST_ERR="$(mktemp)"
if python3 -c "import ast; ast.parse(open('$RELAY_CLIENT').read())" 2>"$AST_ERR"; then
  ok "python3 ast.parse bin/heimdall-relay-client exits 0"
else
  bad "ast.parse bin/heimdall-relay-client: $(cat "$AST_ERR")"
fi
rm -f "$AST_ERR"

if grep -Eq "collect_state|StateCache" "$RELAY_CLIENT"; then
  ok "bin/heimdall-relay-client references collect_state|StateCache"
else
  bad "bin/heimdall-relay-client does not reference collect_state|StateCache"
fi

if grep -q "companion_ui_inbox" "$RELAY_CLIENT"; then
  ok "bin/heimdall-relay-client references companion_ui_inbox"
else
  bad "bin/heimdall-relay-client does not reference companion_ui_inbox"
fi

if [ "$E2E_PRESENT" = true ]; then
  if grep -q "e2e_available" "$E2E_MOD"; then
    ok "bin/lib/hmd_relay_e2e.py defines/references e2e_available"
  else
    bad "bin/lib/hmd_relay_e2e.py missing e2e_available"
  fi
else
  skip "grep e2e_available bin/lib/hmd_relay_e2e.py: bin/lib/hmd_relay_e2e.py absent"
fi

if grep -q -- "--relay" "$APP"; then
  ok "bin/heimdall-app references --relay"
else
  bad "bin/heimdall-app does not reference --relay"
fi
SYN_ERR="$(mktemp)"
if bash -n "$APP" 2>"$SYN_ERR"; then
  ok "bash -n bin/heimdall-app exits 0"
else
  bad "bash -n bin/heimdall-app: $(cat "$SYN_ERR")"
fi
rm -f "$SYN_ERR"

PYC_ERR="$(mktemp)"
if python3 -m py_compile "$FAKE_RELAY" 2>"$PYC_ERR"; then
  ok "python3 -m py_compile test/lib/fake-relay.py"
else
  bad "py_compile test/lib/fake-relay.py: $(cat "$PYC_ERR")"
fi
rm -f "$PYC_ERR"

BACKOFF_CONST="$(grep -n 'BACKOFF_CAP_MS *= *30000' "$RELAY_CLIENT" || true)"
if [ -n "$BACKOFF_CONST" ]; then
  ok "bin/heimdall-relay-client:BACKOFF_CAP_MS == 30000 ($BACKOFF_CONST)"
else
  bad "bin/heimdall-relay-client BACKOFF_CAP_MS constant not found as 30000"
fi

ENVCAP_ENV_CONST="$(grep -n 'HMD_RELAY_MAX_ENVELOPE_BYTES' "$RELAY_CLIENT" || true)"
if [ -n "$ENVCAP_ENV_CONST" ]; then
  ok "INV-16: bin/heimdall-relay-client MAX_ENVELOPE_BYTES is env-overridable via HMD_RELAY_MAX_ENVELOPE_BYTES ($ENVCAP_ENV_CONST)"
else
  bad "INV-16: bin/heimdall-relay-client does not reference HMD_RELAY_MAX_ENVELOPE_BYTES"
fi

ENVCAP_DEFAULT_CONST="$(grep -n 'MAX_ENVELOPE_BYTES.*1048576\|1048576.*MAX_ENVELOPE_BYTES' "$RELAY_CLIENT" || true)"
if [ -n "$ENVCAP_DEFAULT_CONST" ]; then
  ok "INV-16: bin/heimdall-relay-client default envelope cap is 1048576 / 1 MiB ($ENVCAP_DEFAULT_CONST)"
else
  bad "INV-16: bin/heimdall-relay-client 1048576 default cap not found"
fi

# docs/HANDOFF-TO-HEIMDALL-relay-ipv6-stall.md: the two operator-facing knobs
for IPV6_KNOB in HMD_RELAY_IP_FAMILY HMD_RELAY_ACK_WINDOW_S; do
  if grep -q "$IPV6_KNOB" "$RELAY_CLIENT"; then
    ok "ipv6-stall: bin/heimdall-relay-client reads $IPV6_KNOB"
  else
    bad "ipv6-stall: bin/heimdall-relay-client does not reference $IPV6_KNOB"
  fi
done

# ── Scenario A: claims 1, 2, 3, 4, 5 (single long-lived session) ───────────
REPO_A="$(make_repo)"
PORT_A_RELAY="$(free_port)"
PORT_A_UI="$(free_port)"
LOG_A="$TMPROOT/a.log"; CTL_A="$TMPROOT/a.ctl"
mkdir -p "$LOG_A" "$CTL_A"

python3 "$FAKE_RELAY" serve "$PORT_A_RELAY" --log "$LOG_A" --ctl "$CTL_A" >"$TMPROOT/a.srv.out" 2>&1 &
SRV_A=$!
PIDS+=("$SRV_A")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_A_RELAY))==0 else 1)" && break
  sleep 0.1
done

# Device keygen + bind happen BEFORE the client starts: fake-relay.py's serve
# mode sends device_bound unconditionally on the very FIRST stream connection,
# so the real device pubkey has to already be on disk at ctl/bind-device
# before that connection can happen -- a poll/grace-period on the server side
# would race the client's own near-instant loopback connect.
if [ "$E2E_PRESENT" = true ]; then
  DEV_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEV_PRIV_B64="$(printf '%s' "$DEV_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEV_PUB_B64="$(printf '%s' "$DEV_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEV_PUB_B64" > "$CTL_A/bind-device"
fi

CLIENT_A_OUT="$TMPROOT/a.client.out"
CLIENT_A_ERR="$TMPROOT/a.client.err"
"$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_A_RELAY" --repo "$REPO_A" --ui-port "$PORT_A_UI" \
  >"$CLIENT_A_OUT" 2>"$CLIENT_A_ERR" &
CLIENT_A=$!
PIDS+=("$CLIENT_A")

if wait_for "$CLIENT_A_OUT" '"event":"pair_init"' 10; then
  ok "scenario A: relay-client emitted pair_init"
else
  bad "scenario A: relay-client never emitted pair_init: $(cat "$CLIENT_A_ERR" 2>/dev/null)"
fi

SID_A="$(python3 -c "
import json
for line in open('$CLIENT_A_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
HMD_PUB_A="$(python3 -c "
import json
for line in open('$CLIENT_A_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"

if [ -n "$SID_A" ] && [ -n "$HMD_PUB_A" ]; then
  ok "scenario A: session_id + hmd_pubkey extracted from pair_init"
else
  bad "scenario A: could not extract session_id/hmd_pubkey from pair_init"
fi

# claim 1 (INV-6): every request line carries Bearer, none has ?token=
if [ -s "$LOG_A/requests.log" ]; then
  if grep -q 'token_query=y' "$LOG_A/requests.log"; then
    bad "INV-6: a request line in requests.log carried ?token="
  else
    ok "INV-6: no request line ever carried ?token="
  fi
  if grep -Eq '^POST /session/.*/frames.*auth=n' "$LOG_A/requests.log" \
     || grep -Eq '^GET /session/.*/stream.*auth=n' "$LOG_A/requests.log"; then
    bad "INV-6: a /session/.../frames or /stream request was sent without a Bearer header"
  else
    ok "INV-6: every /session/.../frames|stream request carried a Bearer header"
  fi
else
  bad "INV-6: requests.log is empty -- relay-client never contacted the fake relay"
fi

if [ "$E2E_PRESENT" = true ]; then
  KEY_JSON="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_A" --session-id "$SID_A")"
  SESSION_KEY_A="$(printf '%s' "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  if wait_for "$CLIENT_A_OUT" '"event":"device_bound"' 10; then
    ok "scenario A: device_bound bootstrap derived a session key (no hello frame needed)"
  else
    bad "scenario A: relay-client never emitted device_bound"
  fi

  # delta 4: a keepalive control frame (real wire shape: nonce/ciphertext both
  # JSON null) must be silently recognized, never logged as an error --
  # constructed inline (not via `device envelope`, whose --nonce/--ciphertext
  # argparse args are required non-null strings and can't represent this).
  ERR_COUNT_BEFORE_KEEPALIVE="$(count_matching "$CLIENT_A_OUT" '"event":"error"')"
  python3 -c "
import json, sys
env = {'v': 1, 'session_id': sys.argv[1], 'seq': 0, 'sender': 'relay', 'type': 'keepalive',
       'nonce': None, 'ciphertext': None, 'payload': {'ts': 1758700000}}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    json.dump(env, f)
" "$SID_A" "$CTL_A/001.json"
  sleep 1
  ERR_COUNT_AFTER_KEEPALIVE="$(count_matching "$CLIENT_A_OUT" '"event":"error"')"
  if [ "$ERR_COUNT_AFTER_KEEPALIVE" -eq "$ERR_COUNT_BEFORE_KEEPALIVE" ]; then
    ok "delta 4: keepalive control frame produced no error event ($ERR_COUNT_BEFORE_KEEPALIVE == $ERR_COUNT_AFTER_KEEPALIVE)"
  else
    bad "delta 4: keepalive control frame produced an unexpected error event ($ERR_COUNT_BEFORE_KEEPALIVE -> $ERR_COUNT_AFTER_KEEPALIVE)"
  fi

  # claim 2 (INV-22): exactly one state frame across >=3 idle ticks, then
  # exactly one more after a real state change.
  if wait_for_count "$LOG_A/frames.ndjson" 1 '"type":"state"' 8; then
    ok "scenario A: first state frame sent once state_ready"
  else
    bad "scenario A: no state frame ever appeared"
  fi
  sleep 7  # >=3 idle ticks at the client's default 2s cadence
  STATE_COUNT_1="$(count_matching "$LOG_A/frames.ndjson" '"type":"state"')"
  if [ "$STATE_COUNT_1" -eq 1 ]; then
    ok "INV-22: exactly one state frame across >=3 idle ticks (got $STATE_COUNT_1)"
  else
    bad "INV-22: expected exactly 1 state frame across idle ticks, got $STATE_COUNT_1"
  fi

  ( cd "$REPO_A" && HEIMDALL_WATCH_ROOT="$REPO_A" "$UI" panel set claim2-panel --type number \
      --title "claim 2 probe" --data-json - <<<'{"value":1}' ) >/dev/null 2>&1

  if wait_for_count "$LOG_A/frames.ndjson" 2 '"type":"state"' 8; then
    STATE_COUNT_2="$(count_matching "$LOG_A/frames.ndjson" '"type":"state"')"
    if [ "$STATE_COUNT_2" -eq 2 ]; then
      ok "INV-22: publishing a panel produced exactly one more state frame (got $STATE_COUNT_2)"
    else
      bad "INV-22: expected exactly 2 state frames after panel publish, got $STATE_COUNT_2"
    fi
  else
    bad "INV-22: panel publish never produced a second state frame"
  fi

  # claim 3 (INV-14/15): seq strictly increasing across posted hmd frames;
  # a replayed device seq is rejected.
  SEQS="$(python3 -c "
import json
seqs = []
for line in open('$LOG_A/frames.ndjson'):
    line = line.strip()
    if not line: continue
    o = json.loads(line)
    seqs.append(o['seq'])
print(' '.join(str(s) for s in seqs))
")"
  STRICT_OK=true
  PREV=-1
  for s in $SEQS; do
    if [ "$s" -le "$PREV" ]; then STRICT_OK=false; fi
    PREV="$s"
  done
  if [ "$STRICT_OK" = true ]; then
    ok "INV-14: seq strictly increasing across posted hmd frames ($SEQS)"
  else
    bad "INV-14: seq NOT strictly increasing across posted hmd frames ($SEQS)"
  fi

  # claim 4 (INV-23): send-message round-trips into inbox.jsonl with the same
  # record shape companion_ui_inbox.append() produces; sealed ack {ok:true,id}.
  SEAL_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_A" --seq 1 --sender device \
    --text '{"action":"send-message","params":{"text":"hello from claim4"}}')"
  NONCE1="$(printf '%s' "$SEAL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT1="$(printf '%s' "$SEAL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 1 --sender device \
    --type command --nonce "$NONCE1" --ciphertext "$CT1" > "$CTL_A/002.json"

  INBOX_A="$REPO_A/.heimdall/ui/inbox.jsonl"
  if wait_for "$INBOX_A" '"hello from claim4"' 10; then
    ok "INV-23: send-message round-tripped into .heimdall/ui/inbox.jsonl"
  else
    bad "INV-23: send-message never reached .heimdall/ui/inbox.jsonl"
  fi

  RECORD_A="$(grep '"hello from claim4"' "$INBOX_A" 2>/dev/null | tail -1)"
  RECORD_KEYS="$(printf '%s' "$RECORD_A" | python3 -c "
import json,sys
try:
    o = json.loads(sys.stdin.read())
except Exception:
    print('PARSE_FAIL'); raise SystemExit
missing = [k for k in ('id','ts','text','source') if k not in o]
print('OK' if not missing and o.get('source') == 'companion' else 'BAD:%r' % (missing, o.get('source')))
")"
  if [ "$RECORD_KEYS" = "OK" ]; then
    ok "INV-23: inbox record shape matches companion_ui_inbox.append() (id/ts/text/source=companion)"
  else
    bad "INV-23: inbox record shape mismatch ($RECORD_KEYS)"
  fi

  ACK1_JSON="$(wait_for_ack_of_seq "$LOG_A/frames.ndjson" "$SESSION_KEY_A" 1 10)"
  if [ -n "$ACK1_JSON" ]; then
    ok "scenario A: ack for seq=1 appeared in frames.ndjson"
  else
    bad "scenario A: no ack for seq=1 ever appeared"
  fi
  ACK1_OK="$(printf '%s' "$ACK1_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)"
  ACK1_ID="$(printf '%s' "$ACK1_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
  if [ "$ACK1_OK" = "True" ] && [ -n "$ACK1_ID" ]; then
    ok "INV-23: sealed ack decrypts to {ok:true, id:<uuid>} ($ACK1_ID)"
  else
    bad "INV-23: sealed ack for seq=1 did not decrypt to {ok:true, id:...} (ok=$ACK1_OK id=$ACK1_ID)"
  fi

  # claim 3b (INV-15): replay of seq=1 (already seen) is rejected -- no
  # second inbox record, and its only answer on the wire is ONE sealed
  # refusal ack (a frame that opens is answered, see scenario Y).
  #
  # INV-15 is about the REPLAY's own effect, not the client's independent
  # state-tick loop -- but that loop (bin/heimdall-relay-client's tick_s and
  # sentinels/hmd-ui.py's POLL_INTERVAL_S are both 2s) notices, on its own
  # schedule, that the FIRST (legitimate) send-message above just changed
  # on-disk state (collect_inbox()'s pending count, sentinels/hmd-ui.py:638,
  # 0 -> 1) and republishes a "state" frame once that lands -- anywhere up to
  # ~4s after the write. A count of every posted frame blamed that on the
  # replay (observed: "4 -> 5" with the replay itself still correctly
  # rejected per case 23/24) and had to be drained to quiescence first; the
  # replay's effect is counted in ACKS instead, which no state frame is.
  ACKS_BEFORE_REPLAY="$(sealed_acks "$LOG_A/frames.ndjson" "$SESSION_KEY_A" | wc -l | tr -d ' ')"
  # shellcheck disable=SC2126 # grep|wc -l prints 0 while $INBOX_A does not exist yet; grep -c would print nothing
  INBOX_COUNT_BEFORE="$(grep '"hello from claim4"' "$INBOX_A" 2>/dev/null | wc -l | tr -d ' ')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 1 --sender device \
    --type command --nonce "$NONCE1" --ciphertext "$CT1" > "$CTL_A/003.json"
  if wait_for_event "$CLIENT_A_OUT" "error" "non-increasing seq" 6; then
    ok "INV-15: replayed device seq=1 produced a non-increasing-seq error"
  else
    bad "INV-15: replayed device seq=1 was not rejected with an error event"
  fi
  # the replay is a frame that opens, so it is answered (see scenario Y): one sealed refusal naming the last device seq
  A_REFUSAL="$(wait_for_refusal_ack "$LOG_A/frames.ndjson" "$SESSION_KEY_A" 1 6)"
  if [ "$A_REFUSAL" = '{"detail":"non-increasing-seq","last":1,"of_seq":1,"ok":false}' ]; then
    ok "INV-15: the replay is answered with a sealed refusal naming hmd's last device seq ($A_REFUSAL)"
  else
    bad "INV-15: the replay drew no sealed refusal {detail:non-increasing-seq,last:1,of_seq:1,ok:false} (got '${A_REFUSAL:-nothing}')"
  fi
  sleep 1
  # shellcheck disable=SC2126 # grep|wc -l prints 0 while $INBOX_A does not exist yet; grep -c would print nothing
  INBOX_COUNT_AFTER="$(grep '"hello from claim4"' "$INBOX_A" 2>/dev/null | wc -l | tr -d ' ')"
  ACKS_AFTER_REPLAY="$(sealed_acks "$LOG_A/frames.ndjson" "$SESSION_KEY_A" | wc -l | tr -d ' ')"
  if [ "$INBOX_COUNT_AFTER" -eq "$INBOX_COUNT_BEFORE" ]; then
    ok "INV-15: replay produced no second inbox record ($INBOX_COUNT_BEFORE == $INBOX_COUNT_AFTER)"
  else
    bad "INV-15: replay produced a second inbox record ($INBOX_COUNT_BEFORE -> $INBOX_COUNT_AFTER)"
  fi
  if [ "$ACKS_AFTER_REPLAY" -eq "$((ACKS_BEFORE_REPLAY + 1))" ]; then
    ok "INV-15: replay produced exactly one new ack -- the refusal ($ACKS_BEFORE_REPLAY -> $ACKS_AFTER_REPLAY)"
  else
    bad "INV-15: replay produced $((ACKS_AFTER_REPLAY - ACKS_BEFORE_REPLAY)) new acks, want exactly the one refusal ($ACKS_BEFORE_REPLAY -> $ACKS_AFTER_REPLAY)"
  fi

  # claim 4b (INV-23): too-long text -> ack {ok:false, detail:"too-long"}, no inbox record.
  LONG_TEXT="$(python3 -c 'print("x" * 2001)')"
  SEAL2_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_A" --seq 2 --sender device \
    --text "{\"action\":\"send-message\",\"params\":{\"text\":\"$LONG_TEXT\"}}")"
  NONCE2="$(printf '%s' "$SEAL2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT2="$(printf '%s' "$SEAL2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 2 --sender device \
    --type command --nonce "$NONCE2" --ciphertext "$CT2" > "$CTL_A/004.json"

  ACK2_JSON="$(wait_for_ack_of_seq "$LOG_A/frames.ndjson" "$SESSION_KEY_A" 2 10)"
  if [ -n "$ACK2_JSON" ]; then
    ok "scenario A: ack for seq=2 (too-long) appeared in frames.ndjson"
  else
    bad "scenario A: no ack for seq=2 ever appeared"
  fi
  ACK2_OK="$(printf '%s' "$ACK2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)"
  ACK2_DETAIL="$(printf '%s' "$ACK2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("detail"))' 2>/dev/null)"
  if [ "$ACK2_OK" = "False" ] && [ "$ACK2_DETAIL" = "too-long" ]; then
    ok "INV-23: too-long send-message acked {ok:false, detail:too-long}"
  else
    bad "INV-23: too-long send-message ack mismatch (ok=$ACK2_OK detail=$ACK2_DETAIL)"
  fi
  # shellcheck disable=SC2126 # grep|wc -l prints 0 while $INBOX_A does not exist yet; grep -c would print nothing
  TOOLONG_INBOX_COUNT="$(grep -F "$(printf '%s' "$LONG_TEXT" | head -c 40)" "$INBOX_A" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$TOOLONG_INBOX_COUNT" -eq 0 ]; then
    ok "INV-23: too-long send-message produced no inbox record"
  else
    bad "INV-23: too-long send-message unexpectedly produced an inbox record"
  fi
else
  skip "INV-22/14/15/23 (claims 2-4): bin/lib/hmd_relay_e2e.py absent -- session-key bootstrap needs device seal/open/derive"
fi

# claim 5 (INV-21): end-session -> client emits session_ended and exits 0;
# no frame posted after.
FRAMES_BEFORE_END="$(cat "$LOG_A/frames.ndjson" 2>/dev/null | wc -l | tr -d ' ')"
: > "$CTL_A/end-session"
if wait_pid_exit "$CLIENT_A" 10; then
  wait "$CLIENT_A" 2>/dev/null
  CLIENT_A_RC=$?
  if [ "$CLIENT_A_RC" -eq 0 ]; then
    ok "INV-21: relay-client exited 0 after end-session"
  else
    bad "INV-21: relay-client exited $CLIENT_A_RC after end-session (want 0)"
  fi
else
  bad "INV-21: relay-client never exited after end-session"
  kill -9 "$CLIENT_A" 2>/dev/null
fi
if wait_for "$CLIENT_A_OUT" '"event":"session_ended"' 2; then
  ok "INV-21: relay-client emitted session_ended"
else
  bad "INV-21: relay-client never emitted session_ended"
fi
sleep 0.5
FRAMES_AFTER_END="$(cat "$LOG_A/frames.ndjson" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${FRAMES_AFTER_END:-0}" -eq "${FRAMES_BEFORE_END:-0}" ]; then
  ok "INV-21: no frame posted after session_ended ($FRAMES_BEFORE_END == $FRAMES_AFTER_END)"
else
  bad "INV-21: a frame was posted after session_ended ($FRAMES_BEFORE_END -> $FRAMES_AFTER_END)"
fi

kill "$SRV_A" 2>/dev/null
wait "$SRV_A" 2>/dev/null

# ── Scenario B: claim 6 (INV-26) -- 3 induced drop-streams -> 2000/4000/8000 ─
REPO_B="$(make_repo)"
PORT_B_RELAY="$(free_port)"
PORT_B_UI="$(free_port)"
LOG_B="$TMPROOT/b.log"; CTL_B="$TMPROOT/b.ctl"
mkdir -p "$LOG_B" "$CTL_B"

python3 "$FAKE_RELAY" serve "$PORT_B_RELAY" --log "$LOG_B" --ctl "$CTL_B" >"$TMPROOT/b.srv.out" 2>&1 &
SRV_B=$!
PIDS+=("$SRV_B")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_B_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_B_OUT="$TMPROOT/b.client.out"
: > "$CTL_B/drop-stream"  # refuse the client's very first stream attempt
"$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_B_RELAY" --repo "$REPO_B" --ui-port "$PORT_B_UI" \
  >"$CLIENT_B_OUT" 2>"$TMPROOT/b.client.err" &
CLIENT_B=$!
PIDS+=("$CLIENT_B")

if wait_for "$CLIENT_B_OUT" '"event":"stream_drop","retry_ms":2000' 6; then
  ok "INV-26: 1st induced drop -> stream_drop retry_ms=2000"
else
  bad "INV-26: 1st induced drop never produced stream_drop retry_ms=2000"
fi
: > "$CTL_B/drop-stream"  # induce the 2nd drop during the ~2s backoff wait
if wait_for "$CLIENT_B_OUT" '"event":"stream_drop","retry_ms":4000' 6; then
  ok "INV-26: 2nd induced drop -> stream_drop retry_ms=4000"
else
  bad "INV-26: 2nd induced drop never produced stream_drop retry_ms=4000"
fi
: > "$CTL_B/drop-stream"  # induce the 3rd drop during the ~4s backoff wait
if wait_for "$CLIENT_B_OUT" '"event":"stream_drop","retry_ms":8000' 10; then
  ok "INV-26: 3rd induced drop -> stream_drop retry_ms=8000"
else
  bad "INV-26: 3rd induced drop never produced stream_drop retry_ms=8000"
fi
if wait_for "$CLIENT_B_OUT" '"event":"device_bound"' 12; then
  ok "scenario B: stream reconnected cleanly after the 3rd drop (device_bound observed)"
else
  bad "scenario B: stream never reconnected after the 3rd induced drop"
fi

kill "$CLIENT_B" 2>/dev/null
wait "$CLIENT_B" 2>/dev/null
kill "$SRV_B" 2>/dev/null
wait "$SRV_B" 2>/dev/null

# ── Scenario C: claim 7 (INV-25) -- 429 + Retry-After honored ──────────────
REPO_C="$(make_repo)"
PORT_C_RELAY="$(free_port)"
PORT_C_UI="$(free_port)"
LOG_C="$TMPROOT/c.log"; CTL_C="$TMPROOT/c.ctl"
mkdir -p "$LOG_C" "$CTL_C"

python3 "$FAKE_RELAY" serve "$PORT_C_RELAY" --log "$LOG_C" --ctl "$CTL_C" >"$TMPROOT/c.srv.out" 2>&1 &
SRV_C=$!
PIDS+=("$SRV_C")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_C_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_C_OUT="$TMPROOT/c.client.out"
: > "$CTL_C/rate-limit-next=3"  # rate-limit the client's very first stream attempt
"$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_C_RELAY" --repo "$REPO_C" --ui-port "$PORT_C_UI" \
  >"$CLIENT_C_OUT" 2>"$TMPROOT/c.client.err" &
CLIENT_C=$!
PIDS+=("$CLIENT_C")

if wait_for_count "$LOG_C/requests.log" 1 'GET /session/.*/stream' 6; then
  ok "scenario C: relay-client made its first stream attempt (429'd)"
else
  bad "scenario C: relay-client never attempted the stream"
fi
T0="$(python3 -c 'import time; print(time.time())')"
if wait_for_count "$LOG_C/requests.log" 2 'GET /session/.*/stream' 8; then
  T1="$(python3 -c 'import time; print(time.time())')"
  ELAPSED="$(python3 -c "print($T1 - $T0)")"
  ELAPSED_OK="$(python3 -c "print(1 if $ELAPSED >= 2.5 else 0)")"
  if [ "$ELAPSED_OK" = "1" ]; then
    ok "INV-25: no reconnect attempt before Retry-After elapsed (~${ELAPSED}s >= 2.5s)"
  else
    bad "INV-25: reconnect attempt came too soon after 429 (${ELAPSED}s < 2.5s)"
  fi
else
  bad "INV-25: relay-client never retried the stream after the 429"
fi

kill "$CLIENT_C" 2>/dev/null
wait "$CLIENT_C" 2>/dev/null
kill "$SRV_C" 2>/dev/null
wait "$SRV_C" 2>/dev/null

# ── Scenario D: claim 8 (INV-11/E2E gate) -- e2e_available()==False refuses
# to start a plaintext relay session, via the real `hmd app connect --relay`.
REPO_D="$(make_repo)"
PORT_D_RELAY="$(free_port)"
PORT_D_UI="$(free_port)"
LOG_D="$TMPROOT/d.log"; CTL_D="$TMPROOT/d.ctl"
mkdir -p "$LOG_D" "$CTL_D"

python3 "$FAKE_RELAY" serve "$PORT_D_RELAY" --log "$LOG_D" --ctl "$CTL_D" >"$TMPROOT/d.srv.out" 2>&1 &
SRV_D=$!
PIDS+=("$SRV_D")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_D_RELAY))==0 else 1)" && break
  sleep 0.1
done

STUB_LIB_DIR="$TMPROOT/stub-e2e-lib"
mkdir -p "$STUB_LIB_DIR"
cat > "$STUB_LIB_DIR/hmd_relay_e2e.py" <<'STUB_EOF'
"""Stand-in for bin/lib/hmd_relay_e2e.py that always reports the crypto
backend unavailable -- used only to exercise claim 8 (bin/heimdall-relay-client
main() must refuse to start a plaintext relay session and exit 11 when
e2e_available() is False), regardless of whether the real module has landed
on this branch yet."""


def e2e_available():
    return False
STUB_EOF

STUB_CLIENT="$TMPROOT/stub-relay-client"
cat > "$STUB_CLIENT" <<STUB2_EOF
#!/usr/bin/env bash
# Wraps the REAL bin/heimdall-relay-client, shadowing only
# bin/lib/hmd_relay_e2e.py's import (by writing a fake one at the exact path
# _load_module() resolves) so e2e_available() reads False -- this stub never
# reimplements any relay-client logic itself, it just relocates LIB_DIR via a
# throwaway copy of the tree with one file swapped.
set -u
STUBROOT="$TMPROOT/stub-relay-root"
if [ ! -d "\$STUBROOT" ]; then
  mkdir -p "\$STUBROOT"
  cp -R "$REPO/bin" "\$STUBROOT/bin"
  cp -R "$REPO/sentinels" "\$STUBROOT/sentinels"
  cp "$STUB_LIB_DIR/hmd_relay_e2e.py" "\$STUBROOT/bin/lib/hmd_relay_e2e.py"
fi
exec "\$STUBROOT/bin/heimdall-relay-client" "\$@"
STUB2_EOF
chmod +x "$STUB_CLIENT"

CONNECT_D_OUT="$TMPROOT/d.connect.out"
CONNECT_D_ERR="$TMPROOT/d.connect.err"
# HEIMDALL_RELAY_CLIENT_BIN is bin/heimdall-app's own documented override
# (BIN_DIR/heimdall-relay-client is only its default) -- this points the
# REAL, unmodified `hmd app connect --relay` orchestration at a stub relay
# client whose only difference from the real one is an e2e_available()==False
# bin/lib/hmd_relay_e2e.py, so claim 8 (INV-11's refuse-to-run gate) is
# exercised whether or not the real crypto module has landed on this branch
# yet. bin/heimdall-app itself is never copied or edited.
HEIMDALL_RELAY_CLIENT_BIN="$STUB_CLIENT" "$HEIMDALL" app connect \
  --repo "$REPO_D" --port "$PORT_D_UI" --no-code --relay "http://127.0.0.1:$PORT_D_RELAY" \
  >"$CONNECT_D_OUT" 2>"$CONNECT_D_ERR"
CONNECT_D_RC=$?

if [ "$CONNECT_D_RC" -eq 11 ]; then
  ok "claim 8: hmd app connect --relay exits 11 when e2e_available() is False"
else
  bad "claim 8: hmd app connect --relay exited $CONNECT_D_RC, want 11 (stderr: $(cat "$CONNECT_D_ERR" 2>/dev/null | tail -3))"
fi
if [ ! -s "$LOG_D/frames.ndjson" ]; then
  ok "claim 8: frames.ndjson stayed empty -- no plaintext frame was ever posted"
else
  bad "claim 8: frames.ndjson is non-empty -- a frame was posted despite e2e_available()==False"
fi

# leftover UI/relay-client pids from the connect attempt, if any survived
sf="$REPO_D/.heimdall/app/connect.json"
if [ -f "$sf" ]; then
  leak_pid="$(python3 -c "import json,sys; print(json.load(open('$sf')).get('pid_ui','') or '')" 2>/dev/null)"
  [ -n "$leak_pid" ] && kill -9 "$leak_pid" 2>/dev/null
  leak_client="$(python3 -c "import json,sys; print(json.load(open('$sf')).get('pid_client','') or '')" 2>/dev/null)"
  [ -n "$leak_client" ] && kill -9 "$leak_client" 2>/dev/null
fi

kill "$SRV_D" 2>/dev/null
wait "$SRV_D" 2>/dev/null

# ── Scenario E: delta 5 -- silent GET /stream body times out and reconnects ─
REPO_E="$(make_repo)"
PORT_E_RELAY="$(free_port)"
PORT_E_UI="$(free_port)"
LOG_E="$TMPROOT/e.log"; CTL_E="$TMPROOT/e.ctl"
mkdir -p "$LOG_E" "$CTL_E"

python3 "$FAKE_RELAY" serve "$PORT_E_RELAY" --log "$LOG_E" --ctl "$CTL_E" >"$TMPROOT/e.srv.out" 2>&1 &
SRV_E=$!
PIDS+=("$SRV_E")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_E_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_E_OUT="$TMPROOT/e.client.out"
HMD_RELAY_STREAM_IDLE_S=2 "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_E_RELAY" --repo "$REPO_E" --ui-port "$PORT_E_UI" \
  >"$CLIENT_E_OUT" 2>"$TMPROOT/e.client.err" &
CLIENT_E=$!
PIDS+=("$CLIENT_E")

if wait_for "$CLIENT_E_OUT" '"event":"device_bound"' 10; then
  ok "scenario E: initial stream opened and bound before going silent"
else
  bad "scenario E: relay-client never bound on the first (soon-to-go-silent) stream"
fi

if wait_for "$CLIENT_E_OUT" '"event":"stream_drop".*"reason":"idle"' 8; then
  ok "delta 5: silent stream (no keepalive, no close) produced stream_drop reason=idle within HMD_RELAY_STREAM_IDLE_S"
else
  bad "delta 5: silent stream never produced an idle stream_drop"
fi

if wait_for_count "$LOG_E/requests.log" 2 'GET /session/.*/stream' 8; then
  ok "delta 5: relay-client reopened GET /stream after the idle drop"
else
  bad "delta 5: relay-client never reopened the stream after the idle drop"
fi

kill "$CLIENT_E" 2>/dev/null
wait "$CLIENT_E" 2>/dev/null
kill "$SRV_E" 2>/dev/null
wait "$SRV_E" 2>/dev/null

# ── Scenario F: INV-16 -- sender-side envelope cap raised 128 KiB -> 1 MiB,
# HMD_RELAY_MAX_ENVELOPE_BYTES override, loud error (never a silent drop) ──
# Exercises the REAL RelayClient.send_frame_envelope directly -- imported by
# path via importlib (bin/heimdall-relay-client has no .py suffix, so
# spec_from_file_location cannot infer a loader for it the way this suite's
# other python3 heredocs import .py-suffixed modules; an explicit
# SourceFileLoader is required instead) -- against the REAL fake relay over
# HTTP. Not a subprocess + tick-loop this time: producing a real, oversized
# `state` frame would mean inflating actual repo state (panels/roster/etc,
# capped well under 1 MiB and owned by a sibling task's state-payload work,
# never touched here). send_frame_envelope's cap check is agnostic to
# nonce/ciphertext content -- it only measures the serialized envelope's byte
# length -- so a synthetic, precisely-sized (never real AEAD) ciphertext
# exercises the exact same code path a real oversized state frame would,
# without needing real crypto or real state. Runs unconditionally (not gated
# on $E2E_PRESENT, unlike claims 2-4): $RELAY_CLIENT_RUN's own E2E module --
# real or the minstub swapped in above -- always answers
# generate_keypair()/pub_b64(), all pair_init() needs; seal/open_ (the only
# calls the minstub lacks) are never exercised by this scenario.
REPO_F="$(make_repo)"
PORT_F_RELAY="$(free_port)"
LOG_F="$TMPROOT/f.log"; CTL_F="$TMPROOT/f.ctl"
mkdir -p "$LOG_F" "$CTL_F"

python3 "$FAKE_RELAY" serve "$PORT_F_RELAY" --log "$LOG_F" --ctl "$CTL_F" >"$TMPROOT/f.srv.out" 2>&1 &
SRV_F=$!
PIDS+=("$SRV_F")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_F_RELAY))==0 else 1)" && break
  sleep 0.1
done

CAP_OUT="$TMPROOT/f.cap.out"
python3 - "$RELAY_CLIENT_RUN" "http://127.0.0.1:$PORT_F_RELAY" "$REPO_F" >"$CAP_OUT" 2>"$TMPROOT/f.cap.err" <<'PYEOF'
import argparse, importlib.util, json, os, sys
from importlib.machinery import SourceFileLoader

client_path, relay_url, repo_dir = sys.argv[1:4]


def load_client(name, env_value):
    if env_value is None:
        os.environ.pop("HMD_RELAY_MAX_ENVELOPE_BYTES", None)
    else:
        os.environ["HMD_RELAY_MAX_ENVELOPE_BYTES"] = env_value
    loader = SourceFileLoader(name, client_path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def new_client(mod):
    args = argparse.Namespace(relay=relay_url, repo=repo_dir, ui_port=0,
                               public_host=None, status_file=None, tick_s=2.0)
    client = mod.RelayClient(args)
    client.priv, client.pub = mod.E2E.generate_keypair()
    rc = client.pair_init()
    if rc != 0:
        print("RESULT setup_failed rc=%d" % rc)
        sys.exit(2)
    return client


def base_envelope_len(client, type_, seq):
    env = {"v": 1, "session_id": client.session_id, "seq": seq, "sender": "hmd",
           "type": type_, "nonce": "A" * 16, "ciphertext": "", "payload": None}
    return len(json.dumps(env, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def sized_nonce_ciphertext(client, type_, seq, target_bytes):
    pad = max(0, target_bytes - base_envelope_len(client, type_, seq))
    return "A" * 16, "B" * pad


# ── case a: ~600 KiB envelope, default cap (1 MiB) -- must be POSTED ────────
mod_default = load_client("hmd_relay_client_capcheck_default", None)
print("RESULT case_a_cap_constant %d" % mod_default.MAX_ENVELOPE_BYTES)
client_a = new_client(mod_default)
nonce_a, ct_a = sized_nonce_ciphertext(client_a, "state", 0, 600000)
delivered_a, nbytes_a = client_a.send_frame_envelope("state", nonce_a, ct_a, 0)
print("RESULT case_a_delivered %r" % (delivered_a,))
print("RESULT case_a_bytes %d" % nbytes_a)
print("RESULT case_a_over_old_cap %r" % (nbytes_a > 131072,))
print("RESULT case_a_under_new_cap %r" % (nbytes_a < mod_default.MAX_ENVELOPE_BYTES,))

# ── case b: > default 1 MiB cap -- must be refused LOCALLY, loudly ──────────
nonce_b, ct_b = sized_nonce_ciphertext(client_a, "state", 1, 1100000)
delivered_b, nbytes_b = client_a.send_frame_envelope("state", nonce_b, ct_b, 1)
print("RESULT case_b_delivered %r" % (delivered_b,))
print("RESULT case_b_bytes %d" % nbytes_b)
print("RESULT case_b_over_new_cap %r" % (nbytes_b > mod_default.MAX_ENVELOPE_BYTES,))

# ── case c: same ~600 KiB envelope as (a), but HMD_RELAY_MAX_ENVELOPE_BYTES
# overridden small -- must now fail loudly where (a) succeeded ──────────────
mod_small = load_client("hmd_relay_client_capcheck_small", "1000")
print("RESULT case_c_cap_constant %d" % mod_small.MAX_ENVELOPE_BYTES)
client_c = new_client(mod_small)
nonce_c, ct_c = sized_nonce_ciphertext(client_c, "state", 0, 600000)
delivered_c, nbytes_c = client_c.send_frame_envelope("state", nonce_c, ct_c, 0)
print("RESULT case_c_delivered %r" % (delivered_c,))
print("RESULT case_c_bytes %d" % nbytes_c)

sys.exit(0)
PYEOF
CAP_RC=$?

if [ "$CAP_RC" -eq 0 ]; then
  ok "INV-16: cap-check harness (pair_init + send_frame_envelope x3) exited 0"
else
  bad "INV-16: cap-check harness exited $CAP_RC -- $(cat "$TMPROOT/f.cap.err")"
fi

CAP_A_CONST="$(grep -o 'RESULT case_a_cap_constant [0-9]*' "$CAP_OUT" | awk '{print $3}')"
if [ "$CAP_A_CONST" = "1048576" ]; then
  ok "INV-16: default MAX_ENVELOPE_BYTES is 1048576 (1 MiB) at import time"
else
  bad "INV-16: default MAX_ENVELOPE_BYTES was '$CAP_A_CONST', expected 1048576"
fi

if grep -q 'RESULT case_a_delivered True' "$CAP_OUT"; then
  ok "case a: ~600 KiB state envelope (previously dropped under the 128 KiB cap) is now posted"
else
  bad "case a: ~600 KiB state envelope was not delivered -- $(grep case_a "$CAP_OUT")"
fi

if grep -q 'RESULT case_a_over_old_cap True' "$CAP_OUT" && grep -q 'RESULT case_a_under_new_cap True' "$CAP_OUT"; then
  ok "case a: envelope size is genuinely between the old 128 KiB cap and the new 1 MiB cap"
else
  bad "case a: envelope size fixture is not between the old and new caps -- $(grep case_a "$CAP_OUT")"
fi

NBYTES_B="$(grep -o 'RESULT case_b_bytes [0-9]*' "$CAP_OUT" | awk '{print $3}')"
if grep -q 'RESULT case_b_delivered None' "$CAP_OUT"; then
  ok "case b: over-cap (>1 MiB) envelope is refused locally (never reaches the network)"
else
  bad "case b: over-cap envelope was not refused -- $(grep case_b "$CAP_OUT")"
fi

if [ -n "$NBYTES_B" ] && wait_for_event "$CAP_OUT" "error" "dropped: ${NBYTES_B} bytes exceeds 1048576 cap" 2; then
  ok "case b: error event names both the frame's size ($NBYTES_B) and the cap (1048576)"
else
  bad "case b: no error event naming size+cap for the over-cap frame -- $(grep '\"event\":\"error\"' "$CAP_OUT")"
fi

CAP_C_CONST="$(grep -o 'RESULT case_c_cap_constant [0-9]*' "$CAP_OUT" | awk '{print $3}')"
if [ "$CAP_C_CONST" = "1000" ]; then
  ok "case c: HMD_RELAY_MAX_ENVELOPE_BYTES=1000 override took effect on the module constant"
else
  bad "case c: cap override did not take effect, saw '$CAP_C_CONST' instead of 1000"
fi

NBYTES_C="$(grep -o 'RESULT case_c_bytes [0-9]*' "$CAP_OUT" | awk '{print $3}')"
if grep -q 'RESULT case_c_delivered None' "$CAP_OUT"; then
  ok "case c: the SAME ~600 KiB envelope that succeeded in case a now fails loudly under the small override"
else
  bad "case c: envelope was not rejected under the small cap override -- $(grep case_c "$CAP_OUT")"
fi

if [ -n "$NBYTES_C" ] && wait_for_event "$CAP_OUT" "error" "dropped: ${NBYTES_C} bytes exceeds 1000 cap" 2; then
  ok "case c: error event names both the frame's size ($NBYTES_C) and the overridden cap (1000)"
else
  bad "case c: no error event naming size+overridden-cap -- $(grep '\"event\":\"error\"' "$CAP_OUT")"
fi

wait_for_count "$LOG_F/frames.ndjson" 1 '.' 3 >/dev/null 2>&1 || true
FRAMES_F_COUNT="$(wc -l < "$LOG_F/frames.ndjson" 2>/dev/null | tr -d ' ')"
[ -z "$FRAMES_F_COUNT" ] && FRAMES_F_COUNT=0
if [ "$FRAMES_F_COUNT" -eq 1 ]; then
  ok "INV-16: exactly one frame reached the relay (case a's ~600 KiB frame) -- cases b and c never posted"
else
  bad "INV-16: expected exactly 1 posted frame (case a only), got $FRAMES_F_COUNT"
fi

kill "$SRV_F" 2>/dev/null
wait "$SRV_F" 2>/dev/null

# ── Scenario G: relay-client-fixes.md §13 -- an oversized stream line (no
# newline) is capped, dropped with reason=overflow + byte counts, and the
# client keeps running (reconnects and re-binds) ───────────────────────────
REPO_G="$(make_repo)"
PORT_G_RELAY="$(free_port)"
PORT_G_UI="$(free_port)"
LOG_G="$TMPROOT/g.log"; CTL_G="$TMPROOT/g.ctl"
mkdir -p "$LOG_G" "$CTL_G"

python3 "$FAKE_RELAY" serve "$PORT_G_RELAY" --log "$LOG_G" --ctl "$CTL_G" >"$TMPROOT/g.srv.out" 2>&1 &
SRV_G=$!
PIDS+=("$SRV_G")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_G_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_G_OUT="$TMPROOT/g.client.out"
: > "$CTL_G/oversized-line=4000"
HMD_RELAY_MAX_ENVELOPE_BYTES=2000 "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_G_RELAY" --repo "$REPO_G" --ui-port "$PORT_G_UI" \
  >"$CLIENT_G_OUT" 2>"$TMPROOT/g.client.err" &
CLIENT_G=$!
PIDS+=("$CLIENT_G")

if wait_for "$CLIENT_G_OUT" '"event":"device_bound"' 10; then
  ok "scenario G: initial stream bound before the oversized line"
else
  bad "scenario G: relay-client never bound on the first stream"
fi

OVERFLOW_JSON_G="$(wait_for_stream_drop "$CLIENT_G_OUT" "overflow" 8)"
if [ -n "$OVERFLOW_JSON_G" ]; then
  ok "§13: oversized stream line produced stream_drop reason=overflow"
else
  bad "§13: oversized stream line never produced an overflow stream_drop"
fi
LINE_BYTES_G="$(printf '%s' "$OVERFLOW_JSON_G" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("line_bytes"))' 2>/dev/null)"
CAP_BYTES_G="$(printf '%s' "$OVERFLOW_JSON_G" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cap_bytes"))' 2>/dev/null)"
if [ "$LINE_BYTES_G" = "2001" ] && [ "$CAP_BYTES_G" = "2001" ]; then
  ok "§13: overflow stream_drop names line_bytes=cap_bytes=2001 (HMD_RELAY_MAX_ENVELOPE_BYTES=2000 + 1)"
else
  bad "§13: overflow stream_drop byte counts wrong (line_bytes=$LINE_BYTES_G cap_bytes=$CAP_BYTES_G, want 2001/2001)"
fi

if wait_for_count "$CLIENT_G_OUT" 2 '"event":"device_bound"' 10; then
  ok "§13: client kept running -- reconnected and re-bound after the overflow drop"
else
  bad "§13: client never reconnected/re-bound after the overflow drop"
fi

kill "$CLIENT_G" 2>/dev/null
wait "$CLIENT_G" 2>/dev/null
kill "$SRV_G" 2>/dev/null
wait "$SRV_G" 2>/dev/null

# ── Scenario H: relay-client-fixes.md §16 -- planned client-side stream
# self-rotation at HMD_RELAY_STREAM_ROTATE_S, well below the relay's own
# stream-lifetime bound, with no backoff delay on the reconnect ────────────
REPO_H="$(make_repo)"
PORT_H_RELAY="$(free_port)"
PORT_H_UI="$(free_port)"
LOG_H="$TMPROOT/h.log"; CTL_H="$TMPROOT/h.ctl"
mkdir -p "$LOG_H" "$CTL_H"

python3 "$FAKE_RELAY" serve "$PORT_H_RELAY" --log "$LOG_H" --ctl "$CTL_H" >"$TMPROOT/h.srv.out" 2>&1 &
SRV_H=$!
PIDS+=("$SRV_H")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_H_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_H_OUT="$TMPROOT/h.client.out"
T0_H="$(python3 -c 'import time; print(time.time())')"
HMD_RELAY_STREAM_ROTATE_S=3 "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_H_RELAY" --repo "$REPO_H" --ui-port "$PORT_H_UI" \
  >"$CLIENT_H_OUT" 2>"$TMPROOT/h.client.err" &
CLIENT_H=$!
PIDS+=("$CLIENT_H")

if wait_for "$CLIENT_H_OUT" '"event":"device_bound"' 10; then
  ok "scenario H: initial stream bound before rotation"
else
  bad "scenario H: relay-client never bound on the first stream"
fi

ROTATE_JSON_H="$(wait_for_stream_drop "$CLIENT_H_OUT" "rotate" 5)"
T1_H="$(python3 -c 'import time; print(time.time())')"
if [ -n "$ROTATE_JSON_H" ]; then
  ok "§16: client self-rotated (stream_drop reason=rotate) within HMD_RELAY_STREAM_ROTATE_S=3"
  ELAPSED_H="$(python3 -c "print($T1_H - $T0_H)")"
  ELAPSED_H_OK="$(python3 -c "print(1 if 2.5 <= $ELAPSED_H <= 8 else 0)")"
  if [ "$ELAPSED_H_OK" = "1" ]; then
    ok "§16: rotation happened at roughly the configured 3s mark (~${ELAPSED_H}s)"
  else
    bad "§16: rotation timing off (~${ELAPSED_H}s, want roughly 2.5-8s)"
  fi
  RETRY_MS_H="$(printf '%s' "$ROTATE_JSON_H" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("retry_ms"))' 2>/dev/null)"
  if [ "$RETRY_MS_H" = "0" ]; then
    ok "§16: rotate stream_drop carries retry_ms=0 (no backoff delay)"
  else
    bad "§16: rotate stream_drop retry_ms was '$RETRY_MS_H', want 0"
  fi
else
  bad "§16: client never self-rotated within the configured rotate interval"
  bad "§16: cannot check rotation timing -- no rotate event observed"
  bad "§16: cannot check retry_ms -- no rotate event observed"
fi

if wait_for_count "$CLIENT_H_OUT" 2 '"event":"device_bound"' 5; then
  ok "§16: client resumed -- reconnected and re-bound immediately after rotation"
else
  bad "§16: client never reconnected/re-bound after rotation"
fi

kill "$CLIENT_H" 2>/dev/null
wait "$CLIENT_H" 2>/dev/null
kill "$SRV_H" 2>/dev/null
wait "$SRV_H" 2>/dev/null

# ── Scenario I: relay-client-fixes.md §15 -- a clean stream close with no
# other local cause (idle/overflow/rotate all ruled out -- the observable
# signature of a relay-side Durable Object generation rollover after a
# deploy, see hmdapp docs/RELAY-OPERATIONS.md "Deploy impact on live
# sessions") warns and reconnects with backoff actually honored ───────────
REPO_I="$(make_repo)"
PORT_I_RELAY="$(free_port)"
PORT_I_UI="$(free_port)"
LOG_I="$TMPROOT/i.log"; CTL_I="$TMPROOT/i.ctl"
mkdir -p "$LOG_I" "$CTL_I"

python3 "$FAKE_RELAY" serve "$PORT_I_RELAY" --log "$LOG_I" --ctl "$CTL_I" >"$TMPROOT/i.srv.out" 2>&1 &
SRV_I=$!
PIDS+=("$SRV_I")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_I_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_I_OUT="$TMPROOT/i.client.out"
HMD_RELAY_BACKOFF_BASE_MS=500 HMD_RELAY_STREAM_ROTATE_S=120 \
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_I_RELAY" --repo "$REPO_I" --ui-port "$PORT_I_UI" \
  >"$CLIENT_I_OUT" 2>"$TMPROOT/i.client.err" &
CLIENT_I=$!
PIDS+=("$CLIENT_I")

if wait_for "$CLIENT_I_OUT" '"event":"device_bound"' 10; then
  ok "scenario I: initial stream bound before the lifetime-close"
else
  bad "scenario I: relay-client never bound on the first stream"
fi

T0_I="$(python3 -c 'import time; print(time.time())')"
: > "$CTL_I/lifetime-close"

if wait_for_event "$CLIENT_I_OUT" "error" "relay deploy" 8; then
  ok "§15: clean stream close emitted a WARN-shaped error event naming a possible relay deploy"
else
  bad "§15: clean stream close never emitted the expected warn error event"
fi

CLOSED_JSON_I="$(wait_for_stream_drop "$CLIENT_I_OUT" "closed" 2)"
if [ -n "$CLOSED_JSON_I" ]; then
  ok "§15: clean stream close produced stream_drop reason=closed"
else
  bad "§15: clean stream close never produced stream_drop reason=closed"
fi

RETRY_MS_I="$(printf '%s' "$CLOSED_JSON_I" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("retry_ms"))' 2>/dev/null)"
if [ "$RETRY_MS_I" = "500" ]; then
  ok "§15: closed stream_drop carries retry_ms=500 -- HMD_RELAY_BACKOFF_BASE_MS override reached the event, not the 2000ms default"
else
  bad "§15: closed stream_drop retry_ms was '$RETRY_MS_I', want 500 (HMD_RELAY_BACKOFF_BASE_MS override)"
fi

if wait_for_count "$CLIENT_I_OUT" 2 '"event":"device_bound"' 6; then
  ok "§15: client reconnected and re-bound after the warn"
  T1_I="$(python3 -c 'import time; print(time.time())')"
  ELAPSED_I="$(python3 -c "print($T1_I - $T0_I)")"
  # retry_ms above is the direct, load-independent proof the override was
  # honored. This is deliberately just a loose lower-bound sanity check that
  # SOME real wait happened (a broken/skipped backoff reconnects near-
  # instantly) -- not a tight upper-bound window: this suite runs scenario I
  # after 8 earlier scenarios whose fake-relay/client processes are only
  # reaped by the final EXIT trap, so scheduling overhead alone measured up
  # to ~2s here under full-suite load. A tight upper bound was measuring
  # machine load, not correctness, and that's exactly what made it flaky.
  ELAPSED_I_OK="$(python3 -c "print(1 if $ELAPSED_I >= 0.15 else 0)")"
  if [ "$ELAPSED_I_OK" = "1" ]; then
    ok "§15: reconnect wasn't instant -- a real backoff wait occurred (~${ELAPSED_I}s)"
  else
    bad "§15: reconnect happened too fast (~${ELAPSED_I}s) -- backoff wait looks skipped"
  fi
else
  bad "§15: client never reconnected/re-bound after the warn"
  bad "§15: cannot check backoff timing -- no reconnect observed"
fi

kill "$CLIENT_I" 2>/dev/null
wait "$CLIENT_I" 2>/dev/null
kill "$SRV_I" 2>/dev/null
wait "$SRV_I" 2>/dev/null

# ── Scenario G: session-semantics round 2 (§7/§7c/§8/§9) ───────────────────
# hmdapp docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md, round 2 (§7-§9):
# hmd's first sealed frame must start at seq=1, not 0 (audit #3); a device
# rebind must re-send current state even with an unchanged digest (§7c); a
# frame that fails to decrypt must never advance the replay guard (audit
# #5); the session key is derived once, on the first device_bound, and
# latched (audit #1). Gated on $E2E_PRESENT like claims 2-4: needs real
# seal/open/derive, never the minstub.
if [ "$E2E_PRESENT" = true ]; then
  REPO_G="$(make_repo)"
  PORT_G_RELAY="$(free_port)"
  PORT_G_UI="$(free_port)"
  LOG_G="$TMPROOT/g.log"; CTL_G="$TMPROOT/g.ctl"
  mkdir -p "$LOG_G" "$CTL_G"

  python3 "$FAKE_RELAY" serve "$PORT_G_RELAY" --log "$LOG_G" --ctl "$CTL_G" >"$TMPROOT/g.srv.out" 2>&1 &
  SRV_G=$!
  PIDS+=("$SRV_G")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_G_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  DEV1_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEV1_PRIV_B64="$(printf '%s' "$DEV1_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEV1_PUB_B64="$(printf '%s' "$DEV1_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEV1_PUB_B64" > "$CTL_G/bind-device"

  CLIENT_G_OUT="$TMPROOT/g.client.out"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_G_RELAY" --repo "$REPO_G" --ui-port "$PORT_G_UI" \
    >"$CLIENT_G_OUT" 2>"$TMPROOT/g.client.err" &
  CLIENT_G=$!
  PIDS+=("$CLIENT_G")

  if wait_for "$CLIENT_G_OUT" '"event":"pair_init"' 10; then
    ok "scenario G: relay-client emitted pair_init"
  else
    bad "scenario G: relay-client never emitted pair_init"
  fi
  SID_G="$(python3 -c "
import json
for line in open('$CLIENT_G_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  HMD_PUB_G="$(python3 -c "
import json
for line in open('$CLIENT_G_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"

  if wait_for "$CLIENT_G_OUT" '"event":"device_bound"' 10; then
    ok "scenario G: first device_bound derived a session key"
  else
    bad "scenario G: relay-client never emitted the first device_bound"
  fi

  SESSION_KEY_G="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV1_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_G" --session-id "$SID_G" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # ── §7 (round 2, audit #3): hmd's first sealed frame carries seq 1 ───────
  if wait_for_count "$LOG_G/frames.ndjson" 1 '"sender":"hmd"' 8; then
    FIRST_HMD_SEQ="$(python3 -c "
import json
for line in open('$LOG_G/frames.ndjson'):
    line = line.strip()
    if not line: continue
    o = json.loads(line)
    if o.get('sender') == 'hmd':
        print(o['seq']); break
")"
    if [ "$FIRST_HMD_SEQ" = "1" ]; then
      ok "audit #3: hmd's first sealed frame carries seq=1 (got $FIRST_HMD_SEQ)"
    else
      bad "audit #3: hmd's first sealed frame carried seq=$FIRST_HMD_SEQ, want 1"
    fi
  else
    bad "audit #3: no sender=hmd frame ever appeared to check its seq"
  fi

  # ── §8 (audit #5): a forged command that fails to decrypt must never
  # advance last_device_seq -- a real frame at the true next seq is still
  # accepted afterward (a corrupted-in-transit frame must never become a
  # permanent denial-of-service on every later genuine command).
  FORGED_SEQ_G=9007199254740991
  SEAL_BAD_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_G" --seq "$FORGED_SEQ_G" --sender device \
    --text '{"action":"send-message","params":{"text":"forged"}}')"
  NONCE_BAD_G="$(printf '%s' "$SEAL_BAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT_BAD_GOOD_G="$(printf '%s' "$SEAL_BAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  CT_BAD_G="$(python3 -c "
import base64, sys
raw = bytearray(base64.b64decode(sys.argv[1]))
raw[0] ^= 0x01
print(base64.b64encode(bytes(raw)).decode('ascii'))
" "$CT_BAD_GOOD_G")"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_G" --seq "$FORGED_SEQ_G" --sender device \
    --type command --nonce "$NONCE_BAD_G" --ciphertext "$CT_BAD_G" > "$CTL_G/002.json"

  if wait_for_event "$CLIENT_G_OUT" "command" "decrypt-failed" 8; then
    ok "audit #5: forged high-seq frame with a corrupted ciphertext failed to decrypt, as expected"
  else
    bad "audit #5: forged frame did not produce a command/decrypt-failed event"
  fi

  SEAL_G1_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_G" --seq 1 --sender device \
    --text '{"action":"send-message","params":{"text":"hello after forged frame"}}')"
  NONCE_G1="$(printf '%s' "$SEAL_G1_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT_G1="$(printf '%s' "$SEAL_G1_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_G" --seq 1 --sender device \
    --type command --nonce "$NONCE_G1" --ciphertext "$CT_G1" > "$CTL_G/003.json"

  ACK_G1_JSON="$(wait_for_ack_of_seq "$LOG_G/frames.ndjson" "$SESSION_KEY_G" 1 10)"
  ACK_G1_OK="$(printf '%s' "$ACK_G1_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)"
  if [ "$ACK_G1_OK" = "True" ]; then
    ok "audit #5: last_device_seq was not advanced by the forged frame -- the real next seq=1 was still accepted"
  else
    bad "audit #5: seq=1 was rejected after the forged high-seq frame -- last_device_seq was corrupted (ack=$ACK_G1_JSON)"
  fi

  # ── §7c: a device rebind (repeated device_bound, same device pubkey) must
  # re-send the current sealed state frame even though its digest hasn't
  # changed -- digest dedup (INV-22) must never suppress a post-rebind
  # resync, since the phone's own local state was just reset by the rebind.
  # Drain to quiescence first, same reasoning as INV-15's replay check above
  # (line 631): the send-message just acked (seq=1, "hello after forged
  # frame") appends to .heimdall/ui/inbox.jsonl, which organically changes
  # collect_state()'s digest and republishes a "state" frame on the tick
  # loop's own schedule, anywhere up to ~4s later. Snapshotting the "before"
  # count immediately would race that unrelated fallout against the rebind's
  # effect -- exactly the hazard wait_for_quiescent_count's docstring names.
  wait_for_quiescent_count "$LOG_G/frames.ndjson" 3 20
  STATE_COUNT_BEFORE_REBIND_G="$(count_matching "$LOG_G/frames.ndjson" '"sender":"hmd".*"type":"state"')"
  BOUND_AT_REBIND_G="$(python3 -c 'import time; print(int(time.time()))')"
  python3 -c "
import json
env = {
    'v': 1, 'session_id': '$SID_G', 'seq': 0, 'sender': 'relay',
    'type': 'device_bound', 'nonce': None, 'ciphertext': None,
    'payload': {'device_pubkey': '$DEV1_PUB_B64', 'bound_at': $BOUND_AT_REBIND_G},
}
open('$CTL_G/004.json', 'w').write(json.dumps(env))
"
  if wait_for_count "$LOG_G/frames.ndjson" "$((STATE_COUNT_BEFORE_REBIND_G + 1))" '"sender":"hmd".*"type":"state"' 10; then
    ok "§7c: rebind (same device pubkey) re-sent current state despite an unchanged digest"
  else
    bad "§7c: rebind produced no fresh state frame -- digest dedup suppressed the resync"
  fi

  # ── §9 (audit #1): the session key is latched at the FIRST device_bound and
  # never re-derived after -- a device_bound carrying a DIFFERENT device_pubkey
  # must be loudly rejected, never silently adopted. Without the latch, a
  # relay bug (or a malicious relay) could rebind an already-paired session
  # onto an attacker-controlled device key with no visible error.
  DEV2_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEV2_PUB_B64="$(printf '%s' "$DEV2_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  BOUND_AT_HIJACK_G="$(python3 -c 'import time; print(int(time.time()))')"
  python3 -c "
import json
env = {
    'v': 1, 'session_id': '$SID_G', 'seq': 0, 'sender': 'relay',
    'type': 'device_bound', 'nonce': None, 'ciphertext': None,
    'payload': {'device_pubkey': '$DEV2_PUB_B64', 'bound_at': $BOUND_AT_HIJACK_G},
}
open('$CTL_G/005.json', 'w').write(json.dumps(env))
"
  if wait_for_event "$CLIENT_G_OUT" "error" "already latched" 8; then
    ok "audit #1: device_bound with a different device_pubkey was rejected, not adopted"
  else
    bad "audit #1: a differing-key device_bound was not rejected with the expected error"
  fi

  SEAL_G2_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_G" --seq 2 --sender device \
    --text '{"action":"send-message","params":{"text":"still using the original key"}}')"
  NONCE_G2="$(printf '%s' "$SEAL_G2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT_G2="$(printf '%s' "$SEAL_G2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_G" --seq 2 --sender device \
    --type command --nonce "$NONCE_G2" --ciphertext "$CT_G2" > "$CTL_G/006.json"

  ACK_G2_JSON="$(wait_for_ack_of_seq "$LOG_G/frames.ndjson" "$SESSION_KEY_G" 2 10)"
  ACK_G2_OK="$(printf '%s' "$ACK_G2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)"
  if [ "$ACK_G2_OK" = "True" ]; then
    ok "audit #1: original session key still works after the hijack attempt -- key was never re-derived"
  else
    bad "audit #1: original session key no longer works after the hijack attempt -- key was re-derived/overwritten (ack=$ACK_G2_JSON)"
  fi

  kill "$CLIENT_G" 2>/dev/null
  wait "$CLIENT_G" 2>/dev/null
  kill "$SRV_G" 2>/dev/null
  wait "$SRV_G" 2>/dev/null
else
  skip "scenario G (session-semantics round 2, §7/§7c/§8/§9): bin/lib/hmd_relay_e2e.py absent -- needs device seal/open/derive"
fi

# ── Scenario J: docs/HANDOFF-TO-HEIMDALL-relay-send-ack.md "New ask" -- every
# stdout event is durably mirrored, in order, to the default
# <repo>/.heimdall/app/relay-events.jsonl, each log line adding only an
# ISO-8601 UTC "ts" field the stdout copy never carries. Compared only AFTER
# the client has been stopped (never while it is still running), so a
# straggler periodic tick can never turn this into a race against a moving
# target ─────────────────────────────────────────────────────────────────────
REPO_J="$(make_repo)"
PORT_J_RELAY="$(free_port)"
PORT_J_UI="$(free_port)"
LOG_J="$TMPROOT/j.log"; CTL_J="$TMPROOT/j.ctl"
mkdir -p "$LOG_J" "$CTL_J"

python3 "$FAKE_RELAY" serve "$PORT_J_RELAY" --log "$LOG_J" --ctl "$CTL_J" >"$TMPROOT/j.srv.out" 2>&1 &
SRV_J=$!
PIDS+=("$SRV_J")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_J_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_J_OUT="$TMPROOT/j.client.out"
"$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_J_RELAY" --repo "$REPO_J" --ui-port "$PORT_J_UI" \
  >"$CLIENT_J_OUT" 2>"$TMPROOT/j.client.err" &
CLIENT_J=$!
PIDS+=("$CLIENT_J")

EVENT_LOG_J="$REPO_J/.heimdall/app/relay-events.jsonl"
if wait_for "$CLIENT_J_OUT" '"event":"device_bound"' 10; then
  ok "scenario J: relay-client bound (stdout)"
else
  bad "scenario J: relay-client never bound -- cannot test durable event log"
fi
wait_for "$EVENT_LOG_J" '"event":"device_bound"' 10 || true

wait_for_quiescent_count "$CLIENT_J_OUT" 1 5 || true
kill "$CLIENT_J" 2>/dev/null
wait "$CLIENT_J" 2>/dev/null
kill "$SRV_J" 2>/dev/null
wait "$SRV_J" 2>/dev/null

if [ -f "$EVENT_LOG_J" ]; then
  ok "durable event log: default path <repo>/.heimdall/app/relay-events.jsonl was created"
else
  bad "durable event log: $EVENT_LOG_J was never created"
fi

STDOUT_LINES_J="$(wc -l < "$CLIENT_J_OUT" 2>/dev/null | tr -d ' ')"
LOG_LINES_J="$(wc -l < "$EVENT_LOG_J" 2>/dev/null | tr -d ' ')"
[ -z "$STDOUT_LINES_J" ] && STDOUT_LINES_J=0
[ -z "$LOG_LINES_J" ] && LOG_LINES_J=0
if [ "$LOG_LINES_J" -eq "$STDOUT_LINES_J" ] && [ "$LOG_LINES_J" -gt 0 ]; then
  ok "durable event log: line count matches stdout exactly ($LOG_LINES_J lines, client fully stopped before compare)"
else
  bad "durable event log: line count mismatch -- stdout=$STDOUT_LINES_J log=$LOG_LINES_J"
fi

ORDER_OUT_J="$TMPROOT/j.order.out"
python3 - "$CLIENT_J_OUT" "$EVENT_LOG_J" >"$ORDER_OUT_J" 2>"$TMPROOT/j.order.err" <<'PYEOF'
import json, sys


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


stdout_events = load(sys.argv[1])
log_events = load(sys.argv[2])
if len(stdout_events) != len(log_events) or not stdout_events:
    print("RESULT order_ok False")
    sys.exit(0)
for so, lo in zip(stdout_events, log_events):
    lo = dict(lo)
    ts = lo.pop("ts", None)
    if lo != so or not isinstance(ts, str) or not ts.endswith("Z"):
        print("RESULT order_ok False")
        sys.exit(0)
print("RESULT order_ok True")
PYEOF
ORDER_OK_J="$(grep -o 'RESULT order_ok [A-Za-z]*' "$ORDER_OUT_J" | awk '{print $3}')"
if [ "$ORDER_OK_J" = "True" ]; then
  ok "durable event log: every line matches stdout in order, plus one added ISO-8601 UTC 'ts' field"
else
  bad "durable event log: content/order/ts mismatch against stdout (got '$ORDER_OK_J') -- $(cat "$TMPROOT/j.order.err")"
fi

# event_log_secret_lines FILE -- the lines of an NDJSON event log that leak key material; event_log_secret_hits FILE
# -- how many (0 for a clean or absent log). A line leaks when it carries
#   * a FIELD NAME that names a secret: a quoted name containing priv, secret, session_key or token ("priv",
#     "private_key", "session_key", "relay_session_token", "token", ...) followed by a colon. The optional
#     backslashes also catch one inside a string value, such as an error detail echoing a response body; or
#   * a VALUE shaped like 32 bytes of key material under ANY name: padded base64 (44 chars), 64 hex digits, or
#     unpadded base64url (43 chars) filling a whole string.
# The one public 32-byte value the client emits, pair_init's qr.hmd_pubkey, is cut out first -- that exact field
# and nothing else, so a leak sharing its line is still counted.
#
# It must not be a bare substring match. The check used to be `grep -Eic 'priv|secret|session_key|"token"'`, and
# `priv` matches "/private/var/folders/...", the realpath of a macOS $TMPDIR: RelayClient.root is
# os.path.realpath(--repo), so an error detail naming a file the client touched -- `status write failed: [Errno 2]
# No such file or directory: '/private/var/.../.heimdall/app/relay.json.tmp-1234'` -- carries one, and
# write_status() is called from both the state loop and the stream thread, which share that temp name and can race.
# One such event, which a loaded box can produce, made the old check report a secret that was only a path.
event_log_secret_lines() {
  local field_re='\\*"[A-Za-z0-9_.-]*(priv|secret|session_key|token)[A-Za-z0-9_.-]*\\*"[[:space:]]*:'
  local b64_re='(^|[^A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{43}='
  local hex_re='(^|[^A-Fa-f0-9])[A-Fa-f0-9]{64}($|[^A-Fa-f0-9])'
  local b64url_re='"[A-Za-z0-9_-]{43}"'
  sed -E 's|"hmd_pubkey":"[A-Za-z0-9+/_-]{43}="||g' "$1" 2>/dev/null \
    | grep -Ei "$field_re|$b64_re|$hex_re|$b64url_re"
}
event_log_secret_hits() { event_log_secret_lines "$1" | wc -l | tr -d ' '; }

SECRET_HITS_J="$(event_log_secret_hits "$EVENT_LOG_J")"
if [ "$SECRET_HITS_J" -eq 0 ]; then
  ok "durable event log: no secret-shaped field (priv/secret/session_key/token) ever written"
else
  bad "durable event log: found $SECRET_HITS_J secret-shaped line(s) in the event log: $(event_log_secret_lines "$EVENT_LOG_J" | head -3 | cut -c1-240)"
fi

# Controls, so the scan above can neither cry wolf on a path nor miss a leak. Each row is
# `want<TAB>description<TAB>one event-log line`, scanned on its own: want=1 plants a leak in a real shape (fresh
# random key bytes every run), want=0 is something that must stay quiet.
expect_secret_hits() {
  local want="$1" desc="$2" line="$3" one="$TMPROOT/j.scan-one.jsonl" got
  printf '%s\n' "$line" > "$one"
  got="$(event_log_secret_hits "$one")"
  if [ "$got" = "$want" ]; then
    ok "secret scan control: $desc"
  else
    bad "secret scan control: $desc (scan counted $got line(s), want $want) -- $line"
  fi
}

CONTROLS_J="$TMPROOT/j.scan-controls.tsv"
python3 - >"$CONTROLS_J" 2>"$TMPROOT/j.scan-controls.err" <<'PYEOF'
import base64, json, os

key = os.urandom(32)
padded = base64.b64encode(key).decode()                          # 44 chars ending in '=' -- what E2E.pub_b64 emits
url_safe = base64.urlsafe_b64encode(key).decode().rstrip("=")    # 43 chars
hex_key = key.hex()                                              # 64 chars
public = base64.b64encode(os.urandom(32)).decode()               # a public key: allowed where the client puts one
tmp_path = "/private/var/folders/t3/17x0hkw12n3g0qy3sjkggbsr0000gn/T/tmp.AbCdEf0123/repo.XyZ789/.heimdall/app/relay.json.tmp-4242"

rows = [
    (1, '"priv" field holding a base64 key', {"event": "device_bound", "priv": padded}),
    (1, '"private_key" field', {"event": "error", "private_key": padded}),
    (1, '"session_key" field', {"event": "device_bound", "session_key": padded}),
    (1, '"relay_session_token" field with an opaque value', {"event": "pair_init", "relay_session_token": "opaque"}),
    (1, '"token" field with a short value', {"event": "state_sent", "token": "t"}),
    (1, "padded base64 key under a harmless name", {"event": "state_sent", "shared": padded}),
    (1, "64-digit hex key under a harmless name", {"event": "state_sent", "shared": hex_key}),
    (1, "unpadded base64url key under a harmless name", {"event": "state_sent", "shared": url_safe}),
    (1, "base64 key inside free text", {"event": "error", "detail": "key derivation failed for " + padded}),
    (1, "secret field inside an echoed response body",
        {"event": "error", "detail": 'pair/init HTTP 500: {"relay_session_token":"opaque"}'}),
    (1, "leak sharing a line with the public hmd_pubkey (by name)",
        {"event": "pair_init", "qr": {"hmd_pubkey": public}, "session_key": padded}),
    (1, "leak sharing a line with the public hmd_pubkey (by shape)",
        {"event": "pair_init", "qr": {"hmd_pubkey": public}, "shared": padded}),
    (0, "error detail naming a /private/var path (file exists)",
        {"event": "error", "detail": "status write failed: [Errno 17] File exists: '" + tmp_path.rsplit("/", 1)[0] + "'"}),
    (0, "error detail naming a /private/var temp file and its rename target",
        {"event": "error", "detail": "status write failed: [Errno 2] No such file or directory: '" + tmp_path
                                     + "' -> '" + tmp_path.rsplit(".tmp-", 1)[0] + "'"}),
    (0, "pair_init with its public key, a uuid session_id and a pairing code",
        {"event": "pair_init", "exp": 1791264549,
         "qr": {"exp": 1791264549, "hmd_pubkey": public, "pairing_code": "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                "relay": "http://127.0.0.1:53520", "session_id": "e32e227c-3053-4ec4-be99-9487312d3989", "v": 1}}),
]
for want, desc, event in rows:
    print("%d\t%s\t%s" % (want, desc, json.dumps(event, sort_keys=True, separators=(",", ":"))))
PYEOF
if [ -s "$CONTROLS_J" ]; then
  while IFS=$'\t' read -r WANT_J DESC_J LINE_J; do
    expect_secret_hits "$WANT_J" "$DESC_J" "$LINE_J"
  done < "$CONTROLS_J"
else
  bad "secret scan controls: could not be generated -- $(cat "$TMPROOT/j.scan-controls.err")"
fi

# The same negative control with an event the real client emits: RelayClient.write_status() with a file where its
# status dir belongs, so os.makedirs raises FileExistsError naming the path -- under a repo path that holds
# /private/var/ on every platform, as the realpath of a macOS $TMPDIR does. In-process, the same SourceFileLoader
# technique as Scenario K.
NEG_ROOT_J="$TMPROOT/private/var/folders/xx/negctl"
NEG_EVENTS_J="$TMPROOT/j.negctl.events.jsonl"
mkdir -p "$NEG_ROOT_J/.heimdall"
: > "$NEG_ROOT_J/.heimdall/app"
HMD_RELAY_EVENT_LOG="$NEG_EVENTS_J" python3 - "$RELAY_CLIENT_RUN" "$NEG_ROOT_J" >/dev/null 2>"$TMPROOT/j.negctl.err" <<'PYEOF'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader

client_path, repo_dir = sys.argv[1:3]
loader = SourceFileLoader("hmd_relay_client_scan_control", client_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

root = os.path.realpath(repo_dir)        # RelayClient.__init__: self.root = os.path.realpath(--repo)
mod.configure_event_log(root)            # main() does the same right after --repo is parsed
client = object.__new__(mod.RelayClient)
client.status_path = os.path.join(root, ".heimdall", "app", "relay.json")
client._status_snapshot = dict
client.write_status()
PYEOF
NEG_RC_J=$?
NEG_LINE_J="$(grep 'status write failed' "$NEG_EVENTS_J" 2>/dev/null | head -1)"
case "$NEG_RC_J:$NEG_LINE_J" in
  0:*/private/var/*) ok "secret scan control: the real client's own status-write error event names a /private/var path" ;;
  *) bad "secret scan control: no status-write error event naming a /private/var path (rc=$NEG_RC_J, event='$NEG_LINE_J') -- $(cat "$TMPROOT/j.negctl.err")" ;;
esac
if [ "$(grep -Eic 'priv|secret|session_key|"token"' "$NEG_EVENTS_J" 2>/dev/null)" = 1 ]; then
  ok "secret scan control: the old substring pattern flags that same event, so the negative control is live"
else
  bad "secret scan control: the old substring pattern no longer flags the real client's path-bearing event -- the negative control proves nothing"
fi
NEG_HITS_J="$(event_log_secret_hits "$NEG_EVENTS_J")"
if [ "$NEG_HITS_J" = 0 ]; then
  ok "secret scan control: a real client event naming a /private/var path is not a leak"
else
  bad "secret scan control: a real client event naming a /private/var path was flagged as a leak ($NEG_HITS_J line(s))"
fi

# ── Scenario K: durable event log rotation -- HMD_RELAY_EVENT_LOG rotates
# path -> path.1 (single generation, clobbering any previous .1) once path
# reaches EVENT_LOG_MAX_BYTES (4 MiB), mirroring
# bin/lib/companion_ui_inbox.py's _rotate_if_oversized. Direct in-process
# import (no live relay/subprocess needed -- same SourceFileLoader technique
# as Scenario F/INV-16) so the 4 MiB fixture and rotation can be asserted
# deterministically instead of racing real network I/O ─────────────────────
REPO_K="$(make_repo)"
EVENT_LOG_K="$TMPROOT/k-eventlog-dir/relay-events.jsonl"
mkdir -p "$(dirname "$EVENT_LOG_K")"
python3 -c '
import sys
path = sys.argv[1]
line = b"old-generation-filler\n"
with open(path, "wb") as f:
    while f.tell() < 4 * 1024 * 1024 + 1000:
        f.write(line)
' "$EVENT_LOG_K"
OLD_SIZE_K="$(wc -c < "$EVENT_LOG_K" | tr -d ' ')"

ROTATE_OUT_K="$TMPROOT/k.rotate.out"
HMD_RELAY_EVENT_LOG="$EVENT_LOG_K" python3 - "$RELAY_CLIENT_RUN" "$REPO_K" >"$ROTATE_OUT_K" 2>"$TMPROOT/k.rotate.err" <<'PYEOF'
import importlib.util, sys
from importlib.machinery import SourceFileLoader

client_path, repo_dir = sys.argv[1:3]
loader = SourceFileLoader("hmd_relay_client_rotate", client_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

print("RESULT max_bytes %d" % mod.EVENT_LOG_MAX_BYTES)
mod.configure_event_log(repo_dir)
print("RESULT configured_path %s" % mod._event_log_path)
mod.emit({"event": "state_sent", "seq": 1})
mod.emit({"event": "state_sent", "seq": 2})
sys.exit(0)
PYEOF
ROTATE_RC_K=$?

if [ "$ROTATE_RC_K" -eq 0 ]; then
  ok "rotation: in-process emit() harness exited 0"
else
  bad "rotation: harness exited $ROTATE_RC_K -- $(cat "$TMPROOT/k.rotate.err")"
fi

MAX_BYTES_K="$(grep -o 'RESULT max_bytes [0-9]*' "$ROTATE_OUT_K" | awk '{print $3}')"
if [ "$MAX_BYTES_K" = "4194304" ]; then
  ok "rotation: EVENT_LOG_MAX_BYTES is 4194304 (4 MiB)"
else
  bad "rotation: EVENT_LOG_MAX_BYTES was '$MAX_BYTES_K', expected 4194304"
fi

CONFIGURED_PATH_K="$(sed -n 's/^RESULT configured_path //p' "$ROTATE_OUT_K")"
if [ "$CONFIGURED_PATH_K" = "$EVENT_LOG_K" ]; then
  ok "rotation: HMD_RELAY_EVENT_LOG override honored as the configured path"
else
  bad "rotation: configured path was '$CONFIGURED_PATH_K', expected '$EVENT_LOG_K'"
fi

if [ "$OLD_SIZE_K" -ge 4194304 ]; then
  ok "rotation fixture: pre-existing log was >= 4 MiB before any append ($OLD_SIZE_K bytes)"
else
  bad "rotation fixture: pre-existing log was only $OLD_SIZE_K bytes, need >= 4194304 for this scenario to be meaningful"
fi

if [ -f "$EVENT_LOG_K.1" ]; then
  ok "rotation: $EVENT_LOG_K.1 was created"
else
  bad "rotation: $EVENT_LOG_K.1 was never created"
fi

ROTATED_SIZE_K="$(wc -c < "$EVENT_LOG_K.1" 2>/dev/null | tr -d ' ')"
[ -z "$ROTATED_SIZE_K" ] && ROTATED_SIZE_K=0
if [ "$ROTATED_SIZE_K" = "$OLD_SIZE_K" ]; then
  ok "rotation: .1 holds exactly the old generation's bytes ($ROTATED_SIZE_K bytes), untouched"
else
  bad "rotation: .1 size ($ROTATED_SIZE_K) does not match the old generation's size ($OLD_SIZE_K)"
fi

NEW_LINES_K="$(grep -c '"event":"state_sent"' "$EVENT_LOG_K" 2>/dev/null || true)"
[ -z "$NEW_LINES_K" ] && NEW_LINES_K=0
if [ "$NEW_LINES_K" -eq 2 ]; then
  ok "rotation: fresh $EVENT_LOG_K holds only the 2 new post-rotation events (not the 4+ MiB of stale ones)"
else
  bad "rotation: fresh log has $NEW_LINES_K state_sent lines, want exactly 2"
fi

OLD_FILLER_IN_NEW_K="$(grep -c 'old-generation-filler' "$EVENT_LOG_K" 2>/dev/null || true)"
[ -z "$OLD_FILLER_IN_NEW_K" ] && OLD_FILLER_IN_NEW_K=0
if [ "$OLD_FILLER_IN_NEW_K" -eq 0 ]; then
  ok "rotation: none of the old generation's filler lines leaked into the fresh log"
else
  bad "rotation: $OLD_FILLER_IN_NEW_K old filler line(s) leaked into the fresh (post-rotation) log"
fi

# ── Scenario L: durable event log -- an unwritable directory (os.makedirs
# fails at the very first missing path component) never blocks or crashes
# the client: it prints exactly one stderr notice and keeps emitting to
# stdout normally, and the log is NOT switched off -- once the directory is
# writable again the very next emit lands in it (see _append_event_log's
# docstring; the full-disk version is test/relay-client-enospc-recovery.test.sh) ─
if [ "$(id -u)" = "0" ]; then
  skip "scenario L (unwritable event-log dir): running as root -- permission bits are not enforced"
else
  REPO_L="$(make_repo)"
  chmod 0500 "$REPO_L"

  UNWRITABLE_OUT_L="$TMPROOT/l.out"
  python3 - "$RELAY_CLIENT_RUN" "$REPO_L" >"$UNWRITABLE_OUT_L" 2>"$TMPROOT/l.err" <<'PYEOF'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader

client_path, repo_dir = sys.argv[1:3]
loader = SourceFileLoader("hmd_relay_client_unwritable", client_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

mod.configure_event_log(repo_dir)
print("RESULT configured_path %s" % mod._event_log_path)
mod.emit({"event": "state_sent", "seq": 1})
mod.emit({"event": "state_sent", "seq": 2})
mod.emit({"event": "state_sent", "seq": 3})
print("RESULT path_after %s" % mod._event_log_path)
# the directory becomes writable again: the log must come back, not stay off for the rest of the process
os.chmod(repo_dir, 0o700)
mod.emit({"event": "state_sent", "seq": 4})
with open(mod._event_log_path) as f:
    print("RESULT recovered_lines %d" % sum(1 for line in f if '"seq":4' in line))
sys.exit(0)
PYEOF
  UNWRITABLE_RC_L=$?
  chmod 0700 "$REPO_L"

  if [ "$UNWRITABLE_RC_L" -eq 0 ]; then
    ok "unwritable dir: emit() harness exited 0 -- never crashed or raised"
  else
    bad "unwritable dir: harness exited $UNWRITABLE_RC_L -- $(cat "$TMPROOT/l.err")"
  fi

  STDOUT_COUNT_L="$(grep -c '"event":"state_sent"' "$UNWRITABLE_OUT_L" 2>/dev/null || true)"
  [ -z "$STDOUT_COUNT_L" ] && STDOUT_COUNT_L=0
  if [ "$STDOUT_COUNT_L" -eq 4 ]; then
    ok "unwritable dir: all 4 emit() calls (3 while unwritable, 1 after) still reached stdout (client keeps running)"
  else
    bad "unwritable dir: expected 4 state_sent lines on stdout, got $STDOUT_COUNT_L"
  fi

  STDERR_NOTICE_COUNT_L="$(grep -c 'event log write failed' "$TMPROOT/l.err" 2>/dev/null || true)"
  [ -z "$STDERR_NOTICE_COUNT_L" ] && STDERR_NOTICE_COUNT_L=0
  if [ "$STDERR_NOTICE_COUNT_L" -eq 1 ]; then
    ok "unwritable dir: exactly one failure notice printed (not one per failed emit)"
  else
    bad "unwritable dir: expected exactly 1 failure notice, got $STDERR_NOTICE_COUNT_L -- $(cat "$TMPROOT/l.err")"
  fi

  CONFIGURED_PATH_L="$(sed -n 's/^RESULT configured_path //p' "$UNWRITABLE_OUT_L")"
  PATH_AFTER_L="$(sed -n 's/^RESULT path_after //p' "$UNWRITABLE_OUT_L")"
  if [ -n "$CONFIGURED_PATH_L" ] && [ "$CONFIGURED_PATH_L" != "None" ] && [ "$PATH_AFTER_L" = "$CONFIGURED_PATH_L" ]; then
    ok "unwritable dir: the event log stays configured after the failures (retried, not switched off)"
  else
    bad "unwritable dir: event log path changed after failure -- configured '$CONFIGURED_PATH_L', after '$PATH_AFTER_L'"
  fi

  if grep -q 'RESULT recovered_lines 1' "$UNWRITABLE_OUT_L"; then
    ok "unwritable dir: once the dir is writable again the very next emit lands in the log"
  else
    bad "unwritable dir: the log never came back -- $(grep recovered_lines "$UNWRITABLE_OUT_L")"
  fi

  if grep -q 'event log writes recovered after 3 failed' "$TMPROOT/l.err"; then
    ok "unwritable dir: one recovery notice names how many writes failed"
  else
    bad "unwritable dir: no 'recovered after 3 failed' notice -- $(cat "$TMPROOT/l.err")"
  fi
fi

# ── Scenario M: durable event log -- HMD_RELAY_EVENT_LOG="" (explicitly
# empty, not unset) disables the log outright: no file is ever created,
# anywhere, and stdout keeps working exactly as if the feature didn't exist ─
REPO_M="$(make_repo)"
DISABLED_OUT_M="$TMPROOT/m.out"
HMD_RELAY_EVENT_LOG="" python3 - "$RELAY_CLIENT_RUN" "$REPO_M" >"$DISABLED_OUT_M" 2>"$TMPROOT/m.err" <<'PYEOF'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader

client_path, repo_dir = sys.argv[1:3]
loader = SourceFileLoader("hmd_relay_client_disabled", client_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

mod.configure_event_log(repo_dir)
print("RESULT configured_path %r" % (mod._event_log_path,))
mod.emit({"event": "state_sent", "seq": 1})
mod.emit({"event": "state_sent", "seq": 2})
default_path = os.path.join(repo_dir, ".heimdall", "app", "relay-events.jsonl")
print("RESULT default_path_exists %r" % os.path.exists(default_path))
print("RESULT heimdall_dir_exists %r" % os.path.exists(os.path.join(repo_dir, ".heimdall")))
sys.exit(0)
PYEOF
DISABLED_RC_M=$?

if [ "$DISABLED_RC_M" -eq 0 ]; then
  ok "disabled-via-env: emit() harness exited 0"
else
  bad "disabled-via-env: harness exited $DISABLED_RC_M -- $(cat "$TMPROOT/m.err")"
fi

if grep -q 'RESULT configured_path None' "$DISABLED_OUT_M"; then
  ok 'disabled-via-env: HMD_RELAY_EVENT_LOG="" resolved _event_log_path to None'
else
  bad "disabled-via-env: configured_path was not None -- $(grep configured_path "$DISABLED_OUT_M")"
fi

STDOUT_COUNT_M="$(grep -c '"event":"state_sent"' "$DISABLED_OUT_M" 2>/dev/null || true)"
[ -z "$STDOUT_COUNT_M" ] && STDOUT_COUNT_M=0
if [ "$STDOUT_COUNT_M" -eq 2 ]; then
  ok "disabled-via-env: both emit() calls still reached stdout normally"
else
  bad "disabled-via-env: expected 2 state_sent lines on stdout, got $STDOUT_COUNT_M"
fi

if grep -q 'RESULT default_path_exists False' "$DISABLED_OUT_M"; then
  ok "disabled-via-env: the default event-log path was never created"
else
  bad "disabled-via-env: default event-log path exists when it should not -- $(grep default_path_exists "$DISABLED_OUT_M")"
fi

if grep -q 'RESULT heimdall_dir_exists False' "$DISABLED_OUT_M"; then
  ok "disabled-via-env: not even the containing .heimdall dir was created"
else
  bad "disabled-via-env: .heimdall dir was created even though logging is disabled -- $(grep heimdall_dir_exists "$DISABLED_OUT_M")"
fi

STDERR_SIZE_M="$(wc -c < "$TMPROOT/m.err" 2>/dev/null | tr -d ' ')"
[ -z "$STDERR_SIZE_M" ] && STDERR_SIZE_M=0
if [ "$STDERR_SIZE_M" -eq 0 ]; then
  ok "disabled-via-env: no stderr output at all (disabling is not a failure)"
else
  bad "disabled-via-env: unexpected stderr output -- $(cat "$TMPROOT/m.err")"
fi

# ── Scenario N: `hmd app status` surfaces the durable event log's path and
# last-event time (bin/heimdall-app's cmd_status_relay; HANDOFF's "hmd app
# status must show the log path + last event time"). Hand-synthesized
# connect.json/relay.json -- no live processes needed, since cmd_status_relay
# prints every field (including the new ones) before its alive-check can
# short-circuit, confirmed by reading its body ──────────────────────────────
REPO_N="$(make_repo)"
mkdir -p "$REPO_N/.heimdall/app"

cat > "$REPO_N/.heimdall/app/connect.json" <<JSON
{"mode":"relay","pid_ui":$$,"pid_client":$$,"port":0,"relay":"http://127.0.0.1:1","started_at":"2026-01-01T00:00:00Z"}
JSON

EVENT_LOG_N="$REPO_N/.heimdall/app/relay-events.jsonl"
printf '{"event":"device_bound","ts":"2026-01-01T00:00:01.000Z"}\n' > "$EVENT_LOG_N"

cat > "$REPO_N/.heimdall/app/relay.json" <<JSON
{"session_id":"sess-n","relay":"http://127.0.0.1:1","paired":true,"bound_at":1,
 "last_seq":1,"frames_sent":1,"last_delivered":"2026-01-01T00:00:01Z","pid":$$,
 "last_command_at":null,"started_at":1,"event_log":"$EVENT_LOG_N"}
JSON

STATUS_OUT_N="$("$APP" status --repo "$REPO_N" 2>"$TMPROOT/n.status.err")"

if printf '%s\n' "$STATUS_OUT_N" | grep -qF "event log: $EVENT_LOG_N"; then
  ok "hmd app status: prints the event log's path"
else
  bad "hmd app status: did not print the event log path -- $STATUS_OUT_N"
fi

if printf '%s\n' "$STATUS_OUT_N" | grep -Eq 'last event at: [0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  ok "hmd app status: prints an ISO-8601 last-event time for the event log"
else
  bad "hmd app status: did not print a last-event timestamp -- $STATUS_OUT_N"
fi

# event_log:null in relay.json -> "disabled", never a blank or malformed line
REPO_N2="$(make_repo)"
mkdir -p "$REPO_N2/.heimdall/app"
cat > "$REPO_N2/.heimdall/app/connect.json" <<JSON
{"mode":"relay","pid_ui":$$,"pid_client":$$,"port":0,"relay":"http://127.0.0.1:1","started_at":"2026-01-01T00:00:00Z"}
JSON
cat > "$REPO_N2/.heimdall/app/relay.json" <<JSON
{"session_id":"sess-n2","relay":"http://127.0.0.1:1","paired":false,"bound_at":null,
 "last_seq":0,"frames_sent":0,"last_delivered":null,"pid":$$,
 "last_command_at":null,"started_at":1,"event_log":null}
JSON

STATUS_OUT_N2="$("$APP" status --repo "$REPO_N2" 2>"$TMPROOT/n2.status.err")"
if printf '%s\n' "$STATUS_OUT_N2" | grep -qF "event log: disabled"; then
  ok "hmd app status: event_log:null in relay.json prints 'event log: disabled'"
else
  bad "hmd app status: did not print 'event log: disabled' for a null event_log -- $STATUS_OUT_N2"
fi


suite_summary
