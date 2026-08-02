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
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO/hooks/hooks.json"
STATE_BIN="$REPO/bin/heimdall-state"

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
mkdir -p "$FAKE_PLUGIN/bin"
cp "$STATE_BIN" "$FAKE_PLUGIN/bin/heimdall-state"
chmod +x "$FAKE_PLUGIN/bin/heimdall-state"

# run_hook <cwd> <command-string>  -> sets RC / OUT / ERR
run_hook() {
  local cwd="$1" cmd="$2" payload
  payload="$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')"
  OUT="$(cd "$cwd" && printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" PATH="$FAKE_PLUGIN/bin:$PATH" /bin/sh -c "$HOOK_CMD" 2>"$WORK/stderr")"
  RC=$?
  ERR="$(cat "$WORK/stderr")"
}

# fresh sandbox cwd for each case
new_cwd() { local d="$WORK/case$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

printf '\npre-push quality gate — blocking behaviour\n'
printf -- '--------------------------------------------------------------------\n'

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
( cd "$C" && "$FAKE_PLUGIN/bin/heimdall-state" init >/dev/null 2>&1 && "$FAKE_PLUGIN/bin/heimdall-state" mark-clean >/dev/null 2>&1 )
run_hook "$C" "git push origin main"
if [ "$RC" = 0 ]; then
  ok "clean gates => push PROCEEDS (exit 0)"
else
  bad "clean gates => push PROCEEDS (exit 0)" "got exit $RC; stdout=$OUT; stderr=$ERR"
fi
if printf '%s' "$OUT" | grep -q 'BLOCKED'; then
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
if printf '%s' "$ERR" | grep -qi 'UNAVAILABLE'; then
  ok "absent state file => verdict reported UNAVAILABLE on stderr (loud, not silent)"
else
  bad "absent state file => verdict reported UNAVAILABLE on stderr" "stderr=$ERR"
fi
if printf '%s' "$ERR" | grep -q 'heimdall-state init'; then
  ok "absent-state warning is ACTIONABLE (names the command that arms the gate)"
else
  bad "absent-state warning is ACTIONABLE" "stderr=$ERR"
fi

# === CASE 4: ANTI-VACUOUS — absent data must never be reported as a pass =====
if printf '%s' "$ERR" | grep -qi 'all quality gates pass'; then
  bad "absent state must NOT be reported as gates passing" "stderr=$ERR"
else
  ok "absent state is NOT reported as a pass (no vacuous green)"
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
# The defect was `; heimdall-state check-quality-gates;` with its exit code
# discarded. Assert the command never invokes check-quality-gates as a bare
# statement again (it must be captured into a variable or tested in a condition).
if printf '%s' "$HOOK_CMD" | grep -qE '(^|;|then|else|do|&&|\|\|)[[:space:]]+"?\$?(HSTATE|heimdall-state)"?[[:space:]]+check-quality-gates[[:space:]]*;'; then
  bad "check-quality-gates is not a bare fire-and-forget statement" "found the discarded-exit-code form in hooks.json"
else
  ok "check-quality-gates is not a bare fire-and-forget statement"
fi

# The positive half of the same lock: the verdict must actually be CAPTURED.
# Without this, deleting the call entirely would satisfy the negative check above.
if printf '%s' "$HOOK_CMD" | grep -qE '\$\([^)]*check-quality-gates'; then
  ok "check-quality-gates verdict is captured into a variable (exit code observable)"
else
  bad "check-quality-gates verdict is captured into a variable" "no \$( ... check-quality-gates ... ) capture found"
fi

printf -- '--------------------------------------------------------------------\n'
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
