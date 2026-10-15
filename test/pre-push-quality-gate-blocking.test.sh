#!/usr/bin/env bash
#
# pre-push-quality-gate-blocking.test.sh — BEHAVIOURAL proof that the pre-push
# quality gate BLOCKS, and that it blocks for the right reason only.
#
# WHY THIS FILE EXISTS
# --------------------
# CLAUDE.md promises: "Quality Gates (enforced before git push)". For a long time
# the pre-push chain in hooks/hooks.json did not keep that promise. The step read:
#
#     ... then heimdall-state check-quality-gates; if [ -x "$SCAN" ] ...
#
# `heimdall-state check-quality-gates` as a BARE STATEMENT. Its exit code is
# evaluated by /bin/sh and then thrown away. A non-zero verdict — the gate
# explicitly printing "Quality gates not met. Push blocked." — changed nothing.
# The push proceeded. The gate reported, and did not block: the same failure shape
# as the echo|jq bug that silently no-opped this entire chain (215 of 312 hook
# invocations), and the same shape as the five vacuously-green gates found on
# 2026-08-03.
#
# THE COMPLICATION THIS FILE PINS DOWN
# ------------------------------------
# "Just make it blocking" is WRONG, and this file proves the distinction that
# makes it right. `check-quality-gates` has three DISTINCT exit codes:
#
#     exit 0   verdict available, gates PASS          -> proceed
#     exit 2   verdict available, gates FAIL          -> BLOCK (the promise)
#     exit 1   no state file: NO VERDICT AT ALL       -> not a gate failure
#     exit 127 binary not on PATH: NO VERDICT AT ALL  -> not a gate failure
#
# heimdall-state.json is per-checkout local state; it does not exist in a fresh
# clone or in any agent worktree. And `heimdall-state init` writes
# tests_passing:false / lint_clean:false, so AUTO-INITIALISING would hand back
# exit 2 and block every push in every fresh checkout on day one. Treating "no
# verdict" as failure trains everyone to `git push --no-verify`, which disarms
# the whole chain — strictly worse than the advisory status quo it replaced.
#
# So the rule enforced here is: RESPECT THE VERDICT WHEN THERE IS ONE.
# Only exit 2 — the gate's own considered "gates failed" answer — blocks.
# "No verdict" proceeds, but LOUDLY, and it must never be reported as a pass.
# That last clause is the anti-vacuous clause, and it is tested as case 4:
# "absent data reported as clean" is exactly the pattern this sweep exists to
# kill, so an absent state file is asserted to NOT print a success verdict.
#
# ISOLATION — why CLAUDE_PLUGIN_ROOT points at a temp dir
# -------------------------------------------------------
# The hook command is run VERBATIM, exactly as the harness runs it (/bin/sh,
# JSON payload on stdin). NO REAL `git push` IS EVER PERFORMED and no remote is
# contacted: the hook is a PreToolUse gate, so it inspects the proposed command
# string and never executes it. CLAUDE_PLUGIN_ROOT is pointed at a temp dir
# holding ONLY bin/heimdall-state (a real copy of the shipped script), so every
# other step in the chain — secret-scan, heimdall-selfscan, falsify, corpus —
# skips itself via its own `[ -x ... ]` guard. That isolates the quality-gate
# step under test without stubbing anything: the gate binary under test is the
# real one, the steps not under test are simply absent.
#
# WHICH REPO, SINCE 2.4.8 (2026-10-13, "each repo's own checks, not heimdall's")
# ------------------------------------------------------------------------------
# The chain no longer runs this gate in whatever directory the session is in: it
# asks bin/lib/hmd_push_target.py which repository the push goes to and what class
# of gate that repository owes, read from its COMMITS (sweep: a committed
# test/run-all.sh naming last-sweep.json, heimdall's own regime, which is THIS gate;
# repo-checks; unmanaged). So the temp plugin root also carries that REAL resolver
# (and hmd_repo_receipt.py, which it imports: a root without them cannot place any
# push, and the chain then blocks every push), and each case's cwd is a real git
# repo with one commit, on main, that carries the sweep regime: what a fresh clone
# or an agent worktree of heimdall is. Two consequences, both on purpose:
#   - in a git checkout `heimdall-state check-quality-gates` also demands a green
#     sweep receipt (test/run-all.sh is its writer), so "clean gates" in case 2
#     includes one;
#   - a push the resolver cannot place exactly (here: a cwd with no repository) is
#     graded strictly AND a strict gate that was never evaluated BLOCKS instead of
#     warning. "No verdict proceeds" is for a repository positively known to be
#     heimdall's own (case 3); case 4b pins the rest.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO/hooks/hooks.json"
STATE_BIN="$REPO/bin/heimdall-state"
# hermetic: the fixture repos and the resolver's own git calls read nothing from this
# machine (config, hooks, signing, a stray GIT_DIR), and the gate reads its state and
# its sweep receipt from the fixture repo, never from a HEIMDALL_HOME or state file
# named in the caller's environment
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE HEIMDALL_HOME HEIMDALL_STATE_FILE SUPERX_STATE_FILE
TAB=$'\t'

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# --- extract the Bash PreToolUse hook command, verbatim -----------------------
HOOK_CMD="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command' "$HOOKS_JSON" 2>/dev/null)"
if [ -z "$HOOK_CMD" ]; then
  printf '%sFATAL%s could not extract Bash PreToolUse command from %s\n' "$RED" "$RESET" "$HOOKS_JSON"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A plugin root containing ONLY the gate under test.
