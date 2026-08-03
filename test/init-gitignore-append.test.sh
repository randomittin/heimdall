#!/usr/bin/env bash
#
# init-gitignore-append.test.sh — `hmd init` must APPEND to a repo's .gitignore
# without ever damaging a line it does not own.
#
# WHAT THIS GATES. init keeps its transient local state out of the repo's git noise
# by appending three patterns to <repo>/.gitignore. That file belongs to the repo,
# not to Heimdall, so the append has exactly one correct behaviour: every pre-existing
# byte survives, and every pattern we add lands as its OWN whole line.
#
# THE FAILURE THIS EXISTS TO CATCH. A .gitignore whose last line carries no
# terminating newline is ordinary — plenty of editors and every `printf 'x' > .gitignore`
# produce one. Appending onto it with a bare `>>` concatenates our first pattern onto
# the repo's last line:
#
#     node_modules  +  .heimdall/verdict.json  ->  node_modules.heimdall/verdict.json
#
# That single line is a double loss. The repo STOPS ignoring node_modules (a pattern
# the dev wrote and we silently destroyed — git then offers to track the whole tree),
# and Heimdall never gets its verdict.json ignored either, because the pattern it
# merged into matches nothing. Nothing errors and init still exits 0, so the damage is
# silent — it surfaces later as an inexplicably dirty `git status`.
#
# It also defeats the dedupe: `grep -qxF` looks for the pattern as a WHOLE line, and
# the corrupt line is not one, so the next `hmd init` appends the pattern a second
# time. The file grows on every re-init and the corrupt line never heals.
#
# bin/heimdall-init already knows this hazard and guards it correctly for AGENTS.md
# ("without which the BEGIN marker would land mid-line and stop being a marker at
# all", write_agents_md). This gate holds the same wall for the sibling .gitignore
# writer in the same script.
#
# SAFETY. Every case runs `hmd init` inside a throwaway `mktemp -d` git repo with HOME
# and HEIMDALL_HOME redirected into that same temp dir, so no case can touch the real
# repo or the real ~/.heimdall (which holds a live team secret and PKI).
#
# Usage:  bash test/init-gitignore-append.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INIT="$ROOT/bin/heimdall-init"

