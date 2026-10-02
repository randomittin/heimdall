#!/usr/bin/env bash
# test/relay-contract-fixtures.test.sh -- hmd's side of the shared relay wire contract.
#
# relay/contract/wire.json (+ vectors.json) describes the wire the relay, the phone app and
# bin/heimdall-relay-client all speak. The relay's own suites replay it against the real Worker
# (relay/test/contract.spec.ts) and the JS crypto (relay/scripts/__tests__/contract-fixtures.test.mjs).
# This suite replays it against the REAL bin/heimdall-relay-client and bin/lib/hmd_relay_e2e.py,
# hermetically: test/lib/relay_contract_replay.py opens no socket, it swaps the client's one network
# seam (_connect) for in-memory keep-alive connections that record every request and answer from the
# fixture, and compares every byte the client sends. It counts requests, not connections: the
# client's POST /frames connections are persistent, so one carries several frames.
#
# Falsifiable by construction: the replay is also run against tampered copies of the fixture and
# must go red on each, so a replay that can no longer fail is itself a failing suite.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$REPO/test/lib/relay_contract_replay.py"
WIRE="$REPO/relay/contract/wire.json"
VECTORS="$REPO/relay/contract/vectors.json"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "relay-contract-fixtures (relay/contract/wire.json vs bin/heimdall-relay-client, no network)"

for f in "$REPLAY" "$WIRE" "$VECTORS" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_relay_e2e.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: python3 missing\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ── 1. the fixtures are well-formed JSON ──────────────────────────────────────
for f in "$WIRE" "$VECTORS"; do
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
    ok "$(basename "$f") parses as JSON"
  else
    bad "$(basename "$f") does not parse as JSON"
  fi
done

# ── 2. the real client agrees with the fixture, byte for byte ─────────────────
OUT="$TMPROOT/replay.out"
python3 "$REPLAY" >"$OUT" 2>&1
rc=$?
tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$OUT" | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
  ok "replay against the real client: $tally"
else
  bad "replay against the real client failed (exit $rc, tally '${tally:-none}')"
  grep -E 'FAIL|Traceback|Error' -A2 "$OUT" | head -30
fi

# ── 3. the replay is not vacuous: tampered fixtures must turn it red ──────────
# mutate NAME PYTHON-STATEMENT -- writes $TMPROOT/NAME.json from wire.json after running the
# statement on the parsed fixture `w`, then replays it. Red (non-zero exit, a FAIL line) is the pass.
mutant() {
  local name="$1" stmt="$2" path="$TMPROOT/$1.json" out="$TMPROOT/$1.out"
  python3 - "$WIRE" "$path" "$stmt" <<'PY'
import json, sys
src, dst, stmt = sys.argv[1:4]
w = json.load(open(src))
exec(stmt)
json.dump(w, open(dst, "w"), indent=2)
PY
  if [ $? -ne 0 ]; then bad "mutant $name could not be built"; return; fi
  HMD_RELAY_CONTRACT_WIRE="$path" python3 "$REPLAY" >"$out" 2>&1
  local mrc=$?
  if [ "$mrc" -ne 0 ] && grep -q '  FAIL ' "$out"; then
    ok "tampered fixture turns the replay red: $name ($(grep -c '  FAIL ' "$out") checks failed)"
  else
    bad "tampered fixture NOT caught: $name (exit $mrc)"
  fi
}

mutant ciphertext-bit-flip \
  "c = w['frames']['state']['wire']['ciphertext']; w['frames']['state']['wire']['ciphertext'] = ('B' if c[0] != 'B' else 'C') + c[1:]"
mutant ack-seq-skew \
  "w['frames']['ack_send_message']['wire']['seq'] = 9"
mutant wrong-pair-path \
  "w['pair_init']['request']['path'] = '/pair/start'"
mutant frames-content-type \
  "w['frames_post']['request']['headers']['Content-Type'] = 'text/plain'"
mutant qr-wrong-key \
  "w['bindings']['hmd_pubkey'] = {'computed': 'device_pubkey_b64url'}"
mutant decide-ack-flipped \
  "w['frames']['ack_decide_allow']['plaintext']['ok'] = True"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
