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

# A stale-seq refusal (scenario Y, and INV-15 in scenario A) is an ordinary sealed ack, so like every ack its fields live
# INSIDE the sealed payload (see wait_for_ack_of_seq above): the only way to find one is to open each sender=hmd ack
# envelope in FILE with the session key -- here with the same bin/lib/hmd_relay_e2e.py the client uses, never by grepping
# ciphertext.

# sealed_acks FILE KEY_B64 -- every ack the relay received from hmd, oldest first, one JSON line each:
# {"ack": <the opened plaintext>, "seq": <the ack frame's own hmd-side seq>}
sealed_acks() {
  python3 - "$1" "$2" "$E2E_MOD" <<'PYEOF'
import base64, json, sys
from importlib.util import module_from_spec, spec_from_file_location

file_path, key_b64, e2e_path = sys.argv[1:4]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
try:
    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        env = json.loads(line)
    except ValueError:
        continue
    if env.get("sender") != "hmd" or env.get("type") != "ack":
        continue
    try:
        ack = json.loads(e2e.open_(key, env["seq"], "hmd", env.get("nonce"), env.get("ciphertext")).decode("utf-8"))
    except Exception:
        continue
    print(json.dumps({"ack": ack, "seq": env["seq"]}, sort_keys=True))
PYEOF
}

# refusal_acks FILE KEY_B64 [OF_SEQ] -- the sealed_acks that are stale-seq refusals (detail non-increasing-seq), as the
# opened plaintext only, one JSON line each; with OF_SEQ only those answering that device seq
refusal_acks() {
  sealed_acks "$1" "$2" | python3 -c '
import json, sys
want = int(sys.argv[1]) if len(sys.argv) > 1 else None
for line in sys.stdin:
    ack = json.loads(line)["ack"]
    if ack.get("detail") == "non-increasing-seq" and (want is None or ack.get("of_seq") == want):
        print(json.dumps(ack, sort_keys=True, separators=(",", ":")))
' ${3:+"$3"}
}

# wait_for_refusal_ack FILE KEY_B64 OF_SEQ [SECS] -- polls (0.2 s steps) until the relay holds a refusal answering OF_SEQ;
# on match prints the first one as one JSON line and returns 0; returns 1 on timeout with nothing printed
wait_for_refusal_ack() {
  local file="$1" key="$2" want="$3" secs="${4:-10}" i=0 max found
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    found="$(refusal_acks "$file" "$key" "$want" | head -1)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# refusal_rate FILE KEY_B64 POSTS_LOG WINDOW_S -- "<refusals the relay received> <the most of them inside any one WINDOW_S
# window>". The times are the relay's own `recv` stamps in frame-posts.log; an ack's hmd seq joins them to the opened refusals
refusal_rate() {
  python3 - "$1" "$2" "$3" "$4" "$E2E_MOD" <<'PYEOF'
import base64, json, re, sys
from importlib.util import module_from_spec, spec_from_file_location

frames, key_b64, posts_log, window_s, e2e_path = sys.argv[1:6]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
refusal_seqs = set()
with open(frames, "r", encoding="utf-8") as f:
    for line in f.read().splitlines():
        try:
            env = json.loads(line)
            if env.get("sender") != "hmd" or env.get("type") != "ack":
                continue
            ack = json.loads(e2e.open_(key, env["seq"], "hmd", env.get("nonce"), env.get("ciphertext")).decode("utf-8"))
        except Exception:
            continue
        if ack.get("detail") == "non-increasing-seq":
            refusal_seqs.add(env["seq"])
times = []
with open(posts_log, "r", encoding="utf-8") as f:
    for line in f:
        m = re.search(r"recv=([0-9.]+) .* type=ack seq=([0-9]+) result=ok", line)
        if m and int(m.group(2)) in refusal_seqs:
            times.append(float(m.group(1)))
window = float(window_s)
print(len(times), max((sum(1 for u in times if t <= u < t + window) for t in times), default=0))
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

# docs/HANDOFF-TO-HEIMDALL-relay-ipv6-stall.md: the two operator-facing knobs
for IPV6_KNOB in HMD_RELAY_IP_FAMILY HMD_RELAY_ACK_WINDOW_S; do
  if grep -q "$IPV6_KNOB" "$RELAY_CLIENT"; then
    ok "ipv6-stall: bin/heimdall-relay-client reads $IPV6_KNOB"
  else
    bad "ipv6-stall: bin/heimdall-relay-client does not reference $IPV6_KNOB"
  fi
done

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

SECRET_HITS_J="$(grep -Eic 'priv|secret|session_key|"token"' "$EVENT_LOG_J" 2>/dev/null || true)"
[ -z "$SECRET_HITS_J" ] && SECRET_HITS_J=0
if [ "$SECRET_HITS_J" -eq 0 ]; then
  ok "durable event log: no secret-shaped field (priv/secret/session_key/token) ever written"
else
  bad "durable event log: found $SECRET_HITS_J secret-shaped line(s) in the event log"
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
# stdout normally for the rest of its life (never retried -- see
# _append_event_log's docstring) ────────────────────────────────────────────
if [ "$(id -u)" = "0" ]; then
  skip "scenario L (unwritable event-log dir): running as root -- permission bits are not enforced"
else
  REPO_L="$(make_repo)"
  chmod 0500 "$REPO_L"

  UNWRITABLE_OUT_L="$TMPROOT/l.out"
  python3 - "$RELAY_CLIENT_RUN" "$REPO_L" >"$UNWRITABLE_OUT_L" 2>"$TMPROOT/l.err" <<'PYEOF'
import importlib.util, sys
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
print("RESULT notified %r" % mod._event_log_notified)
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
  if [ "$STDOUT_COUNT_L" -eq 3 ]; then
    ok "unwritable dir: all 3 emit() calls still reached stdout (client keeps running)"
  else
    bad "unwritable dir: expected 3 state_sent lines on stdout, got $STDOUT_COUNT_L"
  fi

  STDERR_NOTICE_COUNT_L="$(grep -c 'event log disabled after a write failure' "$TMPROOT/l.err" 2>/dev/null || true)"
  [ -z "$STDERR_NOTICE_COUNT_L" ] && STDERR_NOTICE_COUNT_L=0
  if [ "$STDERR_NOTICE_COUNT_L" -eq 1 ]; then
    ok "unwritable dir: exactly one stderr notice printed (not one per failed emit)"
  else
    bad "unwritable dir: expected exactly 1 stderr notice, got $STDERR_NOTICE_COUNT_L -- $(cat "$TMPROOT/l.err")"
  fi

  if grep -q 'RESULT path_after None' "$UNWRITABLE_OUT_L"; then
    ok "unwritable dir: event log disabled itself (path reset to None) after the first failure"
  else
    bad "unwritable dir: event log path was not reset to None after failure -- $(grep path_after "$UNWRITABLE_OUT_L")"
  fi

  if grep -q 'RESULT notified True' "$UNWRITABLE_OUT_L"; then
    ok "unwritable dir: _event_log_notified latched True"
  else
    bad "unwritable dir: _event_log_notified never latched -- $(grep notified "$UNWRITABLE_OUT_L")"
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

# ═════════════════════════════════════════════════════════════════════════════
# hmdapp docs/HANDOFF-TO-HEIMDALL-relay-ipv6-stall.md -- scenarios O, O2, P, Q, R
#
# Root cause: on the operator's Mac a connect to the relay over IPv6 sometimes
# black-holes (SYN dropped, connect() hangs ~10 s) while the resolver hands
# IPv6 back FIRST, so any hmd->relay POST -- a state frame or an ack -- can sit
# in connect() past the phone's 10 s ack window, and a POST that times out was
# never retried. Three asks, one scenario group each:
#   1. connect robustly      -> O (real client, black-holed first address),
#                               O2 (bad HMD_RELAY_IP_FAMILY), P (the connect
#                               logic itself, case by case)
#   2. retry a failed ack    -> Q (real client + a relay that drops ack
#                               responses), R (the retry's timing rules, on a
#                               clock the harness steps by hand)
#   3. log every ack         -> Q and R (ack_sent for every command)
#
# A true black hole cannot be built from userland on loopback portably (a full
# accept queue stalls Linux but not macOS), so test/lib/fake-relay.py's
# `netfault` mode and install_netfault() emulate one at the stdlib's resolver
# and blocking-connect calls -- below the client, so the pre-fix client stalls
# on exactly the same table the fixed one sails through.
# ═════════════════════════════════════════════════════════════════════════════

# res FILE KEY -- the value of a harness's `RESULT KEY <value>` line ("" if absent)
res() { sed -n "s/^RESULT $2 //p" "$1" | head -1; }

# check_res FILE KEY EXPECTED DESC -- ok when `RESULT KEY` equals EXPECTED exactly
check_res() {
  local got
  got="$(res "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 (got '$got', want '$3')"; fi
}

# check_res_between FILE KEY LO HI DESC -- ok when `RESULT KEY` is an integer in [LO, HI)
check_res_between() {
  local got
  got="$(res "$1" "$2")"
  case "$got" in
    ''|*[!0-9]*) bad "$5 (got '$got', want an integer in [$3, $4))"; return ;;
  esac
  if [ "$got" -ge "$3" ] && [ "$got" -lt "$4" ]; then ok "$5 ($got)"; else bad "$5 (got $got, want [$3, $4))"; fi
}

# ── Scenario O: the REAL client against a relay whose FIRST resolved address
# black-holes. hmd-relay.test resolves to [::1 black-holed, 127.0.0.1 answering]
# below the client; against the pre-fix client pair/init alone then waits out
# the whole 15 s connect timeout before it ever reaches IPv4 ─────────────────
REPO_O="$(make_repo)"
PORT_O_RELAY="$(free_port)"
PORT_O_UI="$(free_port)"
LOG_O="$TMPROOT/o.log"; CTL_O="$TMPROOT/o.ctl"
mkdir -p "$LOG_O" "$CTL_O"

python3 "$FAKE_RELAY" serve "$PORT_O_RELAY" --log "$LOG_O" --ctl "$CTL_O" >"$TMPROOT/o.srv.out" 2>&1 &
SRV_O=$!
PIDS+=("$SRV_O")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_O_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_O_OUT="$TMPROOT/o.client.out"
EVENT_LOG_O="$REPO_O/.heimdall/app/relay-events.jsonl"
python3 "$FAKE_RELAY" netfault --host hmd-relay.test --addrs '::1!,127.0.0.1' -- \
  "$RELAY_CLIENT_RUN" --relay "http://hmd-relay.test:$PORT_O_RELAY" --repo "$REPO_O" --ui-port "$PORT_O_UI" \
  >"$CLIENT_O_OUT" 2>"$TMPROOT/o.client.err" &
CLIENT_O=$!
PIDS+=("$CLIENT_O")

if wait_for "$CLIENT_O_OUT" '"event":"device_bound"' 8; then
  ok "scenario O: paired and bound through a relay name whose first address black-holes (pair/init + stream never waited it out)"
else
  bad "scenario O: never bound within 8 s -- a connect waited out the black-holed first address: $(tail -3 "$TMPROOT/o.client.err" 2>/dev/null)"
fi
wait_for_count "$LOG_O/frames.ndjson" 1 '"type":"state"' 10 >/dev/null 2>&1 || true
wait_for "$EVENT_LOG_O" '"event":"state_sent"' 10 || true

O_CHECK="$TMPROOT/o.check.out"
python3 - "$EVENT_LOG_O" >"$O_CHECK" 2>"$TMPROOT/o.check.err" <<'PYEOF'
import calendar
import json
import sys
import time

events = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except ValueError:
            continue  # the client is still running -- a half-written last line


def ts(event):
    t = event["ts"]
    return calendar.timegm(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S")) + int(t[20:23]) / 1000.0


connects = [e for e in events if e.get("event") == "connect"]
labels = {str(e.get("for")) for e in connects}
print("RESULT o_connect_count %d" % len(connects))
print("RESULT o_has_pair_stream_frames %s" % ({"pair", "stream", "frames"} <= labels))
print("RESULT o_families %s" % ",".join(sorted({str(e.get("family")) for e in connects})))
print("RESULT o_attempts %s" % ",".join(sorted({str(e.get("attempts")) for e in connects})))
print("RESULT o_max_connect_ms %d" % max((e["ms"] for e in connects if isinstance(e.get("ms"), int)), default=-1))

# POST /frames end to end: the connect's own ms plus the time from that connect
# event to the state_sent that is only emitted once the response is in
post_ms = -1
for i, e in enumerate(events):
    if e.get("event") == "connect" and e.get("for") == "frames":
        sent = next((s for s in events[i + 1:] if s.get("event") == "state_sent"), None)
        if sent is not None:
            post_ms = int(e["ms"] + (ts(sent) - ts(e)) * 1000)
            break
print("RESULT o_post_frames_ms %d" % post_ms)
PYEOF

check_res "$O_CHECK" o_has_pair_stream_frames True "scenario O: a connect event was logged for each of pair, stream and frames"
check_res "$O_CHECK" o_families ipv4 "scenario O: every connection went out over IPv4 -- the black-holed IPv6 address never won"
check_res "$O_CHECK" o_attempts 1 "scenario O: every connection needed exactly one attempt (IPv4 is tried first, IPv6 never raced in)"
O_MAX_MS="$(res "$O_CHECK" o_max_connect_ms)"
if [ -n "$O_MAX_MS" ] && [ "$O_MAX_MS" -ge 0 ] && [ "$O_MAX_MS" -lt 1000 ]; then
  ok "scenario O: the slowest connect took ${O_MAX_MS} ms (< 1000 ms, the handoff's 'v4 within ~1 s')"
else
  bad "scenario O: slowest connect was '$O_MAX_MS' ms, want 0..999"
fi
check_res_between "$O_CHECK" o_post_frames_ms 0 2000 "scenario O: POST /frames completed in under 2 s with IPv6 black-holed (handoff acceptance)"
if [ ! -s "$TMPROOT/o.client.err" ]; then
  ok "scenario O: the client wrote nothing to stderr (no connect thread died with a traceback)"
else
  bad "scenario O: the client wrote to stderr: $(head -5 "$TMPROOT/o.client.err")"
fi

kill "$CLIENT_O" 2>/dev/null
wait "$CLIENT_O" 2>/dev/null
kill "$SRV_O" 2>/dev/null
wait "$SRV_O" 2>/dev/null

# ── Scenario O2: HMD_RELAY_IP_FAMILY with a value the knob does not know is a
# loud `error` event naming it -- never silently swallowed -- and the client
# falls back to auto and still works ────────────────────────────────────────
REPO_O2="$(make_repo)"
PORT_O2_RELAY="$(free_port)"
PORT_O2_UI="$(free_port)"
LOG_O2="$TMPROOT/o2.log"; CTL_O2="$TMPROOT/o2.ctl"
mkdir -p "$LOG_O2" "$CTL_O2"

python3 "$FAKE_RELAY" serve "$PORT_O2_RELAY" --log "$LOG_O2" --ctl "$CTL_O2" >"$TMPROOT/o2.srv.out" 2>&1 &
SRV_O2=$!
PIDS+=("$SRV_O2")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_O2_RELAY))==0 else 1)" && break
  sleep 0.1
