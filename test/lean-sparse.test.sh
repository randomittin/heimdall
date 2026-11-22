#!/usr/bin/env bash
# lean-sparse.test.sh -- proves bin/lib/lean_sparse.sh (T2.4 of the 3.x lean-core plan, docs/superpowers/plans/2026-11-12-3x-lean-core.md): the sparse checkout
# that makes an install lean. Invariants (.planning/lean-core/INVARIANTS.md): INV-L3, INV-L4, INV-L6, INV-L7, and INV-L10 for the data it must never touch.
#
#   A. THE LEAN SET, on a fixture clone (a local temp repository cloned with --depth 1 over file://, the way install.sh clones): the files on disk are EXACTLY the
#      runtime list + the convention-loaded core - the on-demand skills (nothing missing, nothing extra); a name with glob characters is matched literally (its
#      look-alike sibling stays out); a second apply changes nothing; an untracked file and a locally edited tracked file outside the set survive.
#   B. INV-L6, `apply full`: the full tree back (every tracked file on disk, byte for byte, none skipped), idempotent; lean -> full -> lean lands on the same set;
#      a clone that never was lean is not touched at all (.git/config included).
#   C. INV-L4, `add`, WITH THE NETWORK CUT (origin deleted, its URL unreachable, every git transport refused): the path comes back from local objects and git never
#      ran a fetch / pull / clone / ls-remote / remote helper (trace2); idempotent; a file works like a directory; a later `apply lean` (the upgrade, INV-L7) and a
#      lean -> full -> lean keep what was added; on a full tree it says so and changes nothing.
#   D. REFUSALS, each before anything is touched: not a repository, a subdirectory of one, a linked worktree, HEAD without the runtime list, a list line that
#      escapes the tree, and `add` of a path that is absent, escapes the tree or carries pattern characters; usage errors exit 2.
#   E. THIS REPOSITORY, lean: a clone of HEAD narrowed to the lean set keeps every bin/ file, every hook, the plugin manifest and the whole runtime list (INV-L3: the
#      plan's "closure audit misses a path" risk), keeps the docs/ files the closure names, drops test/, .planning/ and the five on-demand skills, has every file
#      a hook command names, comes back whole with `apply full`, and is smaller than the full tree.
#   F. THE MUTANTS: the library with one behaviour broken (the on-demand cut, the glob escaping, the return to a full tree, an `add` that fetches) goes RED on
#      the check that guards that behaviour.
#
# budget: about 8 s solo (section E clones this repository's HEAD: the one slow step). Hermetic: HOME, the git config and every GIT_* variable are the test's own;
# nothing outside $T is read or written. bash 3.2 compatible.
#
# Usage:  bash test/lean-sparse.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
LIB="$REPO/bin/lib/lean_sparse.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lean-sparse-test.XXXXXX")" || exit 1; T="$(cd "$T" && pwd -P)"
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=lean-sparse-test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=lean-sparse-test GIT_COMMITTER_EMAIL=test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

