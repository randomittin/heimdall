#!/usr/bin/env bash
# test/heimdall-team.test.sh — acceptance for the per-repo TEAM secret manager
# (bin/heimdall-team), the CLIENT side of multi-tenant team presence.
#
# Proves, against the REAL CLI with a temp HEIMDALL_TEAM_DIR (no git needed) and
# NO network. Both are pinned by test seams, not by luck: `detect_visibility` is
# forced via HEIMDALL_FORCE_VISIBILITY (the same seam test/heimdall-team-default.
# test.sh and test/heimdall-telemetry.test.sh use) so `new`'s outcome never
# depends on the ambient repo's real GitHub visibility, `gh` auth, or the
# ~/.heimdall/vis-cache/ TTL cache of whatever repo happens to be checked out at
# CWD; and `new`'s heimdall-invite subprocess has its `git ls-remote` + raw-URL
# HTTP probe replaced by the same network-free seams test/invite.test.sh:52-58
# uses (HEIMDALL_INVITE_PUBLISHED_TAGS / _BRANCHES / _ASSUME_HTTP). Without both,
# this suite silently inherits whatever the operator's machine/network state
# happens to be — see the incident this header now documents in git blame.
#
# A THIRD, unrelated dependency bit this suite the same day the two above were
# fixed: heimdall-invite refuses to print the live team secret when ITS stdout
# is not a terminal (`[ -t 1 ]` — a security fix; see bin/heimdall-invite's NON-
# TTY REFUSAL). cmd_new (bin/heimdall-team) forwards ITS OWN `[ -t 1 ]` decision
# to invite as the literal --yes-print-secret flag (same idiom as cmd_auto's
# HMD_TEAM_AUTO_LOUD loud-mode check, bin/heimdall-team ~line 761). Because THIS
# harness captures `new`'s stdout via command substitution, every call below is
# non-tty by default — exactly the safe case (b3) proves. (b2)'s happy path
# instead simulates a human via HEIMDALL_TEAM_ASSUME_TTY, heimdall-team's own
# test-only stand-in for `[ -t 1 ]` (NOT invite's --yes-print-secret, which
# stays a deliberate flag only and is never itself settable via env).
#
#   (a) SYNTAX        — `bash -n` parses clean.
#   (b) NEW           — `new` writes a 0600 team.json carrying a 43-char base64url
#                       secret; AT A TERMINAL (simulated: HEIMDALL_TEAM_ASSUME_TTY)
#                       it also prints the heimdall-invite join one-liner
#                       (HEIMDALL_TEAM_SECRET) + a secret caveat. WITHOUT a
#                       terminal (this harness's own default) the live secret is
#                       NEVER printed — heimdall-invite's non-tty refusal, held.
#                       Exit 0 either way; only the PRINT is gated, never the mint.
#   (c) NO-CLOBBER    — a 2nd `new` REFUSES to overwrite an existing team without
#                       --force (exit 2, secret unchanged); `--force` re-mints.
#   (d) SHOW          — `show` (+ --json) prints the NON-SECRET team_id that
#                       matches the server derive byte-for-byte, configured=yes,
#                       and NEVER the secret.
#   (e) SHOW-ABSENT   — `show` with no team.json -> configured:false, exit 0, no
#                       secret, no traceback.
#   (f) JOIN          — `join <secret>` writes a 0600 team.json with a teammate's
#                       secret; a <32-char secret is REJECTED (exit 2).
#   (g) NO-SECRET-LEAK— after new/join, the secret literal appears in NO file
#                       under the team dir except team.json itself.
#
# A deliberately FAKE secret is used for the join case so the repo carries no real
# credential (secret-scan stays clean). The `new` secret is randomly minted at
# runtime (never a committed literal).
#
# Exit 0 = every assertion passed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/bin/heimdall-team"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python not found" >&2; exit 2; }
[ -x "$CLI" ] || { echo "FATAL: $CLI missing/!exec" >&2; exit 2; }

