#!/usr/bin/env bash
# shellcheck disable=SC2016  # the payloads fed to the hook are literal text: $VAR, $(...) and backticks must NOT expand here
# test/sweep-advice.test.sh
#
# MERGE-TIME ADVICE. Operator directive 2026-11-12: "full test runs should be recommended to devs along with explanation and token usage -- plus should always be
# suggested just before merge operations and not before." bin/heimdall-precheck-bash now asks bin/lib/hmd_sweep_advice.py, for a command that mentions merge, push
# or pull (and git or gh), whether the command IS a merge -- a merge of a ref, a pull request merge, a pull on the default branch, a push to it -- and if so SAYS what
# a full test run would buy: why (what changed since the last green full record), what to run, what it costs (suites, wall clock, tokens, labelled estimates), and that
# it is the developer's call. It never blocks, never speaks at any other moment, and fails open. This drives the REAL helper and hook against fixture repos and receipts
# (a throwaway plugin root: the real hook and libs, a tracker that says nothing unless told to, gates that pass) and pins:
#   * the forms that ARE a merge: advice with all four parts (Why, Run, Cost, Your call) as hook JSON -- systemMessage for the developer, hookSpecificOutput.additionalContext
#     for the agent -- and never a permissionDecision; behind wrappers, chains, cd, -C, sh -c; and the forms that are NOT (text that only mentions one, an abort, merge-base,
#     a push to another branch, a rebasing pull, a pull request merge for another repo): nothing at all
#   * the records: HEAD proven green says so and recommends nothing; a red record, no record, a dirty or incremental one, a foreign one, a sweep already running; a repo that
#     declares its own checks gets its own command and its own receipt; a repo with neither gets lint plus the use-case suite
#   * the cost, with its arithmetic, and every token figure labelled an estimate
#   * HMD_SWEEP_ADVICE=off (read from the hook's own environment) and `hmd guardrails off sweep-advice` silence it; any doubt keeps it on
#   * it FAILS OPEN: a helper that crashes, lies or is missing, a command or a record it cannot read, a timeout: one stderr line at most and the command goes on
#   * the pre-filter, the place in the chain (a command a gate denies prints only the deny), the tracker's output never corrupting the JSON, the shipped root, the manifest
# The advice is a COST/DISCIPLINE nudge and BEST EFFORT, not a security boundary: no text guard on shell is complete.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precheck-bash"
HELPER="$REPO/bin/lib/hmd_sweep_advice.py"
MANIFEST="$REPO/guardrails.manifest.json"
LIBS=(hmd_sweep_advice.py hmd_sweep_guard.py hmd_kill_guard.py hmd_push_target.py hmd_repo_receipt.py hmd_repo_checks.py hook-owned-path.sh hmd_guardrail_enabled.sh hmd_wait_guard.py hmd_ci_guard.py)
PASS=0
FAIL=0
N=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# what the operator exports in their own shell never changes a case; a case that needs a setting passes it
unset HEIMDALL_HOME HMD_SWEEP_ADVICE HMD_SWEEP_ADVICE_TIMEOUT_S HMD_GUARDRAILS_MANIFEST HMD_SWEEP_ALLOW HMD_CI_RERUN_ALLOW HMD_WAIT_ALLOW HMD_KILL_GUARD HMD_COLD \
  GH_REPO GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE TRACKER_SAYS ADVICE_STUB_MARK STUB_RC

TMPROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPROOT"; [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null' EXIT

echo "sweep-advice"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { bad "0. git is required"; exit 1; }
[ -f "$HOOK" ] || { bad "0. bin/heimdall-precheck-bash is missing"; exit 1; }
if [ -f "$HELPER" ] && python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null; then ok "0. bin/lib/hmd_sweep_advice.py exists and parses"; else bad "0. bin/lib/hmd_sweep_advice.py is missing or does not parse"; fi
if bash -n "$HOOK" 2>/dev/null; then ok "0. bin/heimdall-precheck-bash parses"; else bad "0. bin/heimdall-precheck-bash does not parse"; fi

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4s a call, and this suite starts python for most of its cases
PYREAL="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$TMPROOT/pybin" "$TMPROOT/home"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then ln -s "$PYREAL" "$TMPROOT/pybin/python3"; fi
export PATH="$TMPROOT/pybin:$PATH"

