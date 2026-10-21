#!/usr/bin/env bash
# shellcheck disable=SC2016  # the payloads fed to the hook are literal text: $VAR, $(...) and backticks must NOT expand here
# test/sweep-guard.test.sh
#
# A FULL sweep (test/run-all.sh, 45-60 min) that the records on disk already answer is denied by the Bash hook, not asked nicely by prose.
#
# 2026-10-21 -- CLAUDE.md ("When the full gate runs", "Release convergence") already says when a full sweep is worth it, and prose did not hold: sweeps
# were started after a red one (instead of --failed), at a HEAD already proven green, and on top of a sweep that was still running. Operator: enforce the
# sweep part MECHANICALLY in the Bash PreToolUse hook. bin/heimdall-precheck-bash now asks bin/lib/hmd_sweep_guard.py (after the CI waste guard and the
# disk floor), which reads the command the way a shell does -- it reuses bin/lib/hmd_kill_guard.py's lexer -- and then reads the repo's own records.
# This drives the REAL hook with JSON payloads against fixture repos and receipts, in a throwaway plugin root (the real hook and libs, a tracker that does
# nothing, a closure engine that prints the salt it is given), and pins:
#   * a FULL sweep (no --failed, --since-green, --filter <regex>, --dry-run, -h) is DENIED when
#       - a sweep is running (receipts/sweep.lock names a live pid)                        "a sweep is already running (pid N)"
#       - the last receipt is red or aborted and its head_sha is HEAD or an ancestor        "last sweep was red at <sha>; fix, commit, then: bash test/run-all.sh --failed"
#       - a green full receipt already covers HEAD, the tree clean (hook-owned commits and records do not count) "already proven green at HEAD; nothing to re-test"
#   * what stays allowed: --failed, --since-green, --filter, --dry-run, help, single suites; --cold while the cache is cold anyway (the salt changed);
#     text that only MENTIONS run-all.sh (echo, grep, cat, git add, a commit message); a green receipt of an older HEAD; a dirty tree
#   * the repo is the one the SCRIPT belongs to (an absolute path, `cd dir &&`, HEIMDALL_HOME inline or in the hook's environment), never the payload's cwd
#   * HMD_SWEEP_ALLOW=1, read from the hook's OWN environment, lifts it (nothing runs); an inline prefix does not; anything but 1 leaves it on
#   * it FAILS OPEN (a cost guard, not a security gate): a missing or garbled receipt, a git failure, a helper that crashes, a command it cannot read,
#     a timeout: one stderr line and an allow -- while a form it DID read wins over what it could not read
#   * the pre-filter (python starts only for a command that mentions run-all), and the guard's place in the chain (after the CI waste guard and the disk floor)
# The guard is a COST control and BEST EFFORT, not a security boundary: no text guard on shell is complete.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precheck-bash"
HELPER="$REPO/bin/lib/hmd_sweep_guard.py"
PASS=0
FAIL=0
N=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# what the operator exports in their own shell never changes a case; a case that needs a setting passes it
unset HEIMDALL_HOME HMD_COLD HMD_SWEEP_ALLOW HMD_SWEEP_GUARD_TIMEOUT_S HMD_CI_RERUN_ALLOW HMD_KILL_GUARD SWEEP_TEST_SALT

TMPROOT="$(mktemp -d)" || exit 1
SLEEPER=""
trap 'rm -rf "$TMPROOT"; [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null' EXIT

echo "sweep-guard"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
command -v git >/dev/null 2>&1 || { bad "0. git is required"; exit 1; }
[ -f "$HOOK" ] || { bad "0. bin/heimdall-precheck-bash is missing"; exit 1; }
if [ -f "$HELPER" ] && python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null; then ok "0. bin/lib/hmd_sweep_guard.py exists and parses"; else bad "0. bin/lib/hmd_sweep_guard.py is missing or does not parse"; fi
if bash -n "$HOOK" 2>/dev/null; then ok "0. bin/heimdall-precheck-bash parses"; else bad "0. bin/heimdall-precheck-bash does not parse"; fi

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4s a call, and this suite starts python for most of its cases
PYREAL="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$TMPROOT/pybin"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then ln -s "$PYREAL" "$TMPROOT/pybin/python3"; fi
export PATH="$TMPROOT/pybin:$PATH"

# Throwaway plugin roots: the REAL hook and libs, a tracker that does nothing, and a closure engine that prints $SWEEP_TEST_SALT (the guard asks the PLUGIN's engine, never the repo's).
mkroot() {  # mkroot <dir> [python source of a stub helper]
  local d="$1"
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  cp "$REPO/bin/lib/hmd_sweep_guard.py" "$d/bin/lib/hmd_sweep_guard.py" 2>/dev/null
  cp "$REPO/bin/lib/hmd_kill_guard.py" "$d/bin/lib/hmd_kill_guard.py" 2>/dev/null
  cp "$REPO/bin/lib/hook-owned-path.sh" "$d/bin/lib/hook-owned-path.sh" 2>/dev/null
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/parallelism-tracker"
  cat >"$d/bin/heimdall-suite-closure" <<'EOF'
#!/bin/sh
[ "$1" = salt ] || exit 2
[ -n "${SWEEP_TEST_SALT:-}" ] || exit 1
printf '%s\n' "$SWEEP_TEST_SALT"
EOF
  chmod +x "$d/bin/heimdall-precheck-bash" "$d/bin/parallelism-tracker" "$d/bin/heimdall-suite-closure"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" >"$d/bin/lib/hmd_sweep_guard.py"; fi
}
PLUGIN="$TMPROOT/plugin"
mkroot "$PLUGIN"
MARK="$TMPROOT/helper.ran"
STUB_OK="$TMPROOT/plugin-stub-ok";       mkroot "$STUB_OK" 'import os
open(os.environ["SWEEP_STUB_MARK"], "a").write("ran\n")
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
sys.stdout.write("an odd command the stub could not read\n")
sys.exit(4)'
NOHELPER="$TMPROOT/plugin-nohelper"; mkroot "$NOHELPER"; rm -f "$NOHELPER/bin/lib/hmd_sweep_guard.py"
NOKILL="$TMPROOT/plugin-nokill"; mkroot "$NOKILL"; rm -f "$NOKILL/bin/lib/hmd_kill_guard.py"
NOENGINE="$TMPROOT/plugin-noengine"; mkroot "$NOENGINE"; rm -f "$NOENGINE/bin/heimdall-suite-closure"
# the same root plus the two guards that sit AHEAD of this one in the chain (the CI waste guard and the disk floor), to pin the order
ORDER="$TMPROOT/plugin-order"; mkroot "$ORDER"
for f in hmd_ci_guard.py hmd_push_target.py hmd_repo_receipt.py hmd_disk_floor.sh; do cp "$REPO/bin/lib/$f" "$ORDER/bin/lib/$f" 2>/dev/null; done

