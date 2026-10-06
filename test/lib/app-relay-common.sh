# test/lib/app-relay-common.sh -- shared prelude of the heimdall-app-relay* suites.
#
# SOURCED, never executed (run-all.sh globs test/*.test.sh only, so this file is not a suite). It carries
# everything the original single suite built before its first scenario: the sandbox (a throwaway HOME +
# TMPROOT, trap-based cleanup), the ok/bad/skip tally, every poll-based wait helper, the e2e-module stand-in
# ($RELAY_CLIENT_RUN) and the RESULT-line helpers. A suite sets RELAY_SUITE_TITLE, sources this file, runs
# its scenarios and ends with `suite_summary`; the three suites are exactly the old suite's scenarios cut
# at section boundaries (test/heimdall-app-relay.test.sh documents which).
#
# python3 is PINNED to the real interpreter for the whole suite (see "python3 pin" below): on a box where
# python3 is a pyenv shim every `python3` call paid a bash+pyenv version-resolution tax of 0.3-0.8 s under
# load, and this suite makes thousands of them (every JSON field extraction, every sealed command, every poll
# iteration of the refusal/ack waits, every fake relay and client start). That tax, not the protocol's own
# timers, was most of the wall clock.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

echo "$RELAY_SUITE_TITLE"

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

# ── python3 pin ──────────────────────────────────────────────────────────
# Resolve the interpreter ONCE and put a one-line exec wrapper first on PATH. A wrapper, not a symlink: a
# symlink would hide a venv's pyvenv.cfg (the interpreter finds it next to the path it was started by), and
# a PATH entry for the interpreter's own bin dir would also expose every other tool installed beside it. The
# wrapper execs the SAME interpreter python3 already resolved to, so nothing the suite imports changes; it
# is only installed when python3 resolves through something else (a pyenv shim, the macOS xcrun stub).
_REAL_PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ -n "$_REAL_PY" ] && [ -x "$_REAL_PY" ] && [ "$_REAL_PY" != "$(command -v python3)" ]; then
  mkdir -p "$TMPROOT/pybin"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$_REAL_PY" > "$TMPROOT/pybin/python3"
  chmod +x "$TMPROOT/pybin/python3"
  export PATH="$TMPROOT/pybin:$PATH"
fi


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

# suite_summary -- the tally line run-all.sh parses ("N passed, M failed") and the suite's exit status
suite_summary() {
  echo
  printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
}
