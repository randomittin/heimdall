#!/usr/bin/env bash
# test/heimdall-push-gate-target-repo.test.sh
#
# THE OPERATOR'S DEFECT, restated 2026-10-13, and the proof that it is fixed:
#
#   "The push gate checks the repo the session started in, not the repo being pushed. `cd X && git push` and
#    `git -C X push` are both graded against heimdall's own test record. It has to resolve the target repo from
#    -C, cd or the working directory, then apply that repo's own checks."
#
# THE SCENARIO. The session (the hook's cwd) is HEIMDALL: the real repo under test, a sweep repo. The push goes to another
# repo X that declares its own checks (.heimdall/repo-checks.json) and has, or has not, a record of them. Each way of aiming a
# push at X must be graded against X's OWN record -- green passes, red or absent blocks -- and heimdall's own test record must
# neither let a bad push through nor hold a good one back:
#   cd X && git push                      the hook runs in heimdall; the command moves to X first
#   git -C X push                         the hook runs in heimdall; -C names X
#   git push, cwd = X                     the working directory is X
#   git push, hook process in heimdall    the shell's own cwd (the payload's) is X: the session started in heimdall and
#                                         the Bash tool's shell moved to X
# Each is run against X green / X red / X with no receipt, with heimdall's own gate FAILING and with it PASSING (a fake
# heimdall-state that records every call): X's verdict must be the same both times, and heimdall's gate must never be asked.
# Then the same defect is shown for real, A against B: a heimdall fixture whose REAL heimdall-state is red, pushed through a
# plugin root without the resolver (the old behaviour: the gate on the cwd) is BLOCKED for a green X; with the resolver it passes.
# The reverse is proven too: heimdall's own push is still graded against heimdall's own record.
#
# Throwaway repos under one mktemp dir, removed on exit; the hook is the REAL bin/heimdall-precheck-bash; no real push is made.
# The wider surface (classes, forged receipts, fail-closed) is test/heimdall-push-gate-per-repo.test.sh.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC_BIN="$REPO/bin/heimdall-repo-checks"
HELPER="$REPO/bin/lib/hmd_push_target.py"
# HMD_TEST_PRECHECK_BASH lets the test be pointed at another hook -- the one before this fix, to watch every "graded on X's own
# record" case go RED against the old behaviour -- exactly as test/heimdall-precheck-bash.test.sh does with HMD_TEST_HOOKS_JSON.
HOOK="${HMD_TEST_PRECHECK_BASH:-$REPO/bin/heimdall-precheck-bash}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hmd-pushtarget.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
MARKS="$W/marks"; mkdir -p "$MARKS" "$W/repos"
# hermetic git; the resolver's time budget is generous because this runs beside a full sweep
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HMD_PUSH_TARGET_TIMEOUT_S=60
unset HEIMDALL_HOME HEIMDALL_STATE_FILE SUPERX_STATE_FILE GIT_DIR GIT_WORK_TREE CDPATH