# Hermeticity seams — MUST be set before any `$CLI new` call. Without
# HEIMDALL_FORCE_VISIBILITY, `detect_visibility` (bin/heimdall-team) walks up
# from CWD to find a git repo and may consult `gh api` / a live curl probe /
# ~/.heimdall/vis-cache/<slug> — all real, ambient, cross-session state that has
# nothing to do with this suite. A repo the operator happens to be sitting in
# that resolves "private" flips `new` onto the commit-branch instead of the
# invite-one-liner branch it's meant to exercise here (and that branch's own
# `git add -f` silently no-ops on this suite's out-of-repo team.json, so nothing
# is even committed) — reproduced deterministically via
# `HEIMDALL_FORCE_VISIBILITY=private bash test/heimdall-team.test.sh`. "public"
# is the value that exercises the invite one-liner (b) documents; same seam as
# test/heimdall-team-default.test.sh:106 and test/heimdall-telemetry.test.sh:281.
# Without HEIMDALL_INVITE_PUBLISHED_TAGS/_BRANCHES/_ASSUME_HTTP, `new`'s
# heimdall-invite subprocess does a real `git ls-remote` against origin plus a
# real HTTPS probe of raw.githubusercontent.com for the resolved ref — a
# transient miss (a just-cut release tag not yet propagated to the raw-content
# CDN, a proxy, a network blip) makes heimdall-invite refuse (exit 3, nothing on
# stdout), which reads identically to a broken join line. Same seams as
# test/invite.test.sh:52-58.
export HEIMDALL_FORCE_VISIBILITY="public"
export HEIMDALL_INVITE_PUBLISHED_TAGS="v0.0.1"
export HEIMDALL_INVITE_PUBLISHED_BRANCHES="main"
export HEIMDALL_INVITE_ASSUME_HTTP="200"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d -t "heimdall-team.$(printf 'X%.0s' 1 2 3 4 5 6)")"
trap 'rm -rf "$WORK"' EXIT

# The canonical client/server team_id derive (MUST match the server byte-for-byte).
server_team_id() { # $1 = secret
  HMD_TST_SECRET="$1" "$PY" - <<'PYEOF'
import hashlib, os
s = os.environ["HMD_TST_SECRET"]
print(hashlib.sha256(b"heimdall-team\x00" + s.encode("utf-8")).hexdigest()[:32])
PYEOF
}
# Read the team_secret straight out of team.json (test-only — proves what landed).
secret_of() { # $1 = team.json path
  HMD_TST_FILE="$1" "$PY" - <<'PYEOF'
import json, os, sys
try:
    sys.stdout.write(json.load(open(os.environ["HMD_TST_FILE"])).get("team_secret") or "")
except Exception:
    sys.stdout.write("")
PYEOF
}
perm_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo '?'; }

# A FAKE secret (>=32 chars) for the join case — never a real credential.
FAKE_SECRET="FAKE-TEAM-SECRET-0000000000-not-a-real-token"

echo "============================================================"
echo "heimdall-team — per-repo team secret manager"
echo "============================================================"
echo

# ── (a) SYNTAX ──────────────────────────────────────────────────────────────
if bash -n "$CLI" 2>/dev/null; then
  ok "(a) bash -n parses heimdall-team clean"
else
  bad "(a) bash -n found a syntax error in heimdall-team"
fi

# ── (b) NEW mints a 0600 team.json + prints the join AT A TERMINAL ───────────
# HEIMDALL_TEAM_ASSUME_TTY=1 simulates "a human is watching" for THIS call only
# (a per-command env prefix, scoped exactly like HEIMDALL_TEAM_DIR below — never
# exported suite-wide, or every other call in this file would stop exercising
# the non-tty refusal (b3) below exists to prove).
TD1="$WORK/repo1/.heimdall"
NEW_OUT="$(HEIMDALL_TEAM_ASSUME_TTY=1 HEIMDALL_TEAM_DIR="$TD1" "$CLI" new 2>"$WORK/new1.err"; echo "RC=$?")"
RC="${NEW_OUT##*RC=}"; BODY="${NEW_OUT%RC=*}"
TJ1="$TD1/team.json"
S1="$(secret_of "$TJ1")"
if [ "$RC" -eq 0 ] && [ -f "$TJ1" ] && [ "$(perm_of "$TJ1")" = "600" ] && [ "${#S1}" -eq 43 ]; then
  ok "(b1) new wrote a 0600 team.json carrying a 43-char secret (${#S1} chars)"
