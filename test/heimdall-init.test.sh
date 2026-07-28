#!/usr/bin/env bash
# test/heimdall-init.test.sh — the universal git core (Layer 0) contract.
#
# WHAT THIS GATES. `hmd init` must turn ANY git repo into a working watchman with
# git alone in the loop — NO Claude Code, NO plugin runtime, NO MCP:
#   1. Installs git hooks via core.hooksPath=.heimdall/hooks WITHOUT clobbering a
#      repo's own hooks — a pre-existing pre-commit is CHAINED (still runs, first).
#   2. pre-commit runs the configured gates headless (reusing bin/falsify over the
#      repo's oracle domains). DENY = nonzero + a BIFRÖST block on stderr, no commit.
#   3. HMD_SKIP=1 proceeds BUT writes a VISIBLE unproven-merge receipt.
#   4. post-commit fires a fire-and-forget presence beat (local beat spool proves it),
#      never blocking the commit.
#   5. `hmd verdict` prints the repo's last gate result.
#   6. `hmd init` / `hmd verdict` route through bin/heimdall (args forwarded, no
#      Claude fall-through).
#
# HERMETIC. Every repo is a throwaway temp git repo; HOME is redirected so nothing
# touches the real ~/.heimdall or the control plane. The whole gated-commit flow runs
# under a PATH that has git + hmd but PROVABLY NO `claude` binary — the "clean
# container" proof that the universal core needs no Claude Code.
#
# EXIT: 0 = every proof holds; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="$REPO/bin"
INIT_BIN="$BIN/heimdall-init"
GATE_BIN="$BIN/heimdall-gate-run"
VERDICT_BIN="$BIN/heimdall-verdict"
REAL_HEIMDALL="$BIN/heimdall"
# DEFAULT-ON egress guard: `hmd init` generates a post-commit hook that shells the REAL
# `heimdall-presence beat` (fire-and-forget). Under this test's fresh, undecided HOME the flip
# would otherwise resolve the baked-in PROD control plane. Pin the default at a dead port so the
# post-commit beat can never reach prod (it stays a local-spool + refused-connection no-op).
. "$REPO/test/lib/net-default-guard.sh"

for b in "$INIT_BIN" "$GATE_BIN" "$VERDICT_BIN" "$REAL_HEIMDALL"; do
  [ -x "$b" ] || { echo "FATAL: missing/!exec $b" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-init.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.heimdall"
# neutralise the auto-share network probe: keep team-auto local + silent.
export HEIMDALL_NO_TEAM_AUTOSHARE=1

# ── a PATH with git + hmd but NO claude (the clean-container proof) ────────────
SANDBOX="$WORK/sandbox-bin"; mkdir -p "$SANDBOX"
ln -sf "$REAL_HEIMDALL" "$SANDBOX/hmd"
NOCLAUDE_PATH="$SANDBOX"
for t in git jq python3 date sed grep head cat mkdir chmod readlink basename dirname mktemp env bash rm ls touch printf sort wc; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] || continue
  d="$(dirname "$p")"
  case ":$NOCLAUDE_PATH:" in *":$d:"*) ;; *) NOCLAUDE_PATH="$NOCLAUDE_PATH:$d" ;; esac
done

# git identity for every repo we create.
gitcfg() { git -C "$1" config user.email dev@example.com; git -C "$1" config user.name Dev; }

# newrepo DIR — a fresh initialized git repo.
newrepo() { mkdir -p "$1"; git -C "$1" init -q; gitcfg "$1"; }

