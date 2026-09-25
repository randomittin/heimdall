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
    c="$(grep -E "$re" "$file" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$c" -ge "$n" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Polls FILE's line count until it stops changing for STABLE_S consecutive
# seconds (0.1s steps), up to MAX_S total. For draining an in-flight
# background write (e.g. the relay-client's own periodic state-tick) before
# a caller snapshots a "before" count -- so a later before/after comparison
# measures the effect being tested, not a race against something already en
# route. Returns 0 once quiescent; 1 if the count was still moving at MAX_S
# (the caller decides whether that itself is worth flagging).
wait_for_quiescent_count() {
  local file="$1" stable_s="${2:-3}" max_s="${3:-20}"
  local stable_ticks=$(( stable_s * 10 )) max_ticks=$(( max_s * 10 ))
  local last="" same=0 i=0 c
  while [ "$i" -lt "$max_ticks" ]; do
    c="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
    [ -z "$c" ] && c=0
    if [ "$c" = "$last" ]; then
      same=$((same + 1))
      [ "$same" -ge "$stable_ticks" ] && return 0
    else
      last="$c"
      same=0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

count_matching() {
  grep -E "$2" "$1" 2>/dev/null | wc -l | tr -d ' '
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

# of_seq/ok/id/detail live INSIDE the sealed payload, never as plaintext keys
# in the envelope JSON that lands in frames.ndjson (that line only ever has
# the 8 fixed envelope keys -- v/session_id/seq/sender/type/nonce/ciphertext/
# payload -- see bin/heimdall-relay-client's send_frame_envelope()). So an ack
# for a given device seq can only be found by decrypting each sender=hmd
# envelope and checking its plaintext of_seq -- never by grepping the raw
# ciphertext line. Polls FILE up to SECS seconds; on match prints the
# decrypted plaintext object as one JSON line on stdout and returns 0;
# returns 1 on timeout with nothing printed.
wait_for_ack_of_seq() {
  local file="$1" key_b64="$2" want="$3" secs="${4:-10}"
  python3 - "$file" "$key_b64" "$want" "$secs" "$E2E_MOD" <<'PYEOF'
import sys, json, time, base64
from importlib.util import spec_from_file_location, module_from_spec

file_path, key_b64, want_s, secs_s, e2e_path = sys.argv[1:6]
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
        if obj.get("of_seq") == want:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PYEOF
}

# Polls FILE (an NDJSON event stream) up to SECS seconds for a line that
# parses as JSON with event==WANT_EVENT and (DETAIL_SUBSTR empty, or
# DETAIL_SUBSTR found in that object's "detail" string) -- never an ordered
# regex like '"event":"error".*non-increasing seq', since emit() writes keys
# sort_keys=True (alphabetical), so field order in the line is NOT the order
# fields were set in code (e.g. {"detail": ..., "event": "error"}, "detail"
# first because 'd' < 'e' -- an ordered regex expecting "event" before the
# detail text would never match). No eval/exec: only literal json.loads and
# a plain substring test, both over data this process itself wrote.
wait_for_event() {
  local file="$1" want_event="$2" detail_substr="$3" secs="${4:-10}"
  python3 - "$file" "$want_event" "$detail_substr" "$secs" <<'PYEOF'
import sys, json, time

file_path, want_event, detail_substr, secs_s = sys.argv[1:5]
deadline = time.time() + float(secs_s)
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
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("event") != want_event:
            continue
        if detail_substr and detail_substr not in (o.get("detail") or ""):
            continue
        sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PYEOF
}

# Polls FILE (an NDJSON event stream) up to SECS seconds for a stream_drop
# event whose "reason" equals WANT_REASON (exact match) -- companion to
# wait_for_event, needed here because "reason" is a stream_drop-specific key
# wait_for_event's generic detail-substring check does not cover (stream_drop
# has no "detail" key at all). On match, prints that event object as one
# compact JSON line on stdout (so a caller can pull line_bytes/cap_bytes/
# total_bytes/retry_ms out of it without a second pass) and returns 0; returns
# 1 on timeout with nothing printed.
wait_for_stream_drop() {
  local file="$1" want_reason="$2" secs="${3:-10}"
  python3 - "$file" "$want_reason" "$secs" <<'PYEOF'
import sys, json, time

file_path, want_reason, secs_s = sys.argv[1:4]
deadline = time.time() + float(secs_s)
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
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("event") != "stream_drop":
            continue
        if (o.get("reason") or "") != want_reason:
            continue
        sys.stdout.write(json.dumps(o) + "\n")
        sys.exit(0)
    if time.time() >= deadline:
        sys.exit(1)
    time.sleep(0.1)
PYEOF
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

# bin/heimdall-relay-client's own main() gates e2e_available() BEFORE
# pair_init -- so even claims that never touch real crypto directly (1, 5, 6,
# 7) still need SOME module at bin/lib/hmd_relay_e2e.py answering
# e2e_available()==True just to get the process past that gate, AND (since
# fake-relay.py's serve mode sends an unconditional device_bound on the very
# first stream connect) answering pub_from_b64/derive_session_key too, just
# to reach a successful device_bound instead of an error event. When the real
# module is present it is used as-is, unshadowed. When it is absent, a full
# copy of bin/ + sentinels/ is made with ONLY hmd_relay_e2e.py swapped for a
# minimal stub that fakes those calls (never real X25519/HKDF) and nothing
# else -- claims 2/3/4, which DO need REAL crypto (seal/open_ against a real
# session key), stay gated on $E2E_PRESENT and are skipped, loudly, whenever
# this stub is in play.
if [ "$E2E_PRESENT" = true ]; then
  RELAY_CLIENT_RUN="$RELAY_CLIENT"
else
  MINSTUB_LIB="$TMPROOT/stub-min-e2e"
  mkdir -p "$MINSTUB_LIB"
  cat > "$MINSTUB_LIB/hmd_relay_e2e.py" <<'MINSTUB_EOF'
"""Minimal e2e_available()==True stand-in used ONLY when the real
bin/lib/hmd_relay_e2e.py has not landed on this branch yet, so claims 1, 5,
6 and 7 can still run against a real, unmodified bin/heimdall-relay-client
process instead of being skipped outright. fake-relay.py's `serve` mode sends
an unconditional device_bound on every stream connect now (no gated "hello"
frame), so pub_from_b64/derive_session_key are needed even for those four
claims just to reach a successful device_bound instead of an error event --
faked here with plain, clearly-non-cryptographic stand-ins (never real
X25519/HKDF). seal/open are deliberately still absent: claims 2/3/4 (which DO
need real AEAD sealing against a real session key) are skipped whenever this
stub is in use -- never faked."""
import base64
import hashlib
import os


def e2e_available():
    return True


def generate_keypair():
    return os.urandom(32), os.urandom(32)


def pub_b64(pub):
    return base64.b64encode(pub).decode("ascii")


def pub_from_b64(s):
    return base64.b64decode(s)


def derive_session_key(priv, pub, session_id):
    return hashlib.sha256(bytes(pub) + session_id.encode("utf-8")).digest()
MINSTUB_EOF
  MINSTUB_ROOT="$TMPROOT/stub-min-e2e-root"
  mkdir -p "$MINSTUB_ROOT"
  cp -R "$REPO/bin" "$MINSTUB_ROOT/bin"
  cp -R "$REPO/sentinels" "$MINSTUB_ROOT/sentinels"
  cp "$MINSTUB_LIB/hmd_relay_e2e.py" "$MINSTUB_ROOT/bin/lib/hmd_relay_e2e.py"
  RELAY_CLIENT_RUN="$MINSTUB_ROOT/bin/heimdall-relay-client"
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
  # second inbox record, no new ack.
  #
  # INV-15 is about the REPLAY's own effect, not the client's independent
  # state-tick loop -- but that loop (bin/heimdall-relay-client's tick_s and
  # sentinels/hmd-ui.py's POLL_INTERVAL_S are both 2s) notices, on its own
  # schedule, that the FIRST (legitimate) send-message above just changed
  # on-disk state (collect_inbox()'s pending count, sentinels/hmd-ui.py:638,
  # 0 -> 1) and republishes a "state" frame once that lands -- anywhere up to
  # ~4s after the write. Sampling FRAMES_BEFORE_REPLAY immediately, before
  # that fallout has necessarily landed, raced it against the replay's own
  # ~1-7s check-plus-sleep window below: under load the legitimate frame
  # could land inside that window and get blamed on the replay (observed:
  # "4 -> 5" with the replay itself still correctly rejected per case 23/24).
  # Draining the frame stream to quiescence here -- rather than a fixed
  # sleep -- makes the before/after comparison isolate the replay's effect
  # regardless of how long that unrelated fallout takes to arrive.
  wait_for_quiescent_count "$LOG_A/frames.ndjson" 3 20
  FRAMES_BEFORE_REPLAY="$(wc -l < "$LOG_A/frames.ndjson" | tr -d ' ')"
  INBOX_COUNT_BEFORE="$(grep '"hello from claim4"' "$INBOX_A" 2>/dev/null | wc -l | tr -d ' ')"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_A" --seq 1 --sender device \
    --type command --nonce "$NONCE1" --ciphertext "$CT1" > "$CTL_A/003.json"
  if wait_for_event "$CLIENT_A_OUT" "error" "non-increasing seq" 6; then
    ok "INV-15: replayed device seq=1 produced a non-increasing-seq error"
  else
    bad "INV-15: replayed device seq=1 was not rejected with an error event"
  fi
  sleep 1
  INBOX_COUNT_AFTER="$(grep '"hello from claim4"' "$INBOX_A" 2>/dev/null | wc -l | tr -d ' ')"
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

if wait_for_count "$CLIENT_I_OUT" 2 '"event":"device_bound"' 6; then
  ok "§15: client reconnected and re-bound after the warn"
  T1_I="$(python3 -c 'import time; print(time.time())')"
  ELAPSED_I="$(python3 -c "print($T1_I - $T0_I)")"
  # lower bound: a broken/skipped backoff reconnects near-instantly instead.
  # upper bound: the DEFAULT base (2000ms) would still clear a lower-bound-
  # only check, so this must also stay well under 2s to prove the
  # HMD_RELAY_BACKOFF_BASE_MS=500 override -- not just the module default --
  # is what got honored.
  ELAPSED_I_OK="$(python3 -c "print(1 if 0.4 <= $ELAPSED_I <= 1.5 else 0)")"
  if [ "$ELAPSED_I_OK" = "1" ]; then
    ok "§15: reconnect honored the HMD_RELAY_BACKOFF_BASE_MS=500 override, not the 2000ms default (~${ELAPSED_I}s)"
  else
    bad "§15: reconnect timing didn't match the HMD_RELAY_BACKOFF_BASE_MS=500 override (~${ELAPSED_I}s, want 0.4-1.5s)"
  fi
else
  bad "§15: client never reconnected/re-bound after the warn"
  bad "§15: cannot check backoff timing -- no reconnect observed"
fi

kill "$CLIENT_I" 2>/dev/null
wait "$CLIENT_I" 2>/dev/null
kill "$SRV_I" 2>/dev/null
wait "$SRV_I" 2>/dev/null

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
