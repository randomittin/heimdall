#!/usr/bin/env bash
# test/dashboard-digest.test.sh -- the daily morning-report push (hmdapp docs/HANDOFF-TO-HEIMDALL-watch.md H4, cap push-digest-v1).
#
# bin/lib/dashboard_digest.py owns the schedule, the counters and the body; the `set-digest` op rides bin/lib/companion_dashboards.py's
# dashboard-request; the push itself goes through bin/lib/companion_push.py's own policy (foreground suppression, coalescing, rate limits).
#   U  the pure rules: params, local time and timezone, once-per-day, counters, values, the body (limits, scrub, secrets)
#   W  the wire: caps, every refusal, the audit line holds no value
#   M  the real PushMonitor over a loopback fake Expo: once a day, asleep, off, empty, foreground, rate limit, kind filter,
#      two processes, values opt-in, timezone, the dashboards switch, the kill switch, payload limits, the production store
#   X  mutants: each rule changed in a copy of bin/lib must make the cases above fail
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR are a temp dir, every sender talks to a loopback fake through HMD_PUSH_EXPO_URL (set by the
# cases), and HTTPS_PROXY points at a closed port so a push that tried to leave this machine would die at the proxy. No real push is
# ever sent. Secret- and token-shaped inputs are assembled at runtime.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "dashboard-digest (the daily morning-report push: schedule, once a day, timezone, caps, limits, scrub)"

for f in "$REPO/bin/lib/dashboard_digest.py" "$REPO/bin/lib/companion_push.py" "$REPO/bin/lib/companion_dashboards.py" \
         "$REPO/test/lib/dashboard_digest_cases.py" "$REPO/test/lib/dashboard_digest_mutants.py" "$REPO/test/lib/push_test_lib.py"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FATAL: python3 is required\n' >&2
  printf '\n0 passed, 1 failed\n'
  exit 1
fi

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$HOME/.heimdall"
export TMPDIR="$TMPROOT"
mkdir -p "$HOME"
unset HMD_PUSH HMD_PUSH_EXPO_URL HMD_PUSH_COALESCE_S HMD_PUSH_MIN_RUN_S HMD_UI_CONTROLS DIGEST_LIB
export HTTPS_PROXY="http://127.0.0.1:9" HTTP_PROXY="http://127.0.0.1:9"
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"

# Run one python part; each line it prints is `ok <text>` or `bad <text>` (forwarded to the tally), anything else is shown indented.
# A part that dies before finishing is itself a failure.
run_part() {
  local label="$1" script="$2"; shift 2
  local out="$TMPROOT/$label.out" line saw_done=0
  python3 "$script" "$REPO" "$TMPROOT/$label" "$@" >"$out" 2>"$TMPROOT/$label.err"
  local rc=$?
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   ok "${line#ok }" ;;
      "bad "*)  bad "${line#bad }" ;;
      "done")   saw_done=1 ;;
      *)        printf '       | %s\n' "$line" ;;
    esac
  done <"$out"
  if [ "$rc" -ne 0 ] || [ "$saw_done" -ne 1 ]; then
    bad "$label: part did not finish (rc=$rc): $(tail -n 6 "$TMPROOT/$label.err" | tr '\n' '|')"
  fi
}

run_part cases "$REPO/test/lib/dashboard_digest_cases.py"
run_part mutants "$REPO/test/lib/dashboard_digest_mutants.py"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
