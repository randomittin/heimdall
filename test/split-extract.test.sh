#!/usr/bin/env bash
#
# split-extract.test.sh -- T1.2 of docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md: bin/heimdall-split-extract, the tool that cuts
# hmd-skills and hmd-statusline out of heimdall's git history (plan section 2), locally, so the operator can review them before anything is pushed.
#
# The tool rewrites history (git filter-repo) and its output goes public once the operator pushes it, so the claims are about what it carries, what it
# must not carry and what it must never touch. Everything runs on a throwaway source repository shaped like heimdall's history: moved and not-moved
# paths, commits that touch one kind only, a mixed commit, a side branch merged with --no-ff, runtime caches committed under
# skills/designmatch/.heimdall, two tags, a branch that was never merged, and decoys whose names start like a moved path.
#   A. the plan's acceptance on THIS checkout (`skills --dry-run | grep -q 'path skills/stacks'`), and every exact path of both lists exists in HEAD.
#   B. --dry-run prints the plan (the path lists, pinned here to the plan's text plus the wave-0 correction) and creates and runs nothing.
#   C. skills: the result holds exactly the 21 moved files with the source's bytes, each with the commits it has in the source (INV-S6), no trace of the
#      .heimdall caches or of any other path, one branch (main), no tag, no remote, a clean checkout; the source is untouched; nothing was pushed.
#   D. statusline: the same for the 18 runtime files, conformance and suites, the source checked out on ANOTHER branch (--branch), and a GIT_DIR and
#      GIT_WORK_TREE of an unrelated repository in the caller's environment (they must not redirect any git call: the decoy stays untouched).
#   E. refusals, exit 2 with nothing created: an existing path of any kind, a missing parent, a destination inside the source, a bad source (not a repo,
#      shallow, detached without --branch, unknown branch), bad arguments. No git filter-repo: exit 3 (--dry-run says so and exits 0). A failure after
#      the clone leaves nothing behind: DIR exists only if the extract is complete.
#   F. every check can go RED: copies of the tool with ONE defect each (applied with sed) are run, and the check that guards the behaviour must fail.
# budget: ~12 s solo (measured): 4 real extractions of the small fixture (git clone + git filter-repo, 1-3 passes each, about 1 s a pass: the two
# controls in C and D, two broken copies in F), about 20 more tool runs that stop before any clone, and a few dozen git calls per result check.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/bin/heimdall-split-extract"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "split-extract: 0 passed, 0 failed (SKIPPED: git unavailable)"; exit 0; }
[ -f "$TOOL" ] || { echo "FATAL: $TOOL missing"; echo "split-extract: 0 passed, 1 failed"; exit 1; }
git filter-repo --version >/dev/null 2>&1 || { echo "SKIP: git filter-repo unavailable"; echo "split-extract: 0 passed, 0 failed (SKIPPED: git filter-repo unavailable)"; exit 0; }

