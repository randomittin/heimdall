#!/usr/bin/env bash
# test/heimdall-push-gate-per-repo.test.sh
#
# Proof that the PreToolUse push gate runs EACH REPO'S OWN checks, not heimdall's -- and that it fails CLOSED when it cannot tell.
#
# THE DEFECT (2026-10-13): the push chain in bin/heimdall-precheck-bash called `heimdall-state
# check-quality-gates` in the SESSION's cwd, whatever repository the command actually pushed. That
# gate demands heimdall's own sweep receipt (.heimdall/receipts/last-sweep.json, written only by
# heimdall's test/run-all.sh) plus the booleans in heimdall-state.json, so a push of the site repo
# (which has six gates of its own, none of them heimdall's sweep) was blocked with "no sweep
# receipt at <site>/.heimdall/receipts/last-sweep.json" -- a receipt that repo can never produce.
#
# THE RULE UNDER TEST (operator, verbatim): "run each repo's own checks, not heimdall's. A repo
# with its own record of passing checks passes on that record. A repo hmd doesn't manage gets a
# warning but isn't blocked. Don't drop the gate altogether."
#   target   the repo the push goes to, ASKED OF GIT: the cwd, `git -C <dir>`, `cd <dir> && ...`, --git-dir, GIT_DIR, a linked
#            worktree, a subdirectory -- git names the git directory the push operates on, and the work tree root is checked back
#   class    read from the COMMITS a push can carry (HEAD, its upstream @{u}/@{push}, origin/HEAD, origin/<branch>, the refspecs
#            named) with `git ls-tree` / `git cat-file`, never from the work tree, and the STRICTEST class over them wins
#   (a) sweep        the repo carries heimdall's sweep regime (test/run-all.sh naming last-sweep.json)
#                    -> the old gate, unchanged, fail closed
#   (b) repo-checks  .heimdall/repo-checks.json declares the repo's own checks -> passes ONLY on a
#                    green, current, clean-tree receipt (.heimdall/receipts/repo-checks.json) bound to the
#                    commit, its tree and the declaration it was recorded for
#   (c) unmanaged    one WARNING line on stderr, exit 0 -- ONLY when the command was understood EXACTLY, git resolved the repository
#                    AND no commit inspected has either marker. Any construct not modelled exactly (a `cd` that is dynamic, `cd -`,
#                    through CDPATH or inside if/for/case/{ }, a function, `source`, `alias`, a script piped to a shell, an expansion
#                    hiding a substitution, find -exec ... git push, xargs handing over the subcommand, a git option or subcommand it
#                    does not know -- an alias may be a push --, an unmodelled GIT_* variable, a repository git cannot place, a marker
#                    that cannot be inspected) makes the whole command uncertain, and then EVERY repo involved gets the strict class (a).
# Secret / self-scan gates are not part of this rule and are not relaxed (section D proves it).
#
# Everything here runs in throwaway repos under one mktemp dir, removed on exit. The hook is the
# REAL bin/heimdall-precheck-bash with a fake plugin root around it (fake heimdall-state that
# records where and whether it was called, fake secret-scan); no real push is ever made.
#
#   A  bin/heimdall-repo-checks  run / status, receipt binding, forged and mismatched receipts, and the ONE receipt definition
#      (bin/lib/hmd_repo_receipt.py): a receipt `run` writes passes, every field mutated on its own fails
#   B  bin/lib/hmd_push_target.py  (the target resolver + classifier): classes, forms, fail-closed, git differential,
#      the parse model (substitutions, eval, sh -c, xargs, pushd, chains of cd, cd - / ~ / "$VAR"), classes from commits
#   C  the hook: each class, target != cwd, multi-target, downgrade attempts, forged receipts, resolver missing
#   D  security gates stay on
#
# Proofs worth knowing by name: A7 (one receipt definition, every field mutated alone), A8 (a receipt attests ONE commit), A9 (a corrupt record is
# never green), B "the class is read from the COMMITS" (an uncommitted marker edit or deletion changes nothing; HEAD, @{u}, origin and the
# refspecs, strictest wins), B "the shell differential" (every corpus command is RUN by real bash and zsh with a recording git, and the
# repositories the pushes really went to are compared with the resolver's answer), B "EVERY error path is strict" (a git that fails, prints
# nonsense or hangs at each call the resolver makes), C40-C43 (refspecs vs the receipt), C44-C48 (the hook's own error paths).
#
# REVIEW ROUND 2026-10-14 (the last security review of the push gate), one proof family per finding:
#   1. a resolver that cannot answer (timeout, crash, missing) must not fall back to ONE repository: C50-C53 (the strict gate runs against the
#      session cwd, the payload cwd and every -C / cd target the parser had reached, and blocks unless all pass)
#   2. ONE resolved (git dir, work tree) pair feeds classification, refspec resolution, the receipt lookup and the heimdall-state check: B "pair"
#      (git's own answer per layout), B "GIT_*" (a variable the resolver does not reproduce is uncertain), C54-C58 (the hook hands the pair on),
#      C59 (the receipt lookup verifies it from the other end and never rediscovers)
#   3. self-audit: A10 (a symlinked .heimdall / receipts / receipt is never followed; size, depth and type abuse of a receipt or declaration),
#      C60 (one commit throughout a status), C61 (a symlink through the hook), C53 (a gate directory that cannot be entered blocks), B "linear time"
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC_BIN="$REPO/bin/heimdall-repo-checks"
HELPER="$REPO/bin/lib/hmd_push_target.py"
RC_PY="$REPO/bin/lib/hmd_repo_checks.py"          # the runner/gate behind the launcher
RC_DEF="$REPO/bin/lib/hmd_repo_receipt.py"        # the ONE definition of the receipt
HOOK="$REPO/bin/heimdall-precheck-bash"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
section() { printf '\n%s\n' "$1"; }

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hmd-pushgate.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
MARKS="$W/marks"; mkdir -p "$MARKS" "$W/repos" "$W/wt"
# hermetic git: no user config, hooks or signing from this machine reach the throwaway repos
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset HEIMDALL_HOME HEIMDALL_STATE_FILE SUPERX_STATE_FILE GIT_DIR GIT_WORK_TREE CDPATH
TAB=$'\t'
ZERO64="0000000000000000000000000000000000000000000000000000000000000000"

# ── fixtures ────────────────────────────────────────────────────────────────
new_repo() {  # new_repo <name> -> physical path of a fresh repo with one commit
  local d="$W/repos/$1"
  mkdir -p "$d"
  # the branch is main: `push origin main` names a ref that exists, as it does in a real checkout (an unknown refspec is strict)
  ( cd "$d" && git init -q && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t && git config commit.gpgsign false \
      && printf 'v1\n' > file.txt && printf '.heimdall/receipts/\n' > .gitignore && git add -A && git commit -q -m init )
  ( cd "$d" && pwd -P )
}
commit_all() { ( cd "$1" && git add -A && git commit -q -m "$2" ); }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
decl_json() {  # decl_json <name> <cmd> [<name> <cmd> ...] -> a repo-checks.json document
  local args=() filter='' sep='' i=0
  while [ $# -ge 2 ]; do
    args+=(--arg "n$i" "$1" --arg "c$i" "$2")
    filter="$filter$sep{name:\$n$i,cmd:\$c$i}"; sep=','; i=$((i + 1)); shift 2
  done
  jq -nc "${args[@]}" "{schema:1, checks:[$filter]}"
}
mk_sweep() {  # a heimdall sweep repo: its own test/run-all.sh names the sweep receipt
  local d; d="$(new_repo "$1")"
  mkdir -p "$d/test"
  printf '#!/usr/bin/env bash\nRECEIPT_FILE="$RECEIPT_DIR/last-sweep.json"\n' > "$d/test/run-all.sh"
  commit_all "$d" sweep
  printf '%s' "$d"
}
mk_checks() {  # mk_checks <name> <declaration-json> -> a repo declaring its own checks
  local d; d="$(new_repo "$1")"
  mkdir -p "$d/.heimdall"
  printf '%s\n' "$2" > "$d/.heimdall/repo-checks.json"
  commit_all "$d" declare
  printf '%s' "$d"
}
GREEN_DECL="$(decl_json first 'printf "first\n" >> "$ORDER"' where 'pwd -P >> "$ORDER"')"
run_checks() {  # run_checks <repo> [cwd] -> RCRC; the runner's own output is in $W/rc.out / $W/rc.err
  ORDER="$W/order.log" bash -c 'cd "$1" && shift && exec "$@"' _ "${2:-$W}" bash "$RC_BIN" run --repo "$1" >"$W/rc.out" 2>"$W/rc.err"
  RCRC=$?
}
status_of() { bash "$RC_BIN" status --repo "$1" >"$W/st.out" 2>"$W/st.err"; STRC=$?; STOUT="$(cat "$W/st.out" "$W/st.err")"; }
receipt_of() { printf '%s/.heimdall/receipts/repo-checks.json' "$1"; }

# ════════════════════════════════════════════════════════════════════════════
section "0. the pieces exist and parse"
[ -x "$RC_BIN" ] && ok "0a. bin/heimdall-repo-checks is executable" || bad "0a. bin/heimdall-repo-checks missing or not executable"
bash -n "$RC_BIN" 2>/dev/null && ok "0b. bash -n bin/heimdall-repo-checks" || bad "0b. bin/heimdall-repo-checks does not parse"
for py in "$HELPER" "$RC_PY" "$RC_DEF"; do
  if python3 -I -S -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$py" 2>/dev/null; then
    ok "0c. ${py#"$REPO"/} parses"
  else
    bad "0c. ${py#"$REPO"/} missing or does not parse"
  fi
done
bash -n "$HOOK" 2>/dev/null && ok "0d. bash -n bin/heimdall-precheck-bash" || bad "0d. bin/heimdall-precheck-bash does not parse"

# ════════════════════════════════════════════════════════════════════════════
section "A. bin/heimdall-repo-checks"

# A1. a green run: from a foreign cwd, in order, from the repo root, receipt complete, bound and atomic
A1="$(mk_checks a1 "$GREEN_DECL")"
: > "$W/order.log"
run_checks "$A1"
[ "$RCRC" = 0 ] && ok "A1. run: every check green -> exit 0" || bad "A1. run: every check green -> exit 0" "rc=$RCRC: $(cat "$W/rc.err" | head -c 300)"
R="$(receipt_of "$A1")"
HEAD_A1="$(git -C "$A1" rev-parse HEAD)"
TREE_A1="$(git -C "$A1" rev-parse 'HEAD^{tree}')"
DECL_A1="$(sha256 "$A1/.heimdall/repo-checks.json")"
if jq -e --arg h "$HEAD_A1" --arg t "$TREE_A1" --arg d "$DECL_A1" '.schema == 1 and .head_sha == $h and .tree_sha == $t and .decl_sha256 == $d
    and .exit_code == 0 and .dirty == false
    and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.checks | length) == 2
    and ([.checks[] | (.exit_code == 0) and (.secs | type == "number" and . >= 0)] | all)
    and (.checks[0] | .name == "first" and .cmd == "printf \"first\\n\" >> \"$ORDER\"")
    and (.checks[1].name == "where")' "$R" >/dev/null 2>&1; then
  ok "A1. receipt: schema 1, full head_sha, tree_sha, decl_sha256, exit_code 0, dirty false, ISO finished_at, per-check name/cmd/exit_code/secs"
else
  bad "A1. receipt fields wrong" "$(head -c 600 "$R" 2>/dev/null)"
fi
if [ "$(sed -n 1p "$W/order.log")" = first ] && [ "$(sed -n 2p "$W/order.log")" = "$A1" ]; then
  ok "A1. checks ran in declared order, each from the repo root (even when started elsewhere)"
else
  bad "A1. order / working directory wrong" "$(cat "$W/order.log")"
fi
if [ "$(ls -A "$(dirname "$R")")" = "repo-checks.json" ]; then ok "A1. receipt written atomically: no temp file left beside it"; else bad "A1. stray files in the receipts dir" "$(ls -A "$(dirname "$R")")"; fi
status_of "$A1"
{ [ "$STRC" = 0 ] && grep -q 'GREEN' <<<"$STOUT"; } && ok "A1. status: green + current -> exit 0, says GREEN" || bad "A1. status of a fresh green receipt" "rc=$STRC $STOUT"
( cd "$A1" && mkdir -p sub && cd sub && bash "$RC_BIN" status >"$W/st.out" 2>&1 ); [ "$?" = 0 ] && ok "A1. status with no --repo resolves the toplevel from the cwd (a subdirectory)" || bad "A1. status with no --repo from a subdirectory" "$(cat "$W/st.out")"

# A2. a red check does not stop the others; the receipt is red; status names the failure and the runner
A2="$(mk_checks a2 "$(decl_json ok-one 'true' bad 'exit 3' after-bad 'true')")"
run_checks "$A2"
[ "$RCRC" != 0 ] && ok "A2. run: a failing check -> nonzero exit" || bad "A2. run: a failing check must exit nonzero"
if jq -e '.exit_code != 0 and (.checks | length) == 3 and .checks[1].exit_code == 3 and .checks[2].exit_code == 0' "$(receipt_of "$A2")" >/dev/null 2>&1; then
  ok "A2. the receipt is red, records every check (the one after the failure still ran) with its own exit code"
else
  bad "A2. red receipt shape" "$(head -c 400 "$(receipt_of "$A2")" 2>/dev/null)"
fi
status_of "$A2"
{ [ "$STRC" = 1 ] && grep -q 'NOT GREEN' <<<"$STOUT" && grep -q 'bad' <<<"$STOUT" && grep -q "heimdall-repo-checks run --repo $A2" <<<"$STOUT"; } \
  && ok "A2. status: red -> exit 1, NOT GREEN, names the failing check and the runner command" || bad "A2. status of a red receipt" "rc=$STRC $STOUT"

# A3. tracked changes at run time are recorded and never satisfy the gate; untracked files are not changes
A3="$(mk_checks a3 "$GREEN_DECL")"
printf 'untracked\n' > "$A3/package-lock.json"
run_checks "$A3"
jq -e '.dirty == false' "$(receipt_of "$A3")" >/dev/null 2>&1 && ok "A3. an untracked file does not make the tree dirty" || bad "A3. an untracked file made the receipt dirty"
printf 'v2\n' > "$A3/file.txt"
run_checks "$A3"
{ [ "$RCRC" = 0 ] && jq -e '.dirty == true and .exit_code == 0' "$(receipt_of "$A3")" >/dev/null 2>&1; } \
  && ok "A3. an uncommitted tracked change -> dirty:true recorded (the checks themselves passed)" || bad "A3. dirty tree not recorded" "rc=$RCRC $(head -c 300 "$(receipt_of "$A3")")"
grep -qi 'uncommitted' "$W/rc.err" && ok "A3. run warns that a dirty-tree receipt will not satisfy the gate" || bad "A3. no dirty-tree warning from run" "$(cat "$W/rc.err" | head -c 300)"
status_of "$A3"
{ [ "$STRC" = 1 ] && grep -qi 'uncommitted tracked changes' <<<"$STOUT"; } && ok "A3. status: dirty receipt -> NOT GREEN, says why" || bad "A3. status of a dirty receipt" "rc=$STRC $STOUT"

# A3b. a check that dirties the tree during the run is recorded the same way
A3B="$(mk_checks a3b "$(decl_json touches 'echo changed > file.txt')")"
run_checks "$A3B"
jq -e '.dirty == true' "$(receipt_of "$A3B")" >/dev/null 2>&1 && ok "A3b. a check that modifies a tracked file leaves dirty:true" || bad "A3b. tree dirtied by a check not recorded"
# A3c. ...and so does a check that rewrites its own declaration
A3C="$(mk_checks a3c "$(decl_json rewrites 'jq . .heimdall/repo-checks.json > .heimdall/tmp.json && cp .heimdall/tmp.json .heimdall/repo-checks.json')")"
run_checks "$A3C"
jq -e '.dirty == true' "$(receipt_of "$A3C")" >/dev/null 2>&1 && ok "A3c. a check that rewrites the declaration it ran under leaves dirty:true" || bad "A3c. declaration rewritten by a check not recorded" "$(head -c 300 "$(receipt_of "$A3C")")"
# A3d. a declaration that is not committed is not what a push carries: the checks run, the receipt is dirty, and status refuses (HEAD declares nothing)
A3D="$(new_repo a3d)"; mkdir -p "$A3D/.heimdall"; printf '%s\n' "$GREEN_DECL" > "$A3D/.heimdall/repo-checks.json"
run_checks "$A3D"
{ [ "$RCRC" = 0 ] && jq -e '.dirty == true' "$(receipt_of "$A3D")" >/dev/null 2>&1; } && ok "A3d. an uncommitted declaration: the checks run, the receipt records dirty:true" || bad "A3d. uncommitted declaration" "rc=$RCRC $(head -c 300 "$(receipt_of "$A3D")")"
bash "$RC_BIN" status --repo "$A3D" >"$W/o" 2>&1; { [ "$?" = 2 ] && grep -q 'repo-checks.json' "$W/o"; } && ok "A3d. ...and status refuses: the commit declares no checks" || bad "A3d. status of an uncommitted declaration" "$(cat "$W/o")"

