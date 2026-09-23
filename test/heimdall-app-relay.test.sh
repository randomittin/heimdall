#!/usr/bin/env bash
# test/heimdall-app-relay.test.sh -- hermetic acceptance for bin/heimdall-relay-client
# (and bin/heimdall-app's `connect --relay` orchestration of it) against
# test/lib/fake-relay.py, a stdlib stand-in for the Cloudflare relay described in
# hmdapp's docs/HANDOFF-TO-HEIMDALL-relay.md ("Implemented relay API",
# "Envelope", "Tests", "Acceptance criteria" -- read-only inputs, never edited
# here) and docs/RELAY-CLIENT-CONTRACT.md (the hello key-exchange convention).
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
# being built by a sibling task and may not exist yet on this branch. Claims
# 3, 4 and 9/10 (the two that need `device seal/open/derive` and the
# e2e_available grep) are SKIPPED, loudly and counted, when the module is
# absent -- never silently passed. Claims 1, 2, 5, 6, 7, 8, 11-14 do not need
# it and always run.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_CLIENT="$REPO/bin/heimdall-relay-client"
APP="$REPO/bin/heimdall-app"
HEIMDALL="$REPO/bin/heimdall"
UI="$REPO/bin/heimdall-ui"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"
INBOX_LIB="$REPO/bin/lib/companion_ui_inbox.py"