WORK="$(mktemp -d)" || { echo "FATAL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# A pristine git: no global hooks, signing or defaults, and an identity for the fixture's commits.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# ── the plan's lists, restated here (this is the pin: the tool and this file change together or this goes RED) ───────────────────────────────────
SKILLS_FILES="skills/designmatch/SKILL.md skills/designmatch/assets/visual-qa.ts skills/designmatch/package-lock.json skills/designmatch/package.json
skills/designmatch/references/anti-patterns.md skills/designmatch/references/canonical-values.md
skills/designmatch/scripts/emit-parity.js skills/designmatch/scripts/fetch-canonical.js skills/designmatch/scripts/iterate-screen.sh
skills/designmatch/scripts/render-canonical.js skills/designmatch/scripts/render-web-candidate.js skills/designmatch/scripts/visual-diff.js
skills/mac-deep-clean/SKILL.md skills/self-improve/SKILL.md skills/system-health/SKILL.md skills/stacks/README.md skills/stacks/SKILL.md
skills/stacks/fastapi/PACK.md skills/stacks/nextjs/PACK.md skills/stacks/react-native/PACK.md skills/stacks/spring-boot/PACK.md"
STATUSLINE_FILES="hooks/statusline.sh hooks/subagent-statusline.sh
bin/heimdall-statusline bin/heimdall-statusline-register bin/heimdall-statusline-register-cursor bin/heimdall-sigil bin/heimdall-sigil-png
sentinels/hmd-statusline.py sentinels/hmd_sigil.py sentinels/hmd_gauge.py sentinels/hmd_sigil_png.py sentinels/hmd-sigil.py
sentinels/subagent-statusline.py sentinels/hmd-subagent-statusline.sh sentinels/hmd_layout.py sentinels/hmd_termcaps.py sentinels/hmd_ledger.py sentinels/hmd_wall.py
conformance/statusline/INVARIANTS.md conformance/statusline/goldens/density/rj_full_16.txt conformance/statusline/goldens/sigil/rj_L_16.txt
conformance/statusline/viral-sigil.fixture.sh
test/heimdall-statusline-density.test.sh test/heimdall-statusline-gauge.test.sh test/heimdall-sigil-render.test.sh test/heimdall-sigil-heroes.test.sh
test/heimdall-subagent-statusline.test.sh"
# names that must NOT travel: core files, the caches, and names that merely START like a moved path or glob
DECOYS="skills/heimdall/SKILL.md skills/heimdall/references/quality-gates.md skills/stacks-extra/SKILL.md skills/designmatch/.heimdall/cache.json
bin/stack-pack bin/heimdall README.md bin/heimdall-statusline-extra conformance/statusline-notes.md hooks/hooks.json sentinels/hmd-banner.sh
test/heimdall-status-json.test.sh test/heimdall-init-cursor-statusline.test.sh"
SKILLS_SPEC="path skills/stacks
path skills/designmatch
path skills/self-improve
path skills/system-health
path skills/mac-deep-clean"
SKILLS_DROP_SPEC="path skills/designmatch/.heimdall"
STATUSLINE_SPEC="path hooks/statusline.sh
path hooks/subagent-statusline.sh
path bin/heimdall-statusline
path bin/heimdall-statusline-register
path bin/heimdall-statusline-register-cursor
path bin/heimdall-sigil
path bin/heimdall-sigil-png
path sentinels/hmd-statusline.py
path sentinels/hmd_sigil.py
path sentinels/hmd_gauge.py
path sentinels/hmd_sigil_png.py
path sentinels/hmd-sigil.py
path sentinels/subagent-statusline.py
path sentinels/hmd-subagent-statusline.sh
path sentinels/hmd_layout.py
path sentinels/hmd_termcaps.py
path sentinels/hmd_ledger.py
path sentinels/hmd_wall.py
path conformance/statusline
path-glob test/heimdall-statusline-*.test.sh
path-glob test/heimdall-sigil-*.test.sh
path test/heimdall-subagent-statusline.test.sh"

# ── harness: run the tool with a recording git wrapper on PATH that logs every git call (and can make one fail) ─────────────────────────────────────────────
LOG="$WORK/git.log"; mkdir -p "$WORK/gitwrap"
REAL_GIT="$(command -v git)"
cat > "$WORK/gitwrap/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LOG"
if [ -n "\${GITWRAP_FAIL:-}" ]; then for a in "\$@"; do [ "\$a" = "\$GITWRAP_FAIL" ] && exit 1; done; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/gitwrap/git"
OUT=""; RC=0; EXTRA_ENV=""; WHY=""; MUT=""
# run <tool> <args>: OUT is stdout and stderr, RC the exit status, LOG every git call made; EXTRA_ENV is "NAME=value ..." for this run
run() {
  local tool="$1"; shift
  : > "$LOG"
  # shellcheck disable=SC2086
  OUT="$(env $EXTRA_ENV PATH="$WORK/gitwrap:$PATH" bash "$tool" "$@" 2>&1)"; RC=$?
}
expect()     { local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label: $WHY"; fi; WHY=""; }
expect_red() { local label="$1"; shift; if "$@"; then bad "$label: the check stayed green on the broken tool"; else ok "$label"; fi; WHY=""; }
snap() { { git -C "$1" for-each-ref --format='%(refname) %(objectname)'; git -C "$1" symbolic-ref -q HEAD; cksum < "$1/.git/config"; git -C "$1" status --porcelain; } 2>&1; }
leftovers() { local n=0 d; for d in "$WORK"/.hmd-split-extract.*; do [ -e "$d" ] && n=$((n+1)); done; echo "$n"; }

# ── the checks: each takes <kind> <result dir> <source branch>, returns 0 when the behaviour holds, else sets WHY ──────────────────────────────
have() { [ -d "$1/.git" ] || { WHY="no result at $1"; return 1; }; }
expected_files() { case "$1" in skills) printf '%s\n' $SKILLS_FILES ;; statusline) printf '%s\n' $STATUSLINE_FILES ;; esac | sort; }
counts() { git -C "$1" log --format= --name-only "$2" 2>/dev/null | sed '/^$/d' | sort | uniq -c | awk '{print $1, $2}'; }