done

CLIENT_O2_OUT="$TMPROOT/o2.client.out"
HMD_RELAY_IP_FAMILY=bogus "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_O2_RELAY" --repo "$REPO_O2" --ui-port "$PORT_O2_UI" \
  >"$CLIENT_O2_OUT" 2>"$TMPROOT/o2.client.err" &
CLIENT_O2=$!
PIDS+=("$CLIENT_O2")

if wait_for_event "$CLIENT_O2_OUT" "error" "HMD_RELAY_IP_FAMILY" 10; then
  ok "scenario O2: HMD_RELAY_IP_FAMILY=bogus produced an error event naming the knob"
else
  bad "scenario O2: HMD_RELAY_IP_FAMILY=bogus was swallowed silently -- no error event named it"
fi
if wait_for "$CLIENT_O2_OUT" '"event":"device_bound"' 10; then
  ok "scenario O2: the client fell back to auto and still paired"
else
  bad "scenario O2: the client did not come up after a bad HMD_RELAY_IP_FAMILY"
fi

kill "$CLIENT_O2" 2>/dev/null
wait "$CLIENT_O2" 2>/dev/null
kill "$SRV_O2" 2>/dev/null
wait "$SRV_O2" 2>/dev/null

# ── Scenario P: the connect logic itself, case by case. Imports the client and
# fake-relay.py in one process and drives `_connect(...).connect()` -- the very
# call every request and the stream go through -- with install_netfault()
# standing in for the network. Every case reads the same way against the
# pre-fix client (serial create_connection), which is what makes the failures
# below meaningful ──────────────────────────────────────────────────────────
HE_OUT_P="$TMPROOT/p.he.out"
python3 - "$RELAY_CLIENT_RUN" "$FAKE_RELAY" >"$HE_OUT_P" 2>"$TMPROOT/p.he.err" <<'PYEOF'
import contextlib
import io
import json
import os
import socket
import ssl
import sys
import threading
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path, fake_relay_path = sys.argv[1:3]
HOST = "hmd-relay.test"
V4, V6 = socket.AF_INET, socket.AF_INET6
FAMILY_NAME = {V4: "ipv4", V6: "ipv6"}


def load(path, name, env=None):
    """Import a script by path (bin/heimdall-relay-client has no .py suffix, hence
    the explicit SourceFileLoader) with `env` applied for the duration of the
    import only -- the client reads its HMD_RELAY_* knobs once, at import."""
    env = env or {}
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        loader = SourceFileLoader(name, path)
        mod = module_from_spec(spec_from_loader(name, loader))
        loader.exec_module(mod)
        return mod
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


fake_relay = load(fake_relay_path, "fake_relay_under_harness")
client = load(client_path, "hmd_relay_client_he_auto")
client_v4 = load(client_path, "hmd_relay_client_he_v4", {"HMD_RELAY_IP_FAMILY": "4"})
client_v6 = load(client_path, "hmd_relay_client_he_v6", {"HMD_RELAY_IP_FAMILY": "6"})


def v6_loopback_usable():
    try:
        probe = socket.socket(V6, socket.SOCK_STREAM)
    except OSError:
        return False
    try:
        probe.bind(("::1", 0))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def open_listeners():
    """A v4 listener on 127.0.0.1:P and, where this host has IPv6 loopback, a v6
    listener on [::1]:P -- the SAME port, because getaddrinfo(host, port) hands
    every address of a name the one port."""
    want_v6 = v6_loopback_usable()
    for _ in range(50):
        l4 = socket.socket(V4, socket.SOCK_STREAM)
        l4.bind(("127.0.0.1", 0))
        l4.listen(16)
        port = l4.getsockname()[1]
        if not want_v6:
            return l4, None, port
        l6 = socket.socket(V6, socket.SOCK_STREAM)
        try:
            l6.bind(("::1", port))
            l6.listen(16)
            return l4, l6, port
        except OSError:
            l6.close()
            l4.close()
    raise SystemExit("no free v4+v6 loopback port pair")


def closed_port():
    s = socket.socket(V4, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_case(mod, table, port, timeout=3.0, scheme="http", conn_hook=None, resolver=None):
    """Resolve HOST through `table` (see fake-relay.py's NetFault) and connect;
    `resolver`, when given, then replaces the patched getaddrinfo (restore()
    puts the real one back either way)."""
    fault = fake_relay.install_netfault(HOST, table)
    if resolver is not None:
        socket.getaddrinfo = resolver
    out = io.StringIO()
    parsed = mod._split_relay("%s://%s:%d" % (scheme, HOST, port))
    result = {"ok": False, "family": None, "error": "", "local_port": None}
    t0 = time.monotonic()
    conn = mod._connect(parsed, timeout=timeout)
    if conn_hook is not None:
        conn_hook(conn)
    try:
        with contextlib.redirect_stdout(out):
            conn.connect()
        result["ok"] = True
        result["family"] = FAMILY_NAME.get(conn.sock.family, "?")
        result["local_port"] = conn.sock.getsockname()[1]
    except OSError as e:
        result["error"] = str(e).replace("\n", " ")
    finally:
        result["ms"] = int((time.monotonic() - t0) * 1000)
        conn.close()
        fault.restore()
    result["attempted"] = list(fault.attempted)
    result["events"] = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return result


def show(tag, r):
    print("RESULT %s_ok %s" % (tag, r["ok"]))
    print("RESULT %s_ms %d" % (tag, r["ms"]))
    print("RESULT %s_family %s" % (tag, r["family"]))
    print("RESULT %s_attempted %s" % (tag, ",".join(r["attempted"])))
    print("RESULT %s_error %s" % (tag, r["error"]))
    print("RESULT %s_local_port %s" % (tag, r["local_port"]))
    connects = [e for e in r["events"] if e.get("event") == "connect"]
    print("RESULT %s_connect_events %d" % (tag, len(connects)))
    if connects:
        print("RESULT %s_connect_event %s" % (tag, json.dumps(connects[0], sort_keys=True)))


l4, l6, PORT = open_listeners()
print("RESULT have_v6 %s" % (l6 is not None))

# c1: the resolver answers IPv6 first and IPv6 black-holes -- the operator's Mac
show("c1", run_case(client, [(V6, "::1", True), (V4, "127.0.0.1", False)], PORT))
# c2: same family, first address black-holed -- the second is raced in after the stagger
show("c2", run_case(client, [(V4, "127.0.0.2", True), (V4, "127.0.0.1", False)], PORT))
# c3: IPv4 black-holed instead -- IPv6 must rescue it (needs IPv6 loopback)
if l6 is not None:
    show("c3", run_case(client, [(V4, "127.0.0.1", True), (V6, "::1", False)], PORT))
# c4: HMD_RELAY_IP_FAMILY=4 considers IPv4 only -- a black-holed IPv4 is NOT rescued by IPv6
show("c4", run_case(client_v4, [(V4, "127.0.0.1", True), (V6, "::1", False)], PORT, timeout=1.0))
# c5: HMD_RELAY_IP_FAMILY=6 considers IPv6 only -- IPv4 is never tried although it answers
show("c5", run_case(client_v6, [(V4, "127.0.0.1", False), (V6, "::1", False)], PORT))
# c6: nothing answers (every address refuses) -- one error that names each family tried
show("c6", run_case(client, [(V6, "::1", False), (V4, "127.0.0.1", False)], closed_port()))
# c7: every address black-holed -- bounded by the ONE overall timeout, not one timeout per address
show("c7", run_case(client, [(V4, "127.0.0.1", True), (V6, "::1", True)], PORT, timeout=1.0))
# c8: HTTPS -- the TLS handshake is still aimed at the NAME, never at the winning IP.
# ssl.SSLContext.wrap_socket is patched at the CLASS, so this reads the same
# however a client builds its connection
recorded = {}
real_wrap_socket = ssl.SSLContext.wrap_socket


def recording_wrap_socket(self, sock, *args, server_hostname=None, **kwargs):
    recorded["server_hostname"] = server_hostname
    raise ssl.SSLError("recording wrap_socket: handshake intentionally not attempted")


ssl.SSLContext.wrap_socket = recording_wrap_socket
try:
    show("c8", run_case(client, [(V4, "127.0.0.1", False)], PORT, scheme="https"))
finally:
    ssl.SSLContext.wrap_socket = real_wrap_socket
print("RESULT c8_server_hostname %s" % recorded.get("server_hostname"))

# c9: a source address set on the connection is honoured -- bound to a port picked up front
bind_port = closed_port()
show("c9", run_case(client, [(V4, "127.0.0.1", False)], PORT,
                    conn_hook=lambda conn: setattr(conn, "source_address", ("127.0.0.1", bind_port))))
print("RESULT c9_bind_port %d" % bind_port)

# c10: the OS refuses to start a thread for the first address -- that address just counts as failed
real_start = threading.Thread.start
start_failures = []


def failing_start(self):
    if self.name == "relay-connect" and not start_failures:
        start_failures.append(self.name)
        raise RuntimeError("can't start new thread")
    return real_start(self)


threading.Thread.start = failing_start
try:
    show("c10", run_case(client, [(V4, "127.0.0.2", False), (V4, "127.0.0.1", False)], PORT))
finally:
    threading.Thread.start = real_start

# c11: the resolver comes back with nothing at all
show("c11", run_case(client, [(V4, "127.0.0.1", False)], PORT,
                     resolver=lambda host, port, family=0, type=0, proto=0, flags=0: []))

# c12: an address that finally connects AFTER the race was decided closes itself -- the
# listener it reached sees EOF at once, not a connection left dangling (needs IPv6 loopback)
if l6 is not None:
    l4.setblocking(False)
    while True:
        try:
            l4.accept()
        except BlockingIOError:
            break  # backlog drained: only c12's slow loser can be accepted from here on
    l4.settimeout(4.0)
    show("c12", run_case(client, [(V4, "127.0.0.1", False, 0.8), (V6, "::1", False)], PORT))
    try:
        loser, _addr = l4.accept()
        loser.settimeout(4.0)
        print("RESULT c12_loser_closed %s" % (loser.recv(1) == b""))
        loser.close()
    except OSError as e:
        print("RESULT c12_loser_closed %s" % e)

# how the knob's value is read: empty means unset, whitespace is trimmed, anything else is invalid
client_empty = load(client_path, "hmd_relay_client_he_empty", {"HMD_RELAY_IP_FAMILY": ""})
client_spaced = load(client_path, "hmd_relay_client_he_spaced", {"HMD_RELAY_IP_FAMILY": " 6 "})
client_bogus = load(client_path, "hmd_relay_client_he_bogus", {"HMD_RELAY_IP_FAMILY": "ipv6"})
print("RESULT env_empty %s/%s" % (client_empty.IP_FAMILY, client_empty.IP_FAMILY_VALID))
print("RESULT env_spaced %s/%s" % (client_spaced.IP_FAMILY, client_spaced.IP_FAMILY_VALID))
print("RESULT env_bogus %s/%s" % (client_bogus.IP_FAMILY, client_bogus.IP_FAMILY_VALID))

l4.close()
if l6 is not None:
    l6.close()
sys.exit(0)
PYEOF
HE_RC_P=$?

if [ "$HE_RC_P" -eq 0 ]; then
  ok "scenario P: connect-logic harness ran to completion"
else
  bad "scenario P: connect-logic harness exited $HE_RC_P -- $(tail -3 "$TMPROOT/p.he.err")"
fi

check_res "$HE_OUT_P" c1_family ipv4 "P/c1: IPv6 first and black-holed -- the connection went out over IPv4"
check_res_between "$HE_OUT_P" c1_ms 0 1000 "P/c1: ...in under 1 s ms (the pre-fix serial connect waits out the black hole first)"
check_res "$HE_OUT_P" c1_attempted 127.0.0.1 "P/c1: IPv4 is tried first -- no attempt is ever spent on the black-holed IPv6 address"
C1_EVENT="$(res "$HE_OUT_P" c1_connect_event)"
if printf '%s' "$C1_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if (e.get("event") == "connect" and e.get("family") == "ipv4" and isinstance(e.get("ms"), int)
               and isinstance(e.get("dns_ms"), int) and e.get("attempts") == 1 and isinstance(e.get("for"), str)) else 1)
