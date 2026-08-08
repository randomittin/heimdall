#!/usr/bin/env bash
# test/land-stale-push-guard.test.sh — `hmd land` must never report a land it did not do.
#
# THE DEFECT. bin/heimdall-land advanced local main with
#     git -C "$REPO" branch -f "$MAIN" "$LANDED_SHA" >/dev/null 2>&1 || true
# and then pushed refs/heads/$MAIN regardless. git REFUSES `branch -f` on a branch
# that is checked out in another worktree ("fatal: cannot force update the branch
# 'main' used by worktree at …", rc 128) — the normal layout for a Heimdall user,
# who keeps main in one worktree and works in another. The `|| true` ate that, so:
#
#   local main  : unchanged (still the pre-land sha)
#   the push    : pushes that unchanged ref, succeeds trivially, rc 0
#   remote main : unchanged
#   land        : logs "pushed 'main' to origin (auto-land …)" and exits 0 "landed"
#
# Measured end to end before the fix: old main == landed local main == remote main,
# while a genuinely different landed_sha was reported. The merge went nowhere and
# the tool said it shipped. That is a fail-OPEN on the one operation land exists to
# perform, and the failure is silent by construction.
#
# CONTRACT PINNED HERE: if local main cannot be advanced, land STOPS (decision
# "stopped", nonzero exit) instead of pushing a stale ref. The happy path must keep
# working, so the falsifier below lands for real and checks the remote moved.
#
# NO REAL-REPO MUTATION: every git write targets a mktemp tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAND="$ROOT/bin/heimdall-land"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$LAND" ] || { echo "FATAL: $LAND not executable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-land-stale-XXXXXX")"
[ -n "$WORK" ] || { echo "FATAL: WORK path empty (mktemp failed)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# mkrepo NAME — bare upstream + clone with main pushed + a feature branch checked
# out in the clone carrying one new commit. Echoes "<bare> <clone> <feature-sha>".
mkrepo() {
  local n="$1" bare clone
  bare="$WORK/$n.git"; clone="$WORK/$n"
  [ -n "$bare" ] || { echo "FATAL: bare path empty" >&2; exit 1; }
  git init -q --bare "$bare"
  git clone -q "$bare" "$clone" 2>/dev/null
  git -C "$clone" config user.email land@test.local
  git -C "$clone" config user.name  land-test
  printf 'base\n' > "$clone/base.txt"
  git -C "$clone" add -A >/dev/null
  git -C "$clone" commit -qm "init"
  git -C "$clone" branch -M main
  git -C "$clone" push -q -u origin main 2>/dev/null
  git -C "$clone" checkout -q -b feat
  printf 'feature\n' > "$clone/feature.txt"
  git -C "$clone" add -A >/dev/null
  git -C "$clone" commit -qm "feat: add feature"
  printf '%s %s %s' "$bare" "$clone" "$(git -C "$clone" rev-parse HEAD)"
}

remote_main() { git -C "$1" rev-parse main 2>/dev/null || echo none; }

# ══════════════════════════════════════════════════════════════════════════════
# 0. PREMISE — git really does refuse `branch -f` on a branch held by another
#    worktree. If git ever stops refusing, this file's whole subject is gone and
#    it should say so here rather than pass for the wrong reason.
# ══════════════════════════════════════════════════════════════════════════════
read -r BARE0 CLONE0 SHA0 <<<"$(mkrepo p0)"
git -C "$CLONE0" worktree add -q "$WORK/p0-main" main >/dev/null 2>&1
if git -C "$CLONE0" branch -f main "$SHA0" >/dev/null 2>&1; then
  bad "premise: git ALLOWED branch -f on a branch checked out in another worktree"
else
  ok "premise: git refuses branch -f while another worktree holds that branch"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1. THE BUG — main held by another worktree. land must STOP, not fake a land.
# ══════════════════════════════════════════════════════════════════════════════
read -r BARE1 CLONE1 SHA1 <<<"$(mkrepo p1)"
git -C "$CLONE1" worktree add -q "$WORK/p1-main" main >/dev/null 2>&1
BEFORE_REMOTE="$(remote_main "$BARE1")"
BEFORE_LOCAL="$(git -C "$CLONE1" rev-parse main)"

V="$("$LAND" --repo "$CLONE1" --branch feat --gate-cmd "true" --json 2>"$WORK/p1.err")"
RC=$?
DECISION="$(printf '%s' "$V" | jq -r '.decision // ""' 2>/dev/null)"
REASON="$(printf '%s' "$V" | jq -r '.reason // ""' 2>/dev/null)"
AFTER_REMOTE="$(remote_main "$BARE1")"
AFTER_LOCAL="$(git -C "$CLONE1" rev-parse main)"

if [ "$DECISION" = "stopped" ]; then
  ok "land STOPS when local main cannot be advanced (decision=stopped)"
else
  bad "land reported decision='$DECISION' (expected 'stopped') — it claimed a land it did not perform"
fi

if [ "$RC" -ne 0 ]; then
  ok "land exits nonzero in that case (rc=$RC)"
else
  bad "land exited 0 while the landed commit never reached main — fail-OPEN"
fi

case "$REASON" in
  *main*) ok "stop reason names the unadvanced main branch: \"$REASON\"" ;;
  *)      bad "stop reason does not explain the failure: \"$REASON\"" ;;