# A4. status verdicts on crafted receipts (each mutation of a fresh green one)
A4="$(mk_checks a4 "$GREEN_DECL")"
run_checks "$A4"
cp "$(receipt_of "$A4")" "$W/a4.green"
cp "$A4/.heimdall/repo-checks.json" "$W/a4.decl"
expect_status() {  # expect_status <label> <want-rc> <pattern> -- uses the receipt currently on disk
  status_of "$A4"
  if [ "$STRC" = "$2" ] && grep -qiE -- "$3" <<<"$STOUT"; then ok "$1"; else bad "$1" "want rc=$2 /$3/, got rc=$STRC: $STOUT"; fi
  cp "$W/a4.green" "$(receipt_of "$A4")"
}
rm -f "$(receipt_of "$A4")";                                                        expect_status "A4. missing receipt -> NOT GREEN (no receipt)" 1 'no receipt'
jq '.exit_code = 1' "$W/a4.green" > "$(receipt_of "$A4")";                          expect_status "A4. exit_code 1 -> NOT GREEN" 1 'NOT GREEN'
jq '.checks[1].exit_code = 1' "$W/a4.green" > "$(receipt_of "$A4")";                expect_status "A4. top-level 0 but one check red -> NOT GREEN, names it" 1 'where'
jq '.dirty = true' "$W/a4.green" > "$(receipt_of "$A4")";                           expect_status "A4. dirty:true -> NOT GREEN" 1 'uncommitted'
jq 'del(.dirty)' "$W/a4.green" > "$(receipt_of "$A4")";                             expect_status "A4. no dirty field (cannot prove a clean tree) -> NOT GREEN" 1 'uncommitted|dirty'
jq '.schema = 2' "$W/a4.green" > "$(receipt_of "$A4")";                             expect_status "A4. unknown schema -> NOT GREEN" 1 'schema'
jq '.exit_code = "0"' "$W/a4.green" > "$(receipt_of "$A4")";                        expect_status "A4. exit_code that is not the number 0 -> NOT GREEN" 1 'NOT GREEN'
jq '.head_sha = "0000000000000000000000000000000000000000"' "$W/a4.green" > "$(receipt_of "$A4")"; expect_status "A4. receipt for another commit -> NOT GREEN (stale)" 1 'stale'
printf '{not json' > "$(receipt_of "$A4")";                                         expect_status "A4. invalid JSON -> NOT GREEN" 1 'not valid|NOT GREEN'
jq '.checks = []' "$W/a4.green" > "$(receipt_of "$A4")";                            expect_status "A4. a green receipt with no checks recorded -> NOT GREEN" 1 'declared|NOT GREEN'
# the binding: a receipt names the commit, its tree and the declaration, and the gate recomputes all three
jq 'del(.tree_sha)' "$W/a4.green" > "$(receipt_of "$A4")";                          expect_status "A4. no tree_sha -> NOT GREEN" 1 'tree'
jq '.tree_sha = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"' "$W/a4.green" > "$(receipt_of "$A4")"; expect_status "A4. tree_sha of another tree -> NOT GREEN" 1 'tree'
jq 'del(.decl_sha256)' "$W/a4.green" > "$(receipt_of "$A4")";                       expect_status "A4. no decl_sha256 -> NOT GREEN" 1 'declaration'
jq --arg z "$ZERO64" '.decl_sha256 = $z' "$W/a4.green" > "$(receipt_of "$A4")";     expect_status "A4. decl_sha256 of another declaration -> NOT GREEN" 1 'declaration'
jq '.checks = [.checks[0]]' "$W/a4.green" > "$(receipt_of "$A4")";                  expect_status "A4. right hashes but fewer checks recorded than declared -> NOT GREEN" 1 'other checks|declared'
jq '.checks[1].cmd = "true"' "$W/a4.green" > "$(receipt_of "$A4")";                 expect_status "A4. right hashes but a recorded command that is not the declared one -> NOT GREEN" 1 'other checks|declared'
# a receipt written by hand: the right commit, clean, exit 0, the declared checks -- and none of the bindings it cannot know
HEAD_A4="$(git -C "$A4" rev-parse HEAD)"; TREE_A4="$(git -C "$A4" rev-parse 'HEAD^{tree}')"
jq -n --arg h "$HEAD_A4" --slurpfile g "$W/a4.green" '{schema:1, head_sha:$h, dirty:false, exit_code:0, finished_at:"2026-10-13T00:00:00Z", checks:$g[0].checks}' > "$(receipt_of "$A4")"
expect_status "A4. FORGED: hand-written exit_code 0 for the current commit, declared checks, no tree_sha/decl_sha256 -> NOT GREEN" 1 'tree'
jq -n --arg h "$HEAD_A4" --arg t "$TREE_A4" --arg z "$ZERO64" --slurpfile g "$W/a4.green" '{schema:1, head_sha:$h, tree_sha:$t, dirty:false, exit_code:0, decl_sha256:$z, finished_at:"2026-10-13T00:00:00Z", checks:$g[0].checks}' > "$(receipt_of "$A4")"
expect_status "A4. FORGED: right commit and tree, a declaration hash guessed wrong -> NOT GREEN" 1 'declaration'
# the verdict is the COMMIT's: an uncommitted edit of the declaration on disk changes nothing about what a push carries
jq . "$W/a4.decl" > "$A4/.heimdall/repo-checks.json"
status_of "$A4"; [ "$STRC" = 0 ] && ok "A4. an uncommitted edit (reformatting) of the declaration on disk does not change the verdict: the commit is what is pushed" || bad "A4. uncommitted declaration edit changed the verdict" "$STOUT"
printf '%s\n' "$(decl_json z 'true')" > "$A4/.heimdall/repo-checks.json"
status_of "$A4"; [ "$STRC" = 0 ] && ok "A4. ...also an uncommitted edit that names other checks" || bad "A4. uncommitted edit of the check list changed the verdict" "$STOUT"
cp "$W/a4.decl" "$A4/.heimdall/repo-checks.json"
# a commit after the run stales it
printf 'v2\n' > "$A4/file.txt"; commit_all "$A4" "after the run"
status_of "$A4"; { [ "$STRC" = 1 ] && grep -qi 'stale' <<<"$STOUT"; } && ok "A4. a commit after the run -> STALE" || bad "A4. commit after run not stale" "rc=$STRC $STOUT"
run_checks "$A4"; status_of "$A4"; [ "$STRC" = 0 ] && ok "A4. re-run at the new HEAD -> GREEN again" || bad "A4. re-run did not turn green" "$STOUT"
# the declaration AS COMMITTED, byte for byte: the same checks reformatted and committed, the receipt re-pointed at the new commit and tree
A4B="$(mk_checks a4b "$GREEN_DECL")"; run_checks "$A4B"; cp "$(receipt_of "$A4B")" "$W/a4b.green"
jq . "$A4B/.heimdall/repo-checks.json" > "$W/a4b.decl" && cp "$W/a4b.decl" "$A4B/.heimdall/repo-checks.json"; commit_all "$A4B" "reformat the declaration"
jq --arg h "$(git -C "$A4B" rev-parse HEAD)" --arg t "$(git -C "$A4B" rev-parse 'HEAD^{tree}')" '.head_sha = $h | .tree_sha = $t' "$W/a4b.green" > "$(receipt_of "$A4B")"
status_of "$A4B"; { [ "$STRC" = 1 ] && grep -qi 'declaration changed' <<<"$STOUT"; } && ok "A4. the same checks, reformatted and COMMITTED -> NOT GREEN (the receipt is bound to the committed declaration's bytes)" || bad "A4. reformatted committed declaration accepted" "rc=$STRC $STOUT"
A4C="$(mk_checks a4c "$GREEN_DECL")"; run_checks "$A4C"; cp "$(receipt_of "$A4C")" "$W/a4c.green"
printf '%s\n' "$(decl_json only 'true')" > "$A4C/.heimdall/repo-checks.json"; commit_all "$A4C" "other checks"
jq --arg h "$(git -C "$A4C" rev-parse HEAD)" --arg t "$(git -C "$A4C" rev-parse 'HEAD^{tree}')" '.head_sha = $h | .tree_sha = $t' "$W/a4c.green" > "$(receipt_of "$A4C")"
status_of "$A4C"; { [ "$STRC" = 1 ] && grep -qi 'declaration' <<<"$STOUT"; } && ok "A4. a receipt for the old checks, re-pointed at a commit that declares other ones -> NOT GREEN" || bad "A4. old receipt accepted for new checks" "rc=$STRC $STOUT"

# A5. refusals and usage
NODECL="$(new_repo nodecl)"
for sub in run status; do
  bash "$RC_BIN" "$sub" --repo "$NODECL" >"$W/o" 2>&1; rc=$?
  { [ "$rc" = 2 ] && grep -q 'repo-checks.json' "$W/o"; } && ok "A5. $sub: no .heimdall/repo-checks.json -> exit 2 (refuses), names the file" || bad "A5. $sub without a declaration" "rc=$rc $(cat "$W/o")"
done
mkdir -p "$W/notrepo"
bash "$RC_BIN" status --repo "$W/notrepo" >"$W/o" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "A5. a directory that is not a git repository -> exit 2" || bad "A5. non-repo" "rc=$rc $(cat "$W/o")"
N5=0
for bad_decl in '{"schema":1,"checks":[]}' '{"schema":2,"checks":[{"name":"x","cmd":"true"}]}' '{"schema":1,"checks":[{"name":"x"}]}' \
                '{"schema":1,"checks":[{"name":"x","cmd":"true"},{"name":"x","cmd":"false"}]}' 'not json'; do
  N5=$((N5 + 1))
  BD="$(mk_checks "baddecl$N5" "$bad_decl")"
  bash "$RC_BIN" run --repo "$BD" >"$W/o" 2>&1; rc=$?
  [ "$rc" = 2 ] && [ ! -e "$(receipt_of "$BD")" ] && ok "A5. invalid declaration $bad_decl -> exit 2, nothing run, no receipt" || bad "A5. invalid declaration $bad_decl" "rc=$rc $(cat "$W/o")"
done
bash "$RC_BIN" >"$W/o" 2>&1; [ "$?" = 2 ] && ok "A5. no subcommand -> exit 2" || bad "A5. no subcommand"
bash "$RC_BIN" frobnicate >"$W/o" 2>&1; [ "$?" = 2 ] && ok "A5. unknown subcommand -> exit 2" || bad "A5. unknown subcommand"
bash "$RC_BIN" run --repo >"$W/o" 2>&1; [ "$?" = 2 ] && ok "A5. --repo without a value -> exit 2" || bad "A5. --repo without a value"
bash "$RC_BIN" run --token abc >"$W/o" 2>&1; [ "$?" = 2 ] && ok "A5. an unknown flag is refused: there is no way to pass a token on the command line" || bad "A5. unknown flag accepted"
bash "$RC_BIN" --help >"$W/o" 2>&1; { [ "$?" = 0 ] && grep -q 'repo-checks.json' "$W/o" && grep -qi 'not a security boundary' "$W/o"; } && ok "A5. --help documents the contract and says plainly the receipt is not a security boundary, exit 0" || bad "A5. --help"

# A6. the runner never records or prints the environment
A6="$(mk_checks a6 "$GREEN_DECL")"
HMD_TEST_TOKEN='tok-9f3a1c-do-not-leak' GH_TOKEN='ghp_do_not_leak_0123456789' ORDER="$W/order.log" bash "$RC_BIN" run --repo "$A6" >"$W/rc.out" 2>"$W/rc.err"
if ! grep -rqE 'do-not-leak|do_not_leak' "$W/rc.out" "$W/rc.err" "$(receipt_of "$A6")"; then ok "A6. no token from the environment reaches the receipt, stdout or stderr"; else bad "A6. a token leaked into the runner's output"; fi

# A7. ONE definition of the receipt (bin/lib/hmd_repo_receipt.py): a receipt `run` writes passes the gate, and every field of it
# mutated on its own -- deleted, retyped, given a wrong value, malformed -- fails the gate. The field list is read FROM the definition,
# so a field added there without a mutation below fails this test instead of slipping through unchecked.
A7="$(mk_checks a7 "$GREEN_DECL")"; run_checks "$A7"; R7="$(receipt_of "$A7")"; cp "$R7" "$W/a7.green"
status_of "$A7"; [ "$STRC" = 0 ] && ok "A7. a receipt written by run passes the gate" || bad "A7. run's own receipt does not pass the gate" "rc=$STRC $STOUT"
DEF="$(python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import hmd_repo_receipt as m; print(" ".join(m.FIELD_NAMES)); print(" ".join(m.CHECK_FIELD_NAMES))' "$REPO/bin/lib")"
DEF_TOP="$(sed -n 1p <<<"$DEF")"; DEF_CHK="$(sed -n 2p <<<"$DEF")"
sorted_words() { tr ' ' '\n' | sort | tr '\n' ' '; }
[ "$(printf '%s' "$DEF_TOP" | sorted_words)" = "$(jq -r 'keys | join(" ")' "$W/a7.green" | sorted_words)" ] \
  && ok "A7. the top-level fields run wrote ARE the fields the definition names ($DEF_TOP)" || bad "A7. run's fields differ from the definition" "definition: $DEF_TOP | receipt: $(jq -r 'keys | join(" ")' "$W/a7.green")"
[ "$(printf '%s' "$DEF_CHK" | sorted_words)" = "$(jq -r '.checks[0] | keys | join(" ")' "$W/a7.green" | sorted_words)" ] \
  && ok "A7. ...and each recorded check has exactly the definition's fields ($DEF_CHK)" || bad "A7. a recorded check's fields differ from the definition" "definition: $DEF_CHK | receipt: $(jq -r '.checks[0] | keys | join(" ")' "$W/a7.green")"
refused_after() {  # refused_after <label> <jq filter over the green receipt>
  jq "$2" "$W/a7.green" > "$R7" 2>/dev/null; status_of "$A7"
  if [ "$STRC" = 1 ] && grep -q 'NOT GREEN' <<<"$STOUT"; then ok "A7. $1 -> refused"; else bad "A7. $1 was NOT refused" "rc=$STRC $STOUT"; fi
  cp "$W/a7.green" "$R7"
}
H1="$(printf '1%.0s' $(seq 1 40))"
for f in $DEF_TOP; do
  refused_after "$f deleted" "del(.$f)"
  refused_after "$f retyped (an object where a scalar or list belongs)" ".$f = {\"x\": 1}"
  case "$f" in
    schema)      refused_after "schema = 2" '.schema = 2' ;;
    head_sha)    refused_after "head_sha of another commit (well formed)" ".head_sha = \"$H1\""
                 refused_after "head_sha upper-cased (format)" '.head_sha |= ascii_upcase'
                 refused_after "head_sha abbreviated to 12 digits (format)" '.head_sha |= .[0:12]'
                 refused_after "head_sha one digit too long (format)" '.head_sha |= . + "0"' ;;
    tree_sha)    refused_after "tree_sha of another tree (well formed)" ".tree_sha = \"$H1\""
                 refused_after "tree_sha upper-cased (format)" '.tree_sha |= ascii_upcase'
                 refused_after "tree_sha abbreviated to 12 digits (format)" '.tree_sha |= .[0:12]' ;;
    decl_sha256) refused_after "decl_sha256 of another declaration (well formed)" ".decl_sha256 = \"$ZERO64\""
                 refused_after "decl_sha256 one digit short (format)" '.decl_sha256 |= .[0:63]'
                 refused_after "decl_sha256 upper-cased (format)" '.decl_sha256 |= ascii_upcase' ;;
    dirty)       refused_after "dirty = true" '.dirty = true'
                 refused_after "dirty as the string \"false\" (type)" '.dirty = "false"' ;;
    exit_code)   refused_after "exit_code = 1" '.exit_code = 1'
                 refused_after "exit_code as the string \"0\" (type)" '.exit_code = "0"'
                 refused_after "exit_code as the boolean false (type)" '.exit_code = false' ;;
    finished_at) refused_after "finished_at not a timestamp (format)" '.finished_at = "yesterday"'
                 refused_after "finished_at without the Z (format)" '.finished_at |= rtrimstr("Z")' ;;
    checks)      refused_after "checks emptied" '.checks = []'
                 refused_after "checks as a string (type)" '.checks = "none"' ;;
    *)           bad "A7. the definition has a field ($f) this test has no value mutation for: add one" ;;
  esac
done
for f in $DEF_CHK; do
  refused_after "checks[0].$f deleted" "del(.checks[0].$f)"
  refused_after "checks[0].$f retyped" ".checks[0].$f = {\"x\": 1}"
  case "$f" in
    name)      refused_after "checks[0].name another check's name" '.checks[0].name = "other"' ;;
    cmd)       refused_after "checks[0].cmd another command" '.checks[0].cmd = "true"' ;;
    exit_code) refused_after "checks[0].exit_code = 1" '.checks[0].exit_code = 1'
               refused_after "checks[0].exit_code as a string (type)" '.checks[0].exit_code = "0"' ;;
    secs)      refused_after "checks[0].secs negative" '.checks[0].secs = -1'
               refused_after "checks[0].secs as a string (type)" '.checks[0].secs = "3"' ;;
    *)         bad "A7. the definition has a check field ($f) this test has no value mutation for: add one" ;;
  esac
done
refused_after "an unknown top-level field added" '.extra = 1'
refused_after "an unknown field added to a recorded check" '.checks[0].extra = 1'
status_of "$A7"; [ "$STRC" = 0 ] && ok "A7. ...and after all of them the untouched receipt still passes" || bad "A7. the untouched receipt no longer passes" "$STOUT"
# the writer and the checker import the same definition; the resolver reads the declaration's path from it too
grep -q 'rr.build_receipt' "$RC_PY" && grep -q 'rr.verify_receipt' "$RC_PY" && ! grep -q 'jq' "$RC_BIN" \
  && ok "A7. run builds with build_receipt and status verifies with verify_receipt, both from hmd_repo_receipt (no second schema in the launcher)" || bad "A7. the writer or the checker is not on the shared definition"
if python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import hmd_repo_receipt as r, hmd_push_target as t; sys.exit(0 if t.DECLARATION == r.DECLARATION else 1)' "$REPO/bin/lib" 2>/dev/null; then
  ok "A7. the resolver classifies by the very declaration path the runner reads"
else
  bad "A7. the resolver's declaration path is not the shared one"
fi

# A8. a receipt attests ONE commit: every commit a push names as a source must be it. `status --pushes <ids>` is what the hook asks; the resolver
# computes the ids (a refspec's source resolved by git, HEAD for a bare push, - when no commit travels, ? when the commits cannot be listed)
A8="$(mk_checks a8 "$GREEN_DECL")"; printf 'v2\n' > "$A8/file.txt"; commit_all "$A8" second; run_checks "$A8"
HEAD_A8="$(git -C "$A8" rev-parse HEAD)"; PREV_A8="$(git -C "$A8" rev-parse 'HEAD~1')"
expect_pushes() {  # expect_pushes <label> <--pushes value> <want rc> <pattern>
  bash "$RC_BIN" status --repo "$A8" --pushes "$2" >"$W/st.out" 2>&1; local rc=$?
  if [ "$rc" = "$3" ] && grep -qiE -- "$4" "$W/st.out"; then ok "A8. $1"; else bad "A8. $1" "want rc=$3 /$4/, got rc=$rc: $(head -c 300 "$W/st.out")"; fi
}
expect_pushes "--pushes the receipt's own commit -> GREEN"                          "$HEAD_A8"                 0 'GREEN'
expect_pushes "--pushes the same commit twice -> GREEN"                             "$HEAD_A8,$HEAD_A8"        0 'GREEN'
expect_pushes "--pushes - (a push that carries no commit) -> GREEN"                 "-"                        0 'GREEN'
expect_pushes "--pushes another commit -> NOT GREEN, says what the push carries"    "$PREV_A8"                 1 'NOT GREEN.*the push carries'
expect_pushes "--pushes the receipt's commit and another -> NOT GREEN"              "$HEAD_A8,$PREV_A8"        1 'the push carries'
expect_pushes "--pushes ? (not modelled) -> NOT GREEN"                              '?'                        1 'cannot be tied'
expect_pushes "--pushes with an empty value -> NOT GREEN"                           ''                         1 'cannot be tied'
expect_pushes "--pushes with a malformed id -> NOT GREEN"                           'not-an-id'                1 'cannot be tied'
expect_pushes "--pushes with an abbreviated id -> NOT GREEN"                        "${HEAD_A8:0:12}"          1 'cannot be tied'
expect_pushes "--pushes with an id and an empty element -> NOT GREEN"               "$HEAD_A8,"                1 'cannot be tied'
bash "$RC_BIN" status --repo "$A8" >"$W/st.out" 2>&1; [ "$?" = 0 ] && ok "A8. status without --pushes is the plain question: is the receipt green and current" || bad "A8. status without --pushes" "$(cat "$W/st.out")"
bash "$RC_BIN" run --repo "$A8" --pushes "$HEAD_A8" >"$W/st.out" 2>&1; [ "$?" = 2 ] && ok "A8. run takes no --pushes (exit 2)" || bad "A8. run accepted --pushes"
bash "$RC_BIN" status --repo "$A8" --pushes >"$W/st.out" 2>&1; [ "$?" = 2 ] && ok "A8. --pushes without a value -> exit 2" || bad "A8. --pushes without a value"

