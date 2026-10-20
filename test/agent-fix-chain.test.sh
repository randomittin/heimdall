#!/usr/bin/env bash
# agent-fix-chain harness
#
# Covers the fix-chain advisory in bin/heimdall-precheck-agent (2026-10-21; CLAUDE.md "Release convergence").
# Measured on 2.4.9: six chained rounds in one evening, each round spawning a fix agent for a MEDIUM/LOW finding
# that only existed because of the previous fix. The hook cannot know a finding's severity, but it can count:
# past HMD_FIX_CHAIN_MAX (default 3) finding-fix spawns in one session, the spawn being made gets one line on
# stderr naming the triage rule. It is ADVICE: exit 0 always, never the {"error": ...} document of a deny,
# silenced by HMD_FIX_CHAIN_ALLOW=1. "A finding-fix spawn" is defined ONCE, in bin/lib/hmd_fix_chain.sh, which
# bin/heimdall-conformance (the `fix-chain` transcript gate) reads too; test/protocol-conformance.test.sh (Q)
# proves that half of the definition from the transcript side.
#
# Falsifiable both ways: the 4th finding-fix spawn warns and the first three do not; an unrelated spawn, a fix
# with no finding, a finding with no fix and look-alike words (prefix, fixture) neither warn nor touch the state
# (the pre-filter: other spawns pay nothing); sessions are counted apart; no session id means no counter; the
# override lifts it only as exactly 1; every fail-open path (occupied state dir, a directory where the counter
# file should be, an unparsable payload, no jq, no lib next to the hook) is silent and exit 0; the section has no
# `exit`; and three mutants of the hook (boundary, classification, override) each flip a verdict.
#
# Hermetic: every invocation gets its own HOME/HEIMDALL_HOME under a mktemp sandbox, and runs the REAL hook with
# HMD_MIN_FREE_PCT=0 (the disk-floor fence would otherwise read THIS machine's free space) and HMD_CTX_GATE_OFF=1
# (the context fence would otherwise consult ambient state for a payload that carries a session id), like
# test/agent-name-gate.test.sh and test/agent-inproc-cap.test.sh. Following the one-suite-per-hook-section pattern of
# test/agent-inproc-cap.test.sh:1-24 and test/agent-ctxgate-fence.test.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
REALPATH="$PATH"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[ -f "$REAL_HOOK" ] || { echo "FATAL: missing $REAL_HOOK" >&2; exit 2; }

# The mute switch and the knob must not leak in from the caller, or every warning below would be suppressed or moved.
unset HMD_FIX_CHAIN_ALLOW HMD_FIX_CHAIN_MAX

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-fix-chain.XXXXXX")"
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# fire_raw HOOK HOME PAYLOAD [VAR=value ...]  -> RC, $OUT, $ERR   (runs from the sandbox, in a clean environment)
fire_raw() {
  local hook="$1" home="$2" pl="$3"
  shift 3
  : >"$OUT"; : >"$ERR"
  ( cd "$SANDBOX" && printf '%s' "$pl" | env -i "HOME=$home" "HEIMDALL_HOME=$home/.heimdall" "PATH=${FIRE_PATH:-$REALPATH}" \
      "HMD_MIN_FREE_PCT=0" "HMD_CTX_GATE_OFF=1" "$@" bash "$hook" >"$OUT" 2>"$ERR" )
  RC=$?
}

# fire HOOK HOME SESSION|- DESCRIPTION PROMPT [VAR=value ...]   (SESSION "-" = a payload with no session_id)
fire() {
  local hook="$1" home="$2" sid="$3" desc="$4" prompt="$5" pl
  shift 5
  if [ "$sid" = "-" ]; then
    pl="$(jq -cn --arg d "$desc" --arg p "$prompt" '{tool_input:{subagent_type:"hmd:coder",description:$d,prompt:$p}}')"
  else
    pl="$(jq -cn --arg s "$sid" --arg d "$desc" --arg p "$prompt" '{session_id:$s,tool_input:{subagent_type:"hmd:coder",description:$d,prompt:$p}}')"
  fi
  fire_raw "$hook" "$home" "$pl" "$@"
}

new_home() { mkdir -p "$SANDBOX/home.$1"; printf '%s' "$SANDBOX/home.$1"; }
# lines FILE -> the number of lines (the counter file holds one line per finding-fix spawn), 0 when absent
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '0'; fi; }