# ── the fixture repo: three commits (C1 base, C2 a code change, C3 a journal entry the hooks write) ─────────────────────────────────────────────────────────
FX="$TMPROOT/fx"
git_q() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mkdir -p "$FX/test" && git init -q "$FX" 2>/dev/null
printf '#!/bin/sh\nexit 0\n' >"$FX/test/run-all.sh"; printf 'one\n' >"$FX/a.txt"
git -C "$FX" add -A && git_q -C "$FX" commit -q -m "C1 base"
C1="$(git -C "$FX" rev-parse HEAD)"
BRANCH="$(git -C "$FX" symbolic-ref --short HEAD)"
printf 'two\n' >"$FX/a.txt"; git -C "$FX" add -A && git_q -C "$FX" commit -q -m "C2 code"
C2="$(git -C "$FX" rev-parse HEAD)"
mkdir -p "$FX/.planning/journal"; printf 'entry\n' >"$FX/.planning/journal/2026-10-21-haid_t.md"
git -C "$FX" add -A && git_q -C "$FX" commit -q -m "C3 journal"
C3="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" checkout -q -b side "$C1" && printf 'side\n' >"$FX/side.txt" && git -C "$FX" add -A && git_q -C "$FX" commit -q -m "S side"
CS="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" checkout -q "$BRANCH"
FXTOP="$(git -C "$FX" rev-parse --show-toplevel)"
[ "$(git -C "$FX" rev-parse HEAD)" = "$C3" ] && ok "0. fixture: HEAD is C3, C1 and C2 are its ancestors, S is on another branch" || bad "0. fixture repo is not as built" "HEAD=$(git -C "$FX" rev-parse HEAD) C3=$C3"

receipt() {  # receipt <home dir> <head_sha> <exit_code> <kind> <tree_clean> [extra json object]: a sweep receipt for the fixture repo
  local home="$1" extra="${6:-}"
  [ -n "$extra" ] || extra='{}'
  mkdir -p "$home/receipts"
  jq -n --arg repo "$FXTOP" --arg sha "$2" --argjson rc "$3" --arg kind "$4" --argjson clean "$5" --argjson extra "$extra" \
    '{finished_at: "2026-10-21T00:00:00Z", repo: $repo, head_sha: $sha, tree_clean: $clean, exit_code: $rc, kind: $kind} + $extra' >"$home/receipts/last-sweep.json"
}
FXH="$FX/.heimdall"
sleep 300 &
SLEEPER=$!
true & DEAD=$!; wait "$DEAD" 2>/dev/null