p_files_exact() {
  have "$2" || return 1
  local got want; got="$(git -C "$2" ls-tree -r --name-only HEAD | sort)"; want="$(expected_files "$1")"
  [ "$got" = "$want" ] && return 0
  WHY="the files at HEAD differ from the plan's set: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep '^[<>]' | head -4 | tr '\n' ' ')"; return 1
}
p_history_paths() {
  have "$2" || return 1
  local extra; extra="$(comm -13 <(expected_files "$1") <(git -C "$2" log --all --format= --name-only | sed '/^$/d' | sort -u))"
  [ -z "$extra" ] && return 0
  WHY="history touches paths outside the set: $(printf '%s\n' "$extra" | head -3 | tr '\n' ' ')"; return 1
}
p_history_counts() {
  have "$2" || return 1
  local bad
  bad="$(awk -v want="$(expected_files "$1" | tr '\n' ' ')" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) need[w[i]] = 1 }
    NR == FNR { s[$2] = $1; next }
    { r[$2] = $1 }
    END { for (f in need) if (s[f] != r[f] || r[f] + 0 == 0) printf " %s(%d/%d)", f, s[f] + 0, r[f] + 0 }' <(counts "$SRC" "$3") <(counts "$2" main))"
  [ -z "$bad" ] && return 0
  WHY="commits per path, source/result:$bad"; return 1
}
p_same_bytes() {
  have "$2" || return 1
  local want got
  want="$(awk -F'\t' 'NR==FNR { w[$0]; next } $2 in w' <(expected_files "$1") <(git -C "$SRC" ls-tree -r "$3") | sort)"
  got="$(git -C "$2" ls-tree -r HEAD | sort)"
  [ "$want" = "$got" ] && return 0
  WHY="blob ids at HEAD differ from the source branch's"; return 1
}
p_subjects() {
  have "$2" || return 1
  local subj bad_re good_re good_n; subj="$(git -C "$2" log --format=%s main)"
  case "$1" in
    skills)     bad_re='^(core only|cache only|statusline)'; good_re='^(initial import|mixed: |stacks skill again|designmatch and its cache|side: fastapi pack)'; good_n=5 ;;
    statusline) bad_re='^(core only|cache only|mixed|stacks|designmatch|side|statusline decoys)'; good_re='^(initial import|statusline: renderer|statusline: subagent row)'; good_n=3 ;;
  esac
  if grep -Eq "$bad_re" <<<"$subj"; then WHY="a commit that touched only other paths travelled: $(grep -E "$bad_re" <<<"$subj" | head -2 | tr '\n' '|')"; return 1; fi
  [ "$(grep -Ec "$good_re" <<<"$subj")" = "$good_n" ] && return 0
  WHY="expected $good_n commits of this kind's own work, got: $(tr '\n' '|' <<<"$subj")"; return 1
}
p_refs_only_main() {
  have "$2" || return 1
  local refs; refs="$(git -C "$2" for-each-ref --format='%(refname)')"
  [ "$refs" = "refs/heads/main" ] && return 0
  WHY="refs in the result: $(tr '\n' ' ' <<<"$refs")"; return 1
}
p_no_remote() {
  have "$2" || return 1
  if [ -n "$(git -C "$2" remote)" ] || grep -q '^\[remote' "$2/.git/config"; then WHY="the result has a remote: $(git -C "$2" remote | tr '\n' ' ')"; return 1; fi
}
p_checkout() {
  have "$2" || return 1
  [ "$(git -C "$2" symbolic-ref --short HEAD)" = main ] && [ -z "$(git -C "$2" status --porcelain)" ] && return 0
  WHY="HEAD is not main with a clean work tree"; return 1
}
# the plan's own INV-S6 command, literally, on three paths whose commit counts the fixture fixes (3, 2 through the merge, 2)
p_inv_s6_literal() {
  have "$2" || return 1
  local p want got
  for p in skills/stacks/SKILL.md:3 skills/stacks/fastapi/PACK.md:2 skills/designmatch/SKILL.md:2; do
    want="${p##*:}"; got="$(git -C "$2" log --oneline -- "${p%%:*}" | wc -l | tr -d ' ')"
    [ "$got" = "$want" ] || { WHY="git log --oneline -- ${p%%:*} | wc -l is $got in the result, the source has $want"; return 1; }
  done
}
p_no_push() {
  if grep -Eq '(^|[[:space:]])push([[:space:]]|$)|remote (add|set-url|rename)' "$LOG"; then WHY="the git calls include: $(grep -E 'push|remote (add|set-url|rename)' "$LOG" | head -2 | tr '\n' '|')"; return 1; fi
}
p_untouched() { [ "$(snap "$2")" = "$1" ] && return 0; WHY="$2 changed"; return 1; }
p_dry_run_clean() {
  [ ! -e "$1" ] || { WHY="$1 was created"; return 1; }
  if grep -Eq 'clone|--force' "$LOG"; then WHY="a dry run cloned or rewrote: $(grep -E 'clone|--force' "$LOG" | head -1)"; return 1; fi
}
p_refused() { [ "$RC" = 2 ] && [ "$(ls -A "$1")" = marker ] && return 0; WHY="exit $RC, the existing directory now holds: $(ls -A "$1" | tr '\n' ' ')"; return 1; }
p_nothing_left() { [ ! -e "$1" ] && [ "$(leftovers)" = 0 ] && return 0; WHY="exit $RC, destination exists: $([ -e "$1" ] && echo yes || echo no), temp dirs left: $(leftovers)"; return 1; }

