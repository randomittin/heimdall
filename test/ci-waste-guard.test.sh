#!/usr/bin/env bash
# shellcheck disable=SC2016  # the payloads fed to the hook are literal text: $id, $(...) and backticks must NOT expand here
# test/ci-waste-guard.test.sh
#
# An hmd agent must never pay CI minutes to re-roll a flaky result.
#
# 2026-10-19 -- in a client repo an hmd agent worked around a flaky test by pushing an EMPTY commit to retrigger CI and by re-running the
# workflow twice, instead of fixing the flake. Every attempt cost GitHub Actions minutes and the test was still flaky. Operator: "this must be
# fixed and you can fix this in hmd harness permanently". bin/heimdall-precheck-bash now asks bin/lib/hmd_ci_guard.py (FIRST in the chain),
# which reads the command the way a shell does -- it reuses bin/lib/hmd_kill_guard.py's lexer. This drives the REAL hook with JSON payloads, in
# a throwaway plugin root (the real hook and libs, a tracker that does nothing), and pins:
#   * every way found to make an empty commit, or to re-run / re-dispatch CI, is denied: `git commit --allow-empty` wherever the flag sits and
#     behind any git global option; `gh run rerun` with any flags; `gh workflow run`; a `gh api` POST (explicit, or implied by a body) to a
#     .../rerun, .../rerun-failed-jobs, .../dispatches or .../rerequest endpoint -- through quotes, wrappers (env, nice, timeout, sudo, xargs),
#     chains, pipes, subshells, substitutions, loops, sh -c, eval and heredocs fed to a shell
#   * what stays allowed: text that only MENTIONS a form (echo, grep, a commit message or its heredoc, a -m value, a gh field value, a file being
#     written), --allow-empty-message, --no-allow-empty, and every gh command that only reads or cancels
#   * the deny text: the two messages the operator asked for, and how the OPERATOR lifts the guard
#   * HMD_CI_RERUN_ALLOW=1, read from the hook's OWN environment, lifts it (nothing runs); an inline prefix does not; anything but 1 leaves it on
#   * it FAILS OPEN, like the disk floor (a cost guard, not a security gate): a helper that is missing, crashes, prints garbage or times out, and
#     a command it cannot read, are one stderr line and an allow -- while a form it DID read wins over what it could not read
#   * the pre-filter: python starts only for a command that mentions one of the trigger words
#   * the guard sits FIRST in the chain: a refused command never reaches git-guard or the secret scan
# The guard is a COST control and BEST EFFORT, not a security boundary: no text guard on shell is complete.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precheck-bash"
HELPER="$REPO/bin/lib/hmd_ci_guard.py"
LIBS=(hmd_ci_guard.py hmd_kill_guard.py hmd_push_target.py hmd_repo_receipt.py)
PASS=0
FAIL=0
N=0
D_FORMS=0
A_FORMS=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

TMPROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

echo "ci-waste-guard"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
[ -f "$HOOK" ] || { bad "0. bin/heimdall-precheck-bash is missing"; exit 1; }
if [ -f "$HELPER" ] && python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null; then ok "0. bin/lib/hmd_ci_guard.py exists and parses"; else bad "0. bin/lib/hmd_ci_guard.py is missing or does not parse"; fi
if bash -n "$HOOK" 2>/dev/null; then ok "0. bin/heimdall-precheck-bash parses"; else bad "0. bin/heimdall-precheck-bash does not parse"; fi

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4s a call, and this suite starts python for most of its cases
PYREAL="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$TMPROOT/pybin"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then ln -s "$PYREAL" "$TMPROOT/pybin/python3"; fi