echo "lean-sparse (bin/lib/lean_sparse.sh: the lean set, apply full, add offline, refusals, this repository, mutants)"
[ -f "$LIB" ] || { bad "bin/lib/lean_sparse.sh is missing"; printf '\nlean-sparse: %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

# ── the fixture: a tiny plugin laid out like this one ─────────────────────────────────────────────────────────────────────────────────────────────────
put() { mkdir -p "$(dirname "$1/$2")"; printf 'content of %s\n' "$2" > "$1/$2"; }      # put DIR PATH
STD_LIST='VERSION
bin/lib/lean_sparse.sh
bin/lib/x.py
bin/tool
data/odd [1] *.txt
docs/samples/allow.json
evals/oracles/registry.json
hooks/h.sh
hooks/hooks.json
release/runtime-files.txt
skills/designmatch/SKILL.md
skills/heimdall/SKILL.md
skills/mac-deep-clean/SKILL.md
skills/self-improve/SKILL.md
skills/stacks/SKILL.md
skills/stacks/fastapi/PACK.md
skills/system-health/SKILL.md'
# what a lean tree of the fixture holds: the list minus the on-demand skills, plus the core (.claude-plugin/ agents/ commands/ hooks/ skills/heimdall/ and three files)
LEAN_EXPECT='.claude-plugin/marketplace.json
.claude-plugin/plugin.json
.mcp.json
LICENSE
VERSION
agents/a.md
bin/lib/lean_sparse.sh
bin/lib/x.py
bin/tool
commands/c.md
commands/designmatch.md
data/odd [1] *.txt
docs/samples/allow.json
evals/oracles/registry.json
hooks/h.sh
hooks/hooks.json
release/runtime-files.txt
settings.json
skills/heimdall/SKILL.md
skills/heimdall/references/r.md'
STACKS_FILES='skills/stacks/SKILL.md
skills/stacks/fastapi/PACK.md'

mk_origin() {   # mk_origin DIR -- the fixture repository, one commit
  local o="$1" f
  mkdir -p "$o" && git -C "$o" init -q || return 1
  for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json .mcp.json settings.json LICENSE README.md VERSION agents/a.md commands/c.md commands/designmatch.md \
           hooks/hooks.json hooks/h.sh bin/tool bin/lib/x.py skills/heimdall/SKILL.md skills/heimdall/references/r.md skills/stacks/SKILL.md skills/stacks/fastapi/PACK.md \
           skills/designmatch/SKILL.md skills/self-improve/SKILL.md skills/system-health/SKILL.md skills/mac-deep-clean/SKILL.md evals/oracles/registry.json \
           evals/other/x.json test/run.test.sh docs/guide.md docs/samples/allow.json .planning/STATE.md "data/odd [1] *.txt" "data/odd 1 x.txt"; do
    put "$o" "$f"
  done
  cp "$LIB" "$o/bin/lib/lean_sparse.sh"
  mkdir -p "$o/release" && printf '%s\n' "$STD_LIST" > "$o/release/runtime-files.txt"
  git -C "$o" add -A >/dev/null && git -C "$o" commit -q -m fixture
}
new_clone() {   # new_clone NAME -- sets ORIGIN and CL: a fresh fixture origin and its depth-1 clone
  ORIGIN="$T/$1.origin"; CL="$T/$1"
  mk_origin "$ORIGIN" && git clone -q --depth 1 "file://$ORIGIN" "$CL" 2>"$T/clone.err" || { bad "the fixture clone $1 could not be made: $(head -c 200 "$T/clone.err")"; exit 1; }
}

# ── helpers ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
RC=0
run_lib() { bash "$LIB" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
run_offline() {   # run_offline SCRIPT ARGS... -- the network is cut: every transport refused, a dead proxy, git's own trace of what it ran
  rm -f "$T/trace.json"
  env GIT_ALLOW_PROTOCOL=none http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 GIT_TRACE2_EVENT="$T/trace.json" bash "$@" > "$T/out" 2> "$T/err"; RC=$?
}
rc_is()  { if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1 (rc=$RC, wanted $2; stderr=[$(head -c 300 "$T/err" | tr '\n' '|')])"; fi; }
ondisk() { ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ); }
tracked_set() { git -C "$1" -c core.quotepath=false ls-files | LC_ALL=C sort; }
sparse_off() { ! git -C "$1" config --get core.sparseCheckout >/dev/null 2>&1; }
treehash() { ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -c1-64)"; done | shasum -a 256 | cut -c1-64 ); }
set_is_lean() {   # set_is_lean CLONE [EXTRA] -- the files on disk are exactly the lean set (+ the EXTRA lines)
  { printf '%s\n' "$LEAN_EXPECT"; if [ -n "${2:-}" ]; then printf '%s\n' "$2"; fi; } | LC_ALL=C sort -u > "$T/want"
  ondisk "$1" > "$T/disk"; cmp -s "$T/want" "$T/disk"
}
show_diff() { diff "$T/want" "$T/disk" | head -8 | tr '\n' '|'; }
set_is_full() {   # every tracked file on disk, none skipped, nothing modified
  ondisk "$1" > "$T/disk"; tracked_set "$1" > "$T/want"
  cmp -s "$T/want" "$T/disk" && [ -z "$(git -C "$1" status --porcelain)" ] && [ "$(git -C "$1" ls-files -v | grep -c '^[Ss]')" = 0 ]
}
no_transport_in_trace() {   # the run is in the trace (so the check is not blind) and git ran no fetch / pull / clone / ls-remote / push / remote helper
  [ -s "$T/trace.json" ] && grep -q 'sparse-checkout' "$T/trace.json" \
    && ! grep -Eq '"(fetch|pull|clone|ls-remote|push|remote-https?|remote-ssh|remote-ext)"|git-remote-' "$T/trace.json"
}
mutant() {   # mutant NAME SED -- $T/NAME.sh: the library with one line changed; the change must have landed
  sed -e "$2" "$LIB" > "$T/$1.sh"
  if cmp -s "$LIB" "$T/$1.sh"; then bad "F: mutant $1 left the library unchanged (its anchor moved)"; return 1; fi
}

echo "-- A. the lean set on a fixture clone --"
new_clone a
HASH_FRESH="$(treehash "$CL")"
run_lib apply lean "$CL"
rc_is "A: apply lean exits 0" 0
if set_is_lean "$CL"; then ok "A: the files on disk are exactly the runtime list + the core - the on-demand skills (nothing missing, nothing extra)"; else bad "A: the lean set differs: $(show_diff)"; fi
if [ -f "$CL/data/odd [1] *.txt" ] && [ ! -e "$CL/data/odd 1 x.txt" ]; then ok "A: a name with glob characters is matched literally: it is there, its look-alike sibling is not"; else bad "A: glob characters in a name were read as a pattern"; fi
if [ -f "$CL/docs/samples/allow.json" ] && [ ! -e "$CL/docs/guide.md" ] && [ ! -e "$CL/test" ] && [ ! -e "$CL/.planning" ] && [ ! -e "$CL/skills/stacks" ]; then
  ok "A: a docs/ file the list names stays; the rest of docs/, test/, .planning/ and the on-demand skills are gone"
else bad "A: docs/, test/, .planning/ or an on-demand skill is wrong"; fi
if [ -z "$(git -C "$CL" status --porcelain)" ]; then ok "A: git sees a clean tree (the skipped files are skipped, not deleted)"; else bad "A: git status is not clean: $(git -C "$CL" status --porcelain | head -3 | tr '\n' '|')"; fi
cp "$CL/.git/info/sparse-checkout" "$T/sf.first"
run_lib apply lean "$CL"
if [ "$RC" = 0 ] && set_is_lean "$CL" && cmp -s "$T/sf.first" "$CL/.git/info/sparse-checkout"; then ok "A: a second apply lean changes nothing (same files, same sparse file)"; else bad "A: the second apply changed something (rc=$RC): $(show_diff)"; fi

new_clone au
mkdir -p "$CL/docs" "$CL/.planning/local"; printf 'my note\n' > "$CL/docs/user-note.txt"; printf 'ledger row\n' > "$CL/.planning/local/ledger.ndjson"
run_lib apply lean "$CL"
if [ "$RC" = 0 ] && [ "$(cat "$CL/docs/user-note.txt")" = "my note" ] && [ "$(cat "$CL/.planning/local/ledger.ndjson")" = "ledger row" ]; then ok "A: untracked files inside directories the lean set drops survive apply lean (INV-L10)"; else bad "A: an untracked file was lost (rc=$RC)"; fi
run_lib apply full "$CL"
if [ "$RC" = 0 ] && [ "$(cat "$CL/docs/user-note.txt")" = "my note" ] && [ "$(cat "$CL/.planning/local/ledger.ndjson")" = "ledger row" ]; then ok "A: ... and apply full"; else bad "A: an untracked file was lost by apply full (rc=$RC)"; fi

new_clone am
printf 'my edit\n' >> "$CL/README.md"
run_lib apply lean "$CL"
if [ "$RC" = 0 ] && grep -qx 'my edit' "$CL/README.md" && set_is_lean "$CL" README.md; then ok "A: a locally edited tracked file outside the set is kept with its edit, and it is the only extra file"; else bad "A: the local edit was lost or more stayed (rc=$RC): $(show_diff)"; fi

echo "-- B. INV-L6: apply full --"
new_clone b
run_lib apply lean "$CL"; run_lib apply full "$CL"
rc_is "B: apply full on a lean tree exits 0" 0
if set_is_full "$CL" && [ "$(treehash "$CL")" = "$HASH_FRESH" ]; then ok "B: every tracked file is back, byte for byte what a fresh clone has, none skipped, git status clean"; else bad "B: the full tree did not come back: $(show_diff)"; fi
run_lib apply full "$CL"
if [ "$RC" = 0 ] && set_is_full "$CL"; then ok "B: a second apply full is a no-op that still exits 0 (idempotent)"; else bad "B: the second apply full failed (rc=$RC)"; fi
run_lib apply lean "$CL"
if [ "$RC" = 0 ] && set_is_lean "$CL" && cmp -s "$T/sf.first" "$CL/.git/info/sparse-checkout"; then ok "B: lean -> full -> lean lands on the same set and the same sparse file"; else bad "B: lean again differs (rc=$RC): $(show_diff)"; fi
new_clone nf
CFG_BEFORE="$(cat "$CL/.git/config")"; HASH_BEFORE="$(treehash "$CL")"
run_lib apply full "$CL"
if [ "$RC" = 0 ] && [ "$(cat "$CL/.git/config")" = "$CFG_BEFORE" ] && [ ! -e "$CL/.git/config.worktree" ] && [ "$(treehash "$CL")" = "$HASH_BEFORE" ] && sparse_off "$CL"; then
  ok "B: apply full on a clone that never was lean touches nothing (tree and .git/config byte for byte)"
else bad "B: apply full changed a clone that was never lean (rc=$RC)"; fi

echo "-- C. INV-L4: add, with the network cut --"
new_clone c
run_lib apply lean "$CL"
rm -rf "$ORIGIN"; git -C "$CL" remote set-url origin "https://127.0.0.1:9/never.git"
run_offline "$CL/bin/lib/lean_sparse.sh" add skills/stacks
rc_is "C: add skills/stacks exits 0 with origin deleted and every transport refused (default dir: the clone the script lives in)" 0
if set_is_lean "$CL" "$STACKS_FILES" && [ "$(cat "$CL/skills/stacks/SKILL.md")" = "content of skills/stacks/SKILL.md" ] && [ "$(cat "$CL/skills/stacks/fastapi/PACK.md")" = "content of skills/stacks/fastapi/PACK.md" ]; then
  ok "C: the whole directory is back from local objects, byte for byte, and nothing else moved (the other on-demand skills are still out)"
else bad "C: add did not put exactly skills/stacks back: $(show_diff)"; fi
if no_transport_in_trace; then ok "C: git ran no fetch, pull, clone, ls-remote, push or remote helper (trace2)"; else bad "C: the trace shows a transport command, or no trace was written"; fi
run_offline "$CL/bin/lib/lean_sparse.sh" add skills/stacks
if [ "$RC" = 0 ] && [ "$(cat "$CL/.git/info/hmd-lean-on-demand")" = "skills/stacks/" ] && set_is_lean "$CL" "$STACKS_FILES"; then ok "C: a second add of the same path is a no-op: one record line, same files"; else bad "C: the repeated add changed something (rc=$RC)"; fi
run_offline "$CL/bin/lib/lean_sparse.sh" add README.md "$CL"
if [ "$RC" = 0 ] && [ "$(wc -l < "$CL/.git/info/hmd-lean-on-demand" | tr -d ' ')" = 2 ] && set_is_lean "$CL" "$STACKS_FILES
README.md"; then ok "C: a single file is added like a directory (explicit dir argument)"; else bad "C: add of a file failed (rc=$RC): $(show_diff)"; fi
run_offline "$LIB" apply lean "$CL"
if [ "$RC" = 0 ] && set_is_lean "$CL" "$STACKS_FILES
README.md"; then ok "C: INV-L7: a later apply lean (the upgrade) keeps what was added"; else bad "C: apply lean dropped an added path (rc=$RC): $(show_diff)"; fi
run_offline "$LIB" apply full "$CL"; run_offline "$LIB" apply lean "$CL"
if [ "$RC" = 0 ] && set_is_lean "$CL" "$STACKS_FILES
README.md"; then ok "C: lean -> full -> lean keeps what was added, still offline"; else bad "C: the round trip dropped an added path (rc=$RC): $(show_diff)"; fi
new_clone cf
CFG_BEFORE="$(cat "$CL/.git/config")"
run_lib add skills/stacks "$CL"
if [ "$RC" = 0 ] && grep -q 'already on disk' "$T/out" && [ "$(cat "$CL/.git/config")" = "$CFG_BEFORE" ] && [ ! -e "$CL/.git/info/hmd-lean-on-demand" ] && set_is_full "$CL"; then ok "C: add on a full tree says so and changes nothing"; else bad "C: add on a full tree did something (rc=$RC)"; fi

echo "-- D. refusals and usage --"
mkdir "$T/plain"; run_lib apply lean "$T/plain"
if [ "$RC" = 3 ] && [ -z "$(ls -A "$T/plain")" ]; then ok "D: a directory that is not a repository: refused (3), nothing created"; else bad "D: non-repository dir: rc=$RC"; fi
new_clone d
run_lib apply lean "$CL/bin"
if [ "$RC" = 3 ] && sparse_off "$CL" && set_is_full "$CL"; then ok "D: a subdirectory of a repository: refused (3), the repository above is untouched"; else bad "D: subdirectory target: rc=$RC"; fi
git -C "$CL" worktree add -q --detach "$T/d.wt" HEAD 2>/dev/null
run_lib apply lean "$T/d.wt"
if [ "$RC" = 3 ] && sparse_off "$CL" && sparse_off "$T/d.wt"; then ok "D: a linked worktree: refused (3), the shared config is untouched"; else bad "D: linked worktree target: rc=$RC"; fi
O2="$T/nolist.origin"; mk_origin "$O2"; git -C "$O2" rm -q release/runtime-files.txt; git -C "$O2" commit -q -m nolist
git clone -q --depth 1 "file://$O2" "$T/nolist" 2>/dev/null
run_lib apply lean "$T/nolist"
if [ "$RC" = 3 ] && grep -q 'runtime-files.txt' "$T/err" && sparse_off "$T/nolist" && set_is_full "$T/nolist"; then ok "D: HEAD without the runtime list: refused (3), says which file, the tree is as it was"; else bad "D: no-list clone: rc=$RC"; fi
O3="$T/escape.origin"; mk_origin "$O3"; printf '../outside\n' >> "$O3/release/runtime-files.txt"; git -C "$O3" commit -q -am escape
git clone -q --depth 1 "file://$O3" "$T/escape" 2>/dev/null
run_lib apply lean "$T/escape"
if [ "$RC" = 3 ] && sparse_off "$T/escape" && set_is_full "$T/escape"; then ok "D: a list line that escapes the tree: refused (3), the tree is as it was"; else bad "D: escaping list line: rc=$RC"; fi
new_clone dr
run_lib apply lean "$CL"; ondisk "$CL" > "$T/before.set"
for p in '../x' '/etc/passwd' '*' '!x' '' 'a/../../b' 'skills/[s]tacks' 'skills/st\acks'; do
  run_lib add "$p" "$CL"; ondisk "$CL" > "$T/after.set"
  if [ "$RC" = 2 ] && cmp -s "$T/before.set" "$T/after.set"; then ok "D: add '$p' refused (2), the tree is unchanged"; else bad "D: add '$p' rc=$RC or the tree moved"; fi
done
run_lib add skills/nope "$CL"; ondisk "$CL" > "$T/after.set"
if [ "$RC" = 3 ] && cmp -s "$T/before.set" "$T/after.set" && [ ! -e "$CL/.git/info/hmd-lean-on-demand" ]; then ok "D: add of a path HEAD does not track: refused (3), no record written"; else bad "D: add of an absent path rc=$RC"; fi
for args in "" "apply" "apply bogus $CL" "apply lean" "add" "add a b c" "frobnicate"; do
  # shellcheck disable=SC2086  # the word list is the point
  run_lib $args
  if [ "$RC" = 2 ] && grep -q '^usage:' "$T/err"; then ok "D: usage error exits 2: [${args}]"; else bad "D: [${args}] rc=$RC"; fi
done

echo "-- E. this repository, lean --"
REAL="$T/real"
if git clone -q --depth 1 "file://$REPO" "$REAL" 2>"$T/real.err"; then
  tracked_set "$REAL" > "$T/real.tracked"
  run_lib apply lean "$REAL"
  rc_is "E: apply lean on a clone of this repository exits 0" 0
  ondisk "$REAL" > "$T/real.lean"
  { grep '^bin/' "$T/real.tracked"; grep -E '^(hooks|\.claude-plugin|agents|commands|skills/heimdall)/' "$T/real.tracked"
    grep -E '^(install\.sh|settings\.json|\.mcp\.json|LICENSE|release/runtime-files\.txt)$' "$T/real.tracked"; } | LC_ALL=C sort -u > "$T/real.core"
  MISSING="$(LC_ALL=C comm -23 "$T/real.core" "$T/real.lean" | head -3 | tr '\n' ' ')"
  if [ -s "$T/real.core" ] && [ -z "$MISSING" ]; then ok "E: INV-L3: every bin/ file, hook, plugin file, agent, command, skills/heimdall file, install.sh, settings.json and .mcp.json is on disk ($(grep -c '' "$T/real.core") files)"; else bad "E: missing from the lean tree: $MISSING"; fi
  grep -Ev '^skills/(stacks|designmatch|self-improve|system-health|mac-deep-clean)/' "$REAL/release/runtime-files.txt" | LC_ALL=C sort -u > "$T/real.list"
  LC_ALL=C comm -12 "$T/real.list" "$T/real.tracked" > "$T/real.list.tracked"
  MISSING="$(LC_ALL=C comm -23 "$T/real.list.tracked" "$T/real.lean" | head -3 | tr '\n' ' ')"
  if [ -s "$T/real.list.tracked" ] && [ -z "$MISSING" ]; then ok "E: every tracked path of release/runtime-files.txt (minus the on-demand skills) is on disk ($(grep -c '' "$T/real.list.tracked") files)"; else bad "E: runtime list paths missing: $MISSING"; fi
  if ! grep -Eq '^(test|\.planning)/' "$T/real.lean"; then ok "E: nothing under test/ or .planning/ is on disk"; else bad "E: test/ or .planning/ files on disk: $(grep -E '^(test|\.planning)/' "$T/real.lean" | head -2 | tr '\n' ' ')"; fi
  GONE=""; for id in stacks designmatch self-improve system-health mac-deep-clean; do if [ -e "$REAL/skills/$id" ]; then GONE="$GONE $id"; fi; done
  if [ -z "$GONE" ]; then ok "E: the five on-demand skill directories are gone"; else bad "E: on-demand skills still on disk:$GONE"; fi
  grep '^docs/' "$T/real.lean" > "$T/real.docs"; grep '^docs/' "$T/real.list.tracked" > "$T/real.docs.want"
  if [ -s "$T/real.docs.want" ] && cmp -s "$T/real.docs" "$T/real.docs.want"; then ok "E: of docs/, exactly the $(grep -c '' "$T/real.docs.want") files the closure names stay (companion_cc_login reads docs/samples/login/allowlist.json)"; else bad "E: docs/ on disk differs from the docs/ files the list names"; fi
  python3 -I - "$REAL/hooks/hooks.json" > "$T/hook.paths" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1]))