' 2>/dev/null; then
  ok "P/c1: exactly one connect event naming family=ipv4, ms, dns_ms, attempts=1 and what it was for"
else
  bad "P/c1: connect event missing or malformed (got '$C1_EVENT')"
fi
check_res "$HE_OUT_P" c1_connect_events 1 "P/c1: one connection emitted exactly one connect event"

check_res "$HE_OUT_P" c2_ok True "P/c2: same-family race -- connected although the first address black-holes"
check_res "$HE_OUT_P" c2_attempted "127.0.0.2,127.0.0.1" "P/c2: the second address was started only after the first (in resolver order)"
check_res_between "$HE_OUT_P" c2_ms 200 1500 "P/c2: the second address was raced in after the ~250 ms stagger, not after the 3 s timeout"
C2_EVENT="$(res "$HE_OUT_P" c2_connect_event)"
if printf '%s' "$C2_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("event") == "connect" and e.get("attempts") == 2 else 1)
' 2>/dev/null; then
  ok "P/c2: the connect event reports attempts=2 (a fallback happened)"
else
  bad "P/c2: connect event does not report attempts=2 (got '$C2_EVENT')"
fi

if [ "$(res "$HE_OUT_P" have_v6)" = "True" ]; then
  check_res "$HE_OUT_P" c3_family ipv6 "P/c3: IPv4 black-holed -- IPv6 rescued the connection"
  check_res_between "$HE_OUT_P" c3_ms 200 1500 "P/c3: ...after the ~250 ms stagger"
  C3_EVENT="$(res "$HE_OUT_P" c3_connect_event)"
  if printf '%s' "$C3_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("family") == "ipv6" and e.get("attempts") == 2 else 1)
' 2>/dev/null; then
    ok "P/c3: the connect event names family=ipv6 and attempts=2"
  else
    bad "P/c3: connect event does not name ipv6/attempts=2 (got '$C3_EVENT')"
  fi
else
  skip "P/c3: IPv4-black-holed -> IPv6 rescue: this host has no IPv6 loopback"
fi

check_res "$HE_OUT_P" c4_attempted 127.0.0.1 "P/c4: HMD_RELAY_IP_FAMILY=4 never attempts an IPv6 address"
check_res "$HE_OUT_P" c4_ok False "P/c4: HMD_RELAY_IP_FAMILY=4 does not fall back to IPv6 when IPv4 black-holes"
check_res "$HE_OUT_P" c5_attempted "::1" "P/c5: HMD_RELAY_IP_FAMILY=6 never attempts an IPv4 address, though one answers"

check_res "$HE_OUT_P" c6_ok False "P/c6: every address refusing is an error, not a hang"
check_res_between "$HE_OUT_P" c6_ms 0 1000 "P/c6: ...reported promptly (ms)"
C6_ERROR="$(res "$HE_OUT_P" c6_error)"
case "$C6_ERROR" in
  *ipv4*ipv6*|*ipv6*ipv4*) ok "P/c6: the error names every family tried ($C6_ERROR)" ;;
  *) bad "P/c6: the error does not name both families (got '$C6_ERROR')" ;;
esac

check_res "$HE_OUT_P" c7_ok False "P/c7: every address black-holed is an error"
check_res_between "$HE_OUT_P" c7_ms 0 1600 "P/c7: bounded by the one overall 1 s timeout, not 1 s per address (ms)"
case "$(res "$HE_OUT_P" c7_error)" in
  *"timed out"*) ok "P/c7: the error says the attempts timed out" ;;
  *) bad "P/c7: error does not say timed out (got '$(res "$HE_OUT_P" c7_error)')" ;;
esac

check_res "$HE_OUT_P" c8_server_hostname hmd-relay.test "P/c8: HTTPS verifies the certificate against the relay NAME, not the IP it connected to"

check_res "$HE_OUT_P" c9_ok True "P/c9: a connection with a source address still connects"
C9_PORT="$(res "$HE_OUT_P" c9_local_port)"
C9_BIND="$(res "$HE_OUT_P" c9_bind_port)"
if [ -n "$C9_BIND" ] && [ "$C9_PORT" = "$C9_BIND" ]; then
  ok "P/c9: ...from the source port it asked for ($C9_PORT)"
else
  bad "P/c9: local port was '$C9_PORT', wanted the requested source port '$C9_BIND'"
fi

check_res "$HE_OUT_P" c10_ok True "P/c10: no thread could be started for the first address -> it counts as failed and the next still connects"
check_res "$HE_OUT_P" c10_attempted 127.0.0.1 "P/c10: ...the address whose thread never started was never attempted"
C10_EVENT="$(res "$HE_OUT_P" c10_connect_event)"
if printf '%s' "$C10_EVENT" | python3 -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(0 if e.get("attempts") == 2 else 1)
' 2>/dev/null; then
  ok "P/c10: ...and the connect event counts both addresses as attempts"
else
  bad "P/c10: connect event does not report attempts=2 (got '$C10_EVENT')"
fi

check_res "$HE_OUT_P" c11_ok False "P/c11: a resolver that finds no address at all is an error, not a hang"
case "$(res "$HE_OUT_P" c11_error)" in
  *"no IPv4/IPv6 address"*) ok "P/c11: ...and the error says so" ;;
  *) bad "P/c11: error does not say no address was found (got '$(res "$HE_OUT_P" c11_error)')" ;;
esac
check_res_between "$HE_OUT_P" c11_ms 0 1000 "P/c11: ...reported at once (ms)"

if [ "$(res "$HE_OUT_P" have_v6)" = "True" ]; then
  check_res "$HE_OUT_P" c12_family ipv6 "P/c12: a slow IPv4 connect lost the race to the faster IPv6 one"
  check_res "$HE_OUT_P" c12_loser_closed True "P/c12: ...and when the slow connect finally completed it closed itself (the listener saw EOF)"
else
  skip "P/c12: late-connecting loser closes itself: this host has no IPv6 loopback"
fi

check_res "$HE_OUT_P" env_empty "auto/True" "P: HMD_RELAY_IP_FAMILY= (empty) means unset -- auto, no complaint"
check_res "$HE_OUT_P" env_spaced "6/True" "P: HMD_RELAY_IP_FAMILY=' 6 ' is trimmed to 6"
check_res "$HE_OUT_P" env_bogus "auto/False" "P: HMD_RELAY_IP_FAMILY=ipv6 is not a value of the knob -- auto, flagged invalid"

if [ ! -s "$TMPROOT/p.he.err" ]; then
  ok "P: the harness wrote nothing to stderr (no connect thread died with a traceback)"
else
  bad "P: the harness wrote to stderr: $(head -5 "$TMPROOT/p.he.err")"
fi

# ── Scenario Q: a failed ack POST is retried -- the SAME sealed envelope, a
# bounded number of times -- and every command line is followed by ack_sent
# lines. fail-ack-posts=N makes the fake relay read the next N ack POSTs in
# full and drop the connection with no response (a lost response, the case that
# turns a naive retry into a duplicate). Needs real seal/open ───────────────
send_device_command() {
  # send_device_command CTLDIR FILENUM SESSION_ID KEY_B64 SEQ TEXT -- seals a
  # send-message command as the paired device and queues it for the relay's
  # stream to push to the client
  local ctl="$1" num="$2" sid="$3" key="$4" seq="$5" text="$6" seal nonce ct
  seal="$(python3 "$FAKE_RELAY" device seal --key-b64 "$key" --seq "$seq" --sender device \
    --text "{\"action\":\"send-message\",\"params\":{\"text\":\"$text\"}}")"
  nonce="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  ct="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$sid" --seq "$seq" --sender device \
    --type command --nonce "$nonce" --ciphertext "$ct" > "$ctl/$num.json"
}

if [ "$E2E_PRESENT" = true ]; then
  REPO_Q="$(make_repo)"
  PORT_Q_RELAY="$(free_port)"
  PORT_Q_UI="$(free_port)"
  LOG_Q="$TMPROOT/q.log"; CTL_Q="$TMPROOT/q.ctl"
  mkdir -p "$LOG_Q" "$CTL_Q"

  python3 "$FAKE_RELAY" serve "$PORT_Q_RELAY" --log "$LOG_Q" --ctl "$CTL_Q" >"$TMPROOT/q.srv.out" 2>&1 &
  SRV_Q=$!
  PIDS+=("$SRV_Q")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_Q_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  DEVQ_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEVQ_PRIV_B64="$(printf '%s' "$DEVQ_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEVQ_PUB_B64="$(printf '%s' "$DEVQ_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEVQ_PUB_B64" > "$CTL_Q/bind-device"

  CLIENT_Q_OUT="$TMPROOT/q.client.out"
  EVENT_LOG_Q="$REPO_Q/.heimdall/app/relay-events.jsonl"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_Q_RELAY" --repo "$REPO_Q" --ui-port "$PORT_Q_UI" \
    >"$CLIENT_Q_OUT" 2>"$TMPROOT/q.client.err" &
  CLIENT_Q=$!
  PIDS+=("$CLIENT_Q")

  wait_for "$CLIENT_Q_OUT" '"event":"pair_init"' 10 || true
  SID_Q="$(python3 -c "