[ -x "$INIT" ] || { echo "FATAL: heimdall-init missing at $INIT"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "init .gitignore append harness  repo=$ROOT"
echo "--------------------------------------------------------------------"

# The patterns bin/heimdall-init appends. Kept in sync with the `for pat in` loop
# there; a pattern renamed on one side and not the other goes RED on case 2.
PATTERNS=".heimdall/verdict.json .heimdall/receipts/ .heimdall/audit.json"

# new_repo <name> — a throwaway git repo with a fully redirected environment.
# Echoes the repo path. `timeout(1)` does not exist on macOS, hence perl's alarm.
new_repo() {
  local d="$WORK/$1"
  git init -q "$d" 2>/dev/null || return 1
  git -C "$d" config user.email heimdall-test@example.invalid
  git -C "$d" config user.name  "heimdall test"
  printf '%s' "$d"
}

run_init() {
  local d="$1"; shift
  ( cd "$d" \
    && HOME="$WORK/fakehome" HEIMDALL_HOME="$WORK/fakehome/.heimdall" \
       HEIMDALL_NO_UPDATE_CHECK=1 HEIMDALL_CP_URL="http://127.0.0.1:1" \
       perl -e 'alarm 90; exec @ARGV' -- bash "$INIT" "$@" ) >/dev/null 2>&1
}
mkdir -p "$WORK/fakehome/.heimdall"

# ══════════════════════════════════════════════════════════════════════════════
# 1. THE BUG: a .gitignore with NO trailing newline must not lose its last pattern
# ══════════════════════════════════════════════════════════════════════════════
R1="$(new_repo nonl)"
printf 'node_modules' > "$R1/.gitignore"          # deliberately unterminated
BEFORE="$(cat "$R1/.gitignore")"
run_init "$R1"; RC1=$?

[ "$RC1" = 0 ] && ok "1a init exits 0 on a repo with an unterminated .gitignore" \
               || bad "1a init exited $RC1"

# The repo's own pattern must still be a whole line — this is the byte the bug ate.
if grep -qxF 'node_modules' "$R1/.gitignore" 2>/dev/null; then
  ok "1b the repo's own final pattern survives as its own line"
else
  bad "1b init DESTROYED the repo's final .gitignore line" "$(head -3 "$R1/.gitignore")"
fi

# ...and it must still actually work as an ignore rule, which is the point of it.
mkdir -p "$R1/node_modules"; : > "$R1/node_modules/pkg.js"
if git -C "$R1" check-ignore -q node_modules/pkg.js 2>/dev/null; then
  ok "1c the repo's own rule still ignores what it was written to ignore"
else
  bad "1c node_modules is NO LONGER ignored — init silently broke the repo's rule"
fi

# The prior content must be preserved byte for byte (a restored newline is the ONLY
# edit init may make to lines it does not own).
if [ "$(head -1 "$R1/.gitignore")" = "$BEFORE" ]; then
  ok "1d prior content preserved byte for byte"
else
  bad "1d prior content was modified" "got: $(head -1 "$R1/.gitignore")"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. Every pattern init appends must land as its own WHOLE line, and must work
# ══════════════════════════════════════════════════════════════════════════════
_all=1
for pat in $PATTERNS; do
  grep -qxF "$pat" "$R1/.gitignore" 2>/dev/null || { _all=0; echo "        missing whole line: $pat" >&2; }
done
[ "$_all" = 1 ] && ok "2a every heimdall pattern is a whole line in .gitignore" \
                || bad "2a a heimdall pattern was swallowed mid-line"

mkdir -p "$R1/.heimdall"; : > "$R1/.heimdall/verdict.json"
if git -C "$R1" check-ignore -q .heimdall/verdict.json 2>/dev/null; then
  ok "2b the first appended pattern actually ignores its target"
else
  bad "2b .heimdall/verdict.json is NOT ignored — the pattern merged into a prior line"
fi

# No line may be a concatenation of the repo's content and one of our patterns.
if grep -q 'node_modules\.heimdall' "$R1/.gitignore" 2>/dev/null; then
  bad "2c a concatenated line exists" "$(grep 'node_modules\.heimdall' "$R1/.gitignore")"
else
  ok "2c no line concatenates repo content with a heimdall pattern"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. IDEMPOTENT: re-init must not duplicate patterns (the dedupe must still work)
# ══════════════════════════════════════════════════════════════════════════════
run_init "$R1"; run_init "$R1"
_dupe=0
for pat in $PATTERNS; do
  n="$(grep -cxF "$pat" "$R1/.gitignore" 2>/dev/null || echo 0)"
  [ "$n" = 1 ] || { _dupe=1; echo "        '$pat' appears $n times after re-init" >&2; }
done
[ "$_dupe" = 0 ] && ok "3a re-init does not duplicate any pattern" \
                 || bad "3a re-init duplicated a pattern — dedupe defeated by a corrupt line"
[ "$(grep -cxF 'node_modules' "$R1/.gitignore" 2>/dev/null || echo 0)" = 1 ] \
  && ok "3b the repo's own pattern is still present exactly once after 3 inits" \
  || bad "3b the repo's own pattern was lost or duplicated across re-inits"

# ══════════════════════════════════════════════════════════════════════════════
# 4. NO REGRESSION: a normally-terminated .gitignore is handled exactly as before
# ══════════════════════════════════════════════════════════════════════════════
R2="$(new_repo withnl)"
printf 'dist/\n*.log\n' > "$R2/.gitignore"
run_init "$R2"; RC2=$?
[ "$RC2" = 0 ] && ok "4a init exits 0 on a normally-terminated .gitignore" || bad "4a init exited $RC2"
grep -qxF 'dist/' "$R2/.gitignore" && grep -qxF '*.log' "$R2/.gitignore" \
  && ok "4b pre-existing terminated patterns survive" || bad "4b a terminated pattern was lost"
# No blank line may be introduced — we only add a newline where one was MISSING.
if grep -qx '' "$R2/.gitignore" 2>/dev/null; then
  bad "4c a blank line was inserted into an already-terminated file"
else
  ok "4c no spurious blank line inserted"
fi
_all=1
for pat in $PATTERNS; do grep -qxF "$pat" "$R2/.gitignore" || _all=0; done
[ "$_all" = 1 ] && ok "4d all heimdall patterns present" || bad "4d a heimdall pattern is missing"

# ══════════════════════════════════════════════════════════════════════════════
# 5. NO .gitignore AT ALL: init creates a clean one
# ══════════════════════════════════════════════════════════════════════════════
R3="$(new_repo nogi)"
run_init "$R3"; RC3=$?
[ "$RC3" = 0 ] && ok "5a init exits 0 with no pre-existing .gitignore" || bad "5a init exited $RC3"
_all=1
for pat in $PATTERNS; do grep -qxF "$pat" "$R3/.gitignore" 2>/dev/null || _all=0; done
[ "$_all" = 1 ] && ok "5b a fresh .gitignore holds every pattern as a whole line" \
                || bad "5b fresh .gitignore is malformed" "$(cat "$R3/.gitignore" 2>/dev/null)"
[ "$(head -c 1 "$R3/.gitignore" 2>/dev/null)" != "" ] \
  && ok "5c the fresh .gitignore does not begin with a blank line" \
  || bad "5c the fresh .gitignore begins with a blank line"

# ══════════════════════════════════════════════════════════════════════════════
# 6. An EMPTY .gitignore (0 bytes) must not gain a leading blank line
# ══════════════════════════════════════════════════════════════════════════════
R4="$(new_repo emptygi)"
: > "$R4/.gitignore"
run_init "$R4"
if [ "$(head -1 "$R4/.gitignore" 2>/dev/null)" = ".heimdall/verdict.json" ]; then
  ok "6a an empty .gitignore gains no leading blank line"
else
  bad "6a empty .gitignore got a leading blank line" "$(head -2 "$R4/.gitignore")"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 7. syntax
# ══════════════════════════════════════════════════════════════════════════════
bash -n "$INIT" 2>/dev/null && ok "7 bin/heimdall-init passes bash -n" || bad "7 heimdall-init has a syntax error"

echo "--------------------------------------------------------------------"
printf 'init-gitignore-append: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
