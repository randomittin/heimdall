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
#   (a) sweep        the repo carries heimdall's sweep regime (test/run-all.sh naming last-sweep.json)
#                    -> the old gate, unchanged, fail closed
#   (b) repo-checks  .heimdall/repo-checks.json declares the repo's own checks -> passes ONLY on a
#                    green, current, clean-tree receipt (.heimdall/receipts/repo-checks.json) bound to the
#                    commit, its tree and the declaration it was recorded for
#   (c) unmanaged    one WARNING line on stderr, exit 0 -- ONLY for a repository git resolved AND that positively carries none
#                    of heimdall's markers. Anything uncertain (a command it cannot read in full, a variable or missing target,
#                    a git option or subcommand it does not know -- an alias may be a push --, a GIT_* variable set in a way it
#                    does not model, a repository git cannot place, a marker that is present but unreadable or tracked yet missing
#                    from disk) is the strict class (a) on the repo resolved, else the cwd: never down to a warning.
# Secret / self-scan gates are not part of this rule and are not relaxed (section D proves it).
#
# Everything here runs in throwaway repos under one mktemp dir, removed on exit. The hook is the
# REAL bin/heimdall-precheck-bash with a fake plugin root around it (fake heimdall-state that
# records where and whether it was called, fake secret-scan); no real push is ever made.
#
#   A  bin/heimdall-repo-checks  run / status, receipt binding, forged and mismatched receipts
#   B  bin/lib/hmd_push_target.py  (the target resolver + classifier): classes, forms, fail-closed, git differential
#   C  the hook: each class, target != cwd, multi-target, downgrade attempts, forged receipts, resolver missing
#   D  security gates stay on
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC_BIN="$REPO/bin/heimdall-repo-checks"
HELPER="$REPO/bin/lib/hmd_push_target.py"
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
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false \
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
if python3 -I -S -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null; then
  ok "0c. bin/lib/hmd_push_target.py parses"
else
  bad "0c. bin/lib/hmd_push_target.py missing or does not parse"
