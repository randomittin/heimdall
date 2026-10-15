#!/usr/bin/env bash
# test/heimdall-nested-state-gitignore.test.sh — falsifiable proof that heimdall RUNTIME STATE
# cannot be committed from a NESTED directory, and that none already is.
#
# WHY THIS EXISTS: `.heimdall/*` has a slash in it, so git anchors the rule to the repo ROOT.
# A heimdall tool run with its cwd inside a subtree (statusline / presence / roster / wall caches)
# writes its own `.heimdall/` THERE; the root-only rule never saw it, and a wip auto-checkpoint
# (`git add -A`) committed skills/designmatch/.heimdall/* (1acd792b). Separately,
# packages/runheimdall/heimdall-state.json was committed by a release sync (4cd73d4c) that predates
# the heimdall-state.json ignore rule — and an ignore rule never un-tracks a committed file, so only
# a tracked-set assertion (claim 4) can catch that half.
#
# The repo's REAL .gitignore is copied VERBATIM into hermetic fixture repos (never reimplemented
# here), so a future edit that narrows the rule fails THIS test, not just goes unnoticed. Same
# technique as test/heimdall-scratch-gitignore.test.sh.
#
# FALSIFIABLE CLAIMS:
#   (1) `git add -A` stages nothing under a `.heimdall/` at ANY depth and no heimdall-state.json at
#       any depth, while look-alike names still stage (the rule is not over-broad).
#   (2) The root exceptions still work (the two committed .example files and team.shared.json are NOT
#       ignored at the root) and the same names one level down ARE ignored — the un-ignores are
#       root-anchored on purpose: only the root examples are source, and a nested team.shared.json
#       would be a team secret.
#   (3) PROVE-DETECTS: against a root-only variant of the rule — derived from the real file, not
#       hard-coded — the nested file IS staged, so claim (1) can go red.
#   (4) THIS repo tracks nothing that `git ls-files | grep -E '(^|/)\.heimdall/|heimdall-state\.json'`
#       matches, except the two committed root `.heimdall/*.example` templates that .gitignore
#       un-ignores by name. That allowlist is EXACT both ways: a tracked match outside it fails, and
#       an allowlisted path that is no longer tracked fails too, so a stale entry cannot linger and
#       quietly widen what is let through. The filter is itself probed against planted offenders
#       (nested state, root hooks / repo-checks.json, a state file and its .lock) and look-alikes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GITIGNORE_SRC="$ROOT/.gitignore"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -f "$GITIGNORE_SRC" ] || { echo "FATAL: $GITIGNORE_SRC missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 2; }

WORK="$(mktemp -d -t "nested-state-gitignore-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# fixture <name> <gitignore-file> — a fresh repo seeded with that .gitignore; prints its path.
fixture() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@runheimdall.dev"
  git -C "$dir" config user.name "test"
  cp "$2" "$dir/.gitignore"
  git -C "$dir" add .gitignore
  git -C "$dir" commit -qm seed
  printf '%s' "$dir"
}

# put <repo> <relpath>... — create each file (parent dirs included).
put() {
  local repo="$1" rel
  shift
  for rel in "$@"; do
    mkdir -p "$repo/$(dirname "$rel")"
    printf 'x\n' > "$repo/$rel"
  done
}

# staged <repo> — run what the auto-checkpoint hook runs (`git add -A`), list what got staged.
staged() {
  git -C "$1" add -A
  git -C "$1" diff --cached --name-only
}

echo "-- (1) nested runtime state is never staged by git add -A --------------------"
F1="$(fixture real "$GITIGNORE_SRC")"
put "$F1" \
  skills/designmatch/.heimdall/.roster-cache.json \
  skills/designmatch/.heimdall/.beat-stamp \
  a/b/c/.heimdall/x \
  .heimdall/foo \
  packages/runheimdall/heimdall-state.json \
  heimdall-state.json \
  skills/designmatch/SKILL.md \
  skills/designmatch/x.heimdall/keep.txt
STAGED1="$(staged "$F1")"
for p in skills/designmatch/.heimdall/.roster-cache.json skills/designmatch/.heimdall/.beat-stamp \
         a/b/c/.heimdall/x .heimdall/foo packages/runheimdall/heimdall-state.json heimdall-state.json; do
  if printf '%s\n' "$STAGED1" | grep -qxF "$p"; then
    bad "git add -A staged runtime state: $p"
  else
    ok "$p is not staged"
  fi
done
for p in skills/designmatch/SKILL.md skills/designmatch/x.heimdall/keep.txt; do
  if printf '%s\n' "$STAGED1" | grep -qxF "$p"; then
    ok "look-alike $p still stages (rule is not over-broad)"
  else
    bad "the ignore rule swallowed a real source path: $p"
  fi
done

echo "-- (2) root exceptions intact; the same names nested stay ignored ------------"
F2="$(fixture exceptions "$GITIGNORE_SRC")"
put "$F2" \
  .heimdall/cp-endpoint.json.example \
  .heimdall/issue-loop.config.json.example \
  .heimdall/team.shared.json \
  skills/designmatch/.heimdall/cp-endpoint.json.example \
  skills/designmatch/.heimdall/team.shared.json