# A9. every record that cannot be read is NOT GREEN: a corrupt receipt, or one that makes the reader fail, never reads as green
A9="$(mk_checks a9 "$GREEN_DECL")"; run_checks "$A9"; R9="$(receipt_of "$A9")"; cp "$R9" "$W/a9.green"
corrupt_receipt() {  # corrupt_receipt <what it is> <command that prints the bad receipt>...
  local label="$1"; shift
  "$@" > "$R9" 2>/dev/null
  status_of "$A9"
  if [ "$STRC" != 0 ] && ! grep -q '^repo-checks: GREEN' <<<"$STOUT"; then ok "A9. a receipt that is $label -> not green  [rc=$STRC]"; else bad "A9. a receipt that is $label was accepted" "rc=$STRC $STOUT"; fi
  cp "$W/a9.green" "$R9"
}
corrupt_receipt "empty" printf ''
corrupt_receipt "a lone brace" printf '{'
corrupt_receipt "an empty array" printf '[]'
corrupt_receipt "null" printf 'null'
corrupt_receipt "a string" printf '"x"'
corrupt_receipt "a number" printf '0'
corrupt_receipt "binary bytes" printf '\377\376\000\001'
corrupt_receipt "100000 brackets deep (past the parser's recursion limit)" python3 -c 'print("[" * 100000)'
corrupt_receipt "an object with a non-finite number" printf '{"schema":1,"checks":[{"secs":1e999}]}'
rm -f "$R9"; mkdir "$R9"; status_of "$A9"
{ [ "$STRC" != 0 ] && ! grep -q '^repo-checks: GREEN' <<<"$STOUT"; } && ok "A9. a receipt path that is a directory -> not green  [rc=$STRC]" || bad "A9. a receipt path that is a directory" "rc=$STRC $STOUT"
rmdir "$R9"; cp "$W/a9.green" "$R9"
N9=0
for bad_decl in 'not json' '[]' 'null' '{"schema":1,"checks":"x"}' '{"schema":1,"checks":[1]}' '{"schema":"1","checks":[{"name":"a","cmd":"true"}]}' $'\xff\xfe' ''; do
  N9=$((N9 + 1)); BD9="$(mk_checks "a9decl$N9" "$bad_decl")"
  bash "$RC_BIN" status --repo "$BD9" >"$W/o" 2>&1; rc=$?
  { [ "$rc" = 2 ] && ! grep -q '^repo-checks: GREEN' "$W/o"; } && ok "A9. a committed declaration that is [$(printf '%s' "$bad_decl" | head -c 24 | tr -c '[:print:]' '?')] -> status refuses  [rc=2]" || bad "A9. a committed declaration that is [$bad_decl]" "rc=$rc $(head -c 200 "$W/o")"
done

# ════════════════════════════════════════════════════════════════════════════
# ── A10. the receipt is read as ONE regular file inside the repository (review round 2026-10-14): a link is never followed, and nothing is
#    trusted that is too big, too deep or not a file ──
A10="$(mk_checks a10 "$GREEN_DECL")"; run_checks "$A10"
cp "$(receipt_of "$A10")" "$W/a10.green"
status_of "$A10"; [ "$STRC" = 0 ] && ok "A10. fixture sanity: the genuine green receipt passes" || bad "A10. fixture sanity" "rc=$STRC $STOUT"
mv "$A10/.heimdall/receipts" "$W/a10.elsewhere"; ln -s "$W/a10.elsewhere" "$A10/.heimdall/receipts"
status_of "$A10"; { [ "$STRC" = 1 ] && grep -qi 'link' <<<"$STOUT"; } && ok "A10a. .heimdall/receipts is a symlink to a genuine receipt elsewhere -> NOT GREEN, says it is a link" || bad "A10a. a symlinked receipts directory was followed" "rc=$STRC $STOUT"
rm "$A10/.heimdall/receipts"; mv "$W/a10.elsewhere" "$A10/.heimdall/receipts"
mv "$A10/.heimdall" "$W/a10.heimdall"; ln -s "$W/a10.heimdall" "$A10/.heimdall"
status_of "$A10"; { [ "$STRC" = 1 ] && grep -qi 'link' <<<"$STOUT"; } && ok "A10b. .heimdall itself is a symlink -> NOT GREEN, says it is a link" || bad "A10b. a symlinked .heimdall was followed" "rc=$STRC $STOUT"
rm "$A10/.heimdall"; mv "$W/a10.heimdall" "$A10/.heimdall"
mv "$(receipt_of "$A10")" "$W/a10.file"; ln -s "$W/a10.file" "$(receipt_of "$A10")"
status_of "$A10"; { [ "$STRC" = 1 ] && grep -qi 'link' <<<"$STOUT"; } && ok "A10c. the receipt file itself is a symlink -> NOT GREEN" || bad "A10c. a symlinked receipt file was followed" "rc=$STRC $STOUT"
rm "$(receipt_of "$A10")"; cp "$W/a10.green" "$(receipt_of "$A10")"
status_of "$A10"; [ "$STRC" = 0 ] && ok "A10c. ...and with the links gone the same receipt passes again (the refusals above were about the links)" || bad "A10c. restored receipt" "rc=$STRC $STOUT"
A10D="$(mk_checks a10d "$GREEN_DECL")"; mkdir -p "$W/a10d.out" "$A10D/.heimdall"; ln -s "$W/a10d.out" "$A10D/.heimdall/receipts"
run_checks "$A10D"
{ [ "$RCRC" = 2 ] && [ -z "$(ls -A "$W/a10d.out")" ] && grep -qi 'link' "$W/rc.err"; } && ok "A10d. run refuses to write the receipt through a symlinked receipts directory: exit 2, nothing lands outside the repository" || bad "A10d. run wrote through a link" "rc=$RCRC out=$(ls -A "$W/a10d.out") $(head -c 300 "$W/rc.err")"
{ cat "$W/a10.green"; head -c 2000000 /dev/zero | tr '\0' ' '; } > "$(receipt_of "$A10")"
status_of "$A10"; { [ "$STRC" = 1 ] && grep -qi 'larger' <<<"$STOUT"; } && ok "A10e. a receipt of 2 MB (valid JSON plus padding) is not read -> NOT GREEN, says it is too large" || bad "A10e. an oversized receipt was read" "rc=$STRC $(printf '%s' "$STOUT" | head -c 300)"
python3 -c 'import sys; sys.stdout.write("[" * 300000 + "]" * 300000)' > "$(receipt_of "$A10")"
status_of "$A10"; { [ "$STRC" = 1 ] && ! grep -q 'Traceback\|RecursionError' <<<"$STOUT"; } && ok "A10g. a receipt nested 300000 deep is NOT GREEN as invalid JSON, not a crash" || bad "A10g. a deeply nested receipt" "rc=$STRC $(printf '%s' "$STOUT" | head -c 300)"
rm -f "$(receipt_of "$A10")"; mkfifo "$(receipt_of "$A10")"
perl -e 'alarm 20; exec @ARGV' bash "$RC_BIN" status --repo "$A10" >"$W/o" 2>&1; rcx=$?
{ [ "$rcx" = 1 ] && grep -q 'NOT GREEN' "$W/o"; } && ok "A10f. a FIFO where the receipt should be: refused at once, never opened (no hang)" || bad "A10f. a FIFO receipt" "rc=$rcx $(head -c 300 "$W/o")"
rm -f "$(receipt_of "$A10")"; cp "$W/a10.green" "$(receipt_of "$A10")"
A10H="$(new_repo a10h)"; mkdir -p "$A10H/.heimdall"
python3 -c 'import json, sys; sys.stdout.write(json.dumps({"schema": 1, "checks": [{"name": "x", "cmd": "true"}], "pad": "a" * 2000000}))' > "$A10H/.heimdall/repo-checks.json"; commit_all "$A10H" "a 2 MB declaration"
bash "$RC_BIN" status --repo "$A10H" >"$W/o" 2>&1; rcx=$?
{ [ "$rcx" = 2 ] && grep -qi 'larger' "$W/o"; } && ok "A10h. a committed declaration of 2 MB is refused, not parsed (exit 2)" || bad "A10h. an oversized declaration" "rc=$rcx $(head -c 300 "$W/o")"

# ════════════════════════════════════════════════════════════════════════════
section "B. bin/lib/hmd_push_target.py -- which repo, which class"
SWEEP="$(mk_sweep sweep)"
CHK="$(mk_checks chk "$GREEN_DECL")"
PLAIN="$(new_repo plain)"; mkdir -p "$PLAIN/sub"
SPACED="$(mk_checks 'with space' "$GREEN_DECL")"
OTHER_RUNNER="$(new_repo other-runner)"; mkdir -p "$OTHER_RUNNER/test"
printf '#!/usr/bin/env bash\necho somebody else runs their suite here\n' > "$OTHER_RUNNER/test/run-all.sh"; commit_all "$OTHER_RUNNER" runner
BOTH="$(mk_sweep both)"; mkdir -p "$BOTH/.heimdall"; printf '%s\n' "$GREEN_DECL" > "$BOTH/.heimdall/repo-checks.json"; commit_all "$BOTH" declare
NOGIT="$W/nogit"; mkdir -p "$NOGIT"
HOMEDIR="$W/home"; mkdir -p "$HOMEDIR"
HOMECHK="$(mk_checks homechk "$GREEN_DECL")"; ln -s "$HOMECHK" "$HOMEDIR/chkhome"
# fixtures for the fail-closed cases: a marker that is a dangling link, a declaration that is a directory, a bare repo,
# linked worktrees (checked out, and with nothing on disk), a link to a sweep repo
DANGLE="$(new_repo dangle)"; mkdir -p "$DANGLE/test"; ln -s /no/such/target/anywhere "$DANGLE/test/run-all.sh"; commit_all "$DANGLE" dangling-marker
DECLDIR="$(new_repo decldir)"; mkdir -p "$DECLDIR/.heimdall/repo-checks.json"; printf 'x\n' > "$DECLDIR/.heimdall/repo-checks.json/keep"; commit_all "$DECLDIR" decl-is-a-directory
BARE="$W/bare.git"
[ -n "$BARE" ] || { echo "FATAL: BARE path empty" >&2; exit 1; }
git init -q --bare "$BARE"
git -C "$SWEEP" worktree add -q "$W/wt/sweep-full" -b wt-sweep-full >/dev/null 2>&1
git -C "$SWEEP" worktree add -q --no-checkout "$W/wt/sweep-bare" -b wt-sweep-bare >/dev/null 2>&1
git -C "$PLAIN" worktree add -q "$W/wt/plain-full" -b wt-plain-full >/dev/null 2>&1
WT_SWEEP="$(cd "$W/wt/sweep-full" && pwd -P)"; WT_BARE="$(cd "$W/wt/sweep-bare" && pwd -P)"; WT_PLAIN="$(cd "$W/wt/plain-full" && pwd -P)"
ln -s "$SWEEP" "$W/link-sweep"
SWEEP_NOCHECKOUT_OK=0; [ ! -e "$WT_BARE/test/run-all.sh" ] && [ -d "$SWEEP/.git/worktrees" ] && SWEEP_NOCHECKOUT_OK=1
[ "$SWEEP_NOCHECKOUT_OK" = 1 ] && ok "B0. fixture sanity: the no-checkout worktree of a sweep repo really has no test/run-all.sh on disk" || bad "B0. no-checkout worktree fixture" "$(ls -A "$WT_BARE")"

PLAN_ENV=""
check_plan() {  # check_plan <label> <base> <command> <class:dir>...   (exact lines, in order)
  local label="$1" base="$2" cmd="$3" want="" got e; shift 3
  for e in "$@"; do want="${want}${e%%:*}${TAB}${e#*:}"$'\n'; done
  # shellcheck disable=SC2086  # PLAN_ENV is a list of VAR=value words on purpose
  # the third column (the commits a repo-checks push names, see check_sources) is not part of the class/directory comparison
  got="$(printf '%s' "$cmd" | env HOME="$HOMEDIR" PATH="${PLAN_PATH:-$PATH}" $PLAN_ENV python3 -I -S "$HELPER" "$base" 2>"$W/plan.err" | awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $2 }'; printf x)"; got="${got%x}"
  if [ "$got" = "$want" ]; then ok "B. $label"; else bad "B. $label" "command: $cmd | want: $(printf '%s' "$want" | tr '\n\t' '|~') | got: $(printf '%s' "$got" | tr '\n\t' '|~') $(head -c 200 "$W/plan.err")"; fi
}
check_strict() {  # check_strict <label> <base> <command> [silent]: at least one row and EVERY row strict: sweep, or a repo-checks row for commits nobody can
                  # list (`?`, which always blocks: a repo that declares checks keeps owing the receipt under uncertainty). `silent` also accepts no answer
  local label="$1" base="$2" cmd="$3" mode="${4:-}" got            # at all: the hook then runs the strict gate on the cwd itself
  got="$(printf '%s' "$cmd" | env HOME="$HOMEDIR" PATH="${PLAN_PATH:-$PATH}" $PLAN_ENV python3 -I -S "$HELPER" "$base" 2>"$W/plan.err")"
  if [ -z "$got" ] && [ "$mode" = silent ]; then ok "B. strict: $label (no answer: the hook falls back to the strict gate on the cwd)"
  elif [ -n "$got" ] && [ -z "$(printf '%s\n' "$got" | grep -v "^sweep${TAB}" | grep -v "^repo-checks${TAB}.*${TAB}?${TAB}[^${TAB}]*\$")" ]; then ok "B. strict: $label"
  else bad "B. strict: $label" "command: $cmd | got: $(printf '%s' "$got" | tr '\n\t' '|~') $(head -c 200 "$W/plan.err")"; fi
}
check_sources() {  # check_sources <label> <base> <command> <the repo-checks row's third column: full ids comma-separated, - (no commit) or ? (cannot be listed)>
  local label="$1" base="$2" cmd="$3" want="$4" got
  got="$(printf '%s' "$cmd" | env HOME="$HOMEDIR" PATH="${PLAN_PATH:-$PATH}" $PLAN_ENV python3 -I -S "$HELPER" "$base" 2>"$W/plan.err" | awk -F'\t' '$1 == "repo-checks" { print $3; exit }')"
  if [ "$got" = "$want" ]; then ok "B. sources: $label"; else bad "B. sources: $label" "command: $cmd | want '$want' | got '$got' $(head -c 200 "$W/plan.err")"; fi
}
# the three classes
check_plan "a repo with heimdall's sweep writer is class sweep"           "$SWEEP" 'git push'                 "sweep:$SWEEP"
check_plan "a repo declaring checks is class repo-checks"                 "$CHK"   'git push origin main'     "repo-checks:$CHK"
check_plan "any other repo, positively without markers, is unmanaged"     "$PLAIN" 'git push'                 "unmanaged:$PLAIN"
check_plan "a test/run-all.sh that is not heimdall's sweep is unmanaged"  "$OTHER_RUNNER" 'git push'          "unmanaged:$OTHER_RUNNER"
check_plan "sweep wins over a declaration (a before b)"                   "$BOTH"  'git push'                 "sweep:$BOTH"
check_plan "a subdirectory resolves to its toplevel"                      "$PLAIN/sub" 'git push'             "unmanaged:$PLAIN"
check_plan "a linked worktree of a non-heimdall repo is unmanaged, not over-blocked" "$WT_PLAIN" 'git push'   "unmanaged:$WT_PLAIN"
# the target is what the command says, not the cwd
check_plan "git -C <abs>"                       "$PLAIN" "git -C $SWEEP push"                      "sweep:$SWEEP"
check_plan "git -C \"<abs>\" (quoted)"          "$PLAIN" "git -C \"$CHK\" push origin HEAD"        "repo-checks:$CHK"
check_plan "git -C '<dir with a space>'"        "$PLAIN" "git -C '$SPACED' push"                   "repo-checks:$SPACED"
check_plan "git -C <relative>"                  "$W/repos" "git -C chk push"                       "repo-checks:$CHK"
check_plan "git -C <a> -C <b> accumulate"       "$W" "git -C repos -C chk push"                    "repo-checks:$CHK"
check_plan "git -C <subdir> -> toplevel"        "$SWEEP" "git -C $PLAIN/sub push"                  "unmanaged:$PLAIN"
check_plan "git -C <link to a sweep repo>"      "$PLAIN" "git -C $W/link-sweep push"               "sweep:$SWEEP"
check_plan "cd <dir> && ..."                    "$SWEEP" "cd $CHK && git push"                     "repo-checks:$CHK"
check_plan "cd <dir>; ..."                      "$SWEEP" "cd $CHK; git push"                       "repo-checks:$CHK"
check_plan "cd <dir> <newline> ..."             "$SWEEP" $'cd '"$CHK"$'\ngit push'                 "repo-checks:$CHK"
check_plan "cd '<quoted>' && ..."               "$SWEEP" "cd '$CHK' && git push"                   "repo-checks:$CHK"
check_plan "cd <rel> then git -C <rel>"         "$W/repos" "cd chk && git -C ../sweep push"        "sweep:$SWEEP"
check_plan "( cd <dir> && ... ) subshell"       "$SWEEP" "(cd $CHK && git push)"                   "repo-checks:$CHK"
check_plan "a subshell's cd does not leak out"  "$SWEEP" "(cd $CHK) && git push"                   "sweep:$SWEEP"
check_plan "a cd in a pipeline does not leak"   "$PLAIN" "cd $SWEEP | cat; git push"               "unmanaged:$PLAIN"
check_plan "pushd <dir> && ..."                 "$SWEEP" "pushd $CHK >/dev/null && git push"       "repo-checks:$CHK"
check_plan "pushd then popd returns"            "$SWEEP" "pushd $CHK >/dev/null; popd >/dev/null; git push" "sweep:$SWEEP"
check_plan "cd ~/<dir>"                         "$SWEEP" 'cd ~/chkhome && git push'                "repo-checks:$HOMECHK"
# wrappers and shells
check_plan "env-assignment prefix"              "$PLAIN" "FOO=1 git -C $SWEEP push"                "sweep:$SWEEP"
check_plan "sudo / command / exec / time / nohup wrappers" "$PLAIN" "sudo git -C $SWEEP push; command git -C $SWEEP push; exec git -C $SWEEP push; time git -C $SWEEP push; nohup git -C $SWEEP push &" "sweep:$SWEEP"
check_plan "env <VAR=x> git ..."                "$PLAIN" "env FOO=1 git -C $SWEEP push"            "sweep:$SWEEP"
check_plan "/usr/bin/git path form"             "$PLAIN" "/usr/bin/git -C $SWEEP push"             "sweep:$SWEEP"
check_plan "bash -c \"cd <dir> && git push\""   "$SWEEP" "bash -c \"cd $CHK && git push\""          "repo-checks:$CHK"
check_plan "sh -c 'git -C <dir> push'"          "$PLAIN" "sh -c 'git -C $SWEEP push'"              "sweep:$SWEEP"
check_plan "eval \"git -C <dir> push\""         "$PLAIN" "eval \"git -C $SWEEP push\""             "sweep:$SWEEP"
check_plan "if/then"                            "$PLAIN" "if true; then git -C $SWEEP push; fi"    "sweep:$SWEEP"
check_plan "-c <k=v> options before the subcommand" "$PLAIN" "git -c user.name=x -c core.pager=cat -C $SWEEP push" "sweep:$SWEEP"
# several pushes: every target is gated, once each, in order
check_plan "two pushes, two repos"              "$PLAIN" "git -C $SWEEP push && git -C $CHK push"  "sweep:$SWEEP" "repo-checks:$CHK"
check_plan "the same repo twice is one target"  "$PLAIN" "git -C $CHK push; cd $CHK && git push"   "repo-checks:$CHK"
check_plan "a push here and a push there"       "$PLAIN" "(cd $CHK && git push); git push"         "repo-checks:$CHK" "unmanaged:$PLAIN"