esac

# The invariant that actually matters: no stale ref was published as a land.
if [ "$AFTER_REMOTE" = "$BEFORE_REMOTE" ] && [ "$AFTER_LOCAL" = "$BEFORE_LOCAL" ]; then
  ok "neither local nor remote main was moved (no stale ref published)"
else
  bad "refs moved despite the failure (local $BEFORE_LOCAL→$AFTER_LOCAL, remote $BEFORE_REMOTE→$AFTER_REMOTE)"
fi

# The silent-success signature must be gone: land must not log a push it didn't make.
if ! grep -q "pushed '\?main'\? to" "$WORK/p1.err" 2>/dev/null; then
  ok "land does not log a shared-main push it never performed"
else
  bad "land logged a shared-main push while main was never advanced"
  head -20 "$WORK/p1.err" >&2
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. FALSIFIER — the happy path must still land for real. A guard that stops
#    everything would pass §1 while destroying the tool.
# ══════════════════════════════════════════════════════════════════════════════
read -r BARE2 CLONE2 SHA2 <<<"$(mkrepo p2)"
BEFORE_REMOTE2="$(remote_main "$BARE2")"

V2="$("$LAND" --repo "$CLONE2" --branch feat --gate-cmd "true" --json 2>"$WORK/p2.err")"
RC2=$?
DECISION2="$(printf '%s' "$V2" | jq -r '.decision // ""' 2>/dev/null)"
LANDED2="$(printf '%s' "$V2" | jq -r '.landed_sha // ""' 2>/dev/null)"
AFTER_REMOTE2="$(remote_main "$BARE2")"

if [ "$DECISION2" = "landed" ] && [ "$RC2" -eq 0 ]; then
  ok "falsifier: a normal repo still lands (decision=landed, rc=0)"
else
  bad "falsifier: the guard broke the happy path (decision='$DECISION2', rc=$RC2)"
  head -20 "$WORK/p2.err" >&2
fi

if [ "$AFTER_REMOTE2" != "$BEFORE_REMOTE2" ] && [ "$AFTER_REMOTE2" = "$LANDED2" ]; then
  ok "falsifier: remote main actually advanced to the landed sha (a REAL land)"
else
  bad "falsifier: remote main did not advance to landed_sha (before=$BEFORE_REMOTE2 after=$AFTER_REMOTE2 landed=$LANDED2)"
fi

# 2b. local main advanced too — the reported land matches the repo's real state.
if [ "$(git -C "$CLONE2" rev-parse main)" = "$LANDED2" ]; then
  ok "falsifier: local main advanced to the landed sha"
else
  bad "falsifier: local main does not match landed_sha"
fi

printf "\n  land-stale-push-guard: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
