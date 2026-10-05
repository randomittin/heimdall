#!/usr/bin/env bash
# test/companion-view.test.sh -- the phone's Files list opens a diff: hmd answers `view-v1`.
#
# The phone half is hmdapp's src/views (docs/HANDOFF-TO-HEIMDALL-cursor-parity.md CP5). The wire under test, through the REAL
# bin/heimdall-relay-client against test/lib/fake-relay.py (a hermetic stand-in for the relay; test/lib/view_phone.py plays
# the paired phone and seals with the real bin/lib/hmd_relay_e2e.py -- nothing about the client is mocked, and no case imports
# the client or bin/lib/companion_view.py):
#     cap      view-v1 in every state frame's caps
#     command  {"action":"view","params":{"rid","kind":"diff","scope","path","ctx","max_bytes"}}
#     ack      {"ok":true,"of_seq":N,"id":rid} | {"ok":false,"of_seq":N,"detail":<code>[,"retry_after_s":N]}
#     answer   state.views = {"v":1,"enabled","kinds":["diff"],"result":{id,kind,at,truncated,bytes,files[],hunks[]}}
#
# What it proves (the cases live in test/lib/view_scenarios.py, one group per concern):
#   wire     the cap, the slice's shape, no slice for a phone that has not listed the cap, caps-missing, the result forgotten
#   diff     files[] and the hunk text equal what git itself prints for the same tree (computed here by running git again);
#            worktree / staged / head, ctx, a rename, a deletion, a binary file, an untracked file shown whole, not-found
#   paths    traversal and absolute paths, the deny list, every kind of symlink, a named pipe: refused, nothing leaks
#   secrets  a token, an assigned credential and a PEM key masked line by line, hunk-header context, secret-shaped names,
#            the relay's redaction profile on the result, the 2000-character line cut
#   params   the exact key set, every wrong type and range, and the contract's other three kinds (not-implemented)
#   size     max_bytes at a hunk boundary, a first hunk kept in part, the slice budget, the 1 MiB envelope, zlib, the 2000-file cap
#   latch    a forged or replayed command is never run; a new binding forgets the phone's caps and the held result
#   kill     .heimdall/app/controls-disabled and HMD_UI_CONTROLS=0 -> controls-off, enabled:false
#   rate     --repo below the git toplevel; the 21st request in a minute is rate-limited
# and, falsifiably, that each rule is the thing holding: a copy of the client with one rule removed must turn its group red.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are temp dirs, every process this suite starts is reaped on exit, every wait is bounded.
# It signals no process it did not start (a running relay client of the operator's is never touched).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$REPO/bin/heimdall-relay-client"
SCEN="$REPO/test/lib/view_scenarios.py"
MODULE="$REPO/bin/lib/companion_view.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "companion-view (the phone's file diff: view-v1 through the real relay client)"

for f in "$CLIENT" "$SCEN" "$MODULE" "$REPO/test/lib/view_phone.py" "$REPO/test/lib/fake-relay.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# run_scenarios LABEL ARGS... -- run one stack of cases, print its lines, fold its tally into ours.
run_scenarios() {
  local label="$1" out="$TMPROOT/out.$RANDOM" rc tally p f
  shift
  python3 "$SCEN" "$@" >"$out" 2>&1
  rc=$?
  cat "$out"
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)"
  if [ -z "$tally" ]; then
    bad "$label: the scenario run produced no tally (exit $rc)"
    tail -20 "$out"
    return
  fi
  p="${tally%% passed*}"
  f="${tally##*, }"
  f="${f%% failed}"
  PASS=$((PASS + p))
  FAIL=$((FAIL + f))
}

# A copy of the client that differs from the real one in nothing but what a mutant changes: the client file itself is a real
# copy (it finds bin/lib beside its own real path), bin/lib is a directory of links except companion_view.py (also a copy),
# and everything else -- sentinels, the other bin scripts, the codec -- is linked to the real one.
mutant_tree() {
  local dir="$TMPROOT/mutant-$1" f name
  mkdir -p "$dir/bin/lib"
  for f in "$REPO"/bin/*; do
    name="$(basename "$f")"
    case "$name" in lib|heimdall-relay-client) ;; *) ln -s "$f" "$dir/bin/$name" ;; esac
  done
  for f in "$REPO"/bin/lib/*; do
    name="$(basename "$f")"
    [ "$name" = companion_view.py ] || ln -s "$f" "$dir/bin/lib/$name"
  done
  cp "$CLIENT" "$dir/bin/heimdall-relay-client"
  cp "$MODULE" "$dir/bin/lib/companion_view.py"
  ln -s "$REPO/sentinels" "$dir/sentinels"
  printf '%s' "$dir"
}

# mutate FILE OLD NEW -- exactly one occurrence of OLD, else the mutant would be vacuous and the suite says so.
mutate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
src = open(path, encoding="utf-8").read()
if src.count(old) != 1:
    sys.exit("mutation site found %d times, not once: %r" % (src.count(old), old))
open(path, "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
}

# mutant NAME FILE-IN-TREE OLD NEW GROUPS -- the suite's own cases for GROUPS must go red on the changed copy.
mutant() {
  local name="$1" rel="$2" old="$3" new="$4" groups="$5" dir out rc
  dir="$(mutant_tree "$name")"
  if ! mutate "$dir/$rel" "$old" "$new" 2>"$TMPROOT/mut.err"; then
    bad "mutant $name could not be built: $(cat "$TMPROOT/mut.err")"
    return
  fi
  out="$TMPROOT/mut.out.$RANDOM"
  python3 "$SCEN" main --client "$dir/bin/heimdall-relay-client" --groups "$groups" >"$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q '^  FAIL ' "$out"; then
    ok "mutant $name turns the suite red ($(grep -c '^  FAIL ' "$out") checks failed: $(grep -m1 '^  FAIL ' "$out" | cut -c8-90))"
  else
    bad "mutant $name NOT caught (exit $rc) -- the rule it removes is not what the cases test"
  fi
}

echo "-- the real client: main stack (groups wire diff paths secrets params size latch kill)"
run_scenarios main main --client "$CLIENT"
echo "-- the real client: --repo below the git toplevel, and the rate limit"
run_scenarios subdir subdir --client "$CLIENT"
echo "-- the real client: HMD_UI_CONTROLS=0"
run_scenarios killenv killenv --client "$CLIENT"

echo "-- mutants: one rule removed from a copy, the cases that guard it must fail"
mutant drop-secret-mask  bin/lib/companion_view.py $'        if P.secret_shaped(text):\n            return REDACTED' $'        if False:\n            return REDACTED' secrets
mutant accept-env        bin/lib/companion_view.py 'name.startswith(".env") or name.endswith(_DENIED_SUFFIXES)' 'name.endswith(_DENIED_SUFFIXES[1:])' paths
mutant accept-dot-git    bin/lib/companion_view.py 'if any(s in _DENIED_DIRS for s in low):' 'if False:' paths
mutant skip-symlink-check bin/lib/companion_view.py 'if os.path.realpath(candidate) != candidate:' 'if False:' paths
mutant skip-max-bytes-cut bin/lib/companion_view.py '"max_bytes": max_bytes,' '"max_bytes": 10 ** 9,' size
mutant skip-cap-check    bin/lib/companion_view.py $'        if not has_cap:\n            return False, "caps-missing", {}' $'        if False:\n            return False, "caps-missing", {}' wire
mutant skip-redaction    bin/heimdall-relay-client 'redact=(lambda obj: UI._redact_public(obj, strip_root)) if redact else None' 'redact=None' secrets

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