import json
for line in open('$CLIENT_Q_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  HMD_PUB_Q="$(python3 -c "
import json
for line in open('$CLIENT_Q_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"
  if wait_for "$CLIENT_Q_OUT" '"event":"device_bound"' 10 && [ -n "$SID_Q" ] && [ -n "$HMD_PUB_Q" ]; then
    ok "scenario Q: relay-client paired (session key derivable)"
  else
    bad "scenario Q: relay-client never paired -- the rest of Q cannot run: $(tail -3 "$TMPROOT/q.client.err" 2>/dev/null)"
  fi
  SESSION_KEY_Q="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEVQ_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_Q" --session-id "$SID_Q" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # 1: the first two ack POSTs are dropped, the third gets through
  : > "$CTL_Q/fail-ack-posts=2"
  send_device_command "$CTL_Q" 001 "$SID_Q" "$SESSION_KEY_Q" 1 "ack retry probe"
  ACK_Q1_JSON="$(wait_for_ack_of_seq "$LOG_Q/frames.ndjson" "$SESSION_KEY_Q" 1 15)"
  if [ -n "$ACK_Q1_JSON" ]; then
    ok "scenario Q: the ack for seq=1 reached the relay after two dropped POSTs"
  else
    bad "scenario Q: no ack for seq=1 ever reached the relay -- a failed ack POST was never retried"
  fi
  wait_for_count "$EVENT_LOG_Q" 3 '"event":"ack_sent".*"of_seq":1,' 5 || true

  # 2: more drops than the bounded retry will spend -- it gives up after 3 tries, the client lives on
  : > "$CTL_Q/fail-ack-posts=9"
  send_device_command "$CTL_Q" 002 "$SID_Q" "$SESSION_KEY_Q" 2 "ack gives up"
  wait_for_count "$EVENT_LOG_Q" 3 '"event":"ack_sent".*"of_seq":2,' 15 || true
  sleep 2
  ACK_SENT_Q2="$(count_matching "$EVENT_LOG_Q" '"event":"ack_sent".*"of_seq":2,')"
  if [ "$ACK_SENT_Q2" -eq 3 ]; then
    ok "scenario Q: a permanently failing ack is tried exactly 3 times, then abandoned (no 4th attempt after 2 s)"
  else
    bad "scenario Q: expected exactly 3 ack_sent attempts for seq=2, got $ACK_SENT_Q2"
  fi
  rm -f "$CTL_Q"/fail-ack-posts=*

  # 3: the client is still alive and acks the next command on the first try
  send_device_command "$CTL_Q" 003 "$SID_Q" "$SESSION_KEY_Q" 3 "client survives"
  ACK_Q3_JSON="$(wait_for_ack_of_seq "$LOG_Q/frames.ndjson" "$SESSION_KEY_Q" 3 10)"
  if [ -n "$ACK_Q3_JSON" ]; then
    ok "scenario Q: after an abandoned ack the client kept running and acked the next command"
  else
    bad "scenario Q: the client never acked seq=3 after abandoning seq=2's ack"
  fi

  # 4: a command that fails to decrypt is acked (and the ack logged) like any other
  SEAL_Q4_JSON="$(python3 "$FAKE_RELAY" device seal --key-b64 "$SESSION_KEY_Q" --seq 4 --sender device \
    --text '{"action":"send-message","params":{"text":"forged"}}')"
  NONCE_Q4="$(printf '%s' "$SEAL_Q4_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  CT_Q4_GOOD="$(printf '%s' "$SEAL_Q4_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  CT_Q4="$(python3 -c "
import base64, sys
raw = bytearray(base64.b64decode(sys.argv[1]))
raw[0] ^= 0x01
print(base64.b64encode(bytes(raw)).decode('ascii'))
" "$CT_Q4_GOOD")"
  python3 "$FAKE_RELAY" device envelope --session-id "$SID_Q" --seq 4 --sender device \
    --type command --nonce "$NONCE_Q4" --ciphertext "$CT_Q4" > "$CTL_Q/004.json"
  wait_for_count "$EVENT_LOG_Q" 1 '"event":"ack_sent".*"of_seq":4,' 10 || true

  Q_CHECK="$TMPROOT/q.check.out"
  python3 - "$EVENT_LOG_Q" "$LOG_Q/frames.ndjson" "$LOG_Q/frames-dropped.ndjson" >"$Q_CHECK" 2>"$TMPROOT/q.check.err" <<'PYEOF'
import json
import sys

log_path, frames_path, dropped_path = sys.argv[1:4]


def load_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def csv(values):
    return ",".join(str(v) for v in values)


events = []
for line in load_lines(log_path):
    try:
        events.append(json.loads(line))
    except ValueError:
        continue


def acks_of(seq):
    return [e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == seq]


def ack_frames(path):
    out = []
    for line in load_lines(path):
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("type") == "ack":
            out.append(line)
    return out


def with_seq(lines, seq):
    return [l for l in lines if json.loads(l).get("seq") == seq]


delivered = ack_frames(frames_path)
dropped = ack_frames(dropped_path)

a1, a2, a3, a4 = acks_of(1), acks_of(2), acks_of(3), acks_of(4)

# command 1: two dropped POSTs, then success -- one delivered ack, same envelope every time
print("RESULT q1_attempts %s" % csv(e["attempt"] for e in a1))
print("RESULT q1_ok %s" % csv(e["ok"] for e in a1))
print("RESULT q1_delivered %s" % csv(e["delivered"] for e in a1))
print("RESULT q1_one_seq %s" % (bool(a1) and len({e["seq"] for e in a1}) == 1))
print("RESULT q1_id %s" % (bool(a1) and all(isinstance(e.get("id"), str) and e["id"] for e in a1)))
print("RESULT q1_ms_int %s" % (bool(a1) and all(isinstance(e.get("ms"), int) and e["ms"] >= 0 for e in a1)))
q1_seq = a1[0]["seq"] if a1 else None
d1, x1 = with_seq(delivered, q1_seq), with_seq(dropped, q1_seq)
print("RESULT q1_delivered_frames %d" % len(d1))
print("RESULT q1_dropped_frames %d" % len(x1))
print("RESULT q1_identical %s" % (bool(d1) and bool(x1) and all(l == d1[0] for l in x1)))

# command 2: every POST dropped -- bounded at three identical copies, none delivered
print("RESULT q2_attempts %s" % csv(e["attempt"] for e in a2))
print("RESULT q2_ok %s" % csv(e["ok"] for e in a2))
q2_seq = a2[0]["seq"] if a2 else None
d2, x2 = with_seq(delivered, q2_seq), with_seq(dropped, q2_seq)
print("RESULT q2_delivered_frames %d" % len(d2))
print("RESULT q2_dropped_frames %d" % len(x2))
print("RESULT q2_identical %s" % (bool(x2) and all(l == x2[0] for l in x2)))

# command 3: healthy relay -- one attempt
print("RESULT q3_attempts %s" % csv(e["attempt"] for e in a3))
print("RESULT q3_ok %s" % csv(e["ok"] for e in a3))
print("RESULT q3_delivered %s" % csv(e["delivered"] for e in a3))

# command 4: decrypt-failed -- still acked and logged; no inbox record, so id is null
print("RESULT q4_attempts %s" % csv(e["attempt"] for e in a4))
print("RESULT q4_id_null %s" % (bool(a4) and all(e.get("id") is None for e in a4)))

# every command line is followed by at least one ack_sent before the next command line
cmd_idx = [i for i, e in enumerate(events) if e.get("event") == "command"]
paired = bool(cmd_idx)
for n, i in enumerate(cmd_idx):
    stop = cmd_idx[n + 1] if n + 1 < len(cmd_idx) else len(events)
    if not any(e.get("event") == "ack_sent" for e in events[i + 1:stop]):
        paired = False
print("RESULT q_commands %d" % len(cmd_idx))
print("RESULT q_every_command_acked %s" % paired)

connects = [e for e in events if e.get("event") == "connect"]
print("RESULT q_connect_shape %s" % (bool(connects) and all(
    e.get("family") in ("ipv4", "ipv6") and isinstance(e.get("ms"), int) for e in connects)))
PYEOF

  check_res "$Q_CHECK" q1_attempts "1,2,3" "Q: two dropped ack POSTs then success -> ack_sent attempts 1,2,3"
  check_res "$Q_CHECK" q1_ok "False,False,True" "Q: ...ok=false,false,true"
  check_res "$Q_CHECK" q1_delivered "False,False,True" "Q: ...delivered=false,false,true"
  check_res "$Q_CHECK" q1_one_seq True "Q: all three attempts carry the SAME ack frame seq (one ack id, never a re-seal)"
  check_res "$Q_CHECK" q1_id True "Q: every ack_sent carries the inbox record id of the command it answers"
  check_res "$Q_CHECK" q1_ms_int True "Q: every ack_sent carries an integer ms"
  check_res "$Q_CHECK" q1_delivered_frames 1 "Q: exactly ONE ack frame was accepted by the relay (one delivered ack)"
  check_res "$Q_CHECK" q1_dropped_frames 2 "Q: the relay received the two dropped attempts in full"
  check_res "$Q_CHECK" q1_identical True "Q: the dropped copies are byte-identical to the delivered ack (duplicate-safe: the phone dedupes on seq)"

  check_res "$Q_CHECK" q2_attempts "1,2,3" "Q: a permanently failing ack is attempted exactly 3 times"
  check_res "$Q_CHECK" q2_ok "False,False,False" "Q: ...every attempt reported ok=false"
  check_res "$Q_CHECK" q2_delivered_frames 0 "Q: ...and none was accepted by the relay"
  # Three attempts, four POSTs: attempt 1 rides the ack connection that carried command 1's
  # delivered ack (frames now travel on a persistent connection), the relay drops it exactly as a
  # dead idle connection would drop it, and the client cannot tell the two apart -- so it re-POSTs
  # the same envelope once on a fresh connection before it calls that attempt failed. Attempts 2
  # and 3 open fresh connections of their own, so a failure there is not retried inside the attempt.
  check_res "$Q_CHECK" q2_dropped_frames 4 "Q: ...the relay received four copies (attempt 1 went out twice: once on the reused connection, once on a fresh one)"
  check_res "$Q_CHECK" q2_identical True "Q: ...and all four copies are the same envelope"

  check_res "$Q_CHECK" q3_attempts 1 "Q: a healthy relay is hit once per ack (no spurious retry)"
  check_res "$Q_CHECK" q3_ok True "Q: ...ok=true"
  check_res "$Q_CHECK" q3_delivered True "Q: ...delivered=true"

  check_res "$Q_CHECK" q4_attempts 1 "Q: a decrypt-failed command is acked and the ack logged"
  check_res "$Q_CHECK" q4_id_null True "Q: ...its ack_sent carries id=null (nothing was written to the inbox)"

  check_res "$Q_CHECK" q_commands 4 "Q: the log holds all four command lines"
  check_res "$Q_CHECK" q_every_command_acked True "Q: relay-events.jsonl shows an ack_sent line for every command line (handoff acceptance)"
  check_res "$Q_CHECK" q_connect_shape True "Q: the durable log carries connect events with family and integer ms"
  if [ ! -s "$TMPROOT/q.client.err" ]; then
    ok "Q: the client wrote nothing to stderr through every retry (no thread died with a traceback)"
  else
    bad "Q: the client wrote to stderr: $(head -5 "$TMPROOT/q.client.err")"
  fi

  kill "$CLIENT_Q" 2>/dev/null
  wait "$CLIENT_Q" 2>/dev/null
  kill "$SRV_Q" 2>/dev/null
  wait "$SRV_Q" 2>/dev/null
else
  skip "scenario Q (ack retry, ack_sent per command): bin/lib/hmd_relay_e2e.py absent -- needs device seal/open/derive"
fi

# ── Scenario R: the ack retry's timing rules, on a clock the harness steps by
# hand. Drives RelayClient._handle_command -- the real path an inbound command
# takes -- with send_frame_envelope replaced by a recorder, `time` by a clock
# that only moves when told to, and stop_event.wait by "advance the clock".
# Deterministic: no real sleeping, no race between a retry and a window ───────
if [ "$E2E_PRESENT" = true ]; then
  ACK_OUT_R="$TMPROOT/r.ack.out"
  python3 - "$RELAY_CLIENT_RUN" >"$ACK_OUT_R" 2>"$TMPROOT/r.ack.err" <<'PYEOF'
import argparse
import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path = sys.argv[1]


def load(env):
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        loader = SourceFileLoader("hmd_relay_client_ackharness", client_path)
        mod = module_from_spec(spec_from_loader(loader.name, loader))
        loader.exec_module(mod)
        return mod
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


class Clock:
    def __init__(self):
        self.now = 5000.0

    def advance(self, seconds):
        self.now += seconds


class FakeTime:
    """The client's `time` module with monotonic() replaced by a clock this
    harness steps by hand; everything else (time(), strftime(), ...) is real."""

    def __init__(self, clock):
        self.clock = clock

    def monotonic(self):
        return self.clock.now

    def __getattr__(self, name):
        return getattr(time, name)


class FakeStopEvent:
    """Stands in for RelayClient.stop_event: wait() advances the fake clock by
    the delay instead of sleeping, and reports "stopping" from the Nth wait on
    when stop_on_wait is given."""

    def __init__(self, clock, stop_on_wait=None):
        self.clock = clock
        self.stop_on_wait = stop_on_wait
        self.waits = []

    def is_set(self):
        return self.stop_on_wait is not None and len(self.waits) >= self.stop_on_wait

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if self.stop_on_wait is not None and len(self.waits) >= self.stop_on_wait:
            return True
        self.clock.advance(timeout or 0)
        return False


def run(env, seq, outcomes, cost=0.01, corrupt=False, stop_on_wait=None, inbox_cost=0.0, direct=False):
    """Hand one sealed command to _handle_command and record every POST attempt
    its ack makes. `outcomes` is what each attempt returns (None = the POST
    failed, False = relay answered but no phone is connected, True = delivered);
    each attempt also costs `cost` fake seconds. `inbox_cost` fake seconds are
    spent inside the inbox write, i.e. before the ack -- time the app's window
    keeps running while hmd is still busy. `direct` skips the command and calls
    send_hmd_frame("ack", ...) itself, with no deadline."""
    mod = load(env)
    clock = Clock()
    stop = FakeStopEvent(clock, stop_on_wait)
    calls = []
    plan = list(outcomes)

    def send_frame_envelope(type_, nonce, ciphertext, seq_, **kwargs):
        calls.append({"type": type_, "seq": seq_, "nonce": nonce, "ciphertext": ciphertext,
                      "timeout": kwargs.get("timeout")})
        clock.advance(cost)
        return (plan.pop(0) if plan else None), 321

    with tempfile.TemporaryDirectory() as repo:
        args = argparse.Namespace(relay="http://127.0.0.1:1", repo=repo, ui_port=0, public_host=None,
                                  status_file=os.path.join(repo, "status.json"), tick_s=2.0)
        client = mod.RelayClient(args)
        client.session_id = "sess-ackharness"
        client.token = "token-ackharness"
        client.session_key = os.urandom(32)
        client.stop_event = stop
        client.send_frame_envelope = send_frame_envelope
        mod.time = FakeTime(clock)
        if inbox_cost:
            real_append = mod.INBOX.append

            def slow_append(root, text):
                clock.advance(inbox_cost)
                return real_append(root, text)

            mod.INBOX.append = slow_append
        out = io.StringIO()
        if direct:
            with contextlib.redirect_stdout(out):
                client.send_hmd_frame("ack", {"ok": True, "of_seq": seq})
        else:
            plaintext = json.dumps({"action": "send-message", "params": {"text": "ack harness probe"}})
            nonce, ciphertext = mod.E2E.seal(client.session_key, seq, "device", plaintext.encode("utf-8"))
            if corrupt:
                raw = bytearray(base64.b64decode(ciphertext))
                raw[0] ^= 0x01
                ciphertext = base64.b64encode(bytes(raw)).decode("ascii")
            envelope = {"v": 1, "session_id": client.session_id, "seq": seq, "sender": "device",
                        "type": "command", "nonce": nonce, "ciphertext": ciphertext, "payload": None}
            with contextlib.redirect_stdout(out):
                client._handle_command(envelope)
        inbox_ids = []
        inbox_path = os.path.join(repo, ".heimdall", "ui", "inbox.jsonl")
        if os.path.exists(inbox_path):
            with open(inbox_path, encoding="utf-8") as f:
                inbox_ids = [json.loads(l)["id"] for l in f if l.strip()]
    events = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return {"calls": calls, "events": events, "waits": stop.waits, "frames_sent": client.frames_sent,
            "last_delivered": client.last_delivered, "inbox_ids": inbox_ids}


def csv(values):
    return ",".join(str(v) for v in values)


def show(tag, r):
    acks = [e for e in r["events"] if e.get("event") == "ack_sent"]
    calls = r["calls"]
    first = (calls[0]["nonce"], calls[0]["ciphertext"], calls[0]["seq"]) if calls else None
    print("RESULT %s_calls %d" % (tag, len(calls)))
    print("RESULT %s_same_envelope %s" % (tag, bool(calls) and all(
        (c["nonce"], c["ciphertext"], c["seq"]) == first for c in calls)))
    print("RESULT %s_timeouts %s" % (tag, csv("None" if c["timeout"] is None else "%.2f" % c["timeout"]
                                              for c in calls)))
    print("RESULT %s_waits %s" % (tag, csv("%.2f" % w for w in r["waits"])))
    print("RESULT %s_attempts %s" % (tag, csv(e["attempt"] for e in acks)))
    print("RESULT %s_ok %s" % (tag, csv(e["ok"] for e in acks)))
    print("RESULT %s_delivered %s" % (tag, csv(e["delivered"] for e in acks)))
    print("RESULT %s_frames_sent %d" % (tag, r["frames_sent"]))
    print("RESULT %s_last_delivered %s" % (tag, r["last_delivered"]))


DEFAULT = {}
# r1: two failures then success -> 3 attempts of the same envelope, backoff 0.25 s then 0.5 s
show("r1", run(DEFAULT, 1, [None, None, True]))
# r2: never succeeds -> still exactly 3 attempts
show("r2", run(DEFAULT, 2, [None] * 5))
# r3: a 1 s window and attempts that each burn 0.6 s -> the 3rd never starts, the 2nd is capped to what is left
show("r3", run({"HMD_RELAY_ACK_WINDOW_S": "1.0"}, 3, [None] * 5, cost=0.6))
# r4: the window was already spent (9 s inside the inbox write) -> the late first attempt is still made, no retries
show("r4", run(DEFAULT, 4, [None, True], inbox_cost=9.0))
# r5: the relay ANSWERED (200) but no phone is connected right now (delivered=false) -> an ack
# is never stored, so the phone would never see it: retried like a failed POST, same envelope,
# inside the window (zero-lag sync Ask 4c)
show("r5", run(DEFAULT, 5, [False, True]))
# r6: a command that fails to decrypt is acked, retried and logged too
r6 = run(DEFAULT, 6, [None, True], corrupt=True)
show("r6", r6)
print("RESULT r6_command_detail %s" % csv(e.get("detail") for e in r6["events"] if e.get("event") == "command"))
print("RESULT r6_ack_id %s" % csv(e.get("id") for e in r6["events"] if e.get("event") == "ack_sent"))
print("RESULT r6_of_seq %s" % csv(e.get("of_seq") for e in r6["events"] if e.get("event") == "ack_sent"))
# r7: the ack_sent event's exact shape
r7 = run(DEFAULT, 7, [True])
show("r7", r7)
first = next((e for e in r7["events"] if e.get("event") == "ack_sent"), {})
print("RESULT r7_keys %s" % csv(sorted(first)))
print("RESULT r7_types %s" % (isinstance(first.get("ms"), int) and isinstance(first.get("seq"), int)
                              and first.get("of_seq") == 7))
print("RESULT r7_id_is_inbox_id %s" % (bool(r7["inbox_ids"]) and first.get("id") == r7["inbox_ids"][-1]))
# r8: the client is told to stop while waiting out a backoff -> no further attempt
show("r8", run(DEFAULT, 8, [None, True], stop_on_wait=1))
# r9: an ack sent with no deadline of its own gets the default window from the moment it is sent
r9 = run(DEFAULT, 9, [None, True], direct=True)
show("r9", r9)
print("RESULT r9_of_seq %s" % csv(e.get("of_seq") for e in r9["events"] if e.get("event") == "ack_sent"))
# r10: a window of 0 means "never retry" -- the one attempt is still made
show("r10", run({"HMD_RELAY_ACK_WINDOW_S": "0"}, 10, [None, True]))
# r11: delivered=false every time -> still bounded at 3 attempts, every answer visible in ack_sent
show("r11", run(DEFAULT, 11, [False] * 5))
# r12: delivered=false and the window is a 1 s one burnt by 0.6 s attempts -> the same window rule
# as a failed POST: the 3rd attempt never starts
show("r12", run({"HMD_RELAY_ACK_WINDOW_S": "1.0"}, 12, [False] * 5, cost=0.6))
# HMD_RELAY_ACK_WINDOW_S that is not a sane number of seconds falls back to the 8 s default
for tag, value in (("nan", "nan"), ("negative", "-3"), ("junk", "abc"), ("huge", "1e9"),
                   ("zero", "0"), ("fractional", "2.5")):
    print("RESULT window_%s %s" % (tag, load({"HMD_RELAY_ACK_WINDOW_S": value}).ACK_WINDOW_S))
sys.exit(0)
PYEOF
  ACK_RC_R=$?

  if [ "$ACK_RC_R" -eq 0 ]; then
    ok "scenario R: ack-retry harness ran to completion"
  else
    bad "scenario R: ack-retry harness exited $ACK_RC_R -- $(tail -3 "$TMPROOT/r.ack.err")"
  fi

  check_res "$ACK_OUT_R" r1_calls 3 "R/r1: two failures then success -> 3 POST attempts"
  check_res "$ACK_OUT_R" r1_same_envelope True "R/r1: every attempt re-POSTs the identical sealed envelope (same nonce, ciphertext, seq)"
  check_res "$ACK_OUT_R" r1_timeouts "3.00,3.00,3.00" "R/r1: each attempt is bounded to 3 s, not the 15 s a state frame gets"
  check_res "$ACK_OUT_R" r1_waits "0.25,0.50" "R/r1: backoff is 0.25 s then 0.5 s"
  check_res "$ACK_OUT_R" r1_attempts "1,2,3" "R/r1: ack_sent logs attempts 1,2,3"
  check_res "$ACK_OUT_R" r1_ok "False,False,True" "R/r1: ack_sent ok=false,false,true"
  check_res "$ACK_OUT_R" r1_delivered "False,False,True" "R/r1: ack_sent delivered=false,false,true"
  check_res "$ACK_OUT_R" r1_frames_sent 1 "R/r1: the frame counts once in relay.json's frames_sent, not once per attempt"
  check_res "$ACK_OUT_R" r1_last_delivered True "R/r1: relay.json's last_delivered reflects the attempt that got through"

  check_res "$ACK_OUT_R" r2_calls 3 "R/r2: a never-succeeding ack is attempted exactly 3 times"
  check_res "$ACK_OUT_R" r2_ok "False,False,False" "R/r2: ack_sent ok=false on every attempt"
  check_res "$ACK_OUT_R" r2_frames_sent 0 "R/r2: an ack that never got through is not counted as sent"

  check_res "$ACK_OUT_R" r3_calls 2 "R/r3: inside a 1 s window with 0.6 s attempts the 3rd attempt never starts"
  check_res "$ACK_OUT_R" r3_timeouts "3.00,0.50" "R/r3: the retry's timeout is capped to the window that is left (floor 0.5 s)"
  check_res "$ACK_OUT_R" r3_attempts "1,2" "R/r3: ack_sent logs attempts 1,2 only"

  check_res "$ACK_OUT_R" r4_calls 1 "R/r4: a window already spent -> the (late) first attempt is still made, with no retries"
  check_res "$ACK_OUT_R" r4_timeouts "3.00" "R/r4: ...and gets the full per-attempt timeout"

  check_res "$ACK_OUT_R" r5_calls 2 "R/r5: a 200 with delivered=false (no phone attached right now) is retried inside the window"
  check_res "$ACK_OUT_R" r5_same_envelope True "R/r5: ...the identical sealed envelope again (same nonce, ciphertext, seq)"
  check_res "$ACK_OUT_R" r5_waits "0.25" "R/r5: ...after the same 0.25 s backoff a failed POST gets"
  check_res "$ACK_OUT_R" r5_attempts "1,2" "R/r5: ...ack_sent logs attempts 1,2"
  check_res "$ACK_OUT_R" r5_ok "True,True" "R/r5: ...ok=true on both (the relay answered each time)"
  check_res "$ACK_OUT_R" r5_delivered "False,True" "R/r5: ...delivered=false then true, so a phone-less relay stays diagnosable"
  check_res "$ACK_OUT_R" r5_frames_sent 1 "R/r5: ...and the ack still counts once in frames_sent"

  check_res "$ACK_OUT_R" r11_calls 3 "R/r11: a relay that keeps answering delivered=false is attempted exactly 3 times"
  check_res "$ACK_OUT_R" r11_ok "True,True,True" "R/r11: ...every attempt ok=true (answered)"
  check_res "$ACK_OUT_R" r11_delivered "False,False,False" "R/r11: ...every attempt delivered=false, none hidden"
  check_res "$ACK_OUT_R" r11_last_delivered False "R/r11: ...relay.json's last_delivered ends false"

  check_res "$ACK_OUT_R" r12_calls 2 "R/r12: delivered=false obeys the same window as a failed POST -- the 3rd attempt never starts"
  check_res "$ACK_OUT_R" r12_timeouts "3.00,0.50" "R/r12: ...and the retry's timeout is capped to what is left of the window"

  check_res "$ACK_OUT_R" r6_command_detail "decrypt-failed" "R/r6: the command line reports decrypt-failed"
  check_res "$ACK_OUT_R" r6_attempts "1,2" "R/r6: its ack is retried and logged like any other"
  check_res "$ACK_OUT_R" r6_ack_id "None,None" "R/r6: ...with id=null (nothing was written to the inbox)"
  check_res "$ACK_OUT_R" r6_of_seq "6,6" "R/r6: ...naming the command seq it answers"

  check_res "$ACK_OUT_R" r7_keys "attempt,delivered,event,id,ms,of_seq,ok,seq" "R/r7: ack_sent carries exactly attempt, delivered, event, id, ms, of_seq, ok, seq"
  check_res "$ACK_OUT_R" r7_types True "R/r7: ms and seq are integers and of_seq is the command's seq"
  check_res "$ACK_OUT_R" r7_id_is_inbox_id True "R/r7: id is the inbox record id the ack's sealed payload carries"

  check_res "$ACK_OUT_R" r8_calls 1 "R/r8: told to stop mid-backoff -> no further attempt (shutdown is never delayed by a retry)"
  check_res "$ACK_OUT_R" r8_waits "0.25" "R/r8: ...the backoff wait goes through stop_event, so a stop interrupts it"

  check_res "$ACK_OUT_R" r9_calls 2 "R/r9: an ack sent with no deadline of its own is still retried (default window)"
  check_res "$ACK_OUT_R" r9_attempts "1,2" "R/r9: ...ack_sent logs attempts 1,2"
  check_res "$ACK_OUT_R" r9_of_seq "9,9" "R/r9: ...naming the seq the ack answers"

  check_res "$ACK_OUT_R" r10_calls 1 "R/r10: HMD_RELAY_ACK_WINDOW_S=0 means never retry -- the one attempt is still made"
  check_res "$ACK_OUT_R" r10_timeouts "3.00" "R/r10: ...with the full per-attempt timeout"

  check_res "$ACK_OUT_R" window_fractional "2.5" "R: HMD_RELAY_ACK_WINDOW_S=2.5 is read as 2.5 s"
  check_res "$ACK_OUT_R" window_zero "0.0" "R: HMD_RELAY_ACK_WINDOW_S=0 is read as 0 s (retries off), not rejected"
  check_res "$ACK_OUT_R" window_nan "8.0" "R: HMD_RELAY_ACK_WINDOW_S=nan falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_negative "8.0" "R: HMD_RELAY_ACK_WINDOW_S=-3 falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_junk "8.0" "R: HMD_RELAY_ACK_WINDOW_S=abc falls back to the 8 s default"
  check_res "$ACK_OUT_R" window_huge "8.0" "R: HMD_RELAY_ACK_WINDOW_S=1e9 (absurd) falls back to the 8 s default"
else
  skip "scenario R (ack retry timing rules): bin/lib/hmd_relay_e2e.py absent -- needs real seal/open"
fi

# ═════════════════════════════════════════════════════════════════════════════
# docs/HANDOFF-TO-HEIMDALL-zero-lag-sync.md (hmdapp repo, read-only), Asks 3 and
# 4 -- the hmd -> relay leg:
#   3. one persistent connection for POST /frames, not one per frame
#                              -> S (the transport, against fake-relay.py's
#                                 connection counter), U (the real client)
#   4a. a failed state POST is re-sent, not forgotten
#                              -> T (real client, a relay that drops the first
#                                 state POST), W (the digest/backoff rules)
#   4b. an ack never waits behind a slow state POST
#                              -> U (real client, a state POST held 3 s at the
#                                 relay while a command is acked), W (the lock
#                                 and ordering rules, stub transport)
#   4c. an ack answered delivered=false is retried inside the ack window
#                              -> U (real client), R above (the timing rules)
# Every case reads the same way against the pre-fix client, which is what makes
# the failures there meaningful: a connection per POST, a digest recorded before
# its POST, one lock across seal + POST + ack retries.
# ═════════════════════════════════════════════════════════════════════════════

# ── Scenario S: POST /frames rides ONE persistent connection per sender. Drives
# RelayClient.send_frame_envelope -- the one function every state frame and every
# ack POST goes through -- against fake-relay.py, which numbers every TCP
# connection it accepts (frame-posts.log), so "one connection" is the relay's own
# count and not the client's claim ───────────────────────────────────────────
PORT_S_RELAY="$(free_port)"
LOG_S="$TMPROOT/s.log"; CTL_S="$TMPROOT/s.ctl"
mkdir -p "$LOG_S" "$CTL_S"
python3 "$FAKE_RELAY" serve "$PORT_S_RELAY" --log "$LOG_S" --ctl "$CTL_S" >"$TMPROOT/s.srv.out" 2>&1 &
SRV_S=$!
PIDS+=("$SRV_S")
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_S_RELAY))==0 else 1)" && break
  sleep 0.1