# Throwaway plugin roots holding ONLY the hook under test, so an allowed command is allowed by this chain alone and nothing real runs.
mkroot() {  # mkroot <dir> [python source of a stub helper]: the REAL hook, the REAL helper and what it imports (or the stub), a tracker that does nothing
  local d="$1" f
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  for f in "${LIBS[@]}"; do cp "$REPO/bin/lib/$f" "$d/bin/lib/$f" 2>/dev/null; done
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/parallelism-tracker"
  chmod +x "$d/bin/heimdall-precheck-bash" "$d/bin/parallelism-tracker"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" >"$d/bin/lib/hmd_ci_guard.py"; fi
}
PLUGIN="$TMPROOT/plugin"
mkroot "$PLUGIN"
# the same root plus a secret scan and a git-guard that only record that they ran: where the guard sits in the chain
ORDER="$TMPROOT/plugin-order"
mkroot "$ORDER"
printf '#!/bin/sh\necho scan >>"%s"\nexit 0\n' "$TMPROOT/scan.ran" >"$ORDER/bin/secret-scan"
printf '#!/bin/sh\necho guard >>"%s"\nexit 0\n' "$TMPROOT/guard.ran" >"$ORDER/bin/heimdall-git-guard"
chmod +x "$ORDER/bin/secret-scan" "$ORDER/bin/heimdall-git-guard"
# helpers that misbehave, and one that records that it was started
MARK="$TMPROOT/helper.ran"
STUB_OK="$TMPROOT/plugin-stub-ok";       mkroot "$STUB_OK" 'import os
open(os.environ["CI_STUB_MARK"], "a").write("ran\n")
print("ok")'
STUB_CRASH="$TMPROOT/plugin-stub-crash"; mkroot "$STUB_CRASH" 'import sys
sys.exit(1)'
STUB_SILENT="$TMPROOT/plugin-stub-silent"; mkroot "$STUB_SILENT" 'import sys
sys.exit(0)'
STUB_GARBAGE="$TMPROOT/plugin-stub-garbage"; mkroot "$STUB_GARBAGE" 'import sys
sys.stdout.write("not ok\n")
sys.exit(7)'
STUB_DENY="$TMPROOT/plugin-stub-deny"; mkroot "$STUB_DENY" 'import sys
sys.stdout.write("a \"quoted\" back\\slash reason\n")
sys.exit(3)'
STUB_UNREAD="$TMPROOT/plugin-stub-unread"; mkroot "$STUB_UNREAD" 'import sys
sys.stdout.write("a odd command the stub could not read\n")
sys.exit(4)'
NOHELPER="$TMPROOT/plugin-nohelper"; mkroot "$NOHELPER"; rm -f "$NOHELPER/bin/lib/hmd_ci_guard.py"
NOKILL="$TMPROOT/plugin-nokill"; mkroot "$NOKILL"; rm -f "$NOKILL/bin/lib/hmd_kill_guard.py"

