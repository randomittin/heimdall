#!/usr/bin/env bash
# test/app-pair-code.test.sh -- the laptop side of pair by session code
# (hmdapp's docs/superpowers/specs/2026-10-05-pair-by-session-code.md; docs/HANDOFF-TO-HEIMDALL-pair-by-code.md,
# sections "Relay client" and "hmd app connect").
#
# Two halves, both hermetic -- a loopback relay (test/lib/fake_relay_code.py), a `gh` script in the sandbox's PATH
# that prints an obviously fake token, throwaway HOME / repo / TMPDIR, free ports, nothing on the network, never
# the real relay or the real GitHub:
#   test/lib/app_pair_code_client_cases.py  the REAL bin/heimdall-relay-client in --code mode: the shared
#                                           known-answer vectors, registration, token hygiene, key_reveal + SAS +
#                                           laptop approval, reject / timeout / closed input, renewal, QR bind
#   test/lib/app_pair_code_app_cases.py     the REAL bin/heimdall-app: transport default, the token's path, the
#                                           code `hmd ui` shows, every "off" path, the --confirm refusals (no
#                                           terminal, --bg), the --confirm prompt and its escape stripping,
#                                           identity revoke, one whole pairing (code-only pairing, the default
#                                           since 2026-10-08, is test/app-pair-confirm.test.sh)
# plus the static checks the handoff lists for the client and for the token's path.
# Every scenario of both files is a case of its own (a sandbox, a relay on a port of its own), and the cases of the two files run in ONE pool of
# processes, six at a time (test/lib/case_pool.py) -- the files one after the other left the pool half empty at the end of each.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_CASES="$REPO/test/lib/app_pair_code_client_cases.py"
APP_CASES="$REPO/test/lib/app_pair_code_app_cases.py"
RUNNER="$REPO/test/lib/case_pool.py"
CLIENT="$REPO/bin/heimdall-relay-client"
APP="$REPO/bin/heimdall-app"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-pair-code (hmd app connect + bin/heimdall-relay-client: pair by session code)"

for f in "$CLIENT_CASES" "$APP_CASES" "$RUNNER" "$REPO/test/lib/sandbox_procs.py" "$CLIENT" "$APP" "$REPO/test/lib/fake_relay_code.py" "$REPO/test/lib/pair_code_harness.py" \
         "$REPO/bin/lib/hmd_app_code.py" "$REPO/test/fixtures/hmdapp-pair-code-vectors.json"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n' "$f" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done
for tool in python3 jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n' "$tool" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ── static checks (the handoff's acceptance greps, and the token's path in the sources) ──────────────
if grep -q 'hmd-pair-sas-v1' "$CLIENT"; then
  ok "the relay client carries the SAS domain string hmd-pair-sas-v1"
else
  bad "hmd-pair-sas-v1 missing from bin/heimdall-relay-client"
fi
if grep -q 'hmd-pair-commit-v1' "$CLIENT"; then
  ok "the relay client carries the commitment domain string hmd-pair-commit-v1"
else
  bad "hmd-pair-commit-v1 missing from bin/heimdall-relay-client"
fi
if grep -nE 'gh_token.*(log|emit|print)' "$CLIENT" >"$TMPROOT/leak.out"; then
  bad "a relay-client line names the token near log/emit/print: $(head -3 "$TMPROOT/leak.out")"
else
  ok "no relay-client line puts the token near a log, emit or print"
fi
if grep -nE '(export|declare -x|env) +[A-Za-z_]*(GH|GITHUB)_?TOKEN|GH_TOKEN=|GITHUB_TOKEN=' "$APP" >"$TMPROOT/env.out"; then
  bad "bin/heimdall-app puts a token in an environment variable: $(head -3 "$TMPROOT/env.out")"
else
  ok "bin/heimdall-app never puts a GitHub token in an environment variable"
fi
if grep -q 'hmd-relay.therishabh16.workers.dev' "$APP"; then
  ok "bin/heimdall-app defaults to the hosted relay origin"
else
  bad "the hosted relay origin is not in bin/heimdall-app"
fi

# ── the two case files: every case of both, in ONE pool of processes ──────────────────────────────────────
# test/lib/case_pool.py runs each case in a process of its own, six at a time (the heimdall-app file's first: it has the most work), and writes
# each file's report -- its result lines in the order the file declares its cases, then its tally -- to $TMPROOT/<key>.out, the file's exit status
# (0 only when no case failed and every case ended with a tally) to $TMPROOT/<key>.rc.
python3 "$RUNNER" "$TMPROOT" "app=$APP_CASES" "client=$CLIENT_CASES" >"$TMPROOT/pool.log" 2>&1
pool_rc=$?

report_cases() {
  local label="$1" key="$2" out="$TMPROOT/$2.out" rc tally
  rc="$(cat "$TMPROOT/$key.rc" 2>/dev/null)"
  echo "-- $label --"
  grep -E '^  (ok|FAIL) ' "$out" 2>/dev/null
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" 2>/dev/null | tail -1)"
  if [ "$rc" = 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
    ok "$label: $tally"
  else
    bad "$label failed (exit ${rc:-none}, tally '${tally:-none}', case pool exit $pool_rc)"
    grep -E 'Traceback|Error' -A3 "$out" "$TMPROOT/pool.log" 2>/dev/null | head -20
  fi
}

report_cases "relay client (--code)" client
report_cases "hmd app connect" app

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
