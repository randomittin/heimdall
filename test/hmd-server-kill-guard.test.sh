#!/usr/bin/env bash
# shellcheck disable=SC2016  # the payloads fed to the hook are literal text: $!, $(...) and backticks must NOT expand here
# test/hmd-server-kill-guard.test.sh
#
# Nothing but the operator's own `hmd app disconnect` (or the phone's own revoke) may end a REAL repo's relay client.
#
# 2026-10-12 16:29:39Z -- the live phone relay clients of /Users/rj/Downloads/heimdall and /Users/rj/Downloads/hmdapp (and the
# routine's) all logged `session_ended reason=local-disconnect` within 0.5s and their phones were unpaired. Who: a sub-agent
# that, debugging a temp-repo test, ran
#     pkill -f app_pair_confirm_cases; pkill -f "heimdall-app pair-window-loop"; pkill -f heimdall-relay-client; ...
# (its transcript, 16:29:39.293Z). The pattern matched EVERY heimdall-relay-client on the machine; each answered SIGTERM (as every client did before 2.4.8) the way
# `hmd app disconnect` makes it answer -- revoke its relay session, then end -- and the relay-events logs show `connect
# for=revoke` 0.4s later. It was NOT a committed test and NOT the orphan reaper. A security review then showed a regex over the
# command text is walked around (quoting the name, a character class, a partial pattern, a variable, a looked-up pid, xargs,
# sh -c, env/command/exec, a process-group kill), so the guard is bin/lib/hmd_kill_guard.py, which reads the command like a
# shell, behind bin/heimdall-precheck-bash; a second review showed the first version failed OPEN. This pins:
#   * every way found to kill by NAME or by a COMPUTED pid is denied, and what is safe is allowed: kill <literal pid>, kill $!,
#     kill -0, reading (pgrep / ps / lsof), text that only MENTIONS a verb (echo, grep, a commit message, a heredoc body)
#   * the guard fails CLOSED: a command that mentions kill and that it cannot fully read (unbalanced quote, unterminated or
#     expanded heredoc, $'...', a verb in a variable, nesting too deep, an exception, a timeout) is denied, and the hook denies
#     when the guard itself is missing, crashes, says nothing or prints garbage
#   * no committed test, helper or bin script pattern-kills an hmd server
#   * bin/lib/hmd_ui_procs.py's reaper (heimdall-gc uis, run-all.sh's end-of-sweep guard) only ever selects orphans whose
#     repo is gone or under a temp dir -- never a live client of an existing non-temp repo -- and never guesses a repo
# The guard is BEST-EFFORT DEFENSE IN DEPTH, NOT A SECURITY BOUNDARY: no text guard on shell is complete. The real protection is
# that a stray signal must not be able to unpair a phone -- settled in 2.4.8: a stopped client revokes nothing and its replacement resumes
# the phone's stored session (test/app-session-resume.test.sh); these cases pin what the guard does
# promise, not that it cannot be walked around.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
N=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "hmd-server-kill-guard"