# ── throwaway plugin roots: the REAL hook and libs, a tracker that says nothing unless TRACKER_SAYS, and the gates a push meets, all passing ─────────────────────────
mkroot() {  # mkroot <dir> [python source of a stub helper]
  local d="$1" f
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  for f in "${LIBS[@]}"; do cp "$REPO/bin/lib/$f" "$d/bin/lib/$f" 2>/dev/null; done
  cp "$REPO/bin/heimdall-repo-checks" "$d/bin/heimdall-repo-checks" 2>/dev/null
  cp "$MANIFEST" "$d/guardrails.manifest.json"
  printf '#!/bin/sh\n[ -n "${TRACKER_SAYS:-}" ] || exit 0\necho "$TRACKER_SAYS"\necho "$TRACKER_SAYS" >&2\nexit 0\n' >"$d/bin/parallelism-tracker"
  printf '#!/bin/sh\necho "all quality gates pass"\nexit 0\n' >"$d/bin/heimdall-state"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/secret-scan"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/heimdall-selfscan"
  chmod +x "$d/bin/heimdall-precheck-bash" "$d/bin/parallelism-tracker" "$d/bin/heimdall-state" "$d/bin/secret-scan" "$d/bin/heimdall-selfscan" "$d/bin/heimdall-repo-checks" 2>/dev/null
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" >"$d/bin/lib/hmd_sweep_advice.py"; fi
}
PLUGIN="$TMPROOT/plugin"; mkroot "$PLUGIN"
MARK="$TMPROOT/helper.ran"
STUB_OK="$TMPROOT/plugin-stub-ok";           mkroot "$STUB_OK" 'import os
open(os.environ["ADVICE_STUB_MARK"], "a").write("ran\n")
print("ok")'
STUB_ADVICE="$TMPROOT/plugin-stub-advice";   mkroot "$STUB_ADVICE" 'import json, os, sys
open(os.environ["ADVICE_STUB_MARK"], "a").write("ran\n")
sys.stdout.write(json.dumps({"systemMessage": "stub says \"hi\" \\ there %s", "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "stub context"}}) + "\n")
sys.exit(3)'
STUB_CRASH="$TMPROOT/plugin-stub-crash";     mkroot "$STUB_CRASH" 'import sys
sys.exit(1)'
STUB_SILENT="$TMPROOT/plugin-stub-silent";   mkroot "$STUB_SILENT" 'import sys
sys.exit(0)'
STUB_GARBAGE="$TMPROOT/plugin-stub-garbage"; mkroot "$STUB_GARBAGE" 'import sys
sys.stdout.write("not ok\n")
sys.exit(7)'
STUB_UNREAD="$TMPROOT/plugin-stub-unread";   mkroot "$STUB_UNREAD" 'import sys
sys.stdout.write("an odd command the stub could not read\n")
sys.exit(4)'
NOHELPER="$TMPROOT/plugin-nohelper";         mkroot "$NOHELPER"; rm -f "$NOHELPER/bin/lib/hmd_sweep_advice.py"
NOGUARD="$TMPROOT/plugin-noguard";           mkroot "$NOGUARD"; rm -f "$NOGUARD/bin/lib/hmd_sweep_guard.py"
NOLIB="$TMPROOT/plugin-nolib";               mkroot "$NOLIB"; rm -f "$NOLIB/bin/lib/hmd_guardrail_enabled.sh"
CORED="$TMPROOT/plugin-cored";               mkroot "$CORED"; jq '(.guardrails[] | select(.id == "sweep-advice") | .tier) = "core"' "$MANIFEST" >"$CORED/guardrails.manifest.json" 2>/dev/null
LIBSTUB="$TMPROOT/plugin-libstub";           mkroot "$LIBSTUB" 'import os
open(os.environ["ADVICE_STUB_MARK"], "a").write("ran\n")
print("ok")'
printf 'hmd_guardrail_enabled() { return "${STUB_RC:-0}"; }\n' >"$LIBSTUB/bin/lib/hmd_guardrail_enabled.sh"

# ── fixture repos ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
git_q() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mkrepo() { mkdir -p "$1" && git init -q "$1" 2>/dev/null && git -C "$1" symbolic-ref HEAD refs/heads/main; }
commit() {  # commit <repo> <message>: everything the fixture changed, as one commit; prints nothing
  git -C "$1" add -A && git_q -C "$1" commit -q -m "$2"
}
SW="$TMPROOT/sw"   # heimdall's own regime: test/run-all.sh names last-sweep.json. main: C1 base -> C2 code -> C3 journal (a hook record); feature: C3 + F1; other: C1 + S
mkrepo "$SW" && mkdir -p "$SW/test"
printf '#!/bin/sh\nRECEIPT_FILE="$RECEIPT_DIR/last-sweep.json"\nexit 0\n' >"$SW/test/run-all.sh"; printf 'one\n' >"$SW/a.txt"
printf '#!/bin/sh\nexit 0\n' >"$SW/test/a.test.sh"; printf '#!/bin/sh\nexit 0\n' >"$SW/test/b.test.sh"
commit "$SW" "C1 base";   C1="$(git -C "$SW" rev-parse HEAD)"
printf 'two\n' >"$SW/a.txt"; commit "$SW" "C2 code"; C2="$(git -C "$SW" rev-parse HEAD)"
mkdir -p "$SW/.planning/journal"; printf 'entry\n' >"$SW/.planning/journal/2026-10-21-haid_t.md"; commit "$SW" "C3 journal"; C3="$(git -C "$SW" rev-parse HEAD)"
git -C "$SW" branch proven "$C3"
git -C "$SW" checkout -q -b feature && printf 'feat\n' >"$SW/f.txt" && commit "$SW" "F1 feature"; F1="$(git -C "$SW" rev-parse HEAD)"
git -C "$SW" checkout -q main
git -C "$SW" checkout -q -b other "$C1" && printf 'side\n' >"$SW/s.txt" && commit "$SW" "S side"; CS="$(git -C "$SW" rev-parse HEAD)"
git -C "$SW" checkout -q main
SWTOP="$(git -C "$SW" rev-parse --show-toplevel)"
SWH="$SW/.heimdall"
[ "$(git -C "$SW" rev-parse HEAD)" = "$C3" ] && ok "0. fixture: main is at C3 (C1, C2 ancestors; feature = C3 + F1; other = C1 + S)" || bad "0. fixture repo is not as built"

RC="$TMPROOT/rc"   # a repo that declares its own checks
mkrepo "$RC" && mkdir -p "$RC/.heimdall"
printf '{"schema":1,"checks":[{"name":"lint","cmd":"true"},{"name":"use-cases","cmd":"true"}]}\n' >"$RC/.heimdall/repo-checks.json"; printf 'one\n' >"$RC/a.txt"
printf '.heimdall/receipts/\n' >"$RC/.gitignore"
commit "$RC" "R1"; R1="$(git -C "$RC" rev-parse HEAD)"
RCTOP="$(git -C "$RC" rev-parse --show-toplevel)"

UN="$TMPROOT/un"   # nothing hmd manages; its default branch is trunk, as origin/HEAD says
mkrepo "$UN" && printf 'one\n' >"$UN/a.txt" && commit "$UN" "U1"; U1="$(git -C "$UN" rev-parse HEAD)"
git -C "$UN" branch trunk "$U1" && git -C "$UN" update-ref refs/remotes/origin/trunk "$U1" && git -C "$UN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
NOGIT="$TMPROOT/nogit"; mkdir -p "$NOGIT"

receipt() {  # receipt <home dir> <head_sha> <exit_code> <kind> <tree_clean> [extra json object]: a sweep receipt for the SW fixture, with the numbers the cost line reads
  local home="$1" extra="${6:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$home/receipts"
  jq -n --arg repo "$SWTOP" --arg sha "$2" --argjson rc "$3" --arg kind "$4" --argjson clean "$5" --argjson extra "$extra" \
    '{finished_at: "2026-11-12T13:20:31Z", repo: $repo, head_sha: $sha, tree_clean: $clean, exit_code: $rc, kind: $kind, suites_total: 568, suites_passed: 568, duration_s: 2873} + $extra' >"$home/receipts/last-sweep.json"
}
sleep 300 &
SLEEPER=$!
true & DEAD=$!; wait "$DEAD" 2>/dev/null

# ── runners ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
HRC=0; HOUT=""; HERR=""
hv() {  # hv <command> [cwd] [VAR=val ...] -> HRC (the helper's exit status), HOUT (its stdout), HERR (its stderr): the helper alone, 60 ms a case
  local cmd="$1" cwd="${2:-$SW}"
  shift; [ $# -gt 0 ] && shift
  HOUT="$(env -u HEIMDALL_HOME -u HMD_SWEEP_ADVICE_TIMEOUT_S HOME="$TMPROOT/home" "$@" python3 -I -S "$HELPER" "$cwd" <<<"$cmd" 2>"$TMPROOT/h.err")"
  HRC=$?
  HERR="$(cat "$TMPROOT/h.err")"
}
RC_=0
run_hook() {  # run_hook <command> <plugin root> [VAR=val ...] -> RC_, $TMPROOT/out (stdout), $TMPROOT/err (stderr); the payload's cwd is $HOOK_CWD, default the SW fixture
  local cmd="$1" root="$2"
  shift 2
  printf '%s' "$cmd" >"$TMPROOT/cmd.txt"
  jq -nc --rawfile c "$TMPROOT/cmd.txt" --arg cwd "${HOOK_CWD:-$SW}" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $c}}' \
    | ( cd "${HOOK_CWD:-$SW}" && env HOME="$TMPROOT/home" HMD_MIN_FREE_PCT=0 CLAUDE_PLUGIN_ROOT="$root" ADVICE_STUB_MARK="$MARK" "$@" bash "$root/bin/heimdall-precheck-bash" ) \
      >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC_=$?
}

# the shape every piece of advice has: one line of hook JSON with the developer's message, the agent's context, no decision, and the four parts
advice_ok() {  # advice_ok <stdout text> <fragment both messages must hold>
  [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$1" | jq -e --arg f "$2" '
    type == "object" and (keys | sort) == ["hookSpecificOutput", "systemMessage"]
    and (.systemMessage | type == "string") and (.hookSpecificOutput.hookEventName == "PreToolUse")
    and (.hookSpecificOutput.additionalContext | type == "string") and (.hookSpecificOutput | has("permissionDecision") | not)
    and (.systemMessage | test("(^|\n)Why: ") and test("(^|\n)Run: ") and test("(^|\n)Cost: ") and test("(^|\n)Your call: "))
    and (.systemMessage | contains($f)) and (.hookSpecificOutput.additionalContext | contains($f))' >/dev/null 2>&1
}
proven_ok() {  # proven_ok <stdout text> <fragment>: one line of hook JSON that says HEAD is already proven green, that there is nothing to run, and recommends nothing
  [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$1" | jq -e --arg f "$2" '
    type == "object" and (.hookSpecificOutput.hookEventName == "PreToolUse") and (.hookSpecificOutput | has("permissionDecision") | not)
    and (.systemMessage | contains("already proven green") and contains("nothing to run") and contains($f) and (test("(^|\n)Run: ") | not))
    and (.hookSpecificOutput.additionalContext | contains("already proven green"))' >/dev/null 2>&1
}
msg() { printf '%s\n' "$HOUT" | jq -r '.systemMessage // empty' 2>/dev/null; }

advises() {  # advises <label> <fragment> <command> [cwd] [VAR=val ...]: the helper says exit 3 and advice with all four parts
  N=$((N + 1))
  local label="$1" frag="$2" cmd="$3"; shift 3
  hv "$cmd" "$@"
  if [ "$HRC" = 3 ] && advice_ok "$HOUT" "$frag" && [ -z "$HERR" ]; then ok "$N. advice: $label"; else bad "$N. NO advice: $label" "rc=$HRC out=$(printf '%s' "$HOUT" | head -c 260) err=$HERR"; fi
}
proves() {  # proves <label> <fragment> <command> [cwd] [VAR=val ...]: exit 3 and "already proven green; nothing to run"
  N=$((N + 1))
  local label="$1" frag="$2" cmd="$3"; shift 3
  hv "$cmd" "$@"
  if [ "$HRC" = 3 ] && proven_ok "$HOUT" "$frag" && [ -z "$HERR" ]; then ok "$N. proven: $label"; else bad "$N. not 'already proven': $label" "rc=$HRC out=$(printf '%s' "$HOUT" | head -c 260) err=$HERR"; fi
}
silent() {  # silent <label> <command> [cwd] [VAR=val ...]: exit 0 and `ok`, nothing on stderr
  N=$((N + 1))
  local label="$1" cmd="$2"; shift 2
  hv "$cmd" "$@"
  if [ "$HRC" = 0 ] && [ "$HOUT" = ok ] && [ -z "$HERR" ]; then ok "$N. silent: $label"; else bad "$N. wrongly advised: $label" "rc=$HRC out=$(printf '%s' "$HOUT" | head -c 260) err=$HERR"; fi
}
unread() {  # unread <label> <fragment of the reason> <command> [cwd] [VAR=val ...]: exit 4 and ONE reason line
  N=$((N + 1))
  local label="$1" frag="$2" cmd="$3"; shift 3
  hv "$cmd" "$@"
  if [ "$HRC" = 4 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$HOUT" | grep -qF -- "$frag" && [ -z "$HERR" ]; then ok "$N. could not tell: $label"; else bad "$N. not 'could not tell': $label" "rc=$HRC out=$HOUT err=$HERR"; fi
}
group_advises() {  # group_advises <label> <fragment> [cwd]; one command per line on stdin; every one must be advice holding the fragment
  local form bad_forms="" n=0
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    n=$((n + 1)); hv "$form" "${3:-$SW}"
    { [ "$HRC" = 3 ] && advice_ok "$HOUT" "$2" && [ -z "$HERR" ]; } || bad_forms="$bad_forms [$form: rc=$HRC $(printf '%s' "$HOUT" | head -c 80) $HERR]"
  done
  N=$((N + 1))
  if [ -z "$bad_forms" ] && [ "$n" -gt 0 ]; then ok "$N. advice, all $n forms: $1"; else bad "$N. forms with NO advice: $1" "${bad_forms:-no forms}"; fi
}
group_silent() {  # group_silent <label> [cwd]; one command per line on stdin; every one must be exit 0 and `ok`, nothing on stderr
  local form bad_forms="" n=0
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    n=$((n + 1)); hv "$form" "${2:-$SW}"
    { [ "$HRC" = 0 ] && [ "$HOUT" = ok ] && [ -z "$HERR" ]; } || bad_forms="$bad_forms [$form: rc=$HRC $(printf '%s' "$HOUT" | head -c 80) $HERR]"
  done
  N=$((N + 1))
  if [ -z "$bad_forms" ] && [ "$n" -gt 0 ]; then ok "$N. silent, all $n forms: $1"; else bad "$N. forms wrongly advised: $1" "${bad_forms:-no forms}"; fi
}

echo "-- 1. the helper's protocol: exit 3 + ONE line of hook JSON, exit 0 + ok, exit 4 + a reason --"
receipt "$SWH" "$C1" 0 full true
hv 'git merge feature'
if [ "$HRC" = 3 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$HOUT" | jq -e 'type == "object"' >/dev/null 2>&1; then ok "a merge: exit 3 and ONE line of JSON"; else bad "helper, merge: rc=$HRC out=$HOUT err=$HERR"; fi
hv 'git status && ls'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ] && [ -z "$HERR" ]; then ok "an ordinary command: exit 0 and 'ok'"; else bad "helper, ordinary: rc=$HRC out=$HOUT"; fi
hv 'echo "git merge feature'
if [ "$HRC" = 4 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$HOUT" | grep -q 'unbalanced quote'; then ok "an unbalanced quote: exit 4 and the reason it could not be read"; else bad "helper, unbalanced: rc=$HRC out=$HOUT"; fi

echo "-- 2. ADVICE: every way of typing a merge, with the records of the heimdall regime (last green full sweep at C1, so C2 and F1 are not covered) --"
FRAG_SW="since the last green full sweep (${C1:0:12}"
group_advises "a merge of a ref, with the options that take a value and the ones that do not" "$FRAG_SW" <<'EOF'
git merge feature
git merge --no-ff feature
git merge -m "land the feature" feature
git merge --squash feature
git merge --no-commit feature
git merge -s ours feature
git merge -X theirs feature
git merge feature other
git merge origin/feature
git merge
git merge --ff-only feature
git merge --no-edit feature
EOF
group_advises "behind git's global options, wrappers, chains, subshells, shells and eval" "$FRAG_SW" <<'EOF'
git -c user.name=x merge feature
git --no-pager merge feature
env FOO=1 git merge feature
FOO=1 git merge feature
time git merge feature
nohup git merge feature &
command git merge feature
sudo -u bob git merge feature
git status && git merge feature
git fetch; git merge feature
false || git merge feature
(git merge feature)
{ git merge feature; }
if true; then git merge feature; fi
x=$(git merge feature)
sh -c "git merge feature"
bash -lc 'git merge feature'
eval "git merge feature"
echo go | xargs git merge feature
git merge feature 2>&1 | tail -3
EOF
hv $'echo start\ngit merge feature'
if [ "$HRC" = 3 ]; then ok "after a newline"; else bad "after a newline: rc=$HRC $HOUT"; fi
hv $'git \\\n  merge \\\n  feature'
if [ "$HRC" = 3 ]; then ok "a continued line"; else bad "continued line: rc=$HRC $HOUT"; fi
hv $'bash <<EOF\ngit merge feature\nEOF'
if [ "$HRC" = 3 ]; then ok "a heredoc fed to a shell"; else bad "heredoc fed to a shell: rc=$HRC $HOUT"; fi
group_advises "pull request merges" "$FRAG_SW" <<'EOF'
gh pr merge 12
gh pr merge 12 --squash --delete-branch
gh pr merge --auto --squash
gh pr merge https://github.com/o/r/pull/12 --merge
gh --no-pager pr merge 12
gh pr merge 12 -t "subject" -b "body"
EOF
group_advises "a push whose target is the default branch (main, master, or what origin/HEAD names), however it is spelled" "$FRAG_SW" <<'EOF'
git push origin main
git push
git push origin
git push -u origin main
git push --force-with-lease origin main
git push -o ci.skip origin main
git push origin HEAD:main
git push origin main:main
git push origin refs/heads/main
git push origin HEAD
git push origin +main
git push origin feature:main
git push origin feature:refs/heads/main
git push origin other main
git push --all
git push --mirror origin
git push --tags origin main
git push origin HEAD:master
git -C . push origin main
EOF
group_advises "a pull on the default branch (a merge into it, never a rebase)" "$FRAG_SW" <<'EOF'
git pull
git pull origin main
git pull origin
git pull --no-rebase
git pull --ff-only
git pull --rebase=false
git pull -s ours origin main
EOF
group_advises "the repo comes from -C, cd, a subshell: not the cwd" "$FRAG_SW" "$TMPROOT" <<EOF
git -C $SW merge feature
git -C $SW push origin main
cd $SW && git merge feature
cd "$SW"; gh pr merge 12
cd $SW/test && git merge feature
cd $SW && cd test && git push
bash -c "cd $SW && git merge feature"
EOF
N=$((N + 1)); hv 'git push origin trunk' "$UN"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'no green record yet'; then ok "$N. the default branch is what origin/HEAD names (trunk), not only main and master"; else bad "$N. trunk push: rc=$HRC $HOUT $HERR"; fi

echo "-- 3. SILENT: text that only mentions a merge, what is no merge, and the forms that go elsewhere (every one: exit 0, ok, nothing on stderr) --"
group_silent "text that only mentions a merge (echo, printf, grep, cat, a commit message, a script written to disk)" <<'EOF'
echo "git merge feature"
echo git push origin main
printf '%s\n' "run gh pr merge 12 when done"
grep -rn "git push" docs/
grep -n "merge" CLAUDE.md
cat docs/merge-notes.md
sed -n '1,5p' docs/pull.md
git commit -m "merge fix"
git commit -m "git push origin main now"
git log --oneline --grep "merge"
git add notes/merge.md
vim notes/push.md
echo "$(echo git pull)"
EOF
hv $'cat > go.sh <<\'EOF\'\ngit merge feature\nEOF'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ]; then ok "a script that holds a merge written to disk (data fed to cat, not to a shell)"; else bad "script written to disk: rc=$HRC $HOUT"; fi
hv $'git commit -m "$(cat <<\'EOF\'\nland: merge the feature\nEOF\n)"'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ]; then ok "a heredoc commit message that mentions a merge"; else bad "heredoc commit message: rc=$HRC $HOUT"; fi
group_silent "git commands that are not a merge or push, even when the word is in them" <<'EOF'
git status
git merge --abort
git merge --continue
git merge --quit
git merge --help
git merge -h
git merge-base HEAD main
git merge-tree HEAD main
git merge-file a b c
git mergetool
git log --merges --oneline
git diff main...feature
git branch --merged
git stash push -m "wip"
git fetch origin
git checkout feature
git rebase main
git cherry-pick F1
git remote -v
EOF
group_silent "a push that is not to the default branch, or sends no branch" <<'EOF'
git push origin feature
git push origin feature:feature
git push origin HEAD:release
git push origin :old
git push --delete origin old
git push -d origin old
git push --tags
git push origin v1.2.3
git push origin tag v1.2.3
git push --dry-run origin feature
EOF
group_silent "a pull that rebases, or that merges into a branch that is not the default" <<'EOF'
git pull --rebase
git pull -r
git pull --rebase=true
git pull --rebase=merges origin main
EOF
group_silent "gh commands that are not a merge, a merge help page, and a merge for ANOTHER repository (these records are not that repo's)" <<'EOF'
gh pr view 12
gh pr list --state merged
gh pr create --title x --body y
gh pr merge --help
gh pr merge -h
gh pr merge 12 -R owner/repo
gh pr merge 12 --repo owner/repo
GH_REPO=o/r gh pr merge 12
gh release view v1
EOF
group_silent "other commands that carry the word pull, push or merge" <<'EOF'
npm run pull-translations
docker pull alpine:3
make merge
ls
echo done
EOF
git -C "$SW" checkout -q feature
group_silent "a bare push and a pull on a branch that is not the default" <<'EOF'
git push
git push origin
git push -u origin
git pull
git pull origin main
git pull --no-rebase
EOF
N=$((N + 1)); hv 'git merge main'
if [ "$HRC" = 3 ]; then ok "$N. (control) a merge is a merge whichever branch it is typed on"; else bad "$N. merge on a feature branch: rc=$HRC $HOUT"; fi
git -C "$SW" checkout -q main

echo "-- 4. the records: HEAD proven green says so, recommends nothing, and is exact about WHAT is proven --"
receipt "$SWH" "$C3" 0 full true
proves "a push to main at a HEAD the last full sweep covers" "${C3:0:12}" 'git push origin main'
receipt "$SWH" "$C2" 0 full true
proves "only the hooks' own journal commit came after the sweep (the push gate counts that fresh too)" "${C3:0:12}" 'git push origin main'
proves "a merge of a branch that IS the proven commit (nothing new comes in)" "proven" 'git merge proven'
advises "a merge whose INCOMING branch the sweep has not seen, although HEAD is proven" "feature" 'git merge feature'
proves "a pull request merge at a proven HEAD" "${C3:0:12}" 'gh pr merge 12'
proves "a pull at a proven HEAD with no upstream to bring anything" "${C3:0:12}" 'git pull'
git -C "$SW" update-ref refs/remotes/origin/main "$F1"
git -C "$SW" config remote.origin.url "$SW"; git -C "$SW" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'   # an upstream needs a remote whose fetch refspec stores it
git -C "$SW" config branch.main.remote origin; git -C "$SW" config branch.main.merge refs/heads/main
advises "a pull whose upstream (origin/main) is ahead and unproven, at a proven HEAD" "origin/main" 'git pull'
git -C "$SW" update-ref -d refs/remotes/origin/main; git -C "$SW" config --remove-section remote.origin; git -C "$SW" config --remove-section branch.main
receipt "$SWH" "$C1" 0 full true
advises "an OLDER green sweep with a real code commit since: the counts say how much" "2 commits and 1 file changed since the last green full sweep (${C1:0:12}" 'git push origin main'
advises "the sweep's own number of files does not count the hooks' journal record" "1 file changed" 'git merge proven'
receipt "$SWH" "$C3" 0 full false
advises "a green receipt that recorded a DIRTY tree proves nothing" "no green record yet" 'git push origin main'
receipt "$SWH" "$C3" 0 incremental true '{"base_full_sha": "x"}'
advises "a green INCREMENTAL receipt is not a full proof" "incremental" 'git push origin main'
receipt "$SWH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false}, "full_equivalent": false}'
advises "a cache-composed receipt that is not full-equivalent is not a proof either" "full-equivalent" 'git push origin main'
receipt "$SWH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false, "suites_fresh": 40, "suites_cached": 528}, "full_equivalent": true}'
proves "a cache-composed receipt that IS full-equivalent counts" "${C3:0:12}" 'git push origin main'
receipt "$SWH" "$C3" 1 full false
advises "a RED receipt at HEAD: no green record, and the way forward is --failed" "was red" 'git push origin main'
hv 'git push origin main'
if printf '%s' "$HOUT" | jq -r .systemMessage | grep -q '^Run: bash test/run-all.sh --failed'; then ok "$N. after a red sweep the command to run is test/run-all.sh --failed, never a second full sweep"; else bad "red: the Run line is not --failed" "$(msg)"; fi
receipt "$SWH" "$C1" 1 full false
advises "a red receipt at an ANCESTOR of HEAD (the fix is committed, the red is still the last word)" "was red" 'git merge feature'
receipt "$SWH" "$CS" 1 full false
advises "a red receipt of other history says nothing about this tree: no green record yet, and a plain full sweep" "no green record yet" 'git push origin main'
hv 'git push origin main'
if printf '%s' "$HOUT" | jq -r .systemMessage | grep -q '^Run: bash test/run-all.sh$'; then ok "$N. ...and the command is the plain bash test/run-all.sh"; else bad "other history: the Run line" "$(msg)"; fi
receipt "$SWH" "$C3" 0 aborted true
advises "an ABORTED receipt is red even with an exit_code of 0" "was red" 'git push origin main'
rm -rf "$SWH/receipts"
advises "no receipt at all: no green record yet, and the number of suites on disk" "no green record yet" 'git push origin main'
hv 'git push origin main'
if msg | grep -q '^Cost: 2 suites on disk (test/\*.test.sh), no run on record'; then ok "$N. ...the cost line then counts the suites it can see (test/*.test.sh: 2), with no wall clock on record"; else bad "no receipt: the Cost line" "$(msg)"; fi
mkdir -p "$SWH/receipts"; printf 'not json at all\n' >"$SWH/receipts/last-sweep.json"
advises "a receipt that is not JSON: no usable record, said so" "unreadable" 'git push origin main'
receipt "$SWH" "$C3" 0 full true '{"repo": "/somewhere/else"}'
advises "a receipt recorded for ANOTHER checkout is not this tree's" "another checkout" 'git push origin main'
receipt "$SWH" "$C1" 0 full true
printf 'pid=%s\nrepo=%s\nstarted=2026-11-12T00:00:00+0000\n' "$SLEEPER" "$SWTOP" >"$SWH/receipts/sweep.lock"
advises "a sweep is ALREADY RUNNING (a live pid in the lock): wait for it, never start a second" "already running (pid $SLEEPER)" 'git push origin main'
rm -f "$SWH/receipts/sweep.lock"
HH="$TMPROOT/hh"; receipt "$HH" "$C3" 0 full true
proves "HEIMDALL_HOME moves the receipts, as it does for the runner" "${C3:0:12}" 'git push origin main' "$SW" HEIMDALL_HOME="$HH"
receipt "$SWH" "$C1" 0 full true
printf '{"finished_at": "2026-10-01T00:00:00Z", "repo": "%s", "head_sha": "%s", "tree_clean": true, "exit_code": 0, "kind": "full", "suites_total": 535, "duration_s": 492}\n' "$SWTOP" "$C3" >"$SWH/receipts/last-full-green.json"
proves "the last-sweep receipt is red or partial but last-full-green.json (the chain anchor) covers HEAD" "${C3:0:12}" 'git push origin main'
rm -f "$SWH/receipts/last-full-green.json"

echo "-- 5. the cost: suites, wall clock, and tokens as LABELLED ESTIMATES with their arithmetic --"
receipt "$SWH" "$C1" 0 full true
hv 'git push origin main'
COST="$(msg | grep '^Cost: ')"
# 568 suites, 2873 s = 47m53s; a 40-line summary tail at 91 bytes a line is 3640 B = ~910 tokens; the whole output is (568 + 40) rows x 91 B = 55328 B = ~13.8k tokens
if printf '%s' "$COST" | grep -q '568 suites' && printf '%s' "$COST" | grep -q '47m53s'; then ok "the suite count and the last measured wall clock come from the receipt (568 suites, 2873 s = 47m53s)"; else bad "cost: suites and wall clock" "$COST"; fi
if printf '%s' "$COST" | grep -q '~910' && printf '%s' "$COST" | grep -q '~13.8k'; then ok "tokens: ~910 for a summary tail (40 lines x 91 B / 4), ~13.8k for all of it ((568 + 40) rows x 91 B / 4)"; else bad "cost: the token estimates" "$COST"; fi
if printf '%s' "$COST" | grep -qi 'estimate' && printf '%s' "$COST" | grep -q 'no model tokens\|0 model tokens\| 0 '; then ok "every token figure is labelled an estimate, and the machine time of a terminal run is said to cost no model tokens"; else bad "cost: labels" "$COST"; fi
receipt "$SWH" "$C1" 0 full true '{"suites_total": 100, "duration_s": 59, "cache": {"cold": false, "suites_fresh": 7, "suites_cached": 93}}'
hv 'git push origin main'
COST="$(msg | grep '^Cost: ')"
if printf '%s' "$COST" | grep -q '100 suites' && printf '%s' "$COST" | grep -q '59s' && printf '%s' "$COST" | grep -q '7 fresh, 93 cached' && printf '%s' "$COST" | grep -q '~910' && printf '%s' "$COST" | grep -q '~3.2k'; then ok "100 suites, 59 s, 7 fresh and 93 cached; the whole output is (100 + 40) x 91 B / 4 = ~3.2k tokens"; else bad "cost: a second set of numbers" "$COST"; fi
receipt "$SWH" "$C1" 0 full true '{"suites_total": 568, "duration_s": 7385}'
hv 'git push origin main'
if msg | grep '^Cost: ' | grep -q '2h03m'; then ok "an hour or more is written 2h03m"; else bad "cost: hours" "$(msg | grep '^Cost: ')"; fi

echo "-- 6. a repo that declares its own checks gets its own command and its own receipt --"
rc_run() {  # record the declared checks with the REAL runner, then give the two checks the seconds the cost line is to quote
  ( cd "$RC" && python3 -I -S "$REPO/bin/lib/hmd_repo_checks.py" run --repo "$RC" >/dev/null 2>&1 ) \
    && jq '.checks[0].secs = 12 | .checks[1].secs = 95' "$RC/.heimdall/receipts/repo-checks.json" >"$TMPROOT/rcr.json" && mv "$TMPROOT/rcr.json" "$RC/.heimdall/receipts/repo-checks.json"
}
hv 'git push origin main' "$RC"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'bin/heimdall-repo-checks run --repo' && msg | grep -q 'no green record yet' && msg | grep -q '^Cost: 2 checks'; then ok "no receipt yet: its own runner (bin/heimdall-repo-checks run --repo <repo>), 2 checks, no green record yet"; else bad "repo-checks, no receipt: rc=$HRC" "$(msg)"; fi
rc_run
hv 'git push origin main' "$RC"
if [ "$HRC" = 3 ] && proven_ok "$HOUT" "${R1:0:12}" && msg | grep -q 'repo-checks'; then ok "a green receipt for HEAD: already proven green (the repo's own receipt, bound to the commit)"; else bad "repo-checks, green: rc=$HRC" "$(msg)"; fi
hv 'gh pr merge 3' "$RC"
if [ "$HRC" = 3 ] && proven_ok "$HOUT" "${R1:0:12}"; then ok "a pull request merge at that proven HEAD"; else bad "repo-checks, pr merge: $(msg)"; fi
printf 'two\n' >"$RC/a.txt"; git -C "$RC" add a.txt && git_q -C "$RC" commit -q -m "R2 code"; R2="$(git -C "$RC" rev-parse HEAD)"
hv 'git push origin main' "$RC"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'STALE' && msg | grep -q "1 commit and 1 file changed since the last recorded run (${R1:0:12}" && msg | grep -q '^Run: .*bin/heimdall-repo-checks run --repo' && msg | grep -q '^Cost: 2 checks (lint 12s, use-cases 1m35s)' && msg | grep -q '1m47s'; then ok "a commit after the run: STALE, how much changed since it, the runner command, and the checks with the seconds the receipt recorded (1m47s in all)"; else bad "repo-checks, stale: rc=$HRC" "$(msg)"; fi
rc_run
git -C "$RC" checkout -q -b side && printf 'side\n' >"$RC/s.txt" && git -C "$RC" add s.txt && git_q -C "$RC" commit -q -m "S side" && git -C "$RC" checkout -q main
hv 'git merge side' "$RC"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'side' && msg | grep -q '^Run: .*bin/heimdall-repo-checks run --repo'; then ok "a merge in a repo-checks repo: HEAD is proven but the receipt attests ONE commit and the branch coming in is another, so the runner command"; else bad "repo-checks, merge: rc=$HRC" "$(msg)"; fi
jq '.exit_code = 1 | .checks[1].exit_code = 1' "$RC/.heimdall/receipts/repo-checks.json" >"$TMPROOT/rcr.json" && mv "$TMPROOT/rcr.json" "$RC/.heimdall/receipts/repo-checks.json"
hv 'git push origin main' "$RC"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'RED - check(s) failed: use-cases'; then ok "a red receipt at HEAD: the runner's own words, RED - check(s) failed: use-cases"; else bad "repo-checks, red: rc=$HRC $(msg)"; fi
printf '{"schema":1,"checks":[]}\n' >"$RC/.heimdall/repo-checks.json"; git -C "$RC" add .heimdall/repo-checks.json && git_q -C "$RC" commit -q -m "R3 broken declaration"
hv 'git push origin main' "$RC"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'use-case-tests.md' && msg | grep -q 'declaration'; then ok "an invalid declaration cannot name a runner: lint plus the use-case suite, with the pointer, and the declaration named as the problem"; else bad "repo-checks, invalid declaration: rc=$HRC $(msg)"; fi

echo "-- 7. a repo hmd does not manage gets lint plus the use-case suite --"
hv 'git push origin trunk' "$UN"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'skills/heimdall/references/use-case-tests.md' && msg | grep -q '^Run: .*lint' && msg | grep -q 'no green record yet' && msg | grep -q '~910'; then ok "lint + the use-case suite, the pointer to use-case-tests.md, no green record yet, and the token estimate still there"; else bad "unmanaged: rc=$HRC" "$(msg)"; fi
hv 'git merge trunk' "$UN"
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'use-case-tests.md'; then ok "a merge in an unmanaged repo"; else bad "unmanaged merge: rc=$HRC $(msg)"; fi

echo "-- 8. what it cannot tell is exit 4 with a reason (the hook warns and allows), never a guess --"
unread "an unbalanced quote that mentions a merge" 'unbalanced quote' 'echo "git merge feature'
unread "a cd to a variable, then a merge: which repo is unknown" 'cannot be told' 'cd "$SOMEWHERE" && git merge feature'
unread "cd - likewise" 'cannot be told' 'cd - && git merge feature'
unread "the repository is not a git repository" 'rev-parse' 'git merge feature' "$NOGIT"
unread "a directory that does not exist" 'does not exist' 'git -C /no/such/dir merge feature'
unread "git's -C value in a variable" 'variable' 'git -C "$D" merge feature'
unread "ANSI-C quoting, which is not decoded" 'ANSI-C' $'echo $\'git merge x\''
DEEP='git merge feature'
for i in 1 2 3 4 5 6 7 8 9 10; do DEEP="sh <<E$i"$'\n'"$DEEP"$'\n'"E$i"; done
unread "shell strings nested ten deep (past the depth it reads)" 'nested more than 8 deep' "$DEEP"
LONGCMD="$(python3 -I -c 'print("echo merge; " + "echo x; " * 3000)')"
unread "a command that takes longer than HMD_SWEEP_ADVICE_TIMEOUT_S to read (1 ms here)" 'took longer' "$LONGCMD" "$SW" HMD_SWEEP_ADVICE_TIMEOUT_S=0.001
N=$((N + 1)); hv 'git merge feature; echo "unbalanced'
if [ "$HRC" = 3 ] && advice_ok "$HOUT" "feature"; then ok "$N. a merge it READ wins over a quote it could not close"; else bad "$N. read wins over unread: rc=$HRC $HOUT"; fi
N=$((N + 1)); hv 'git merge nosuchbranch'
if [ "$HRC" = 3 ] && advice_ok "$HOUT" 'since the last'; then ok "$N. a ref git cannot place is not counted: HEAD alone is judged"; else bad "$N. unknown ref: rc=$HRC $HOUT $HERR"; fi

echo "-- 9. through the REAL hook: one line of JSON on stdout, nothing else, exit 0 --"
receipt "$SWH" "$C1" 0 full true
run_hook 'git merge feature' "$PLUGIN"
N=$((N + 1))
if [ "$RC_" = 0 ] && advice_ok "$(cat "$TMPROOT/out")" 'bash test/run-all.sh' && [ ! -s "$TMPROOT/err" ]; then ok "$N. a merge: exit 0, advice on stdout as hook JSON, silent on stderr"; else bad "$N. hook, merge: rc=$RC_" "stdout=$(head -c 300 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"; fi
N=$((N + 1))
if jq -e '.hookSpecificOutput.additionalContext | contains("not a block") and contains("developer") and (contains("Do not start") or contains("do not start"))' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the agent's context says it is advice, that the developer decides, and that the agent does not start the run itself"; else bad "$N. agent context" "$(jq -r .hookSpecificOutput.additionalContext "$TMPROOT/out" | head -c 400)"; fi
run_hook 'gh pr merge 12 --squash' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 0 ] && advice_ok "$(cat "$TMPROOT/out")" 'bash test/run-all.sh'; then ok "$N. a pull request merge through the hook"; else bad "$N. hook, pr merge: rc=$RC_" "$(head -c 300 "$TMPROOT/out")"; fi
run_hook 'git push origin main' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 0 ] && advice_ok "$(cat "$TMPROOT/out")" 'bash test/run-all.sh'; then ok "$N. a push to main: the push gates pass (fakes), THEN the advice: still one line of JSON"; else bad "$N. hook, push: rc=$RC_" "stdout=$(head -c 300 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"; fi
SILENT_BAD=""
for form in 'ls -la' 'git status' 'git commit -m "merge fix"' 'echo "git push origin main"' 'git push origin feature' 'git merge --abort' 'git pull --rebase' 'npm run pull-translations' 'gh pr view 12' 'bash test/a.test.sh'; do
  run_hook "$form" "$PLUGIN"
  { [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ]; } || SILENT_BAD="$SILENT_BAD [$form: rc=$RC_ $(head -c 100 "$TMPROOT/out")]"
done
N=$((N + 1)); if [ -z "$SILENT_BAD" ]; then ok "$N. ordinary commands, mentions and non-merges print nothing on stdout: no suggestion before merge time"; else bad "$N. the hook spoke for a non-merge:$SILENT_BAD"; fi

echo "-- 10. the tracker's output never corrupts the JSON; without advice it is untouched --"
run_hook 'git merge feature' "$PLUGIN" TRACKER_SAYS="tracker says hi"
N=$((N + 1)); if [ "$RC_" = 0 ] && advice_ok "$(cat "$TMPROOT/out")" 'bash test/run-all.sh' && grep -q 'tracker says hi' "$TMPROOT/err" && ! grep -q 'tracker says hi' "$TMPROOT/out"; then ok "$N. with advice, stdout is JSON only and the tracker's words go to stderr"; else bad "$N. tracker with advice: rc=$RC_" "stdout=$(head -c 300 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"; fi
run_hook 'git status' "$PLUGIN" TRACKER_SAYS="tracker says hi"
N=$((N + 1)); if [ "$RC_" = 0 ] && [ "$(cat "$TMPROOT/out")" = "$(printf 'tracker says hi\ntracker says hi')" ]; then ok "$N. without advice the tracker's output is exactly what it was (its stderr folded into stdout, as before)"; else bad "$N. tracker without advice: rc=$RC_" "stdout=$(head -c 200 "$TMPROOT/out")"; fi

echo "-- 11. HMD_SWEEP_ADVICE=off (the hook's OWN environment) silences it; anything else leaves it on --"
OV_BAD=""
for v in off OFF Off 0 false FALSE no No; do
  rm -f "$MARK"; run_hook 'git merge feature' "$STUB_ADVICE" HMD_SWEEP_ADVICE="$v"
  { [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ] && [ ! -e "$MARK" ]; } || OV_BAD="$OV_BAD [$v: rc=$RC_ out=$(head -c 60 "$TMPROOT/out") ran=$([ -e "$MARK" ] && echo yes || echo no)]"
done
N=$((N + 1)); if [ -z "$OV_BAD" ]; then ok "$N. off, OFF, Off, 0, false, FALSE, no, No: silent, and the helper is never even started"; else bad "$N. override off:$OV_BAD"; fi
OV_BAD=""
for v in '' 1 on true yes offx ' off' 'off ' 00 nope; do
  rm -f "$MARK"; run_hook 'git merge feature' "$STUB_ADVICE" HMD_SWEEP_ADVICE="$v"
  { [ "$RC_" = 0 ] && jq -e '.systemMessage | startswith("stub says")' "$TMPROOT/out" >/dev/null 2>&1 && [ -e "$MARK" ]; } || OV_BAD="$OV_BAD [$(printf '%s' "$v"): rc=$RC_ out=$(head -c 60 "$TMPROOT/out")]"
done
N=$((N + 1)); if [ -z "$OV_BAD" ]; then ok "$N. empty, 1, on, true, yes, offx, ' off', 'off ', 00, nope all leave it ON: a typo never switches it off"; else bad "$N. override other values:$OV_BAD"; fi
rm -f "$MARK"; run_hook 'HMD_SWEEP_ADVICE=off git merge feature' "$STUB_ADVICE"
N=$((N + 1)); if [ "$RC_" = 0 ] && [ -e "$MARK" ]; then ok "$N. an INLINE HMD_SWEEP_ADVICE=off reaches the merge, not the hook that reads its own environment"; else bad "$N. inline override: rc=$RC_"; fi

echo "-- 12. the guardrail switch (hmd guardrails off sweep-advice): only the lib's exit 1 is off, and a core row is never switchable --"
mkdir -p "$TMPROOT/home/.heimdall"
printf 'sweep-advice\n' >"$TMPROOT/home/.heimdall/guardrails-off"
rm -f "$MARK"; run_hook 'git merge feature' "$STUB_ADVICE"
N=$((N + 1)); if [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ] && [ ! -e "$MARK" ]; then ok "$N. sweep-advice in guardrails-off: silent, and the helper never starts"; else bad "$N. guardrails-off: rc=$RC_" "$(head -c 200 "$TMPROOT/out") $(head -c 200 "$TMPROOT/err")"; fi
run_hook 'git merge feature' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then ok "$N. ...with the REAL helper too (nothing on stdout, nothing on stderr)"; else bad "$N. guardrails-off, real helper: rc=$RC_" "$(head -c 200 "$TMPROOT/out")"; fi
run_hook 'git merge feature' "$CORED"
N=$((N + 1)); if [ "$RC_" = 0 ] && jq -e 'has("systemMessage")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a manifest that calls it core keeps it on (the tier is read from the manifest, not trusted from the file)"; else bad "$N. core tier: rc=$RC_" "$(head -c 200 "$TMPROOT/out")"; fi
printf 'bash-gate-chain\nkill-guard\nsweep-guard\nci-waste-guard\nwait-guard\ndisk-floor\n' >"$TMPROOT/home/.heimdall/guardrails-off"
run_hook 'git merge feature' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 0 ] && jq -e 'has("systemMessage")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. other ids in the file (core and the other recommended guards) leave it on"; else bad "$N. other ids: rc=$RC_" "$(head -c 200 "$TMPROOT/out")"; fi
printf 'sweep-advice\n' >"$TMPROOT/home/.heimdall/guardrails-off"
for rc in 0 2 127; do
  rm -f "$MARK"; run_hook 'git merge feature' "$LIBSTUB" STUB_RC=$rc
  N=$((N + 1)); if [ "$RC_" = 0 ] && [ -e "$MARK" ]; then ok "$N. a lib that answers $rc leaves it on (only exactly 1 is off)"; else bad "$N. lib answers $rc: rc=$RC_ ran=$([ -e "$MARK" ] && echo yes || echo no)"; fi
done
rm -f "$MARK"; run_hook 'git merge feature' "$LIBSTUB" STUB_RC=1
N=$((N + 1)); if [ "$RC_" = 0 ] && [ ! -e "$MARK" ] && [ ! -s "$TMPROOT/out" ]; then ok "$N. a lib that answers 1: off"; else bad "$N. lib answers 1: rc=$RC_"; fi
run_hook 'git merge feature' "$NOLIB"
N=$((N + 1)); if [ "$RC_" = 0 ] && jq -e 'has("systemMessage")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. no guardrail lib in the plugin root: any doubt keeps it on"; else bad "$N. no lib: rc=$RC_" "$(head -c 200 "$TMPROOT/out")"; fi
rm -f "$TMPROOT/home/.heimdall/guardrails-off"

echo "-- 13. FAILS OPEN: what the helper cannot do is one stderr line at most, and the command goes on --"
fail_open() {  # fail_open <label> <plugin root> <fragment of the stderr line, or ''>
  run_hook 'git merge feature' "$2"
  N=$((N + 1))
  local lines; lines="$(wc -l <"$TMPROOT/err" | tr -d ' ')"
  local said=1   # the stderr line holds the fragment, or (fragment -) there is no stderr at all
  if [ "$3" = - ]; then [ ! -s "$TMPROOT/err" ] || said=0; else grep -qF -- "$3" "$TMPROOT/err" || said=0; fi
  if [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ "$lines" -le 1 ] && [ "$said" = 1 ]; then ok "$N. $1"; else bad "$N. $1" "rc=$RC_ stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"; fi
}
fail_open "a helper that crashes (exit 1): a warning, an allow, nothing on stdout" "$STUB_CRASH" 'the helper itself failed (exit 1)'
fail_open "a helper that prints garbage and exits 7" "$STUB_GARBAGE" 'the helper itself failed (exit 7)'
fail_open "a helper that exits 4: its reason is the warning" "$STUB_UNREAD" 'an odd command the stub could not read'
fail_open "a helper whose import is missing (no hmd_sweep_guard.py beside it)" "$NOGUARD" 'the helper itself failed'
fail_open "no helper in the plugin root: silent, a plumbing gap (not even a warning)" "$NOHELPER" -
fail_open "a helper that says nothing and exits 0: silent" "$STUB_SILENT" -
run_hook 'git merge feature' "$PLUGIN" HMD_SWEEP_ADVICE_TIMEOUT_S=0.0000001
N=$((N + 1)); if [ "$RC_" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ "$(wc -l <"$TMPROOT/err" | tr -d ' ')" -le 1 ]; then ok "$N. a timeout: an allow, one line at most"; else bad "$N. timeout: rc=$RC_" "$(head -c 200 "$TMPROOT/err")"; fi
rm -f "$MARK"; run_hook 'git merge feature' "$STUB_ADVICE"
N=$((N + 1)); if [ "$RC_" = 0 ] && jq -e '.systemMessage == "stub says \"hi\" \\ there %s"' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a message with a quote, a backslash and a percent sign reaches stdout verbatim (printf '%s', never a format)"; else bad "$N. verbatim: rc=$RC_" "$(head -c 200 "$TMPROOT/out")"; fi

echo "-- 14. the place in the chain: advice comes only for a command the gates let through --"
run_hook 'git merge feature; sleep 600' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 2 ] && jq -e 'keys == ["error"] and (.error | startswith("BLOCKED: hmd wait guard"))' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a command the wait guard denies prints ONLY the deny (no advice before it, none after)"; else bad "$N. deny wins: rc=$RC_" "$(head -c 300 "$TMPROOT/out")"; fi
receipt "$SWH" "$C3" 1 full false
run_hook 'bash test/run-all.sh; git push origin main' "$PLUGIN"
N=$((N + 1)); if [ "$RC_" = 2 ] && jq -e 'keys == ["error"] and (.error | startswith("BLOCKED: hmd sweep guard"))' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a full sweep the sweep guard holds is the sweep guard's deny, not advice"; else bad "$N. sweep guard first: rc=$RC_" "$(head -c 300 "$TMPROOT/out")"; fi
receipt "$SWH" "$C1" 0 full true