RC=0
run_hook() {  # run_hook <command> <plugin root> [VAR=val ...]  -> RC, $TMPROOT/out (stdout), $TMPROOT/err (stderr)
  local cmd="$1" root="$2"
  shift 2
  # the payload is built from a file (--rawfile), so a command of any size is not an argument; HMD_MIN_FREE_PCT=0 keeps the disk floor out of it (this suite never
  # depends on the disk it runs on); what the operator exports in their own shell never changes a case, a case that needs a setting passes it
  printf '%s' "$cmd" >"$TMPROOT/cmd.txt"
  jq -nc --rawfile c "$TMPROOT/cmd.txt" --arg cwd "$TMPROOT" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $c}}' \
    | env -u HMD_CI_RERUN_ALLOW -u HMD_KILL_GUARD -u HMD_CI_GUARD_TIMEOUT_S PATH="$TMPROOT/pybin:$PATH" HMD_MIN_FREE_PCT=0 \
        CLAUDE_PLUGIN_ROOT="$root" CI_STUB_MARK="$MARK" "$@" bash "$root/bin/heimdall-precheck-bash" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
}
denied() {  # denied <command> <label> [VAR=val ...]: exit 2, a JSON {error} from THIS guard on stdout, the same verdict on stderr
  N=$((N + 1)); D_FORMS=$((D_FORMS + 1))
  run_hook "$1" "$PLUGIN" "${@:3}"
  if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: ")' "$TMPROOT/out" >/dev/null 2>&1 && grep -q 'hmd CI waste guard' "$TMPROOT/err"; then
    ok "$N. denied: $2"
  else
    bad "$N. NOT denied: $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
allowed() {  # allowed <command> <label> [VAR=val ...]: exit 0 and completely silent (no deny, no warning)
  N=$((N + 1)); A_FORMS=$((A_FORMS + 1))
  run_hook "$1" "$PLUGIN" "${@:3}"
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then
    ok "$N. allowed: $2"
  else
    bad "$N. wrongly held: $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
warned() {  # warned <command> <label> <fragment of the warning> [plugin root] [VAR=val ...]: allowed (exit 0, stdout empty), one stderr line that says why nothing was checked
  N=$((N + 1))
  run_hook "$1" "${4:-$PLUGIN}" "${@:5}"
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && grep -q 'heimdall ci guard: ' "$TMPROOT/err" && grep -qF -- "$3" "$TMPROOT/err" && grep -q 'no CI-waste check for this command, allowing' "$TMPROOT/err"; then
    ok "$N. allowed with a warning: $2"
  else
    bad "$N. not 'allowed with a warning': $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"
  fi
}
denied_each() {  # one command per line on stdin
  local form
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    denied "$form" "$form"
  done
}
allowed_each() {  # one command per line on stdin
  local form
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    allowed "$form" "$form"
  done
}

echo "-- 1. the helper alone: command text on stdin; exit 0 + ok, exit 3 + a reason (deny), exit 4 + a reason (could not read) --"
helper() { python3 -I -S "$HELPER" <<<"$1" >"$TMPROOT/h.out" 2>"$TMPROOT/h.err"; echo $? >"$TMPROOT/h.rc"; }
helper 'git commit --allow-empty -m x'
if [ "$(cat "$TMPROOT/h.rc")" = 3 ] && [ "$(wc -l <"$TMPROOT/h.out" | tr -d ' ')" = 1 ] && grep -q 'empty commits to retrigger CI waste minutes' "$TMPROOT/h.out" && [ ! -s "$TMPROOT/h.err" ]; then ok "an empty commit: exit 3 and ONE reason line"; else bad "helper, empty commit: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out") err=$(head -c 200 "$TMPROOT/h.err")"; fi
helper 'gh run rerun 1 --failed'
if [ "$(cat "$TMPROOT/h.rc")" = 3 ] && grep -q 'a flaky failure is a defect' "$TMPROOT/h.out"; then ok "a CI re-run: exit 3 and the flaky-failure reason"; else bad "helper, rerun: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out")"; fi
helper 'git status && gh run list'
if [ "$(cat "$TMPROOT/h.rc")" = 0 ] && [ "$(cat "$TMPROOT/h.out")" = ok ] && [ ! -s "$TMPROOT/h.err" ]; then ok "an ordinary command: exit 0 and 'ok'"; else bad "helper, ordinary: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out")"; fi
helper 'echo "gh run rerun'
if [ "$(cat "$TMPROOT/h.rc")" = 4 ] && [ "$(wc -l <"$TMPROOT/h.out" | tr -d ' ')" = 1 ] && grep -q 'unbalanced quote' "$TMPROOT/h.out"; then ok "an unbalanced quote that mentions a trigger: exit 4 and the reason it could not be read"; else bad "helper, unbalanced: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out")"; fi

