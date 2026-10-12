#!/usr/bin/env bash
# test/app-upgrade-paired.test.sh -- upgrade while paired: the phone a v2.4.6 relay client has bound is carried over into the per-phone
# device records of v2.4.7 -- the running client is not restarted, replaced or signalled by the new hooks, statusline, `hmd app status`,
# pair window or `hmd app connect`, the phone does not pair again, `hmd app status` lists it, a second phone pairs beside it without
# clearing its push registrations, and `hmd app disconnect --device` revokes it the way a 2.4.6 client can be revoked.
#
# Hermetic like test/app-pair-confirm.test.sh (loopback relay test/lib/fake_relay_code.py, a fake `gh`, throwaway HOME / repo / TMPDIR);
# the old side is the real v2.4.6 tree, extracted with `git archive` into a scratch directory and removed again. A clone whose
# history lacks the tag runs the check as a visible skip.
#   test/lib/app_upgrade_paired_cases.py   the case; its header numbers the checks
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$REPO/test/lib/app_upgrade_paired_cases.py"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-upgrade-paired (a phone bound to a v2.4.6 client survives the upgrade to per-phone device records)"

for f in "$CASES" "$REPO/bin/heimdall-app" "$REPO/bin/heimdall-relay-client" "$REPO/bin/lib/hmd_devices.py" \
         "$REPO/test/lib/app_pair_confirm_cases.py" "$REPO/test/lib/fake_relay_code.py" "$REPO/test/lib/pair_code_harness.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 jq git tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

python3 "$CASES" >"$TMPROOT/cases.out" 2>&1
rc=$?
grep -E '^  (ok|FAIL) ' "$TMPROOT/cases.out"
tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$TMPROOT/cases.out" | tail -1)"
if [ "$rc" -eq 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
  ok "cases: $tally"
else
  bad "cases failed (exit $rc, tally '${tally:-none}')"
  grep -E 'Traceback|Error' -A3 "$TMPROOT/cases.out" | head -20
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
