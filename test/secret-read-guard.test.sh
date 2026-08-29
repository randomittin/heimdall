#!/usr/bin/env bash
#
# secret-read-guard.test.sh — acceptance for bin/secret-read-guard, the
# PreToolUse guard closing the credential-egress-audit C-4/H-1 file-read hole
# (.planning/security/2026-08-29-credential-egress-audit.md).
#
# Guarantees proved (hermetic — own $TMP, FAKE credential-shaped content only,
# NEVER the operator's real ~/.ssh, ~/.aws, ~/.omniroute or .heimdall/team.json):
#   1. Every named deny pattern is blocked (filename signal).
#   2. .env.example / *.pub / ordinary source are NOT blocked (false-positive
#      protection — the guard must not be so broad it gets disabled).
#   3. A RENAMED private key (fake OPENSSH/RSA PEM header in a .txt file) IS
#      blocked — proves the content signal is independent of filename.
#   4. Bash coverage: single-command and piped invocations of the covered
#      reader binaries are blocked the same as the Read tool; a bare
#      command with no covered reader is allowed.
#   5. Escape hatch (blanket "1" and path-scoped glob) allows the read AND
#      always announces itself on stderr; an ordinary allow stays silent.
#   6. Fail-closed on an ambiguous, sensitivity-hinted argument; fail-open
#      when the guard's own dependency (jq) is unavailable.
#   7. FALSIFIABILITY — the same expect_block() assertion function is
#      re-run against a deliberately no-op (always-allow) guard and must
#      itself report FAILs; those synthetic fails are then excluded from
#      the real tally (see "red-proof" section). This proves the suite is
#      not vacuously true without ever putting the real, committed guard
#      script into a broken state.
#
# Usage: bash test/secret-read-guard.test.sh   (exit 0 = all hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
GUARD="$REPO/bin/secret-read-guard"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this test harness"; exit 1; }
[ -x "$GUARD" ] || { echo "FATAL: $GUARD missing or not executable"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/secret-read-guard.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "secret-read-guard acceptance  fixtures=$TMP"
echo "--------------------------------------------------------------------"

# ---- fixture builder (FAKE content only) -----------------------------------
mk() {
  rel="$1"; content="$2"
  full="$TMP/$rel"
  mkdir -p "$(dirname "$full")"
  printf '%s\n' "$content" > "$full"
}

mk ".env"                              "FAKE_SECRET=sk-fake-0000000000000000"
mk ".env.local"                        "FAKE_SECRET=sk-fake-local-0000000000"
mk ".env.example"                      "FAKE_SECRET=your-key-here"
mk ".env.sample"                       "FAKE_SECRET=your-key-here"
mk ".env.template"                     "FAKE_SECRET=your-key-here"
mk "config.pem"                        "-----BEGIN CERTIFICATE-----\nFAKEFAKEFAKE\n-----END CERTIFICATE-----"
mk "app.key"                           "fake-key-bytes-not-real"
mk "app.pub"                           "ssh-rsa AAAAB3FAKEFAKEFAKE fake@fake"
mk "id_rsa"                            "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEFAKEFAKE\n-----END OPENSSH PRIVATE KEY-----"
mk "id_rsa.pub"                        "ssh-rsa AAAAB3FAKEFAKEFAKE fake@fake"
mk "id_ed25519"                        "fake-ed25519-key-bytes"
mk "id_ecdsa"                          "fake-ecdsa-key-bytes"
mk "credentials.json"                  '{"fake_key":"fake_value"}'
mk "service-account-foo.json"          '{"type":"service_account","fake":"value"}'
mk "vault.p12"                         "fake-p12-bytes"
mk "vault.pfx"                         "fake-pfx-bytes"
mk "app.keystore"                      "fake-keystore-bytes"
mk "app.jks"                           "fake-jks-bytes"
mk ".aws/credentials"                  "[default]\naws_access_key_id=FAKE\naws_secret_access_key=FAKE"
mk ".omniroute/heimdall-fallback.key"  "fake-fallback-key"
mk ".omniroute/management-password.txt" "fake-password"
mk ".omniroute/server.env"             "FAKE_VAR=fake"
mk ".heimdall/team.json"               '{"fake":"team"}'
mk ".ssh/id_rsa"                       "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEFAKEFAKE\n-----END OPENSSH PRIVATE KEY-----"
mk ".ssh/my_custom_key"                "fake-unknown-named-key-in-ssh-dir"
mk ".ssh/known_hosts"                  "example.com ssh-rsa FAKEFAKEFAKE"
mk ".ssh/id_rsa.pub"                   "ssh-rsa AAAAB3FAKEFAKEFAKE fake@fake"
mk "ordinary.ts"                       "export const answer = 42;"
mk "notes-with-key.txt"                "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEFAKEFAKE\n-----END OPENSSH PRIVATE KEY-----"
mk "notes-with-rsa-key.txt"            "-----BEGIN RSA PRIVATE KEY-----\nFAKEFAKEFAKE\n-----END RSA PRIVATE KEY-----"

# ---- harness -----------------------------------------------------------
GUARD_OUT=""; GUARD_ERR=""
run_guard() {
  bin="$1"; payload="$2"; cwd="${3:-$TMP}"; extra_env="${4:-}"
  full="$(printf '%s' "$payload" | jq -c --arg c "$cwd" '. + {cwd: $c}')"
  errfile="$TMP/.stderr.$$"
  if [ -n "$extra_env" ]; then
    GUARD_OUT="$(printf '%s' "$full" | env "$extra_env" "$bin" 2>"$errfile")"
  else
    GUARD_OUT="$(printf '%s' "$full" | "$bin" 2>"$errfile")"
  fi
  rc=$?
  GUARD_ERR="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
  return "$rc"
}

expect_block() {
  desc="$1"; bin="$2"; payload="$3"; cwd="${4:-$TMP}"
  if run_guard "$bin" "$payload" "$cwd"; then
    bad "$desc (expected BLOCK, guard ALLOWED, rc=0)"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then ok "$desc (blocked, rc=2)"
    else bad "$desc (expected rc=2, got rc=$rc; stderr: $GUARD_ERR)"
    fi
  fi
}

expect_allow() {
  desc="$1"; bin="$2"; payload="$3"; cwd="${4:-$TMP}"
  if run_guard "$bin" "$payload" "$cwd"; then
    ok "$desc (allowed, rc=0)"
  else
    rc=$?
    bad "$desc (expected ALLOW rc=0, got rc=$rc; out: $GUARD_OUT)"
  fi
}

read_payload() { printf '{"tool_name":"Read","tool_input":{"file_path":"%s/%s"}}' "$TMP" "$1"; }
bash_payload()  { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

echo "-- 1. deny-list: each named pattern blocked (Read) --------------------"
expect_block ".env"                             "$GUARD" "$(read_payload .env)"
expect_block ".env.local (.env.* pattern)"      "$GUARD" "$(read_payload .env.local)"
expect_block "*.pem"                            "$GUARD" "$(read_payload config.pem)"
expect_block "*.key"                            "$GUARD" "$(read_payload app.key)"
expect_block "id_rsa"                           "$GUARD" "$(read_payload id_rsa)"
expect_block "id_ed25519"                       "$GUARD" "$(read_payload id_ed25519)"
expect_block "id_ecdsa"                         "$GUARD" "$(read_payload id_ecdsa)"
expect_block "credentials.json"                 "$GUARD" "$(read_payload credentials.json)"
expect_block "service-account*.json"            "$GUARD" "$(read_payload service-account-foo.json)"
expect_block "*.p12"                            "$GUARD" "$(read_payload vault.p12)"
expect_block "*.pfx"                            "$GUARD" "$(read_payload vault.pfx)"
expect_block "*.keystore"                       "$GUARD" "$(read_payload app.keystore)"
expect_block "*.jks"                            "$GUARD" "$(read_payload app.jks)"
expect_block "~/.aws/credentials shape"         "$GUARD" "$(read_payload .aws/credentials)"
expect_block "~/.omniroute/heimdall-fallback.key" "$GUARD" "$(read_payload .omniroute/heimdall-fallback.key)"
expect_block "~/.omniroute/management-password.txt" "$GUARD" "$(read_payload .omniroute/management-password.txt)"
expect_block "~/.omniroute/server.env"          "$GUARD" "$(read_payload .omniroute/server.env)"
expect_block ".heimdall/team.json"              "$GUARD" "$(read_payload .heimdall/team.json)"
expect_block "~/.ssh/id_rsa (named)"            "$GUARD" "$(read_payload .ssh/id_rsa)"
expect_block "~/.ssh/<unknown> (fail-closed default)" "$GUARD" "$(read_payload .ssh/my_custom_key)"

echo "-- 2. false-positive protection: these must NOT block -----------------"
expect_allow ".env.example"                     "$GUARD" "$(read_payload .env.example)"
expect_allow ".env.sample"                      "$GUARD" "$(read_payload .env.sample)"
expect_allow ".env.template"                    "$GUARD" "$(read_payload .env.template)"
expect_allow "*.pub (app.pub)"                  "$GUARD" "$(read_payload app.pub)"
expect_allow "id_rsa.pub"                       "$GUARD" "$(read_payload id_rsa.pub)"
expect_allow "~/.ssh/id_rsa.pub"                "$GUARD" "$(read_payload .ssh/id_rsa.pub)"
expect_allow "~/.ssh/known_hosts (safe-listed)" "$GUARD" "$(read_payload .ssh/known_hosts)"
expect_allow "ordinary source file"             "$GUARD" "$(read_payload ordinary.ts)"

echo "-- 3. content sniff: renamed private key blocked regardless of name --"
expect_block "notes.txt containing OPENSSH PRIVATE KEY header" "$GUARD" "$(read_payload notes-with-key.txt)"
expect_block "notes.txt containing RSA PRIVATE KEY header"     "$GUARD" "$(read_payload notes-with-rsa-key.txt)"

echo "-- 4. Bash coverage ----------------------------------------------------"
expect_block "Bash: cat .env (single command, no pipe)" \
  "$GUARD" "$(bash_payload "cat $TMP/.env")"
expect_block "Bash: grep foo .env | head (piped)" \
  "$GUARD" "$(bash_payload "grep foo $TMP/.env | head")"
expect_block "Bash: head -c 100 id_rsa" \
  "$GUARD" "$(bash_payload "head -c 100 $TMP/id_rsa")"
expect_block "Bash: cp .env /dev/stdout" \
  "$GUARD" "$(bash_payload "cp $TMP/.env /dev/stdout")"
expect_block "Bash: base64 credentials.json" \
  "$GUARD" "$(bash_payload "base64 $TMP/credentials.json")"
expect_allow "Bash: cat ordinary.ts" \
  "$GUARD" "$(bash_payload "cat $TMP/ordinary.ts")"
expect_allow "Bash: echo hi && ls -la (no covered reader)" \
  "$GUARD" "$(bash_payload "echo hi && ls -la")"
expect_block "Bash: find .ssh | xargs cat (coarse xargs/dir heuristic)" \
  "$GUARD" "$(bash_payload "find $TMP/.ssh -type f | xargs cat")"
expect_allow "Bash: find . -name '*.ts' | xargs wc -l (uncovered reader, no sensitive dir)" \
  "$GUARD" "$(bash_payload "find $TMP -name '*.ts' | xargs wc -l")"

echo "-- 5. escape hatch: allows AND always announces on stderr ------------"
if run_guard "$GUARD" "$(read_payload .env)" "$TMP" "HMD_ALLOW_SECRET_READ=1"; then
  if printf '%s' "$GUARD_ERR" | grep -q "HMD_ALLOW_SECRET_READ"; then
    ok "blanket HMD_ALLOW_SECRET_READ=1 allows .env AND announces on stderr"
  else
    bad "blanket escape hatch allowed but did NOT announce on stderr (silent override is forbidden)"
  fi
else
  bad "blanket HMD_ALLOW_SECRET_READ=1 did not allow .env (rc=$?)"
fi

if run_guard "$GUARD" "$(read_payload .env)" "$TMP" "HMD_ALLOW_SECRET_READ=$TMP/.env"; then
  ok "path-scoped escape hatch (exact path) allows the matching path"
else
  bad "path-scoped escape hatch did not allow its own exact path"
fi

if run_guard "$GUARD" "$(read_payload id_rsa)" "$TMP" "HMD_ALLOW_SECRET_READ=$TMP/.env"; then
  bad "path-scoped escape hatch for .env WRONGLY allowed id_rsa (scoping leaked)"
else
  ok "path-scoped escape hatch does NOT leak to a non-matching path (id_rsa still blocked)"
fi

if run_guard "$GUARD" "$(read_payload ordinary.ts)" "$TMP"; then
  if [ -z "$GUARD_ERR" ]; then
    ok "an ordinary allow (no deny match) stays silent on stderr"
  else
    bad "ordinary allow unexpectedly printed to stderr: $GUARD_ERR"
  fi
else
  bad "ordinary.ts unexpectedly blocked"
fi

echo "-- 6. fail-closed (ambiguous) / fail-open (own dependency missing) ---"
expect_block "Bash: cat \$SECRET_KEY_FILE (unresolvable + sensitivity hint)" \
  "$GUARD" "$(bash_payload 'cat $SECRET_KEY_FILE')"
expect_allow "Bash: cat \$LOGFILE (unresolvable, no sensitivity hint)" \
  "$GUARD" "$(bash_payload 'cat $LOGFILE')"

NO_JQ_PATH="/usr/bin:/bin"
if PATH="$NO_JQ_PATH" command -v jq >/dev/null 2>&1; then
  bad "fail-open/no-jq check: jq unexpectedly present on $NO_JQ_PATH -- cannot isolate, counting as FAIL not silently skipped"
else
  OUT="$(printf '%s' "$(read_payload .env)" | env PATH="$NO_JQ_PATH" "$GUARD" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "guard fails OPEN (rc=0) when its own jq dependency is unavailable"
  else
    bad "guard did not fail open without jq (rc=$rc) -- a missing dependency must never brick every tool call"
  fi
fi

echo "-- 7. falsifiability red-proof (no-op guard must fail these) ----------"
NOOP="$TMP/noop-guard"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"
chmod +x "$NOOP"

_PASS_SNAPSHOT=$PASS
_FAIL_SNAPSHOT=$FAIL

expect_block "[red-proof] .env vs no-op guard"          "$NOOP" "$(read_payload .env)"
expect_block "[red-proof] id_rsa vs no-op guard"        "$NOOP" "$(read_payload id_rsa)"
expect_block "[red-proof] renamed key vs no-op guard"   "$NOOP" "$(read_payload notes-with-key.txt)"
expect_block "[red-proof] Bash cat .env vs no-op guard" "$NOOP" "$(bash_payload "cat $TMP/.env")"

_RED_FAILS=$((FAIL - _FAIL_SNAPSHOT))
_RED_TOTAL=$((PASS - _PASS_SNAPSHOT + _RED_FAILS))

# These four assertions are EXPECTED to fail (the no-op always allows). That
# is the point of a red-proof: show the harness CAN report FAIL. Restore the
# real tally so this deliberate negative-control doesn't count against the
# real guard, then record ONE real verdict on the falsifiability property
# itself.
PASS=$_PASS_SNAPSHOT
FAIL=$_FAIL_SNAPSHOT

if [ "$_RED_TOTAL" -gt 0 ] && [ "$_RED_FAILS" -eq "$_RED_TOTAL" ]; then
  ok "falsifiability: all $_RED_TOTAL red-proof assertions correctly FAILED against the no-op (always-allow) guard"
else
  bad "falsifiability BROKEN: only $_RED_FAILS/$_RED_TOTAL red-proof assertions failed against the no-op guard -- assertions may be vacuously true"
fi

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