MSG_TAIL='finding-fix agents this cycle; triage by severity (heimdall-findings) — only BLOCKER/HIGH get a fix agent; MEDIUM/LOW go to the backlog'
expect_silent() { # expect_silent <label>   exit 0, nothing on stdout (no deny document), no fix-chain line on stderr
  if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && ! grep -qF 'fix-chain:' "$ERR"; then ok "$1"; else bad "$1 (rc=$RC out=[$(cat "$OUT")] err=[$(cat "$ERR")])"; fi
}
expect_warn() { # expect_warn <label> <count already spawned>   exit 0, nothing on stdout, the exact line on stderr
  if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && grep -qF "fix-chain: $2 $MSG_TAIL" "$ERR"; then ok "$1"; else bad "$1 (rc=$RC out=[$(cat "$OUT")] err=[$(cat "$ERR")])"; fi
}

echo "agent-fix-chain harness"
echo "--------------------------------------------------------------------"

# ── 0. the subject exists and is wired the way it must stay ───────────────────────────────────
bash -n "$REAL_HOOK" 2>/dev/null && ok "real hook parses (bash -n)" || bad "real hook fails bash -n"
[ -r "$REPO/bin/lib/hmd_fix_chain.sh" ] && ok "the shared definition bin/lib/hmd_fix_chain.sh exists" || bad "bin/lib/hmd_fix_chain.sh is missing — the hook has nothing to classify with"
if grep -q 'hmd_fix_chain.sh' "$REAL_HOOK" && ! grep -qE 'security\[ -\]review|reviewers\?' "$REAL_HOOK"; then
  ok "the hook sources the shared definition and carries no private copy of the finding regex (one definition, two callers)"
else
  bad "the hook does not source lib/hmd_fix_chain.sh, or holds its own finding regex — the gate and the warning can drift apart"
fi
SECTION="$(sed -n '/^# -- fix-chain advisory/,/^# -- end fix-chain advisory/p' "$REAL_HOOK")"
if [ -z "$SECTION" ]; then
  bad "could not isolate the fix-chain advisory section (markers moved?) — the no-exit check below would be vacuous"
elif grep -v '^[[:space:]]*#' <<<"$SECTION" | grep -qE '(^|[^A-Za-z_])exit([[:space:]]|$)'; then
  bad "the fix-chain advisory contains an exit — some input path could end the hook, and it must never be able to deny"
else
  ok "the fix-chain advisory contains no exit — it can warn, it cannot deny"
fi

# ── 1. the default limit: the 4th finding-fix spawn warns, the first three do not ─────────────
H1="$(new_home 1)"
C1="$H1/.heimdall/fix-chain/sess-one"
for i in 1 2 3; do
  fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F$i" "Fix the finding F$i from the security review"
  expect_silent "spawn $i of 3 (within the limit): silent, exit 0, no deny document"
done
[ "$(lines "$C1")" = 3 ] && ok "the per-session counter holds 3 after three finding-fix spawns" || bad "counter is $(lines "$C1"), want 3"
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F4" "Fix the finding F4 from the security review"
expect_warn "the 4th finding-fix spawn WARNS with the exact triage line (3 already spawned) — exit 0, never a deny" 3
grep -qF 'HMD_FIX_CHAIN_ALLOW=1' "$ERR" && ok "the warning names the override (HMD_FIX_CHAIN_ALLOW=1)" || bad "the warning does not name how to silence it"
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F5" "Fix the finding F5 from the security review"
expect_warn "the 5th warns too and counts what is already spawned (4): the loop did not stop, so neither does the line" 4
[ "$(lines "$C1")" = 5 ] && ok "every finding-fix spawn is counted, the warned ones included (5)" || bad "counter is $(lines "$C1"), want 5"

# ── 2. other spawns pay nothing: no warning, no count, no state touched ───────────────────────
H2="$(new_home 2)"
fire "$REAL_HOOK" "$H2" sess-two "Write the release notes" "Draft the notes for the next release"
expect_silent "an unrelated spawn (no fix in the payload at all) is silent"
fire "$REAL_HOOK" "$H2" sess-two "Fix lint errors in bin/x" "Fix the lint errors"
expect_silent "a fix with no review or security finding is silent"
fire "$REAL_HOOK" "$H2" sess-two "Review the security finding F2" "Review it"
expect_silent "a finding with no fix is silent"
fire "$REAL_HOOK" "$H2" sess-two "Update the fixture and prefix files" "Keep the reviewer finding intact. Prefix the suffix."
expect_silent "look-alike words (fixture, prefix, suffix) are not the verb fix"
[ ! -e "$H2/.heimdall/fix-chain" ] && ok "none of them touched the state dir: the cheap path never reached the filesystem" || bad "an unrelated spawn created $H2/.heimdall/fix-chain"
for i in 1 2 3; do fire "$REAL_HOOK" "$H2" sess-two "Fix reviewer finding F$i" ""; done
fire "$REAL_HOOK" "$H2" sess-two "Write the release notes" "Draft the notes for the next release"
expect_silent "an unrelated spawn in the middle of a chain does not warn"
[ "$(lines "$H2/.heimdall/fix-chain/sess-two")" = 3 ] && ok "...and is not counted (the counter still reads 3)" || bad "an unrelated spawn changed the counter to $(lines "$H2/.heimdall/fix-chain/sess-two")"
fire "$REAL_HOOK" "$H2" sess-two "Fix reviewer finding F4" ""
expect_warn "the next finding-fix spawn is therefore the 4th and warns (a description alone classifies it)" 3

