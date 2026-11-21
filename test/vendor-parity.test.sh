#!/usr/bin/env bash
#
# vendor-parity.test.sh -- T3.1 of docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md: heimdall pins the split-out skills and statusline
# repositories in vendor/vendor.lock.json, and its in-tree copies equal BOTH the pin and the recording of the tree before the split
# (evals/split/baseline.json, written in W0 by another tool, bin/lib/split_baseline.py). INV-S1 and INV-S2 of .planning/split/INVARIANTS.md.
#
# `heimdall-vendor verify` alone says the mirror hashes to the lock: a lock and a mirror edited together would still pass it. So the claim is checked
# three ways, each a GREEN control on the real tree next to RED mutations of one thing on a throwaway copy:
#   A. the lock is the plan's pin (two repositories, the ssh URLs, tag v1.0.0, a commit and a tree_sha256 each) and `verify --all` is exit 0 on the real
#      tree; it is exit 1 for a flipped byte (same size), a dropped exec bit on hooks/statusline.sh, a deleted file, a flipped tree_sha256 and a path
#      dropped from the lock.
#   B. the mirror equals the recording byte for byte: every pinned path has the sha256 and exec bit the recording has (hashed here by shasum, not by the
#      tool); nothing is pinned that the recording does not list; nothing the recording lists is left unpinned except the two suites that stay core-only.
#      RED for the same mutations, a doctored recording, a core-only suite pinned and a path the recording does not know pinned.
#   C. the pin is the tag: when the local clones sit next to the heimdall checkout (HMD_SPLIT_REPOS_DIR overrides the directory), `verify --upstream
#      --source` fetches v1.0.0 from each and wants the locked commit and tree_sha256; RED for a lock with another commit. A clone that is not there
#      is a printed skip (CI has none): the pin is then checked offline by A and B only.
# No network: every source is a local path and ssh is switched off.
# cost: about 20 runs of the tool (python3), as many of jq, ~10 batch shasum calls and up to three local fetches of a tag: seconds solo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-vendor"
LOCK="$ROOT/vendor/vendor.lock.json"
BASE="$ROOT/evals/split/baseline.json"
# The two statusline suites the recording lists that stay in heimdall and are not in the new repo: they test host code (plan section 4).
CORE_ONLY="test/heimdall-init-cursor-statusline.test.sh test/heimdall-status-json.test.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

skip() { echo "SKIP: $1"; echo "vendor-parity: 0 passed, 0 failed (SKIPPED: $1)"; exit 0; }
for need in python3 jq; do command -v "$need" >/dev/null 2>&1 || skip "$need unavailable"; done
if command -v shasum >/dev/null 2>&1; then SHA=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum)
else skip "no shasum or sha256sum"; fi
for need in "$TOOL" "$LOCK" "$BASE"; do
  [ -f "$need" ] || { echo "FATAL: $need is missing"; echo "vendor-parity: 0 passed, 1 failed"; exit 1; }
done
[ -x "$TOOL" ] || { echo "FATAL: $TOOL is not executable"; echo "vendor-parity: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_QUARANTINE_PATH
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND=false HMD_VENDOR_GIT_TIMEOUT_S=60

OUT=""; RC=0
# run <tool args>: OUT is stdout and stderr, RC the exit status
run() { OUT="$("$TOOL" "$@" 2>&1)"; RC=$?; }
# contains <text> <needle>: a literal substring test in the shell itself
contains() { [[ "$1" == *"$2"* ]]; }
# check <label> <command...>: the command succeeds
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
# green <label> <needle> <tool args>: exit 0 and the output names <needle>
green() {
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "$RC" = 0 ] && contains "$OUT" "$needle"; then ok "$label"; else bad "$label (exit $RC, wanted 0 naming '$needle'): $(head -3 <<<"$OUT")"; fi
}
# red <label> <needle> <tool args>: exit 1, the output names <needle>, and it is a report, not a traceback
red() {
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "$RC" = 1 ] && contains "$OUT" "$needle" && ! contains "$OUT" Traceback; then ok "$label"; else bad "$label (exit $RC, wanted 1 naming '$needle'): $(head -3 <<<"$OUT")"; fi
}
# names <label> <text> <needle>: the text names <needle>
names() { if contains "$2" "$3"; then ok "$1"; else bad "$1: wanted '$3' in: $(head -3 <<<"$2")"; fi; }