verify_result() { # verify_result <kind> <result dir> <source branch>
  local k="$1" d="$2" b="$3"
  expect "$k: exactly the plan's files are at HEAD" p_files_exact "$k" "$d" "$b"
  expect "$k: no commit ever touched a path outside the set (caches, decoys, the other repo's files)" p_history_paths "$k" "$d" "$b"
  expect "$k: each path keeps the commits it has in the source (INV-S6)" p_history_counts "$k" "$d" "$b"
  expect "$k: the same bytes at the same paths as the source branch (INV-S1)" p_same_bytes "$k" "$d" "$b"
  expect "$k: commits that touched only other paths are gone, the mixed ones stay" p_subjects "$k" "$d" "$b"
  expect "$k: one branch (main), no tag, no other ref" p_refs_only_main "$k" "$d" "$b"
  expect "$k: no remote" p_no_remote "$k" "$d" "$b"
  expect "$k: a clean work tree on main" p_checkout "$k" "$d" "$b"
}
plan_keep() { awk '/--invert-paths/ { exit } /^  path(-glob)? / { sub(/^  /, ""); print }' <<<"$1" | sort; }
plan_drop() { awk '/--invert-paths/ { f = 1; next } f && /^  path(-glob)? / { sub(/^  /, ""); print }' <<<"$1" | sort; }

echo "== A) the plan's acceptance, on this checkout =="
if bash -n "$TOOL"; then ok "the tool parses (bash -n)"; else bad "the tool does not parse"; fi
if [ -x "$TOOL" ]; then ok "bin/heimdall-split-extract is executable"; else bad "bin/heimdall-split-extract is not executable"; fi
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = false ] && git -C "$ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
  for kind in skills statusline; do
    PLAN="$("$TOOL" "$kind" --dry-run 2>/dev/null)"
    if [ "$kind" = skills ]; then
      if grep -q 'path skills/stacks' <<<"$PLAN"; then ok "bin/heimdall-split-extract skills --dry-run | grep -q 'path skills/stacks'"
      else bad "the plan's accept line fails on this checkout"; fi
    fi
    # the keep list only: the drop list (skills/designmatch/.heimdall) is history, it is no longer in HEAD
    MISSING=""
    while IFS= read -r p; do git -C "$ROOT" cat-file -e "HEAD:$p" 2>/dev/null || MISSING="$MISSING $p"; done \
      < <(plan_keep "$PLAN" | sed -n 's/^path \(.*\)$/\1/p')
    if [ -z "$MISSING" ]; then ok "$kind: every exact path of the keep list exists in this checkout's HEAD"; else bad "$kind: paths of the keep list missing from HEAD:$MISSING"; fi
  done