echo "-- 15. the pre-filter: the helper starts only for a command that mentions merge, push or pull AND git or gh --"
PF_BAD=""
for form in 'ls -la' 'git status' 'git commit -m "fix the flaky test"' 'bash test/a.test.sh' 'echo hello world' 'gh run list' 'npm run pull-translations' 'echo merge the branches' 'docker push img' 'make push' 'git log --oneline'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC_" = 0 ] && [ ! -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC_]"
done
N=$((N + 1)); if [ -z "$PF_BAD" ]; then ok "$N. ls, git status, a commit, a test file, echo, gh run list, npm, docker, make, git log: the helper is never started"; else bad "$N. pre-filter let ordinary commands through to python:$PF_BAD"; fi
PF_BAD=""
for form in 'git merge feature' 'git merge --abort' 'gh pr merge 12' 'git pull' 'git push origin main' 'git push origin feature' 'echo "git push"' 'grep -rn "git merge" docs/' 'git commit -m "merge"'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC_" = 0 ] && [ -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC_]"
done
N=$((N + 1)); if [ -z "$PF_BAD" ]; then ok "$N. a merge, an abort, a pull request merge, a pull, two pushes, two mentions and a commit message that names one: the helper is asked (it decides what is real)"; else bad "$N. pre-filter missed a trigger:$PF_BAD"; fi