PAYLOAD_CWD="$FX"
RC=0
run_hook() {  # run_hook <command> <plugin root> [VAR=val ...]  -> RC, $TMPROOT/out (stdout), $TMPROOT/err (stderr)
  local cmd="$1" root="$2"
  shift 2
  # the payload is built from a file (--rawfile), so a command of any size is not an argument; HMD_MIN_FREE_PCT=0 keeps the disk floor out of it
  printf '%s' "$cmd" >"$TMPROOT/cmd.txt"
  jq -nc --rawfile c "$TMPROOT/cmd.txt" --arg cwd "$PAYLOAD_CWD" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $c}}' \
    | env -u HMD_SWEEP_ALLOW -u HEIMDALL_HOME -u HMD_COLD -u HMD_CI_RERUN_ALLOW -u HMD_KILL_GUARD -u HMD_SWEEP_GUARD_TIMEOUT_S -u SWEEP_TEST_SALT HMD_MIN_FREE_PCT=0 \
        CLAUDE_PLUGIN_ROOT="$root" SWEEP_STUB_MARK="$MARK" "$@" bash "$root/bin/heimdall-precheck-bash" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
}
VIA=hook  # hook: through the real hook (150 ms a case); helper: the throwaway root's copy of the helper alone (45 ms), where only what the records say is in question
via_helper() {  # via_helper <command> <plugin root> [VAR=val ...] -> RC (the helper's exit status), HOUT (its one line); the root's stub closure engine answers for the salt
  local cmd="$1" root="$2"
  shift 2
  HOUT="$(env "$@" python3 -I -S "$root/bin/lib/hmd_sweep_guard.py" "$PAYLOAD_CWD" <<<"$cmd" 2>"$TMPROOT/h.err")"
  RC=$?
}
denied() {  # denied <command> <label> <reason fragment> [VAR=val ...]: exit 2, a JSON {error} from THIS guard on stdout naming the fragment, the same verdict on stderr (helper: exit 3 and the reason)
  N=$((N + 1))
  if [ "$VIA" = helper ]; then
    via_helper "$1" "$PLUGIN" "${@:4}"
    if [ "$RC" = 3 ] && printf '%s' "$HOUT" | grep -qF -- "$3" && [ ! -s "$TMPROOT/h.err" ]; then ok "$N. denied: $2"; else bad "$N. NOT denied: $2" "rc=$RC out=$HOUT"; fi
    return
  fi
  run_hook "$1" "$PLUGIN" "${@:4}"
  if [ "$RC" = 2 ] && jq -e --arg f "$3" '.error | startswith("BLOCKED: hmd sweep guard: ") and contains($f)' "$TMPROOT/out" >/dev/null 2>&1 && grep -q 'hmd sweep guard' "$TMPROOT/err"; then
    ok "$N. denied: $2"
  else
    bad "$N. NOT denied: $2" "rc=$RC stdout=$(head -c 240 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
allowed() {  # allowed <command> <label> [VAR=val ...]: exit 0 and completely silent (no deny, no warning)
  N=$((N + 1))
  if [ "$VIA" = helper ]; then
    via_helper "$1" "$PLUGIN" "${@:3}"
    if [ "$RC" = 0 ] && [ "$HOUT" = ok ] && [ ! -s "$TMPROOT/h.err" ]; then ok "$N. allowed: $2"; else bad "$N. wrongly held: $2" "rc=$RC out=$HOUT"; fi
    return
  fi
  run_hook "$1" "$PLUGIN" "${@:3}"
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then
    ok "$N. allowed: $2"
  else
    bad "$N. wrongly held: $2" "rc=$RC stdout=$(head -c 240 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
warned() {  # warned <command> <label> <fragment of the warning> [plugin root] [VAR=val ...]: allowed (exit 0, stdout empty), one stderr line that says why nothing was checked (helper: exit 4 and the reason)
  N=$((N + 1))
  if [ "$VIA" = helper ]; then
    via_helper "$1" "${4:-$PLUGIN}" "${@:5}"
    if [ "$RC" = 4 ] && printf '%s' "$HOUT" | grep -qF -- "$3" && [ ! -s "$TMPROOT/h.err" ]; then ok "$N. could not tell (allowed with a warning): $2"; else bad "$N. not 'could not tell': $2" "rc=$RC out=$HOUT"; fi
    return
  fi
  run_hook "$1" "${4:-$PLUGIN}" "${@:5}"
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && grep -q 'heimdall sweep guard: ' "$TMPROOT/err" && grep -qF -- "$3" "$TMPROOT/err" && grep -q 'no sweep check for this command, allowing' "$TMPROOT/err"; then
    ok "$N. allowed with a warning: $2"
  else
    bad "$N. not 'allowed with a warning': $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"
  fi
}

# The helper alone: command text on stdin, the shell's directory as the one argument. Many command FORMS are pinned here (45 ms each) rather than through the hook (150 ms each).
hv() {  # hv <command> [cwd] -> HRC, HOUT
  HOUT="$(python3 -I -S "$HELPER" "${2:-$FX}" <<<"$1" 2>"$TMPROOT/h.err")"
  HRC=$?
}
group_denied() {  # group_denied <label> <reason fragment> [cwd]; one command per line on stdin; every one must be exit 3 and ONE reason line holding the fragment
  local form bad_forms="" n=0
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    n=$((n + 1)); hv "$form" "${3:-$FX}"
    { [ "$HRC" = 3 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$HOUT" | grep -qF -- "$2" && [ ! -s "$TMPROOT/h.err" ]; } || bad_forms="$bad_forms [$form: rc=$HRC $HOUT]"
  done
  N=$((N + 1))
  if [ -z "$bad_forms" ] && [ "$n" -gt 0 ]; then ok "$N. denied, all $n forms: $1"; else bad "$N. forms NOT denied: $1" "${bad_forms:-no forms}"; fi
}
group_ok() {  # group_ok <label> [cwd]; one command per line on stdin; every one must be exit 0 and `ok`, with nothing on stderr
  local form bad_forms="" n=0
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    n=$((n + 1)); hv "$form" "${2:-$FX}"
    { [ "$HRC" = 0 ] && [ "$HOUT" = ok ] && [ ! -s "$TMPROOT/h.err" ]; } || bad_forms="$bad_forms [$form: rc=$HRC $HOUT]"
  done
  N=$((N + 1))
  if [ -z "$bad_forms" ] && [ "$n" -gt 0 ]; then ok "$N. allowed, all $n forms: $1"; else bad "$N. forms wrongly held: $1" "${bad_forms:-no forms}"; fi
}

echo "-- 1. the helper alone: exit 0 + ok, exit 3 + ONE reason line (deny), exit 4 + a reason (could not tell) --"
receipt "$FXH" "$C3" 1 full false
hv 'bash test/run-all.sh'
if [ "$HRC" = 3 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && [ "$HOUT" = "last sweep was red at ${C3:0:12}; fix, commit, then: bash test/run-all.sh --failed" ] && [ ! -s "$TMPROOT/h.err" ]; then ok "a full sweep after a red one: exit 3 and ONE reason line"; else bad "helper, red: rc=$HRC out=$HOUT err=$(head -c 200 "$TMPROOT/h.err")"; fi
hv 'git status && ls'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ] && [ ! -s "$TMPROOT/h.err" ]; then ok "an ordinary command: exit 0 and 'ok'"; else bad "helper, ordinary: rc=$HRC out=$HOUT"; fi
hv 'echo "bash test/run-all.sh'
if [ "$HRC" = 4 ] && [ "$(printf '%s\n' "$HOUT" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$HOUT" | grep -q 'unbalanced quote'; then ok "an unbalanced quote that mentions run-all: exit 4 and the reason it could not be read"; else bad "helper, unbalanced: rc=$HRC out=$HOUT"; fi

echo "-- 2. DENIED after a red sweep: every way of typing a FULL run, behind wrappers, chains and shells --"
group_denied "a plain full sweep, with flags that do not make it partial" "last sweep was red at ${C3:0:12}; fix, commit, then: bash test/run-all.sh --failed" <<'EOF'
bash test/run-all.sh
bash test/run-all.sh --wait-quiet
bash test/run-all.sh --include-live --jobs 4
bash test/run-all.sh --jobs 2 --timeout 600 --no-retry
bash test/run-all.sh --fail-fast
bash test/run-all.sh --no-cache
bash test/run-all.sh --filter ""
bash test/run-all.sh --wait-quiet 2>&1 | tail -20
sh test/run-all.sh
zsh test/run-all.sh
bash -x test/run-all.sh
bash -e -u -o pipefail test/run-all.sh
bash --norc test/run-all.sh
/bin/bash test/run-all.sh
./test/run-all.sh
test/run-all.sh --wait-quiet
"./test/run-all.sh"
bash "test/run-all.sh"
bash 'test/run-all.sh'
bash test/run-all.sh # the whole thing
EOF
group_denied "behind env assignments, wrappers and chains" "last sweep was red at" <<'EOF'
FOO=1 bash test/run-all.sh
env FOO=1 bash test/run-all.sh
HMD_COLD=0 bash test/run-all.sh
time bash test/run-all.sh
nohup bash test/run-all.sh &
caffeinate -i bash test/run-all.sh
timeout 7200 bash test/run-all.sh
nice -n 5 bash test/run-all.sh
command bash test/run-all.sh
sudo -u bob bash test/run-all.sh
echo go | xargs bash test/run-all.sh
git status && bash test/run-all.sh
git status; bash test/run-all.sh
false || bash test/run-all.sh
(bash test/run-all.sh)
{ bash test/run-all.sh; }
if true; then bash test/run-all.sh; fi
for i in 1; do bash test/run-all.sh; done
x=$(bash test/run-all.sh)
sh -c "bash test/run-all.sh"
bash -lc 'bash test/run-all.sh --jobs 3'
eval "bash test/run-all.sh"
source test/run-all.sh
. test/run-all.sh
EOF
hv $'echo start\nbash test/run-all.sh'
if [ "$HRC" = 3 ]; then ok "after a newline"; else bad "after a newline: rc=$HRC $HOUT"; fi
hv $'bash \\\n  test/run-all.sh \\\n  --wait-quiet'
if [ "$HRC" = 3 ]; then ok "a continued line"; else bad "continued line: rc=$HRC $HOUT"; fi
hv $'bash <<EOF\nbash test/run-all.sh\nEOF'
if [ "$HRC" = 3 ]; then ok "a heredoc fed to a shell"; else bad "heredoc fed to a shell: rc=$HRC $HOUT"; fi
group_denied "the repo comes from the SCRIPT: an absolute path, cd, a subshell cd" "last sweep was red at" "$TMPROOT" <<EOF
bash $FX/test/run-all.sh
$FX/test/run-all.sh --jobs 4
cd $FX && bash test/run-all.sh
cd "$FX"; bash test/run-all.sh
cd $FX/test && bash run-all.sh
cd $FX/test && bash ./run-all.sh
cd $FX && cd test && bash run-all.sh
bash -c "cd $FX && bash test/run-all.sh"
EOF

echo "-- 3. ALLOWED while the last sweep is red: partial runs, runs that stop before a suite, single suites, text that only MENTIONS run-all.sh --"
group_ok "--failed, --since-green, --filter <regex>, --dry-run, help: not a full sweep" <<'EOF'
bash test/run-all.sh --failed
bash test/run-all.sh --failed --jobs 4
bash test/run-all.sh --since-green
bash test/run-all.sh --filter statusline
bash test/run-all.sh --filter 'foo|bar' --jobs 2
bash test/run-all.sh --jobs 2 --filter x
bash test/run-all.sh --dry-run
bash test/run-all.sh --dry-run --since-green
bash test/run-all.sh --help
bash test/run-all.sh -h
HMD_COLD=1 bash test/run-all.sh --failed
cd test && bash run-all.sh --failed
sh -c "bash test/run-all.sh --failed"
EOF
group_ok "single suites and other scripts: not the sweep" <<'EOF'
bash test/a.test.sh
bash test/sweep-guard.test.sh
./test/a.test.sh
bash scripts/run-tests.sh
bash test/lib/run-all-guards.sh
python3 test/lib/foo_cases.py
EOF
group_ok "text that only mentions run-all.sh (echo, printf, grep, cat, sed, git add, a commit message, a script written to disk)" <<'EOF'
echo "bash test/run-all.sh"
echo bash test/run-all.sh
printf '%s\n' "run bash test/run-all.sh when done"
grep -rn "run-all.sh" docs/
grep -n run-all CLAUDE.md
cat test/run-all.sh
sed -n '1,20p' test/run-all.sh
head -5 test/run-all.sh
wc -l test/run-all.sh
ls -la test/run-all.sh
git add test/run-all.sh
git diff -- test/run-all.sh
git log --oneline -- test/run-all.sh
git commit -m "fix: run-all.sh now bash test/run-all.sh --failed"
bash -n test/run-all.sh
bash -nx test/run-all.sh
shellcheck test/run-all.sh
vim test/run-all.sh
chmod +x test/run-all.sh
cp test/run-all.sh /tmp/x.sh
echo "$(echo bash test/run-all.sh)"
EOF
hv $'git commit -m "$(cat <<\'EOF\'\nfix: never start bash test/run-all.sh twice\nEOF\n)"'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ]; then ok "a heredoc commit message that mentions the sweep"; else bad "heredoc commit message: rc=$HRC $HOUT"; fi
hv $'cat > go.sh <<\'EOF\'\nbash test/run-all.sh\nEOF'
if [ "$HRC" = 0 ] && [ "$HOUT" = ok ]; then ok "a script that holds the sweep written to disk (data fed to cat, not to a shell)"; else bad "script written to disk: rc=$HRC $HOUT"; fi

echo "-- 4. the rules against the fixture's records: red, green, hook-owned commits, dirty tree, a receipt of other history (sections 4-7: the helper alone; 8-13: through the real hook) --"
VIA=helper
receipt "$FXH" "$C3" 1 full false
denied 'bash test/run-all.sh' "red at HEAD: a full sweep is held, --failed is the way" "last sweep was red at ${C3:0:12}; fix, commit, then: bash test/run-all.sh --failed"
receipt "$FXH" "$C1" 1 full true
denied 'bash test/run-all.sh' "red at an ANCESTOR of HEAD (the fix is committed, the red is still the last word)" "last sweep was red at ${C1:0:12}; fix, commit, then: bash test/run-all.sh --failed"
receipt "$FXH" "$C3" 1 aborted true '{"aborted": {"reason": "fail-fast", "suites_not_run": 40}}'
denied 'bash test/run-all.sh' "an ABORTED receipt (exit_code or not) is red" "last sweep was red at ${C3:0:12}"
receipt "$FXH" "$C3" 0 aborted true
denied 'bash test/run-all.sh' "an ABORTED receipt is red even with a forged exit_code 0" "last sweep was red at ${C3:0:12}"
receipt "$FXH" "$CS" 1 full false
allowed 'bash test/run-all.sh' "a red receipt of a commit that is NOT an ancestor of HEAD (other history) says nothing about this tree"
receipt "$FXH" "$C3" 0 full true
denied 'bash test/run-all.sh' "a green full receipt at HEAD, tree clean: nothing to re-test" "already proven green at HEAD; nothing to re-test"
receipt "$FXH" "$C2" 0 full true
denied 'bash test/run-all.sh' "a green full receipt, and only the hooks' own journal commit came after it (the push gate counts it fresh too)" "already proven green at HEAD; nothing to re-test"
receipt "$FXH" "$C1" 0 full true
allowed 'bash test/run-all.sh' "a green receipt of an OLDER head with a real code commit since: a new sweep is wanted"
receipt "$FXH" "$C3" 0 full false
allowed 'bash test/run-all.sh' "a green receipt that recorded a DIRTY tree proves nothing"
receipt "$FXH" "$C3" 0 incremental true '{"base_full_sha": "x"}'
allowed 'bash test/run-all.sh' "a green INCREMENTAL receipt is not a full proof: a full sweep may be wanted"
receipt "$FXH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false}, "full_equivalent": false}'
allowed 'bash test/run-all.sh' "a cache-composed receipt that is NOT full-equivalent is not a proof either"
receipt "$FXH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false}, "full_equivalent": true}'
denied 'bash test/run-all.sh' "a cache-composed receipt that IS full-equivalent counts" "already proven green at HEAD"
echo 'edit' >>"$FX/a.txt"
allowed 'bash test/run-all.sh' "green at HEAD but a tracked file has uncommitted changes: the tree is not what was proven"
git -C "$FX" checkout -q -- a.txt
printf 'new\n' >"$FX/newfile.txt"
allowed 'bash test/run-all.sh' "green at HEAD but an UNTRACKED file is there (a new suite, say): the sweep would include it"
rm -f "$FX/newfile.txt"
printf 'entry2\n' >"$FX/.planning/journal/2026-10-21-haid_other.md"
denied 'bash test/run-all.sh' "an untracked journal record the hooks write does not make the tree dirty" "already proven green at HEAD"
rm -f "$FX/.planning/journal/2026-10-21-haid_other.md"
printf 'x\n' >"$FX/.planning/journal/not-a-record.sh"
allowed 'bash test/run-all.sh' "an untracked file under .planning/journal that is NOT the shape the hooks write does count"
rm -f "$FX/.planning/journal/not-a-record.sh"
allowed 'bash test/run-all.sh --failed' "after a green: --failed is not held"
denied 'bash test/run-all.sh' "(control) the tree is clean again, so green at HEAD denies again" "already proven green at HEAD"
receipt "$FXH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false}, "full_equivalent": true}'

echo "-- 5. overlap: sweep.lock plus a live pid (checked FIRST, whatever the receipt says) --"
receipt "$FXH" "$C1" 0 full true
printf 'pid=%s\nrepo=%s\nstarted=2026-10-21T00:00:00+0000\n' "$SLEEPER" "$FXTOP" >"$FXH/receipts/sweep.lock"
denied 'bash test/run-all.sh' "the lock names a live pid (the receipt alone would allow this sweep)" "a sweep is already running (pid $SLEEPER)"
receipt "$FXH" "$C3" 1 full false
denied 'bash test/run-all.sh' "overlap wins over a red receipt: the more immediate fact" "a sweep is already running (pid $SLEEPER)"
printf 'pid=%s\nrepo=x\n' "$DEAD" >"$FXH/receipts/sweep.lock"
denied 'bash test/run-all.sh' "a dead pid in the lock is no sweep: the receipt decides (red here)" "last sweep was red at"
receipt "$FXH" "$C1" 0 full true
allowed 'bash test/run-all.sh' "a dead pid and a receipt that allows: allowed"
: >"$FXH/receipts/sweep.lock"
allowed 'bash test/run-all.sh' "an EMPTY lock file (what a finished sweep leaves behind) is no sweep"
printf 'garbage\npid=abc\n' >"$FXH/receipts/sweep.lock"
allowed 'bash test/run-all.sh' "a garbled lock file is no sweep"
printf 'pid=%s\n' "$SLEEPER" >"$FXH/receipts/sweep.lock"
allowed 'bash test/run-all.sh --failed' "--failed is allowed whatever the lock says (the runner refuses a second sweep itself)"
allowed 'bash test/run-all.sh --filter x' "--filter likewise"
rm -f "$FXH/receipts/sweep.lock"

echo "-- 6. --cold (or HMD_COLD=1) is allowed only while the cache is cold anyway: no cache entry carries the salt of HEAD --"
SALT1="$(printf 'a%.0s' $(seq 1 64))"; SALT2="$(printf 'b%.0s' $(seq 1 64))"
mkdir -p "$FXH/receipts/suite-cache"
printf '{"suite": "a.test.sh", "salt": "%s"}\n' "$SALT1" >"$FXH/receipts/suite-cache/a.test.sh.json"
receipt "$FXH" "$C3" 1 full false
denied 'bash test/run-all.sh --cold' "red, --cold, and the cache is WARM (an entry has the current salt): the cache did not force this" "last sweep was red at" SWEEP_TEST_SALT="$SALT1"
denied 'HMD_COLD=1 bash test/run-all.sh' "HMD_COLD=1 inline is --cold, so it gets the same answer" "last sweep was red at" SWEEP_TEST_SALT="$SALT1"
allowed 'bash test/run-all.sh --cold' "red, --cold, and the SALT CHANGED (no entry has it): every suite runs anyway" SWEEP_TEST_SALT="$SALT2"
allowed 'HMD_COLD=1 bash test/run-all.sh' "HMD_COLD=1 inline after a salt change" SWEEP_TEST_SALT="$SALT2"
denied 'bash test/run-all.sh' "a PLAIN full sweep after a salt change is still held: the exemption is for --cold only" "last sweep was red at" SWEEP_TEST_SALT="$SALT2"
rm -f "$FXH/receipts/suite-cache/a.test.sh.json"
allowed 'bash test/run-all.sh --cold' "red, --cold, and the cache is EMPTY: the next sweep is cold by itself" SWEEP_TEST_SALT="$SALT1"
printf '{"suite": "a.test.sh", "salt": "%s"}\n' "$SALT1" >"$FXH/receipts/suite-cache/a.test.sh.json"
printf 'not json\n' >"$FXH/receipts/suite-cache/b.test.sh.json"
denied 'bash test/run-all.sh --cold' "a garbled cache entry is skipped, the good one still shows the cache warm" "last sweep was red at" SWEEP_TEST_SALT="$SALT1"
warned 'bash test/run-all.sh --cold' "red + --cold and the plugin has no closure engine to ask for the salt" 'closure engine' "$NOENGINE"
warned 'bash test/run-all.sh --cold' "red + --cold and the engine fails (no salt printed)" 'salt' "$PLUGIN"
receipt "$FXH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": false}, "full_equivalent": true}'
allowed 'bash test/run-all.sh --cold' "green at HEAD but composed from the cache: a --cold sweep makes a different receipt (a cold one, which an x.y.0 ship needs)" SWEEP_TEST_SALT="$SALT1"
receipt "$FXH" "$C3" 0 full true '{"cache": {"mode": "closure", "cold": true}, "full_equivalent": true}'
denied 'bash test/run-all.sh --cold' "green at HEAD and ALREADY cold: a second cold sweep proves nothing new" "already proven green at HEAD" SWEEP_TEST_SALT="$SALT1"
receipt "$FXH" "$C3" 0 full true
denied 'bash test/run-all.sh --cold' "green at HEAD, a legacy receipt with no cache block (every suite ran)" "already proven green at HEAD" SWEEP_TEST_SALT="$SALT1"
allowed 'bash test/run-all.sh --cold' "green at HEAD, --cold, salt changed" SWEEP_TEST_SALT="$SALT2"
rm -rf "$FXH/receipts/suite-cache"

echo "-- 7. which repo: the one the SCRIPT belongs to (not the payload's cwd), and where the receipts live (HEIMDALL_HOME) --"
receipt "$FXH" "$C3" 1 full false
OTHER="$TMPROOT/other"; mkdir -p "$OTHER/test"; printf '#!/bin/sh\nexit 0\n' >"$OTHER/test/run-all.sh"; git init -q "$OTHER" 2>/dev/null
git -C "$OTHER" add -A && git_q -C "$OTHER" commit -q -m base
PAYLOAD_CWD="$OTHER"
denied "bash $FX/test/run-all.sh" "an absolute script path is judged by ITS repo, whatever the session's cwd is" "last sweep was red at"
denied "cd $FX && bash test/run-all.sh" "cd into the repo, then the sweep" "last sweep was red at"
warned 'bash test/run-all.sh' "the cwd is another repo with no receipt: nothing to compare with" 'no sweep receipt'
PAYLOAD_CWD="$FX"
HH="$TMPROOT/home"; mkdir -p "$HH"
receipt "$HH" "$C3" 1 full false
rm -rf "$FXH/receipts/last-sweep.json"
denied 'bash test/run-all.sh' "HEIMDALL_HOME in the hook's environment moves the receipts" "last sweep was red at" HEIMDALL_HOME="$HH"
denied "HEIMDALL_HOME=$HH bash test/run-all.sh" "HEIMDALL_HOME as an inline assignment moves them for that command" "last sweep was red at"
denied "env HEIMDALL_HOME=$HH bash test/run-all.sh" "HEIMDALL_HOME through env" "last sweep was red at"
allowed 'bash test/run-all.sh --failed' "(control) --failed with the same records"  HEIMDALL_HOME="$HH"
jq '.repo = "/somewhere/else"' "$HH/receipts/last-sweep.json" >"$HH/receipts/x.json" && mv "$HH/receipts/x.json" "$HH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a receipt recorded for ANOTHER checkout (a shared HEIMDALL_HOME) is not this tree's" 'another checkout' "$PLUGIN" HEIMDALL_HOME="$HH"
receipt "$FXH" "$C3" 1 full false

echo "-- 8. the deny text: the three messages, and how the OPERATOR lifts the guard --"
VIA=hook
run_hook 'bash test/run-all.sh' "$PLUGIN"
ERR1="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
if printf '%s' "$ERR1" | grep -qF "last sweep was red at ${C3:0:12}; fix, commit, then: bash test/run-all.sh --failed"; then ok "red: 'last sweep was red at <sha>; fix, commit, then: bash test/run-all.sh --failed'"; else bad "red deny text: $ERR1"; fi
receipt "$FXH" "$C3" 0 full true
run_hook 'bash test/run-all.sh' "$PLUGIN"
ERR2="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
if printf '%s' "$ERR2" | grep -qF 'already proven green at HEAD; nothing to re-test'; then ok "green: 'already proven green at HEAD; nothing to re-test'"; else bad "green deny text: $ERR2"; fi
printf 'pid=%s\n' "$SLEEPER" >"$FXH/receipts/sweep.lock"
run_hook 'bash test/run-all.sh' "$PLUGIN"
ERR3="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
rm -f "$FXH/receipts/sweep.lock"
if printf '%s' "$ERR3" | grep -qF "a sweep is already running (pid $SLEEPER)"; then ok "overlap: 'a sweep is already running (pid N)'"; else bad "overlap deny text: $ERR3"; fi
FOOT_BAD=""
for e in "$ERR1" "$ERR2" "$ERR3"; do
  printf '%s' "$e" | grep -q 'HMD_SWEEP_ALLOW=1' && printf '%s' "$e" | grep -q 'environment Claude Code runs in' && printf '%s' "$e" | grep -q 'inline' && printf '%s' "$e" | grep -q 'not a security boundary' && printf '%s' "$e" | grep -q -- '--failed' || FOOT_BAD="${FOOT_BAD} [$e]"
done
if [ -z "$FOOT_BAD" ]; then ok "all three denies tell the operator: HMD_SWEEP_ALLOW=1 in the environment Claude Code runs in (an inline prefix does not reach the hook), not a security boundary, --failed after a red"; else bad "deny footer:$FOOT_BAD"; fi

echo "-- 9. HMD_SWEEP_ALLOW=1 (the hook's OWN environment) lifts the guard; anything else leaves it on --"
receipt "$FXH" "$C3" 1 full false
OV=0; OV_BAD=""
for form in 'bash test/run-all.sh --wait-quiet' 'sh -c "bash test/run-all.sh"'; do
  OV=$((OV + 1)); run_hook "$form" "$PLUGIN" HMD_SWEEP_ALLOW=1
  { [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; } || OV_BAD="$OV_BAD [$form: rc=$RC $(head -c 120 "$TMPROOT/err")]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_SWEEP_ALLOW=1: all $OV forms are allowed, silently"; else bad "override 1:$OV_BAD"; fi
OV_BAD=""
for v in 0 '' true ' 1' 11; do
  run_hook 'bash test/run-all.sh' "$PLUGIN" "HMD_SWEEP_ALLOW=$v"
  { [ "$RC" = 2 ] && grep -q 'hmd sweep guard' "$TMPROOT/out"; } || OV_BAD="$OV_BAD [$v: rc=$RC]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_SWEEP_ALLOW=0, empty, true, ' 1' and 11 all leave it ON: only exactly 1 lifts it"; else bad "override other values:$OV_BAD"; fi
denied 'HMD_SWEEP_ALLOW=1 bash test/run-all.sh' "an INLINE HMD_SWEEP_ALLOW=1 reaches the sweep, not the hook that has already said no" "last sweep was red at"
rm -f "$MARK"
run_hook 'bash test/run-all.sh' "$STUB_OK" HMD_SWEEP_ALLOW=1
if [ "$RC" = 0 ] && [ ! -e "$MARK" ]; then ok "with the override on, the helper is never even started"; else bad "override still ran the helper: rc=$RC mark=$([ -e "$MARK" ] && echo yes || echo no)"; fi

echo "-- 10. FAILS OPEN (a cost guard, not a security gate): what it cannot read or run is a warning and an allow --"
receipt "$FXH" "$C3" 1 full false
warned 'echo "bash test/run-all.sh' "an unbalanced quote that mentions run-all" 'unbalanced quote'
warned $'echo $\'run-all\'' "ANSI-C quoting, which is not decoded" 'ANSI-C'
DEEP='bash test/run-all.sh'
for i in 1 2 3 4 5 6 7 8 9 10; do DEEP="sh <<E$i"$'\n'"$DEEP"$'\n'"E$i"; done
warned "$DEEP" "shell strings nested ten deep (past the depth it reads)" 'nested more than 8 deep'
LONGCMD="$(python3 -I -c 'print("echo run-all.sh; " + "echo x; " * 3000)')"
warned "$LONGCMD" "a command that takes longer than HMD_SWEEP_GUARD_TIMEOUT_S to read (1 ms here)" 'took longer' "$PLUGIN" HMD_SWEEP_GUARD_TIMEOUT_S=0.001
denied 'bash test/run-all.sh -m "unbalanced' "a form it READ wins over a quote it could not close" "last sweep was red at"
denied 'bash test/run-all.sh; echo "unbalanced' "a sweep before an unbalanced quote is still found" "last sweep was red at"
warned 'bash nosuch/test/run-all.sh' "a script that does not exist: nothing to compare" 'does not exist'
warned 'bash "$ROOT/test/run-all.sh"' "the script's path in a variable: which repo is unknown" 'variable'
warned 'bash test/run-all.sh $OPTS' "an option in a variable: whether it is a full sweep is unknown" 'variable'
warned 'cd "$SOMEWHERE" && bash test/run-all.sh' "a cd to a variable, then a relative script path" 'cannot be told'
warned 'cd - && bash test/run-all.sh' "cd - likewise" 'cannot be told'
rm -f "$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "no receipt at all (a checkout that never swept)" 'no sweep receipt'
printf 'not json at all\n' >"$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a receipt that is not JSON" 'not valid JSON'
printf '[1, 2]\n' >"$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a receipt that is JSON but not an object" 'not a JSON object'
printf '{"head_sha": "%s", "exit_code": "1", "kind": "full"}\n' "$C3" >"$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a receipt whose exit_code is not a number" 'exit_code'
printf '{"head_sha": "not-a-sha", "exit_code": 1, "kind": "full"}\n' >"$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a receipt that names no commit" 'no commit'
jq -n --arg r "$FXTOP" '{repo: $r, head_sha: "0123456789abcdef0123456789abcdef01234567", exit_code: 1, kind: "full", tree_clean: false}' >"$FXH/receipts/last-sweep.json"
warned 'bash test/run-all.sh' "a red receipt of a commit git does not know: git cannot place it" 'could not compare'
NOGIT="$TMPROOT/nogit"; mkdir -p "$NOGIT/test" "$NOGIT/.heimdall/receipts"; printf '#!/bin/sh\nexit 0\n' >"$NOGIT/test/run-all.sh"
jq -n --arg sha "$C3" '{repo: "/x", head_sha: $sha, exit_code: 1, kind: "full", tree_clean: false}' >"$NOGIT/.heimdall/receipts/last-sweep.json"
PAYLOAD_CWD="$NOGIT"
warned 'bash test/run-all.sh' "a directory that is not a git repository: git fails" 'git rev-parse failed'
PAYLOAD_CWD="$FX"
receipt "$FXH" "$C3" 1 full false
warned 'bash test/run-all.sh' "a helper that crashes (exit 1)" 'the guard itself failed (exit 1)' "$STUB_CRASH"
warned 'bash test/run-all.sh' "a helper that prints garbage and exits 7" 'the guard itself failed (exit 7)' "$STUB_GARBAGE"
warned 'bash test/run-all.sh' "a helper that exits 4: its reason is the warning" 'an odd command the stub could not read' "$STUB_UNREAD"
warned 'bash test/run-all.sh' "a helper whose import is missing (no hmd_kill_guard.py beside it)" 'the guard itself failed' "$NOKILL"
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$NOHELPER"
if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then ok "$N. no helper in the plugin root: allowed, completely silent"; else bad "$N. no helper: rc=$RC err=$(head -c 200 "$TMPROOT/err")"; fi
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$STUB_SILENT"
if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ]; then ok "$N. a helper that says nothing and exits 0: allowed"; else bad "$N. silent helper: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$STUB_DENY"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd sweep guard: a \"quoted\" back\\slash reason. ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a reason with a quote and a backslash still makes valid JSON (escaped by jq, verbatim in the verdict)"; else bad "$N. deny escaping: rc=$RC out=$(head -c 300 "$TMPROOT/out")"; fi

echo "-- 11. the pre-filter: python starts only for a command that mentions run-all --"
PF_BAD=""
for form in 'ls -la' 'git status' 'git commit -m "fix the flaky test"' 'bash test/a.test.sh' 'echo hello world' 'gh run list' 'bash scripts/run-tests.sh' 'npm run all'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ ! -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "ls, git status, an ordinary commit, a single suite, echo, gh run list, another script, npm run: the helper is never started"; else bad "pre-filter let ordinary commands through to python:$PF_BAD"; fi
PF_BAD=""
for form in 'bash test/run-all.sh' 'bash test/run-all.sh --failed' 'bash "test/run-all.sh"' 'echo run-all.sh' 'grep -rn run-all docs/' './test/run-all.sh --dry-run'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "every command that mentions run-all (a run, a partial run, a quoted path, a mere mention) starts the helper"; else bad "pre-filter missed a trigger:$PF_BAD"; fi

echo "-- 12. the guard sits AFTER the CI waste guard and the disk floor --"
N=$((N + 1)); run_hook 'bash test/run-all.sh; git commit --allow-empty -m retrigger' "$ORDER"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a command that is both an empty commit and a held sweep gets the CI waste guard's verdict"; else bad "$N. order vs CI waste guard: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$ORDER" HMD_MIN_FREE_PCT=100
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: disk floor: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a held sweep on a full disk gets the disk floor's verdict"; else bad "$N. order vs disk floor: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$ORDER"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd sweep guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. (control) with both ahead of it quiet, this guard answers"; else bad "$N. order control: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi

echo "-- 13. the REAL plugin root (the files as shipped), not a copy --"
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$REPO"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd sweep guard: last sweep was red at ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the shipped hook and libs deny a full sweep after a red one"; else bad "$N. real root, red: rc=$RC out=$(head -c 200 "$TMPROOT/out") err=$(head -c 200 "$TMPROOT/err")"; fi
receipt "$FXH" "$C3" 0 full true
N=$((N + 1)); run_hook 'bash test/run-all.sh' "$REPO"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd sweep guard: already proven green at HEAD; nothing to re-test")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the shipped hook and libs deny a full sweep at a HEAD already proven green"; else bad "$N. real root, green: rc=$RC out=$(head -c 200 "$TMPROOT/out") err=$(head -c 200 "$TMPROOT/err")"; fi

echo "-- 14. wiring: the docs agents read name the rule and the guard --"
if grep -q 'HMD_SWEEP_ALLOW' "$REPO/CLAUDE.md" && grep -q 'bin/lib/hmd_sweep_guard.py' "$REPO/CLAUDE.md" && grep -q 'test/sweep-guard.test.sh' "$REPO/CLAUDE.md"; then ok "CLAUDE.md describes the guard: the override, the lib, and this test"; else bad "CLAUDE.md does not name HMD_SWEEP_ALLOW, bin/lib/hmd_sweep_guard.py and test/sweep-guard.test.sh"; fi
# The bullet lives under [Unreleased] until a release stamps it into its version section, so look in any section.
if grep -q 'hmd_sweep_guard' "$REPO/CHANGELOG.md"; then ok "CHANGELOG.md has the bullet"; else bad "CHANGELOG.md does not mention hmd_sweep_guard"; fi
if grep -q 'HMD_SWEEP_ALLOW' "$HOOK" && grep -q 'hmd_sweep_guard.py' "$HOOK"; then ok "bin/heimdall-precheck-bash documents the switch and calls the helper"; else bad "the hook does not name HMD_SWEEP_ALLOW and hmd_sweep_guard.py"; fi

printf '\n  sweep-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