FAKE_PLUGIN="$WORK/plugin"
mkdir -p "$FAKE_PLUGIN/bin/lib"
# The chain body lives in bin/heimdall-precheck-bash; hooks.json's command is
# just the stdin-pipe wrapper into "$PLUGIN/bin/heimdall-precheck-bash". The
# fake plugin therefore carries the REAL script (the code under test) alongside
# the one gate bin whose verdict this file is about.
cp "$REPO/bin/heimdall-precheck-bash" "$FAKE_PLUGIN/bin/heimdall-precheck-bash"
chmod +x "$FAKE_PLUGIN/bin/heimdall-precheck-bash"
cp "$STATE_BIN" "$FAKE_PLUGIN/bin/heimdall-state"
chmod +x "$FAKE_PLUGIN/bin/heimdall-state"
# ...and the REAL resolver the script asks which repository a push goes to (it imports
# hmd_repo_receipt). Not a fake either. heimdall-repo-checks and hmd_repo_checks.py are
# left out on purpose: no case here declares checks of its own.
cp "$REPO/bin/lib/hmd_push_target.py" "$REPO/bin/lib/hmd_repo_receipt.py" "$FAKE_PLUGIN/bin/lib/"

# run_hook <cwd> <command-string>  -> sets RC / OUT / ERR
run_hook() {
  local cwd="$1" cmd="$2" payload
  payload="$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')"
  OUT="$(cd "$cwd" && printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" PATH="$FAKE_PLUGIN/bin:$PATH" /bin/sh -c "$HOOK_CMD" 2>"$WORK/stderr")"
  RC=$?
  ERR="$(cat "$WORK/stderr")"
}

# fresh sandbox cwd for each case: a real git repo on main with ONE commit, heimdall's own sweep regime. The committed
# test/run-all.sh naming last-sweep.json is what makes the chain grade a push of it with THIS gate (the class is read from the
# commits, never the work tree); the branch is main because `git push origin main` names a ref that must exist, as it does in
# a real checkout.
new_cwd() {
  local d="$WORK/case$1"
  rm -rf "$d"; mkdir -p "$d/test"
  printf 'RECEIPT_FILE="$RECEIPT_DIR/last-sweep.json"\n' > "$d/test/run-all.sh"
  ( cd "$d" && git init -q && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
      && git add test/run-all.sh && git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "the sweep writer" )
  printf '%s' "$d"
}
# A green, current, clean FULL sweep receipt for the repo's HEAD. In a git checkout heimdall-state demands one (a sweep repo that
# never recorded a green sweep is refused whatever its state booleans say), so "clean gates" is only clean with it.
green_sweep_receipt() {  # green_sweep_receipt <repo>
  local top head
  top="$(git -C "$1" rev-parse --show-toplevel)"
  head="$(git -C "$1" rev-parse HEAD)"
  mkdir -p "$top/.heimdall/receipts"
  jq -n --arg r "$top" --arg h "$head" '{kind: "full", repo: $r, head_sha: $h, tree_clean: true, exit_code: 0}' > "$top/.heimdall/receipts/last-sweep.json"
}