PASS=0
FAIL=0
SKIP=0
N=0
ok()   { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad()  { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }
skip() { N=$((N + 1)); SKIP=$((SKIP + 1)); printf '  SKIP %d. %s\n' "$N" "$1"; }

echo "heimdall-app-relay (bin/heimdall-relay-client + hmd app connect --relay oracle)"

for f in "$RELAY_CLIENT" "$APP" "$HEIMDALL" "$UI" "$FAKE_RELAY" "$INBOX_LIB"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

E2E_PRESENT=false
[ -f "$E2E_MOD" ] && E2E_PRESENT=true

# ── sandbox ──────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
mkdir -p "$HOME/.claude"

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

make_repo() {
  local d
  d="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  ( cd "$d" && git init -q . 2>/dev/null \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true
  printf '%s' "$d"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# Poll FILE for a regex up to SECS seconds (0.1s steps). Exit 0 on match.
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Poll FILE for at least N non-empty lines matching (optional) regex $3.
wait_for_count() {
  local file="$1" n="$2" re="${3:-.}" secs="${4:-10}" i=0 max c
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    c="$(grep -Ec "$re" "$file" 2>/dev/null || echo 0)"
    [ "$c" -ge "$n" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

count_matching() {
  grep -Ec "$2" "$1" 2>/dev/null || echo 0
}

wait_pid_exit() {
  local pid="$1" secs="${2:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

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

CLIENT_A_OUT="$TMPROOT/a.client.out"
CLIENT_A_ERR="$TMPROOT/a.client.err"
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_A_RELAY" --repo "$REPO_A" --ui-port "$PORT_A_UI" \
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
  DEV_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEV_PRIV_B64="$(printf '%s' "$DEV_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEV_PUB_B64="$(printf '%s' "$DEV_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"

  KEY_JSON="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_A" --session-id "$SID_A")"
  SESSION_KEY_A="$(printf '%s' "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # Wave-1 hello: unsealed device pubkey as ciphertext, nonce literally "hello", seq 0.
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 0 --sender device \
    --type command --nonce hello --ciphertext "$DEV_PUB_B64" > "$CTL_A/001.json"

  if wait_for_count "$LOG_A/frames.ndjson" 1 '"type":"ack"' 10; then
    ok "scenario A: hello key-exchange produced a sealed ack frame"
  else
    bad "scenario A: no ack frame ever appeared in frames.ndjson after hello"
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
    --text '{"action":"send-message","text":"hello from claim4"}')"
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

  if wait_for_count "$LOG_A/frames.ndjson" 1 '"of_seq":1' 10; then
    ok "scenario A: ack for seq=1 appeared in frames.ndjson"
  else
    bad "scenario A: no ack for seq=1 ever appeared"
  fi
  ACK1_ENV="$(grep '"of_seq":1' "$LOG_A/frames.ndjson" 2>/dev/null | tail -1)"
  ACK1_SEQ="$(printf '%s' "$ACK1_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["seq"])')"
  ACK1_NONCE="$(printf '%s' "$ACK1_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["nonce"])')"
  ACK1_CT="$(printf '%s' "$ACK1_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ciphertext"])')"
  ACK1_OPEN="$(python3 "$FAKE_RELAY" device open --key-b64 "$SESSION_KEY_A" --seq "$ACK1_SEQ" --sender hmd \
    --nonce-b64 "$ACK1_NONCE" --ciphertext-b64 "$ACK1_CT" 2>/dev/null)"
  ACK1_OK="$(printf '%s' "$ACK1_OPEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plaintext_json"].get("ok"))' 2>/dev/null)"
  ACK1_ID="$(printf '%s' "$ACK1_OPEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plaintext_json"].get("id",""))' 2>/dev/null)"
  if [ "$ACK1_OK" = "True" ] && [ -n "$ACK1_ID" ]; then
    ok "INV-23: sealed ack decrypts to {ok:true, id:<uuid>} ($ACK1_ID)"
  else
    bad "INV-23: sealed ack for seq=1 did not decrypt to {ok:true, id:...} (ok=$ACK1_OK id=$ACK1_ID)"
  fi

  # claim 3b (INV-15): replay of seq=1 (already seen) is rejected -- no
  # second inbox record, no new ack.
  FRAMES_BEFORE_REPLAY="$(wc -l < "$LOG_A/frames.ndjson" | tr -d ' ')"
  INBOX_COUNT_BEFORE="$(grep -c '"hello from claim4"' "$INBOX_A" 2>/dev/null || echo 0)"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 1 --sender device \
    --type command --nonce "$NONCE1" --ciphertext "$CT1" > "$CTL_A/003.json"
  if wait_for "$CLIENT_A_OUT" '"event":"error".*non-increasing seq' 6; then
    ok "INV-15: replayed device seq=1 produced a non-increasing-seq error"
  else
    bad "INV-15: replayed device seq=1 was not rejected with an error event"
  fi
  sleep 1
  INBOX_COUNT_AFTER="$(grep -c '"hello from claim4"' "$INBOX_A" 2>/dev/null || echo 0)"
  FRAMES_AFTER_REPLAY="$(wc -l < "$LOG_A/frames.ndjson" | tr -d ' ')"
  if [ "$INBOX_COUNT_AFTER" -eq "$INBOX_COUNT_BEFORE" ]; then
    ok "INV-15: replay produced no second inbox record ($INBOX_COUNT_BEFORE == $INBOX_COUNT_AFTER)"
  else
    bad "INV-15: replay produced a second inbox record ($INBOX_COUNT_BEFORE -> $INBOX_COUNT_AFTER)"
  fi
  if [ "$FRAMES_AFTER_REPLAY" -eq "$FRAMES_BEFORE_REPLAY" ]; then
    ok "INV-15: replay produced no new posted frame ($FRAMES_BEFORE_REPLAY == $FRAMES_AFTER_REPLAY)"
  else
    bad "INV-15: replay unexpectedly produced a new posted frame ($FRAMES_BEFORE_REPLAY -> $FRAMES_AFTER_REPLAY)"
  fi

  # claim 4b (INV-23): too-long text -> ack {ok:false, detail:"too-long"}, no inbox record.
  LONG_TEXT="$(python3 -c 'print("x" * 2001)')"
  SEAL2_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_A" --seq 2 --sender device \
    --text "{\"action\":\"send-message\",\"text\":\"$LONG_TEXT\"}")"
  NONCE2="$(printf '%s' "$SEAL2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT2="$(printf '%s' "$SEAL2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 2 --sender device \
    --type command --nonce "$NONCE2" --ciphertext "$CT2" > "$CTL_A/004.json"

  if wait_for_count "$LOG_A/frames.ndjson" 1 '"of_seq":2' 10; then
    ok "scenario A: ack for seq=2 (too-long) appeared in frames.ndjson"
  else
    bad "scenario A: no ack for seq=2 ever appeared"
  fi
  ACK2_ENV="$(grep '"of_seq":2' "$LOG_A/frames.ndjson" 2>/dev/null | tail -1)"
  ACK2_SEQ="$(printf '%s' "$ACK2_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["seq"])')"
  ACK2_NONCE="$(printf '%s' "$ACK2_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["nonce"])')"
  ACK2_CT="$(printf '%s' "$ACK2_ENV" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ciphertext"])')"
  ACK2_OPEN="$(python3 "$FAKE_RELAY" device open --key-b64 "$SESSION_KEY_A" --seq "$ACK2_SEQ" --sender hmd \
    --nonce-b64 "$ACK2_NONCE" --ciphertext-b64 "$ACK2_CT" 2>/dev/null)"
  ACK2_OK="$(printf '%s' "$ACK2_OPEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plaintext_json"].get("ok"))' 2>/dev/null)"
  ACK2_DETAIL="$(printf '%s' "$ACK2_OPEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plaintext_json"].get("detail"))' 2>/dev/null)"
  if [ "$ACK2_OK" = "False" ] && [ "$ACK2_DETAIL" = "too-long" ]; then
    ok "INV-23: too-long send-message acked {ok:false, detail:too-long}"
  else
    bad "INV-23: too-long send-message ack mismatch (ok=$ACK2_OK detail=$ACK2_DETAIL)"
  fi
  TOOLONG_INBOX_COUNT="$(grep -c "$(printf '%s' "$LONG_TEXT" | head -c 40)" "$INBOX_A" 2>/dev/null || echo 0)"
  if [ "$TOOLONG_INBOX_COUNT" -eq 0 ]; then
    ok "INV-23: too-long send-message produced no inbox record"
  else
    bad "INV-23: too-long send-message unexpectedly produced an inbox record"
  fi
