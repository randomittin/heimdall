#!/usr/bin/env bash
# shellcheck disable=SC2016  # the payloads fed to the hook are literal text: $VAR, $(...) and backticks must NOT expand here
# test/wait-guard.test.sh
#
# An agent must never WAIT in the foreground for a job it will be told about: it blocks, re-polls and goes stale.
#
# 2026-11-10 -- docs/analysis/2026-11-10-stale-general-purpose-agents.md: agents that "went stale after 1-2 h" were not hung, they sat inside their own
# shell. 1355 foreground poll loops (167.8 h) in general-purpose agents and 940 (113.6 h) in hmd:coder: `until grep -q DONE f; do sleep 30; done`,
# `for i in $(seq 1 58); do grep -q X f && break; sleep 10; done`, `perl -e 'alarm 595; sleep 595'`, `while pgrep -f job; do sleep 5; done`, all waiting for
# a job the agent had itself put in the background. bin/heimdall-precheck-bash now asks bin/lib/hmd_wait_guard.py (after the CI waste guard, the disk
# floor and the sweep guard), which reads the command the way a shell does -- it reuses bin/lib/hmd_kill_guard.py's lexer. This drives the REAL hook with JSON
# payloads in a throwaway plugin root (the real hook, the real helper and its lexer, a tracker that does nothing), pins every form against the helper's own
# main() in ONE python process per group, and pins:
#   * what is DENIED: a loop (until, while, for) whose body or condition runs sleep, whatever the duration; a while/until loop whose condition polls pgrep or
#     kill -0; a standalone sleep of 60 s or more; an interpreter one-liner that sleeps with an alarm or for 60 s or more (perl -e 'alarm N; sleep N');
#     tail -f / tail -F -- through quotes, wrappers (env, nice, timeout, sudo, nohup, xargs), chains, pipes, subshells, substitutions, sh -c, eval and heredocs
#   * what stays ALLOWED: text that only MENTIONS a form (echo, grep, a commit message or its heredoc, a script written to disk), sleep under 60 s outside a loop,
#     loops without sleep, tail without a follow flag, perl -e 'alarm N; exec ...', and EVERYTHING when the Bash call has run_in_background: true
#   * the deny text: the three things the operator asked it to say, and how the OPERATOR lifts the guard
#   * HMD_WAIT_ALLOW=1, read from the hook's OWN environment, lifts it (nothing runs); an inline prefix does not; anything but 1 leaves it on
#   * it FAILS OPEN (a cost guard, not a security gate): a helper that is missing, crashes, prints garbage or times out, and a command it cannot read, are one
#     stderr line and an allow -- while a form it DID read wins over what it could not read
#   * the pre-filter (python starts only for a command that mentions sleep, alarm or tail -f), and the guard's place in the chain (after the CI waste guard,
#     the disk floor and the sweep guard)
#   * the suite can go RED: three one-line breaks of the helper each make a deny form pass
# The guard is a COST control and BEST EFFORT, not a security boundary: no text guard on shell is complete.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/bin/heimdall-precheck-bash"
HELPER="$REPO/bin/lib/hmd_wait_guard.py"
LIBS=(hmd_wait_guard.py hmd_kill_guard.py)
PASS=0
FAIL=0
N=0
D_FORMS=0
A_FORMS=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# what the operator exports in their own shell never changes a case; a case that needs a setting passes it
unset HMD_WAIT_ALLOW HMD_WAIT_GUARD_TIMEOUT_S HMD_CI_RERUN_ALLOW HMD_SWEEP_ALLOW HMD_KILL_GUARD HMD_MIN_FREE_PCT BG

TMPROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

echo "wait-guard"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
[ -f "$HOOK" ] || { bad "0. bin/heimdall-precheck-bash is missing"; exit 1; }
if [ -f "$HELPER" ] && python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null; then ok "0. bin/lib/hmd_wait_guard.py exists and parses"; else bad "0. bin/lib/hmd_wait_guard.py is missing or does not parse"; fi
if bash -n "$HOOK" 2>/dev/null; then ok "0. bin/heimdall-precheck-bash parses"; else bad "0. bin/heimdall-precheck-bash does not parse"; fi

# python3 straight to the real interpreter first on PATH: a version-manager shim (pyenv) costs ~0.4s a call, and this suite starts python for most hook cases
PYREAL="$(python3 -I -c 'import sys; print(sys.executable)' 2>/dev/null)"
mkdir -p "$TMPROOT/pybin"
if [ -n "$PYREAL" ] && [ -x "$PYREAL" ]; then ln -s "$PYREAL" "$TMPROOT/pybin/python3"; fi
export PATH="$TMPROOT/pybin:$PATH"

# Throwaway plugin roots holding ONLY the hook under test, so an allowed command is allowed by this chain alone and nothing real runs.
mkroot() {  # mkroot <dir> [python source of a stub helper]: the REAL hook, the REAL helper and the lexer it imports (or the stub), a tracker that does nothing
  local d="$1" f
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  for f in "${LIBS[@]}"; do cp "$REPO/bin/lib/$f" "$d/bin/lib/$f" 2>/dev/null; done
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/parallelism-tracker"
  chmod +x "$d/bin/heimdall-precheck-bash" "$d/bin/parallelism-tracker"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" >"$d/bin/lib/hmd_wait_guard.py"; fi
}
PLUGIN="$TMPROOT/plugin"
mkroot "$PLUGIN"
# helpers that misbehave, and one that records that it was started
MARK="$TMPROOT/helper.ran"
STUB_OK="$TMPROOT/plugin-stub-ok";       mkroot "$STUB_OK" 'import os
open(os.environ["WAIT_STUB_MARK"], "a").write("ran\n")
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
NOHELPER="$TMPROOT/plugin-nohelper"; mkroot "$NOHELPER"; rm -f "$NOHELPER/bin/lib/hmd_wait_guard.py"
NOKILL="$TMPROOT/plugin-nokill"; mkroot "$NOKILL"; rm -f "$NOKILL/bin/lib/hmd_kill_guard.py"
# the same root plus the three guards that sit AHEAD of this one in the chain (the CI waste guard, the disk floor, a sweep guard that always denies), to pin the order
ORDER="$TMPROOT/plugin-order"; mkroot "$ORDER"
for f in hmd_ci_guard.py hmd_push_target.py hmd_repo_receipt.py hmd_disk_floor.sh; do cp "$REPO/bin/lib/$f" "$ORDER/bin/lib/$f" 2>/dev/null; done
printf 'import sys\nsys.stdout.write("stub sweep reason\\n")\nsys.exit(3)\n' >"$ORDER/bin/lib/hmd_sweep_guard.py"