else
  echo "  skip: this checkout is shallow or on a detached HEAD (the tool refuses such a source, section E); the fixture below covers the tool"
fi

echo "== B) the fixture, and --dry-run =="
SRC="$WORK/src"
git init -q "$SRC" && git -C "$SRC" symbolic-ref HEAD refs/heads/trunk
put() { local d="${1%/*}"; [ "$d" = "$1" ] && d=.; [ -d "$SRC/$d" ] || mkdir -p "$SRC/$d"; printf '%s\n' "$2" > "$SRC/$1"; }
rev() { local msg="$1" v="$2" f; shift 2; for f in "$@"; do put "$f" "$f $v"; done; git -C "$SRC" add -A && git -C "$SRC" commit -q -m "$msg"; }
# shellcheck disable=SC2086
rev "initial import" v1 $SKILLS_FILES $STATUSLINE_FILES $DECOYS
rev "mixed: stacks skill and a core bin" v2 skills/stacks/SKILL.md bin/heimdall
rev "core only: bump heimdall" v3 bin/heimdall README.md
rev "stacks skill again" v3 skills/stacks/SKILL.md
git -C "$SRC" tag v9.9.9
rev "designmatch and its cache" v2 skills/designmatch/SKILL.md skills/designmatch/.heimdall/cache.json
rev "cache only" v3 skills/designmatch/.heimdall/cache.json
git -C "$SRC" tag -a v9.9.10 -m release
git -C "$SRC" checkout -q -b side v9.9.9
rev "side: fastapi pack" v2 skills/stacks/fastapi/PACK.md
git -C "$SRC" checkout -q trunk
rev "core only: second bump" v4 bin/heimdall
git -C "$SRC" merge -q --no-ff side -m "merge side"
rev "statusline: renderer" v2 bin/heimdall-statusline sentinels/hmd_sigil.py test/heimdall-statusline-density.test.sh
rev "statusline: subagent row" v3 bin/heimdall-statusline test/heimdall-subagent-statusline.test.sh conformance/statusline/INVARIANTS.md
rev "statusline decoys only" v2 bin/heimdall-statusline-extra test/heimdall-status-json.test.sh
git -C "$SRC" checkout -q -b feature/unrelated
rev "unmerged work, must not travel" v9 skills/self-improve/SKILL.md bin/heimdall-statusline
git -C "$SRC" checkout -q trunk
DECOY="$WORK/decoy"; git init -q "$DECOY" && git -C "$DECOY" symbolic-ref HEAD refs/heads/decoy && printf 'x\n' > "$DECOY/x" && git -C "$DECOY" add x && git -C "$DECOY" commit -q -m decoy
TRUNK_SHORT="$(git -C "$SRC" rev-parse --short=12 trunk)"

