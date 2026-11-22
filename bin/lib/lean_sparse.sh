#!/usr/bin/env bash
# bin/lib/lean_sparse.sh -- the lean install payload (3.x lean-core plan, task T2.4: docs/superpowers/plans/2026-11-12-3x-lean-core.md).
#
# A lean install is the plugin clone with a SPARSE CHECKOUT. Every git object stays in .git (a depth-1 clone keeps all of them), so whatever the lean tree
# lacks is one local `add` away and nothing here ever needs the network (INV-L4). Claude Code loads this plugin IN PLACE from the clone and finds skills/ and
# commands/ by a directory scan (docs/analysis/2026-11-12-lean-plugin-dist.md, ...-lean-agent-override.md): a removed skill directory is simply not listed,
# there is nothing to unregister.
#
#   bash lean_sparse.sh apply lean <dir>     narrow the clone at <dir> to the lean set; idempotent; keeps every path `add` put back
#   bash lean_sparse.sh apply full <dir>     the full tree again (INV-L6: git sparse-checkout disable); idempotent; a clone that never was lean is not touched
#   bash lean_sparse.sh add <path> [<dir>]   put one tracked path (a skill directory, a file) back; <dir> defaults to the clone this script lives in
#
# THE LEAN SET is derived from HEAD of the clone, never from the work tree:
#     release/runtime-files.txt       what the code can reach (bin/heimdall-runtime-closure). "Reachable", not "lean": it names skills/ whole.
#   + the convention-loaded core      Claude Code reads these by name and no file names them: .claude-plugin/ agents/ commands/ hooks/ skills/heimdall/ and
#                                     settings.json, .mcp.json (the heimdall-ledger MCP server), LICENSE (a lean tree is still a copy of the software)
#   - the on-demand skills            skills/{stacks,designmatch,self-improve,system-health,mac-deep-clean}
#   + what `add` recorded             .git/info/hmd-lean-on-demand, one path per line (a re-apply, an upgrade, lean off then on: all keep it)
# test/ and docs/ are out because nothing reachable names them. The few docs/ files the closure DOES name stay: bin/lib/companion_cc_login.py reads
# docs/samples/login/allowlist.json at run time, and without it every login URL is refused. .planning/ is never runtime.
#
# NEVER DISCARDS WORK. git keeps a locally modified file the lean set would drop (it warns) and never touches an untracked file, so ledger, receipts,
# memory, team, pairing and data/ in the same directory are untouched (INV-L10). It refuses anything but the ROOT of a standalone clone (a subdirectory of
# another repository, a linked worktree whose config is shared), and a failed update puts the previous tree back.
#
# Exit: 0 done (or nothing to do) | 1 git failed (tree put back) | 2 usage | 3 refused before touching anything (not a clone root, no commit, no runtime list,
# a bad path). Needs git 2.27+ (`sparse-checkout reapply`); an older git fails closed with the tree as it was. Bash 3.2 compatible.
set -u

LSP_PROG="lean_sparse"
LSP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LSP_LIST="release/runtime-files.txt"
LSP_RECORD="info/hmd-lean-on-demand"
LSP_CORE_DIRS=".claude-plugin agents commands hooks skills/heimdall"
LSP_CORE_FILES="settings.json .mcp.json LICENSE"
LSP_ON_DEMAND="stacks designmatch self-improve system-health mac-deep-clean"