echo "-- 2. DENIED: an empty commit (git commit --allow-empty) --"
denied_each <<'EOF'
git commit --allow-empty -m "retrigger CI"
git commit -m "retrigger CI" --allow-empty
git commit --allow-empty
git commit --allow-empty --no-verify -m x
git commit -a --allow-empty -m x
git commit -qm retry --allow-empty
git commit -am "x" --allow-empty
git commit --amend --allow-empty --no-edit
git commit -m --allow-empty --allow-empty
git commit "--allow-empty" -m x
git commit '--allow-empty' -m x
git commit --allow-"empty" -m x
git commit --allow-\empty -m x
git -C /tmp/repo commit --allow-empty -m x
git -c user.name=a -c user.email=b@c commit --allow-empty -m x
git --no-pager commit --allow-empty -m x
git --git-dir=/x/.git --work-tree=/x commit --allow-empty -m x
git --git-dir /x/.git commit --allow-empty -m x
git -C "$REPO_DIR" commit --allow-empty -m x
/usr/bin/git commit --allow-empty -m x
"git" commit --allow-empty -m x
GIT commit --allow-empty -m x
cd repo && git commit --allow-empty -m x
git add -A; git commit --allow-empty -m x
git status || git commit --allow-empty -m x
echo ping | git commit --allow-empty -F -
git commit --allow-empty -m x && git push
git commit --allow-empty -m x 2>&1 | tail -3
EOF
echo "-- 2b. DENIED: an empty commit, behind wrappers, chains and shells --"
denied_each <<'EOF'
env GIT_AUTHOR_NAME=a git commit --allow-empty -m x
FOO=1 git commit --allow-empty -m x
HMD_CI_RERUN_ALLOW=1 git commit --allow-empty -m x
nice git commit --allow-empty -m x
nice -n 5 git commit --allow-empty -m x
time git commit --allow-empty -m x
timeout 30 git commit --allow-empty -m x
sudo -u bob git commit --allow-empty -m x
command git commit --allow-empty -m x
nohup git commit --allow-empty -m x &
echo ready | xargs git commit --allow-empty -m
sh -c "git commit --allow-empty -m x"
bash -lc 'git commit --allow-empty -m x'
eval "git commit --allow-empty -m x"
(git commit --allow-empty -m x)
{ git commit --allow-empty -m x; }
if true; then git commit --allow-empty -m x; fi
for i in 1 2; do git commit --allow-empty -m "try $i"; done
x=$(git commit --allow-empty -m x)
EOF
denied $'git status\ngit commit --allow-empty -m x' "after a newline"
denied $'git commit \\\n  --allow-empty \\\n  -m x' "the flag on a continued line"
denied $'bash <<EOF\ngit commit --allow-empty -m x\nEOF' "fed to a shell as a heredoc"
denied $'git commit --allow-empty -m "$(cat <<\'EOF\'\nretry\nEOF\n)"' "with a heredoc commit message"

echo "-- 3. DENIED: CI re-runs and re-dispatches (gh run rerun, gh workflow run, gh api POST) --"
denied_each <<'EOF'
gh run rerun 123
gh run rerun
gh run rerun 123 --failed
gh run rerun --failed 123
gh run rerun 123 --job 456
gh run rerun --job 456 -R owner/repo
gh run rerun 123 -R owner/repo
gh run rerun 123 --repo owner/repo --debug
gh run -R owner/repo rerun 123
gh run --repo=owner/repo rerun 123
gh workflow run ci.yml
gh workflow run ci.yml --ref main -f foo=bar
gh workflow run
gh workflow -R owner/repo run ci.yml
gh api -X POST repos/o/r/actions/runs/123/rerun
gh api -X POST /repos/o/r/actions/runs/123/rerun
gh api --method POST repos/o/r/actions/runs/123/rerun-failed-jobs
gh api repos/o/r/actions/runs/123/rerun -X POST
gh api -XPOST repos/o/r/actions/runs/123/rerun
gh api -X=POST repos/o/r/actions/runs/123/rerun
gh api --method=POST repos/o/r/actions/runs/123/rerun
gh api -X post repos/o/r/actions/runs/123/rerun
gh api -X POST repos/o/r/actions/jobs/456/rerun
gh api -X POST repos/o/r/check-suites/9/rerequest
gh api -X POST repos/o/r/check-runs/9/rerequest
gh api -X POST repos/o/r/actions/workflows/ci.yml/dispatches -f ref=main
gh api repos/o/r/actions/workflows/ci.yml/dispatches -f ref=main
gh api repos/o/r/actions/workflows/ci.yml/dispatches -F ref=main
gh api repos/o/r/actions/workflows/ci.yml/dispatches --raw-field ref=main
gh api repos/o/r/actions/workflows/ci.yml/dispatches --field ref=main
gh api repos/o/r/actions/workflows/ci.yml/dispatches --input body.json
gh api repos/o/r/dispatches -f event_type=ci
gh api -H "Accept: application/vnd.github+json" -X POST repos/o/r/actions/runs/123/rerun
gh api -X POST "repos/o/r/actions/runs/$ID/rerun"
gh api -X POST repos/{owner}/{repo}/actions/runs/123/rerun
gh api -X POST repos/o/r/actions/runs/123/rerun?enable_debug_logging=true
gh api -X POST https://api.github.com/repos/o/r/actions/runs/123/rerun
gh api -X "$M" repos/o/r/actions/runs/123/rerun
EOF
echo "-- 3b. DENIED: CI re-runs, behind wrappers, chains and shells --"
denied_each <<'EOF'
GH_TOKEN=x gh run rerun 123
env GH_TOKEN=x gh run rerun 123
timeout 60 gh run rerun 123 --failed
time gh run rerun 123
sudo gh run rerun 123
/opt/homebrew/bin/gh run rerun 123
GH run rerun 123
gh run list && gh run rerun 123
gh run view 123 --log-failed; gh run rerun 123 --failed
git push && gh run rerun
sleep 30 && gh workflow run ci.yml
gh run rerun 123 | cat
gh run rerun 123 2>&1
gh run rerun $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
echo 123 | xargs gh run rerun
for id in 1 2; do gh run rerun $id; done
if ! gh run watch 123; then gh run rerun 123 --failed; fi
(gh run rerun 123)
x=$(gh run rerun 123)
sh -c "gh run rerun 123"
bash -c 'gh workflow run ci.yml'
eval "gh run rerun 123"
EOF
denied $'cat log.txt\ngh run rerun 123 --failed' "after a newline"
denied $'sh <<EOF\ngh workflow run ci.yml\nEOF' "fed to a shell as a heredoc"