BG=""
RC=0
run_hook() {  # run_hook <command> <plugin root> [VAR=val ...]  -> RC, $TMPROOT/out (stdout), $TMPROOT/err (stderr); BG (true, false, "true" as a string) is run_in_background in the payload, unset = absent
  local cmd="$1" root="$2"
  shift 2
  # the payload is built from a file (--rawfile), so a command of any size is not an argument; HMD_MIN_FREE_PCT=0 keeps the disk floor out of it (this suite never
  # depends on the disk it runs on); what the operator exports in their own shell never changes a case, a case that needs a setting passes it
  printf '%s' "$cmd" >"$TMPROOT/cmd.txt"
  jq -nc --rawfile c "$TMPROOT/cmd.txt" --arg cwd "$TMPROOT" --argjson bg "${BG:-null}" \
      '{tool_name: "Bash", cwd: $cwd, tool_input: ({command: $c} + (if $bg == null then {} else {run_in_background: $bg} end))}' \
    | env -u HMD_WAIT_ALLOW -u HMD_CI_RERUN_ALLOW -u HMD_SWEEP_ALLOW -u HMD_KILL_GUARD -u HMD_WAIT_GUARD_TIMEOUT_S PATH="$TMPROOT/pybin:$PATH" HMD_MIN_FREE_PCT=0 \
        CLAUDE_PLUGIN_ROOT="$root" WAIT_STUB_MARK="$MARK" "$@" bash "$root/bin/heimdall-precheck-bash" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
}
denied() {  # denied <command> <label> [VAR=val ...]: exit 2, a JSON {error} from THIS guard on stdout, the same verdict on stderr
  N=$((N + 1))
  run_hook "$1" "$PLUGIN" "${@:3}"
  if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd wait guard: ")' "$TMPROOT/out" >/dev/null 2>&1 && grep -q 'hmd wait guard' "$TMPROOT/err"; then
    ok "$N. denied: $2"
  else
    bad "$N. NOT denied: $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 200 "$TMPROOT/err")"
  fi
}
allowed() {  # allowed <command> <label> [VAR=val ...]: exit 0 and completely silent (no deny, no warning)
  N=$((N + 1))
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
  if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && grep -q 'heimdall wait guard: ' "$TMPROOT/err" && grep -qF -- "$3" "$TMPROOT/err" && grep -q 'no wait check for this command, allowing' "$TMPROOT/err"; then
    ok "$N. allowed with a warning: $2"
  else
    bad "$N. not 'allowed with a warning': $2" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out") stderr=$(head -c 300 "$TMPROOT/err")"
  fi
}

# The helper's own main(), many forms to ONE python process (the hook costs ~120 ms a case, a python start ~45 ms; the whole suite aims at 10 s): the driver loads the helper
# as a module and runs main() on each form with that form on stdin, printing "<exit status> <lines it wrote> <what it wrote>". The real command line is pinned in section 1.
DRIVER="$TMPROOT/driver.py"
cat >"$DRIVER" <<'PYEOF'
import importlib.util
import io
import sys

spec = importlib.util.spec_from_file_location("wait_guard_under_test", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
real_out = sys.stdout
with open(sys.argv[2], "rb") as f:
    forms = f.read().decode("utf-8").split("\0")[:-1]
for form in forms:
    sys.stdin = io.TextIOWrapper(io.BytesIO(form.encode("utf-8")), encoding="utf-8")
    sys.stdout = io.StringIO()
    rc = guard.main()
    said = sys.stdout.getvalue()
    sys.stdout = real_out
    print("%d\t%d\t%s" % (rc, said.count("\n"), said.strip()))
PYEOF
FORMS=()
verify() {  # verify <deny|ok> <label> <reason fragment> [helper]: the verdict on every form in FORMS (deny: exit 3 and ONE reason line holding the fragment; ok: exit 0 and `ok`)
  local want="$1" label="$2" frag="$3" form i=0 n=${#FORMS[@]} bad_forms="" rc nl said verb=denied
  [ "$want" = ok ] && verb=allowed
  : >"$TMPROOT/forms.bin"
  for form in "${FORMS[@]}"; do printf '%s\0' "$form" >>"$TMPROOT/forms.bin"; done
  python3 -I -S "$DRIVER" "${4:-$HELPER}" "$TMPROOT/forms.bin" >"$TMPROOT/drive.out" 2>"$TMPROOT/drive.err"
  while IFS=$'\t' read -r rc nl said; do
    form="${FORMS[$i]:-}"
    i=$((i + 1))
    if [ "$want" = deny ]; then
      case $said in *"$frag"*) { [ "$rc" = 3 ] && [ "$nl" = 1 ]; } || bad_forms="$bad_forms [$form: rc=$rc lines=$nl $said]" ;; *) bad_forms="$bad_forms [$form: rc=$rc $said]" ;; esac
    else
      { [ "$rc" = 0 ] && [ "$said" = ok ]; } || bad_forms="$bad_forms [$form: rc=$rc $said]"
    fi
  done <"$TMPROOT/drive.out"
  N=$((N + 1))
  if [ "$want" = deny ]; then D_FORMS=$((D_FORMS + n)); else A_FORMS=$((A_FORMS + n)); fi
  if [ -z "$bad_forms" ] && [ "$n" -gt 0 ] && [ "$i" = "$n" ]; then
    ok "$N. $verb, all $n forms: $label"
  else
    bad "$N. forms with the wrong verdict ($want): $label" "${bad_forms:-no forms ran} (driver stderr: $(head -c 200 "$TMPROOT/drive.err"))"
  fi
}
group() {  # group <deny|ok> <label> <reason fragment>; one command per line on stdin
  local form
  FORMS=()
  while IFS= read -r form; do
    [ -n "$form" ] || continue
    FORMS+=("$form")
  done
  verify "$1" "$2" "$3"
}
multi() {  # multi <deny|ok> <label> <reason fragment> <command>...: commands that span several lines
  local want="$1" label="$2" frag="$3"
  shift 3
  FORMS=("$@")
  verify "$want" "$label" "$frag"
}

