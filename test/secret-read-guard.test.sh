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
#   8. FAIL-OPEN HARDENING (2026-08-30, docs/analysis/2026-08-30-secret-
#      read-guard-crash-blocks-commands.md) — a battery of hostile/
#      malformed payloads (embedded quotes, backticks, nested $(), embedded
#      newlines, a ~200KB command, invalid UTF-8, a missing/null/array
#      `command`, an empty command, no `tool_input`, truncated JSON, jq
#      unavailable) must NEVER produce a silent non-zero exit — only a
#      clean exit 0 or an exit 2 that carries its payload. A malformed/
#      garbage payload specifically must be a clean, SILENT allow (rc=0,
#      empty stdout AND stderr). Falsifiability is re-proved the same way
#      as (7), this time against a deliberately-crashing mutant rather than
#      a no-op one, since the original crash trigger could not be
#      reproduced against current code (see status report).
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
mk "id_rsa"                            "fake-rsa-key-bytes"
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
mk ".ssh/id_rsa"                       "fake-rsa-key-bytes"
mk ".ssh/my_custom_key"                "fake-unknown-named-key-in-ssh-dir"
mk ".ssh/known_hosts"                  "example.com ssh-rsa FAKEFAKEFAKE"
mk ".ssh/id_rsa.pub"                   "ssh-rsa AAAAB3FAKEFAKEFAKE fake@fake"
mk "ordinary.ts"                       "export const answer = 42;"
# PEM banners assembled at runtime — fragments below never form a literal
# "-----BEGIN ... PRIVATE KEY-----" run in source (heimdall-fixture-secret-convention.md).
# These two fixtures rely on the guard's CONTENT sniff (innocuous .txt name), so the
# runtime bytes must still contain a genuine PEM header.
P_PB='-----BEGIN'; P_PK='PRIVATE KEY-----'; P_PE='-----END'; P_NL='\n'
NOTES_KEY_BODY="${P_PB} OPENSSH ${P_PK}${P_NL}FAKEFAKEFAKE${P_NL}${P_PE} OPENSSH ${P_PK}"
NOTES_RSA_BODY="${P_PB} RSA ${P_PK}${P_NL}FAKEFAKEFAKE${P_NL}${P_PE} RSA ${P_PK}"
mk "notes-with-key.txt"                "$NOTES_KEY_BODY"
mk "notes-with-rsa-key.txt"            "$NOTES_RSA_BODY"

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

# Build a PATH that has every OTHER dependency the guard needs (bash, cat,
# grep, sed, awk, head, readlink, env) but deliberately NOT jq, regardless of
# where jq happens to live on this host (a hardcoded "/usr/bin:/bin lacks
# jq" assumption broke on a machine that ships jq there).
NOJQ_BIN="$TMP/.nojq-bin"
mkdir -p "$NOJQ_BIN"
for t in bash cat grep sed awk head readlink env; do
  real="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "$NOJQ_BIN/$t"
done
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
  bad "fail-open/no-jq check: jq unexpectedly resolvable via the isolated PATH -- cannot isolate, counting as FAIL not silently skipped"
else
  OUT="$(printf '%s' "$(read_payload .env)" | PATH="$NOJQ_BIN" "$GUARD" 2>/dev/null)"
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

echo "-- 8. hostile-payload fail-open hardening (2026-08-30 crash fix) ------"
# Every assertion here enforces ONE contract, at this script's own process
# boundary: the ONLY two reachable outcomes are exit 0 (silent, or with an
# escape-hatch stderr notice) or exit 2 WITH its {"error":...} payload
# already on stdout. A non-zero exit that is not 2, or an exit 2 with empty
# stdout, is exactly the failure mode from docs/analysis/2026-08-30-secret-
# read-guard-crash-blocks-commands.md and must never happen again.
expect_never_silent() {
  desc="$1"; bin="$2"; payload="$3"
  errfile="$TMP/.stderr.nsi.$$"
  out="$(printf '%s' "$payload" | perl -e 'alarm(5); exec @ARGV' "$bin" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
  case "$rc" in
    0) ok "$desc (allowed cleanly, rc=0)" ;;
    2)
      if [ -n "$out" ]; then
        ok "$desc (blocked WITH payload, rc=2)"
      else
        bad "$desc (rc=2 but stdout EMPTY -- exactly the 2026-08-30 failure shape)"
      fi
      ;;
    *)
      bad "$desc (SILENT non-zero exit rc=$rc -- structurally forbidden; stdout=[$out] stderr=[$err])"
      ;;
  esac
}

CMD_QUOTES=$(cat <<'RAWCMD'
echo "she said \"hi\" and `whoami` then $(echo done)"
RAWCMD
)
P_QUOTES=$(jq -cn --arg cmd "$CMD_QUOTES" '{tool_name:"Bash", tool_input:{command:$cmd}}')
expect_never_silent "embedded double quotes + backticks + \$()" "$GUARD" "$P_QUOTES"

P_NESTED=$(jq -cn --arg cmd 'echo $(echo $(echo $(echo inner)))' '{tool_name:"Bash", tool_input:{command:$cmd}}')
expect_never_silent "deeply nested \$()" "$GUARD" "$P_NESTED"

CMD_MULTILINE=$(cat <<'RAWCMD'
echo "path: $(grep -c FOO some/file)" && echo "~/.heimdall/agent-pool.json"
git merge --no-ff -m "merge: issue-loop fixtures off the removed 'on' state" some-branch
RAWCMD
)
P_MULTILINE=$(jq -cn --arg cmd "$CMD_MULTILINE" '{tool_name:"Bash", tool_input:{command:$cmd}}')
expect_never_silent "multi-line command resembling the reported trigger shape" "$GUARD" "$P_MULTILINE"