echo "-- 4. ALLOWED: text that only MENTIONS a form, and what the guard is not about --"
allowed_each <<'EOF'
echo "gh run rerun 123"
echo gh run rerun
echo "git commit --allow-empty"
printf '%s\n' "gh workflow run ci.yml"
echo 'gh api -X POST repos/o/r/actions/runs/1/rerun'
grep -rn "gh run rerun" docs/
grep -rn -- --allow-empty bin/
grep -n 'allow-empty' test/disk-floor.test.sh
cat docs/ci-notes-rerun.md
sed -n '1,20p' docs/dispatches.md
ls .github/workflows/
cat .github/workflows/run-tests.yml
git add .github/workflows/ci.yml
git commit -m "docs: never gh run rerun or git commit --allow-empty"
git commit -m "fix flaky test (was: gh workflow run twice)"
git commit -m "--allow-empty"
git commit -m '--allow-empty'
git commit -m --allow-empty
git commit -F --allow-empty
git commit --message --allow-empty
git commit --message=--allow-empty
git commit -am --allow-empty
git commit -m x -- --allow-empty
git commit --allow-empty-message -m ""
git commit --allow-empty-message -m x
git commit --no-allow-empty -m x
git commit -m x
git commit --amend --no-edit
git commit
git -C /tmp/repo commit -m "gh run rerun"
git log --oneline --grep=allow-empty
echo "$(echo gh run rerun)"
EOF
allowed_each <<'EOF'
gh run list
gh run list --workflow rerun.yml
gh run view 123
gh run view 123 --log-failed
gh run watch 123
gh run download 123
gh run cancel 123
gh run delete 123
gh workflow list
gh workflow view ci.yml
gh workflow view run
gh workflow enable ci.yml
gh workflow disable ci.yml
gh api repos/o/r/actions/runs/123
gh api repos/o/r/actions/runs/123/jobs
gh api repos/o/r/actions/workflows
gh api repos/o/r/actions/runs/123/rerun
gh api -X GET repos/o/r/actions/runs/123/rerun
gh api --method GET repos/o/r/actions/workflows/ci.yml/dispatches -f ref=main
gh api repos/o/r/issues/1/comments -f body="please gh run rerun"
gh api repos/o/r/issues/1/comments -f body="see /actions/runs/1/rerun"
gh api repos/o/r/issues/1/comments -X POST -f body=x
gh api graphql -f query='{viewer{login}}'
gh pr create --title "no gh run rerun" --body "x"
gh issue comment 5 --body "gh workflow run is denied"
gh --version
gh auth status
EOF
allowed $'git commit -m "$(cat <<\'EOF\'\nfix: never gh run rerun, never git commit --allow-empty\nEOF\n)"' "a heredoc commit message that mentions the forms"
allowed $'cat > retry.sh <<\'EOF\'\ngit commit --allow-empty -m x\ngh run rerun 1\nEOF' "writing a script that holds the forms (data fed to cat, not to a shell)"
allowed $'cat <<EOF\ngh workflow run ci.yml\nEOF' "a heredoc fed to cat"
allowed $'echo start\ngrep -n rerun log.txt' "a trigger word in a later line's argument"