# ── the repository is what GIT says it is: decoys and the -C / --git-dir / GIT_DIR differential ──
check_plan "--git-dir=<dir>/.git"               "$PLAIN" "git --git-dir=$CHK/.git push"            "repo-checks:$CHK"
check_plan "--git-dir <dir>/.git --work-tree <same>" "$PLAIN" "git --git-dir $CHK/.git --work-tree $CHK push" "repo-checks:$CHK"
check_plan "GIT_DIR=<dir>/.git prefix"          "$PLAIN" "GIT_DIR=$CHK/.git git push"              "repo-checks:$CHK"
check_plan "DECOY: --work-tree=<plain repo> cannot point a push of the sweep repo at it" "$PLAIN" "git --git-dir=$SWEEP/.git --work-tree=$PLAIN push" "sweep:$SWEEP"
check_plan "DECOY: GIT_WORK_TREE=<plain repo> likewise" "$PLAIN" "GIT_DIR=$SWEEP/.git GIT_WORK_TREE=$PLAIN git push" "sweep:$SWEEP"
check_plan "DECOY: --work-tree alone does not change which repository is pushed" "$SWEEP" "git --work-tree=$CHK push" "sweep:$SWEEP"
check_plan "DECOY: -C <plain> --git-dir=<sweep>/.git: the git dir wins" "$PLAIN" "git -C $PLAIN --git-dir=$SWEEP/.git push" "sweep:$SWEEP"
check_plan "DECOY: -c core.worktree=<plain> cannot hide a sweep repo" "$PLAIN" "git -c core.worktree=$PLAIN -C $SWEEP push" "sweep:$SWEEP"
check_plan "DECOY: --work-tree=<a subdirectory of the sweep repo> -- the repo is still the sweep repo" "$PLAIN" "git --git-dir=$SWEEP/.git --work-tree=$SWEEP/test push" "sweep:$SWEEP"
check_plan "export GIT_DIR=... && git push"     "$PLAIN" "export GIT_DIR=$SWEEP/.git && git push"  "sweep:$SWEEP"
check_plan "export then unset GIT_DIR"          "$PLAIN" "export GIT_DIR=$SWEEP/.git; unset GIT_DIR; git push" "unmanaged:$PLAIN"
check_plan "a linked worktree of a sweep repo is a sweep repo"            "$WT_SWEEP" 'git push'                       "sweep:$WT_SWEEP"
check_plan "...from a subdirectory of it"                                 "$WT_SWEEP/test" 'git push'                  "sweep:$WT_SWEEP"
check_plan "...and with nothing checked out (git still tracks the marker)" "$WT_BARE" 'git push'                        "sweep:$WT_BARE"
check_plan "git -C <no-checkout worktree of a sweep repo>"                "$PLAIN" "git -C $WT_BARE push"              "sweep:$WT_BARE"
check_plan "a marker that is a dangling link is a sweep repo, not unmanaged"  "$DANGLE" 'git push'                     "sweep:$DANGLE"
check_plan "a declaration that is a directory is a sweep repo, not unmanaged" "$DECLDIR" 'git push'                    "sweep:$DECLDIR"

# git is the judge: for each shape the repository the resolver names is the one git itself reports for the same options and
# environment (`git <options> rev-parse --absolute-git-dir`, run for real in the same directory)
diff_vs_git() {  # reads  cwd|env words|option words  lines
  local dcwd denv dopts want got
  while IFS='|' read -r dcwd denv dopts; do
    [ -n "$dcwd" ] || continue
    [ "$denv" = - ] && denv=""
    [ "$dopts" = - ] && dopts=""
    # shellcheck disable=SC2086  # the option and environment words are meant to split
    want="$(cd "$dcwd" && env $denv git $dopts rev-parse --absolute-git-dir 2>/dev/null)"; want="${want%/.git}"
    # shellcheck disable=SC2086
    got="$(printf '%s' "$denv git $dopts push" | env HOME="$HOMEDIR" python3 -I -S "$HELPER" "$dcwd" 2>/dev/null | awk -F'\t' 'NR == 1 { print $2 }')"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then ok "B. differential vs git: [$denv] git $dopts push from ${dcwd#"$W"/}"; else bad "B. differential vs git: [$denv] git $dopts push from $dcwd" "git says '$want', the resolver says '$got'"; fi
  done
}
diff_vs_git <<EOF
$W|-|-C repos -C chk
$W/repos|-|-C chk -C .
$W/repos/chk|-|-C .. -C sweep
$W/repos/chk|-|-C ../plain/sub
$W|-|-C repos/plain -C sub -C ..
$PLAIN|-|-c user.name=x -c core.pager=cat -C $CHK
$PLAIN|-|--git-dir=$CHK/.git
$PLAIN|-|--git-dir=$CHK/.git --work-tree=$PLAIN
$PLAIN|-|--work-tree=$SWEEP -C $CHK
$PLAIN|-|-C $CHK --git-dir=.git
$PLAIN|GIT_DIR=$CHK/.git|-
$PLAIN|GIT_DIR=$CHK/.git GIT_WORK_TREE=$SWEEP|-
$PLAIN|GIT_DIR=.git|-C $CHK
$SWEEP|-|-C test
$PLAIN|-|-C $W/link-sweep
EOF

# ── fail closed: whatever is uncertain is the strict gate on the repo resolved, else the cwd -- never a warning ──
check_plan "NOT a repository: a cwd that is not inside one cannot be positively resolved" "$NOGIT" 'git push'      "sweep:$NOGIT"
check_plan "a variable target -> strict on the cwd, even an unmanaged one"   "$PLAIN" 'git -C "$DIR" push'          "sweep:$PLAIN"
check_plan "a variable target -> the cwd repo (sweep)"                       "$SWEEP" 'git -C "$DIR" push'           "sweep:$SWEEP"
check_plan "a substitution target"                                           "$PLAIN" 'git -C "$(pwd)/x" push'       "sweep:$PLAIN"
check_plan "cd to a variable"                                                "$PLAIN" 'cd "$X" && git push'          "sweep:$PLAIN"
check_plan "a target that does not exist -> strict on the cwd"               "$PLAIN" 'git -C /no/such/dir/anywhere push' "sweep:$PLAIN"
check_plan "a target that is not a repo -> strict on the cwd"                "$PLAIN" "git -C $NOGIT push"           "sweep:$PLAIN"
check_plan "a bare repository cannot be placed in a work tree -> strict, on the cwd AND on the bare repository itself (the one pushed from)" "$PLAIN" "git -C $BARE push" "sweep:$PLAIN" "sweep:$BARE"
check_plan "text that only mentions a push -> strict on the cwd"             "$PLAIN" 'echo "git push" > /dev/null'  "sweep:$PLAIN"
check_plan "a heredoc body is data, not a command -> nothing found -> strict" "$PLAIN" $'cat <<EOF\ngit -C '"$CHK"$' push\nEOF'  "sweep:$PLAIN"
check_plan "empty command -> strict on the cwd"                              "$PLAIN" ''                             "sweep:$PLAIN"
# an uncertain command gives EVERY repo involved the strict class -- the resolved ones too, whatever their own class says
check_plan "an unreadable rest of the command: the resolved repo and the cwd both strict" "$PLAIN" "git -C $CHK push \"never closed" "sweep:$CHK" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "a resolved target plus an unresolvable one: both strict"         "$PLAIN" "git -C $CHK push && git -C \"\$X\" push" "sweep:$CHK" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "an unknown git subcommand may be an alias of a push"             "$PLAIN" "git -C $CHK push && git -C $CHK pp" "sweep:$CHK" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "an alias alone: no push is seen -> strict"                       "$PLAIN" "git -c alias.pp=push -C $CHK pp" "sweep:$PLAIN"
check_plan "a git option this does not know"                                 "$PLAIN" 'git --frobnicate push'        "sweep:$PLAIN"
check_plan "a command name held in a variable"                               "$PLAIN" '$GIT push'                    "sweep:$PLAIN"
check_plan "...also quoted, with an argument for the push"                   "$PLAIN" "\"\$GIT\" -C $CHK push"       "sweep:$PLAIN"
check_plan "env -C <dir> runs git elsewhere: not followed -> strict"         "$PLAIN" "env -C $CHK git push"         "sweep:$PLAIN"
check_plan "a sourced script may cd or export anything"                      "$PLAIN" 'source ./env.sh && git push'  "sweep:$PLAIN"
check_plan "a bare GIT_DIR= assignment may update an exported variable"      "$PLAIN" "GIT_DIR=$SWEEP/.git; git push" "sweep:$PLAIN"
check_plan "re-exporting GIT_DIR without a value is not modelled"            "$PLAIN" 'export GIT_DIR; git push'     "sweep:$PLAIN"
check_plan "declare/local/readonly of a GIT_* name is not modelled"          "$PLAIN" "declare GIT_DIR=$SWEEP/.git; git push" "sweep:$PLAIN"
PLAN_ENV="CDPATH=$W/repos"
check_plan "a relative cd with CDPATH set may land elsewhere -> strict"      "$PLAIN" 'cd chk && git push'           "sweep:$PLAIN"
check_plan "...but ./<dir> is not searched through CDPATH"                   "$W/repos" 'cd ./chk && git push'       "repo-checks:$CHK"
PLAN_ENV=""

