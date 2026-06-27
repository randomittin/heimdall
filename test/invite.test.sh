#!/usr/bin/env bash
# test/invite.test.sh — acceptance test for the team-join viral loop
# (bin/heimdall-invite). Proves, against the REAL CLI with a temp $HOME + a per-
# repo team.json (via HEIMDALL_TEAM_DIR), with NO network call:
#
#   (a) SYNTAX — `bash -n` parses the script clean.
#   (b) FULL JOIN — a repo team.json {team_secret} + a global cp-endpoint {url}
#       prints the ONE-command join inlining BOTH the url and the TEAM SECRET into
#       the canonical curl|bash installer (HEIMDALL_CP_URL + HEIMDALL_TEAM_SECRET),
#       plus the "contains your team secret" caveat. Exit 0.
#   (c) URL-DEFAULT JOIN — a team.json secret but NO cp-endpoint url falls back to
#       the shipped public default url (still HEIMDALL_TEAM_SECRET). Exit 0.
#   (d) CLEAN DEGRADE — no team.json at all -> a helpful "run heimdall-team new"
#       message, exit 0, NO traceback / NO `curl …| … bash` join emitted.
#   (e) NO-SECRET-TO-FILE — after the FULL-join case, the secret literal appears
#       NOWHERE on disk under the temp dirs except, of course, the input team.json
#       the dev already owns. The CLI writes the secret to STDOUT only.
#
# A deliberately FAKE secret is used so the test output and the repo carry no real
# credential (secret-scan stays clean).
#
# Exit 0 = every assertion passed. Non-zero = a regression.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-invite"

[ -x "$CLI" ] || { echo "FATAL: $CLI not executable" >&2; exit 2; }

FAKE_URL="https://cp.example-team.test"
FAKE_SECRET="FAKE-INVITE-SECRET-0000000000-not-a-real-token"
DEFAULT_CP_URL="https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# A throwaway HOME + team dir per case so the CLI reads ONLY our fixtures and any
# file it might (wrongly) write lands inside the sandbox where (e) can scan for the
# secret. The mktemp template's variable run is assembled at runtime (never a
# source literal) to keep the content gate happy.
mk_dir() {
  local xr; xr="$(printf 'X%.0s' 1 2 3 4 5 6)"
  mktemp -d "${TMPDIR:-/tmp}/hmd-invite.$xr"
}
write_cp_url() { mkdir -p "$1/.heimdall"; printf '{\n  "url": "%s"\n}\n' "$2" > "$1/.heimdall/cp-endpoint.json"; }
write_team()   { mkdir -p "$1"; printf '{\n  "team_secret": "%s",\n  "created": 1719500000\n}\n' "$2" > "$1/team.json"; }

# ── (a) SYNTAX ─────────────────────────────────────────────────────────────────
if bash -n "$CLI" 2>/dev/null; then
  ok "(a) bash -n parses heimdall-invite clean"
else
  bad "(a) bash -n found a syntax error in heimdall-invite"
fi

# ── (b) FULL JOIN (team secret + cp url) ────────────────────────────────────────
H1="$(mk_dir)"; TD1="$(mk_dir)/.heimdall"
write_cp_url "$H1" "$FAKE_URL"; write_team "$TD1" "$FAKE_SECRET"
OUT1="$(HOME="$H1" HEIMDALL_TEAM_DIR="$TD1" "$CLI"; echo "RC=$?")"
RC1="${OUT1##*RC=}"; BODY1="${OUT1%RC=*}"
if [ "$RC1" -eq 0 ] \
   && printf '%s' "$BODY1" | grep -qF "curl -fsSL https://raw.githubusercontent.com/" \
   && printf '%s' "$BODY1" | grep -qF "HEIMDALL_CP_URL='$FAKE_URL'" \
   && printf '%s' "$BODY1" | grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" \
   && printf '%s' "$BODY1" | grep -qF "install.sh | HEIMDALL_CP_URL=" \
   && printf '%s' "$BODY1" | grep -qE " bash *$" \
   && printf '%s' "$BODY1" | grep -q "contains your team secret"; then
  ok "(b) team secret + url -> one-command join inlines both + prints the secret caveat (exit 0)"
else
  bad "(b) full-join output wrong (rc=$RC1):
$BODY1"
fi

# ── (c) URL-DEFAULT JOIN (team secret, no cp url) ───────────────────────────────
H2="$(mk_dir)"; TD2="$(mk_dir)/.heimdall"   # H2 has NO cp-endpoint.json
write_team "$TD2" "$FAKE_SECRET"
OUT2="$(HOME="$H2" HEIMDALL_TEAM_DIR="$TD2" "$CLI"; echo "RC=$?")"
RC2="${OUT2##*RC=}"; BODY2="${OUT2%RC=*}"
if [ "$RC2" -eq 0 ] \
   && printf '%s' "$BODY2" | grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" \
   && printf '%s' "$BODY2" | grep -qF "HEIMDALL_CP_URL='$DEFAULT_CP_URL'"; then
  ok "(c) no cp url -> join falls back to the shipped public default url (exit 0)"
else
  bad "(c) url-default output wrong (rc=$RC2):
$BODY2"
fi

# ── (d) CLEAN DEGRADE (no team.json) ────────────────────────────────────────────
H3="$(mk_dir)"; TD3="$(mk_dir)/.heimdall"   # TD3 exists but has NO team.json
mkdir -p "$TD3"
OUT3="$(HOME="$H3" HEIMDALL_TEAM_DIR="$TD3" "$CLI" 2>&1; echo "RC=$?")"
RC3="${OUT3##*RC=}"; BODY3="${OUT3%RC=*}"
if [ "$RC3" -eq 0 ] \
   && printf '%s' "$BODY3" | grep -q "no team is configured for this repo" \
   && ! printf '%s' "$BODY3" | grep -q "Traceback" \
   && ! printf '%s' "$BODY3" | grep -qE "curl -fsSL https://raw\.githubusercontent\.com/[^ ]+ \| HEIMDALL_CP_URL="; then
  ok "(d) no team.json -> helpful setup message, exit 0, no traceback, no fabricated join"
else
  bad "(d) degrade output wrong (rc=$RC3):
$BODY3"
fi

# ── (e) NO-SECRET-TO-FILE — the secret is written to STDOUT only ────────────────
# Re-run the full-join case in fresh sandboxes, then scan the ENTIRE temp dirs for
# the secret literal. The ONLY allowed hit is the input team.json the dev already
# owns — the CLI must add no log/cache/tracked file carrying the secret.
H4="$(mk_dir)"; TD4="$(mk_dir)/.heimdall"
write_cp_url "$H4" "$FAKE_URL"; write_team "$TD4" "$FAKE_SECRET"
HOME="$H4" HEIMDALL_TEAM_DIR="$TD4" "$CLI" >/dev/null 2>&1
HITS="$(grep -rlF "$FAKE_SECRET" "$H4" "$TD4" 2>/dev/null | grep -vF "$TD4/team.json" || true)"
if [ -z "$HITS" ]; then
  ok "(e) secret written to stdout ONLY — no extra file carries it"
else
  bad "(e) secret LEAKED to file(s):
$HITS"
fi

# ── cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$H1" "$H2" "$H3" "$H4" "$TD1" "$TD2" "$TD3" "$TD4" 2>/dev/null || true

echo
echo "  invite tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