new_repo() {
  local d="$W/repos/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false \
      && printf 'v1\n' > file.txt && printf '.heimdall/receipts/\n' > .gitignore && git add -A && git commit -q -m init )
  ( cd "$d" && pwd -P )
}
commit_all() { ( cd "$1" && git add -A && git commit -q -m "$2" ); }
decl_json() {  # decl_json <name> <cmd> [<name> <cmd> ...]
  local args=() filter='' sep='' i=0
  while [ $# -ge 2 ]; do
    args+=(--arg "n$i" "$1" --arg "c$i" "$2"); filter="$filter$sep{name:\$n$i,cmd:\$c$i}"; sep=','; i=$((i + 1)); shift 2
  done
  jq -nc "${args[@]}" "{schema:1, checks:[$filter]}"
}
mk_checks() {  # mk_checks <name> <declaration-json> -> a repo declaring its own checks
  local d; d="$(new_repo "$1")"
  mkdir -p "$d/.heimdall"; printf '%s\n' "$2" > "$d/.heimdall/repo-checks.json"; commit_all "$d" declare
  printf '%s' "$d"
}
mk_sweep() {  # a heimdall-like sweep repo
  local d; d="$(new_repo "$1")"
  mkdir -p "$d/test"; printf '#!/usr/bin/env bash\nRECEIPT_FILE="$RECEIPT_DIR/last-sweep.json"\n' > "$d/test/run-all.sh"; commit_all "$d" sweep
  printf '%s' "$d"
}

mk_plugin() {  # mk_plugin <name> [--no-resolver] [--real-state] -> a fake plugin root around the REAL hook
  local d="$W/plugin-$1" opt; shift
  mkdir -p "$d/bin/lib"
  cp "$HOOK" "$d/bin/heimdall-precheck-bash"
  cp "$RC_BIN" "$d/bin/heimdall-repo-checks" 2>/dev/null
  cp "$HELPER" "$REPO/bin/lib/hmd_repo_checks.py" "$REPO/bin/lib/hmd_repo_receipt.py" "$d/bin/lib/" 2>/dev/null
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
if [ "\${FAKE_HSTATE_RC:-0}" = 0 ]; then echo "All quality gates pass."; else echo "GATE FAILED: heimdall's own record is red" >&2; fi
exit "\${FAKE_HSTATE_RC:-0}"
EOF
  fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/secret-scan"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/parallelism-tracker"
  chmod +x "$d/bin/"*
  printf '%s' "$d"
}
PLUGIN="$(mk_plugin main)"
PLUGIN_REAL="$(mk_plugin real --real-state)"
PLUGIN_OLD="$(mk_plugin old --real-state --no-resolver)"   # the old behaviour: the gate on the cwd, whatever is pushed

run_hook() {  # run_hook <plugin> <hook-process-cwd> <command> [ENV=VAL ...] -> RC OUT ERR  (PAYLOAD_CWD rides in the payload)
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
state_calls() { wc -l < "$MARKS/state.calls" | tr -d ' '; }

# ── X: three repos that declare their own checks ──
X_GREEN="$(mk_checks x-green "$(decl_json lint 'true' integrity 'true')")"
X_RED="$(mk_checks x-red "$(decl_json lint 'true' broken 'exit 1')")"
X_NONE="$(mk_checks x-none "$(decl_json lint 'true' integrity 'true')")"
bash "$RC_BIN" run --repo "$X_GREEN" >/dev/null 2>&1; [ "$?" = 0 ] && ok "fixture: X green has a green record" || bad "fixture: X green"
bash "$RC_BIN" run --repo "$X_RED" >/dev/null 2>&1;   [ "$?" = 1 ] && ok "fixture: X red has a red record (a check exits 1)" || bad "fixture: X red"
[ ! -e "$X_NONE/.heimdall/receipts/repo-checks.json" ] && ok "fixture: X none has no receipt" || bad "fixture: X none has a receipt"

# heimdall = the session's cwd: the real repo under test, whose class is "sweep"
printf '\nthe session is in heimdall (%s)\n' "$(basename "$REPO")"
run_hook "$PLUGIN" "$REPO" 'git push' FAKE_HSTATE_RC=2
{ [ "$RC" = 2 ] && [ "$(state_calls)" = 1 ] && grep -q 'heimdall.s own record is red' <<<"$ERR"; } \
  && ok "sanity: a push OF heimdall is graded against heimdall's own record -> BLOCKED when that is red  [rc=2]" || bad "sanity: heimdall's own push, record red" "rc=$RC calls=$(state_calls) $ERR"
run_hook "$PLUGIN" "$REPO" 'git push' FAKE_HSTATE_RC=0
{ [ "$RC" = 0 ] && [ "$(state_calls)" = 1 ]; } && ok "sanity: ...and allowed when it is green  [rc=0]" || bad "sanity: heimdall's own push, record green" "rc=$RC calls=$(state_calls) $ERR"

# the four ways of aiming a push at X, each against X green / red / none, with heimdall's own gate failing and passing
check() {  # check <form label> <x label> <heimdall gate rc> <expect: pass|block> <x dir> <plugin cwd> <command> [payload cwd]
  local form="$1" xl="$2" hrc="$3" want="$4" x="$5" cwd="$6" cmd="$7" pcwd="${8:-}" why=""
  PAYLOAD_CWD="$pcwd" run_hook "$PLUGIN" "$cwd" "$cmd" FAKE_HSTATE_RC="$hrc"
  [ "$(state_calls)" = 0 ] || why="$why heimdall's own gate was asked ($(state_calls)x);"
  case "$want" in
    pass)
      [ "$RC" = 0 ] || why="$why rc=$RC, wanted 0;"
      grep -q 'repo-checks: GREEN' <<<"$ERR" || why="$why no GREEN verdict from X's record;" ;;
    block)
      [ "$RC" = 2 ] || why="$why rc=$RC, wanted 2;"
      printf '%s' "$OUT" | jq -e --arg x "$x" '.error | test("pre-push repo-checks gate failed for " + ($x | gsub("[.]"; "[.]"))) and test("heimdall-repo-checks run --repo")' >/dev/null 2>&1 \
        || why="$why the deny is not X's own record naming the runner;"
      case "$xl" in
        red)  printf '%s' "$OUT" | grep -q 'broken' || why="$why the failing check is not named;" ;;
        none) printf '%s' "$OUT" | grep -q 'no receipt' || why="$why 'no receipt' not said;" ;;
      esac ;;
  esac
  if [ -z "$why" ]; then ok "$form | X $xl | heimdall's gate $([ "$hrc" = 0 ] && echo passing || echo FAILING) -> graded on X's own record: $want  [rc=$RC]"; else bad "$form | X $xl | heimdall's gate rc=$hrc" "$why stdout: $(printf '%s' "$OUT" | head -c 240) stderr: $(printf '%s' "$ERR" | head -c 240)"; fi
}
for hrc in 2 0; do
  for xl in green red none; do
    case "$xl" in green) x="$X_GREEN"; want=pass ;; red) x="$X_RED"; want=block ;; none) x="$X_NONE"; want=block ;; esac
    check "cd X && git push                (hook cwd heimdall)" "$xl" "$hrc" "$want" "$x" "$REPO" "cd $x && git push"
    check "git -C X push                   (hook cwd heimdall)" "$xl" "$hrc" "$want" "$x" "$REPO" "git -C $x push"
    check "git push                        (cwd = X)"           "$xl" "$hrc" "$want" "$x" "$x"    "git push"
    check "git push (hook in heimdall, the shell's cwd = X)"    "$xl" "$hrc" "$want" "$x" "$REPO" "git push" "$x"
  done