command -v jq >/dev/null 2>&1 || { bad "0. jq is required: the hook parses its payload with it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { bad "0. python3 is required"; exit 1; }
[ -f "$REPO/bin/heimdall-precheck-bash" ] || { bad "0. bin/heimdall-precheck-bash is missing"; exit 1; }
[ -f "$REPO/bin/lib/hmd_kill_guard.py" ] || { bad "0. bin/lib/hmd_kill_guard.py is missing"; exit 1; }
GUARD="$REPO/bin/lib/hmd_kill_guard.py"

# Throwaway plugin roots holding ONLY the hook under test (no git-guard, secret scan, state or tracker, so an allowed command is
# allowed by this chain alone and nothing real runs). PLUGIN has the real helper; the others have none or a stub that misbehaves.
mkroot() {  # mkroot <dir> [python source of a stub helper]
  mkdir -p "$1/bin/lib"
  cp "$REPO/bin/heimdall-precheck-bash" "$1/bin/heimdall-precheck-bash"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >"$1/bin/lib/hmd_kill_guard.py"
}
PLUGIN="$TMPROOT/plugin"
mkroot "$PLUGIN"
cp "$GUARD" "$PLUGIN/bin/lib/hmd_kill_guard.py"
BARE="$TMPROOT/plugin-bare"
mkroot "$BARE"
CRASH="$TMPROOT/plugin-crash"
mkroot "$CRASH" 'import sys
sys.exit(1)'
SILENT="$TMPROOT/plugin-silent"
mkroot "$SILENT" 'import sys
sys.exit(0)'
GARBAGE="$TMPROOT/plugin-garbage"
mkroot "$GARBAGE" 'import sys
sys.stdout.write("not ok \"quoted\" back\\slash\n")
sys.exit(3)'

RC=0
run_hook() {  # run_hook <command> [plugin root]  -> RC, $TMPROOT/out (stdout), $TMPROOT/err (stderr)
  local root="${2:-$PLUGIN}"
  jq -nc --arg c "$1" '{tool_input: {command: $c}}' \
    | env CLAUDE_PLUGIN_ROOT="$root" bash "$root/bin/heimdall-precheck-bash" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
}
denied() {  # denied <command> <label> [plugin root]: exit 2 and a valid JSON deny naming the guard
  N=$((N + 1))
  run_hook "$1" "${3:-$PLUGIN}"
  if [ "$RC" = 2 ] && jq -e '.error | test("hmd kill guard")' "$TMPROOT/out" >/dev/null 2>&1; then
    ok "$N. denied: $2"
  else
    bad "$N. NOT denied: $2" "rc=$RC stdout=$(head -c 160 "$TMPROOT/out") stderr=$(head -c 120 "$TMPROOT/err")"
  fi
}
allowed() {  # allowed <command> <label> [plugin root]: not this guard's deny, and the guard did not fail
  N=$((N + 1))
  run_hook "$1" "${3:-$PLUGIN}"
  if [ "$RC" != 2 ] && ! grep -q 'hmd kill guard' "$TMPROOT/out" "$TMPROOT/err"; then
    ok "$N. allowed: $2"
  else
    bad "$N. wrongly denied: $2" "rc=$RC stdout=$(head -c 160 "$TMPROOT/out") stderr=$(head -c 120 "$TMPROOT/err")"
  fi
}

# --- by NAME: every pkill / killall is machine-wide, whatever the pattern looks like ---
INCIDENT='pkill -f app_pair_confirm_cases; pkill -f "heimdall-app pair-window-loop"; pkill -f heimdall-relay-client; sleep 1; python3 - <<EOF
print("debug")
EOF'
denied "$INCIDENT" "the 2026-10-12 incident command (three pkills, a heredoc after)"
denied 'pkill -f heimdall-relay-client' "pkill -f <relay client>"
denied "pkill -9 -f 'heimdall-relay-client'" "pkill -9 -f '<relay client>' (quoted)"
denied "pkill -f 'heimdall''-relay-client'" "name split by adjacent quotes: heimdall''-relay-client"
denied 'pkill -f heimdall-rela[y]' "name as a regex character class: heimdall-rela[y]"
denied 'pkill -f relay-client' "partial pattern: relay-client"
denied 'pkill -f hmd' "partial pattern: hmd"
denied 'pkill python' "bare interpreter name: python"
denied 'X=heimdall-relay-client; pkill -f "$X"' 'pattern held in a variable set earlier: pkill -f "$X"'
denied 'pkill -f app_pair_confirm_cases' "a test-local pattern too: a pattern cannot be proven not to match a hmd server"
denied "pk''ill -f app_pair_confirm_cases" "verb split by adjacent quotes: pk''ill"
denied '\pkill -f app_pair_confirm_cases' "backslash-escaped verb"
denied 'PKILL -f app_pair_confirm_cases' "upper-case verb (a case-insensitive filesystem runs it as pkill)"
denied 'Killall -9 x' "mixed-case killall"
denied 'killall heimdall-relay-client' "killall"
denied 'killall -9 python3' "killall -9 python3"
denied 'pkill -f sentinels/hmd-ui.py' "pkill -f the hmd ui server"
denied 'pkill -f "heimdall-app pair-window-loop"' "pkill -f the pair-window supervisor"
denied 'fuser -k 8711/tcp' "fuser -k <port> kills whatever holds the port"
denied 'fuser -k -n tcp 8711' "fuser -k -n tcp <port>"

# --- wrapper forms: the verb is still the command that runs ---
denied 'sudo pkill -f heimdall-relay-client' "sudo pkill"
denied 'env pkill -f heimdall-relay-client' "env pkill"
denied 'env FOO=1 pkill -f x' "env with an assignment, then pkill"
denied 'X=$(echo a) pkill -f x' "an assignment prefix holding a substitution, then pkill"
denied 'env FOO=$(echo a) -u BAR pkill -f x' "env with a computed assignment and an option, then pkill"
denied 'command pkill -f x' "command pkill"
denied 'exec pkill -f x' "exec pkill"
denied 'timeout 5 pkill -f x' "timeout 5 pkill"
denied 'nohup pkill -f x &' "nohup pkill"
denied 'sh -c "pkill -f heimdall-relay-client"' "sh -c"
denied "bash -lc 'pkill -f x'" "bash -lc"
denied '/bin/sh -c "kill $(pgrep -f heimdall-relay-client)"' "/bin/sh -c with a computed kill inside"
denied 'eval "pkill -f x"' "eval"
denied 'cd /tmp && pkill -f relay-client' "after &&"
denied '( pkill -f x )' "in a subshell"
denied '{ pkill -f x; }' "in a brace group"
denied 'if pkill -f x; then echo hit; fi' "as an if condition"
denied 'echo $(pkill -f x)' "inside a command substitution"
denied $'bash <<EOF\npkill -f heimdall-relay-client\nEOF' "fed to a shell as a heredoc"
denied "python3 -c \"import subprocess; subprocess.run(['pkill', '-f', 'x'])\"" "pkill from a python one-liner"

# --- by a COMPUTED pid: only a literal number may be killed ---
denied 'kill $(pgrep -f heimdall-relay-client)' "kill of a pgrep substitution"
denied 'kill -9 `pgrep -f heimdall-relay-client`' "kill -9 of a backtick pgrep"
denied 'PID=$(pgrep -f heimdall-relay-client); kill -9 $PID' 'a pid looked up first, then kill -9 $PID'
denied 'kill -9 "$PID"' 'kill -9 "$PID"'
denied 'kill -9 ${PID}' 'kill -9 ${PID}'
denied 'kill $(lsof -ti :8711)' "kill of the pid on a port"
denied 'for p in $(pgrep -f x); do kill $p; done' "for loop over pgrep"
denied 'pgrep -f x | while read p; do kill -9 "$p"; done' "while read loop"
denied 'pgrep -f heimdall-relay-client | xargs kill' "pgrep | xargs kill"
denied "ps aux | grep heimdall-relay-client | grep -v grep | awk '{print \$2}' | xargs kill -9" "ps | grep | awk | xargs kill -9"
denied 'lsof -ti :8711 | xargs -I{} kill {}' "xargs -I{} kill {}"
denied 'xargs -n1 kill -9 < pids.txt' "xargs -n1 kill -9"
denied "ps aux | awk '/relay-client/ {print \"kill -9 \" \$2}' | sh" "kill commands generated by awk and piped into sh"
denied "ps aux | awk '/relay-client/ {system(\"kill -9 \" \$2)}'" "awk system(kill ...)"
denied 'find /tmp -name "*.pid" -exec kill {} \;' "find -exec kill"

# --- process groups and other non-pid targets ---
denied 'kill -- -1234' "kill -- -<pgid>"
denied 'kill -9 -1234' "kill -9 -<pgid>"
denied 'kill -TERM -- -$PGID' 'kill -TERM -- -$PGID'
denied 'kill -9 -1' "kill -9 -1 (every process)"
denied 'kill 0' "kill 0 (the whole process group)"

# --- FAILS CLOSED: a command that mentions kill and cannot be fully read is denied, not waved through ---
denied "echo 'it will kill" "an unbalanced single quote"
denied 'echo "kill' "an unbalanced double quote"
denied 'echo $(kill' "an unterminated command substitution"
denied 'echo `kill' "an unterminated backtick"
denied 'echo ${X:-kill' "an unterminated parameter expansion"
denied $'cat <<EOF\nkill me' "a heredoc with no terminator"
denied $'(( x = 1 << 3 ))\npkill -f heimdall-relay-client' "a << shift in arithmetic must not hide the next line as a heredoc body"
denied "echo \$'kill\\n'" "ANSI-C quoting: \$'...' is not decoded"
denied 'echo ${X:-$(pkill -f y)}' "a substitution hidden inside a parameter expansion"
denied $'cat <<EOF\n$(pkill -f x)\nEOF' "an unquoted heredoc whose body runs a substitution"
denied 'K=pkill; $K -f heimdall-relay-client' "the verb held in a variable: \$K -f ..."
denied 'X="pkill -f x"; eval "$X"' 'eval of a variable'
denied 'X="pkill -f x"; sh -c "$X"' 'sh -c of a variable'
DEEP="$(python3 -I -c '
import shlex
s = "pkill -f x"
for _ in range(10):
    s = "sh -c " + shlex.quote(s)
print(s)')"
denied "$DEEP" "sh -c strings nested ten deep (past the depth the guard reads)"
DEEPSUB="$(python3 -I -c 'print("$(" * 4000 + "kill")')"
denied "$DEEPSUB" "4000 nested substitutions: the lexer's recursion error is a deny, not a pass"

# --- what stays allowed: a literal pid, a job, the pid you just started, signal 0, reading, text that only mentions a verb ---
allowed 'kill 4242' "kill <literal pid>"
allowed 'kill -9 4242 4243' "kill -9 <pid> <pid>"
allowed 'kill -TERM 4242' "kill -TERM <pid>"
allowed 'kill -s KILL 4242' "kill -s KILL <pid>"
allowed 'kill -- 4242' "kill -- <pid>"
allowed 'kill 4242 2>/dev/null || true' "kill <pid> with a redirect and || true"
allowed 'kill 4242 # stop the old server' "kill <pid> with a trailing comment"
allowed 'kill %1' "kill a job of this shell"
allowed 'sleep 100 & kill $!' "kill the pid just started in the background"
allowed 'kill -TERM "$!"' 'kill -TERM "$!"'
allowed 'kill -0 $PID' "kill -0 <anything> sends no signal"
allowed 'kill -l' "kill -l lists signals"
allowed '[ -n "$pid" ] && kill 4242' "the [ builtin is not an opaque command name"
allowed '"$HOME/bin/tool" --note kill' "a command name with a variable prefix and a slash is a path"
allowed 'bash -c "echo $X kill"' "a -c string that starts with a plain command"
allowed 'git commit -m "kill switch: documented"' "a balanced quote that mentions kill"
allowed "echo \"it's a kill\"" "an apostrophe inside double quotes"
allowed 'fuser 8711/tcp' "fuser without -k only reads"
allowed 'pgrep -f heimdall-relay-client' "pgrep (read-only)"
allowed 'ps aux | grep heimdall-relay-client | grep -v grep' "ps | grep (read-only)"
allowed 'lsof -ti :8711' "lsof (read-only)"
allowed 'git commit -m "docs: never pkill -f heimdall-relay-client"' "a commit message that only mentions the command"
allowed 'git log --oneline --grep=kill' "git log --grep=kill"
allowed 'grep -rn "pkill -f heimdall-relay-client" docs' "grep for the text"
allowed 'echo "pkill -f heimdall-relay-client"' "echo of the text"
allowed 'bash -c "echo pkill"' "a shell string that only echoes the word"
allowed 'man pkill' "man pkill"
allowed 'command -v pkill' "command -v pkill (a lookup)"
allowed 'bash test/heimdall-app.test.sh' "running a suite"
allowed 'heimdall-gc uis --dry-run' "the sanctioned reaper"
allowed 'for f in $(ls test); do echo "$f"; done' "an ordinary loop"
allowed $'cat > notes.md <<\'EOF\'\npkill -f heimdall-relay-client\nkill $(pgrep x)\nEOF' "a heredoc body that only mentions the commands"
allowed $'cat <<\'EOF\'\nkill `date` $(date)\nEOF' "a quoted heredoc may contain substitutions"
allowed $'git commit -m "$(cat <<\'EOF\'\nfix: don\'t pkill things\n\nCo-Authored-By: x\nEOF\n)"' "a commit-message heredoc with an apostrophe that mentions pkill"
allowed $'python3 - <<\'EOF\'\nimport os\nprint(os.getpid())\nEOF' "a python heredoc that kills nothing"

# --- the HOOK fails closed: a guard that cannot answer has not cleared the command ---
denied 'kill 4242' "helper missing: even a literal-pid kill is only allowed when the guard says ok" "$BARE"
denied 'kill 4242' "helper crashes (exit 1)" "$CRASH"
denied 'kill 4242' "helper exits 0 but prints nothing" "$SILENT"
N=$((N + 1))
run_hook 'kill 4242' "$GARBAGE"
if [ "$RC" = 2 ] && jq -e '.error | test("hmd kill guard: not ok")' "$TMPROOT/out" >/dev/null 2>&1; then
  ok "$N. helper exits 3 with a quote and a backslash in its output: still a valid JSON deny"
else
  bad "$N. a garbage reason" "rc=$RC stdout=$(head -c 200 "$TMPROOT/out")"
fi
allowed 'ls -la' "a command that does not mention kill never reaches the guard, so a crashing helper cannot block it" "$CRASH"

# --- the guard itself: protocol, timeout ---
N=$((N + 1))
OUT="$(printf 'kill 4242' | python3 -I -S "$GUARD")"
GRC=$?
if [ "$GRC" = 0 ] && [ "$OUT" = ok ]; then
  ok "$N. guard protocol: an allowed command prints ok and exits 0"
else
  bad "$N. guard protocol" "rc=$GRC out=$OUT"
fi
N=$((N + 1))
python3 -I -c 'print("a " * 1500000 + "kill")' >"$TMPROOT/big.txt"
OUT="$(HMD_KILL_GUARD_TIMEOUT_S=0.01 python3 -I -S "$GUARD" <"$TMPROOT/big.txt")"
GRC=$?
if [ "$GRC" = 3 ] && printf '%s' "$OUT" | grep -q GuardTimeout; then
  ok "$N. a command that outlasts the guard's timeout is denied (exit 3, GuardTimeout), not passed"
else
  bad "$N. guard timeout" "rc=$GRC out=$(printf '%s' "$OUT" | head -c 160)"
fi

# --- no committed test, helper or bin script may do what the hook now denies (pkill -P <pid> is scoped to one parent: fine) ---
N=$((N + 1))
NAMES='(relay-client|hmd-ui|heimdall-app|pair-window)'
RE_PKILL='(pkill|killall)[[:space:]].*'"$NAMES"
RE_XARGS='pgrep[^|]*'"$NAMES"'[^|]*\|[[:space:]]*xargs[[:space:]]+kill'
HITS="$(grep -rInE -e "$RE_PKILL" -e "$RE_XARGS" \
          --exclude=hmd-server-kill-guard.test.sh --exclude=heimdall-precheck-bash --exclude=heimdall-precheck-bash.test.sh \
          --exclude=hmd_kill_guard.py \
          "$REPO/test" "$REPO/bin" "$REPO/hooks" "$REPO/sentinels" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE 'pkill[[:space:]]+(-[A-Za-z0-9]+[[:space:]]+)*-P' || true)"
if [ -z "$HITS" ]; then
  ok "$N. no committed test, helper or bin script pattern-kills an hmd server"
else
  bad "$N. a committed file pattern-kills an hmd server (it would unpair the operator's phone)" "$HITS"
fi

# The reaper: only orphans whose repo is gone or under a temp dir. The "real repo" is an existing directory outside every
# temp root the reaper is told about, and its processes are ppid 1 and very old -- exactly what a `hmd app connect --bg`
# client looks like in production.
cat >"$TMPROOT/reaper.py" <<'PY'
import os
import sys

repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "lib"))
import hmd_ui_procs as H