echo "-- 16. the REAL plugin root (the files as shipped), and the wiring --"
run_hook 'git merge feature' "$REPO"
N=$((N + 1)); if [ "$RC_" = 0 ] && advice_ok "$(cat "$TMPROOT/out")" 'bash test/run-all.sh'; then ok "$N. the shipped hook and libs give the advice"; else bad "$N. real root: rc=$RC_" "stdout=$(head -c 300 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"; fi
ROW="$(jq -c '[.guardrails[] | select(.id == "sweep-advice")]' "$MANIFEST" 2>/dev/null)"
if [ "$(printf '%s' "$ROW" | jq 'length')" = 1 ] && printf '%s' "$ROW" | jq -e '.[0] | .kind == "guard" and .tier == "recommended" and .layer == "precheck-bash" and .hook == "bash-gate-chain" and .fails == "open" and .operator_env == "HMD_SWEEP_ADVICE=off" and .proof == "test/sweep-advice.test.sh"' >/dev/null 2>&1; then ok "guardrails.manifest.json has ONE sweep-advice row: a recommended guard in precheck-bash, fails open, override HMD_SWEEP_ADVICE=off, proven by this suite"; else bad "the manifest row" "$ROW"; fi
if grep -q 'HMD_SWEEP_ADVICE' "$HOOK" && grep -q 'hmd_sweep_advice.py' "$HOOK" && grep -q 'gp_guard_on sweep-advice' "$HOOK"; then ok "bin/heimdall-precheck-bash names the switch, the helper and asks the guardrail lib for sweep-advice"; else bad "the hook does not name HMD_SWEEP_ADVICE, hmd_sweep_advice.py and gp_guard_on sweep-advice"; fi
if grep -q 'HMD_SWEEP_ADVICE' "$REPO/CLAUDE.md" && grep -q 'bin/lib/hmd_sweep_advice.py' "$REPO/CLAUDE.md" && grep -q 'test/sweep-advice.test.sh' "$REPO/CLAUDE.md"; then ok "CLAUDE.md describes the advice: the override, the lib, and this test"; else bad "CLAUDE.md does not name HMD_SWEEP_ADVICE, bin/lib/hmd_sweep_advice.py and test/sweep-advice.test.sh"; fi
if grep -q 'hmd_sweep_advice' "$REPO/CHANGELOG.md"; then ok "CHANGELOG.md has the bullet"; else bad "CHANGELOG.md does not mention hmd_sweep_advice"; fi

printf '\n  sweep-advice: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