# A stray GIT_* variable (this runs from installers and hooks) could point git at another repository; lazy fetch off makes "no network" a hard failure.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
LSP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lean-sparse.XXXXXX")" || { echo "$LSP_PROG: cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$LSP_TMP"' EXIT

lsp_die()   { printf '%s: %s\n' "$LSP_PROG" "$1" >&2; exit "${2:-1}"; }
lsp_usage() { printf 'usage: %s apply lean|full <dir> | add <path> [<dir>]\n' "$LSP_PROG" >&2; exit 2; }
lsp_git()   { git -C "$LSP_DIR" "$@"; }

# the three behaviours the test breaks one by one: pattern escaping, the on-demand cut, the return to a full tree
lsp_escape()         { sed -e 's/\\/\\\\/g' -e 's/[][*?]/\\&/g'; }
lsp_drop_on_demand() { awk -v ids="$LSP_ON_DEMAND" 'BEGIN { n = split(ids, id, " ") } { for (i = 1; i <= n; i++) if (index($0, "skills/" id[i] "/") == 1) next; print }'; }
lsp_disable()        { lsp_git sparse-checkout disable; }

# lsp_valid_path P -- a plain relative path inside the tree: no escape (`..`, leading `/`), no pattern character (`! # * ? [ ] \`), no control character
lsp_valid_path() {
  case "$1" in
    ''|/*|\!*|\#*|.|..|../*|*/..|*/../*|*\**|*\?*|*\[*|*\]*|*\\*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# lsp_gitpath NAME -- absolute path of a file in the git directory (git knows where info/ lives)
lsp_gitpath() {
  local p
  p="$(lsp_git rev-parse --git-path "$1")" || return 1
  case "$p" in /*) printf '%s\n' "$p" ;; *) printf '%s/%s\n' "$LSP_DIR" "$p" ;; esac
}

# lsp_target DIR -- DIR must be the ROOT of a standalone clone that has a commit; sets LSP_DIR (physical path). Anything else is refused (exit 3): git run in a
# subdirectory would sparse the repository ABOVE it (a dotfiles repo in $HOME, say), and a linked worktree shares its config with the main checkout.
lsp_target() {
  local d top gd common
  [ -n "$1" ] && [ -d "$1" ] || lsp_die "not a directory: ${1:-<none>}" 3
  d="$(cd "$1" && pwd -P)"
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || lsp_die "not a git work tree: $d" 3
  top="$(cd "$top" && pwd -P)"
  [ "$top" = "$d" ] || lsp_die "$d is inside the repository at $top, not its root: refusing to touch another repository" 3
  gd="$(cd "$d" && cd "$(git rev-parse --git-dir)" && pwd -P)"
  common="$(cd "$d" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  [ "$gd" = "$common" ] || lsp_die "$d is a linked worktree: its sparse-checkout config is shared with the main checkout, refusing" 3
  LSP_DIR="$d"
  lsp_git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 || lsp_die "$d has no commit to read the lean set from" 3
}

lsp_sparse_on() { [ "$(lsp_git config --bool --get core.sparseCheckout 2>/dev/null)" = true ]; }
lsp_skipped()   { lsp_git ls-files -v | grep -c '^[Ss]'; }

# lsp_read_list OUT -- the runtime list of HEAD, one path per line, to OUT; refuses a missing or empty list and a line that is not a path inside the tree
lsp_read_list() {
  lsp_git cat-file blob "HEAD:$LSP_LIST" > "$LSP_TMP/raw" 2>/dev/null || lsp_die "HEAD has no $LSP_LIST, so the lean set cannot be derived; the tree is as it was" 3
  awk 'NF { if ($0 ~ /^\// || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /[[:cntrl:]]/) bad++; else { print; ok++ } } END { exit (bad || !ok) }' "$LSP_TMP/raw" > "$1" \
    || lsp_die "$LSP_LIST at HEAD is empty or names a path outside the tree; the tree is as it was" 3
}

# lsp_build OUT -- the sparse-checkout file of the lean set at HEAD to OUT. Side file $LSP_TMP/keep: the exact files it names (what lsp_check_present checks).
lsp_build() {
  local f d line
  lsp_read_list "$LSP_TMP/list"
  { cat "$LSP_TMP/list"; for f in $LSP_CORE_FILES; do printf '%s\n' "$f"; done; } | lsp_drop_on_demand | LC_ALL=C sort -u > "$LSP_TMP/keep"
  {
    printf '%s\n' "# hmd lean sparse set, generated by bin/lib/lean_sparse.sh from $LSP_LIST at HEAD: run apply or add, never edit"
    lsp_escape < "$LSP_TMP/keep" | sed 's|^|/|'
    for d in $LSP_CORE_DIRS; do printf '/%s/\n' "$d"; done
    if [ -f "$LSP_REC" ]; then
      while IFS= read -r line; do
        if lsp_valid_path "${line%/}"; then printf '/%s\n' "$line"; else echo "$LSP_PROG: ignoring a bad line in $LSP_REC: $line" >&2; fi
      done < "$LSP_REC"
    fi
  } > "$1"
}

# lsp_check_present -- every tracked path the lean set names is on disk (a pattern git read differently, a path it could not write); names the first few missing
lsp_check_present() {
  local p miss=0 line
  lsp_git -c core.quotepath=false ls-files | LC_ALL=C sort > "$LSP_TMP/tracked"
  {
    LC_ALL=C comm -12 "$LSP_TMP/keep" "$LSP_TMP/tracked"
    lsp_git -c core.quotepath=false ls-files -- $LSP_CORE_DIRS
    if [ -f "$LSP_REC" ]; then while IFS= read -r line; do lsp_git -c core.quotepath=false ls-files -- "$line"; done < "$LSP_REC"; fi
  } > "$LSP_TMP/want"
  while IFS= read -r p; do
    if [ -e "$LSP_DIR/$p" ] || [ -L "$LSP_DIR/$p" ]; then continue; fi
    miss=$((miss + 1))
    if [ "$miss" -le 3 ]; then echo "$LSP_PROG: missing after the update: $p" >&2; fi
  done < "$LSP_TMP/want"
  [ "$miss" -eq 0 ]
}

# lsp_snapshot / lsp_restore -- what a failed update puts back: the sparse file, the on-demand record, and whether the tree was sparse at all
lsp_snapshot() {
  LSP_SF="$(lsp_gitpath info/sparse-checkout)"
  LSP_REC="$(lsp_gitpath "$LSP_RECORD")"
  LSP_WAS=false
  if lsp_sparse_on; then LSP_WAS=true; fi
  mkdir -p "$(dirname "$LSP_SF")"
  if [ -f "$LSP_SF" ]; then cp -p "$LSP_SF" "$LSP_TMP/sf.prev"; fi
  if [ -f "$LSP_REC" ]; then cp -p "$LSP_REC" "$LSP_TMP/rec.prev"; fi
  return 0
}
lsp_restore() {
  if [ -f "$LSP_TMP/sf.prev" ]; then cp -p "$LSP_TMP/sf.prev" "$LSP_SF"; else rm -f "$LSP_SF"; fi
  if [ -f "$LSP_TMP/rec.prev" ]; then cp -p "$LSP_TMP/rec.prev" "$LSP_REC"; else rm -f "$LSP_REC"; fi
  if [ "$LSP_WAS" = true ]; then lsp_git sparse-checkout reapply; else lsp_disable; fi
}

# lsp_apply_lean -- (after lsp_snapshot) write the lean sparse file, turn it on, update the work tree, check it; any failure puts the previous state back
lsp_apply_lean() {
  lsp_build "$LSP_TMP/new"
  if ! { cp "$LSP_TMP/new" "$LSP_SF.tmp.$$" && mv -f "$LSP_SF.tmp.$$" "$LSP_SF"; }; then lsp_restore; lsp_die "cannot write $LSP_SF" 1; fi
  if lsp_git config --worktree core.sparseCheckout true && lsp_git config --worktree core.sparseCheckoutCone false \
     && lsp_git sparse-checkout reapply && lsp_check_present; then
    return 0
  fi
  if lsp_restore; then lsp_die "the lean update failed; the previous tree is back" 1; fi
  lsp_die "the lean update failed AND putting the tree back failed: run: bash $LSP_HERE/lean_sparse.sh apply full $LSP_DIR" 1
}

# lsp_apply_full -- INV-L6. A clone that never was lean (no sparse config, no skipped entry) is left byte for byte alone, .git/config included.
lsp_apply_full() {
  local n
  n="$(lsp_skipped)"
  if ! lsp_sparse_on && [ "$n" -eq 0 ]; then return 0; fi
  lsp_disable || lsp_die "git sparse-checkout disable failed: the tree is still sparse" 1
  n="$(lsp_skipped)"
  [ "$n" -eq 0 ] || lsp_die "$n path(s) are still skipped after the return to the full tree" 1
}

# lsp_add PATH DIR -- record PATH (a directory keeps its trailing slash) and re-apply; on a full tree there is nothing to put back
lsp_add() {
  local p="${1#./}" kind entry
  p="${p%/}"
  lsp_valid_path "$p" || lsp_die "not a plain path inside the tree: $1" 2
  lsp_target "$2"
  kind="$(lsp_git cat-file -t "HEAD:$p" 2>/dev/null)"
  case "$kind" in tree|blob) ;; *) lsp_die "$p is not a tracked file or directory at HEAD" 3 ;; esac
  if ! lsp_sparse_on; then echo "$LSP_PROG: $LSP_DIR is a full tree, $p is already on disk"; return 0; fi
  entry="$p"
  if [ "$kind" = tree ]; then entry="$p/"; fi
  lsp_snapshot
  if [ ! -f "$LSP_REC" ] || ! grep -qxF -- "$entry" "$LSP_REC"; then printf '%s\n' "$entry" >> "$LSP_REC"; fi
  lsp_apply_lean
  echo "$LSP_PROG: $entry is on disk"
}

case "${1:-}" in
  apply)
    [ "$#" -eq 3 ] || lsp_usage
    case "$2" in lean|full) ;; *) lsp_usage ;; esac
    lsp_target "$3"
    if [ "$2" = lean ]; then lsp_snapshot; lsp_apply_lean; else lsp_apply_full; fi
    ;;
  add)
    { [ "$#" -ge 2 ] && [ "$#" -le 3 ]; } || lsp_usage
    lsp_add "$2" "${3:-$LSP_HERE/../..}"
    ;;
  *) lsp_usage ;;
esac
exit 0