SNAP_SRC="$(snap "$SRC")"
run "$TOOL" skills --dry-run --source "$SRC" --to "$WORK/out-dry"
if [ "$RC" = 0 ]; then ok "skills --dry-run exits 0"; else bad "skills --dry-run: exit $RC: $(tail -2 <<<"$OUT")"; fi
if [ "$(plan_keep "$OUT")" = "$(sort <<<"$SKILLS_SPEC")" ]; then ok "skills: the plan's five paths are kept, nothing else"; else bad "skills: kept paths differ: $(plan_keep "$OUT" | tr '\n' '|')"; fi
if [ "$(plan_drop "$OUT")" = "$SKILLS_DROP_SPEC" ]; then ok "skills: the second pass drops skills/designmatch/.heimdall (the committed runtime caches)"; else bad "skills: dropped paths differ: $(plan_drop "$OUT" | tr '\n' '|')"; fi
if grep -qF "branch trunk @ $TRUNK_SHORT" <<<"$OUT" && grep -qF 'destination' <<<"$OUT"; then ok "skills: the plan names the source branch and commit (the source's own branch is the default)"; else bad "skills: no source branch and commit in the plan: $(head -4 <<<"$OUT")"; fi
expect "skills --dry-run creates nothing and runs no clone or rewrite" p_dry_run_clean "$WORK/out-dry"
expect "skills --dry-run leaves the source untouched" p_untouched "$SNAP_SRC" "$SRC"
run "$TOOL" statusline --dry-run --source "$SRC"
if [ "$RC" = 0 ] && [ "$(plan_keep "$OUT")" = "$(sort <<<"$STATUSLINE_SPEC")" ] && [ -z "$(plan_drop "$OUT")" ]; then ok "statusline: the plan's 18 runtime files, conformance, both globs and the subagent suite (wave-0 correction); no second pass"
else bad "statusline --dry-run (exit $RC): kept paths differ: $(diff <(plan_keep "$OUT") <(sort <<<"$STATUSLINE_SPEC") | head -4 | tr '\n' ' ')"; fi
if grep -qF 'none: a real run needs --to DIR' <<<"$OUT"; then ok "a dry run needs no --to and says so"; else bad "no note about the missing --to in the plan"; fi
run "$TOOL" --help
if [ "$RC" = 0 ] && grep -qF -- '--dry-run' <<<"$OUT" && grep -qF 'never' <<<"$OUT"; then ok "--help exits 0 and states the contract"; else bad "--help: exit $RC"; fi

echo "== C) skills: the extract, from the source's own branch =="
SNAP_SRC="$(snap "$SRC")"
run "$TOOL" skills --to "$WORK/out-skills" --source "$SRC"
if [ "$RC" = 0 ] && [ -d "$WORK/out-skills/.git" ]; then ok "skills: exit 0, the repository is at the destination"; else bad "skills: exit $RC: $(tail -4 <<<"$OUT")"; fi
verify_result skills "$WORK/out-skills" trunk
expect "skills: the plan's own INV-S6 command gives the source's counts" p_inv_s6_literal skills "$WORK/out-skills" trunk
expect "skills: nothing was pushed and no remote was added or renamed (the git calls are logged)" p_no_push
expect "skills: the source repository is untouched" p_untouched "$SNAP_SRC" "$SRC"
expect "skills: no work directory is left next to the destination" p_nothing_left "$WORK/none"

echo "== D) statusline: --branch, the source on another branch, GIT_DIR of an unrelated repository in the environment =="
git -C "$SRC" checkout -q feature/unrelated
SNAP_SRC="$(snap "$SRC")"; SNAP_DECOY="$(snap "$DECOY")"
EXTRA_ENV="GIT_DIR=$DECOY/.git GIT_WORK_TREE=$DECOY GIT_INDEX_FILE=$DECOY/.git/index"
run "$TOOL" statusline --to "$WORK/out-sl" --source "$SRC" --branch trunk
EXTRA_ENV=""
if [ "$RC" = 0 ] && [ -d "$WORK/out-sl/.git" ]; then ok "statusline: exit 0 although the caller's GIT_DIR points elsewhere"; else bad "statusline: exit $RC: $(tail -4 <<<"$OUT")"; fi
verify_result statusline "$WORK/out-sl" trunk
expect "statusline: nothing was pushed and no remote was added or renamed" p_no_push
expect "statusline: the source repository is untouched" p_untouched "$SNAP_SRC" "$SRC"
expect "statusline: the unrelated repository named by GIT_DIR is untouched" p_untouched "$SNAP_DECOY" "$DECOY"