else
  bad "(b1) new did not produce a 0600 43-char team.json (rc=$RC perm=$(perm_of "$TJ1") len=${#S1})"; cat "$WORK/new1.err" >&2
fi
if grep -q "HEIMDALL_TEAM_SECRET=" <<<"$BODY" \
   && grep -qF "curl -fsSL --proto '=https' https://raw.githubusercontent.com/" <<<"$BODY" \
   && grep -qi "team secret" <<<"$BODY"; then
  ok "(b2) new (at a terminal) printed the heimdall-invite join one-liner (HEIMDALL_TEAM_SECRET) + a secret caveat"
else
  bad "(b2) new did not print the join one-liner + caveat:
$BODY"
fi

# ── (b3) SECURITY — the SAME new, but with NO tty (this harness's own default,
# since it captures stdout via command substitution — no seam needed to prove
# it): the live secret must NEVER be printed. Asserted explicitly, with the
# real minted secret checked for literal absence, so a future change to
# cmd_new's forwarding logic cannot silently reintroduce the leak heimdall-
# invite's non-tty refusal exists to prevent. The failure branch deliberately
# never echoes the secret itself (booleans only), same discipline as (d2) above.
TD1_NOTTY="$WORK/repo1-notty/.heimdall"
NEW_NOTTY="$(HEIMDALL_TEAM_DIR="$TD1_NOTTY" "$CLI" new 2>"$WORK/new1-notty.err"; echo "RC=$?")"
RC1N="${NEW_NOTTY##*RC=}"; BODY1N="${NEW_NOTTY%RC=*}"
TJ1N="$TD1_NOTTY/team.json"
S1N="$(secret_of "$TJ1N")"
ERR1N="$(cat "$WORK/new1-notty.err" 2>/dev/null || true)"
if [ "$RC1N" -eq 0 ] && [ "${#S1N}" -eq 43 ] \
   && ! grep -qF -- "$S1N" <<<"$BODY1N" \
   && ! grep -q "HEIMDALL_TEAM_SECRET=" <<<"$BODY1N" \
   && grep -qi "REFUSING to print your live team secret" <<<"$ERR1N"; then
  ok "(b3) new WITHOUT a tty never printed the live secret (heimdall-invite refused)"
else
  bad "(b3) SECURITY: new without a tty must never print the secret (rc=$RC1N, secret-in-stdout=$(grep -qF -- "$S1N" <<<"$BODY1N" && echo YES-LEAKED || echo no), refusal-seen=$(grep -qi "REFUSING to print your live team secret" <<<"$ERR1N" && echo yes || echo no))"
fi

# ── (c) NO-CLOBBER without --force; --force re-mints ─────────────────────────
HEIMDALL_TEAM_DIR="$TD1" "$CLI" new 2>"$WORK/new2.err" >/dev/null; RC2="$?"
S1b="$(secret_of "$TJ1")"
if [ "$RC2" -ne 0 ] && [ "$S1b" = "$S1" ]; then
  ok "(c1) a 2nd new REFUSED to clobber (exit $RC2) and left the secret unchanged"
else
  bad "(c1) a 2nd new should refuse without --force (rc=$RC2, secret changed=$([ "$S1b" != "$S1" ] && echo yes || echo no))"
fi
HEIMDALL_TEAM_DIR="$TD1" "$CLI" new --force >/dev/null 2>&1; RC3="$?"
S1c="$(secret_of "$TJ1")"
if [ "$RC3" -eq 0 ] && [ -n "$S1c" ] && [ "$S1c" != "$S1" ]; then
  ok "(c2) new --force re-minted a fresh secret"
else
  bad "(c2) new --force did not re-mint (rc=$RC3, changed=$([ "$S1c" != "$S1" ] && echo yes || echo no))"