temp_root = os.path.realpath(os.path.join(tmp, "temp-root"))
real_repo = os.path.realpath(os.path.join(tmp, "real-repo"))
suite_repo = os.path.join(temp_root, "suite-repo")
vanished_repo = os.path.join(os.path.realpath(tmp), "vanished-repo")
os.makedirs(real_repo)
os.makedirs(suite_repo)
os.environ["HMD_UI_PROCS_TMP_ROOTS"] = temp_root


def proc(kind, pid, repo_path, port):
    script = "/opt/hmd/bin/heimdall-relay-client" if kind == "client" else "/opt/hmd/sentinels/hmd-ui.py"
    command = "/usr/bin/python3 %s --repo %s --ui-port %d" % (script, repo_path, port)
    p = H.Proc(pid, 1, 10 ** 6, command, command.split(), 1, kind)
    p.repo = os.path.realpath(repo_path)
    if kind == "client":
        p.ui_port = port
    else:
        p.port = port
    return p


def pids(procs):
    return sorted(p.pid for p in procs)


def say(label, good, detail):
    print(("ok " if good else "bad ") + label + ("" if good else " :: " + detail))


real = [proc("client", 101, real_repo, 8711), proc("ui", 102, real_repo, 8711)]
temp = [proc("client", 201, suite_repo, 8801), proc("ui", 202, suite_repo, 8801)]
gone = [proc("client", 301, vanished_repo, 8901)]