done

FRAMES_OUT_S="$TMPROOT/s.frames.out"
python3 - "$RELAY_CLIENT_RUN" "$PORT_S_RELAY" "$LOG_S" "$CTL_S" >"$FRAMES_OUT_S" 2>"$TMPROOT/s.frames.err" <<'PYEOF'
import argparse
import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import time
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

client_path, port, log_dir, ctl_dir = sys.argv[1:5]
loader = SourceFileLoader("hmd_relay_client_frames_harness", client_path)
mod = module_from_spec(spec_from_loader(loader.name, loader))
loader.exec_module(mod)

NONCE, CIPHERTEXT = "bm9uY2U", "Y2lwaGVydGV4dA"  # opaque to the relay: it never opens a frame


def csv(values):
    return ",".join(str(v) for v in values)


def new_client(repo):
    """A RelayClient paired for real with the fake relay (a fresh session each time)."""
    args = argparse.Namespace(relay="http://127.0.0.1:%s" % port, repo=repo, ui_port=0, public_host=None,
                              status_file=os.path.join(repo, "status.json"), tick_s=2.0)
    client = mod.RelayClient(args)
    client.priv, client.pub = mod.E2E.generate_keypair()
    with contextlib.redirect_stdout(io.StringIO()):
        if client.pair_init() != 0:
            raise SystemExit("pair_init against the fake relay failed")
    return client