echo "== E) refusals, and a failure after the clone =="
refused() { # refused <label> <needle> <tool args>: exit 2 and the message names <needle>
  local label="$1" needle="$2"; shift 2
  run "$TOOL" "$@"
  if [ "$RC" = 2 ] && grep -qiF -- "$needle" <<<"$OUT"; then ok "$label"; else bad "$label (exit $RC, wanted 2 naming '$needle'): $(head -2 <<<"$OUT")"; fi
}
A="--source $SRC --branch trunk"
mkdir "$WORK/e-empty"; mkdir "$WORK/e-full"; printf 'keep\n' > "$WORK/e-full/marker"; : > "$WORK/e-file"; ln -s "$WORK/nowhere" "$WORK/e-link"
# shellcheck disable=SC2086
{
refused "an existing empty directory is refused" "already exists" skills --to "$WORK/e-empty" $A
refused "an existing directory with files is refused" "already exists" skills --to "$WORK/e-full" $A
refused "an existing regular file is refused" "already exists" skills --to "$WORK/e-file" $A
refused "a dangling symlink is refused" "already exists" skills --to "$WORK/e-link" $A
refused "a missing parent directory is refused (no deep directories made from a typo)" "parent" skills --to "$WORK/no/such/dir" $A
refused "a destination inside the source work tree is refused" "inside the source" skills --to "$SRC/new-repo" $A
refused "no --to without --dry-run" "--to" skills $A
refused "no repo name" "skills"
refused "an unknown repo name" "unknown repo" frobnicate
refused "an unknown option" "unknown option" skills --bogus
mkdir "$WORK/plain"
refused "a source that is no git work tree" "not inside a git work tree" skills --to "$WORK/x1" --source "$WORK/plain"
refused "an unknown source branch" "no branch" skills --to "$WORK/x2" --source "$SRC" --branch nope
}
git clone -q --depth 1 --no-local --branch trunk "$SRC" "$WORK/shallow" 2>/dev/null
refused "a shallow source (its history is cut short, so the extract would be too)" "shallow" skills --to "$WORK/x3" --source "$WORK/shallow"
git -C "$SRC" checkout -q --detach trunk
refused "a detached source HEAD without --branch" "detached" skills --to "$WORK/x4" --source "$SRC"
if [ -z "$(ls -A "$WORK/e-empty")" ] && [ "$(ls -A "$WORK/e-full")" = marker ] && [ ! -s "$WORK/e-file" ] && [ ! -e "$WORK/x1" ] && [ ! -e "$WORK/x2" ] \
   && [ ! -e "$WORK/x3" ] && [ ! -e "$WORK/x4" ] && [ ! -e "$WORK/no" ] && [ "$(leftovers)" = 0 ]; then ok "the refusals created, changed and left nothing"
else bad "a refusal left something behind: $(ls -A "$WORK" | tr '\n' ' ')"; fi

EXTRA_ENV="GITWRAP_FAIL=--version"
run "$TOOL" skills --to "$WORK/x5" --source "$SRC" --branch trunk
if [ "$RC" = 3 ] && grep -qF 'pip install --user git-filter-repo' <<<"$OUT" && [ ! -e "$WORK/x5" ]; then ok "no git filter-repo: exit 3, names the user-level install, creates nothing"; else bad "no git filter-repo: exit $RC: $(tail -2 <<<"$OUT")"; fi
run "$TOOL" skills --dry-run --source "$SRC" --branch trunk
if [ "$RC" = 0 ] && grep -qF 'NOT FOUND' <<<"$OUT"; then ok "--dry-run without git filter-repo still prints the plan, says NOT FOUND and exits 0"; else bad "--dry-run without filter-repo: exit $RC"; fi
EXTRA_ENV="GITWRAP_FAIL=--force"
run "$TOOL" skills --to "$WORK/x6" --source "$SRC" --branch trunk
EXTRA_ENV=""
if [ "$RC" = 1 ] && grep -qF 'filter-repo failed' <<<"$OUT"; then ok "a git filter-repo that fails: exit 1 and the message says which pass"; else bad "failing filter-repo: exit $RC: $(tail -2 <<<"$OUT")"; fi
expect "a failure after the clone leaves no destination and no work directory" p_nothing_left "$WORK/x6"

