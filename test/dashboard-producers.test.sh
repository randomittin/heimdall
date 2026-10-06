#!/usr/bin/env bash
# test/dashboard-producers.test.sh
#
# The PRODUCER half of custom dashboards (hmdapp docs/HANDOFF-TO-HEIMDALL-custom-dashboards.md DD4, DD5, DD6):
# bin/lib/dashboard_producers.py -- the statement check, the read-only drivers, the generator, `hmd dash` laptop confirmation and the
# refresh scheduler. The protocol half (bin/lib/companion_dashboards.py) is the one writer of tile files; this suite drives the producer
# half against test/lib/dash_store_fake.py, a file-backed implementation of the interface companion_dashboards documents (the real
# store is exercised by the integration run after both halves merge).
#
#   1  the battery (test/lib/dashboard_producers_battery.py), against the REAL module:
#        statement table (SELECT ok; every write attempt, `;`, comment, SELECT INTO, locking clause, pg_sleep, file read, function off the
#        allowlist, quoted/qualified call, backslash, `$`, psql variable, bidi character, PRAGMA/ATTACH: refused), the type wall (a driver
#        runs a CheckedStatement and nothing else), the engine layers (sqlite mode=ro + query_only + authorizer; psql read-only session),
#        credentials (env-var NAME only; never argv, file, log or the model's process), the psql child (argv/env/cwd, timeout kills it),
#        every panel shape, the 32 KiB budget, the generator against a fake model (valid, two statements, free text, extra key, duplicate
#        key, two objects, injection text; no-connector / ambiguous / unsafe-query / generation-failed / timeout; never a running producer),
#        confirmation (non-TTY refused in the library and the CLI, wrong code, 3 wrong = 10 minute lock, right code on a real pty, hash only
#        in the pending file, 24 h expiry, a changed fingerprint re-enters confirmation, imports ALWAYS re-confirmed, decline), the
#        scheduler (backoff 1,2,4.., 10 failures = paused/backoff, refresh lifts it, +-10% jitter, 12 h idle pause with an injected clock,
#        one producer at a time per repo), and structure (no shell, no write-capable connector module, nothing remote can confirm)
#   2  mutants: the module is rebuilt with ONE deliberate defect at a time and the NAMED assertion must fail for each
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, the psql and model binaries are fake scripts, every child is reaped, every wait
# is bounded. No network, no real psql, no model call. Secret-shaped strings are assembled at runtime.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$REPO/bin/lib/dashboard_producers.py"
FAKE="$REPO/test/lib/dash_store_fake.py"
BATTERY="$REPO/test/lib/dashboard_producers_battery.py"

PASS=0
FAIL=0

echo "dashboard-producers (statement check, read-only drivers, generator, laptop confirmation, scheduler)"

for f in "$MOD" "$FAKE" "$BATTERY" "$REPO/bin/lib/companion_ui_panels.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: required tool missing: python3\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

run_section() {
  local label="$1"
  shift
  local out rc
  out="$("$@" 2>&1 </dev/null)"
  rc=$?
  printf '%s\n' "$out"
  local p f
  p="$(printf '%s\n' "$out" | grep -c '^  ok  ' || true)"
  f="$(printf '%s\n' "$out" | grep -c '^  FAIL ' || true)"
  PASS=$((PASS + p))
  FAIL=$((FAIL + f))
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s exited %d without a failing assertion\n' "$label" "$rc"
  fi
}

echo "== 1. the battery against the real module =="
run_section "battery" python3 "$BATTERY" "$MOD" "$FAKE"

echo "== 2. mutants: each deliberate defect must fail its named assertion =="
run_section "mutants" python3 "$BATTERY" "$MOD" "$FAKE" --mutants

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