got = pids(H.orphans(real, 0))
say("reaper: a live relay client + ui of an existing non-temp repo (ppid 1, very old) is never an orphan", got == [], "selected %s" % got)
got = pids(H.orphans(real + temp + gone, 0))
say("reaper: among real, temp-repo and vanished-repo servers it selects exactly the temp-repo and vanished-repo ones", got == [201, 202, 301], "selected %s" % got)
got = pids(H.orphans([real[0]], 0))
say("reaper: a lone real-repo client (its ui absent from the survey) is still not an orphan", got == [], "selected %s" % got)
unreadable = H._identify(401, 1, 10 ** 6, "/usr/bin/python3 /opt/hmd/bin/heimdall-relay-client --repo /a b --ui-port 1")
say("reaper: a --repo value ps may have split at a space is skipped, never guessed", unreadable is None, "identified %r" % (unreadable,))
got = pids(H.superseded(real, real_repo, set(), set())) + pids(H.superseded([real[0]], real_repo, set(), set()))
say("supersede: never selects a relay client, nor a ui a live client serves", got == [], "selected %s" % got)
PY
python3 -I "$TMPROOT/reaper.py" "$REPO" "$TMPROOT" >"$TMPROOT/reaper.out" 2>"$TMPROOT/reaper.err"
REAPER_RC=$?
[ "$REAPER_RC" = 0 ] || bad "reaper cases did not run" "rc=$REAPER_RC $(head -c 300 "$TMPROOT/reaper.err")"
while IFS= read -r line; do
  N=$((N + 1))
  case "$line" in
    "ok "*) ok "$N. ${line#ok }" ;;
    *)      bad "$N. ${line#bad }" ;;
  esac
done <"$TMPROOT/reaper.out"

printf '\n  hmd-server-kill-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