echo "== F) every check can go RED: copies of the tool with one defect each =="
make_mutant() { # make_mutant <name> <sed args>: MUT is a copy of the tool with the edit applied; the edit must change it and it must still parse
  local name="$1"; shift
  mkdir -p "$WORK/mutants/$name"; MUT="$WORK/mutants/$name/heimdall-split-extract"
  sed "$@" "$TOOL" > "$MUT"
  if cmp -s "$TOOL" "$MUT"; then bad "mutant $name: the sed edit changed nothing (the tool moved on)"; return 1; fi
  if ! bash -n "$MUT" 2>/dev/null; then bad "mutant $name does not parse, so a RED would prove nothing"; return 1; fi
}
R="$WORK/out-m1"
if make_mutant carry-everything -e 's/ --no-tags --single-branch//' -e 's|^  "path skills/designmatch/.heimdall"|  "path skills/designmatch/.heimdall-typo"|' -e '/^  "path skills\/self-improve"/d' \
     -e 's|^mv -- "\$WORK" "\$DEST"|git -C "$WORK" remote add upstream /nonexistent; git -C "$WORK" push upstream main; &|'; then
  run "$MUT" skills --to "$R" --source "$SRC" --branch trunk
  if [ -d "$R/.git" ]; then
    expect_red "tags and every branch carried (no --no-tags --single-branch): the refs check fails" p_refs_only_main skills "$R" trunk
    expect_red "the .heimdall caches left in history (a typo in the drop path): the history-paths check fails" p_history_paths skills "$R" trunk
    expect_red "a moved path left out of the list: the file-set check fails" p_files_exact skills "$R" trunk
    expect_red "a moved path left out of the list: the per-path history check fails" p_history_counts skills "$R" trunk
    expect_red "a remote added: the no-remote check fails" p_no_remote skills "$R" trunk
    expect_red "a push attempted: the git-call check fails" p_no_push
  else bad "mutant carry-everything made no result (exit $RC): $(tail -2 <<<"$OUT")"; fi
fi
R="$WORK/out-m3"
if make_mutant no-sigil-glob -e '/^  "path-glob test\/heimdall-sigil-\*.test.sh"/d'; then
  run "$MUT" statusline --to "$R" --source "$SRC" --branch trunk
  if [ -d "$R/.git" ]; then
    expect_red "a glob dropped from the list: the file-set check fails" p_files_exact statusline "$R" trunk
    expect_red "a glob dropped from the list: the per-path history check fails" p_history_counts statusline "$R" trunk
  else bad "mutant no-sigil-glob made no result (exit $RC): $(tail -2 <<<"$OUT")"; fi
fi
if make_mutant no-env-scrub -e '/local-env-vars/d'; then
  EXTRA_ENV="GIT_DIR=$DECOY/.git GIT_WORK_TREE=$DECOY GIT_INDEX_FILE=$DECOY/.git/index"
  run "$MUT" statusline --to "$WORK/out-m2" --source "$SRC" --branch trunk
  EXTRA_ENV=""
  expect_red "the caller's GIT_DIR not dropped: the extract no longer comes out right (section D is the control)" p_files_exact statusline "$WORK/out-m2" trunk
fi
# (the two runs below end in a failing git filter-repo on purpose: the defect shows in the log and the exit code, so no full extract is paid for)
if make_mutant dry-run-runs -e 's/^  exit 0$/  :/'; then
  EXTRA_ENV="GITWRAP_FAIL=--force"
  run "$MUT" skills --dry-run --to "$WORK/out-m4" --source "$SRC" --branch trunk
  EXTRA_ENV=""
  expect_red "a dry run that does not stop: the creates-nothing check fails" p_dry_run_clean "$WORK/out-m4"
fi
mkdir "$WORK/exists-m5"; printf 'keep\n' > "$WORK/exists-m5/marker"
if make_mutant no-exists-guard -e 's/^\( *\)refuse_if_exists /\1true /'; then
  EXTRA_ENV="GITWRAP_FAIL=--force"
  run "$MUT" statusline --to "$WORK/exists-m5" --source "$SRC" --branch trunk
  EXTRA_ENV=""
  expect_red "the existing-path guard removed: an existing directory is no longer refused up front (exit 2)" p_refused "$WORK/exists-m5"
fi
if make_mutant no-cleanup -e 's/rm -rf -- "\$WORK"/:/'; then
  EXTRA_ENV="GITWRAP_FAIL=--force"
  run "$MUT" skills --to "$WORK/out-m6" --source "$SRC" --branch trunk
  EXTRA_ENV=""
  expect_red "the cleanup removed: a failed run leaves its work directory behind" p_nothing_left "$WORK/out-m6"
fi

echo
echo "split-extract: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