def post(client, type_, seq, timeout=15):
    """One send_frame_envelope call -> (answer, events it emitted, seconds it took)."""
    out = io.StringIO()
    began = time.monotonic()
    with contextlib.redirect_stdout(out):
        answer, _nbytes = client.send_frame_envelope(type_, NONCE, CIPHERTEXT, seq, timeout=timeout)
    events = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    return answer, events, time.monotonic() - began


def connects(events):
    return [e for e in events if e.get("event") == "connect" and e.get("for") == "frames"]


def posts(events):
    return [e for e in events if e.get("event") == "post"]


def relay_rows(seqs):
    """The relay's own frame-posts.log lines for these seqs, oldest first."""
    rows = []
    with open(os.path.join(log_dir, "frame-posts.log"), encoding="utf-8") as f:
        for line in f:
            kv = dict(part.split("=", 1) for part in line.split())
            if kv["seq"].isdigit() and int(kv["seq"]) in seqs:
                rows.append(kv)
    return rows


def relay_bodies(name, seq):
    path = os.path.join(log_dir, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip() and json.loads(l).get("seq") == seq]


def socket_of(client, sender):
    """The pooled socket of one sender's connection, or None when the client keeps no pool."""
    try:
        return client._frame_channels[sender].conn.sock
    except (AttributeError, KeyError):
        return None


def keepalive_set(sock):
    if sock is None:
        return "no-pooled-socket"
    return bool(sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE))


def put_token(name):
    open(os.path.join(ctl_dir, name), "w").close()


def remove_token(name):
    os.remove(os.path.join(ctl_dir, name))


# s1: six state POSTs in a row -- one connection, opened by the first and reused by the rest
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    events, answers = [], []
    for seq in range(101, 107):
        answer, evs, _secs = post(client, "state", seq)
        answers.append(answer)
        events += evs
    print("RESULT s1_answers %s" % csv(answers))
    print("RESULT s1_connects %d" % len(connects(events)))
    print("RESULT s1_reused %s" % csv(e.get("reused") for e in posts(events)))
    print("RESULT s1_post_keys %s" % csv(sorted(posts(events)[0])) if posts(events) else "RESULT s1_post_keys none")
    print("RESULT s1_ms_ints %s" % (bool(posts(events)) and all(isinstance(e.get("ms"), int) and e["ms"] >= 0
                                                                for e in posts(events))))
    print("RESULT s1_relay_conns %d" % len({r["conn"] for r in relay_rows(set(range(101, 107)))}))
    print("RESULT s1_keepalive %s" % keepalive_set(socket_of(client, "state")))

    # s2: an ack has a connection of its own -- the state connection is untouched by it
    ack1, ev_ack1, _ = post(client, "ack", 201)
    state7, ev_state7, _ = post(client, "state", 107)
    ack2, ev_ack2, _ = post(client, "ack", 202)
    print("RESULT s2_answers %s" % csv([ack1, state7, ack2]))
    print("RESULT s2_connects %s" % csv([len(connects(ev_ack1)), len(connects(ev_state7)), len(connects(ev_ack2))]))
    print("RESULT s2_reused %s" % csv(e.get("reused") for e in posts(ev_ack1 + ev_state7 + ev_ack2)))
    ack_conns = {r["conn"] for r in relay_rows({201, 202})}
    state_conns = {r["conn"] for r in relay_rows({107})} | {r["conn"] for r in relay_rows(set(range(101, 107)))}
    print("RESULT s2_relay_ack_conns %d" % len(ack_conns))
    print("RESULT s2_relay_state_conns %d" % len(state_conns))
    print("RESULT s2_relay_disjoint %s" % (not (ack_conns & state_conns)))
    print("RESULT s2_keepalive %s" % keepalive_set(socket_of(client, "ack")))

# s3: the connection died while idle (the relay closes it as it reads the next request) -- the
# SAME sealed envelope goes out once more, at once, on a fresh connection
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 301)
    put_token("fail-state-posts=1")
    answer, evs, _secs = post(client, "state", 302)
    rows = relay_rows({302})
    dropped, delivered = relay_bodies("frames-dropped.ndjson", 302), relay_bodies("frames.ndjson", 302)
    print("RESULT s3_answer %s" % answer)
    print("RESULT s3_relay_results %s" % csv(r["result"] for r in rows))
    print("RESULT s3_relay_conns %d" % len({r["conn"] for r in rows}))
    print("RESULT s3_same_envelope %s" % (len(dropped) == 1 and len(delivered) == 1 and dropped[0] == delivered[0]))
    print("RESULT s3_connects %d" % len(connects(evs)))
    print("RESULT s3_reused %s" % csv(e.get("reused") for e in posts(evs)))
    print("RESULT s3_errors %d" % sum(1 for e in evs if e.get("event") == "error"))

# s4: a failure on a connection opened for THAT POST is not retried here -- nothing about a
# fresh connection is stale, and the caller (ack retry, the state loop) owns the next try
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    put_token("fail-state-posts=1")
    answer, evs, _secs = post(client, "state", 401)
    print("RESULT s4_answer %s" % answer)
    print("RESULT s4_relay_posts %d" % len(relay_rows({401})))
    print("RESULT s4_error_events %d" % sum(1 for e in evs if e.get("event") == "error" and "post failed" in e.get("detail", "")))

# s5: a POST that times out drops its connection -- the late answer must never be read as the
# answer to the NEXT frame -- and is not retried (it already spent the whole budget)
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 501)
    put_token("delay-state-posts=2")
    answer, _evs, secs = post(client, "state", 502, timeout=0.5)
    remove_token("delay-state-posts=2")
    answer2, evs2, _secs2 = post(client, "state", 503)
    print("RESULT s5_timeout_answer %s" % answer)
    print("RESULT s5_timeout_ms %d" % round(secs * 1000))
    print("RESULT s5_next_answer %s" % answer2)
    print("RESULT s5_next_reused %s" % csv(e.get("reused") for e in posts(evs2)))
    print("RESULT s5_next_connects %d" % len(connects(evs2)))

# s6: anything that interrupts a POST half way -- not only a network error -- must not leave a
# half-used connection behind to be reused: the next POST opens a fresh one
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 601)
    real_request = mod.http.client.HTTPConnection.request

    def interrupted_request(self, *args, **kwargs):
        raise RuntimeError("simulated non-network fault mid-request")

    mod.http.client.HTTPConnection.request = interrupted_request
    try:
        try:
            post(client, "state", 602)
            raised = "nothing"
        except RuntimeError as e:
            raised = type(e).__name__
    finally:
        mod.http.client.HTTPConnection.request = real_request
    pooled = getattr(client, "_frame_channels", {}).get("state")
    pool_emptied = pooled is not None and pooled.conn is None
    answer, evs, _secs = post(client, "state", 603)
    print("RESULT s6_raised %s" % raised)
    print("RESULT s6_pool_emptied %s" % pool_emptied)
    print("RESULT s6_next_answer %s" % answer)
    print("RESULT s6_next_reused %s" % csv(e.get("reused") for e in posts(evs)))
    print("RESULT s6_next_connects %d" % len(connects(evs)))