echo "-- 1. the helper alone, through its real command line: exit 0 + ok, exit 3 + ONE reason line (deny), exit 4 + a reason (could not read) --"
helper() { python3 -I -S "$HELPER" <<<"$1" >"$TMPROOT/h.out" 2>"$TMPROOT/h.err"; echo $? >"$TMPROOT/h.rc"; }
cli_denied() {  # cli_denied <command> <reason fragment> <label>
  helper "$1"
  if [ "$(cat "$TMPROOT/h.rc")" = 3 ] && [ "$(wc -l <"$TMPROOT/h.out" | tr -d ' ')" = 1 ] && grep -qF -- "$2" "$TMPROOT/h.out" && [ ! -s "$TMPROOT/h.err" ]; then ok "$3: exit 3 and ONE reason line"; else bad "helper, $3: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out") err=$(head -c 200 "$TMPROOT/h.err")"; fi
}
cli_denied 'until grep -q ALLDONE f; do sleep 30; done' 'a loop that runs sleep' "a loop that sleeps"
cli_denied 'while kill -0 $PID; do sleep 2; done' 'polls pgrep or kill -0' "a loop that polls kill -0"
cli_denied "perl -e 'alarm 595; sleep 595'" 'an interpreter script that sleeps' "an alarm and a sleep in perl"
cli_denied 'sleep 120' 'sleep for 60 seconds or more' "a sleep of two minutes"
cli_denied 'tail -f /tmp/job.log' 'tail -f or tail -F' "tail -f"
helper 'git status && ls'
if [ "$(cat "$TMPROOT/h.rc")" = 0 ] && [ "$(cat "$TMPROOT/h.out")" = ok ] && [ ! -s "$TMPROOT/h.err" ]; then ok "an ordinary command: exit 0 and 'ok'"; else bad "helper, ordinary: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out")"; fi
helper 'echo "sleep'
if [ "$(cat "$TMPROOT/h.rc")" = 4 ] && [ "$(wc -l <"$TMPROOT/h.out" | tr -d ' ')" = 1 ] && grep -q 'unbalanced quote' "$TMPROOT/h.out"; then ok "an unbalanced quote that mentions sleep: exit 4 and the reason it could not be read"; else bad "helper, unbalanced: rc=$(cat "$TMPROOT/h.rc") out=$(head -c 200 "$TMPROOT/h.out")"; fi

