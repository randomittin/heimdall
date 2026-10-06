#!/usr/bin/env bash
# test/heimdall-dash.test.sh -- `hmd dash`: the dispatcher arm in bin/heimdall -> bin/heimdall-dash ->
# bin/lib/dashboard_producers.py.
#
# WHAT THIS GATES. The dash arm is a thin pass-through, like ui) / app) / attack): it must NOT resolve an
# interpreter or source a lib inline (heimdall-landmine-lint class 5 flags that after the uninstall arm;
# test/landmine-lint.test.sh section B is the fence). The behaviour the arm used to carry lives in
# bin/heimdall-dash and is pinned here through a recording interpreter (HMD_PYTHON is hmd_python's
# explicit-override seam):
#   1. --repo defaults to $CLAUDE_PROJECT_DIR, else the git toplevel, else the cwd (the order `hmd app`
#      uses); an explicit --repo is forwarded untouched, with no second one added;
#   2. the module path and every argument arrive byte-exact (a space, an empty argument, a quote survive)
#      and stdin is left exactly as the caller had it;
#   3. the lib is found relative to the script's own location, also when it is run through a symlink;
#   4. no python -> exit 2 naming HMD_PYTHON; no producers module -> exit 1 pointing at the reinstall;
#   5. the arm routes `hmd dash <args>` to bin/heimdall-dash, args verbatim and the word `dash` dropped;
#      a missing wrapper refuses cleanly (exit 1, names the file, points at the reinstall).
# The terminal half of the stdin contract (`confirm` / `connector add` refusing without a tty) is
# test/dashboards-e2e.test.sh, which drives the real dispatcher on a pty.
#
# EXIT: 0 = every assertion holds; 1 = FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
WRAPPER="$REPO/bin/heimdall-dash"
PRODUCERS="$(cd "$REPO/bin" && pwd -P)/lib/dashboard_producers.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
finish() { printf "\n  Results: %d passed, %d failed\n" "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

[ -x "$WRAPPER" ] || { bad "bin/heimdall-dash missing or not executable ($WRAPPER)"; finish; }
[ -r "$PRODUCERS" ] || { bad "bin/lib/dashboard_producers.py missing ($PRODUCERS)"; finish; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-heimdall-dash.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The recording interpreter: the wrapper must exec it with the module path and the args, stdin untouched.
RECORDER="$WORK/recorder"
cat > "$RECORDER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DASH_TEST_ARGV"
cat > "$DASH_TEST_STDIN"
EOF
chmod +x "$RECORDER"
ARGV="$WORK/argv"; STDIN_SEEN="$WORK/stdin-seen"

GITREPO="$WORK/gitrepo"; mkdir -p "$GITREPO/sub/deeper"; git init -q "$GITREPO" 2>/dev/null
PROJ_DIR="$WORK/proj"; PLAIN="$WORK/plain"; mkdir -p "$PROJ_DIR" "$PLAIN"
TOPLEVEL="$(git -C "$GITREPO/sub" rev-parse --show-toplevel)"
PLAIN_PWD="$(cd "$PLAIN" && pwd)"

# run <cwd> <args...> -- run $BIN (default: the real wrapper) with the recording interpreter. stdin comes from
# $IN (default /dev/null); CLAUDE_PROJECT_DIR is $CPD when non-empty, else removed from the environment. git
# cannot climb above $WORK, so a "plain" directory is plain wherever the suite runs.
run() {
  local cwd="$1"; shift
  : > "$ARGV"; : > "$STDIN_SEEN"
  (
    cd "$cwd" || exit 99
    if [ -n "${CPD:-}" ]; then export CLAUDE_PROJECT_DIR="$CPD"; else unset CLAUDE_PROJECT_DIR; fi
    export HMD_PYTHON="$RECORDER" DASH_TEST_ARGV="$ARGV" DASH_TEST_STDIN="$STDIN_SEEN" GIT_CEILING_DIRECTORIES="$WORK"
    "${BIN:-$WRAPPER}" "$@" < "${IN:-/dev/null}"
  )
}

# check_argv <label> <expected argv...> -- what the recording interpreter saw, one argument per line.
check_argv() {
  local label="$1" got want; shift
  got="$(cat "$ARGV")"; want="$(printf '%s\n' "$@")"
  if [ "$got" = "$want" ]; then ok "$label"
  else bad "$label -- got: $(printf '%s' "$got" | tr '\n' '|')  want: $(printf '%s' "$want" | tr '\n' '|')"; fi
}

echo "1. --repo default: CLAUDE_PROJECT_DIR, else the git toplevel, else the cwd"
CPD="$PROJ_DIR" run "$GITREPO/sub" ls
check_argv "CLAUDE_PROJECT_DIR wins over the git toplevel" "$PRODUCERS" --repo "$PROJ_DIR" ls
CPD="" run "$GITREPO/sub/deeper" ls
check_argv "no CLAUDE_PROJECT_DIR: the git toplevel, from a subdirectory" "$PRODUCERS" --repo "$TOPLEVEL" ls
CPD="" run "$PLAIN" ls
check_argv "no CLAUDE_PROJECT_DIR, not a git repo: the cwd" "$PRODUCERS" --repo "$PLAIN_PWD" ls
CPD="$PROJ_DIR" run "$GITREPO" --repo /explicit/repo pending
check_argv "an explicit --repo is forwarded untouched, no second one added" "$PRODUCERS" --repo /explicit/repo pending

echo "2. arguments and stdin reach the module untouched"
CPD="$PROJ_DIR" run "$GITREPO" show "a b" "" 'c"d'
check_argv "arguments survive byte-exact (a space, an empty argument, a quote)" "$PRODUCERS" --repo "$PROJ_DIR" show "a b" "" 'c"d'
printf 'typed-answer\n' > "$WORK/typed"
IN="$WORK/typed" CPD="$PROJ_DIR" run "$GITREPO" confirm T1
if [ "$(cat "$STDIN_SEEN")" = "typed-answer" ]; then ok "stdin is neither read nor redirected by the wrapper"
else bad "stdin was consumed or redirected: [$(cat "$STDIN_SEEN")]"; fi

echo "3. the lib is found next to the real script, also through a symlink"
mkdir -p "$WORK/link"; ln -s "$WRAPPER" "$WORK/link/hmd-dash"
BIN="$WORK/link/hmd-dash" CPD="$PROJ_DIR" run "$GITREPO" ls
check_argv "run through a symlink" "$PRODUCERS" --repo "$PROJ_DIR" ls

echo "4. refusals: no interpreter, no producers module"
NOPY="$WORK/nopy/bin"; mkdir -p "$NOPY/lib"
cp "$WRAPPER" "$NOPY/heimdall-dash"; : > "$NOPY/lib/dashboard_producers.py"
out="$(BIN="$NOPY/heimdall-dash" CPD="$PROJ_DIR" run "$GITREPO" ls 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'hmd dash needs a working python3' <<<"$out" && grep -qF 'HMD_PYTHON' <<<"$out" \
   && grep -qF 're-run: hmd dash ls' <<<"$out"; then
  ok "no resolver lib -> no interpreter: exit 2, names HMD_PYTHON and the command to re-run"
else bad "no interpreter (rc=$rc): $out"; fi
NOPROD="$WORK/noprod/bin"; mkdir -p "$NOPROD/lib"
cp "$WRAPPER" "$NOPROD/heimdall-dash"; cp "$REPO/bin/lib/hmd-python.sh" "$NOPROD/lib/"
out="$(BIN="$NOPROD/heimdall-dash" CPD="$PROJ_DIR" run "$GITREPO" ls 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'dashboard_producers.py not found' <<<"$out" && grep -qF 'Reinstall:' <<<"$out"; then
  ok "no producers module: exit 1, points at the reinstall"
else bad "no producers module (rc=$rc): $out"; fi

echo "5. the dispatcher arm routes to bin/heimdall-dash"
FAKE="$WORK/fake"; FAKE_BIN="$FAKE/bin"; FAKE_HOME="$FAKE/home"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$FAKE/.claude-plugin"
cp "$REPO/bin/heimdall" "$FAKE_BIN/heimdall"; chmod +x "$FAKE_BIN/heimdall"
touch "$FAKE_HOME/setup-done"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/claude"; chmod +x "$FAKE_BIN/claude"
# dispatch <args...> -- the real dispatcher, copied beside whatever wrapper this case provides, isolated HOME.
dispatch() {
  PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" HEIMDALL_HOME="$FAKE_HOME" HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 \
    bash "$FAKE_BIN/heimdall" "$@" </dev/null 2>&1
}
out="$(dispatch dash ls)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'heimdall-dash not found at' <<<"$out" && grep -qF 'Reinstall:' <<<"$out"; then
  ok "no bin/heimdall-dash beside the dispatcher: exit 1, names the file, points at the reinstall"
else bad "missing wrapper (rc=$rc): $out"; fi
ROUTED="$WORK/routed"
cat > "$FAKE_BIN/heimdall-dash" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ROUTED"
EOF
chmod +x "$FAKE_BIN/heimdall-dash"
: > "$ROUTED"
dispatch dash connector ls --x "a b" >/dev/null
if [ "$(cat "$ROUTED")" = "$(printf '%s\n' connector ls --x 'a b')" ]; then
  ok "hmd dash <args> reaches bin/heimdall-dash with the args verbatim and the word dash dropped"
else bad "routing: wrapper saw [$(tr '\n' '|' < "$ROUTED")]"; fi

finish