# s7: a reused connection that fails AFTER the POST's whole budget is spent is not retried -- the
# retry would have nothing left to run in, and would hide the real error behind its own timeout
with tempfile.TemporaryDirectory() as repo:
    client = new_client(repo)
    post(client, "state", 701)
    real_getresponse, real_connect = mod.http.client.HTTPConnection.getresponse, mod._connect
    opened = []

    def late_reset(self, *args, **kwargs):
        time.sleep(0.4)  # past the 0.3 s budget below
        raise ConnectionResetError("simulated reset after the budget is gone")

    def counting_connect(*args, **kwargs):
        opened.append(1)
        return real_connect(*args, **kwargs)

    mod.http.client.HTTPConnection.getresponse = late_reset
    mod._connect = counting_connect
    try:
        answer, evs, secs = post(client, "state", 702, timeout=0.3)
    finally:
        mod.http.client.HTTPConnection.getresponse = real_getresponse
        mod._connect = real_connect
    print("RESULT s7_answer %s" % answer)
    print("RESULT s7_new_connections %d" % len(opened))
    print("RESULT s7_error_events %d" % sum(1 for e in evs if e.get("event") == "error" and "simulated reset" in e.get("detail", "")))
sys.exit(0)
PYEOF
FRAMES_RC_S=$?

if [ "$FRAMES_RC_S" -eq 0 ]; then
  ok "scenario S: frame-connection harness ran to completion"
else
  bad "scenario S: frame-connection harness exited $FRAMES_RC_S -- $(tail -3 "$TMPROOT/s.frames.err")"
fi

check_res "$FRAMES_OUT_S" s1_answers "True,True,True,True,True,True" "S/s1: six state POSTs, six delivered answers"
check_res "$FRAMES_OUT_S" s1_connects 1 "S/s1: six state POSTs opened exactly ONE connection (connect events)"
check_res "$FRAMES_OUT_S" s1_reused "False,True,True,True,True,True" "S/s1: ...the first POST opened it, the other five reused it (post events)"
check_res "$FRAMES_OUT_S" s1_post_keys "event,ms,reused" "S/s1: a post event carries exactly event, ms and reused"
check_res "$FRAMES_OUT_S" s1_ms_ints True "S/s1: ...ms is a non-negative integer"
check_res "$FRAMES_OUT_S" s1_relay_conns 1 "S/s1: the relay itself counted ONE connection for the six frames"
check_res "$FRAMES_OUT_S" s1_keepalive True "S/s1: the pooled socket has TCP keepalive on (an idle NAT mapping does not silently kill it)"

check_res "$FRAMES_OUT_S" s2_answers "True,True,True" "S/s2: an ack, a state frame and an ack, all delivered"
check_res "$FRAMES_OUT_S" s2_connects "1,0,0" "S/s2: the first ack opened a connection of its own; the next state frame and ack opened none"
check_res "$FRAMES_OUT_S" s2_reused "False,True,True" "S/s2: ...the state frame reused the state connection, the second ack the ack connection"
check_res "$FRAMES_OUT_S" s2_relay_ack_conns 1 "S/s2: the relay saw every ack on ONE connection"
check_res "$FRAMES_OUT_S" s2_relay_state_conns 1 "S/s2: ...and every state frame on ONE connection"
check_res "$FRAMES_OUT_S" s2_relay_disjoint True "S/s2: ...never the same one (a slow state POST cannot hold up an ack)"
check_res "$FRAMES_OUT_S" s2_keepalive True "S/s2: the ack connection has TCP keepalive on too"

check_res "$FRAMES_OUT_S" s3_answer True "S/s3: a reused connection that dies mid-request still ends in a delivered answer"
check_res "$FRAMES_OUT_S" s3_relay_results "dropped,ok" "S/s3: the relay saw the POST twice: dropped, then answered"
check_res "$FRAMES_OUT_S" s3_relay_conns 2 "S/s3: ...on two different connections"
check_res "$FRAMES_OUT_S" s3_same_envelope True "S/s3: ...the very same sealed envelope both times (same seq, nonce, ciphertext)"
check_res "$FRAMES_OUT_S" s3_connects 1 "S/s3: exactly one reconnect"
check_res "$FRAMES_OUT_S" s3_reused False "S/s3: the answered exchange is reported as not reused"
check_res "$FRAMES_OUT_S" s3_errors 0 "S/s3: a stale connection that was transparently replaced is not an error"

check_res "$FRAMES_OUT_S" s4_answer None "S/s4: a failure on a brand-new connection is reported to the caller as no usable answer"
check_res "$FRAMES_OUT_S" s4_relay_posts 1 "S/s4: ...after exactly one POST (no blind retry)"
check_res "$FRAMES_OUT_S" s4_error_events 1 "S/s4: ...and one loud error event"

check_res "$FRAMES_OUT_S" s5_timeout_answer None "S/s5: a timed-out POST is reported as no usable answer"
check_res_between "$FRAMES_OUT_S" s5_timeout_ms 400 1500 "S/s5: ...after its own 0.5 s budget, not retried into a second wait (ms)"
check_res "$FRAMES_OUT_S" s5_next_answer True "S/s5: the next POST is answered normally (the late answer was never read as its own)"
check_res "$FRAMES_OUT_S" s5_next_reused False "S/s5: ...on a fresh connection: the timed-out one was dropped, not reused"
check_res "$FRAMES_OUT_S" s5_next_connects 1 "S/s5: ...one connect event"

check_res "$FRAMES_OUT_S" s6_raised RuntimeError "S/s6: a non-network fault mid-POST propagates (it is not mistaken for a stale connection)"
check_res "$FRAMES_OUT_S" s6_pool_emptied True "S/s6: ...and the interrupted connection is dropped from the pool"
check_res "$FRAMES_OUT_S" s6_next_answer True "S/s6: the next POST is answered normally"
check_res "$FRAMES_OUT_S" s6_next_reused False "S/s6: ...on a fresh connection, not the half-used one"
check_res "$FRAMES_OUT_S" s6_next_connects 1 "S/s6: ...one connect event"

check_res "$FRAMES_OUT_S" s7_answer None "S/s7: a reused connection that fails once the budget is gone is reported as no usable answer"
check_res "$FRAMES_OUT_S" s7_new_connections 0 "S/s7: ...with no retry attempted (a retry has nothing left to run in)"
check_res "$FRAMES_OUT_S" s7_error_events 1 "S/s7: ...and the error event names the real failure, not a retry's timeout"
if [ ! -s "$TMPROOT/s.frames.err" ]; then
  ok "S: the harness wrote nothing to stderr"
else
  bad "S: the harness wrote to stderr: $(head -5 "$TMPROOT/s.frames.err")"
fi

kill "$SRV_S" 2>/dev/null
wait "$SRV_S" 2>/dev/null

# ── Scenario T: a failed state POST is re-sent. The relay receives the very first
# state POST in full and never answers it (fail-state-posts=1). Nothing in the repo
# changes afterwards, so the ONLY thing that can put that state on the wire again is
# the client treating the failure as "not sent". The pre-fix client recorded the
# digest BEFORE posting: the frame was simply gone, until the next state change ─
if [ "$E2E_PRESENT" = true ]; then
  REPO_T="$(make_repo)"
  PORT_T_RELAY="$(free_port)"
  PORT_T_UI="$(free_port)"
  LOG_T="$TMPROOT/t.log"; CTL_T="$TMPROOT/t.ctl"
  mkdir -p "$LOG_T" "$CTL_T"
  : > "$CTL_T/fail-state-posts=1"

  python3 "$FAKE_RELAY" serve "$PORT_T_RELAY" --log "$LOG_T" --ctl "$CTL_T" >"$TMPROOT/t.srv.out" 2>&1 &
  SRV_T=$!
  PIDS+=("$SRV_T")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_T_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  CLIENT_T_OUT="$TMPROOT/t.client.out"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_T_RELAY" --repo "$REPO_T" --ui-port "$PORT_T_UI" \
    >"$CLIENT_T_OUT" 2>"$TMPROOT/t.client.err" &
  CLIENT_T=$!
  PIDS+=("$CLIENT_T")

  if wait_for_count "$LOG_T/frames-dropped.ndjson" 1 '"type":"state"' 15; then
    ok "scenario T: the relay received the first state POST and dropped it unanswered"
  else
    bad "scenario T: the relay never saw a state POST to drop"
  fi
  if wait_for_count "$LOG_T/frames.ndjson" 1 '"type":"state"' 15; then
    ok "scenario T: the state whose POST failed was re-sent, with no state change in between"
  else
    bad "scenario T: the state whose POST failed was never re-sent (its digest was recorded before the POST)"
  fi
  [ -e "$LOG_T/frames.ndjson" ] && { wait_for_quiescent_count "$LOG_T/frames.ndjson" 4 14 || true; }
  T_DROPPED="$(count_matching "$LOG_T/frames-dropped.ndjson" '"type":"state"')"
  T_DELIVERED="$(count_matching "$LOG_T/frames.ndjson" '"type":"state"')"
  if [ "$T_DROPPED" -eq 1 ] && [ "$T_DELIVERED" -eq 1 ]; then
    ok "scenario T: exactly one dropped and one delivered state frame (a retry, not a resend loop; INV-22 intact)"
  else
    bad "scenario T: want 1 dropped + 1 delivered state frame, got $T_DROPPED dropped + $T_DELIVERED delivered"
  fi
  if wait_for_event "$CLIENT_T_OUT" "error" "post failed" 2; then
    ok "scenario T: the failed POST was reported (error event naming it), not swallowed"
  else
    bad "scenario T: the failed state POST left no error event"
  fi
  T_GAP_MS="$(python3 - "$LOG_T/frame-posts.log" <<'PYEOF'
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        rows.append(dict(part.split("=", 1) for part in line.split()))
dropped = [r for r in rows if r["type"] == "state" and r["result"] == "dropped"]
sent = [r for r in rows if r["type"] == "state" and r["result"] == "ok"]
if dropped and sent:
    print(int((float(sent[0]["done"]) - float(dropped[0]["recv"])) * 1000))
PYEOF
)"
  if [ -n "$T_GAP_MS" ] && [ "$T_GAP_MS" -lt 8000 ]; then
    ok "scenario T: the re-send reached the relay ${T_GAP_MS} ms after the dropped POST (< 8000 ms: next tick plus a bounded backoff)"
  else
    bad "scenario T: re-send gap was '$T_GAP_MS' ms, want < 8000"
  fi
  if [ ! -s "$TMPROOT/t.client.err" ]; then
    ok "scenario T: the client wrote nothing to stderr"
  else
    bad "scenario T: the client wrote to stderr: $(head -5 "$TMPROOT/t.client.err")"
  fi

  kill "$CLIENT_T" 2>/dev/null
  wait "$CLIENT_T" 2>/dev/null
  kill "$SRV_T" 2>/dev/null
  wait "$SRV_T" 2>/dev/null
else
  skip "scenario T (failed state POST is re-sent): bin/lib/hmd_relay_e2e.py absent"
fi

# ── Scenario U: the REAL client, a state POST held 3 s at the relay (delay-state-
# posts) while the phone's command arrives. The ack must land at once (it has a
# connection and a lock of its own), the state frame it overtook must be re-sent
# (the phone drops a frame whose seq a newer one has passed), every state POST
# rides one connection and every ack another, and an ack answered delivered=false
# is retried. The no-op command writes nothing to the inbox, so no state change
# can explain a later state frame ─────────────────────────────────────────────
prepare_device_action() {
  # prepare_device_action OUT_FILE SESSION_ID KEY_B64 SEQ JSON -- seals JSON (a whole command
  # object) as the paired device into a complete relay envelope at OUT_FILE WITHOUT queueing it:
  # the relay's stream only pushes what appears in the ctl dir, so a test can `mv` the file there
  # the instant it wants the command to arrive (sealing takes the better part of a second, which
  # is a large slice of a 3 s window)
  local out="$1" sid="$2" key="$3" seq="$4" json_text="$5" seal nonce ct
  seal="$(python3 "$FAKE_RELAY" device seal --key-b64 "$key" --seq "$seq" --sender device --text "$json_text")"
  nonce="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce_b64"])')"
  ct="$(printf '%s' "$seal" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ciphertext_b64"])')"
  python3 "$FAKE_RELAY" device envelope --session-id "$sid" --seq "$seq" --sender device \
    --type command --nonce "$nonce" --ciphertext "$ct" > "$out"
}

