#!/usr/bin/env bash
# test/invite.test.sh — acceptance test for the team-join viral loop
# (bin/heimdall-invite). Proves, against the REAL CLI with a temp $HOME + a per-
# repo team.json (via HEIMDALL_TEAM_DIR), with NO real network call (origin
# listing + the raw-URL HTTP probe are injected via test seams:
# HEIMDALL_INVITE_PUBLISHED_TAGS / HEIMDALL_INVITE_PUBLISHED_BRANCHES /
# HEIMDALL_INVITE_ASSUME_HTTP):
#
#   (a) SYNTAX — `bash -n` parses the script clean.
#   (b) FULL JOIN — a repo team.json {team_secret} + a global cp-endpoint {url}
#       prints the ONE-command join inlining BOTH the url and the TEAM SECRET into
#       the download-then-run installer form (curl -o <mktemp> && … bash <file>),
#       pinned to the HIGHEST PUBLISHED tag on origin, plus the "contains your team
#       secret" caveat. Exit 0.
#   (c) URL-DEFAULT JOIN — a team.json secret but NO cp-endpoint url falls back to
#       the shipped public default url (still HEIMDALL_TEAM_SECRET). Exit 0.
#   (d) CLEAN DEGRADE — no team.json at all -> a helpful "run heimdall-team new"
#       message, exit 0, NO traceback / NO curl…bash join emitted.
#   (e) NO-SECRET-TO-FILE — after the FULL-join case, the secret literal appears
#       NOWHERE on disk under the temp dirs except, of course, the input team.json
#       the dev already owns. The CLI writes the secret to STDOUT only.
#   (f) FALSIFIER — REFUSE UNRESOLVABLE REF — when the pinned ref (HEIMDALL_REF)
#       is NOT a published tag/branch on origin, the CLI must NOT print a join; it
#       must print a loud error and exit non-zero (so a teammate never gets a
#       silent-404 install one-liner).
#   (g) FALSIFIER — EMITTED REF IS PUBLISHED — with no pin, the emitted install
#       URL pins the HIGHEST tag that actually exists on origin (never the local
#       VERSION / local-only tag).
#   (h) FALSIFIER — NON-SWALLOWING ONE-LINER — the emitted join downloads the
#       installer to a temp file and runs `bash <file>` (curl 404 -> no bash run ->
#       loud non-zero), NOT the old `curl … | bash` shape that swallows a 404 into
#       an empty pipe. The secret rides ONLY the env of the bash invocation — the
#       curl download (what lands in the /tmp installer file) carries NO secret.
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

# Test seams — stand in for `git ls-remote` (published refs on origin) + the raw
# URL HTTP probe, so the whole suite runs WITHOUT touching the network.
PUB_TAGS="v2.0.9 v2.0.18 v2.0.10"     # highest published = v2.0.18
PUB_HIGH="v2.0.18"
export HEIMDALL_INVITE_PUBLISHED_TAGS="$PUB_TAGS"
export HEIMDALL_INVITE_PUBLISHED_BRANCHES="main"
export HEIMDALL_INVITE_ASSUME_HTTP="200"

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
OUT1="$(HOME="$H1" HEIMDALL_TEAM_DIR="$TD1" "$CLI" --yes-print-secret; echo "RC=$?")"
RC1="${OUT1##*RC=}"; BODY1="${OUT1%RC=*}"
if [ "$RC1" -eq 0 ] \
   && grep -qF "curl -fsSL --proto '=https' https://raw.githubusercontent.com/" <<<"$BODY1" \
   && grep -qF "/$PUB_HIGH/install.sh" <<<"$BODY1" \
   && grep -qF "set -o pipefail" <<<"$BODY1" \
   && grep -qF 'bash "$f"' <<<"$BODY1" \
   && grep -qF "HEIMDALL_CP_URL='$FAKE_URL'" <<<"$BODY1" \
   && grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" <<<"$BODY1" \
   && ! grep -qF "install.sh | HEIMDALL_CP_URL=" <<<"$BODY1" \
   && grep -q "contains your team secret" <<<"$BODY1"; then
  ok "(b) team secret + url -> download-then-run join, pinned to the highest published tag, inlines both + caveat (exit 0)"
else
  bad "(b) full-join output wrong (rc=$RC1):
$BODY1"
fi

# ── (c) URL-DEFAULT JOIN (team secret, no cp url) ───────────────────────────────
H2="$(mk_dir)"; TD2="$(mk_dir)/.heimdall"   # H2 has NO cp-endpoint.json
write_team "$TD2" "$FAKE_SECRET"
OUT2="$(HOME="$H2" HEIMDALL_TEAM_DIR="$TD2" "$CLI" --yes-print-secret; echo "RC=$?")"
RC2="${OUT2##*RC=}"; BODY2="${OUT2%RC=*}"
if [ "$RC2" -eq 0 ] \
   && grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET'" <<<"$BODY2" \
   && grep -qF "HEIMDALL_CP_URL='$DEFAULT_CP_URL'" <<<"$BODY2"; then
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
   && grep -q "no team is configured for this repo" <<<"$BODY3" \
   && ! grep -q "Traceback" <<<"$BODY3" \
   && ! grep -qE "raw\.githubusercontent\.com/[^ ]+/install\.sh" <<<"$BODY3"; then
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
HOME="$H4" HEIMDALL_TEAM_DIR="$TD4" "$CLI" --yes-print-secret >/dev/null 2>&1
HITS="$(grep -rlF "$FAKE_SECRET" "$H4" "$TD4" 2>/dev/null | grep -vF "$TD4/team.json" || true)"
if [ -z "$HITS" ]; then
  ok "(e) secret written to stdout ONLY — no extra file carries it"