# Drop a REAL oracle domain whose single mutant SURVIVES -> bin/falsify score 0.0
# -> a genuine DENY through the real gate path (evals/ is fixture territory).
mk_deny_domain() {
  local dom="$1/evals/oracles/deny-demo"
  mkdir -p "$dom/fixtures/golden" "$dom/fixtures/mutants"
  printf '{"id":"deny-demo","golden_input":"fixtures/golden/candidate.txt"}\n' > "$dom/gate.json"
  printf 'GOLDEN\n' > "$dom/fixtures/golden/candidate.txt"
  printf 'MUTANT\n'  > "$dom/fixtures/mutants/m1.txt"
  printf '{"domain":"deny-demo","mutants":[{"name":"m1","file":"m1.txt"}]}\n' > "$dom/fixtures/mutants/manifest.json"
  cat > "$dom/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -u
report=""
while [ $# -gt 0 ]; do case "$1" in --report) report="$2"; shift 2;; --input|--truth) shift 2;; *) shift;; esac; done
# ALWAYS pass -> golden passes AND the mutant survives -> the gate cannot go red.
[ -n "$report" ] && printf '{"gate_id":"deny-demo","status":"pass","wave":"w0"}\n' > "$report"
exit 0
RUNEOF
  chmod +x "$dom/run.sh"
}

# run a git command inside a repo under the NO-CLAUDE path.
gitrun() { local r="$1"; shift; ( cd "$r" && env PATH="$NOCLAUDE_PATH" HOME="$HOME" git "$@" ); }
commits_of() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }

echo "════════════════════════════════════════════════════════════════"
echo "hmd init — universal git core (Layer 0)  [clean container: no CC]"
echo "════════════════════════════════════════════════════════════════"

# ── 0. NO CLAUDE CODE on the path (the whole flow proves it) ──────────────────
if PATH="$NOCLAUDE_PATH" command -v claude >/dev/null 2>&1; then
  bad "0 a 'claude' binary is reachable on the test PATH — not a clean-container proof" "$(PATH="$NOCLAUDE_PATH" command -v claude)"
else
  ok "0 NO 'claude' on PATH — git + hmd only (clean-container proof holds)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1. install: hooks + hooksPath + chaining pointer
# ══════════════════════════════════════════════════════════════════════════════
R1="$WORK/r1"; newrepo "$R1"
( cd "$R1" && env PATH="$NOCLAUDE_PATH" HOME="$HOME" "$INIT_BIN" ) >/dev/null 2>&1
HP="$(git -C "$R1" config --get core.hooksPath 2>/dev/null || true)"
[ "$HP" = ".heimdall/hooks" ] && ok "1a core.hooksPath = .heimdall/hooks" || bad "1a core.hooksPath wrong" "got '$HP'"
_all=1
for h in pre-commit pre-push post-commit; do [ -x "$R1/.heimdall/hooks/$h" ] || _all=0; done
[ "$_all" = 1 ] && ok "1b pre-commit + pre-push + post-commit installed and executable" || bad "1b a generated hook is missing/not executable"
PREV="$(git -C "$R1" config --get heimdall.prevHooksPath 2>/dev/null || true)"
case "$PREV" in */.git/hooks) ok "1c prior hooksPath recorded for chaining (.git/hooks)" ;; *) bad "1c prevHooksPath wrong" "got '$PREV'" ;; esac

# ══════════════════════════════════════════════════════════════════════════════
# 2. green commit: no oracle domain -> gate passes -> commit succeeds + verdict pass
#    + the post-commit beat fires (local spool entry)
# ══════════════════════════════════════════════════════════════════════════════
printf 'hello\n' > "$R1/a.txt"
gitrun "$R1" add -A >/dev/null 2>&1
gitrun "$R1" commit -m "first" >/dev/null 2>"$WORK/r1c.err"; R1EX=$?
[ "$R1EX" = 0 ] && [ "$(commits_of "$R1")" = 1 ] && ok "2a a clean repo commits (gate green with no domains)" || bad "2a green commit failed (exit=$R1EX, commits=$(commits_of "$R1"))" "$(cat "$WORK/r1c.err")"
V1="$( cd "$R1" && "$VERDICT_BIN" --field verdict 2>/dev/null )"
[ "$V1" = "pass" ] && ok "2b verdict.json persisted verdict=pass" || bad "2b verdict not pass" "got '$V1'"
if [ -s "$R1/.heimdall/receipts/beats.log" ] && grep -q "	pass	" "$R1/.heimdall/receipts/beats.log"; then
  ok "2c post-commit beat fired — a 'pass' beat spool entry was written (never blocked the commit)"