echo "-- 2. DENIED: a loop whose body or condition runs sleep (until, while, for), whatever it waits for and however short the sleep --"
group deny "the shapes the transcripts hold, and the loops of the same family" 'a loop that runs sleep' <<'EOF'
until grep -q ALLDONE f; do sleep 30; done
until grep -q ALLDONE /tmp/job.log; do sleep 30; done; tail -5 /tmp/job.log
for i in $(seq 1 58); do grep -q X f && break; sleep 10; done
for i in $(seq 1 58); do grep -q DONE /tmp/out.log && break; sleep 10; done; tail -20 /tmp/out.log
for i in 1 2 3; do echo $i; sleep 1; done
for ((i=0;i<60;i++)); do sleep 5; done
for i in {1..30}; do curl -sf localhost:8080/health && break; sleep 2; done
for f in a b c; do process $f; sleep 0.2; done
while true; do sleep 1; done
while :; do date; sleep 60; done
while [ ! -f done.flag ]; do sleep 2; done
until [ -f /tmp/ready ]; do sleep 0.5; done
while ! curl -sf http://localhost:3000/health; do sleep 1; done
until curl -sf http://localhost:3000/health >/dev/null; do sleep 2; done
until test -s out.log; do sleep 3; done
while sleep 5; do check; done
while true; do if [ -f x ]; then break; fi; sleep 1; done
while true; do for j in 1; do sleep 1; done; done
while read l; do echo $l; sleep 1; done < file
EOF
group deny "the same loops in a group, a subshell, a conditional, a pipeline, a redirect, a chain, behind time" 'a loop that runs sleep' <<'EOF'
(until grep -q X f; do sleep 5; done)
{ until grep -q X f; do sleep 5; done; }
if true; then until grep -q X f; do sleep 5; done; fi
until grep -q X f; do sleep 5; done | tail -3
until grep -q X f; do sleep 5; done 2>&1
until grep -q X f; do sleep 5; done > /tmp/out.txt
time until grep -q X f; do sleep 5; done
echo start; until grep -q X f; do sleep 5; done
echo start && until grep -q X f; do sleep 5; done
until grep -q X f; do sleep 5; done && echo ready
until grep -q X f; do sleep 5; done; echo done
x=$(for i in 1 2; do sleep 1; done)
for i in 1 2; do echo $(sleep 1); done
for i in 1 2; do echo `sleep 1`; done
EOF
group deny "the sleep itself behind a wrapper, a path, a variable duration or a quote" 'a loop that runs sleep' <<'EOF'
for i in 1 2; do timeout 5 sleep 1; done
for i in 1 2; do env X=1 sleep 1; done
for i in 1 2; do nohup sleep 1; done
for i in 1 2; do time sleep 1; done
for i in 1 2; do /bin/sleep 1; done
for i in 1 2; do "sleep" 1; done
for i in 1 2; do sleep $DELAY; done
for i in 1 2; do sleep "$DELAY"; done
for i in 1 2; do echo 5 | xargs sleep; done
EOF
group deny "the loop inside a shell string: sh -c, bash -lc, timeout ... bash -c, eval, and a sleep in a shell string run by a loop" 'a loop that runs sleep' <<'EOF'
timeout 600 bash -c 'until grep -q X f; do sleep 5; done'
bash -c "until grep -q X f; do sleep 5; done"
sh -c 'for i in 1 2 3; do sleep 1; done'
eval 'until grep -q X f; do sleep 1; done'
env X=1 bash -lc 'until grep -q X f; do sleep 1; done'
for i in 1 2; do bash -c 'sleep 1'; done
for i in 1 2; do eval "sleep 1"; done
EOF
multi deny "a loop on several lines, after a newline, a continued line, a heredoc fed to a shell" 'a loop that runs sleep' \
  $'until grep -q X f\ndo\n  sleep 5\ndone' \
  $'echo start\nuntil grep -q X f; do sleep 5; done' \
  $'until grep -q X f; do \\\n  sleep 5; \\\ndone' \
  $'bash <<EOF\nuntil grep -q X f; do sleep 5; done\nEOF' \
  $'sh <<\'EOF\'\nfor i in 1 2 3; do sleep 1; done\nEOF' \
  $'while true\ndo\n  sleep 1\ndone'

echo "-- 3. DENIED: a while or until loop that polls a process (pgrep, kill -0), with a sleep or without --"
group deny "pgrep and kill -0 as the loop's condition" 'polls pgrep or kill -0' <<'EOF'
while pgrep -f foo >/dev/null; do sleep 5; done
while pgrep -f "npm run dev" > /dev/null 2>&1; do sleep 2; done
until ! pgrep -f job; do sleep 5; done
while ! pgrep -f server; do sleep 1; done
while kill -0 $PID; do sleep 2; done
while kill -0 $PID 2>/dev/null; do sleep 1; done
while kill -0 "$pid" 2>/dev/null; do sleep 1; done
while kill -0 $! 2>/dev/null; do sleep 1; done
until ! kill -0 $PID 2>/dev/null; do sleep 1; done
while kill -s 0 $PID; do sleep 1; done
while /usr/bin/pgrep foo; do sleep 1; done
while pgrep foo || pgrep bar; do sleep 1; done
x=1; while pgrep -f foo; do sleep 1; done
sh -c "while pgrep foo; do sleep 1; done"
timeout 300 bash -c 'while kill -0 $PID; do sleep 2; done'
EOF
group deny "the same polls busy-waiting, with no sleep at all" 'polls pgrep or kill -0' <<'EOF'
while pgrep -f foo >/dev/null; do :; done
until ! pgrep -f job; do true; done
while kill -0 $PID 2>/dev/null; do :; done
EOF

echo "-- 4. DENIED: an interpreter one-liner that sleeps with an alarm, or for 60 seconds or more --"
group deny "perl -e 'alarm N; sleep N' (the transcripts' shape) and the same in other interpreters" 'an interpreter script that sleeps' <<'EOF'
perl -e 'alarm 595; sleep 595'
perl -e 'alarm 30; sleep'
perl -e "alarm 300; sleep 300"
perl -e 'alarm(120); sleep(120)'
perl -e 'sleep 600'
perl -e 'alarm 595; sleep 595' && echo timed out
timeout 700 perl -e 'alarm 595; sleep 595'
nohup perl -e 'alarm 595; sleep 595'
x=$(perl -e 'alarm 595; sleep 595')
bash -c "perl -e 'alarm 595; sleep 595'"
python3 -c 'import signal, time; signal.alarm(300); time.sleep(300)'
python3 -c "import time; time.sleep(120)"
python3 -c 'import time; time.sleep(60)'
python -c 'import time; time.sleep(600.5)'
ruby -e 'sleep 90'
awk 'BEGIN { system("sleep 100") }'
EOF
multi deny "a script on stdin (heredoc, here-string)" 'an interpreter script that sleeps' \
  $'python3 - <<\'EOF\'\nimport time\ntime.sleep(300)\nEOF' \
  $'perl <<\'EOF\'\nalarm 595;\nsleep 595;\nEOF' \
  $'perl <<<"alarm 595; sleep 595"'

echo "-- 5. DENIED: a standalone sleep of 60 seconds or more --"
group deny "60 s and up, with units, several arguments and infinity" 'sleep for 60 seconds or more' <<'EOF'
sleep 60
sleep 61
sleep 120
sleep 595
sleep 60.5
sleep 1m
sleep 2m
sleep 1h
sleep 1d
sleep 1e2
sleep 90s
sleep 30 30
sleep 1m 30s
sleep infinity
sleep inf
EOF
group deny "behind wrappers, chains, pipes, subshells, substitutions and shell strings" 'sleep for 60 seconds or more' <<'EOF'
sleep 60 && echo done
echo x; sleep 600
sleep 600; echo done
echo hi && sleep 600 && echo bye
timeout 700 sleep 650
nohup sleep 100
time sleep 100
sudo -n sleep 100
env X=1 sleep 100
/bin/sleep 100
(sleep 100)
sleep 100 | cat
x=$(sleep 100)
sh -c 'sleep 100'
bash -lc "echo go; sleep 300"
eval 'sleep 100'
"sleep" 100
EOF

