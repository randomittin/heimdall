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
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_CASES="$REPO/test/lib/app_pair_code_client_cases.py"
APP_CASES="$REPO/test/lib/app_pair_code_app_cases.py"
CLIENT="$REPO/bin/heimdall-relay-client"
APP="$REPO/bin/heimdall-app"

PASS=0
FAIL=0
N=0
ok()  { N=$((N + 1)); PASS=$((PASS + 1)); printf '  ok   %d. %s\n' "$N" "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %d. %s\n' "$N" "$1"; }

echo "app-pair-code (hmd app connect + bin/heimdall-relay-client: pair by session code)"

for f in "$CLIENT_CASES" "$APP_CASES" "$CLIENT" "$APP" "$REPO/test/lib/fake_relay_code.py" "$REPO/test/lib/pair_code_harness.py" \
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

# ── the two case files ────────────────────────────────────────────────────────────────────────────────
run_cases() {
  local label="$1" file="$2" out="$TMPROOT/$1.out" rc tally
  python3 "$file" >"$out" 2>&1
  rc=$?
  echo "-- $label --"
  grep -E '^  (ok|FAIL) ' "$out"
  tally="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$tally" ] && printf '%s' "$tally" | grep -q ' 0 failed$'; then
    ok "$label: $tally"
  else
    bad "$label failed (exit $rc, tally '${tally:-none}')"
    grep -E 'Traceback|Error' -A3 "$out" | head -20
  fi
}

run_cases "relay client (--code)" "$CLIENT_CASES"
run_cases "hmd app connect" "$APP_CASES"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