printf '\npre-push quality gate — blocking behaviour\n'
printf -- '--------------------------------------------------------------------\n'

# === CASE 0: fixture sanity — each case's cwd is a repo the resolver POSITIVELY places as class sweep ==
# Every outcome below rests on it: a cwd the resolver could not place is graded by the strict fallback row instead, and a case
# that expects a BLOCK (1) would then pass for the wrong reason.
C="$(new_cwd 0)"
ROW="$(cd "$C" && printf '%s' 'git push origin main' | python3 -I -S "$FAKE_PLUGIN/bin/lib/hmd_push_target.py" "$C" 2>&1)"
case "$ROW" in
  "sweep${TAB}"*"${TAB}-${TAB}/"*) ok "fixture: each case's cwd is positively class sweep (heimdall's own regime), not the strict fallback" ;;
  *) bad "fixture: each case's cwd is positively class sweep (heimdall's own regime)" "resolver said: $ROW" ;;
esac

# === CASE 1: verdict available and FAILING -> must BLOCK =====================
C="$(new_cwd 1)"
( cd "$C" && "$FAKE_PLUGIN/bin/heimdall-state" init >/dev/null 2>&1 )   # init defaults: tests_passing=false
run_hook "$C" "git push origin main"
if [ "$RC" = 2 ]; then
  ok "failing gates + state present => push BLOCKED (exit 2)"
else
  bad "failing gates + state present => push BLOCKED (exit 2)" "got exit $RC; stdout=$OUT"
fi
if printf '%s' "$OUT" | jq -e '.error | test("BLOCKED")' >/dev/null 2>&1; then
  ok "block emits a JSON .error containing BLOCKED (renders to the user)"
else
  bad "block emits a JSON .error containing BLOCKED" "stdout=$OUT"
fi
if printf '%s' "$OUT" | jq -e '.error | test("quality gate"; "i")' >/dev/null 2>&1; then
  ok "block message names the quality gate as the cause"
else
  bad "block message names the quality gate as the cause" "stdout=$OUT"
fi
if printf '%s' "$OUT" | jq -e '.error | test("mark-clean")' >/dev/null 2>&1; then
  ok "block message is ACTIONABLE (tells the user the command to run)"
else
  bad "block message is ACTIONABLE (tells the user the command to run)" "stdout=$OUT"
fi

# === CASE 2: verdict available and PASSING -> must NOT block =================
C="$(new_cwd 2)"
( cd "$C" && "$FAKE_PLUGIN/bin/heimdall-state" init >/dev/null 2>&1 && HMD_LINT_WAIVER="fixture: pre-push blocking is not about lint evidence" "$FAKE_PLUGIN/bin/heimdall-state" mark-clean >/dev/null 2>&1 )
green_sweep_receipt "$C"
run_hook "$C" "git push origin main"
if [ "$RC" = 0 ]; then
  ok "clean gates => push PROCEEDS (exit 0)"
else
  bad "clean gates => push PROCEEDS (exit 0)" "got exit $RC; stdout=$OUT; stderr=$ERR"
fi
if grep -q 'BLOCKED' <<<"$OUT"; then
  bad "clean gates => no BLOCKED verdict emitted" "stdout=$OUT"
else
  ok "clean gates => no BLOCKED verdict emitted"
fi

# === CASE 3: NO verdict (absent state) -> must NOT block, but must be LOUD ===
C="$(new_cwd 3)"
run_hook "$C" "git push origin main"
if [ "$RC" = 0 ]; then
  ok "absent state file => push PROCEEDS (fresh clone / worktree stays usable)"
else
  bad "absent state file => push PROCEEDS" "got exit $RC; stdout=$OUT; stderr=$ERR"
fi
if grep -qi 'UNAVAILABLE' <<<"$ERR"; then
  ok "absent state file => verdict reported UNAVAILABLE on stderr (loud, not silent)"
else
  bad "absent state file => verdict reported UNAVAILABLE on stderr" "stderr=$ERR"
fi
if grep -q 'heimdall-state init' <<<"$ERR"; then
  ok "absent-state warning is ACTIONABLE (names the command that arms the gate)"
else
  bad "absent-state warning is ACTIONABLE" "stderr=$ERR"
fi

# === CASE 4: ANTI-VACUOUS — absent data must never be reported as a pass =====
if grep -qi 'all quality gates pass' <<<"$ERR"; then
  bad "absent state must NOT be reported as gates passing" "stderr=$ERR"