echo "-- 6. DENIED: tail -f / tail -F (a file followed with no end) --"
group deny "-f, -F, --follow, clustered flags, flags after the file, values of other options skipped" 'tail -f or tail -F' <<'EOF'
tail -f log
tail -F log
tail -f /tmp/out.log | grep -m1 DONE
tail -fn 100 log
tail -n 100 -f log
tail -n100 -F log
tail -Fn0 log
tail -f -n 0 log
tail -qf a b
tail -n +1 -f log
tail -c 100 -F log
tail log -f
tail -20f log
tail --follow log
tail --follow=name log
tail --follow=descriptor --retry log
tail --fol log
tail -f --pid=$PID log
EOF
group deny "tail -f behind wrappers, paths, chains, subshells, loops and shell strings" 'tail -f or tail -F' <<'EOF'
timeout 30 tail -f log
sudo tail -f /var/log/system.log
/usr/bin/tail -f x
nohup tail -f log
bash -c 'tail -f log'
echo a; tail -F log
tail -F log | head -1
(tail -f log)
x=$(tail -f log)
for i in 1; do tail -f log; done
EOF

echo "-- 7. ALLOWED: text that only MENTIONS a form (echo, printf, grep, cat, git, a commit message or its heredoc, a script written to disk) --"
group ok "echo, printf, grep, cat, sed, ls, git, gh, man, which: the form is an argument, not a command" '-' <<'EOF'
echo "until grep -q ALLDONE f; do sleep 30; done"
echo 'for i in 1 2; do sleep 10; done'
echo "perl -e 'alarm 595; sleep 595'"
echo sleep 600
echo "tail -f log"
echo while true
printf '%s\n' "sleep 600 and tail -F"
grep -rn "sleep 600" docs/
grep -rn "until grep" docs/
grep -n 'tail -f' CLAUDE.md
grep -n 'alarm 595' docs/analysis/2026-11-10-stale-general-purpose-agents.md
grep sleep bin/foo.sh
grep -c "kill -0" bin/lib/x.py
cat docs/sleep-notes.md
cat bin/sleeper
sed -n '1,20p' bin/heimdall-wait
head -5 tail-notes.txt
ls sleep*
ls detail-tail.txt
git add docs/sleep.md
git log --oneline --grep=sleep
git commit -m "fix: no more sleep 300 loops, tail -f or alarm waits"
git commit -m 'perl -e alarm 595; sleep 595'
git commit -m "until grep -q X f; do sleep 30; done"
git -C /tmp/repo commit -m "while pgrep foo; do sleep 5; done"
gh issue comment 5 --body "tail -f is a wait"
echo "$(echo sleep 600)"
man sleep
which sleep
command -v sleep
type sleep
EOF
multi ok "a heredoc commit message, a script written to disk, a heredoc fed to cat, a mention on a later line" '-' \
  $'git commit -m "$(cat <<\'EOF\'\nfix: never until grep -q X f; do sleep 30; done, never tail -f\nEOF\n)"' \
  $'cat > poll.sh <<\'EOF\'\nuntil grep -q X f; do sleep 30; done\nEOF' \
  $'cat <<EOF\nsleep 600\nEOF' \
  $'echo start\ngrep -n sleep log.txt' \
  $'cat > wait.py <<\'EOF\'\nimport signal, time\nsignal.alarm(595)\ntime.sleep(595)\nEOF'

echo "-- 8. ALLOWED: what the guard is not about (sleep under 60 s outside a loop, loops without sleep, tail without follow, an alarm without a sleep) --"
group ok "sleep under 60 seconds outside a loop, in every spelling" '-' <<'EOF'
sleep 1
sleep 5
sleep 30
sleep 59
sleep 59.9
sleep 0.5
sleep 30s
sleep 0.5m
sleep 20 20
sleep 1 && echo ok
echo a; sleep 2; echo b
sleep 1; sleep 1; sleep 1
sleep 5 | cat
make test && sleep 2 && make lint
timeout 10 sleep 5
nohup sleep 5
sleep $N
sleep "$DELAY"
echo 5 | xargs sleep
sleep
sleep --help
EOF
group ok "loops without sleep, and loops that only LOOK like polls (a for loop, a while read, a probe in the body, an if)" '-' <<'EOF'
for f in *.txt; do grep -q X $f && echo $f; done
for i in 1 2 3; do echo $i; done
while read l; do echo $l; done < file
while [ -f x ]; do rm x; done
until grep -q X f; do :; done
until [ -f x ]; do true; done
for pid in $PIDS; do kill -0 $pid && echo alive; done
while read pid; do kill -0 "$pid" 2>/dev/null || echo dead; done < pids.txt
while read pid; do alive=$(pgrep -P $pid); echo "$alive"; done < pids.txt
for f in a b; do pgrep -f $f; done
for i in 1 2 3; do curl -sf localhost:8080 && break; done
for f in *.sh; do shellcheck "$f"; done; sleep 1
(for f in a b; do echo $f; done); sleep 2
if pgrep -f foo >/dev/null; then echo running; fi
pgrep -f foo
kill -0 $PID && echo alive
wait $PID
EOF
group ok "tail without a follow flag, the bound the guard recommends, an alarm without a sleep, an interpreter that sleeps briefly" '-' <<'EOF'
tail -n 20 log
tail -20 log
make test 2>&1 | tail -20
npm run build 2>&1 | tail -n 30
git log --oneline | tail -5
tail -n +5 file
tail -c 100 file
tail -qn 5 a b
tail -r file
tail -s 5 file
tail -n 5 log.txt | grep -f patterns.txt
tail -- -f
timeout 120 npm test
perl -e 'alarm 45; exec @ARGV' make test
perl -pi -e 's/sleep/nap/' f.pl
perl -e 'print "sleep"'
python3 -c "import time; time.sleep(5)"
python3 -c "import time; time.sleep(0.5)"
python3 -c 'import signal; signal.alarm(30)'
python3 -c "import time; time.sleep(delay)"
python3 sleep.py
python3 scripts/poll_sleep.py --wait 600
ruby -e 'puts 1'
node -e 'console.log("sleep")'
awk '{ print }' file
EOF