fi
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
# A3c. ...and so does a check that rewrites its own declaration (here an untracked one, so only the declaration hash can tell)
A3C="$(new_repo a3c)"; mkdir -p "$A3C/.heimdall"
decl_json rewrites 'jq . .heimdall/repo-checks.json > .heimdall/tmp.json && cp .heimdall/tmp.json .heimdall/repo-checks.json' > "$A3C/.heimdall/repo-checks.json"
run_checks "$A3C"
jq -e '.dirty == true' "$(receipt_of "$A3C")" >/dev/null 2>&1 && ok "A3c. a check that rewrites the declaration it ran under leaves dirty:true" || bad "A3c. declaration rewritten by a check not recorded" "$(head -c 300 "$(receipt_of "$A3C")")"

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
# the declaration, byte for byte: the same checks reformatted are not the declaration the receipt was recorded for
jq . "$W/a4.decl" > "$A4/.heimdall/repo-checks.json"
status_of "$A4"; { [ "$STRC" = 1 ] && grep -qi 'declaration changed' <<<"$STOUT"; } && ok "A4. the same checks, reformatted -> NOT GREEN (the receipt is bound to the declaration's bytes)" || bad "A4. reformatted declaration accepted" "rc=$STRC $STOUT"
cp "$W/a4.decl" "$A4/.heimdall/repo-checks.json"
status_of "$A4"; [ "$STRC" = 0 ] && ok "A4. ...and the original bytes restored -> GREEN again" || bad "A4. restored declaration is not green" "$STOUT"
# a commit after the run stales it; an edited declaration voids it
printf 'v2\n' > "$A4/file.txt"; commit_all "$A4" "after the run"
status_of "$A4"; { [ "$STRC" = 1 ] && grep -qi 'stale' <<<"$STOUT"; } && ok "A4. a commit after the run -> STALE" || bad "A4. commit after run not stale" "rc=$STRC $STOUT"
run_checks "$A4"; status_of "$A4"; [ "$STRC" = 0 ] && ok "A4. re-run at the new HEAD -> GREEN again" || bad "A4. re-run did not turn green" "$STOUT"
cp "$(receipt_of "$A4")" "$W/a4.green"
jq '.checks[0].cmd = "true"' "$A4/.heimdall/repo-checks.json" > "$W/decl.edited" && cp "$W/decl.edited" "$A4/.heimdall/repo-checks.json"
status_of "$A4"; { [ "$STRC" = 1 ] && grep -qi 'declaration' <<<"$STOUT"; } && ok "A4. declaration edited after the run -> NOT GREEN (the receipt is for other checks)" || bad "A4. edited declaration not detected" "rc=$STRC $STOUT"

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
BARE="$W/bare.git"; git init -q --bare "$BARE"
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
  got="$(printf '%s' "$cmd" | env HOME="$HOMEDIR" $PLAN_ENV python3 -I -S "$HELPER" "$base" 2>"$W/plan.err"; printf x)"; got="${got%x}"
  if [ "$got" = "$want" ]; then ok "B. $label"; else bad "B. $label" "command: $cmd | want: $(printf '%s' "$want" | tr '\n\t' '|~') | got: $(printf '%s' "$got" | tr '\n\t' '|~') $(head -c 200 "$W/plan.err")"; fi
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
check_plan "a bare repository cannot be placed in a work tree -> strict"     "$PLAIN" "git -C $BARE push"            "sweep:$PLAIN"
check_plan "text that only mentions a push -> strict on the cwd"             "$PLAIN" 'echo "git push" > /dev/null'  "sweep:$PLAIN"
check_plan "a heredoc body is data, not a command -> nothing found -> strict" "$PLAIN" $'cat <<EOF\ngit -C '"$CHK"$' push\nEOF'  "sweep:$PLAIN"
check_plan "empty command -> strict on the cwd"                              "$PLAIN" ''                             "sweep:$PLAIN"
check_plan "an unreadable rest of the command adds the strict gate on the cwd" "$PLAIN" "git -C $CHK push \"never closed" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "a resolved target plus an unresolvable one: both gated"          "$PLAIN" "git -C $CHK push && git -C \"\$X\" push" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "an unknown git subcommand may be an alias of a push"             "$PLAIN" "git -C $CHK push && git -C $CHK pp" "repo-checks:$CHK" "sweep:$PLAIN"
check_plan "an alias alone: no push is seen -> strict"                       "$PLAIN" "git -c alias.pp=push -C $CHK pp" "sweep:$PLAIN"
check_plan "a git option this does not know"                                 "$PLAIN" 'git --frobnicate push'        "sweep:$PLAIN"
check_plan "a command name held in a variable"                               "$PLAIN" '$GIT push'                    "sweep:$PLAIN"
check_plan "...also quoted, with an argument for the push"                   "$PLAIN" "\"\$GIT\" -C $CHK push"       "sweep:$PLAIN"
check_plan "env -C <dir> runs git elsewhere: not followed -> strict"         "$PLAIN" "env -C $CHK git push"         "sweep:$PLAIN"
check_plan "a sourced script may cd or export anything"                      "$PLAIN" 'source ./env.sh && git push'  "unmanaged:$PLAIN" "sweep:$PLAIN"
check_plan "a bare GIT_DIR= assignment may update an exported variable"      "$PLAIN" "GIT_DIR=$SWEEP/.git; git push" "unmanaged:$PLAIN" "sweep:$PLAIN"
check_plan "re-exporting GIT_DIR without a value is not modelled"            "$PLAIN" 'export GIT_DIR; git push'     "unmanaged:$PLAIN" "sweep:$PLAIN"
check_plan "declare/local/readonly of a GIT_* name is not modelled"          "$PLAIN" "declare GIT_DIR=$SWEEP/.git; git push" "unmanaged:$PLAIN" "sweep:$PLAIN"
PLAN_ENV="CDPATH=$W/repos"
check_plan "a relative cd with CDPATH set may land elsewhere -> strict"      "$PLAIN" 'cd chk && git push'           "sweep:$PLAIN"
check_plan "...but ./<dir> is not searched through CDPATH"                   "$W/repos" 'cd ./chk && git push'       "repo-checks:$CHK"
PLAN_ENV=""
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
  cp "$HELPER" "$d/bin/lib/hmd_push_target.py" 2>/dev/null
  for opt in "$@"; do
    case "$opt" in
      --no-resolver) rm -f "$d/bin/lib/hmd_push_target.py" ;;
      --real-state)  cp "$REPO/bin/heimdall-state" "$d/bin/heimdall-state" ;;
    esac
  done
  if [ ! -e "$d/bin/heimdall-state" ]; then
    cat > "$d/bin/heimdall-state" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$MARKS/state.calls"
if [ "\${FAKE_HSTATE_RC:-0}" = 0 ]; then echo "All quality gates pass."; else echo "GATE FAILED: fake sweep gate" >&2; fi
exit "\${FAKE_HSTATE_RC:-0}"
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
expect_rc "C13. (b) declaration edited after the receipt -> BLOCKED" 2

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