else
  skip "INV-22/14/15/23 (claims 2-4): bin/lib/hmd_relay_e2e.py absent -- hello handshake needs device seal/open/derive"
fi

# claim 5 (INV-21): end-session -> client emits session_ended and exits 0;
# no frame posted after.
FRAMES_BEFORE_END="$(wc -l < "$LOG_A/frames.ndjson" 2>/dev/null | tr -d ' ')"
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
FRAMES_AFTER_END="$(wc -l < "$LOG_A/frames.ndjson" 2>/dev/null | tr -d ' ')"
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
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_B_RELAY" --repo "$REPO_B" --ui-port "$PORT_B_UI" \
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
"$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_C_RELAY" --repo "$REPO_C" --ui-port "$PORT_C_UI" \
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
  mkdir -p "\$STUBROOT/bin/lib" "\$STUBROOT/sentinels"
  cp "$RELAY_CLIENT" "\$STUBROOT/bin/heimdall-relay-client"
  cp "$REPO/bin/lib/companion_ui_inbox.py" "\$STUBROOT/bin/lib/companion_ui_inbox.py"
  cp "$REPO/sentinels/hmd-ui.py" "\$STUBROOT/sentinels/hmd-ui.py"
  cp "$STUB_LIB_DIR/hmd_relay_e2e.py" "\$STUBROOT/bin/lib/hmd_relay_e2e.py"
  chmod +x "\$STUBROOT/bin/heimdall-relay-client"
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
  --repo "$REPO_D" --port "$PORT_D_UI" --relay "http://127.0.0.1:$PORT_D_RELAY" \
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
for sf in "$REPO_D"/.heimdall/app/connect.json; do
  [ -f "$sf" ] || continue
  leak_pid="$(python3 -c "import json,sys; print(json.load(open('$sf')).get('pid_ui','') or '')" 2>/dev/null)"
  [ -n "$leak_pid" ] && kill -9 "$leak_pid" 2>/dev/null
  leak_client="$(python3 -c "import json,sys; print(json.load(open('$sf')).get('pid_client','') or '')" 2>/dev/null)"
  [ -n "$leak_client" ] && kill -9 "$leak_client" 2>/dev/null
done

kill "$SRV_D" 2>/dev/null
wait "$SRV_D" 2>/dev/null

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