else
  bad "2c no beat spool entry after commit" "$(cat "$R1/.heimdall/receipts/beats.log" 2>/dev/null)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. DENY: a repo whose oracle gate cannot go red is BLOCKED at commit
# ══════════════════════════════════════════════════════════════════════════════
R2="$WORK/r2"; newrepo "$R2"; mk_deny_domain "$R2"
( cd "$R2" && env PATH="$NOCLAUDE_PATH" HOME="$HOME" "$INIT_BIN" ) >/dev/null 2>&1
gitrun "$R2" add -A >/dev/null 2>&1
gitrun "$R2" commit -m "blocked" >/dev/null 2>"$WORK/r2c.err"; R2EX=$?
[ "$R2EX" != 0 ] && ok "3a DENY: pre-commit exited nonzero (commit refused)" || bad "3a a red gate did NOT block the commit (exit=$R2EX)"
[ "$(commits_of "$R2")" = 0 ] && ok "3b DENY: NO commit was created (HEAD has 0 commits)" || bad "3b a blocked commit still landed" "commits=$(commits_of "$R2")"
grep -q "BIFRÖST" "$WORK/r2c.err" && ok "3c DENY: the BIFRÖST verdict block was printed on stderr" || bad "3c no BIFRÖST block on stderr" "$(cat "$WORK/r2c.err")"
V2="$( cd "$R2" && "$VERDICT_BIN" --field verdict 2>/dev/null )"
[ "$V2" = "deny" ] && ok "3d verdict.json persisted verdict=deny" || bad "3d verdict not deny" "got '$V2'"

# ══════════════════════════════════════════════════════════════════════════════
# 4. HMD_SKIP=1 proceeds BUT logs a visible unproven-merge receipt
# ══════════════════════════════════════════════════════════════════════════════
( cd "$R2" && env PATH="$NOCLAUDE_PATH" HOME="$HOME" HMD_SKIP=1 git commit -m "skip" ) >/dev/null 2>"$WORK/r2s.err"; SKEX=$?
[ "$SKEX" = 0 ] && [ "$(commits_of "$R2")" = 1 ] && ok "4a HMD_SKIP=1 bypassed the red gate and the commit landed" || bad "4a HMD_SKIP did not proceed (exit=$SKEX, commits=$(commits_of "$R2"))" "$(cat "$WORK/r2s.err")"
RCPT="$R2/.heimdall/receipts/unproven.log"
if [ -s "$RCPT" ] && grep -q "HMD_SKIP" "$RCPT"; then
  ok "4b an unproven-merge receipt was logged (visible, never silent) → .heimdall/receipts/unproven.log"
else
  bad "4b no HMD_SKIP receipt written" "$(cat "$RCPT" 2>/dev/null)"
fi
grep -qi "HMD_SKIP=1" "$WORK/r2s.err" && ok "4c the skip warned loudly on stderr" || bad "4c the skip was silent on stderr"
# FALSIFIER: the skip must NOT run the gate (verdict stays the prior 'deny', not refreshed to pass).
V2b="$( cd "$R2" && "$VERDICT_BIN" --field verdict 2>/dev/null )"
[ "$V2b" = "deny" ] && ok "4d falsifier: HMD_SKIP did NOT silently re-run/greenwash the gate (verdict still deny)" || bad "4d a skipped commit mutated the verdict" "got '$V2b'"

# ══════════════════════════════════════════════════════════════════════════════
# 5. beat-from-hook wiring: post-commit shells the real presence beat + spool
# ══════════════════════════════════════════════════════════════════════════════
if [ -s "$R2/.heimdall/receipts/beats.log" ]; then
  ok "5a post-commit ran on the skipped commit and wrote a beat spool entry"