echo "-- 5. the deny text: the two messages, and how the OPERATOR lifts the guard --"
run_hook 'git commit --allow-empty -m x' "$PLUGIN"
ERR1="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
if printf '%s' "$ERR1" | grep -q 'empty commits to retrigger CI waste minutes' && printf '%s' "$ERR1" | grep -q 'fix the failing test or report it'; then ok "an empty commit: 'empty commits to retrigger CI waste minutes; fix the failing test or report it'"; else bad "empty-commit deny text: $ERR1"; fi
run_hook 'gh run rerun 123 --failed' "$PLUGIN"
ERR2="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
if printf '%s' "$ERR2" | grep -q 'a flaky failure is a defect' && printf '%s' "$ERR2" | grep -q 'count steps, not seconds' && printf '%s' "$ERR2" | grep -q 'mark it local-only' && printf '%s' "$ERR2" | grep -q 'or report it' && printf '%s' "$ERR2" | grep -q 'never re-roll CI'; then ok "a CI re-run: a flaky failure is a defect -- fix it (count steps, not seconds, or mark it local-only) or report it; never re-roll CI"; else bad "rerun deny text: $ERR2"; fi
if printf '%s' "$ERR2" | grep -q 'gh run rerun'; then ok "the deny names the form that tripped it"; else bad "deny does not name the form: $ERR2"; fi
for e in "$ERR1" "$ERR2"; do
  printf '%s' "$e" | grep -q 'HMD_CI_RERUN_ALLOW=1' && printf '%s' "$e" | grep -q 'environment Claude Code runs in' && printf '%s' "$e" | grep -q 'inline' && printf '%s' "$e" | grep -q 'not a security boundary' && printf '%s' "$e" | grep -q 'wall-clock speed of a shared runner' || ERR_BAD="${ERR_BAD:-} [$e]"
done
if [ -z "${ERR_BAD:-}" ]; then ok "both denies tell the operator: HMD_CI_RERUN_ALLOW=1 in the environment Claude Code runs in (an inline prefix does not reach the hook), not a security boundary, tests must not depend on the wall-clock speed of a shared runner"; else bad "deny footer:${ERR_BAD:-}"; fi

