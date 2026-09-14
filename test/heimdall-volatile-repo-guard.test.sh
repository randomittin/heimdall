#!/usr/bin/env bash
# heimdall-volatile-repo-guard.test.sh
#
# The incident this guard exists for: a clone at /private/tmp/rally-cc-aggregator
# held 16 local commits, no remote ever saw them, and macOS wiped /tmp on
# reboot -- all 16 gone. An "unpushed branches" flag had fired earlier that day
# and was ignored, because unpushed work in an ordinary durable clone is not an
# incident, it's just WIP. This test proves two properties:
#
#   1. DETECTION IS THE COMBINATION, NOT EITHER SIGNAL ALONE -- a volatile
#      location with unpushed work is CRITICAL; the same location with
#      everything pushed drops out of alarm; the same unpushed work in a
#      durable location is INFO only and still exits 0 (must never cry wolf
#      on ordinary WIP -- that is exactly the failure mode that preceded the
#      real incident).
#   2. THE ANTI-BRICK GUARANTEE -- a non-git directory, and any git plumbing
#      the tool cannot make sense of, exits 0 silently. A guard that panics
#      on every ordinary directory it's pointed at is worse than the bug.
#
# SAFETY: every repo this test touches is created fresh under mktemp -d and
# torn down on exit. Never touch the user's real repos in the test.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/heimdall-volatile-repo-guard"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMPROOT="$(mktemp -d)"
# mktemp -d resolves under $TMPDIR, which on macOS IS itself under
# /private/var/folders -- one of the guard's own volatile prefixes. Any fixture
# meant to represent a DURABLE location must live outside TMPROOT entirely, or
# the test would be asserting nothing (both "durable" and "volatile" fixtures
# would resolve as volatile). DURABLE_ROOT lives under $HOME instead, which is
# not covered by any volatile prefix.
DURABLE_ROOT="$HOME/.hmd-volguard-durable-test.$$"
mkdir -p "$DURABLE_ROOT"
trap 'rm -rf "$TMPROOT" "$DURABLE_ROOT"' EXIT

git config --global user.email >/dev/null 2>&1 || export GIT_CONFIG_GLOBAL=/dev/null
GIT_AUTHOR_NAME="hmd-test"
GIT_AUTHOR_EMAIL="hmd-test@example.invalid"
GIT_COMMITTER_NAME="hmd-test"
GIT_COMMITTER_EMAIL="hmd-test@example.invalid"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# mk_repo DIR -- git init a throwaway repo at DIR with one real commit.
mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  echo "hello" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -q -m "initial commit"
}

# mk_bare_remote DIR -- an init --bare repo to act as a real, local "remote".
mk_bare_remote() {
  local dir="$1"
  git init -q --bare "$dir"
}

# ── 1. volatile location + unpushed commits = CRITICAL, exit 1 ──
# This is the exact incident shape: /private/tmp is the real (symlink-
# resolved) location of macOS /tmp, wiped on reboot, holding work no
# remote has ever seen.
VOL_DIR="$(mktemp -d /private/tmp/hmd-volguard-test.XXXXXX)"
mk_repo "$VOL_DIR"
OUT="$("$GUARD" check --repo "$VOL_DIR" 2>&1)"
CODE=$?
if [ "$CODE" -eq 1 ] && printf '%s' "$OUT" | grep -qi "CRITICAL"; then
  ok "volatile location + unpushed commits -> CRITICAL, exit 1"
else
  bad "volatile location + unpushed commits -> CRITICAL, exit 1 (got exit=$CODE, out=$OUT)"
fi

# ── 2. same repo, fully pushed to a local bare remote -> no longer CRITICAL ──
# Proves the alarm is about UNSEEN commits, not merely "is this repo unpushed
# by convention" -- once a remote genuinely has everything, the CRITICAL
# finding must clear even though the location is still volatile.
REMOTE_DIR="$TMPROOT/bare-remote.git"
mk_bare_remote "$REMOTE_DIR"
git -C "$VOL_DIR" remote add origin "$REMOTE_DIR"
git -C "$VOL_DIR" push -q -u origin main
OUT="$("$GUARD" check --repo "$VOL_DIR" 2>&1)"
CODE=$?
if ! printf '%s' "$OUT" | grep -qi "CRITICAL"; then
  ok "fully pushed volatile repo -> no CRITICAL finding"