STAGED2="$(staged "$F2")"
for p in .heimdall/cp-endpoint.json.example .heimdall/issue-loop.config.json.example .heimdall/team.shared.json; do
  if printf '%s\n' "$STAGED2" | grep -qxF "$p"; then
    ok "root exception $p stages"
  else
    bad "root exception $p is ignored — its un-ignore stopped working"
  fi
done
for p in skills/designmatch/.heimdall/cp-endpoint.json.example skills/designmatch/.heimdall/team.shared.json; do
  if printf '%s\n' "$STAGED2" | grep -qxF "$p"; then
    bad "nested $p staged — the un-ignores must stay root-anchored"
  else
    ok "nested $p stays ignored"
  fi
done

echo "-- (3) PROVE-DETECTS: the pre-fix, root-only rule DOES leak the nested file ---"
ROOT_ONLY="$WORK/gitignore.root-only"
sed 's#^\*\*/\.heimdall/\*$#.heimdall/*#' "$GITIGNORE_SRC" > "$ROOT_ONLY"
if cmp -s "$GITIGNORE_SRC" "$ROOT_ONLY"; then
  bad "the probe rewrote nothing — .gitignore has no '**/.heimdall/*' line, so this red leg would be vacuous"
else
  F3="$(fixture rootonly "$ROOT_ONLY")"
  put "$F3" skills/designmatch/.heimdall/.roster-cache.json
  STAGED3="$(staged "$F3")"
  if printf '%s\n' "$STAGED3" | grep -qxF skills/designmatch/.heimdall/.roster-cache.json; then
    ok "root-only rule stages skills/designmatch/.heimdall/.roster-cache.json — claim (1) can go red"
  else
    bad "root-only rule did NOT leak the nested file — claim (1) cannot detect the defect it guards"
  fi
fi

echo "-- (4) THIS repo tracks no runtime state beyond the root example allowlist ----"
# Everything the tracked-state sweep matches is runtime state, EXCEPT the committed root EXAMPLES
# below (shape + env-var NAMES, never secrets) that .gitignore un-ignores by name. They stay put
# because they are path-coupled: bin/lib/issue_config.py example_path() hard-codes
# <repo>/.heimdall/<example>, and test/public-repo-no-secrets.test.sh (Proof B),
# test/install-cp-endpoint.test.sh and test/issue-config.test.sh all expect them there. Moving them
# is a separate, coordinated change — edit this list in that change, not before. The allowlist is
# EXACT both ways: a tracked match outside it fails, and an entry that is no longer tracked fails
# too, so a stale line cannot linger and quietly widen what is let through.
ALLOWED_ROOT=(.heimdall/cp-endpoint.json.example .heimdall/issue-loop.config.json.example)

# leaked — filter a tracked-path list (stdin) down to the offenders (stdout).
leaked() {
  local keep=() p
  for p in "${ALLOWED_ROOT[@]}"; do keep+=(-e "$p"); done
  grep -E '(^|/)\.heimdall/|heimdall-state\.json' | grep -vxF "${keep[@]}" || true
}

PLANTED="$(printf '%s\n' \
  skills/x/.heimdall/.beat-stamp .heimdall/hooks/pre-push .heimdall/repo-checks.json \
  pkg/heimdall-state.json pkg/heimdall-state.json.lock \
  .heimdall/cp-endpoint.json.example .heimdall/issue-loop.config.json.example \
  bin/heimdall-state skills/x/not.heimdall/a | leaked)"
EXPECT="$(printf '%s\n' \
  skills/x/.heimdall/.beat-stamp .heimdall/hooks/pre-push .heimdall/repo-checks.json \
  pkg/heimdall-state.json pkg/heimdall-state.json.lock)"
if [ "$PLANTED" = "$EXPECT" ]; then
  ok "PROVE-DETECTS: the filter flags nested state, root hooks / repo-checks.json and heimdall-state.json[.lock]; spares the two root examples and look-alikes"
else
  bad "the offender filter is wrong — it flagged: $(printf '%s' "$PLANTED" | tr '\n' ' ')"
fi

TRACKED="$(git -C "$ROOT" ls-files 2>/dev/null)"
if [ -z "$TRACKED" ]; then
  bad "git ls-files returned nothing at $ROOT — a 'clean' verdict here would be vacuous"
else
  LEAKS="$(printf '%s\n' "$TRACKED" | leaked)"
  if [ -z "$LEAKS" ]; then
    ok "no tracked runtime state beyond the allowlist ($(printf '%s\n' "$TRACKED" | grep -c '') tracked files scanned)"
  else
    bad "tracked runtime state outside the allowlist: $(printf '%s' "$LEAKS" | tr '\n' ' ')"
  fi
  # Here-string, not a pipe: TRACKED is large and `grep -q` exits at its first match, which under
  # pipefail turns the writer's EPIPE into a false "not tracked".
  for p in "${ALLOWED_ROOT[@]}"; do
    if grep -qxF "$p" <<<"$TRACKED"; then
      ok "allowlisted $p is tracked (no stale entry)"
    else
      bad "allowlisted $p is not tracked — drop it from ALLOWED_ROOT so the allowlist stays exact"
    fi
  done
fi

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