commands = []
def walk(x):
    if isinstance(x, dict):
        for key, value in x.items():
            if key == "command" and isinstance(value, str):
                commands.append(value)
            else:
                walk(value)
    elif isinstance(x, list):
        for value in x:
            walk(value)
walk(doc)
paths = set()
for command in commands:
    paths.update(re.findall(r"(?:bin|hooks)/[A-Za-z0-9_./@+=,-]+", command))
print("\n".join(sorted(paths)))
PY
  LC_ALL=C sort -u "$T/hook.paths" > "$T/hook.sorted"; LC_ALL=C comm -12 "$T/hook.sorted" "$T/real.tracked" > "$T/hook.tracked"
  MISSING="$(LC_ALL=C comm -23 "$T/hook.tracked" "$T/real.lean" | head -3 | tr '\n' ' ')"
  if [ "$(grep -c '' "$T/hook.tracked")" -gt 20 ] && [ -z "$MISSING" ]; then ok "E: the hook smoke: every bin/ and hooks/ file a hook command names is on disk ($(grep -c '' "$T/hook.tracked") files)"; else bad "E: hook files missing (or fewer than 20 found): $MISSING"; fi
  tree_bytes() { ( cd "$1" && find . -path ./.git -prune -o -type f -exec wc -c {} + | awk '$2 != "total" { s += $1 } END { print s + 0 }' ); }
  LEAN_B="$(tree_bytes "$REAL")"; LEAN_N="$(grep -c '' "$T/real.lean")"
  run_lib apply full "$REAL"
  rc_is "E: apply full on the real clone exits 0" 0
  if set_is_full "$REAL"; then ok "E: INV-L6 on the real tree: every tracked file is back, none skipped, git status clean"; else bad "E: the real clone did not come back whole"; fi
  FULL_B="$(tree_bytes "$REAL")"; FULL_N="$(ondisk "$REAL" | grep -c '')"
  if [ "$LEAN_B" -lt "$FULL_B" ] && [ "$LEAN_N" -lt "$FULL_N" ]; then ok "E: the lean tree is smaller: $((LEAN_B / 1024)) KB in $LEAN_N files against $((FULL_B / 1024)) KB in $FULL_N files ($((LEAN_B * 100 / FULL_B))% of the bytes)"; else bad "E: lean $LEAN_B B / $LEAN_N files is not smaller than full $FULL_B B / $FULL_N files"; fi
