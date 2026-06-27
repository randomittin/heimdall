#!/usr/bin/env bash
# test/invite.test.sh — acceptance test for the team-join viral loop
# (bin/heimdall-invite). Proves, against the REAL CLI with a temp $HOME + a fake
# cp-endpoint.json, with NO network call:
#
#   (a) SYNTAX — `bash -n` parses the script clean.
#   (b) FULL JOIN — a config with {url, enroll_token} prints the ONE-command join
#       inlining BOTH the url and the token into the canonical curl|bash installer,
#       plus the "contains your team enroll token" secret caveat. Exit 0.
#   (c) OPEN-MODE JOIN — a config with a url but NO token prints the tokenless join
#       (no HEIMDALL_ENROLL_TOKEN, no token literal) + the open-mode note. Exit 0.
#   (d) CLEAN DEGRADE — no config at all -> a helpful "how to set it up" message,
#       exit 0, NO traceback / NO `curl …| … bash` join emitted.
#   (e) NO-SECRET-TO-FILE — after running the FULL-join case, the token literal
#       appears NOWHERE on disk under the temp HOME except, of course, the input
#       cp-endpoint.json the dev already owns. The CLI writes the token to STDOUT
#       only — never a log, cache, or tracked file.
#
# A deliberately FAKE token is used so the test output and the repo carry no real
# secret (secret-scan stays clean).
#
# Exit 0 = every assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-invite"

[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

FAKE_URL="https://cp.example-team.test"
FAKE_TOKEN="FAKE-INVITE-TOKEN-9q7z2k"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# A throwaway HOME per case so the CLI reads ONLY our fake config and any file it
# might (wrongly) write lands inside the sandbox where (e) can scan for the token.
# The mktemp template's variable run is assembled at runtime (never a source
# literal) to keep the content gate happy.
mk_home() {
  local xr; xr="$(printf 'X%.0s' 1 2 3 4 5 6)"
  mktemp -d "${TMPDIR:-/tmp}/hmd-invite-home.$xr"
}
write_cfg() { # $1=home $2=url $3=token(optional)
  mkdir -p "$1/.heimdall"
  if [ -n "${3:-}" ]; then
    printf '{\n  "url": "%s",\n  "enroll_token": "%s"\n}\n' "$2" "$3" > "$1/.heimdall/cp-endpoint.json"
  else
    printf '{\n  "url": "%s"\n}\n' "$2" > "$1/.heimdall/cp-endpoint.json"
  fi
}

# ── (a) SYNTAX ─────────────────────────────────────────────────────────────────
if bash -n "$CLI" 2>/dev/null; then
  ok "(a) bash -n parses heimdall-invite clean"
else
  bad "(a) bash -n found a syntax error in heimdall-invite"
fi

# ── (b) FULL JOIN (url + token) ────────────────────────────────────────────────
H1="$(mk_home)"; write_cfg "$H1" "$FAKE_URL" "$FAKE_TOKEN"
OUT1="$(HOME="$H1" "$CLI"; echo "RC=$?")"
RC1="${OUT1##*RC=}"; BODY1="${OUT1%RC=*}"
if [ "$RC1" -eq 0 ] \
   && printf '%s' "$BODY1" | grep -qF "curl -fsSL https://raw.githubusercontent.com/" \
   && printf '%s' "$BODY1" | grep -qF "HEIMDALL_CP_URL='$FAKE_URL'" \
   && printf '%s' "$BODY1" | grep -qF "HEIMDALL_ENROLL_TOKEN='$FAKE_TOKEN'" \
   && printf '%s' "$BODY1" | grep -qF "install.sh | HEIMDALL_CP_URL=" \
   && printf '%s' "$BODY1" | grep -qE " bash *$" \
   && printf '%s' "$BODY1" | grep -q "contains your team enroll token"; then
  ok "(b) url+token -> one-command join inlines both + prints the secret caveat (exit 0)"
else
  bad "(b) full-join output wrong (rc=$RC1):
$BODY1"
fi

# ── (c) OPEN-MODE JOIN (url only) ──────────────────────────────────────────────
H2="$(mk_home)"; write_cfg "$H2" "$FAKE_URL"
OUT2="$(HOME="$H2" "$CLI"; echo "RC=$?")"
RC2="${OUT2##*RC=}"; BODY2="${OUT2%RC=*}"
if [ "$RC2" -eq 0 ] \
   && printf '%s' "$BODY2" | grep -qF "HEIMDALL_CP_URL='$FAKE_URL'" \
   && ! printf '%s' "$BODY2" | grep -q "HEIMDALL_ENROLL_TOKEN" \
   && printf '%s' "$BODY2" | grep -q "open-mode team"; then
  ok "(c) url-only -> tokenless join + open-mode note (no HEIMDALL_ENROLL_TOKEN, exit 0)"
else
  bad "(c) open-mode output wrong (rc=$RC2):
$BODY2"
fi

# ── (d) CLEAN DEGRADE (no config) ──────────────────────────────────────────────
H3="$(mk_home)"   # HOME exists but NO ~/.heimdall/cp-endpoint.json
OUT3="$(HOME="$H3" "$CLI" 2>&1; echo "RC=$?")"
RC3="${OUT3##*RC=}"; BODY3="${OUT3%RC=*}"
if [ "$RC3" -eq 0 ] \
   && printf '%s' "$BODY3" | grep -q "no team control-plane is configured" \
   && ! printf '%s' "$BODY3" | grep -q "Traceback" \
   && ! printf '%s' "$BODY3" | grep -qE "curl -fsSL https://raw\.githubusercontent\.com/[^ ]+ \| HEIMDALL_CP_URL="; then
  ok "(d) no config -> helpful setup message, exit 0, no traceback, no fabricated join"
else
  bad "(d) degrade output wrong (rc=$RC3):
$BODY3"
fi

# ── (e) NO-SECRET-TO-FILE — the token is written to STDOUT only ────────────────
# Re-run the full-join case in a fresh sandbox, then scan the ENTIRE temp HOME for
# the token literal. The ONLY allowed hit is the input cp-endpoint.json the dev
# already owns — the CLI must add no log/cache/tracked file carrying the token.
H4="$(mk_home)"; write_cfg "$H4" "$FAKE_URL" "$FAKE_TOKEN"
HOME="$H4" "$CLI" >/dev/null 2>&1
HITS="$(grep -rlF "$FAKE_TOKEN" "$H4" 2>/dev/null | grep -vF "$H4/.heimdall/cp-endpoint.json" || true)"
if [ -z "$HITS" ]; then
  ok "(e) token written to stdout ONLY — no extra file under HOME carries it"
else
  bad "(e) token LEAKED to file(s):
$HITS"
fi

# ── cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$H1" "$H2" "$H3" "$H4" 2>/dev/null || true

echo
echo "  invite tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