echo "-- 9. through the REAL hook: the five shapes the transcripts hold, and the other forms, are denied; ordinary commands are not --"
denied 'until grep -q ALLDONE f; do sleep 30; done' "until grep -q ALLDONE f; do sleep 30; done"
denied 'for i in $(seq 1 58); do grep -q X f && break; sleep 10; done' "for i in \$(seq 1 58); do grep -q X f && break; sleep 10; done"
denied "perl -e 'alarm 595; sleep 595'" "perl -e 'alarm 595; sleep 595'"
denied 'while pgrep -f foo >/dev/null; do sleep 5; done' "while pgrep -f foo >/dev/null; do sleep 5; done"
denied 'while kill -0 $PID; do sleep 2; done' "while kill -0 \$PID; do sleep 2; done"
denied 'sleep 600' "a standalone sleep of ten minutes"
denied 'tail -f /tmp/out.log' "tail -f"
denied 'timeout 900 bash -c "until grep -q X f; do sleep 5; done"' "the same loop inside timeout ... bash -c"
denied $'echo start\nuntil grep -q X f; do sleep 5; done' "after a newline"
allowed 'echo "until grep -q ALLDONE f; do sleep 30; done"' "text that only mentions a loop"
allowed 'git commit -m "fix: no sleep 300 loops, tail -f or alarm waits"' "a commit message that mentions the forms"
allowed $'git commit -m "$(cat <<\'EOF\'\nfix: never until grep -q X f; do sleep 30; done\nEOF\n)"' "a heredoc commit message that mentions a loop"
allowed 'sleep 5' "a short sleep outside a loop"
allowed 'for i in 1 2 3; do echo $i; done' "a loop without sleep"
allowed 'make test 2>&1 | tail -20' "tail without a follow flag"
allowed "perl -e 'alarm 45; exec @ARGV' true" "an alarm without a sleep (the bound the guard recommends)"
allowed 'timeout 120 sleep 30' "sleep under 60 s behind timeout"