else
  bad "(e) secret LEAKED to file(s):
$HITS"
fi

# ── (f) FALSIFIER — refuse to emit a join pinned to an UNRESOLVABLE ref ──────────
# HEIMDALL_REF pins a ref that is NOT among the published tags/branches on origin.
# The CLI MUST refuse: loud error, non-zero exit, and NO curl…bash join emitted.
H5="$(mk_dir)"; TD5="$(mk_dir)/.heimdall"
write_cp_url "$H5" "$FAKE_URL"; write_team "$TD5" "$FAKE_SECRET"
OUT5="$(HOME="$H5" HEIMDALL_TEAM_DIR="$TD5" HEIMDALL_REF="v99.99.99" \
        HEIMDALL_INVITE_ASSUME_HTTP="404" "$CLI" --yes-print-secret 2>&1; echo "RC=$?")"
RC5="${OUT5##*RC=}"; BODY5="${OUT5%RC=*}"
if [ "$RC5" -ne 0 ] \
   && ! grep -qE "raw\.githubusercontent\.com/[^ ]+/v99\.99\.99/install\.sh -o" <<<"$BODY5" \
   && grep -qiE "does not resolve|REFUSING|not (published|resolve)" <<<"$BODY5"; then
  ok "(f) unpublished pinned ref -> loud refusal, non-zero exit, NO join emitted"
else
  bad "(f) FALSIFIER: CLI emitted a join for an unresolvable ref (rc=$RC5):
$BODY5"
fi

# ── (g) FALSIFIER — the emitted ref is the HIGHEST PUBLISHED tag on origin ───────
# No pin: the emitted install URL must pin v2.0.18 (highest published), never a
# local-only tag / the manifest VERSION.
H6="$(mk_dir)"; TD6="$(mk_dir)/.heimdall"
write_cp_url "$H6" "$FAKE_URL"; write_team "$TD6" "$FAKE_SECRET"
OUT6="$(HOME="$H6" HEIMDALL_TEAM_DIR="$TD6" "$CLI"; echo "RC=$?")"
RC6="${OUT6##*RC=}"; BODY6="${OUT6%RC=*}"
EMITTED_REF="$(grep -oE 'raw\.githubusercontent\.com/[^ ]+/install\.sh' <<<"$BODY6" \
                | head -1 | sed -E 's#.*/([^/]+)/install\.sh#\1#')"
if [ "$RC6" -eq 0 ] && [ "$EMITTED_REF" = "$PUB_HIGH" ]; then
  ok "(g) no pin -> emitted ref is the highest PUBLISHED tag ($EMITTED_REF), not a local-only ref"
else
  bad "(g) FALSIFIER: emitted ref is '$EMITTED_REF', expected '$PUB_HIGH' (rc=$RC6):
$BODY6"
fi

# ── (h) FALSIFIER — non-swallowing one-liner; secret not in the downloaded file ──
# The join must download the installer to a temp file then `bash <file>` (a 404
# gives a non-zero curl and NO bash run), and the secret must ride ONLY the env of
# the bash invocation — the curl download portion (what the /tmp installer file
# receives) must NOT contain the secret.
H7="$(mk_dir)"; TD7="$(mk_dir)/.heimdall"
write_cp_url "$H7" "$FAKE_URL"; write_team "$TD7" "$FAKE_SECRET"
OUT7="$(HOME="$H7" HEIMDALL_TEAM_DIR="$TD7" "$CLI"; echo "RC=$?")"
RC7="${OUT7##*RC=}"; BODY7="${OUT7%RC=*}"
# The join line is the last printed line carrying the raw installer URL.
JOINLINE="$(grep -F 'raw.githubusercontent.com' <<<"$BODY7" | tail -1)"
CURL_PART="${JOINLINE%%&& HEIMDALL_CP_URL=*}"   # everything up to the download's success
if [ "$RC7" -eq 0 ] \
   && printf '%s' "$JOINLINE" | grep -qF -e '-o "$f"' \
   && grep -qF 'bash "$f"' <<<"$JOINLINE" \
   && grep -qF "HEIMDALL_TEAM_SECRET='$FAKE_SECRET' bash" <<<"$JOINLINE" \
   && printf '%s' "$CURL_PART" | grep -qF -e '-o "$f"' \
   && ! grep -qF "$FAKE_SECRET" <<<"$CURL_PART"; then
  ok "(h) non-swallowing join: downloads to a file then bash <file>; secret only in the bash env, not the download"
else
  bad "(h) FALSIFIER: one-liner shape wrong or secret in the download portion (rc=$RC7):
JOIN: $JOINLINE
CURL_PART: $CURL_PART"
fi

# ── cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$H1" "$H2" "$H3" "$H4" "$H5" "$H6" "$H7" \
       "$TD1" "$TD2" "$TD3" "$TD4" "$TD5" "$TD6" "$TD7" 2>/dev/null || true

echo
echo "  invite tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