# ── the shell model: each construct below is either followed EXACTLY (and gated by the class of what it really pushes) or flagged
#    (and then every repo involved is strict). Nothing in between: no construct may let a push slip to the warn-only class. ──
read -r NEST_BACKTICKS <<EOF
echo \`echo \\\`git -C $CHK push\\\`\`
EOF
check_plan "\$( ): a push in a substitution is a push, at the directory its command runs in" "$PLAIN" "echo \"\$(cd $CHK && git push)\""   "repo-checks:$CHK"
check_plan "\$( ): the substitution's own cd stays inside it"                  "$PLAIN" "x=\$(cd $CHK && pwd); git push"          "unmanaged:$PLAIN"
check_plan "backticks"                                                         "$PLAIN" "echo \`git -C $CHK push\`"               "repo-checks:$CHK"
check_plan "escaped, nested backticks are not read -> strict"                  "$PLAIN" "$NEST_BACKTICKS"                         "sweep:$PLAIN"
check_plan "eval runs in the CURRENT shell: its cd carries on"                 "$PLAIN" "eval 'cd $CHK'; git push"                "repo-checks:$CHK"
check_plan "eval of a string with a variable in it cannot be read -> strict"   "$PLAIN" 'eval "cd $X"; git push'                  "sweep:$PLAIN"
check_plan "sh -c is a subshell: its cd does not carry out"                    "$PLAIN" "sh -c 'cd $CHK'; git push"               "unmanaged:$PLAIN"
check_plan "sh -c \"\$VAR\" cannot be read: the resolved push and the cwd both strict" "$PLAIN" "sh -c \"\$CMD\"; git -C $CHK push" "sweep:$CHK" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "xargs git -C <dir> push"                                           "$PLAIN" "xargs git -C $CHK push"                  "repo-checks:$CHK"
check_plan "xargs git -C <dir>: the subcommand may arrive on stdin -> strict"  "$PLAIN" "xargs git -C $CHK"                         "sweep:$PLAIN"
check_plan "a here-string fed to a shell is a script"                          "$PLAIN" "bash <<< 'git -C $CHK push'"             "repo-checks:$CHK"
check_plan "a heredoc fed to a shell is a script"                              "$PLAIN" $'bash <<EOF\ngit -C '"$CHK"$' push\nEOF' "repo-checks:$CHK"
check_plan "a script piped into a shell cannot be seen -> strict"              "$PLAIN" "echo 'git -C $CHK push' | sh"            "sweep:$PLAIN"
check_plan "a here-string fed to cat is only data"                             "$PLAIN" "cat <<< 'git push'; git -C $CHK push"    "repo-checks:$CHK"
check_plan "a heredoc body the shell expands runs its substitutions: not read -> strict" "$PLAIN" $'cat <<EOF\n$(git -C '"$CHK"$' push)\nEOF' "sweep:$PLAIN"
check_plan "a QUOTED heredoc is data even with a \$( ) in it"                  "$PLAIN" $'cat <<\'EOF\'\n$(git -C '"$CHK"$' push)\nEOF\ngit -C '"$CHK"$' push' "repo-checks:$CHK"
check_plan "an expansion that hides a substitution (\${x:-\$( )}) is not read -> strict" "$PLAIN" "echo \${X:-\$(git -C $CHK push)}" "sweep:$PLAIN"
check_plan "find -exec ... git push carries a push in its arguments -> strict" "$PLAIN" "find . -exec git -C $CHK push \\;"        "sweep:$PLAIN"
check_plan "perl -e with a git push in it -> strict"                           "$PLAIN" "perl -e 'system(\"git -C $CHK push\")'"  "sweep:$PLAIN"
check_plan "trap with a push in it, and a push to <dir> -> both strict"        "$PLAIN" "trap 'git push' EXIT; git -C $CHK push"  "sweep:$CHK" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "echo and a commit message that mention a push are only text"       "$PLAIN" "echo \"git push\"; git commit -m \"git push\"; git -C $CHK push" "repo-checks:$CHK"
check_plan "pushd with no argument swaps the stack: not modelled -> strict"    "$PLAIN" 'pushd; git push'                         "sweep:$PLAIN"
check_plan "cd A && cd B && git push: the last cd wins"                        "$PLAIN" "cd $CHK && cd $SWEEP && git push"        "sweep:$SWEEP"
check_plan "cd A; cd <relative to A>; git push"                                "$W/repos" "cd chk; cd ../sweep; git push"         "sweep:$SWEEP"
check_plan "cd A || cd B: a cd into a directory that exists cannot fail, B never runs" "$PLAIN" "cd $CHK || cd $SWEEP; git push"   "repo-checks:$CHK"
check_plan "test -d A && cd A; git push: it may or may not move, so BOTH are gated" "$PLAIN" "test -d $CHK && cd $CHK; git push"   "repo-checks:$CHK" "unmanaged:$PLAIN"
check_plan "false || cd A && git push: gated at both"                          "$PLAIN" "false || cd $CHK && git push"            "repo-checks:$CHK" "unmanaged:$PLAIN"
check_plan "a cd into a directory that does not exist leaves the cwd unknown -> strict" "$PLAIN" "cd /no/such/dir; git push"     "sweep:$PLAIN"
check_plan "a cd in a backgrounded list does not carry out"                    "$PLAIN" "cd $CHK & git push"                      "unmanaged:$PLAIN"
check_plan "a cd inside if / while / for / case is not modelled -> strict"     "$PLAIN" "if cd $CHK; then git push; fi"           "sweep:$PLAIN"
check_plan "a cd inside a brace group is not modelled -> strict"               "$PLAIN" "{ cd $CHK; git push; }"                  "sweep:$PLAIN"
check_plan "a function definition is not read -> strict"                       "$PLAIN" "f() { cd $CHK; }; f; git push"           "sweep:$PLAIN"
check_plan "an alias may turn any word into a push -> strict"                  "$PLAIN" "alias git='git -C $CHK'; git push"       "sweep:$PLAIN"
check_plan "cd - : OLDPWD is not known -> strict"                              "$PLAIN" 'cd -; git push'                          "sweep:$PLAIN"
check_plan "cd ~ : the home directory is where the push then runs (here not a repo) -> strict" "$PLAIN" 'cd ~; git push'          "sweep:$PLAIN"
check_plan "cd with no argument goes home, likewise"                           "$PLAIN" 'cd; git push'                            "sweep:$PLAIN"
check_plan "cd to a quoted path with a space"                                  "$PLAIN" "cd '$SPACED' && git push"                "repo-checks:$SPACED"
check_plan "cd to a quoted path with a space that does not exist -> strict"    "$PLAIN" "cd '$W/no such dir'; git push"           "sweep:$PLAIN"
check_plan "sudo -D <dir> runs git elsewhere -> strict"                        "$PLAIN" "sudo -D $CHK git push"                   "sweep:$PLAIN"
check_plan "sudo -i runs a login shell in another directory -> strict"         "$PLAIN" "sudo -i git push"                        "sweep:$PLAIN"

# ── the class is read from the COMMITS, never the work tree; the stricter of HEAD, its upstream, origin and the refspecs wins ──
set_upstream() {  # set_upstream <repo> <sha>: refs/remotes/origin/<branch> = sha, the branch tracks it -- no remote is ever contacted
  local d="$1" sha="$2" br
  br="$(git -C "$d" symbolic-ref --short HEAD)"
  git -C "$d" config remote.origin.url "$W/no-such-remote.git"
  git -C "$d" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$d" update-ref "refs/remotes/origin/$br" "$sha"
  git -C "$d" config "branch.$br.remote" origin
  git -C "$d" config "branch.$br.merge" "refs/heads/$br"
}
head_of() { git -C "$1" rev-parse HEAD; }
SW_DEL="$(mk_sweep swdel)"; rm "$SW_DEL/test/run-all.sh"
check_plan "an UNCOMMITTED deletion of the marker on disk does not change the class"            "$SW_DEL" 'git push' "sweep:$SW_DEL"
SW_EDIT="$(mk_sweep swedit)"; printf 'echo hi\n' > "$SW_EDIT/test/run-all.sh"
check_plan "an uncommitted edit that drops the marker's receipt name does not either"           "$SW_EDIT" 'git push' "sweep:$SW_EDIT"
PL_ADD="$(new_repo pladd)"; mkdir -p "$PL_ADD/test" "$PL_ADD/.heimdall"
printf 'RECEIPT_FILE="$X/last-sweep.json"\n' > "$PL_ADD/test/run-all.sh"; printf '%s\n' "$GREEN_DECL" > "$PL_ADD/.heimdall/repo-checks.json"
check_plan "markers ADDED on disk and not committed do not change the class"                    "$PL_ADD" 'git push' "unmanaged:$PL_ADD"
PL_STG="$(new_repo plstg)"; mkdir -p "$PL_STG/test"; printf 'RECEIPT_FILE="$X/last-sweep.json"\n' > "$PL_STG/test/run-all.sh"; git -C "$PL_STG" add -A
check_plan "...nor does a marker that is only staged"                                           "$PL_STG" 'git push' "unmanaged:$PL_STG"
SW_DROP="$(mk_sweep swdrop)"; set_upstream "$SW_DROP" "$(head_of "$SW_DROP")"; git -C "$SW_DROP" rm -q test/run-all.sh; git -C "$SW_DROP" commit -q -m "drop the marker"
check_plan "the pushed commit DROPS the marker, its upstream (@{u}) still has it -> sweep, the stricter" "$SW_DROP" 'git push' "sweep:$SW_DROP"
SW_DROP2="$(mk_sweep swdrop2)"; BR2="$(git -C "$SW_DROP2" symbolic-ref --short HEAD)"
git -C "$SW_DROP2" update-ref "refs/remotes/origin/$BR2" "$(head_of "$SW_DROP2")"; git -C "$SW_DROP2" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$BR2"
git -C "$SW_DROP2" rm -q test/run-all.sh; git -C "$SW_DROP2" commit -q -m "drop the marker"
check_plan "...the same with no branch upstream, only origin/HEAD keeping it"                   "$SW_DROP2" 'git push' "sweep:$SW_DROP2"
SW_SWAP="$(mk_sweep swswap)"; set_upstream "$SW_SWAP" "$(head_of "$SW_SWAP")"
git -C "$SW_SWAP" rm -q test/run-all.sh; mkdir -p "$SW_SWAP/.heimdall"; printf '%s\n' "$GREEN_DECL" > "$SW_SWAP/.heimdall/repo-checks.json"; commit_all "$SW_SWAP" "swap the marker for a declaration"
check_plan "HEAD declares checks, its upstream is a sweep repo -> sweep, the stricter"          "$SW_SWAP" 'git push' "sweep:$SW_SWAP"
UP_DECL="$(mk_checks updecl "$GREEN_DECL")"; set_upstream "$UP_DECL" "$(head_of "$UP_DECL")"; git -C "$UP_DECL" rm -q .heimdall/repo-checks.json; git -C "$UP_DECL" commit -q -m "drop the declaration"
check_plan "HEAD declares nothing, its upstream declares checks -> repo-checks"                  "$UP_DECL" 'git push' "repo-checks:$UP_DECL"
RS="$(new_repo refspec)"; RS_BR="$(git -C "$RS" symbolic-ref --short HEAD)"
git -C "$RS" checkout -q -b other; mkdir -p "$RS/test"; printf 'RECEIPT_FILE="$X/last-sweep.json"\n' > "$RS/test/run-all.sh"; commit_all "$RS" "a branch that carries the marker"; git -C "$RS" checkout -q "$RS_BR"
check_plan "HEAD has no marker, but 'push origin other' pushes a branch that does -> sweep"      "$RS" 'git push origin other' "sweep:$RS"
check_plan "...also as src:dst"                                                                 "$RS" 'git push origin other:main' "sweep:$RS"
check_plan "...and a +force refspec"                                                            "$RS" 'git push origin +other:main' "sweep:$RS"
check_plan "...and after --"                                                                    "$RS" 'git push origin -- other' "sweep:$RS"
check_plan "--all pushes every branch, so the marked one counts"                                "$RS" 'git push --all' "sweep:$RS"
check_plan "pushing the branch you are on is only HEAD: unmanaged"                              "$RS" "git push origin $RS_BR" "unmanaged:$RS"
check_plan "deleting a branch (:other) carries no commit: unmanaged"                            "$RS" 'git push origin :other' "unmanaged:$RS"
check_plan "a refspec that names nothing git knows cannot be placed -> strict"                  "$RS" 'git push origin nosuchbranch' "sweep:$RS"
LNK="$(new_repo lnk)"; mkdir -p "$LNK/test"; ln -s /no/such "$LNK/test/run-all.sh"; commit_all "$LNK" "marker is a link"
check_plan "a marker that is a symlink in the commit cannot be read -> strict"                  "$LNK" 'git push' "sweep:$LNK"
UNBORN="$W/repos/unborn"; mkdir -p "$UNBORN"; git -C "$UNBORN" init -q
check_plan "a repository with no commit has nothing to inspect -> strict"                       "$UNBORN" 'git push' "sweep:$UNBORN"

# ── hardening of the shell model: a wrapper that starts a process runs no builtin in THIS shell, a pipeline's last element may, and the
#    variables a cd depends on are not modelled ──
check_strict "env cd: /usr/bin/env starts a process, so the cd is lost and the push runs where the shell was"  "$PLAIN" "env cd $CHK; git push"
check_strict "nice cd, nohup cd and xargs cd likewise"                       "$PLAIN" "nice cd $CHK; nohup cd $CHK; echo | xargs cd $CHK; git push"
check_strict "sudo cd likewise"                                              "$PLAIN" "sudo cd $CHK; git push"
check_strict "command cd: bash runs the builtin, zsh an external cd, so it is not modelled" "$PLAIN" "command cd $CHK; git push"
check_plan "builtin cd runs the builtin in THIS shell, in both"              "$PLAIN" "builtin cd $CHK; git push"   "repo-checks:$CHK"
check_plan "time cd likewise"                                                "$PLAIN" "time cd $CHK; git push"      "repo-checks:$CHK"
check_plan "the last element of a pipeline may run in the current shell (zsh, bash lastpipe): both outcomes are gated" "$PLAIN" "echo | cd $CHK; git push" "unmanaged:$PLAIN" "repo-checks:$CHK"
check_strict "env -u GIT_DIR undoes an exported GIT_DIR: not modelled"       "$PLAIN" "export GIT_DIR=$CHK/.git; env -u GIT_DIR git push"
check_strict "env -i git push"                                               "$PLAIN" "env -i git push"
check_strict "env -S 'git push'"                                             "$PLAIN" "env -S 'git push'"
# the home directory of these runs is a repository of its own (unmanaged), so an unmodelled change of HOME shows as a row that is not strict
PLAN_ENV="HOME=$PLAIN"
check_strict "HOME=<dir> cd: the cd goes to the temporary HOME"              "$SWEEP" "HOME=$CHK cd; git push"
check_strict "HOME=<dir>; cd ~: the home directory moved"                    "$SWEEP" "HOME=$CHK; cd ~; git push"
check_strict "export HOME=<dir>; cd"                                         "$SWEEP" "export HOME=$CHK; cd; git push"
check_strict "unset HOME; cd"                                                "$SWEEP" "unset HOME; cd; git push"
check_plan "...and a plain cd to that home is followed exactly"              "$SWEEP" "cd; git push"                "unmanaged:$PLAIN"
PLAN_ENV=""
check_strict "CDPATH=<dir>; cd <name>: a relative name may be found elsewhere" "$W/repos" "CDPATH=$W/cdp; cd chk; git push"
check_strict "OLDPWD=<dir>; cd -"                                            "$PLAIN" "OLDPWD=$CHK; cd -; git push"
check_strict "PWD=<dir> git push"                                            "$PLAIN" "PWD=$CHK git push"
check_strict "BASH_ENV=<file> runs a file in every shell it starts"          "$PLAIN" "BASH_ENV=./x.sh bash -c 'git push'"

# ── the third column of a sweep row says whether it is only the strict FALLBACK (the command or git could not be read), or a marker was found ──
fb_column() { printf '%s' "$2" | env HOME="$HOMEDIR" python3 -I -S "$HELPER" "$1" 2>/dev/null | awk -F'\t' 'NR == 1 { print $3 }'; }
[ "$(fb_column "$PLAIN" 'git -C "$X" push')" = fallback ] && ok "B. an uncertain command's strict row is marked fallback" || bad "B. an uncertain command's strict row is not marked fallback" "$(fb_column "$PLAIN" 'git -C "$X" push')"
[ "$(fb_column "$SWEEP" 'git push')" = - ] && ok "B. a sweep row found through a marker is NOT marked fallback (the column holds -)" || bad "B. a marker-derived sweep row is marked fallback" "$(fb_column "$SWEEP" 'git push')"
[ "$(fb_column "$DANGLE" 'git push')" = fallback ] && ok "B. a marker that cannot be read is a fallback row too" || bad "B. an unreadable marker's strict row is not marked fallback"

# ── the receipt attests ONE commit: the resolver names the commits a push sends as sources (the third column of a repo-checks row) ──
SRC="$(mk_checks srcs "$GREEN_DECL")"; printf 'v2\n' > "$SRC/file.txt"; commit_all "$SRC" second
SRC_HEAD="$(head_of "$SRC")"; SRC_PREV="$(git -C "$SRC" rev-parse 'HEAD~1')"; SRC_BR="$(git -C "$SRC" symbolic-ref --short HEAD)"
git -C "$SRC" branch other "$SRC_PREV"; git -C "$SRC" tag v1 "$SRC_PREV"
SRC_CFG="$(mk_checks srccfg "$GREEN_DECL")"; SRC_CFG_HEAD="$(head_of "$SRC_CFG")"
git -C "$SRC_CFG" config remote.origin.url "$W/no-such-remote.git"; git -C "$SRC_CFG" config remote.origin.push 'refs/heads/main:refs/heads/main'
check_sources "a bare push sends HEAD"                           "$SRC" 'git push'                                    "$SRC_HEAD"
check_sources "push <remote> <the branch HEAD is on>"            "$SRC" "git push origin $SRC_BR"                     "$SRC_HEAD"
check_sources "push <remote> HEAD"                               "$SRC" 'git push origin HEAD'                        "$SRC_HEAD"
check_sources "src:dst takes the source"                         "$SRC" 'git push origin HEAD:refs/heads/x'           "$SRC_HEAD"
check_sources "another branch: its own commit"                   "$SRC" 'git push origin other'                       "$SRC_PREV"
check_sources "HEAD~1:main"                                      "$SRC" 'git push origin HEAD~1:main'                 "$SRC_PREV"
check_sources "a full sha as the source"                         "$SRC" "git push origin $SRC_HEAD:main"              "$SRC_HEAD"
check_sources "a tag: the commit it points to"                   "$SRC" 'git push origin v1'                          "$SRC_PREV"
check_sources "tag <name> syntax"                                "$SRC" 'git push origin tag v1'                      "$SRC_PREV"
check_sources "several refspecs: every source"                   "$SRC" "git push origin $SRC_BR other"               "$SRC_HEAD,$SRC_PREV"
check_sources "several pushes in one command: the union"         "$SRC" 'git push; git push origin other'             "$SRC_HEAD,$SRC_PREV"
check_sources "a deletion carries no commit"                     "$SRC" 'git push origin :other'                      "-"
check_sources "--delete carries no commit"                       "$SRC" 'git push --delete origin other'              "-"
check_sources "--all cannot be listed"                           "$SRC" 'git push --all'                              "?"
check_sources "--tags cannot be listed"                          "$SRC" 'git push --tags'                             "?"
check_sources "--mirror cannot be listed"                        "$SRC" 'git push --mirror'                           "?"
check_sources "a wildcard refspec cannot be listed"              "$SRC" "git push origin 'refs/heads/*:refs/heads/*'" "?"
check_sources "push.default=matching picks the refs"             "$SRC" 'git -c push.default=matching push'           "?"
check_sources "a configured remote.<name>.push picks the refs of a bare push" "$SRC_CFG" 'git push'                   "?"
check_sources "...but an explicit refspec overrides it"          "$SRC_CFG" "git push origin $SRC_BR"                 "$SRC_CFG_HEAD"
check_plan "a refspec that names no commit cannot be placed: the strict class" "$SRC" 'git push origin nosuch'           "sweep:$SRC"

# ── EVERY error path is strict: a git that fails, prints nonsense or hangs, at each call the resolver makes, is never read as "no markers" ──
BROKEN="$W/brokengit"; mkdir -p "$BROKEN"
cat > "$BROKEN/git" <<'FAKEGIT_EOF'
#!/usr/bin/env bash
# a git that misbehaves for ONE kind of call and is the real git otherwise. FAKE_GIT_BREAK is <subcommand>[:<text the arguments must contain>];
# FAKE_GIT_MODE is fail (exit 128), garbage (exit 0, nonsense on stdout), empty (exit 0, nothing) or hang (sleeps, replacing this process)
[ -n "${FAKE_GIT_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
sub="${FAKE_GIT_BREAK%%:*}"; pat=""
[ "$FAKE_GIT_BREAK" = "$sub" ] || pat="${FAKE_GIT_BREAK#*:}"
hit=0
case " $* " in
  *" $sub "*) if [ -z "$pat" ]; then hit=1; else case "$*" in *"$pat"*) hit=1 ;; esac; fi ;;
esac
if [ "$hit" = 1 ]; then
  case "${FAKE_GIT_MODE:-fail}" in
    fail)    echo "fatal: simulated git failure" >&2; exit 128 ;;
    garbage) echo "garbage that is not what git prints"; exit 0 ;;
    empty)   exit 0 ;;
    hang)    exec sleep 20 ;;
  esac
fi
exec "$FAKE_GIT_REAL" "$@"
FAKEGIT_EOF
chmod +x "$BROKEN/git"
REAL_GIT="$(command -v git)"
ERRREPO="$(new_repo errrepo)"; set_upstream "$ERRREPO" "$(head_of "$ERRREPO")"; git -C "$ERRREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
check_plan "fixture: with a healthy git this repository and command are unmanaged, so a broken-git answer of 'unmanaged' below would be a real downgrade" "$ERRREPO" 'git push' "unmanaged:$ERRREPO"
PLAN_PATH="$BROKEN:$PATH"
for spec in 'rev-parse:--absolute-git-dir' 'rev-parse:--show-toplevel' 'rev-parse:HEAD' 'rev-parse:refs/remotes/origin' 'symbolic-ref' 'for-each-ref' 'config' 'ls-tree'; do
  for mode in fail garbage; do
    PLAN_ENV="FAKE_GIT_REAL=$REAL_GIT FAKE_GIT_BREAK=$spec FAKE_GIT_MODE=$mode"
    check_strict "git [$spec] answers '$mode' -> every row is the strict class, never unmanaged" "$ERRREPO" 'git push'
  done
done
for spec in 'rev-parse:--absolute-git-dir' 'rev-parse:HEAD' 'rev-parse:refs/remotes/origin'; do
  PLAN_ENV="FAKE_GIT_REAL=$REAL_GIT FAKE_GIT_BREAK=$spec FAKE_GIT_MODE=empty"
  check_strict "git [$spec] succeeds with no output -> strict" "$ERRREPO" 'git push'
done
PLAN_ENV="FAKE_GIT_REAL=$REAL_GIT FAKE_GIT_BREAK=cat-file FAKE_GIT_MODE=fail"
check_strict "git [cat-file] fails on a repository whose test/run-all.sh has to be read -> strict" "$OTHER_RUNNER" 'git push'
for spec in 'ls-tree' 'rev-parse:HEAD'; do
  PLAN_ENV="FAKE_GIT_REAL=$REAL_GIT FAKE_GIT_BREAK=$spec FAKE_GIT_MODE=hang HMD_PUSH_TARGET_TIMEOUT_S=1"
  check_strict "git [$spec] hangs past the resolver's timeout -> strict" "$ERRREPO" 'git push' silent
done
PLAN_ENV=""; PLAN_PATH=""
# ── review round 2026-10-14, finding 2: ONE resolved (git dir, work tree) pair per row (columns 2 and 4), and it is git's own answer for that layout ──
SUBSRC="$(mk_sweep subsrc)"; SUPER="$(new_repo super)"
git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1 && commit_all "$SUPER" "add the submodule"
[ -f "$SUPER/sub/.git" ] && ok "B. fixture sanity: the submodule's .git is a file, its git directory lives in the superproject" || bad "B. the submodule fixture did not materialise" "$(ls -A "$SUPER/sub" 2>&1 | head -c 200)"
phys() { ( cd "$1" && pwd -P ); }
pair_of() { printf '%s' "$2" | env HOME="$HOMEDIR" python3 -I -S "$HELPER" "$1" 2>/dev/null | awk -F'\t' 'NR == 1 { print $2 "|" $4 }'; }
check_pair() {  # check_pair <label> <base> <command> <work tree> <git dir>
  local got; got="$(pair_of "$2" "$3")"
  if [ "$got" = "$4|$5" ]; then ok "B. pair: $1"; else bad "B. pair: $1" "want $4|$5 | got $got"; fi
}
check_pair "a plain repository"                                  "$PLAIN"      'git push'   "$PLAIN" "$PLAIN/.git"
check_pair "from a subdirectory: the toplevel's pair"            "$PLAIN/sub"  'git push'   "$PLAIN" "$PLAIN/.git"
check_pair "a linked worktree: its own git directory under .git/worktrees" "$WT_SWEEP" 'git push' "$WT_SWEEP" "$(phys "$(git -C "$WT_SWEEP" rev-parse --absolute-git-dir)")"
check_pair "a submodule: its git directory lives in the superproject"      "$SUPER/sub" 'git push' "$SUPER/sub" "$(phys "$(git -C "$SUPER/sub" rev-parse --absolute-git-dir)")"
check_pair "DECOY --work-tree: the repository's own pair, not the decoy's" "$PLAIN" "git --git-dir=$SWEEP/.git --work-tree=$PLAIN push" "$SWEEP" "$SWEEP/.git"
check_pair "GIT_DIR=<x>/.git, started in another repository"     "$PLAIN"      "GIT_DIR=$CHK/.git git push" "$CHK" "$CHK/.git"
check_pair "-C <b> started in a: the pair of b"                  "$PLAIN"      "git -C $CHK push" "$CHK" "$CHK/.git"
# a GIT_* variable the resolver does not reproduce gives the PUSH another view of the repository (refs, objects, namespaces) than the one the gate
# reads: uncertain. The ones git reads itself at every call the resolver makes, and the ones that cannot change what is pushed, keep the class.
for v in GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_INDEX_FILE GIT_REPLACE_REF_BASE GIT_EXEC_PATH GIT_GRAFT_FILE; do
  check_strict "B. GIT_*: $v=<x> in front of the push: not reproduced, so the push may see other refs than the gate reads" "$PLAIN" "$v=$CHK/.git git -C $PLAIN push origin main"
  check_strict "B. GIT_*: export $v=<x> likewise" "$PLAIN" "export $v=$CHK/.git; git -C $PLAIN push origin main"
done
check_plan "GIT_*: GIT_SSH_COMMAND / GIT_TERMINAL_PROMPT / GIT_TRACE cannot change the repository or its refs: the class stands" "$PLAIN" "GIT_SSH_COMMAND='ssh -i k' GIT_TERMINAL_PROMPT=0 GIT_TRACE=1 git push origin main" "unmanaged:$PLAIN"
check_plan "GIT_*: GIT_CEILING_DIRECTORIES and GIT_CONFIG_NOSYSTEM are read by git itself at every call: modelled" "$PLAIN" "GIT_CEILING_DIRECTORIES=$W GIT_CONFIG_NOSYSTEM=1 git push origin main" "unmanaged:$PLAIN"
# linear time: one regex over a long command used to backtrack quadratically, and a signal cannot interrupt a regex, so the resolver's own timeout never
# fired and the hook's (a failed hook lets the push through) was the only bound
python3 -c 'import sys; sys.stdout.write("foo " + "git " * 20000)' > "$W/longcmd.txt"
T_LONG0=$SECONDS
perl -e 'alarm 40; exec @ARGV' env HOME="$HOMEDIR" python3 -I -S "$HELPER" "$PLAIN" < "$W/longcmd.txt" > "$W/long.out" 2>/dev/null
T_LONG=$((SECONDS - T_LONG0))
{ [ "$T_LONG" -lt 8 ] && grep -q "^sweep${TAB}" "$W/long.out"; } && ok "B. linear time: a long command that names git 20000 times and never push is read in ${T_LONG}s and is strict" || bad "B. linear time: a long command" "took ${T_LONG}s: $(head -c 200 "$W/long.out")"

# a marker that is not what it should be, in the commit: every shape is strict, none is "no marker"
RUNDIR="$(mk_sweep rundir)"; git -C "$RUNDIR" rm -q test/run-all.sh; mkdir -p "$RUNDIR/test/run-all.sh"; printf 'x\n' > "$RUNDIR/test/run-all.sh/k"; commit_all "$RUNDIR" "run-all.sh becomes a directory"
check_plan "a commit whose test/run-all.sh is a directory is strict: a marker that is not a regular file" "$RUNDIR" 'git push' "sweep:$RUNDIR"

# ── the shell differential: every command below is RUN by real bash (and zsh when installed), with a git that only records where it was started
#    and with which options; the repositories those pushes really went to are then compared with what the resolver answers. Either every real
#    push is gated at least as strictly as its repository's own class, or the whole plan is the strict class. A model that is wrong in a way
#    that lets a push through shows up here as a command where the two disagree. ──
FAKEBIN="$W/fakebin"; mkdir -p "$FAKEBIN" "$W/cdp"
cat > "$FAKEBIN/git" <<'FAKEGIT_EOF'
#!/usr/bin/env bash
{ printf '%s' "$(pwd -P)"; printf '\037%s' "${GIT_DIR-}" "${GIT_WORK_TREE-}" "$@"; printf '\n'; } >> "$HMD_DIFF_LOG"
exit 0
FAKEGIT_EOF
chmod +x "$FAKEBIN/git"
ln -s "$SWEEP" "$W/cdp/chk"
HOMEREPO="$(new_repo homerepo)"     # the HOME of every differential run is a repository (unmanaged), so a wrong idea of where `cd` goes shows
DIFF_FIXTURES="$(jq -nc --arg plain "$PLAIN" --arg chk "$CHK" --arg sweep "$SWEEP" --arg spaced "$SPACED" --arg other "$OTHER_RUNNER" --arg wrepos "$W/repos" --arg cdp "$W/cdp" --arg fakegit "$FAKEBIN/git" \
  '{paths: {PLAIN: $plain, CHK: $chk, SWEEP: $sweep, SPACED: $spaced, OTHER: $other, WREPOS: $wrepos, CDP: $cdp, FAKEGIT: $fakegit},
    classes: {($plain): "unmanaged", ($chk): "repo-checks", ($sweep): "sweep", ($spaced): "repo-checks", ($other): "unmanaged"}}')"
DIFF_SHELLS="bash"; command -v zsh >/dev/null 2>&1 && DIFF_SHELLS="bash zsh"
cat > "$W/diff-shells.py" <<'DIFF_PY_EOF'
import json, os, subprocess, sys

fx = json.loads(os.environ["HMD_DIFF_FIXTURES"])
paths, classes = fx["paths"], fx["classes"]
helper, fakebin, log = os.environ["HMD_DIFF_HELPER"], os.environ["HMD_DIFF_FAKEBIN"], os.environ["HMD_DIFF_LOG"]
real_git, home = os.environ["HMD_DIFF_REALGIT"], os.environ["HMD_DIFF_HOME"]
RANK = {"unmanaged": 0, "repo-checks": 1, "sweep": 2}
CORPUS = [
    ("PLAIN", "git push"),
    ("PLAIN", "git -C @CHK@ push"),
    ("PLAIN", "git -C '@SPACED@' push"),
    ("PLAIN", 'git -C "@SPACED@" push'),
    ("WREPOS", "git -C chk push"),
    ("PLAIN", "git --git-dir=@CHK@/.git push"),
    ("PLAIN", "GIT_DIR=@CHK@/.git git push"),
    ("PLAIN", "export GIT_DIR=@SWEEP@/.git; git push"),
    ("PLAIN", "export GIT_DIR=@SWEEP@/.git; unset GIT_DIR; git push"),
    ("PLAIN", "cd @CHK@ && git push"),
    ("PLAIN", "cd @CHK@; cd @SWEEP@; git push"),
    ("WREPOS", "cd chk; cd ../sweep; git push"),
    ("PLAIN", "cd '@SPACED@' && git push"),
    ("PLAIN", 'cd "@SPACED@" && git push'),
    ("PLAIN", "pushd @CHK@ >/dev/null && git push"),
    ("PLAIN", "pushd @CHK@ >/dev/null; popd >/dev/null; git push"),
    ("SWEEP", "(cd @CHK@ && git push)"),
    ("SWEEP", "(cd @CHK@) && git push"),
    ("PLAIN", 'echo "$(cd @CHK@ && git push)"'),
    ("PLAIN", "x=$(cd @CHK@ && pwd); git push"),
    ("PLAIN", "echo `cd @CHK@ && git push`"),
    ("PLAIN", "eval 'cd @CHK@'; git push"),
    ("PLAIN", 'eval "cd @CHK@ && git push"'),
    ("PLAIN", "sh -c 'cd @CHK@ && git push'"),
    ("PLAIN", 'bash -c "cd @CHK@ && git push"'),
    ("PLAIN", "sh -c 'cd @CHK@'; git push"),
    ("PLAIN", "bash <<< 'git -C @CHK@ push'"),
    ("PLAIN", "bash <<EOF\ngit -C @CHK@ push\nEOF"),
    ("PLAIN", "echo x | xargs git -C @CHK@ push"),
    ("PLAIN", "env FOO=1 git -C @CHK@ push"),
    ("PLAIN", "command git -C @CHK@ push"),
    ("PLAIN", "@FAKEGIT@ -C @CHK@ push"),
    ("PLAIN", "time git -C @CHK@ push"),
    ("PLAIN", "nohup git -C @CHK@ push"),
    ("PLAIN", "test -d @CHK@ && cd @CHK@; git push"),
    ("PLAIN", "false || cd @CHK@ && git push"),
    ("PLAIN", "cd @CHK@ & git push"),
    ("PLAIN", "cd @CHK@ | cat; git push"),
    ("PLAIN", "echo | cd @CHK@; git push"),
    ("PLAIN", "echo | cd @CHK@ && git push"),
    ("PLAIN", "env cd @CHK@; git push"),
    ("PLAIN", "echo | xargs cd @CHK@; git push"),
    ("PLAIN", "nice cd @CHK@; git push"),
    ("PLAIN", "command cd @CHK@; git push"),
    ("PLAIN", "builtin cd @CHK@; git push"),
    ("PLAIN", "time cd @CHK@; git push"),
    ("PLAIN", "export GIT_DIR=@CHK@/.git; env -u GIT_DIR git push"),
    ("SWEEP", "HOME=@CHK@ cd; git push"),
    ("SWEEP", "HOME=@CHK@; cd; git push"),
    ("SWEEP", "export HOME=@CHK@; cd ~; git push"),
    ("WREPOS", "CDPATH=@CDP@; cd chk; git push"),
    ("PLAIN", 'cd "$D" && git push'),
    ("PLAIN", "cd $D; git push"),
    ("PLAIN", 'git -C "$D" push'),
    ("PLAIN", 'git -C "$(echo @CHK@)" push'),
    ("PLAIN", "cd -; git push"),
    ("PLAIN", "cd ~; git push"),
    ("PLAIN", "cd; git push"),
    ("PLAIN", 'eval "cd $D"; git push'),
    ("PLAIN", "D2=@CHK@; git -C $D2 push"),
    ("PLAIN", "echo 'git -C @CHK@ push' | sh"),
    ("PLAIN", "if cd @CHK@; then git push; fi"),
    ("PLAIN", "{ cd @CHK@; git push; }"),
    ("PLAIN", "f() { cd @CHK@; }; f; git push"),
    ("PLAIN", "alias git='git -C @CHK@'; git push"),
    ("PLAIN", "cd /no/such/dir; git push"),
    ("PLAIN", "source ./nothing.sh; git push"),
]


def shell_pushes(shell, base, cmd):
    """The repositories (physical top level; None where git cannot place the push) the shell's pushes really went to."""
    open(log, "w").close()
    env = dict(os.environ, PATH=fakebin + os.pathsep + os.environ["PATH"], HOME=home, HMD_DIFF_LOG=log, D=paths["CHK"])
    for name in ("GIT_DIR", "GIT_WORK_TREE", "CDPATH", "BASH_ENV", "ENV"):
        env.pop(name, None)
    subprocess.run([shell, "-c", cmd], cwd=base, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=60)
    repos = []
    with open(log, "rb") as fh:
        records = [r for r in fh.read().split(b"\n") if r]
    for record in records:
        cwd, gdir, gwt, *args = record.decode("utf-8", "replace").split("\x1f")
        i = 0
        while i < len(args):
            if args[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
                i += 2
            elif args[i].startswith("-"):
                i += 1
            else:
                break
        if i >= len(args) or args[i] != "push":
            continue
        genv = dict(os.environ)
        for name in ("GIT_DIR", "GIT_WORK_TREE"):
            genv.pop(name, None)
        if gdir:
            genv["GIT_DIR"] = gdir
        if gwt:
            genv["GIT_WORK_TREE"] = gwt
        got = subprocess.run([real_git] + args[:i] + ["rev-parse", "--absolute-git-dir"], cwd=cwd, env=genv,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if got.returncode != 0 or not got.stdout.strip():
            repos.append(None)
            continue
        gd = os.path.realpath(got.stdout.strip())
        repos.append(os.path.dirname(gd) if os.path.basename(gd) == ".git" else gd)
    return repos


def plan_rows(base, cmd):
    got = subprocess.run([sys.executable, "-I", "-S", helper, base], input=cmd, capture_output=True, text=True,
                         env=dict(os.environ, HOME=home, HMD_PUSH_TARGET_TIMEOUT_S="60"))
    return [line.split("\t") for line in got.stdout.splitlines() if line]


def verdict(repos, rows):
    """"strict" when the plan is the strict class throughout (or gave no answer: the hook then runs the strict gate); "exact" when every real
    push is covered by a row of its own repository at least as strict as that repository's class; None when a push slipped through."""
    if not rows or all(r[0] == "sweep" or (r[0] == "repo-checks" and r[2:3] == ["?"]) for r in rows):
        return "strict"
    for repo in repos:
        need = RANK[classes.get(repo, "unmanaged")] if repo else 99
        if not any(r[1] == repo and RANK.get(r[0], 0) >= need for r in rows):
            return None
    return "exact"


bad, stats = [], {}
for shell in sys.argv[1:]:
    exact = strict = pushes = 0
    for key, template in CORPUS:
        cmd = template
        for name, value in paths.items():
            cmd = cmd.replace("@%s@" % name, value)
        base = paths[key]
        try:
            repos = shell_pushes(shell, base, cmd)
        except subprocess.TimeoutExpired:
            bad.append("%s in %s: the shell did not finish: %r" % (shell, key, cmd))
            continue
        rows = plan_rows(base, cmd)
        pushes += len(repos)
        got = verdict(repos, rows)
        if got is None:
            bad.append("%s in %s: %r\n         real pushes went to: %s\n         the plan says: %s"
                       % (shell, key, cmd, [os.path.basename(r) if r else None for r in repos], rows))
        elif got == "exact" and repos:
            exact += 1
        else:
            strict += 1
    stats[shell] = (exact, strict, pushes)
    if exact < 25:
        bad.append("%s: only %d commands were resolved exactly; the corpus no longer exercises the exact path" % (shell, exact))
for line in bad:
    print("FAIL " + line)
for shell, (e, s, p) in stats.items():
    print("SUMMARY %s: %d commands, %d resolved exactly, %d strict, %d real pushes" % (shell, len(CORPUS), e, s, p))
sys.exit(1 if bad else 0)
DIFF_PY_EOF
DIFF_OUT="$(HMD_DIFF_FIXTURES="$DIFF_FIXTURES" HMD_DIFF_HELPER="$HELPER" HMD_DIFF_FAKEBIN="$FAKEBIN" HMD_DIFF_LOG="$W/diff.log" HMD_DIFF_REALGIT="$REAL_GIT" HMD_DIFF_HOME="$HOMEREPO" \
  python3 -I -S "$W/diff-shells.py" $DIFF_SHELLS 2>&1)"; DIFF_RC=$?
if [ "$DIFF_RC" = 0 ]; then ok "B. shell differential (real shell vs resolver): no push slipped through. $(grep '^SUMMARY' <<<"$DIFF_OUT" | tr '\n' ';')"
else bad "B. shell differential: the resolver and a real shell disagree about where a push goes" "$(printf '%s' "$DIFF_OUT" | head -c 4000)"; fi

# the real heimdall repo is class sweep: if run-all.sh stops naming the receipt, this goes RED
REPO_P="$(cd "$REPO" && pwd -P)"
check_plan "THIS repo (test/run-all.sh) is a sweep repo" "$REPO" 'git push'                        "sweep:$REPO_P"

# ════════════════════════════════════════════════════════════════════════════
section "C. the hook"
mk_plugin() {  # mk_plugin <name> [--no-resolver] [--real-state] -> path
  local d="$W/plugin-$1" opt; shift
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  cp "$RC_BIN" "$d/bin/heimdall-repo-checks" 2>/dev/null
  cp "$HELPER" "$RC_PY" "$RC_DEF" "$d/bin/lib/" 2>/dev/null
  for opt in "$@"; do
    case "$opt" in
      --no-resolver) rm -f "$d/bin/lib/hmd_push_target.py" ;;
      --real-state)  cp "$REPO/bin/heimdall-state" "$d/bin/heimdall-state" ;;
      --spy-runner)  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/runner.calls"\nexec python3 -I -S "%s/bin/lib/hmd_repo_checks.py" "$@"\n' "$MARKS" "$d" > "$d/bin/heimdall-repo-checks" ;;
    esac
  done
  if [ ! -e "$d/bin/heimdall-state" ]; then
    cat > "$d/bin/heimdall-state" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\n' "\$PWD" "\$*" "\${GIT_DIR-}" "\${GIT_WORK_TREE-}" >> "$MARKS/state.calls"
rc="\${FAKE_HSTATE_RC:-0}"
if [ -n "\${FAKE_HSTATE_FAIL_IN:-}" ]; then if [ "\$(pwd -P)" = "\$FAKE_HSTATE_FAIL_IN" ]; then rc=2; else rc=0; fi; fi
if [ "\$rc" = 0 ]; then echo "All quality gates pass."; else echo "GATE FAILED: fake sweep gate" >&2; fi
exit "\$rc"
EOF
  fi
  cat > "$d/bin/secret-scan" <<'EOF'
#!/usr/bin/env bash
rc=0; [ "${1:-}" = --require ] && rc="${FAKE_SCAN_REQUIRE_RC:-0}"
[ "$rc" = 0 ] || echo "fake leak" >&2
exit "$rc"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/parallelism-tracker"
  chmod +x "$d/bin/"*
  printf '%s' "$d"
}
PLUGIN="$(mk_plugin main)"
PLUGIN_REAL="$(mk_plugin real --real-state)"
PLUGIN_NORES="$(mk_plugin nores --no-resolver)"

run_hook() {  # run_hook <plugin> <cwd> <command> [ENV=VAL ...] -> RC OUT ERR  (PAYLOAD_CWD, when set, rides in the payload)
  local plugin="$1" cwd="$2" cmd="$3" payload; shift 3
  if [ -n "${PAYLOAD_CWD:-}" ]; then
    payload="$(jq -nc --arg c "$cmd" --arg d "$PAYLOAD_CWD" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
  else
    payload="$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  fi
  : > "$MARKS/state.calls"
  OUT="$(cd "$cwd" && printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$plugin" PATH="$plugin/bin:$PATH" "$@" bash "$plugin/bin/heimdall-precheck-bash" 2>"$W/hook.err")"
  RC=$?
  ERR="$(cat "$W/hook.err")"
}
expect_rc() { if [ "$RC" = "$2" ]; then ok "$1  [rc=$RC]"; else bad "$1" "wanted rc=$2, got rc=$RC | stdout: $(printf '%s' "$OUT" | head -c 300) | stderr: $(printf '%s' "$ERR" | head -c 500)"; fi; }
err_has()   { case "$ERR" in *"$2"*) ok "$1" ;; *) bad "$1" "stderr lacks '$2': $(printf '%s' "$ERR" | head -c 500)" ;; esac; }
out_has()   { case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "stdout lacks '$2': $(printf '%s' "$OUT" | head -c 500)" ;; esac; }
state_calls() { wc -l < "$MARKS/state.calls" | tr -d ' '; }
state_cwds()  { local p; while IFS="$TAB" read -r p _; do ( cd "$p" 2>/dev/null && pwd -P ); done < "$MARKS/state.calls"; }
# a deny is JSON on stdout and the same text on stderr (Claude Code shows only stderr for exit 2)
denies() {  # denies <label> <pattern-in-error>
  if printf '%s' "$OUT" | jq -e --arg p "$2" '.error | test("BLOCKED") and test($p)' >/dev/null 2>&1 && grep -qF 'BLOCKED' <<<"$ERR"; then ok "$1"; else bad "$1" "stdout: $(printf '%s' "$OUT" | head -c 500) | stderr: $(printf '%s' "$ERR" | head -c 300)"; fi
}
# the strict (sweep) gate ran for <dir> and blocked: rc 2, the fake gate called exactly once, inside <dir>
strict_blocks() {  # strict_blocks <label> <expected gate dir>  -- uses RC OUT ERR of the run just made
  if [ "$RC" = 2 ] && [ "$(state_calls)" = 1 ] && [ "$(state_cwds)" = "$2" ] && printf '%s' "$OUT" | jq -e '.error | test("BLOCKED: pre-push quality gate failed")' >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1" "rc=$RC calls=$(state_calls) gate ran in '$(state_cwds)' (want '$2') | stdout: $(printf '%s' "$OUT" | head -c 300) | stderr: $(printf '%s' "$ERR" | head -c 300)"
  fi
}

# ── (a) the sweep regime: unchanged, fail closed ──
run_hook "$PLUGIN" "$SWEEP" 'git push origin main' FAKE_HSTATE_RC=2
expect_rc "C1. (a) sweep repo, gate fails -> BLOCKED" 2
denies "C1. ...with the quality-gate verdict" 'quality gate'
[ "$(state_calls)" = 1 ] && [ "$(state_cwds)" = "$SWEEP" ] && ok "C1. ...heimdall-state check-quality-gates ran once, inside the repo" || bad "C1. gate call" "calls=$(state_calls) cwd=$(state_cwds)"
run_hook "$PLUGIN" "$SWEEP" 'git push origin main'
expect_rc "C2. (a) sweep repo, gate passes -> allowed" 0
err_has "C2. ...the gate's verdict is relayed on stderr" 'All quality gates pass.'
run_hook "$PLUGIN" "$SWEEP/test" 'git push'
{ [ "$RC" = 0 ] && [ "$(state_cwds)" = "$SWEEP" ]; } && ok "C2b. (a) from a subdirectory: the gate is evaluated at the repo's toplevel" || bad "C2b. subdirectory cwd" "rc=$RC cwd=$(state_cwds)"
# the REAL gate: a sweep repo with green booleans but no receipt must still be refused (the marker is the repo's, never the receipt's)
SWEEP2="$(mk_sweep sweep2)"
( cd "$SWEEP2" && "$PLUGIN_REAL/bin/heimdall-state" init >/dev/null 2>&1 && HMD_LINT_WAIVER=fixture "$PLUGIN_REAL/bin/heimdall-state" mark-clean >/dev/null 2>&1 )
run_hook "$PLUGIN_REAL" "$SWEEP2" 'git push'
expect_rc "C3. (a) real heimdall-state, no sweep receipt -> BLOCKED (a missing receipt cannot downgrade the repo)" 2
out_has "C3. ...for the missing sweep receipt" 'no sweep receipt'
# the gate belongs to the repo pushed, not to the session's cwd
run_hook "$PLUGIN" "$PLAIN" "git -C $SWEEP push" FAKE_HSTATE_RC=2
expect_rc "C4. (a) target, unmanaged cwd: git -C <sweep repo> push -> BLOCKED" 2
[ "$(state_cwds)" = "$SWEEP" ] && ok "C4. ...the gate ran in the TARGET repo, not the cwd" || bad "C4. gate ran in the wrong place" "$(state_cwds)"
run_hook "$PLUGIN" "$PLAIN" "cd $SWEEP && git push" FAKE_HSTATE_RC=2
expect_rc "C5. (a) target via cd <sweep repo> && git push -> BLOCKED" 2

# ── (c) unmanaged: a warning, never a block -- but only for a repo positively without markers ──
run_hook "$PLUGIN" "$PLAIN" 'git push origin main' FAKE_HSTATE_RC=2
expect_rc "C6. (c) unmanaged repo, a failing sweep gate would block -> allowed" 0
[ "$(state_calls)" = 0 ] && ok "C6. ...heimdall's sweep gate was never consulted for it" || bad "C6. heimdall-state was called for an unmanaged repo"
{ [ "$(grep -c 'WARNING' <<<"$ERR")" = 1 ] && grep 'WARNING' <<<"$ERR" | grep -qF "$PLAIN" && grep 'WARNING' <<<"$ERR" | grep -qF '.heimdall/repo-checks.json'; } \
  && ok "C6. ...exactly one WARNING line, naming the repo and how to gate it" || bad "C6. warning line" "$ERR"
[ -z "$OUT" ] && ok "C6. ...stdout stays empty (it is reserved for a deny)" || bad "C6. unexpected stdout" "$OUT"
run_hook "$PLUGIN" "$NOGIT" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C7. a cwd that is not inside a repository cannot be positively resolved: the strict gate runs on it (not a warning)" "$NOGIT"
run_hook "$PLUGIN" "$NOGIT" 'git push'
{ [ "$RC" = 0 ] && ! grep -q 'WARNING' <<<"$ERR" && [ "$(state_calls)" = 1 ]; } && ok "C7. ...and when that gate passes the push goes on without a warning  [rc=0]" || bad "C7. non-repo cwd, passing gate" "rc=$RC $ERR"
run_hook "$PLUGIN" "$OTHER_RUNNER" 'git push' FAKE_HSTATE_RC=2
expect_rc "C7b. (c) a repo with somebody else's test/run-all.sh (readable, no marker) -> allowed with a warning" 0
err_has "C7b. ...the warning" 'WARNING'

# ── (b) own checks: only a green, current, clean receipt, bound to the commit, its tree and the declaration, passes ──
B_GREEN="$(mk_checks bgreen "$GREEN_DECL")"; run_checks "$B_GREEN"
run_hook "$PLUGIN" "$B_GREEN" 'git push origin main' FAKE_HSTATE_RC=2
expect_rc "C8. (b) green current receipt -> allowed (heimdall's failing sweep gate is not asked)" 0
[ "$(state_calls)" = 0 ] && ok "C8. ...heimdall-state was never called" || bad "C8. heimdall-state called for a repo-checks repo"
err_has "C8. ...the GREEN verdict is relayed on stderr" 'GREEN'
[ "$(grep -c 'WARNING' <<<"$ERR")" = 0 ] && ok "C8. ...and no unmanaged warning" || bad "C8. spurious warning" "$ERR"

B_MISSING="$(mk_checks bmissing "$GREEN_DECL")"
run_hook "$PLUGIN" "$B_MISSING" 'git push'
expect_rc "C9. (b) no receipt -> BLOCKED (fail closed)" 2
denies "C9. ...names the runner command" "heimdall-repo-checks run --repo $B_MISSING"
denies "C9. ...and says there is no receipt" 'no receipt'

B_STALE="$(mk_checks bstale "$GREEN_DECL")"; run_checks "$B_STALE"; printf 'v2\n' > "$B_STALE/file.txt"; commit_all "$B_STALE" later
run_hook "$PLUGIN" "$B_STALE" 'git push'
expect_rc "C10. (b) receipt for an older commit -> BLOCKED" 2
denies "C10. ...says stale and names the runner" "(?i)stale"

B_RED="$(mk_checks bred "$(decl_json fine 'true' broken 'exit 1')")"; run_checks "$B_RED"
run_hook "$PLUGIN" "$B_RED" 'git push'
expect_rc "C11. (b) red receipt -> BLOCKED" 2
denies "C11. ...names the failing check" 'broken'

B_DIRTY="$(mk_checks bdirty "$GREEN_DECL")"; printf 'v2\n' > "$B_DIRTY/file.txt"; run_checks "$B_DIRTY"
run_hook "$PLUGIN" "$B_DIRTY" 'git push'
expect_rc "C12. (b) receipt recorded on a dirty tree -> BLOCKED" 2
denies "C12. ...says why" '(?i)uncommitted'

B_EDIT="$(mk_checks bedit "$GREEN_DECL")"; run_checks "$B_EDIT"; printf '%s\n' "$(decl_json only 'true')" > "$B_EDIT/.heimdall/repo-checks.json"
run_hook "$PLUGIN" "$B_EDIT" 'git push'
expect_rc "C13. (b) an UNCOMMITTED edit of the declaration changes nothing about the commit pushed: the receipt for HEAD still passes" 0
git -C "$B_EDIT" add -A; git -C "$B_EDIT" commit -q -m "declare other checks"
run_hook "$PLUGIN" "$B_EDIT" 'git push'
expect_rc "C13b. ...but once that edit is COMMITTED the old receipt is for another commit -> BLOCKED" 2

B_BAD="$(mk_checks bbad 'this is not json')"
run_hook "$PLUGIN" "$B_BAD" 'git push'
expect_rc "C14. (b) a declaration that is present but invalid -> BLOCKED (never downgraded to unmanaged)" 2

# the site's real shape: a heimdall-state.json that says tests are failing and a dirty tree, no sweep receipt, plus a green record of its own checks
B_SITE="$(mk_checks bsite "$GREEN_DECL")"
( cd "$B_SITE" && "$PLUGIN_REAL/bin/heimdall-state" init >/dev/null 2>&1 && "$PLUGIN_REAL/bin/heimdall-state" mark-dirty >/dev/null 2>&1 )
run_checks "$B_SITE"
( cd "$B_SITE" && "$PLUGIN_REAL/bin/heimdall-state" check-quality-gates >/dev/null 2>&1 ); [ "$?" = 2 ] && ok "C15. fixture sanity: the real sweep gate WOULD block this repo (failing state, no sweep receipt)" || bad "C15. fixture sanity: the real gate does not block it"
run_hook "$PLUGIN_REAL" "$B_SITE" 'git push'
expect_rc "C15. (b) a green record of its own checks passes where heimdall's gate would have blocked" 0

# forged and mismatched receipts, through the hook
B_FORGED="$(mk_checks bforged "$GREEN_DECL")"
mkdir -p "$B_FORGED/.heimdall/receipts"
jq -n --arg h "$(git -C "$B_FORGED" rev-parse HEAD)" --slurpfile d "$B_FORGED/.heimdall/repo-checks.json" '{schema:1, head_sha:$h, dirty:false, exit_code:0, finished_at:"2026-10-13T00:00:00Z",
  checks:($d[0].checks | map({name:.name, cmd:.cmd, exit_code:0, secs:0}))}' > "$(receipt_of "$B_FORGED")"
run_hook "$PLUGIN" "$B_FORGED" 'git push'
expect_rc "C16a. (b) FORGED: a hand-written exit_code 0 for the current commit and the declared checks, without tree_sha/decl_sha256 -> BLOCKED" 2
denies "C16a. ...refused for the binding it cannot show" 'tree'
B_REPLAY="$(mk_checks breplay "$GREEN_DECL")"; printf 'other\n' > "$B_REPLAY/file.txt"; commit_all "$B_REPLAY" "a different commit"
mkdir -p "$B_REPLAY/.heimdall/receipts"; cp "$(receipt_of "$B_GREEN")" "$(receipt_of "$B_REPLAY")"
run_hook "$PLUGIN" "$B_REPLAY" 'git push'
expect_rc "C16b. (b) REPLAY: a genuine green receipt copied from another checkout/commit -> BLOCKED" 2
denies "C16b. ...stale" "(?i)stale"
B_OTHER="$(mk_checks bother "$(decl_json solo 'true')")"; mkdir -p "$B_OTHER/.heimdall/receipts"
jq --arg h "$(git -C "$B_OTHER" rev-parse HEAD)" --arg t "$(git -C "$B_OTHER" rev-parse 'HEAD^{tree}')" '.head_sha = $h | .tree_sha = $t' "$(receipt_of "$B_GREEN")" > "$(receipt_of "$B_OTHER")"
run_hook "$PLUGIN" "$B_OTHER" 'git push'
expect_rc "C16c. (b) MISMATCH: another repo's green receipt re-pointed at this commit and tree, but for another check list -> BLOCKED" 2
denies "C16c. ...the declaration hash gives it away" 'declaration'

# ── target != cwd, in both directions ──
run_hook "$PLUGIN" "$SWEEP" "git -C $B_GREEN push" FAKE_HSTATE_RC=2
expect_rc "C17. cwd is a sweep repo that would block, the push goes to a green (b) repo -> allowed" 0
[ "$(state_calls)" = 0 ] && ok "C17. ...the cwd's gate was not applied to somebody else's push" || bad "C17. cwd gate applied to another repo's push"
run_hook "$PLUGIN" "$PLAIN" "git -C $B_RED push"
expect_rc "C18. cwd is unmanaged, the push goes to a red (b) repo -> BLOCKED by the target's own record" 2
run_hook "$PLUGIN" "$SWEEP" "cd $B_RED && git push" FAKE_HSTATE_RC=0
expect_rc "C19. cd <red (b) repo> && git push from a passing sweep repo -> BLOCKED" 2
run_hook "$PLUGIN" "$B_GREEN" "(cd $B_MISSING && git push)"
expect_rc "C19b. (cd <(b) repo without a receipt> && git push) from a green repo -> BLOCKED" 2

# ── payload cwd is the shell's cwd ──
PAYLOAD_CWD="$B_GREEN" run_hook "$PLUGIN" "$SWEEP" 'git push' FAKE_HSTATE_RC=2
expect_rc "C20. the payload's cwd (the shell's) decides the target when the hook process sits elsewhere" 0
PAYLOAD_CWD="$W/does/not/exist" run_hook "$PLUGIN" "$SWEEP" 'git push' FAKE_HSTATE_RC=2
expect_rc "C20b. a payload cwd that is not a directory is ignored: the process cwd decides" 2

# ── several targets: all of them are gated ──
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push && git -C $SWEEP push" FAKE_HSTATE_RC=2
expect_rc "C21. a green (b) push and a failing (a) push in one command -> BLOCKED" 2
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push && git -C $PLAIN push"
expect_rc "C21b. a green (b) push and an unmanaged push -> allowed" 0
[ "$(grep -c 'WARNING' <<<"$ERR")" = 1 ] && ok "C21b. ...one warning, for the unmanaged one" || bad "C21b. warning count" "$ERR"

# ── downgrade attempts: none of these may end in a warning ──
run_hook "$PLUGIN" "$PLAIN" 'git -C /no/such/dir/anywhere push' FAKE_HSTATE_RC=2
strict_blocks "C22. a target path that does not exist, cwd unmanaged -> the strict gate on the cwd, BLOCKED" "$PLAIN"
run_hook "$PLUGIN" "$PLAIN" 'git -C "$DIR" push' FAKE_HSTATE_RC=2
strict_blocks "C22b. a target held in a variable -> strict on the cwd" "$PLAIN"
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push && git -C \"\$X\" push" FAKE_HSTATE_RC=2
expect_rc "C22c. a green (b) push plus a push that cannot be resolved -> BLOCKED by the strict gate on the cwd" 2
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push && git -C $B_GREEN pp" FAKE_HSTATE_RC=2
expect_rc "C22d. a git subcommand that is not a known built-in (an alias may be a push) -> the strict gate too" 2
run_hook "$PLUGIN" "$PLAIN" "git push \"never closed" FAKE_HSTATE_RC=2
expect_rc "C22e. a command with an unbalanced quote -> the strict gate" 2
run_hook "$PLUGIN" "$PLAIN" "git --git-dir=$SWEEP/.git --work-tree=$PLAIN push" FAKE_HSTATE_RC=2
strict_blocks "C23. DECOY work tree: --git-dir=<sweep>/.git --work-tree=<plain repo> -> the SWEEP repo is gated, in the sweep repo" "$SWEEP"
run_hook "$PLUGIN" "$PLAIN" "GIT_DIR=$SWEEP/.git GIT_WORK_TREE=$PLAIN git push" FAKE_HSTATE_RC=2
strict_blocks "C23b. DECOY work tree through GIT_DIR / GIT_WORK_TREE" "$SWEEP"
run_hook "$PLUGIN" "$PLAIN" "export GIT_DIR=$SWEEP/.git && git push" FAKE_HSTATE_RC=2
strict_blocks "C23c. an exported GIT_DIR" "$SWEEP"
run_hook "$PLUGIN" "$WT_SWEEP" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C24. cwd is a linked worktree of the sweep repo (heimdall's agent worktrees) -> the strict gate, in that worktree" "$WT_SWEEP"
run_hook "$PLUGIN" "$WT_SWEEP/test" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C24b. ...from a subdirectory of that worktree" "$WT_SWEEP"
run_hook "$PLUGIN" "$WT_BARE" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C24c. a worktree with nothing checked out (the marker is on no disk, git tracks it) -> the strict gate" "$WT_BARE"
run_hook "$PLUGIN" "$DANGLE" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C25. a marker that is a dangling symlink -> the strict gate, not a warning" "$DANGLE"
run_hook "$PLUGIN" "$DECLDIR" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C25b. a declaration that is a directory -> the strict gate" "$DECLDIR"
run_hook "$PLUGIN" "$W/link-sweep" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C26. a cwd that is a symlink to a sweep repo -> the sweep repo's strict gate" "$SWEEP"
run_hook "$PLUGIN" "$WT_PLAIN" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 0 ] && [ "$(grep -c 'WARNING' <<<"$ERR")" = 1 ] && [ "$(state_calls)" = 0 ]; } && ok "C27. ...while a worktree of an unmanaged repo (positively no markers) still only warns  [rc=0]" || bad "C27. worktree of an unmanaged repo" "rc=$RC calls=$(state_calls) $ERR"

# ── the class comes from the commits: what is on disk, uncommitted, cannot loosen or tighten the gate ──
run_hook "$PLUGIN" "$SW_DEL" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C30. the marker deleted on disk (uncommitted) -> still the sweep repo's strict gate" "$SW_DEL"
run_hook "$PLUGIN" "$PL_ADD" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 0 ] && [ "$(state_calls)" = 0 ] && [ "$(grep -c 'WARNING' <<<"$ERR")" = 1 ]; } && ok "C30b. markers added on disk and not committed do not make a repo managed: still only the warning  [rc=0]" || bad "C30b. uncommitted markers" "rc=$RC calls=$(state_calls) $ERR"
run_hook "$PLUGIN" "$SW_DROP" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C31. the pushed commit drops the marker but its upstream keeps it -> the strict gate" "$SW_DROP"
run_hook "$PLUGIN" "$RS" 'git push origin other' FAKE_HSTATE_RC=2
strict_blocks "C31b. pushing a branch that carries the marker from a HEAD that does not -> the strict gate" "$RS"

# ── the shell read exactly, or strict -- at the hook, where it decides a push ──
run_hook "$PLUGIN" "$PLAIN" "eval 'cd $B_RED'; git push"
expect_rc "C32. eval's cd carries on: the push after it goes to the red (b) repo and is BLOCKED by that record" 2
run_hook "$PLUGIN" "$PLAIN" "git push; bash <<< 'git -C $B_RED push'"
expect_rc "C32b. a push inside a here-string fed to a shell is graded on its target's record (the red (b) repo) -> BLOCKED" 2
run_hook "$PLUGIN" "$PLAIN" "git push; echo 'git -C $B_GREEN push' | sh" FAKE_HSTATE_RC=2
strict_blocks "C32c. a script piped into a shell cannot be seen -> the strict gate on the cwd, not the warning" "$PLAIN"
run_hook "$PLUGIN" "$PLAIN" "test -d $B_RED && cd $B_RED; git push"
expect_rc "C32d. a cd that may or may not happen: BOTH possible targets are gated -> BLOCKED by the red record" 2
run_hook "$PLUGIN" "$PLAIN" "test -d $B_GREEN && cd $B_GREEN; git push"
expect_rc "C32e. ...and when every possible target passes (a green record, an unmanaged cwd) the push goes on" 0
run_hook "$PLUGIN" "$PLAIN" 'cd -; git push' FAKE_HSTATE_RC=2
strict_blocks "C32f. cd - : OLDPWD is unknown -> the strict gate" "$PLAIN"
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push; source ./x.sh" FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_cwds | sed -n 1p)" = "$B_GREEN" ]; } && ok "C32g. an uncertain command makes the resolved (b) repo strict too: its green receipt alone does not pass it  [rc=2]" || bad "C32g. uncertain command left a resolved repo on its own class" "rc=$RC cwds=$(state_cwds | tr '\n' ' ') $OUT"

# ── the receipt attests ONE commit: a push that names another commit, or commits that cannot be listed, is not covered by it ──
run_checks "$SRC"; run_checks "$SRC_CFG"
for form in 'git push' 'git push origin main' 'git push origin HEAD' "git push origin $SRC_HEAD:main" 'git push origin :other' 'git push --delete origin other'; do
  run_hook "$PLUGIN" "$SRC" "$form" FAKE_HSTATE_RC=2
  expect_rc "C40. [$form] sends only the commit the receipt is for -> allowed" 0
done
for form in 'git push origin other' 'git push origin HEAD~1:main' "git push origin $SRC_PREV:main" "git push origin $SRC_BR other" 'git push origin v1' 'git push origin tag v1' 'git push; git push origin other'; do
  run_hook "$PLUGIN" "$SRC" "$form" FAKE_HSTATE_RC=2
  expect_rc "C41. [$form] names a commit the receipt is not for -> BLOCKED" 2
  denies "C41. ...says what the push carries" 'the push carries'
done
for form in 'git push --all' 'git push --tags' 'git push --mirror' "git push origin 'refs/heads/*:refs/heads/*'" 'git -c push.default=matching push'; do
  run_hook "$PLUGIN" "$SRC" "$form" FAKE_HSTATE_RC=2
  expect_rc "C42. [$form] names commits that cannot be listed -> BLOCKED" 2
  denies "C42. ...says they cannot be tied to the receipt" 'cannot be tied'
done
run_hook "$PLUGIN" "$SRC_CFG" 'git push' FAKE_HSTATE_RC=2
expect_rc "C42b. a configured remote.<name>.push picks the refs of a bare push -> BLOCKED" 2
run_hook "$PLUGIN" "$SRC_CFG" "git push origin $SRC_BR" FAKE_HSTATE_RC=2
expect_rc "C42c. ...while an explicit refspec overrides it -> allowed" 0
run_hook "$PLUGIN_REAL" "$SRC" 'git push origin nosuch'
expect_rc "C43. a refspec that names no commit is the strict class, and a repository with no sweep record cannot pass it (a gate never evaluated does not stand in)" 2
denies "C43. ...and the block says the push cannot be graded" 'cannot grade this push'
run_hook "$PLUGIN_REAL" "$B_GREEN" 'git push; source ./x.sh'
expect_rc "C43b. an uncertain command in a repo that declares checks is BLOCKED even with a green receipt (the strict gate was never evaluated)" 2
run_hook "$PLUGIN" "$B_GREEN" 'git push; source ./x.sh' FAKE_HSTATE_RC=0
expect_rc "C43b. ...and when the strict gate passes, the receipt row still blocks it: the commits cannot be listed" 2
denies "C43b. ...cannot be tied to the receipt" 'cannot be tied'
run_hook "$PLUGIN_REAL" "$PLAIN" 'git -C "$X" push'
expect_rc "C43c. an uncertain command in an unmanaged repo is not waved through as unmanaged: the strict gate was never evaluated, so BLOCKED" 2
denies "C43c. ...says it cannot grade the push" 'cannot grade this push'
run_hook "$PLUGIN_REAL" "$PLAIN" 'git push'
{ [ "$RC" = 0 ] && grep -q 'WARNING' <<<"$ERR"; } && ok "C43d. ...while the same push stated plainly is only the unmanaged warning  [rc=0]" || bad "C43d. plain push of an unmanaged repo" "rc=$RC $ERR"

# ── every error path is strict: a git that fails at any call the resolver makes never turns into the unmanaged warning or a pass ──
for spec in 'ls-tree' 'rev-parse:HEAD' 'rev-parse:--absolute-git-dir' 'symbolic-ref' 'for-each-ref' 'config'; do
  run_hook "$PLUGIN" "$ERRREPO" 'git push' "PATH=$BROKEN:$PLUGIN/bin:$PATH" FAKE_GIT_REAL="$REAL_GIT" FAKE_GIT_BREAK="$spec" FAKE_GIT_MODE=fail FAKE_HSTATE_RC=2
  strict_blocks "C44. git fails in [$spec]: the strict gate runs (and blocks here), never the unmanaged warning" "$ERRREPO"
done
run_hook "$PLUGIN" "$B_GREEN" 'git push' "PATH=$BROKEN:$PLUGIN/bin:$PATH" FAKE_GIT_REAL="$REAL_GIT" FAKE_GIT_BREAK=ls-tree FAKE_GIT_MODE=fail FAKE_HSTATE_RC=2
strict_blocks "C44b. git fails reading the markers of a repo whose green receipt would pass: the strict gate, not the receipt" "$B_GREEN"
run_hook "$PLUGIN_REAL" "$ERRREPO" 'git push' "PATH=$BROKEN:$PLUGIN_REAL/bin:$PATH" FAKE_GIT_REAL="$REAL_GIT" FAKE_GIT_BREAK=ls-tree FAKE_GIT_MODE=fail
expect_rc "C44c. git fails, and the strict gate is the REAL heimdall-state of a checkout that never armed it: BLOCKED, not 'UNAVAILABLE, allowing'" 2
denies "C44c. ...says it cannot grade the push" 'cannot grade this push'
B_CORRUPT="$(mk_checks bcorrupt "$GREEN_DECL")"; run_checks "$B_CORRUPT"
for bad_receipt in '' '{' '[]' 'null' '"x"' '0' '{"schema":1}'; do
  printf '%s' "$bad_receipt" > "$(receipt_of "$B_CORRUPT")"
  run_hook "$PLUGIN" "$B_CORRUPT" 'git push'
  expect_rc "C45. a receipt that is [$bad_receipt] -> BLOCKED" 2
done
N47=0
for bad_decl in 'not json' '[]' 'null' '{"schema":1,"checks":"x"}' '{"schema":1,"checks":[1]}' $'\xff\xfe' ''; do
  N47=$((N47 + 1)); BD47="$(mk_checks "c47decl$N47" "$bad_decl")"
  run_hook "$PLUGIN" "$BD47" 'git push'
  expect_rc "C47. a committed declaration that is [$(printf '%s' "$bad_decl" | head -c 24 | tr -c '[:print:]' '?')] -> BLOCKED" 2
done
PLUGIN_CRASH="$(mk_plugin crash)"; printf 'import sys\nsys.stderr.write("simulated crash\\n")\nsys.exit(3)\n' > "$PLUGIN_CRASH/bin/lib/hmd_push_target.py"
run_hook "$PLUGIN_CRASH" "$B_GREEN" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C48. the resolver crashes (exit 3, no answer): the strict gate on the cwd, not the repo's own record" "$B_GREEN"
PLUGIN_LIE="$(mk_plugin lie)"; printf 'import sys\nsys.stdout.write("allow\\t" + sys.argv[1] + "\\n")\n' > "$PLUGIN_LIE/bin/lib/hmd_push_target.py"
run_hook "$PLUGIN_LIE" "$B_GREEN" 'git push' FAKE_HSTATE_RC=2
strict_blocks "C48b. the resolver answers with a class nobody knows: the strict gate" "$B_GREEN"
PLUGIN_NOEXTRA="$(mk_plugin noextra)"; printf 'import sys\nsys.stdout.write("repo-checks\\t%s\\n")\n' "$B_GREEN" > "$PLUGIN_NOEXTRA/bin/lib/hmd_push_target.py"
run_hook "$PLUGIN_NOEXTRA" "$B_GREEN" 'git push' FAKE_HSTATE_RC=2
expect_rc "C48c. a repo-checks row without its list of pushed commits means 'cannot be listed': BLOCKED even though the receipt is green" 2
denies "C48c. ...cannot be tied to the receipt" 'cannot be tied'

# ── review round 2026-10-14, finding 1: a resolver that cannot answer is never a reason to grade ONE repository. The strict gate runs against EVERY
#    directory that may be the one pushed -- the session's cwd, the payload's cwd, each -C / cd target the parser had reached -- and blocks unless all pass ──
cwd_set() { state_cwds | LC_ALL=C sort | tr '\n' ' '; }
expect_set() {  # expect_set <label> <dir>...: the strict gate ran in exactly these directories, once each
  local label="$1" want got; shift
  want="$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ')"; got="$(cwd_set)"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "the gate ran in: $got | wanted: $want"; fi
}
TIMEOUT_ENV=("PATH=$BROKEN:$PLUGIN/bin:$PATH" "FAKE_GIT_REAL=$REAL_GIT" "FAKE_GIT_BREAK=rev-parse:--absolute-git-dir" "FAKE_GIT_MODE=hang" "HMD_PUSH_TARGET_TIMEOUT_S=0.3")
PAYLOAD_CWD="$PLAIN" run_hook "$PLUGIN" "$SWEEP" "git -C $CHK push" "${TIMEOUT_ENV[@]}"
expect_rc "C50. the resolver times out and every candidate repository passes the strict gate -> allowed" 0
expect_set "C50. ...the gate ran in the session cwd, the payload cwd AND the -C target (not in one of them)" "$SWEEP" "$PLAIN" "$CHK"
PAYLOAD_CWD="$PLAIN" run_hook "$PLUGIN" "$SWEEP" "git -C $CHK push" "${TIMEOUT_ENV[@]}" FAKE_HSTATE_FAIL_IN="$CHK"
expect_rc "C50b. the resolver times out and only the -C target's gate fails (the session's and the payload's repos pass) -> BLOCKED" 2
PAYLOAD_CWD="$PLAIN" run_hook "$PLUGIN" "$SWEEP" "cd $CHK && git push" "${TIMEOUT_ENV[@]}" FAKE_HSTATE_FAIL_IN="$CHK"
expect_rc "C50c. ...the same for a cd target" 2
PAYLOAD_CWD="$PLAIN" run_hook "$PLUGIN" "$SWEEP" "git -C $CHK push" "${TIMEOUT_ENV[@]}" FAKE_HSTATE_FAIL_IN="$PLAIN"
expect_rc "C50d. ...and when it is the payload cwd's gate that fails -> BLOCKED" 2
DOT="$W/dot"; mkdir -p "$DOT"
CFG_BARE="$DOT/cfg.git"
[ -n "$CFG_BARE" ] || { echo "FATAL: CFG_BARE path empty" >&2; exit 1; }
git init -q --bare "$CFG_BARE"
run_hook "$PLUGIN" "$PLAIN" "git --git-dir=$DOT/cfg.git --work-tree=$DOT push" FAKE_HSTATE_FAIL_IN="$DOT"
expect_rc "C51. a repository git names whose work tree cannot be confirmed from the other end (a dotfiles layout): every candidate directory is graded, a failing one BLOCKS although the cwd repo passes" 2
run_hook "$PLUGIN" "$PLAIN" "git --git-dir=$DOT/cfg.git --work-tree=$DOT push"
expect_rc "C51b. ...and when every candidate passes the strict gate the push goes on" 0
for P52 in "$PLUGIN_CRASH" "$PLUGIN_NORES"; do
  PAYLOAD_CWD="$PLAIN" run_hook "$P52" "$SWEEP" 'git push'
  expect_rc "C52. [$(basename "$P52")] a resolver that gives no answer: the session cwd and the payload cwd both pass -> allowed" 0
  expect_set "C52. [$(basename "$P52")] ...and BOTH were graded" "$SWEEP" "$PLAIN"
  PAYLOAD_CWD="$PLAIN" run_hook "$P52" "$SWEEP" 'git push' FAKE_HSTATE_FAIL_IN="$PLAIN"
  expect_rc "C52b. [$(basename "$P52")] the payload cwd's gate fails (the session cwd's passes) -> BLOCKED: the shell's repo is not skipped" 2
  PAYLOAD_CWD="$PLAIN" run_hook "$P52" "$SWEEP" 'git push' FAKE_HSTATE_FAIL_IN="$SWEEP"
  expect_rc "C52c. [$(basename "$P52")] the session cwd's gate fails (the payload cwd's passes) -> BLOCKED" 2
done
PLUGIN_ROWS="$(mk_plugin rows)"
printf 'import sys\nsys.stdout.write("sweep\\t/no/such/dir/anywhere\\t-\\t-\\n")\n' > "$PLUGIN_ROWS/bin/lib/hmd_push_target.py"
run_hook "$PLUGIN_ROWS" "$PLAIN" 'git push'
expect_rc "C53. a row for a directory the gate cannot enter is BLOCKED (it used to run the gate wherever the hook happened to be)" 2
denies "C53. ...and says it cannot be entered" 'cannot be entered'
printf 'import os, sys\nsys.stdout.write("sweep\\t/no/such/dir/anywhere\\tfallback\\t-\\nsweep\\t" + os.getcwd() + "\\tfallback\\t-\\n")\n' > "$PLUGIN_ROWS/bin/lib/hmd_push_target.py"
run_hook "$PLUGIN_ROWS" "$PLAIN" 'git push'
expect_rc "C53b. a CANDIDATE directory that does not exist cannot be pushed from: skipped, the others are still graded" 0
expect_set "C53b. ...the gate ran in the one that exists" "$PLAIN"

# ── finding 2: the pair the resolver resolved is the pair every stage reads ──
state_pair() { awk -F'\t' 'NR == 1 { print $3 "|" $4 }' "$MARKS/state.calls"; }    # GIT_DIR|GIT_WORK_TREE of the first gate call
run_hook "$PLUGIN" "$PLAIN" "git --git-dir=$SWEEP/.git --work-tree=$PLAIN push" FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_pair)" = "$SWEEP/.git|$SWEEP" ]; } && ok "C54. DECOY work tree: the gate is handed the RESOLVED pair (the sweep repo's git dir and its own work tree), never the decoy's" || bad "C54. the pair handed to the gate" "rc=$RC pair=$(state_pair)"
run_hook "$PLUGIN" "$WT_SWEEP" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_pair)" = "$(phys "$(git -C "$WT_SWEEP" rev-parse --absolute-git-dir)")|$WT_SWEEP" ]; } && ok "C55. a linked worktree: the gate is handed its own git directory (under .git/worktrees) and its own work tree" || bad "C55. linked worktree pair" "rc=$RC pair=$(state_pair)"
run_hook "$PLUGIN" "$SUPER/sub" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_cwds)" = "$SUPER/sub" ] && [ "$(state_pair)" = "$(phys "$(git -C "$SUPER/sub" rev-parse --absolute-git-dir)")|$SUPER/sub" ]; } && ok "C56. a submodule: the gate runs in the submodule with the git directory that lives in the superproject" || bad "C56. submodule pair" "rc=$RC cwd=$(state_cwds) pair=$(state_pair)"
run_hook "$PLUGIN" "$SWEEP/test" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_pair)" = "$SWEEP/.git|$SWEEP" ]; } && ok "C57. from a subdirectory the gate is handed the toplevel's pair" || bad "C57. subdirectory pair" "rc=$RC pair=$(state_pair)"
PLUGIN_SPY="$(mk_plugin spy --spy-runner)"; : > "$MARKS/runner.calls"
PAYLOAD_CWD="$SWEEP" run_hook "$PLUGIN_SPY" "$PLAIN" "cd $B_GREEN && git push" FAKE_HSTATE_RC=2
expect_rc "C58. the payload cwd (a sweep repo whose gate would fail) differs from the cd target (a green repo-checks repo) -> allowed on the target's own record" 0
[ "$(cat "$MARKS/runner.calls")" = "status --repo $B_GREEN --git-dir $B_GREEN/.git --pushes $(git -C "$B_GREEN" rev-parse HEAD)" ] && ok "C58. ...the receipt lookup was handed the SAME pair (--repo <work tree> --git-dir <git dir>) and nothing about the payload's repo" || bad "C58. the runner's arguments" "$(cat "$MARKS/runner.calls")"
run_hook "$PLUGIN" "$PLAIN" "GIT_COMMON_DIR=$CHK/.git git -C $PLAIN push origin main" FAKE_HSTATE_RC=2
strict_blocks "C58b. GIT_COMMON_DIR points the push at another repository's refs: the strict gate, not the unmanaged warning for the repo the gate read" "$PLAIN"
bash "$RC_BIN" status --repo "$PLAIN" --git-dir "$B_GREEN/.git" >"$W/o" 2>&1; rcx=$?
{ [ "$rcx" = 2 ] && grep -q 'do not belong to each other' "$W/o"; } && ok "C59. status --repo <repo A> --git-dir <repo B's>: refused, the two must name each other from both ends" || bad "C59. a mismatched pair" "rc=$rcx $(head -c 300 "$W/o")"
mkdir -p "$PLAIN/.heimdall/receipts"; cp "$(receipt_of "$B_GREEN")" "$PLAIN/.heimdall/receipts/repo-checks.json"
bash "$RC_BIN" status --repo "$PLAIN" --git-dir "$B_GREEN/.git" >"$W/o" 2>&1; rcx=$?
{ [ "$rcx" = 2 ] && ! grep -q 'GREEN -' "$W/o"; } && ok "C59b. a decoy work tree cannot host B's genuine receipt for B's git directory" || bad "C59b. decoy work tree hosting a receipt" "rc=$rcx $(head -c 300 "$W/o")"
rm -rf "$PLAIN/.heimdall"
bash "$RC_BIN" status --repo "$B_GREEN" --git-dir "$B_GREEN/.git" >"$W/o" 2>&1; rcx=$?
{ [ "$rcx" = 0 ] && grep -q 'GREEN' "$W/o"; } && ok "C59c. ...while the repository's own pair reads its receipt" || bad "C59c. the right pair" "rc=$rcx $(head -c 300 "$W/o")"

# ── finding 3 (self-audit): one commit throughout a status; a link is never followed, through the hook either ──
: > "$W/git.log"
env PATH="$BROKEN:$PATH" FAKE_GIT_REAL="$REAL_GIT" FAKE_GIT_BREAK=none FAKE_GIT_LOG="$W/git.log" bash "$RC_BIN" status --repo "$B_GREEN" >/dev/null 2>&1
{ [ "$(grep -c 'HEAD' "$W/git.log")" = 1 ] && grep -qE '^ls-tree -z [0-9a-f]{40} ' "$W/git.log"; } && ok "C60. status names HEAD ONCE and reads the tree and the declaration of THAT commit (a HEAD that moves between reads cannot mix two commits)" || bad "C60. HEAD is read more than once" "$(cat "$W/git.log")"
B_LINKED="$(mk_checks blinked "$GREEN_DECL")"; run_checks "$B_LINKED"
mv "$B_LINKED/.heimdall/receipts" "$W/blinked.elsewhere"; ln -s "$W/blinked.elsewhere" "$B_LINKED/.heimdall/receipts"
run_hook "$PLUGIN" "$B_LINKED" 'git push'
expect_rc "C61. the receipts directory is a symlink to a genuine green receipt elsewhere -> BLOCKED (a link is never followed)" 2
denies "C61. ...says it is a link" '(?i)link'

# ── no resolver: gated exactly as before ──
run_hook "$PLUGIN_NORES" "$PLAIN" 'git push' FAKE_HSTATE_RC=2
expect_rc "C28. resolver missing -> the old gate on the cwd (fails closed, not open)" 2
run_hook "$PLUGIN_NORES" "$PLAIN" 'git push'
expect_rc "C28b. resolver missing, old gate passes -> allowed" 0

# ── what is not a push is not gated ──
run_hook "$PLUGIN" "$PLAIN" 'ls -la' FAKE_HSTATE_RC=2
{ [ "$RC" = 0 ] && ! grep -q 'WARNING' <<<"$ERR" && [ "$(state_calls)" = 0 ]; } && ok "C29. a command that is not a push: no gate, no warning" || bad "C29. non-push command" "rc=$RC $ERR"

# ════════════════════════════════════════════════════════════════════════════
section "D. the security gates are not relaxed"
for target in "$PLAIN" "$B_GREEN" "$SWEEP"; do
  run_hook "$PLUGIN" "$target" 'git push' FAKE_SCAN_REQUIRE_RC=1
  { [ "$RC" = 2 ] && grep -q 'pre-push secret gate failed' <<<"$OUT"; } && ok "D1. a failing push-range secret scan still blocks (cwd $(basename "$target"))" || bad "D1. secret gate relaxed for $(basename "$target")" "rc=$RC $OUT"
done
run_hook "$PLUGIN" "$PLAIN" "git -C $B_GREEN push" FAKE_SCAN_REQUIRE_RC=1
expect_rc "D2. ...also when the target is another repo" 2

printf '\n  heimdall-push-gate-per-repo: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