# ── 3. sessions are counted apart ─────────────────────────────────────────────────────────────
fire "$REAL_HOOK" "$H1" sess-other "Fix security finding F1" "Fix the finding F1 from the security review"
expect_silent "a different session on the same machine starts at zero, whatever the first session reached"
[ "$(lines "$H1/.heimdall/fix-chain/sess-other")" = 1 ] && [ "$(lines "$C1")" = 5 ] \
  && ok "each session keeps its own counter file (sess-one 5, sess-other 1)" || bad "counters bled across sessions"

# ── 4. no session id, no counter: never borrow another session's state ────────────────────────
H4="$(new_home 4)"
fire "$REAL_HOOK" "$H4" - "Fix security finding F1" "Fix the finding F1 from the security review" HMD_FIX_CHAIN_MAX=0
expect_silent "a payload with no session_id is silent even when the limit is 0 (it has nothing to count under)"
[ ! -e "$H4/.heimdall/fix-chain" ] && ok "...and writes no state" || bad "a spawn with no session id wrote state"

# ── 5. the override ───────────────────────────────────────────────────────────────────────────
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F6" "Fix the finding F6 from the security review" HMD_FIX_CHAIN_ALLOW=1
expect_silent "HMD_FIX_CHAIN_ALLOW=1 silences the warning"
[ "$(lines "$C1")" = 5 ] && ok "...and runs nothing of the guard: the counter did not move (5)" || bad "the override still counted: $(lines "$C1")"
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F7" "Fix the finding F7 from the security review" HMD_FIX_CHAIN_ALLOW=yes
expect_warn "only exactly 1 lifts it: HMD_FIX_CHAIN_ALLOW=yes still warns" 5

# ── 6. the limit is a knob, and a typo is the default, never off ──────────────────────────────
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F8" "Fix the finding F8 from the security review" HMD_FIX_CHAIN_MAX=99
expect_silent "HMD_FIX_CHAIN_MAX=99 raises the limit past the 6 already spawned"
fire "$REAL_HOOK" "$H1" sess-one "Fix security finding F9" "Fix the finding F9 from the security review" HMD_FIX_CHAIN_MAX=three
expect_warn "a value that is not a number is the default (3), not a silent off" 7
H6="$(new_home 6)"
fire "$REAL_HOOK" "$H6" sess-six "Fix security finding F1" "Fix the finding F1 from the security review" HMD_FIX_CHAIN_MAX=1
expect_silent "HMD_FIX_CHAIN_MAX=1: the first spawn is within the limit"
fire "$REAL_HOOK" "$H6" sess-six "Fix security finding F2" "Fix the finding F2 from the security review" HMD_FIX_CHAIN_MAX=1
expect_warn "HMD_FIX_CHAIN_MAX=1: the second spawn is past it" 1

# ── 7. FAIL OPEN: nothing here can cost a spawn, warn wrongly or deny ─────────────────────────
# Each case would warn on its SECOND spawn at HMD_FIX_CHAIN_MAX=1 if the counter worked, so two silent spawns
# prove the failure was swallowed rather than the counting never being reached.
failopen() { # failopen <label> <hook> <home> [PATH override]
  local label="$1" hook="$2" home="$3"
  FIRE_PATH="${4:-$REALPATH}"
  fire "$hook" "$home" sess-fo "Fix security finding F1" "Fix the finding F1 from the security review" HMD_FIX_CHAIN_MAX=1
  local rc1="$RC"
  fire "$hook" "$home" sess-fo "Fix security finding F2" "Fix the finding F2 from the security review" HMD_FIX_CHAIN_MAX=1
  FIRE_PATH=""
  if [ "$rc1" = 0 ] && [ "$RC" = 0 ] && [ ! -s "$OUT" ] && ! grep -qF 'fix-chain:' "$ERR"; then ok "$label"; else bad "$label (rc=$rc1/$RC out=[$(cat "$OUT")] err=[$(cat "$ERR")])"; fi
}
H7a="$(new_home 7a)"; mkdir -p "$H7a/.heimdall"; printf 'a file where the state dir should be\n' > "$H7a/.heimdall/fix-chain"
failopen "a regular file occupying the state dir: silent, exit 0, no deny" "$REAL_HOOK" "$H7a"
H7b="$(new_home 7b)"; mkdir -p "$H7b/.heimdall/fix-chain/sess-fo"
failopen "a directory where the counter file should be: silent, exit 0, no deny" "$REAL_HOOK" "$H7b"
H7c="$(new_home 7c)"
fire_raw "$REAL_HOOK" "$H7c" '{"session_id":"sess-fo","tool_input":{"description":"Fix security finding' HMD_FIX_CHAIN_MAX=0
expect_silent "a truncated payload that passes the pre-filter (it says Fix) is silent, exit 0"
H7d="$(new_home 7d)"
make_fakebin() { local dir="$1" t src; shift; mkdir -p "$dir"; for t in "$@"; do src="$(command -v "$t" 2>/dev/null)" || continue; ln -sf "$src" "$dir/$t"; done; }
make_fakebin "$SANDBOX/nojq" bash cat dirname readlink date wc tr mkdir df awk sed grep rm mktemp
failopen "no jq on PATH: silent, exit 0, no deny" "$REAL_HOOK" "$H7d" "$SANDBOX/nojq"
H7e="$(new_home 7e)"
mkdir -p "$SANDBOX/nolib/bin"; cp "$REAL_HOOK" "$SANDBOX/nolib/bin/heimdall-precheck-agent"
failopen "no lib next to the hook (a sandbox copy): silent, exit 0, no deny" "$SANDBOX/nolib/bin/heimdall-precheck-agent" "$H7e"