LONGCMD="echo $(printf 'a%.0s' $(seq 1 200000))"
P_LONG=$(jq -cn --arg cmd "$LONGCMD" '{tool_name:"Bash", tool_input:{command:$cmd}}')
expect_never_silent "very long command (~200KB)" "$GUARD" "$P_LONG"

expect_never_silent "command is a JSON array, not a string" "$GUARD" \
  '{"tool_name":"Bash","tool_input":{"command":["cat",".env"]}}'
expect_never_silent "command is JSON null" "$GUARD" \
  '{"tool_name":"Bash","tool_input":{"command":null}}'
expect_never_silent "command is empty string" "$GUARD" \
  '{"tool_name":"Bash","tool_input":{"command":""}}'
expect_never_silent "tool_input missing entirely" "$GUARD" \
  '{"tool_name":"Bash"}'

P_EMBEDDED_NL=$(jq -cn --arg cmd "$(printf 'line one\nline two\ncat .env')" '{tool_name:"Bash", tool_input:{command:$cmd}}')
expect_never_silent "embedded literal newlines in command" "$GUARD" "$P_EMBEDDED_NL"

BADUTF8_FILE="$TMP/.badutf8-payload.json"
printf '{"tool_name":"Bash","tool_input":{"command":"cat \xc0\x80 .env"}}' > "$BADUTF8_FILE"
BADUTF8_PAYLOAD="$(cat "$BADUTF8_FILE")"
rm -f "$BADUTF8_FILE"
expect_never_silent "invalid UTF-8 bytes embedded in command value" "$GUARD" "$BADUTF8_PAYLOAD"

echo "-- 8b. jq-missing forces fail-open even for a would-be-denied payload -"
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
  bad "jq-missing recheck: jq unexpectedly resolvable via isolated PATH -- cannot isolate, counting as FAIL"
else
  OUT2="$(printf '%s' "$(read_payload .env)" | PATH="$NOJQ_BIN" "$GUARD" 2>/dev/null)"
  rc2=$?
  if [ "$rc2" -eq 0 ] && [ -z "$OUT2" ]; then
    ok "jq missing -> even a would-be-denied .env read is allowed cleanly (rc=0, no payload)"
  else
    bad "jq missing did not cleanly fail open for a would-be-denied payload (rc=$rc2, out=[$OUT2])"
  fi
fi

echo "-- 8c. malformed/garbage payload -> clean SILENT allow, not just non-crash --"
expect_clean_allow() {
  desc="$1"; bin="$2"; payload="$3"
  errfile="$TMP/.stderr.ca.$$"
  out="$(printf '%s' "$payload" | perl -e 'alarm(5); exec @ARGV' "$bin" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then
    ok "$desc (clean silent allow: rc=0, stdout empty, stderr empty)"
  else
    bad "$desc (expected clean silent allow; got rc=$rc stdout=[$out] stderr=[$err])"
  fi
}
P_TRUNCATED='{"tool_name":"Bash", "tool_input": {"command": "cat .env"'
expect_clean_allow "truncated/malformed JSON" "$GUARD" "$P_TRUNCATED"
P_GARBAGE=$'\x00\x01\xff\xfe garbage not json at all'
expect_clean_allow "completely garbage non-JSON bytes" "$GUARD" "$P_GARBAGE"

echo "-- 9. crashing-mutant red-proof (fail-open assertions must go RED) ----"
# The original 2026-08-30 crash trigger could NOT be reproduced against
# current code (a bounded battery of hostile payloads above all landed on a
# clean 0 or a payload-bearing 2). Per the task's fallback instruction,
# falsifiability of the never-silent assertions is proved instead against a
# DELIBERATELY crashing mutant -- a standalone script, never the real
# committed guard -- that dies from an unguarded internal failure under
# `set -e`, mimicking the reported failure shape: non-zero exit, no
# payload, no explanation.
CRASHER="$TMP/crasher-guard"
cat > "$CRASHER" <<'CRASHEOF'
#!/usr/bin/env bash
set -euo pipefail
INPUT="$(cat)"
false
echo "unreachable"
CRASHEOF
chmod +x "$CRASHER"

_PASS_SNAPSHOT2=$PASS
_FAIL_SNAPSHOT2=$FAIL

expect_never_silent "[red-proof] plain Bash payload vs crashing mutant" "$CRASHER" "$(bash_payload "echo hi")"
expect_never_silent "[red-proof] .env Read payload vs crashing mutant"  "$CRASHER" "$(read_payload .env)"
expect_never_silent "[red-proof] hostile quotes payload vs crashing mutant" "$CRASHER" "$P_QUOTES"

_RED_FAILS2=$((FAIL - _FAIL_SNAPSHOT2))
_RED_TOTAL2=$((PASS - _PASS_SNAPSHOT2 + _RED_FAILS2))

PASS=$_PASS_SNAPSHOT2
FAIL=$_FAIL_SNAPSHOT2

if [ "$_RED_TOTAL2" -gt 0 ] && [ "$_RED_FAILS2" -eq "$_RED_TOTAL2" ]; then
  ok "falsifiability: all $_RED_TOTAL2 never-silent assertions correctly FAILED against a deliberately-crashing mutant"
else
  bad "falsifiability BROKEN: only $_RED_FAILS2/$_RED_TOTAL2 never-silent assertions failed against the crashing mutant -- may be vacuously true"
fi

echo "--------------------------------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