else
  bad "5a no beat spool after the skip commit"
fi
if grep -q 'heimdall-presence' "$R2/.heimdall/hooks/post-commit" && grep -q 'beat --verdict' "$R2/.heimdall/hooks/post-commit"; then
  ok "5b the generated post-commit invokes heimdall-presence beat (reuses the beat plumbing)"
else
  bad "5b post-commit does not call heimdall-presence beat"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. EXISTING-HOOKSPATH CHAINING falsifier: a prior pre-commit STILL runs AND the
#    hmd gate runs; strip the chain -> the prior side-effect disappears (RED-line)
# ══════════════════════════════════════════════════════════════════════════════
R3="$WORK/r3"; newrepo "$R3"
cat > "$R3/.git/hooks/pre-commit" <<'PEOF'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/PRIOR_HOOK_RAN"
exit 0
PEOF
chmod +x "$R3/.git/hooks/pre-commit"
( cd "$R3" && env PATH="$NOCLAUDE_PATH" HOME="$HOME" "$INIT_BIN" ) >/dev/null 2>&1
printf 'x\n' > "$R3/f.txt"
gitrun "$R3" add -A >/dev/null 2>&1
gitrun "$R3" commit -m "chain" >/dev/null 2>"$WORK/r3c.err"; R3EX=$?
[ "$R3EX" = 0 ] && ok "6a chained commit succeeded" || bad "6a chained commit failed (exit=$R3EX)" "$(cat "$WORK/r3c.err")"
[ -f "$R3/PRIOR_HOOK_RAN" ] && ok "6b the PRE-EXISTING pre-commit STILL ran (its side-effect is present)" || bad "6b the prior hook was CLOBBERED — chaining broken"
V3="$( cd "$R3" && "$VERDICT_BIN" --field verdict 2>/dev/null )"
[ "$V3" = "pass" ] && ok "6c the hmd gate ALSO ran alongside the prior hook (verdict persisted)" || bad "6c the hmd gate did not run under chaining" "got '$V3'"
# structural: the generated hook actually contains the chain call.
grep -q 'prevHooksPath' "$R3/.heimdall/hooks/pre-commit" && grep -q '"$PREV/$HOOK"' "$R3/.heimdall/hooks/pre-commit" \
  && ok "6d the generated pre-commit contains the chain invocation" || bad "6d generated hook lacks the chain call"
# RED-LINE falsifier: remove the chain pointer -> the prior hook must NO LONGER run.
rm -f "$R3/PRIOR_HOOK_RAN"
git -C "$R3" config --unset heimdall.prevHooksPath 2>/dev/null || true
printf 'y\n' > "$R3/g.txt"
gitrun "$R3" add -A >/dev/null 2>&1
gitrun "$R3" commit -m "no-chain" >/dev/null 2>&1
[ ! -f "$R3/PRIOR_HOOK_RAN" ] && ok "6e falsifier: with the chain pointer stripped, the prior hook does NOT run (chaining is load-bearing)" || bad "6e prior hook ran without a chain pointer — the chain assertion is not falsifiable"

# ══════════════════════════════════════════════════════════════════════════════
# 7. `hmd verdict` prints the repo's last result
# ══════════════════════════════════════════════════════════════════════════════
OUT1="$( cd "$R1" && "$VERDICT_BIN" 2>/dev/null )"
printf '%s' "$OUT1" | grep -q "PASS" && ok "7a hmd verdict prints PASS for the green repo" || bad "7a verdict PASS not shown" "$OUT1"
OUT2="$( cd "$R2" && "$VERDICT_BIN" 2>/dev/null )"
printf '%s' "$OUT2" | grep -q "DENY" && ok "7b hmd verdict prints DENY for the blocked repo" || bad "7b verdict DENY not shown" "$OUT2"
OUTX="$( cd "$WORK" && git init -q nozone 2>/dev/null; cd "$WORK/nozone" && "$VERDICT_BIN" 2>/dev/null )"
printf '%s' "$OUTX" | grep -qi "none yet" && ok "7c hmd verdict degrades cleanly when no gate has run" || bad "7c no-verdict message wrong" "$OUTX"