# ── 8. MUTATION RED-PROOFS: disarm one rule of a COPY of the hook, the verdict must flip ──────
mkdir -p "$SANDBOX/mut/bin"
ln -s "$REPO/bin/lib" "$SANDBOX/mut/bin/lib"
mutate_hook() { # mutate_hook <sed script> -> $SANDBOX/mut/bin/heimdall-precheck-agent; fails when the edit missed
  sed "$1" "$REAL_HOOK" > "$SANDBOX/mut/bin/heimdall-precheck-agent"
  chmod +x "$SANDBOX/mut/bin/heimdall-precheck-agent"
  ! cmp -s "$SANDBOX/mut/bin/heimdall-precheck-agent" "$REAL_HOOK"
}
MUT_HOOK="$SANDBOX/mut/bin/heimdall-precheck-agent"
HM="$(new_home m1)"
if mutate_hook 's/-ge "\$(hmd_fix_chain_max)"/-gt "$(hmd_fix_chain_max)"/'; then
  fire "$MUT_HOOK" "$HM" sess-m "Fix security finding F1" "Fix the finding F1 from the security review" HMD_FIX_CHAIN_MAX=1
  fire "$MUT_HOOK" "$HM" sess-m "Fix security finding F2" "Fix the finding F2 from the security review" HMD_FIX_CHAIN_MAX=1
  ! grep -qF 'fix-chain:' "$ERR" && ok "M1 KILLED: warning on one MORE spawn than the limit (-gt for -ge) leaves the second spawn silent -> section 6's boundary is a real check" \
    || bad "M1 SURVIVED: the off-by-one mutant still warned on the second spawn"
else
  bad "M1 NOT APPLIED: the threshold comparison no longer matches — this mutation proof is dead"
fi
HM="$(new_home m2)"
if mutate_hook 's/hmd_finding_fix(\$t.description; \$t.prompt)/true/'; then
  fire "$MUT_HOOK" "$HM" sess-m "Fix lint errors in bin/x" "Fix the lint errors"
  [ -e "$HM/.heimdall/fix-chain/sess-m" ] && ok "M2 KILLED: classifying every fix as a finding-fix creates state for a fix with no finding -> section 2 is a real check" \
    || bad "M2 SURVIVED: the mutant that skips classification still left a fix with no finding uncounted"
else
  bad "M2 NOT APPLIED: the classification call no longer matches — this mutation proof is dead"
fi
HM="$(new_home m3)"
if mutate_hook 's/HMD_FIX_CHAIN_ALLOW:-}" != "1"/HMD_FIX_CHAIN_ALLOW:-}" != "never"/'; then
  fire "$MUT_HOOK" "$HM" sess-m "Fix security finding F1" "Fix the finding F1 from the security review" HMD_FIX_CHAIN_ALLOW=1 HMD_FIX_CHAIN_MAX=0
  grep -qF 'fix-chain:' "$ERR" && ok "M3 KILLED: ignoring the override warns on an HMD_FIX_CHAIN_ALLOW=1 spawn -> section 5 is a real check" \
    || bad "M3 SURVIVED: the mutant that ignores the override was still silent"
else
  bad "M3 NOT APPLIED: the override test no longer matches — this mutation proof is dead"
fi
cmp -s "$REAL_HOOK" "$MUT_HOOK" && bad "the last mutant is byte-identical to the shipped hook — the mutations edited the wrong file" \
  || ok "every mutant is a sandboxed COPY; bin/heimdall-precheck-agent itself is never edited"

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
