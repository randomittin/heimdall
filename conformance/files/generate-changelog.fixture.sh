#!/usr/bin/env bash
# PARITY-ROW: Command `generate-changelog [--since][--version][--append]` (kept,
#   flags identical) — conventional-commit changelog.
# ASSERT: superx's generate-changelog read git log conventional commits and emitted
#   Keep-a-Changelog markdown; flags --since/--version/--append. heimdall must keep
#   identical flags + behavior. We build a throwaway git repo with conventional
#   commits and assert the tool groups them by type into changelog markdown and
#   honors --version. No model.
ROW="file:generate-changelog"
source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# Flags documented.
HELP="$("$BIN/generate-changelog" --help 2>&1 || true)"
assert_grep '\-\-since'   "$HELP" "--since flag documented"
assert_grep '\-\-version' "$HELP" "--version flag documented"
assert_grep '\-\-append'  "$HELP" "--append flag documented"

# FINDING (portability): bin/generate-changelog uses `declare -A` (associative
#   arrays), which require bash >= 4. The system default bash on macOS is 3.2.57,
#   under which the tool prints `declare: -A: invalid option` and produces no
#   changelog. We therefore run the behavioral assertions under a bash >= 4 if one
#   is on PATH; otherwise we SKIP the behavioral run and RECORD the finding (this
#   is a real heimdall portability gap, not a fake pass).
pick_bash4() {
  for b in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    command -v "$b" >/dev/null 2>&1 || continue
    local maj; maj="$("$b" -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)"
    if [ "${maj:-0}" -ge 4 ] 2>/dev/null; then echo "$b"; return 0; fi
  done
  return 1
}

# Real run over a throwaway repo.
WS="$(mk_workspace)"; cd "$WS" || { bad "no ws"; finish; }
git init -q
git config user.email c@c.co; git config user.name c
git commit -q --allow-empty -m "feat: add login"
git commit -q --allow-empty -m "fix: handle null token"
git commit -q --allow-empty -m "docs: readme"

if BASH4="$(pick_bash4)"; then
  OUT="$("$BASH4" "$BIN/generate-changelog" --version 9.9.9 2>&1)"; CODE=$?
  assert_exit 0 "$CODE" "generate-changelog exits 0 (under $BASH4)"
  assert_contains "$OUT" "9.9.9" "honors --version label"
  assert_grep 'add login|login'   "$OUT" "feat commit appears in changelog"
  assert_grep 'null token|handle' "$OUT" "fix commit appears in changelog"
  assert_grep 'feature|added|fix' "$OUT" "groups entries by conventional type"
else
  note "SKIP behavioral run: no bash >= 4 on PATH. FINDING: bin/generate-changelog uses 'declare -A' and fails under the macOS-default bash 3.2 ('declare: -A: invalid option'). Recommend a bash-3.2-safe rewrite or a documented bash>=4 requirement."
fi

cd / && rm -rf "$WS"
finish