else
  bad "fully pushed volatile repo -> no CRITICAL finding (got exit=$CODE, out=$OUT)"
fi
if printf '%s' "$OUT" | grep -qi "HIGH"; then
  ok "fully pushed volatile repo still flags HIGH (location itself is still a standing hazard)"
else
  bad "fully pushed volatile repo still flags HIGH (out=$OUT)"
fi

# ── 3. unpushed commits in a DURABLE location = INFO only, exit 0 ──
# Ordinary WIP must not cry wolf -- this is the exact distinction the
# preceding "unpushed branches" flag failed to make.
DUR_DIR="$DURABLE_ROOT/durable-repo"
mk_repo "$DUR_DIR"
mk_bare_remote "$DURABLE_ROOT/durable-remote.git"
git -C "$DUR_DIR" remote add origin "$DURABLE_ROOT/durable-remote.git"
git -C "$DUR_DIR" push -q -u origin main
echo "more work" >> "$DUR_DIR/file.txt"
git -C "$DUR_DIR" commit -q -am "unpushed wip commit"
OUT="$("$GUARD" check --repo "$DUR_DIR" 2>&1)"
CODE=$?
if [ "$CODE" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi "CRITICAL\|HIGH RISK"; then
  ok "unpushed commits in durable location -> INFO only, exit 0"
else
  bad "unpushed commits in durable location -> INFO only, exit 0 (got exit=$CODE, out=$OUT)"
fi

# ── 4. non-git directory exits 0 silently ──
# Anti-brick guarantee: a guard that narrates every ordinary non-repo
# directory it's pointed at trains operators to ignore its stderr.
PLAIN_DIR="$TMPROOT/not-a-repo"
mkdir -p "$PLAIN_DIR"
OUT="$("$GUARD" check --repo "$PLAIN_DIR" 2>&1)"
CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  ok "non-git directory exits 0 silently"
else
  bad "non-git directory exits 0 silently (got exit=$CODE, out=$OUT)"
fi

# ── 5. repo with no remote at all is flagged as its own risk ──
# Zero remotes is not "zero unpushed commits" -- it's a clone with no
# offsite copy of anything, a severe risk independent of commit counting.
NOREMOTE_DIR="$TMPROOT/no-remote-repo"
mk_repo "$NOREMOTE_DIR"
OUT="$("$GUARD" check --repo "$NOREMOTE_DIR" 2>&1)"
CODE=$?
if printf '%s' "$OUT" | grep -qi "no remote"; then
  ok "repo with no remote configured is flagged"
else
  bad "repo with no remote configured is flagged (got exit=$CODE, out=$OUT)"
fi

# ── 6. no remote AND volatile location -> CRITICAL too ──
NOREMOTE_VOL_DIR="$(mktemp -d /private/tmp/hmd-volguard-test.XXXXXX)"
mk_repo "$NOREMOTE_VOL_DIR"
OUT="$("$GUARD" check --repo "$NOREMOTE_VOL_DIR" 2>&1)"
CODE=$?
if [ "$CODE" -eq 1 ] && printf '%s' "$OUT" | grep -qi "CRITICAL" && printf '%s' "$OUT" | grep -qi "no remote"; then
  ok "volatile location + no remote at all -> CRITICAL, exit 1"
else
  bad "volatile location + no remote at all -> CRITICAL, exit 1 (got exit=$CODE, out=$OUT)"
fi

# ── 7. remote URL credentials are never printed ──
# A remote URL can carry embedded creds (user:pass@host); this must never
# reach stdout/stderr in any form.
CRED_DIR="$TMPROOT/cred-repo"
mk_repo "$CRED_DIR"
mk_bare_remote "$TMPROOT/cred-remote.git"
git -C "$CRED_DIR" remote add origin "https://itsasecret:hunter2@example.invalid/cred-remote.git"
echo "wip" >> "$CRED_DIR/file.txt"
git -C "$CRED_DIR" commit -q -am "wip"
OUT="$("$GUARD" check --repo "$CRED_DIR" 2>&1)"
if printf '%s' "$OUT" | grep -q "hunter2"; then
  bad "remote credentials never printed (leaked password!)"
else
  ok "remote credentials never printed"
fi

# ── 8. --json output is valid JSON and reflects severity ──
JOUT="$("$GUARD" check --repo "$VOL_DIR" --json 2>&1)"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$JOUT" | jq -e '.severity' >/dev/null 2>&1; then
    ok "--json output is valid JSON with a severity field"
  else
    bad "--json output is valid JSON with a severity field (out=$JOUT)"
  fi
else
  if printf '%s' "$JOUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'severity' in d" 2>/dev/null; then
    ok "--json output is valid JSON with a severity field"
  else
    bad "--json output is valid JSON with a severity field (out=$JOUT)"
  fi
fi

# ── 9. explain subcommand prints runnable git commands, no crash, exit 0 ──
EOUT="$("$GUARD" explain --repo "$DUR_DIR" 2>&1)"
ECODE=$?
if [ "$ECODE" -eq 0 ] && printf '%s' "$EOUT" | grep -q "git clone" && printf '%s' "$EOUT" | grep -q "git push"; then
  ok "explain prints git clone/push remedy and exits 0"
else
  bad "explain prints git clone/push remedy and exits 0 (got exit=$ECODE, out=$EOUT)"
fi

# ── 10. explain on a no-remote repo suggests git remote add ──
EOUT2="$("$GUARD" explain --repo "$NOREMOTE_DIR" 2>&1)"
if printf '%s' "$EOUT2" | grep -q "git remote add"; then
  ok "explain on no-remote repo suggests git remote add"
else
  bad "explain on no-remote repo suggests git remote add (out=$EOUT2)"
fi

# ── 11. non-existent path exits 0 silently (fail open on bad input) ──
OUT="$("$GUARD" check --repo "$TMPROOT/does-not-exist" 2>&1)"
CODE=$?
if [ "$CODE" -eq 0 ]; then
  ok "non-existent path exits 0 (fail open)"
else
  bad "non-existent path exits 0 (fail open) (got exit=$CODE, out=$OUT)"
fi

# ── 12. --repo works both before and after the subcommand ──
OUT_AFTER="$("$GUARD" check --repo "$DUR_DIR" 2>&1)"
CODE_AFTER=$?
OUT_BEFORE="$("$GUARD" --repo "$DUR_DIR" check 2>&1)"
CODE_BEFORE=$?
if ! printf '%s' "$OUT_AFTER" | grep -qi "unrecognized" && \
   ! printf '%s' "$OUT_BEFORE" | grep -qi "unrecognized" && \
   [ "$CODE_AFTER" -eq "$CODE_BEFORE" ]; then
  ok "--repo works both before and after the subcommand"
else
  bad "--repo works both before and after the subcommand (after=$CODE_AFTER/$OUT_AFTER before=$CODE_BEFORE/$OUT_BEFORE)"
fi

# ── 13. Caches directory path is treated as volatile ──
CACHES_DIR="$TMPROOT/Library/Caches/hmd-cache-repo"
mk_repo "$CACHES_DIR"
OUT="$("$GUARD" check --repo "$CACHES_DIR" 2>&1)"
CODE=$?
if [ "$CODE" -eq 1 ] && printf '%s' "$OUT" | grep -qi "HIGH\|CRITICAL"; then
  ok "path under Caches/ is treated as volatile"
else
  bad "path under Caches/ is treated as volatile (got exit=$CODE, out=$OUT)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