if [ "$E2E_PRESENT" = true ]; then
  REPO_U="$(make_repo)"
  PORT_U_RELAY="$(free_port)"
  PORT_U_UI="$(free_port)"
  LOG_U="$TMPROOT/u.log"; CTL_U="$TMPROOT/u.ctl"
  mkdir -p "$LOG_U" "$CTL_U"

  python3 "$FAKE_RELAY" serve "$PORT_U_RELAY" --log "$LOG_U" --ctl "$CTL_U" >"$TMPROOT/u.srv.out" 2>&1 &
  SRV_U=$!
  PIDS+=("$SRV_U")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_U_RELAY))==0 else 1)" && break
    sleep 0.1
  done

  DEVU_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEVU_PRIV_B64="$(printf '%s' "$DEVU_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv_b64"])')"
  DEVU_PUB_B64="$(printf '%s' "$DEVU_KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub_b64"])')"
  printf '%s' "$DEVU_PUB_B64" > "$CTL_U/bind-device"

  CLIENT_U_OUT="$TMPROOT/u.client.out"
  EVENT_LOG_U="$REPO_U/.heimdall/app/relay-events.jsonl"
  "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$PORT_U_RELAY" --repo "$REPO_U" --ui-port "$PORT_U_UI" \
    >"$CLIENT_U_OUT" 2>"$TMPROOT/u.client.err" &
  CLIENT_U=$!
  PIDS+=("$CLIENT_U")

  wait_for "$CLIENT_U_OUT" '"event":"pair_init"' 10 || true
  SID_U="$(python3 -c "
import json
for line in open('$CLIENT_U_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['session_id']); break
" 2>/dev/null)"
  HMD_PUB_U="$(python3 -c "
import json
for line in open('$CLIENT_U_OUT'):
    o = json.loads(line)
    if o.get('event') == 'pair_init':
        print(o['qr']['hmd_pubkey']); break
" 2>/dev/null)"
  if wait_for "$CLIENT_U_OUT" '"event":"device_bound"' 10 && [ -n "$SID_U" ] && [ -n "$HMD_PUB_U" ]; then
    ok "scenario U: relay-client paired (session key derivable)"
  else
    bad "scenario U: relay-client never paired -- the rest of U cannot run: $(tail -3 "$TMPROOT/u.client.err" 2>/dev/null)"
  fi
  SESSION_KEY_U="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEVU_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_U" --session-id "$SID_U" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_b64"])')"

  # a no-op action writes nothing to the inbox, so no state change can explain a later state frame;
  # both commands are sealed now and moved into the ctl dir only when each is wanted
  prepare_device_action "$TMPROOT/u.cmd1.json" "$SID_U" "$SESSION_KEY_U" 1 '{"action":"noop","params":{}}'
  prepare_device_action "$TMPROOT/u.cmd2.json" "$SID_U" "$SESSION_KEY_U" 2 '{"action":"noop","params":{}}'

  # the first state frame, so both directions of the exchange start from a warm state connection
  if wait_for_count "$LOG_U/frames.ndjson" 1 '"type":"state"' 10; then
    ok "scenario U: first state frame delivered"
  else
    bad "scenario U: no first state frame"
  fi

  # a state change whose POST the relay then holds 3 s
  : > "$CTL_U/delay-state-posts=3"
  ( cd "$REPO_U" && HEIMDALL_WATCH_ROOT="$REPO_U" "$UI" panel set slow-state --type number \
      --title "slow state probe" --data-json - <<<'{"value":1}' ) >/dev/null 2>&1
  for _ in $(seq 1 120); do
    [ -e "$LOG_U/state-inflight" ] && break
    sleep 0.1
  done
  if [ -e "$LOG_U/state-inflight" ]; then
    ok "scenario U: a state POST is in flight at the relay, held 3 s"
  else
    bad "scenario U: the changed state was never POSTed -- U cannot show an ack passing it"
  fi

  # the command goes in while that POST is still held
  mv "$TMPROOT/u.cmd1.json" "$CTL_U/001.json"
  ACK_U1_JSON="$(wait_for_ack_of_seq "$LOG_U/frames.ndjson" "$SESSION_KEY_U" 1 10)"
  rm -f "$CTL_U/delay-state-posts=3"
  if [ -n "$ACK_U1_JSON" ]; then
    ok "scenario U: the ack for seq=1 reached the relay"
  else
    bad "scenario U: no ack for seq=1 ever reached the relay"
  fi

  # the state frame the ack overtook is re-sent (a frame with a seq above the ack's)
  U_RESEND="$(python3 - "$LOG_U/frames.ndjson" 20 <<'PYEOF'
import json
import sys
import time

path, secs = sys.argv[1], float(sys.argv[2])
deadline = time.time() + secs
while True:
    ack_seq, state_seqs = None, []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("type") == "ack" and ack_seq is None:
            ack_seq = env["seq"]
        if env.get("type") == "state":
            state_seqs.append(env["seq"])
    if ack_seq is not None and any(s > ack_seq for s in state_seqs):
        print("yes")
        sys.exit(0)
    if time.time() >= deadline:
        print("no")
        sys.exit(0)
    time.sleep(0.1)
PYEOF
)"
  if [ "$U_RESEND" = "yes" ]; then
    ok "scenario U: the state frame the ack overtook was re-sent under a seq above the ack's"
  else
    bad "scenario U: no state frame with a seq above the ack's ever followed -- the phone would keep the older state it dropped"
  fi

  # the delivered=false ack: the relay says no phone is attached for the next two tries
  : > "$CTL_U/undelivered-ack-posts=2"
  mv "$TMPROOT/u.cmd2.json" "$CTL_U/002.json"
  wait_for_count "$EVENT_LOG_U" 3 '"event":"ack_sent".*"of_seq":2,' 15 || true
  ACK_U2_JSON="$(wait_for_ack_of_seq "$LOG_U/frames.ndjson" "$SESSION_KEY_U" 2 5)"
  if [ -n "$ACK_U2_JSON" ]; then
    ok "scenario U: the ack for seq=2 reached the phone after two delivered=false answers"
  else
    bad "scenario U: the ack for seq=2 never reached the phone -- a delivered=false answer was not retried"
  fi

  U_CHECK="$TMPROOT/u.check.out"
  python3 - "$EVENT_LOG_U" "$LOG_U/frame-posts.log" "$LOG_U/frames.ndjson" "$LOG_U/frames-undelivered.ndjson" \
    >"$U_CHECK" 2>"$TMPROOT/u.check.err" <<'PYEOF'
import calendar
import json
import sys
import time

events_path, posts_path, frames_path, undelivered_path = sys.argv[1:5]


def lines_of(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def csv(values):
    return ",".join(str(v) for v in values)


def ts(event):
    t = event["ts"]
    return calendar.timegm(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S")) + int(t[20:23]) / 1000.0


events = []
for line in lines_of(events_path):
    try:
        events.append(json.loads(line))
    except ValueError:
        continue  # the client is still running -- a half-written last line

rows = []
for line in lines_of(posts_path):
    kv = dict(part.split("=", 1) for part in line.split())
    kv["recv"], kv["done"] = float(kv["recv"]), float(kv["done"])
    kv["seq"] = int(kv["seq"]) if kv["seq"].isdigit() else None
    rows.append(kv)

# u1: the command is acked while the state POST is still held at the relay
cmd1 = next((e for e in events if e.get("event") == "command"), None)
ack1 = next((e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == 1), None)
print("RESULT u1_ack_ms %d" % (round((ts(ack1) - ts(cmd1)) * 1000) if cmd1 and ack1 else -1))
ack_row = next((r for r in rows if ack1 and r["type"] == "ack" and r["seq"] == ack1["seq"] and r["result"] == "ok"), None)
held = [r for r in rows if ack_row and r["type"] == "state" and r["recv"] < ack_row["done"] < r["done"]
        and r["done"] - r["recv"] >= 2.5]
print("RESULT u1_state_in_flight %s" % bool(held))
overtaken = [r for r in rows if ack1 and ack_row and r["type"] == "state" and r["result"] == "ok"
             and r["seq"] < ack1["seq"] and r["done"] > ack_row["done"]]
print("RESULT u1_state_overtaken %s" % bool(overtaken))

# u2: connections, counted by the relay and by the client's own events
state_conns = {r["conn"] for r in rows if r["type"] == "state"}
ack_conns = {r["conn"] for r in rows if r["type"] == "ack"}
print("RESULT u2_state_conns %d" % len(state_conns))
print("RESULT u2_ack_conns %d" % len(ack_conns))
print("RESULT u2_disjoint %s" % (not (state_conns & ack_conns)))
print("RESULT u2_frames_connects %d" % sum(1 for e in events if e.get("event") == "connect" and e.get("for") == "frames"))
print("RESULT u2_unreused_posts %d" % sum(1 for e in events if e.get("event") == "post" and e.get("reused") is False))

# u3: delivered=false is retried
a2 = [e for e in events if e.get("event") == "ack_sent" and e.get("of_seq") == 2]
print("RESULT u3_attempts %s" % csv(e["attempt"] for e in a2))
print("RESULT u3_ok %s" % csv(e["ok"] for e in a2))
print("RESULT u3_delivered %s" % csv(e["delivered"] for e in a2))
print("RESULT u3_one_seq %s" % (bool(a2) and len({e["seq"] for e in a2}) == 1))
seq2 = a2[0]["seq"] if a2 else None
undelivered = [l for l in lines_of(undelivered_path) if json.loads(l).get("seq") == seq2]
delivered = [l for l in lines_of(frames_path) if json.loads(l).get("type") == "ack" and json.loads(l).get("seq") == seq2]
print("RESULT u3_undelivered_frames %d" % len(undelivered))
print("RESULT u3_delivered_frames %d" % len(delivered))
print("RESULT u3_identical %s" % (bool(delivered) and bool(undelivered) and all(l == delivered[0] for l in undelivered)))
PYEOF

  check_res_between "$U_CHECK" u1_ack_ms 0 500 "scenario U: the ack landed within 500 ms of its command while a state POST was held 3 s (ms)"
  check_res "$U_CHECK" u1_state_in_flight True "scenario U: ...and the relay's own log shows that state POST still in flight when the ack landed"
  check_res "$U_CHECK" u1_state_overtaken True "scenario U: ...so the ack really did pass the older state frame (the phone will drop the state as a replay)"
  check_res "$U_CHECK" u2_state_conns 1 "scenario U: every state POST of the session rode ONE connection (the relay's count)"
  check_res "$U_CHECK" u2_ack_conns 1 "scenario U: every ack POST rode ONE connection"
  check_res "$U_CHECK" u2_disjoint True "scenario U: ...never the same one"
  check_res "$U_CHECK" u2_frames_connects 2 "scenario U: exactly two connect events for frames (one per sender) across the whole session"
  check_res "$U_CHECK" u2_unreused_posts 2 "scenario U: only those two POSTs opened a connection; every other post event is reused=true"
  check_res "$U_CHECK" u3_attempts "1,2,3" "scenario U: two delivered=false answers then delivered -> ack_sent attempts 1,2,3"
  check_res "$U_CHECK" u3_ok "True,True,True" "scenario U: ...every attempt got an answer (ok=true)"
  check_res "$U_CHECK" u3_delivered "False,False,True" "scenario U: ...delivered=false,false,true"
  check_res "$U_CHECK" u3_one_seq True "scenario U: ...all three attempts carry the same ack seq"
  check_res "$U_CHECK" u3_undelivered_frames 2 "scenario U: the relay received the two undelivered copies"
  check_res "$U_CHECK" u3_delivered_frames 1 "scenario U: ...and ONE delivered ack"
  check_res "$U_CHECK" u3_identical True "scenario U: ...all byte-identical (never a re-seal)"
  if [ ! -s "$TMPROOT/u.client.err" ]; then
    ok "scenario U: the client wrote nothing to stderr"
  else
    bad "scenario U: the client wrote to stderr: $(head -5 "$TMPROOT/u.client.err")"
  fi

  kill "$CLIENT_U" 2>/dev/null
  wait "$CLIENT_U" 2>/dev/null
  kill "$SRV_U" 2>/dev/null
  wait "$SRV_U" 2>/dev/null
else
  skip "scenario U (ack priority, persistent connections, delivered=false retry): bin/lib/hmd_relay_e2e.py absent"
fi

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
  port_relay="$(free_port)"; port_ui="$(free_port)"
  python3 "$FAKE_RELAY" serve "$port_relay" --log "$XS_LOG" --ctl "$XS_CTL" >"$TMPROOT/$tag.srv.out" 2>&1 &
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
  "$@" "$RELAY_CLIENT_RUN" --relay "http://127.0.0.1:$port_relay" --repo "$repo" --ui-port "$port_ui" >"$XS_OUT" 2>"$XS_ERR" &
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
    if x_json_same "$X_CAPS" '["login-v1","push-v1","resync","z-zlib"]'; then
      ok "X: the state frame the relay received lists push-v1 beside login-v1, resync and z-zlib in its caps"
    else
      bad "X: state frame caps are not [login-v1, push-v1, resync, z-zlib]: $X_CAPS"
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
    if x_json_same "$X_CAPS" '["login-v1","resync","z-zlib"]'; then
      ok "X2: with HMD_PUSH=0 the state frame no longer lists push-v1 (login-v1 is untouched)"
    else
      bad "X2: state frame caps with HMD_PUSH=0 are not [login-v1, resync, z-zlib]: $X_CAPS"
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

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