echo "-- 6. HMD_CI_RERUN_ALLOW=1 (the hook's OWN environment) lifts the guard; anything else leaves it on --"
OV=0; OV_BAD=""
for form in 'git commit --allow-empty -m x' 'gh run rerun 123 --failed' 'gh workflow run ci.yml' 'gh api -X POST repos/o/r/actions/runs/1/rerun' 'sh -c "git commit --allow-empty -m x"'; do
  OV=$((OV + 1)); run_hook "$form" "$PLUGIN" HMD_CI_RERUN_ALLOW=1
  { [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; } || OV_BAD="$OV_BAD [$form: rc=$RC $(head -c 120 "$TMPROOT/err")]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_CI_RERUN_ALLOW=1: all $OV forms are allowed, silently"; else bad "override 1:$OV_BAD"; fi
OV_BAD=""
for v in 0 '' true yes on ' 1' 1x 11 TRUE; do
  run_hook 'git commit --allow-empty -m x' "$PLUGIN" "HMD_CI_RERUN_ALLOW=$v"
  { [ "$RC" = 2 ] && grep -q 'hmd CI waste guard' "$TMPROOT/out"; } || OV_BAD="$OV_BAD [$v: rc=$RC]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_CI_RERUN_ALLOW=0, empty, true, yes, on, ' 1', 1x, 11 and TRUE all leave it ON: only exactly 1 lifts it"; else bad "override other values:$OV_BAD"; fi
rm -f "$MARK"
run_hook 'git commit --allow-empty -m x' "$STUB_OK" HMD_CI_RERUN_ALLOW=1
if [ "$RC" = 0 ] && [ ! -e "$MARK" ]; then ok "with the override on, the helper is never even started"; else bad "override still ran the helper: rc=$RC mark=$([ -e "$MARK" ] && echo yes || echo no)"; fi

echo "-- 7. FAILS OPEN (a cost guard, not a security gate): what it cannot read or run is a warning and an allow --"
warned 'echo "gh run rerun' "an unbalanced quote that mentions a trigger" 'unbalanced quote'
warned $'echo $\'rerun\'' "ANSI-C quoting, which is not decoded" 'ANSI-C'
warned $'cat <<EOF\n$(echo rerun)\nEOF' "an unquoted heredoc whose body runs a substitution" 'heredoc'
DEEP='git commit --allow-empty -m x'
for i in 1 2 3 4 5 6 7 8 9 10; do DEEP="sh <<E$i"$'\n'"$DEEP"$'\n'"E$i"; done
warned "$DEEP" "shell strings nested ten deep (past the depth it reads)" 'nested more than 8 deep'
DEEPSUB="$(python3 -I -c 'print("$(" * 4000 + "git commit --allow-empty")')"
warned "$DEEPSUB" "4000 nested substitutions: the lexer's recursion error is an allow with a warning, not a crash and not a deny" 'internal error'
LONGCMD="$(python3 -I -c 'print("echo allow-empty; " + "echo x; " * 3000)')"
warned "$LONGCMD" "a command that takes longer than HMD_CI_GUARD_TIMEOUT_S to read (1 ms here)" 'took longer' "$PLUGIN" HMD_CI_GUARD_TIMEOUT_S=0.001
denied 'git commit --allow-empty -m "unbalanced' "a form it READ wins over a quote it could not close"
denied 'gh run rerun 5; echo "unbalanced' "a form before an unbalanced quote is still found"
warned 'git commit --allow-empty -m x' "a helper that crashes (exit 1)" 'the guard itself failed (exit 1)' "$STUB_CRASH"
warned 'gh run rerun 5' "a helper that crashes, for a gh form" 'the guard itself failed (exit 1)' "$STUB_CRASH"
warned 'gh run rerun 5' "a helper that prints garbage and exits 7" 'the guard itself failed (exit 7)' "$STUB_GARBAGE"
warned 'gh run rerun 5' "a helper that exits 4: its reason is the warning" 'a odd command the stub could not read' "$STUB_UNREAD"
warned 'gh run rerun 5' "no helper in the plugin root" 'the guard itself failed' "$NOHELPER"
warned 'gh run rerun 5' "a helper whose import is missing (no hmd_kill_guard.py beside it)" 'the guard itself failed' "$NOKILL"
N=$((N + 1)); run_hook 'gh run rerun 5' "$STUB_SILENT"
if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ]; then ok "$N. a helper that says nothing and exits 0: allowed"; else bad "$N. silent helper: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'gh run rerun 5' "$STUB_DENY"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: a \"quoted\" back\\slash reason. ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a reason with a quote and a backslash still makes valid JSON (escaped by jq, verbatim in the verdict)"; else bad "$N. deny escaping: rc=$RC out=$(head -c 300 "$TMPROOT/out")"; fi

echo "-- 8. the pre-filter: python starts only for a command that mentions a trigger word --"
PF_BAD=""
for form in 'ls -la' 'git status' 'git commit -m "fix the flaky test"' 'gh run list' 'gh workflow list' 'gh pr view 5' 'echo hello world' 'bash test/x.sh'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ ! -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "ls, git status, an ordinary commit, gh run list / workflow list / pr view, echo, a script run: the helper is never started"; else bad "pre-filter let ordinary commands through to python:$PF_BAD"; fi
PF_BAD=""
for form in 'git commit --allow-empty -m x' 'git commit --allow-"empty" -m x' 'gh run rerun 1' 'gh run re"run" 1' 'gh api repos/o/r/dispatches -f a=b' 'gh api -X POST repos/o/r/check-runs/1/rerequest' 'gh workflow run ci.yml' 'gh  workflow   run ci.yml'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "each trigger (allow-empty, rerun, dispatches, rerequest, workflow ... run), also split by quotes or by extra spaces: the helper IS started"; else bad "pre-filter missed a trigger:$PF_BAD"; fi

echo "-- 9. the guard sits FIRST in the chain: a refused command never reaches git-guard or the secret scan --"
rm -f "$TMPROOT/scan.ran" "$TMPROOT/guard.ran"
run_hook 'git commit --allow-empty -m x' "$ORDER"
if [ "$RC" = 2 ] && [ ! -e "$TMPROOT/scan.ran" ] && [ ! -e "$TMPROOT/guard.ran" ]; then ok "a denied empty commit: neither the secret scan nor git-guard ran"; else bad "ordering: rc=$RC scan=$([ -e "$TMPROOT/scan.ran" ] && echo ran || echo no) guard=$([ -e "$TMPROOT/guard.ran" ] && echo ran || echo no)"; fi
rm -f "$TMPROOT/scan.ran" "$TMPROOT/guard.ran"
run_hook 'git commit -m "gh run rerun is denied"' "$ORDER"
if [ "$RC" = 0 ] && [ -e "$TMPROOT/scan.ran" ] && [ -e "$TMPROOT/guard.ran" ]; then ok "a commit that only mentions a form: allowed, and the scan and git-guard DID run (so the recorders above are live, not vacuous)"; else bad "ordering control: rc=$RC scan=$([ -e "$TMPROOT/scan.ran" ] && echo ran || echo no) guard=$([ -e "$TMPROOT/guard.ran" ] && echo ran || echo no)"; fi

echo "-- 10. the REAL plugin root (the files as shipped), not a copy --"
N=$((N + 1)); run_hook 'git commit --allow-empty -m "retrigger CI"' "$REPO"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the shipped hook and libs deny an empty commit"; else bad "$N. real root, empty commit: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'gh run rerun 123 --failed' "$REPO"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the shipped hook and libs deny a CI re-run"; else bad "$N. real root, rerun: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi

echo "-- 11. wiring: the docs agents read name the rule and the guard --"
if grep -q 'HMD_CI_RERUN_ALLOW' "$REPO/CLAUDE.md" && grep -q 'bin/lib/hmd_ci_guard.py' "$REPO/CLAUDE.md" && grep -q 'test/ci-waste-guard.test.sh' "$REPO/CLAUDE.md"; then ok "CLAUDE.md describes the guard: the override, the lib, and this test"; else bad "CLAUDE.md does not name HMD_CI_RERUN_ALLOW, bin/lib/hmd_ci_guard.py and test/ci-waste-guard.test.sh"; fi
DOC_BAD=""
for f in skills/heimdall/references/definition-of-done.md agents/coder.md agents/fixer.md; do
  { grep -q 'CI waste guard' "$REPO/$f" && grep -q 'wall-clock speed of a shared runner' "$REPO/$f" && grep -q 'gh run rerun' "$REPO/$f"; } || DOC_BAD="$DOC_BAD $f"
done
if [ -z "$DOC_BAD" ]; then ok "the definition of done, agents/coder.md and agents/fixer.md carry the rule: no empty commit or re-run to retrigger CI, a flaky test is fixed or reported, a test must not depend on the wall-clock speed of a shared runner"; else bad "rule missing from:$DOC_BAD"; fi

printf '\n  forms through the real hook: %d denied, %d allowed (plus the override, fail-open, ordering and wiring cases)\n' "$D_FORMS" "$A_FORMS"
printf '  ci-waste-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