echo "-- 10. run_in_background: true (read from the payload's tool_input) allows every wait: the harness notifies on completion --"
BG_BAD=""; BG_N=0
BG=true
for form in 'until grep -q ALLDONE f; do sleep 30; done' 'for i in $(seq 1 58); do grep -q X f && break; sleep 10; done' "perl -e 'alarm 595; sleep 595'" \
            'while pgrep -f foo >/dev/null; do sleep 5; done' 'while kill -0 $PID; do sleep 2; done' 'sleep 600' 'tail -f /tmp/out.log' 'tail -F /tmp/out.log | grep -m1 DONE'; do
  BG_N=$((BG_N + 1)); run_hook "$form" "$PLUGIN"
  { [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; } || BG_BAD="$BG_BAD [$form: rc=$RC $(head -c 120 "$TMPROOT/err")]"
done
BG=""
if [ -z "$BG_BAD" ]; then ok "run_in_background: true: all $BG_N forms are allowed, silently"; else bad "background allow:$BG_BAD"; fi
BG='"true"'
allowed 'until grep -q ALLDONE f; do sleep 30; done' "run_in_background given as the string \"true\" counts too (an agent is never stuck behind a type quirk)"
BG=false
denied 'until grep -q ALLDONE f; do sleep 30; done' "run_in_background: false is a foreground call"
BG='"false"'
denied 'sleep 600' "run_in_background given as the string \"false\" is a foreground call"
BG=""
denied 'sleep 600' "no run_in_background in the payload at all"
BG=true
rm -f "$MARK"
run_hook 'sleep 600' "$STUB_OK"
if [ "$RC" = 0 ] && [ ! -e "$MARK" ]; then ok "with run_in_background: true the helper is never even started"; else bad "background still ran the helper: rc=$RC mark=$([ -e "$MARK" ] && echo yes || echo no)"; fi
BG=""

echo "-- 11. the deny text: what the operator asked it to say, and how the OPERATOR lifts the guard --"
run_hook 'until grep -q ALLDONE f; do sleep 30; done' "$PLUGIN"
ERR1="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
run_hook 'tail -F /tmp/out.log' "$PLUGIN"
ERR2="$(jq -r '.error // empty' "$TMPROOT/out" 2>/dev/null)"
TXT_BAD=""
for e in "$ERR1" "$ERR2"; do
  for frag in 'Wait loops block the agent and stale it' 'run_in_background' 'completion notification' 'Monitor tool' 'bound a long command with the Bash timeout' \
              'HMD_WAIT_ALLOW=1' 'environment Claude Code runs in' 'inline' 'not a security boundary' 'docs/analysis/2026-11-10-stale-general-purpose-agents.md'; do
    printf '%s' "$e" | grep -qF -- "$frag" || TXT_BAD="$TXT_BAD [missing: $frag]"
  done
done
if [ -z "$TXT_BAD" ]; then ok "both denies say: wait loops block the agent and stale it; run the job with run_in_background and wait for its completion notification (or the Monitor tool); bound a long command with the Bash timeout; the operator override; not a security boundary"; else bad "deny text:$TXT_BAD" "$ERR1"; fi
if printf '%s' "$ERR1" | grep -qF 'a loop that runs sleep' && printf '%s' "$ERR2" | grep -qF 'tail -f or tail -F'; then ok "the deny names the form that tripped it (a loop that runs sleep, tail -f or tail -F)"; else bad "deny does not name the form: $ERR1 | $ERR2"; fi

echo "-- 12. HMD_WAIT_ALLOW=1 (the hook's OWN environment) lifts the guard; anything else leaves it on --"
OV=0; OV_BAD=""
for form in 'until grep -q ALLDONE f; do sleep 30; done' 'sleep 600' 'tail -f /tmp/out.log' 'sh -c "while pgrep foo; do sleep 1; done"'; do
  OV=$((OV + 1)); run_hook "$form" "$PLUGIN" HMD_WAIT_ALLOW=1
  { [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; } || OV_BAD="$OV_BAD [$form: rc=$RC $(head -c 120 "$TMPROOT/err")]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_WAIT_ALLOW=1: all $OV forms are allowed, silently"; else bad "override 1:$OV_BAD"; fi
OV_BAD=""
for v in 0 '' true yes ' 1' 11; do
  run_hook 'sleep 600' "$PLUGIN" "HMD_WAIT_ALLOW=$v"
  { [ "$RC" = 2 ] && grep -q 'hmd wait guard' "$TMPROOT/out"; } || OV_BAD="$OV_BAD [$v: rc=$RC]"
done
if [ -z "$OV_BAD" ]; then ok "HMD_WAIT_ALLOW=0, empty, true, yes, ' 1' and 11 all leave it ON: only exactly 1 lifts it"; else bad "override other values:$OV_BAD"; fi
denied 'HMD_WAIT_ALLOW=1 sleep 600' "an INLINE HMD_WAIT_ALLOW=1 reaches the command, not the hook that has already said no"
rm -f "$MARK"
run_hook 'sleep 600' "$STUB_OK" HMD_WAIT_ALLOW=1
if [ "$RC" = 0 ] && [ ! -e "$MARK" ]; then ok "with the override on, the helper is never even started"; else bad "override still ran the helper: rc=$RC mark=$([ -e "$MARK" ] && echo yes || echo no)"; fi

echo "-- 13. FAILS OPEN (a cost guard, not a security gate): what it cannot read or run is a warning and an allow --"
warned 'echo "sleep' "an unbalanced quote that mentions sleep" 'unbalanced quote'
warned $'echo $\'sleep\'' "ANSI-C quoting, which is not decoded" 'ANSI-C'
warned $'cat <<EOF\n$(echo sleep)\nEOF' "an unquoted heredoc whose body runs a substitution" 'heredoc'
DEEP='sleep 600'
for i in 1 2 3 4 5 6 7 8 9 10; do DEEP="sh <<E$i"$'\n'"$DEEP"$'\n'"E$i"; done
warned "$DEEP" "shell strings nested ten deep (past the depth it reads)" 'nested more than 8 deep'
DEEPSUB="$(python3 -I -c 'print("$(" * 4000 + "sleep 600")')"
warned "$DEEPSUB" "4000 nested substitutions: the lexer's recursion error is an allow with a warning, not a crash and not a deny" 'internal error'
LONGCMD="$(python3 -I -c 'print("echo sleep; " + "echo x; " * 3000)')"
warned "$LONGCMD" "a command that takes longer than HMD_WAIT_GUARD_TIMEOUT_S to read (1 ms here)" 'took longer' "$PLUGIN" HMD_WAIT_GUARD_TIMEOUT_S=0.001
denied 'sleep 600; echo "unbalanced' "a form it READ wins over a quote it could not close"
denied 'until grep -q X f; do sleep 5; done; echo "unbalanced' "a loop before an unbalanced quote is still found"
warned 'sleep 600' "a helper that crashes (exit 1)" 'the guard itself failed (exit 1)' "$STUB_CRASH"
warned 'tail -f x' "a helper that prints garbage and exits 7" 'the guard itself failed (exit 7)' "$STUB_GARBAGE"
warned 'sleep 600' "a helper that exits 4: its reason is the warning" 'an odd command the stub could not read' "$STUB_UNREAD"
warned 'sleep 600' "a helper whose import is missing (no hmd_kill_guard.py beside it)" 'the guard itself failed' "$NOKILL"
N=$((N + 1)); run_hook 'sleep 600' "$NOHELPER"
if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ] && [ ! -s "$TMPROOT/err" ]; then ok "$N. no helper in the plugin root: allowed, completely silent"; else bad "$N. no helper: rc=$RC err=$(head -c 200 "$TMPROOT/err")"; fi
N=$((N + 1)); run_hook 'sleep 600' "$STUB_SILENT"
if [ "$RC" = 0 ] && [ ! -s "$TMPROOT/out" ]; then ok "$N. a helper that says nothing and exits 0: allowed"; else bad "$N. silent helper: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'sleep 600' "$STUB_DENY"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd wait guard: a \"quoted\" back\\slash reason. ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a reason with a quote and a backslash still makes valid JSON (escaped by jq, verbatim in the verdict)"; else bad "$N. deny escaping: rc=$RC out=$(head -c 300 "$TMPROOT/out")"; fi

echo "-- 14. the pre-filter: python starts only for a command that mentions sleep, alarm or tail -f --"
PF_BAD=""
for form in 'ls -la' 'git status' 'git commit -m "fix the flaky test"' 'make test 2>&1 | tail -20' 'tail -n 20 log' 'echo hello world' 'npm run build' 'grep -rn foo src/'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ ! -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "ls, git status, an ordinary commit, a test run piped to tail, tail -n, echo, npm, grep: the helper is never started"; else bad "pre-filter let ordinary commands through to python:$PF_BAD"; fi
PF_BAD=""
for form in 'sleep 5' 'echo alarm' 'tail -f x' 'tail -F x' 'tail -n 20 -f x' 'tail --follow x' 'tail -fn 5 x'; do
  rm -f "$MARK"; run_hook "$form" "$STUB_OK"
  { [ "$RC" = 0 ] && [ -e "$MARK" ]; } || PF_BAD="$PF_BAD [$form: rc=$RC]"
done
if [ -z "$PF_BAD" ]; then ok "each trigger (sleep, alarm, tail -f, tail -F, a flag after another, --follow, a cluster): the helper IS started"; else bad "pre-filter missed a trigger:$PF_BAD"; fi

echo "-- 15. the guard sits AFTER the CI waste guard, the disk floor and the sweep guard --"
N=$((N + 1)); run_hook 'git commit --allow-empty -m retrigger; sleep 600' "$ORDER"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd CI waste guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a command that is both an empty commit and a wait gets the CI waste guard's verdict"; else bad "$N. order vs CI waste guard: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'bash test/x.test.sh; sleep 600' "$ORDER" HMD_MIN_FREE_PCT=100
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: disk floor: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a test run that is also a wait, on a full disk, gets the disk floor's verdict"; else bad "$N. order vs disk floor: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'bash test/run-all.sh; sleep 600' "$ORDER"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd sweep guard: stub sweep reason")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. a sweep that is also a wait gets the sweep guard's verdict"; else bad "$N. order vs sweep guard: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi
N=$((N + 1)); run_hook 'sleep 600' "$ORDER"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd wait guard: ")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. (control) with the three ahead of it quiet, this guard answers"; else bad "$N. order control: rc=$RC out=$(head -c 200 "$TMPROOT/out")"; fi

echo "-- 16. the REAL plugin root (the files as shipped), not a copy --"
N=$((N + 1)); run_hook 'until grep -q ALLDONE f; do sleep 30; done' "$REPO"
if [ "$RC" = 2 ] && jq -e '.error | startswith("BLOCKED: hmd wait guard: a loop that runs sleep")' "$TMPROOT/out" >/dev/null 2>&1; then ok "$N. the shipped hook and libs deny a foreground poll loop"; else bad "$N. real root, loop: rc=$RC out=$(head -c 200 "$TMPROOT/out") err=$(head -c 200 "$TMPROOT/err")"; fi

echo "-- 17. the suite can go RED: a one-line break of the helper makes a deny form pass --"
MUT="$TMPROOT/mut"
mutate() {  # mutate <name> <sed expression> <form that must stop being denied> <label>
  mkdir -p "$MUT/$1"
  cp "$REPO/bin/lib/hmd_kill_guard.py" "$MUT/$1/hmd_kill_guard.py" 2>/dev/null
  sed -e "$2" "$HELPER" >"$MUT/$1/hmd_wait_guard.py" 2>/dev/null
  N=$((N + 1))
  if cmp -s "$HELPER" "$MUT/$1/hmd_wait_guard.py"; then bad "$N. the mutation '$1' changed nothing (the pattern no longer matches the helper)"; return; fi
  printf '%s\0' "$3" >"$TMPROOT/mut.bin"
  python3 -I -S "$DRIVER" "$MUT/$1/hmd_wait_guard.py" "$TMPROOT/mut.bin" >"$TMPROOT/mut.out" 2>/dev/null
  if [ "$(cut -f1 "$TMPROOT/mut.out")" = 0 ]; then ok "$N. $4"; else bad "$N. mutation '$1' is still denied, so no assertion above could catch it: $4" "$(head -c 200 "$TMPROOT/mut.out")"; fi
}
mutate long 's/^LONG_S = 60/LONG_S = 6000/' 'sleep 120' "LONG_S = 6000: a sleep of two minutes is no longer denied (the 60 s rule is what pins it)"
mutate loop 's/looped or open_loops > 0/looped/' 'for i in 1 2 3; do echo $i; sleep 1; done' "no loop tracking: a loop that sleeps is no longer denied"
mutate tail 's/if c in "fF":/if c in "xX":/' 'tail -f log' "no follow flag: tail -f is no longer denied"

echo "-- 18. wiring: the docs agents read name the rule and the guard --"
if grep -q 'HMD_WAIT_ALLOW' "$REPO/CLAUDE.md" && grep -q 'bin/lib/hmd_wait_guard.py' "$REPO/CLAUDE.md" && grep -q 'test/wait-guard.test.sh' "$REPO/CLAUDE.md"; then ok "CLAUDE.md describes the guard: the override, the lib, and this test"; else bad "CLAUDE.md does not name HMD_WAIT_ALLOW, bin/lib/hmd_wait_guard.py and test/wait-guard.test.sh"; fi
if grep -q 'hmd_wait_guard' "$REPO/CHANGELOG.md"; then ok "CHANGELOG.md has the bullet"; else bad "CHANGELOG.md does not mention hmd_wait_guard"; fi
if grep -q 'HMD_WAIT_ALLOW' "$HOOK" && grep -q 'hmd_wait_guard.py' "$HOOK"; then ok "bin/heimdall-precheck-bash documents the switch and calls the helper"; else bad "the hook does not name HMD_WAIT_ALLOW and hmd_wait_guard.py"; fi

printf '\n  forms through the helper: %d denied, %d allowed (plus the real command line, the hook cases, the override, fail-open, ordering and mutants)\n' "$D_FORMS" "$A_FORMS"
printf '  wait-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