else
  bad "E: could not clone this repository's HEAD: $(head -c 300 "$T/real.err")"
fi

echo "-- F. the mutants: one behaviour broken, its check goes RED --"
if mutant m1 's/^lsp_drop_on_demand() .*/lsp_drop_on_demand() { cat; }/'; then
  new_clone m1; bash "$T/m1.sh" apply lean "$CL" >/dev/null 2>&1; RC=$?
  if [ "$RC" = 0 ] && [ -f "$CL/skills/stacks/SKILL.md" ] && ! set_is_lean "$CL"; then ok "F: without the on-demand cut the on-demand skills stay on disk and the lean-set check goes RED"; else bad "F: the on-demand mutant was not caught (rc=$RC)"; fi
fi
if mutant m2 's/^lsp_escape() .*/lsp_escape() { cat; }/'; then
  new_clone m2; bash "$T/m2.sh" apply lean "$CL" >/dev/null 2> "$T/err"; RC=$?
  if ! set_is_lean "$CL" && { grep -q 'missing after the update' "$T/err" || [ -e "$CL/data/odd 1 x.txt" ]; }; then ok "F: without the glob escaping the literal name is not matched (the post-check refuses, or the look-alike sneaks in) and the lean-set check goes RED"; else bad "F: the escaping mutant was not caught (rc=$RC)"; fi
fi
if mutant m3 's/^lsp_disable() .*/lsp_disable() { :; }/'; then
  new_clone m3; run_lib apply lean "$CL"; bash "$T/m3.sh" apply full "$CL" >/dev/null 2>&1; RC=$?
  if ! set_is_full "$CL"; then ok "F: an apply full that restores nothing leaves the tree sparse and the full-tree check goes RED (rc=$RC)"; else bad "F: the apply-full mutant was not caught"; fi
fi
if mutant m4 's/^  kind=/  lsp_git fetch -q origin 2>\/dev\/null; kind=/'; then
  new_clone m4; run_lib apply lean "$CL"; rm -rf "$ORIGIN"; git -C "$CL" remote set-url origin "https://127.0.0.1:9/never.git"
  run_offline "$T/m4.sh" add skills/stacks "$CL"
  if [ "$RC" = 0 ] && set_is_lean "$CL" "$STACKS_FILES" && ! no_transport_in_trace; then ok "F: an add that quietly runs a fetch still works offline, and only the trace check goes RED"; else bad "F: the fetching mutant was not caught (rc=$RC)"; fi
fi

printf '\nlean-sparse: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