else
  ok "absent state is NOT reported as a pass (no vacuous green)"
fi

# === CASE 4b: a cwd the chain cannot place (no repository) + NO verdict -> must BLOCK =====
# The 2.4.8 narrowing of case 3: "no verdict proceeds" holds for a repository the chain positively identified as heimdall's own.
# A push it cannot place exactly is uncertain, graded strictly, and a strict gate that was never evaluated is not a pass.
C="$WORK/no-repository"
rm -rf "$C"; mkdir -p "$C"
run_hook "$C" "git push origin main"
if [ "$RC" = 2 ] && printf '%s' "$OUT" | jq -e '.error | test("BLOCKED") and test("cannot grade this push") and test("never evaluated")' >/dev/null 2>&1; then
  ok "no repository + absent state file => push BLOCKED (a gate that was never evaluated is not a pass for a push the chain cannot place)"
else
  bad "no repository + absent state file => push BLOCKED" "got exit $RC; stdout=$OUT; stderr=$ERR"
fi

# === CASE 5: gate is scoped to push, not to every Bash command ===============
C="$(new_cwd 5)"
( cd "$C" && "$FAKE_PLUGIN/bin/heimdall-state" init >/dev/null 2>&1 )   # failing gates present
run_hook "$C" "ls -la"
if [ "$RC" = 0 ]; then
  ok "non-push command is not blocked by the quality gate (scope preserved)"
else
  bad "non-push command is not blocked by the quality gate" "got exit $RC; stdout=$OUT"
fi

# === CASE 6: structural — hooks.json stays valid JSON ========================
if jq . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json is valid JSON"
else
  bad "hooks.json is valid JSON" "jq failed to parse"
fi

# === CASE 7: regression lock — the bare-statement form must not come back ====
# The structural greps below read the CHAIN TEXT. hooks.json used to carry it
# inline; it now delegates to bin/heimdall-precheck-bash, so when the shipped
# command does not itself contain check-quality-gates, read the script it names.
CHAIN_TEXT="$HOOK_CMD"
if ! grep -q 'check-quality-gates' <<<"$HOOK_CMD" && grep -q 'heimdall-precheck-bash' <<<"$HOOK_CMD"; then
  CHAIN_TEXT="$(grep -v '^[[:space:]]*#' "$REPO/bin/heimdall-precheck-bash")"
fi
# The defect was `; heimdall-state check-quality-gates;` with its exit code
# discarded. Assert the command never invokes check-quality-gates as a bare
# statement again (it must be captured into a variable or tested in a condition).
if grep -qE '(^|;|then|else|do|&&|\|\|)[[:space:]]+"?\$?(HSTATE|heimdall-state)"?[[:space:]]+check-quality-gates[[:space:]]*;' <<<"$CHAIN_TEXT"; then
  bad "check-quality-gates is not a bare fire-and-forget statement" "found the discarded-exit-code form in hooks.json"
else
  ok "check-quality-gates is not a bare fire-and-forget statement"
fi

# The positive half of the same lock: the verdict must actually be CAPTURED and its exit code READ.
# Without this, deleting the call entirely would satisfy the negative check above. Every
# `VAR=$( ... check-quality-gates ... )` must be followed at once by the line that reads its status (`QGRC=$?`).
# The substitution may WRAP the call: since 2.4.8 the chain hands the gate the git directory and work tree the resolver
# resolved, `$(case "$PG_GITDIR" in (/*) export GIT_DIR=... ;; esac; "$HSTATE" check-quality-gates 2>&1)`, so the
# parentheses of that case pattern now sit between the `$(` and the call, past what the old `\$\([^)]*check-quality-gates`
# could see. The lock is the same, and one thing stricter: it is the status being read, not just a `$(` being present.
if awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\(.*check-quality-gates/ { n++; if ((getline nxt) > 0 && nxt ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\?/) ok++ } END { exit !(n > 0 && n == ok) }' <<<"$CHAIN_TEXT"; then
  ok "check-quality-gates verdict is captured into a variable (exit code observable)"
else
  bad "check-quality-gates verdict is captured into a variable" "no VAR=\$( ... check-quality-gates ... ) capture followed by a read of \$? found"
fi

printf -- '--------------------------------------------------------------------\n'
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