# ══════════════════════════════════════════════════════════════════════════════
# 8. ROUTING: `hmd init` / `hmd verdict` route through bin/heimdall, args forwarded,
#    no Claude fall-through (fake-plugin-dir stub pattern, per heimdall-cli-routing)
# ══════════════════════════════════════════════════════════════════════════════
FAKE="$WORK/fake"; mkdir -p "$FAKE/bin" "$FAKE/home" "$FAKE/.claude-plugin"
cp "$REAL_HEIMDALL" "$FAKE/bin/heimdall"; chmod +x "$FAKE/bin/heimdall"
touch "$FAKE/home/setup-done"
cat > "$FAKE/bin/claude" <<'E'
#!/usr/bin/env bash
exit 0
E
chmod +x "$FAKE/bin/claude"
STUB_OUT="$WORK/stub.out"; TRACE="$WORK/trace.out"; : > "$STUB_OUT"; : > "$TRACE"
for name in heimdall-init heimdall-verdict; do
  cat > "$FAKE/bin/$name" <<EOB
#!/usr/bin/env bash
printf '%s ARGS: %s\n' "$name" "\$*" >> "\${HMD_STUB_OUT:-/dev/null}"
exit 0
EOB
  chmod +x "$FAKE/bin/$name"
done
run_fake() {
  PATH="$FAKE/bin:$PATH" HEIMDALL_HOME="$FAKE/home" HEIMDALL_NO_INTRO=1 \
    HEIMDALL_NO_UPDATE_CHECK=1 HMD_STUB_OUT="$STUB_OUT" HEIMDALL_TRACE_ORDER="$TRACE" \
    bash "$FAKE/bin/heimdall" "$@" >/dev/null 2>&1 || true
}
: > "$STUB_OUT"; : > "$TRACE"; run_fake init --force
grep -q "heimdall-init" "$STUB_OUT" && grep -qF -- "--force" "$STUB_OUT" \
  && ok "8a hmd init routes to heimdall-init with args forwarded" || bad "8a init routing failed" "$(cat "$STUB_OUT")"
grep -q "launch:task" "$TRACE" && bad "8b hmd init WRONGLY fell through to the Claude launch path" || ok "8b hmd init does NOT fall through to Claude"
: > "$STUB_OUT"; : > "$TRACE"; run_fake verdict --json
grep -q "heimdall-verdict" "$STUB_OUT" && grep -qF -- "--json" "$STUB_OUT" \
  && ok "8c hmd verdict routes to heimdall-verdict with args forwarded" || bad "8c verdict routing failed" "$(cat "$STUB_OUT")"
grep -q "launch:task" "$TRACE" && bad "8d hmd verdict WRONGLY fell through to Claude" || ok "8d hmd verdict does NOT fall through to Claude"

# ══════════════════════════════════════════════════════════════════════════════
# 9. syntax: the bins AND the generated hooks parse clean
# ══════════════════════════════════════════════════════════════════════════════
_syn=1
for f in "$INIT_BIN" "$GATE_BIN" "$VERDICT_BIN" "$REAL_HEIMDALL" \
         "$R1/.heimdall/hooks/pre-commit" "$R1/.heimdall/hooks/pre-push" "$R1/.heimdall/hooks/post-commit"; do
  bash -n "$f" 2>/dev/null || { _syn=0; echo "        bad syntax: $f" >&2; }
done
[ "$_syn" = 1 ] && ok "9 all bins + generated hooks pass bash -n" || bad "9 a bin or generated hook has a syntax error"

echo
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