# flip_byte <file>: change one byte in the middle, the size stays
flip_byte() {
  python3 -I - "$1" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as handle:
    data = bytearray(handle.read())
data[len(data) // 2] ^= 1
with open(path, "wb") as handle:
    handle.write(data)
PY
}
FLIP='(if .[0:1]=="0" then "1"+.[1:] else "0"+.[1:] end)'

# tree_lines <dir> <path list file>: "<sha256> <x|-> <path>" for each listed file under <dir>, hashed by ONE shasum call; a file that cannot be read is absent
tree_lines() {
  local dir="$1" list="$2" h p
  ( cd "$dir" && xargs "${SHA[@]}" -- < "$list" 2>/dev/null ) | while read -r h p; do
    printf '%s %s %s\n' "$h" "$([ -x "$dir/$p" ] && echo x || echo -)" "$p"
  done | LC_ALL=C sort -k3,3
}
# base_lines <lock> <baseline>: the recording's "<sha256> <x|-> <path>" for the paths the lock pins
base_lines() {
  jq -r --slurpfile lock "$1" '($lock[0].repos | map(.paths) | add) as $pinned
    | .paths[] | select(.path as $p | $pinned | any(. == $p))
    | "\(.sha256) \(if .exec then "x" else "-" end) \(.path)"' "$2" | LC_ALL=C sort -k3,3
}
# parity_problems <tree> <lock> <baseline>: one line for each way the tree, the lock and the recording disagree; nothing when they agree
parity_problems() {
  local tree="$1" lock="$2" base="$3"
  jq -r '.repos[].paths[]' "$lock" | LC_ALL=C sort > "$WORK/pp.lock"
  jq -r '.paths[].path' "$base" | LC_ALL=C sort > "$WORK/pp.base"
  printf '%s\n' $CORE_ONLY | LC_ALL=C sort > "$WORK/pp.core"
  comm -23 "$WORK/pp.lock" "$WORK/pp.base" | sed 's/^/pinned, not in the recording: /'
  comm -13 "$WORK/pp.lock" "$WORK/pp.base" | comm -23 - "$WORK/pp.core" | sed 's/^/in the recording, not pinned: /'
  comm -12 "$WORK/pp.lock" "$WORK/pp.core" | sed 's/^/pinned, but stays core-only: /'
  diff <(base_lines "$lock" "$base") <(tree_lines "$tree" "$WORK/pp.lock") | grep '^[<>]' | sed 's/^/differs (< recording, > tree): /'
}

jq -r '.repos[].paths[]' "$LOCK" | LC_ALL=C sort > "$WORK/paths.lock"
NPATHS="$(wc -l < "$WORK/paths.lock" | tr -d ' ')"
M="$WORK/mirror"
fresh() { rm -rf "$M"; mkdir -p "$M"; (cd "$ROOT" && tar -cf - -T "$WORK/paths.lock") | tar -xf - -C "$M"; }   # the pinned files only, modes kept

echo "== A) the lock is the plan's pin; verify --all is green on the real tree and RED when one thing moves =="
check "the plan's accept: the lock lists two repositories" jq -e '.repos|length==2' "$LOCK"
lock_shape() { jq -e '
  .schema==1 and (.repos|map(.name)==["hmd-skills","hmd-statusline"])
  and (.repos|map(.repo)==["git@github.com:randomittin/hmd-skills.git","git@github.com:randomittin/hmd-statusline.git"])
  and all(.repos[]; .tag=="v1.0.0" and (.commit|test("^[0-9a-f]{40}$")) and (.tree_sha256|test("^[0-9a-f]{64}$")))' "$1" >/dev/null 2>&1; }
if lock_shape "$LOCK"; then ok "hmd-skills and hmd-statusline, the ssh URLs under randomittin, tag v1.0.0, a 40-hex commit and a 64-hex tree_sha256 each"
else bad "the lock is not the plan's pin (names, repo URLs, tag v1.0.0, commit and tree_sha256 shapes)"; fi
jq 'del(.repos[1])' "$LOCK" > "$WORK/lock.one"
jq '.repos[0].tag = "v1.0.1"' "$LOCK" > "$WORK/lock.tag"
if ! lock_shape "$WORK/lock.one" && ! lock_shape "$WORK/lock.tag"; then ok "RED: the shape check fails for a lock with one repository and for a lock pinning another tag"
else bad "the shape check accepts a lock with one repository or another tag"; fi

run verify --all
if [ "$RC" = 0 ] && contains "$OUT" "ok hmd-skills" && contains "$OUT" "ok hmd-statusline"; then ok "verify --all on the real tree: exit 0, both repositories ok ($NPATHS files)"
else bad "verify --all on the real tree (exit $RC): $(head -3 <<<"$OUT")"; fi
fresh
green "control: a fresh copy of the $NPATHS pinned files verifies against the real lock" "ok hmd-statusline" verify --all --root "$M" --lock "$LOCK"
fresh; flip_byte "$M/sentinels/hmd-statusline.py"
red "RED: one byte of sentinels/hmd-statusline.py changed (same size)" "FAIL hmd-statusline: tree_sha256 differs" verify --all --root "$M" --lock "$LOCK"
fresh; chmod -x "$M/hooks/statusline.sh"
red "RED: hooks/statusline.sh loses its exec bit (INV-S2: the registered statusLine command must stay executable)" "FAIL hmd-statusline: tree_sha256 differs" verify --all --root "$M" --lock "$LOCK"
fresh; rm "$M/sentinels/hmd_sigil.py"
red "RED: a mirrored file deleted, and named" "sentinels/hmd_sigil.py: missing" verify --all --root "$M" --lock "$LOCK"
jq ".repos[0].tree_sha256 |= $FLIP" "$LOCK" > "$WORK/lock.flip"
red "RED: the lock's tree_sha256 flipped" "FAIL hmd-skills: tree_sha256 differs" verify --all --lock "$WORK/lock.flip"
jq 'del(.repos[1].paths[] | select(. == "hooks/statusline.sh"))' "$LOCK" > "$WORK/lock.drop"
red "RED: a moved path (hooks/statusline.sh) dropped from the lock" "FAIL hmd-statusline: tree_sha256 differs" verify --all --lock "$WORK/lock.drop"

echo "== B) the mirror equals the recording (evals/split/baseline.json), byte for byte =="
PROBLEMS="$(parity_problems "$ROOT" "$LOCK" "$BASE")"
if [ -z "$PROBLEMS" ]; then ok "every one of the $NPATHS pinned paths has the recorded sha256 and exec bit; lock plus the two core-only suites is the whole recording"
else bad "the tree, the lock and the recording disagree: $(head -5 <<<"$PROBLEMS")"; fi
fresh; flip_byte "$M/sentinels/hmd_sigil.py"
names "RED: a changed byte in a copy is named" "$(parity_problems "$M" "$LOCK" "$BASE")" "differs (< recording, > tree): "
names "RED: ... and the path it is in" "$(parity_problems "$M" "$LOCK" "$BASE")" "sentinels/hmd_sigil.py"
fresh; chmod -x "$M/hooks/statusline.sh"
names "RED: a dropped exec bit on hooks/statusline.sh is named" "$(parity_problems "$M" "$LOCK" "$BASE")" "hooks/statusline.sh"
fresh; rm "$M/bin/heimdall-statusline"
names "RED: a deleted bin/heimdall-statusline is named" "$(parity_problems "$M" "$LOCK" "$BASE")" "bin/heimdall-statusline"
jq '.paths[0].sha256 |= '"$FLIP" "$BASE" > "$WORK/base.flip"
names "RED: a doctored recording hash (the first recorded path) is named" "$(parity_problems "$ROOT" "$LOCK" "$WORK/base.flip")" "skills/designmatch/SKILL.md"
names "RED: a runtime path dropped from the lock is reported as unpinned" "$(parity_problems "$ROOT" "$WORK/lock.drop" "$BASE")" "in the recording, not pinned: hooks/statusline.sh"
jq '.repos[1].paths += ["test/heimdall-status-json.test.sh"]' "$LOCK" > "$WORK/lock.core"
names "RED: a core-only suite pinned is reported" "$(parity_problems "$ROOT" "$WORK/lock.core" "$BASE")" "pinned, but stays core-only: test/heimdall-status-json.test.sh"
jq '.repos[1].paths += ["hooks/hooks.json"]' "$LOCK" > "$WORK/lock.extra"
names "RED: a pinned path the recording does not list is reported" "$(parity_problems "$ROOT" "$WORK/lock.extra" "$BASE")" "pinned, not in the recording: hooks/hooks.json"

echo "== C) the pin is the tag (local clones) =="
REPOS_DIR="${HMD_SPLIT_REPOS_DIR:-}"
if [ -z "$REPOS_DIR" ] && command -v git >/dev/null 2>&1; then
  COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && REPOS_DIR="$(dirname "$(dirname "$COMMON")")"
fi
first_clone=""
for name in hmd-skills hmd-statusline; do
  src="$REPOS_DIR/$name"
  if [ -n "$REPOS_DIR" ] && git -C "$src" rev-parse -q --verify "refs/tags/v1.0.0" >/dev/null 2>&1; then
    green "verify --upstream: tag v1.0.0 of $src is the locked commit and tree_sha256" "tag checked upstream" verify "$name" --upstream --source "$src" --lock "$LOCK"
    [ "$name" = hmd-skills ] && first_clone="$src"
  else
    echo "  skip $name: no clone with tag v1.0.0 at '$src' (HMD_SPLIT_REPOS_DIR names the directory that holds it)"
  fi
done
if [ -n "$first_clone" ]; then
  jq ".repos[0].commit |= $FLIP" "$LOCK" > "$WORK/lock.commit"
  red "RED: a lock pinning another commit than the tag has" "the tag moved, or the lock is stale" verify hmd-skills --upstream --source "$first_clone" --lock "$WORK/lock.commit"
fi

echo
echo "vendor-parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