fi

# ── (d) SHOW prints the team_id (matches server derive), never the secret ────
EXPECT_TID="$(server_team_id "$S1c")"
SHOW_TXT="$(HEIMDALL_TEAM_DIR="$TD1" "$CLI" show 2>/dev/null)"
SHOW_JSON="$(HEIMDALL_TEAM_DIR="$TD1" "$CLI" show --json 2>/dev/null)"
JSON_TID="$(printf '%s' "$SHOW_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("team_id") or "")' 2>/dev/null || true)"
if [ -n "$EXPECT_TID" ] && [ "$JSON_TID" = "$EXPECT_TID" ] && grep -qF "$EXPECT_TID" <<<"$SHOW_TXT"; then
  ok "(d1) show prints the team_id matching the server derive ($EXPECT_TID)"
else
  bad "(d1) show team_id mismatch (expect=$EXPECT_TID json=$JSON_TID txt=$SHOW_TXT)"
fi
if ! grep -qF -- "$S1c" <<<"$SHOW_TXT$SHOW_JSON"; then
  ok "(d2) show NEVER prints the secret (text + --json)"
else
  bad "(d2) show LEAKED the secret"
fi

# ── (e) SHOW with no team.json -> not configured, exit 0 ─────────────────────
TD_EMPTY="$WORK/empty/.heimdall"
SE_TXT="$(HEIMDALL_TEAM_DIR="$TD_EMPTY" "$CLI" show 2>"$WORK/showempty.err"; echo "RC=$?")"
RCE="${SE_TXT##*RC=}"; SEB="${SE_TXT%RC=*}"
SE_JSON="$(HEIMDALL_TEAM_DIR="$TD_EMPTY" "$CLI" show --json 2>/dev/null)"
CONF="$(printf '%s' "$SE_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("configured"))' 2>/dev/null || true)"
if [ "$RCE" -eq 0 ] && [ "$CONF" = "False" ] && [ ! -s "$WORK/showempty.err" ]; then
  ok "(e) show with no team.json -> configured:false, exit 0, no traceback"
else
  bad "(e) show-absent wrong (rc=$RCE configured=$CONF):
$SEB"
fi

# ── (f) JOIN writes the teammate's secret; rejects a weak one ────────────────
TD2="$WORK/repo2/.heimdall"
HEIMDALL_TEAM_DIR="$TD2" "$CLI" join "$FAKE_SECRET" >/dev/null 2>"$WORK/join.err"; RCJ="$?"
TJ2="$TD2/team.json"
SJ="$(secret_of "$TJ2")"
if [ "$RCJ" -eq 0 ] && [ "$SJ" = "$FAKE_SECRET" ] && [ "$(perm_of "$TJ2")" = "600" ]; then
  ok "(f1) join wrote the teammate's secret to a 0600 team.json"
else
  bad "(f1) join did not store the secret 0600 (rc=$RCJ perm=$(perm_of "$TJ2"))"; cat "$WORK/join.err" >&2
fi
TD3="$WORK/repo3/.heimdall"
HEIMDALL_TEAM_DIR="$TD3" "$CLI" join "tooshort" >/dev/null 2>/dev/null; RCW="$?"
if [ "$RCW" -ne 0 ] && [ ! -f "$TD3/team.json" ]; then
  ok "(f2) join REJECTED a <32-char secret (exit $RCW, wrote nothing)"
else
  bad "(f2) join should reject a weak secret (rc=$RCW, wrote=$([ -f "$TD3/team.json" ] && echo yes || echo no))"
fi

# ── (g) the secret lives in team.json ONLY ───────────────────────────────────
HITS="$(grep -rlF "$FAKE_SECRET" "$WORK/repo2" 2>/dev/null | grep -vF "$TJ2" || true)"
if [ -z "$HITS" ]; then
  ok "(g) the joined secret appears in NO file but team.json"
else
  bad "(g) the secret LEAKED to other file(s):
$HITS"
fi

echo
echo "============================================================"
printf "heimdall-team: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