done

# the same defect, for real: heimdall's REAL gate is red; before the fix X's good push was graded against it
printf '\nthe defect, before and after (heimdall'"'"'s REAL gate, red)\n'
H_FX="$(mk_sweep heimdall-fixture)"
( cd "$H_FX" && "$PLUGIN_REAL/bin/heimdall-state" init >/dev/null 2>&1 )
run_hook "$PLUGIN_REAL" "$H_FX" 'git push'
[ "$RC" = 2 ] && ok "fixture: heimdall's own record is really red (the real gate blocks a push of heimdall)  [rc=2]" || bad "fixture: heimdall fixture is not red" "rc=$RC $OUT"
for form in "cd $X_GREEN && git push" "git -C $X_GREEN push"; do
  run_hook "$PLUGIN_OLD" "$H_FX" "$form"
  { [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'pre-push quality gate failed'; } \
    && ok "BEFORE (no resolver, the gate on the cwd): [$form] is BLOCKED by heimdall's test record -- the defect  [rc=2]" || bad "BEFORE: the old behaviour did not block [$form]" "rc=$RC $OUT"
  run_hook "$PLUGIN_REAL" "$H_FX" "$form"
  { [ "$RC" = 0 ] && grep -q 'repo-checks: GREEN' <<<"$ERR"; } \
    && ok "AFTER  (the target resolved): [$form] passes on X's own green record  [rc=0]" || bad "AFTER: [$form] still blocked" "rc=$RC $OUT"
done
run_hook "$PLUGIN_REAL" "$X_GREEN" 'git push'
{ [ "$RC" = 0 ] && grep -q 'repo-checks: GREEN' <<<"$ERR"; } && ok "AFTER  (cwd = X): a plain push passes on X's own green record  [rc=0]" || bad "AFTER: plain push in X" "rc=$RC $OUT"
run_hook "$PLUGIN_REAL" "$H_FX" "git -C $X_RED push"
{ [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'repo-checks gate failed'; } && ok "AFTER  and the reverse: a red X is blocked by X's own record, not waved through on heimdall's account  [rc=2]" || bad "AFTER: red X" "rc=$RC $OUT"

printf '\n  heimdall-push-gate-target-repo: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
