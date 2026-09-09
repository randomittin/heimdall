#!/usr/bin/env bash
#
# agent-ctxgate-fence.test.sh — proof for the "context gate fence" in
# bin/heimdall-precheck-agent, the sixth PreToolUse/Agent fence, added
# alongside the existing adjudication and coop native-spawn refusal fences.
#
# WHY THIS FILE EXISTS
# --------------------
# bin/heimdall-ctx-meter gate is an existing, settled, 119-assertion-tested
# decision (test/ctx-meter.test.sh): ok/checkpoint below the hard ceiling,
# defer at-or-past it whenever the boundary isn't provably clean (a live
# agent, or a dirty tree), refuse only at-or-past it AND with a clean
# boundary (0 live agents, `git status --porcelain` empty). Until this fence,
# `gate` had zero consumers — a tested refusal mechanism nobody ever called.
# This file proves the NEW consumer wiring in bin/heimdall-precheck-agent,
# never bin/heimdall-ctx-meter's own decision logic (that stays
# test/ctx-meter.test.sh's job, untouched and unduplicated here).
#
# WHAT THIS SUITE PROVES
# -----------------------
#   1. Static: the fence exists (start/end markers), sits after the coop
#      fence and before the brief-adoption gate, documents its escape hatch,
#      and never re-derives the boundary itself (no direct
#      `heimdall-agents`/`git status` calls of its own — it must trust
#      gate's verdict completely, never re-check the question gate already
#      answered).
#   2. Sandboxed, fully-controlled behavior against a FAKE
#      bin/heimdall-ctx-meter test double (mirrors ONLY the `gate --json` /
#      `gate --session <sid> --json` call the fence itself makes, driven by
#      FAKE_CTXMETER_MODE — never real token counts or repo state): denies
#      only decision=refuse at exit 1, allows ok/checkpoint/defer, and fails
#      OPEN on every plumbing gap (absent binary, non-executable, garbage
#      output, a contract-violating rc=1 body, and a hang bounded by the same
#      perl-alarm idiom the brief-adoption gate already uses). An argv-marker
#      side channel proves the session id is actually threaded through via
#      --session when the payload carries one, and omitted when it doesn't
#      (never silently falling back to heimdall-ctx-meter's own
#      cross-session newest-record guess while a real id was available).
#   3. TWO RED-PROOFS (mutation tests, pattern: test/agent-fallback-
#      coop.test.sh): a "no-op-fence" mutant (deny neutered) proves the real
#      exit 2 is load-bearing by making the SAME deny-scenario wrongly pass;
#      an "always-fence" mutant (decision check replaced with `if true`)
#      proves the decision=="refuse" gate is a real discriminator by making
#      a currently-allowed garbage-output scenario wrongly get denied.
#   4. Adjudication-undisturbed is NOT re-tested here (this file isolates the
#      ctx gate fence only, same boundary test/agent-fallback-coop.test.sh
#      draws around itself) — every `fire` below pins ANTHROPIC_BASE_URL to
#      the real Anthropic endpoint so the unrelated adjudication fence can
#      never itself trigger and confound an assertion. The adjudication
#      fence's own undisturbed behavior is proven by running
#      test/agent-fallback-adjudication.test.sh itself (53 passed, 0 failed,
#      confirmed the same session this fence was added).
#
# Usage: bash test/agent-ctxgate-fence.test.sh   (exit 0 = all green)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
BASH_ABS="$(command -v bash)"
REAL_PATH="$PATH"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "agent-ctxgate-fence (precheck-agent context gate fence)  repo=$REPO"

SANDBOX="$(mktemp -d)"
ERRF="$(mktemp)"
ARGVMARK="$(mktemp -u)"
cleanup() { rm -rf "$SANDBOX" "$ERRF" "$ARGVMARK"; }
trap cleanup EXIT

mkdir -p "$SANDBOX/bin"
cp "$REAL_HOOK" "$SANDBOX/bin/heimdall-precheck-agent"
chmod +x "$SANDBOX/bin/heimdall-precheck-agent"

# Test double for bin/heimdall-ctx-meter: mirrors ONLY the fence's own call
# shape (`gate --json` or `gate --session <sid> --json`), driven entirely by
# FAKE_CTXMETER_MODE. FAKE_CTXMETER_ARGV_MARKER records the exact argv this
# double was invoked with, so a case can prove not just the exit code but
# whether --session was actually threaded through.
cat > "$SANDBOX/bin/heimdall-ctx-meter" <<'FAKE'
#!/bin/sh
if [ -n "${FAKE_CTXMETER_ARGV_MARKER:-}" ]; then
  printf '%s\n' "$*" > "$FAKE_CTXMETER_ARGV_MARKER"
fi
mode="${FAKE_CTXMETER_MODE:-ok}"
case "$mode" in
  ok)
    printf '{"decision":"ok","state":"ok","tokens":118678,"reason":"below ceiling"}\n'
    exit 0
    ;;
  checkpoint)
    printf '{"decision":"checkpoint","state":"cliff_near","tokens":720000,"reason":"approaching hard ceiling"}\n'
    exit 0
    ;;
  defer)
    printf '{"decision":"defer","state":"cliff","tokens":850000,"reason":"live agent still running"}\n'
    exit 0
    ;;
  refuse)
    printf '{"decision":"refuse","state":"cliff","tokens":900000,"reason":"no live agents, clean tree -- a clean boundary to stop new work at"}\n'
    exit 1
    ;;
  garbage)
    printf 'not valid json{{{\n'
    exit 1
    ;;
  rc1-not-refuse)
    printf '{"decision":"ok","state":"ok","tokens":1,"reason":"contract-violation probe -- exit 1 body claims ok, not refuse"}\n'
    exit 1
    ;;
  hang)
    # exec (not a plain foreground `sleep 30`) replaces THIS process's own
    # image in place -- no forked grandchild ends up holding the stdout
    # pipe's write end. That distinction is exactly what the fence's
    # perl-alarm bound can and cannot reach: SIGALRM terminates the ONE PID
    # perl called alarm() on (preserved across exec, POSIX-guaranteed) --
    # instantly unblocking the fence's command substitution once THIS PID
    # dies -- but a separately forked child holding the same fd open would
    # keep that pipe open regardless of whether this PID is killed. Real
    # heimdall-ctx-meter forking a grandchild that itself hangs (e.g. a
    # wedged `git status`) is a distinct, pre-existing characteristic of the
    # repo's shared perl-alarm idiom (bin/heimdall-precheck-agent already
    # uses it identically for the brief-adoption gate) -- not something
    # unique to, or fixable from, this one new fence.
    exec sleep 30
    ;;
  *)
    printf '{"decision":"ok","state":"ok","tokens":0,"reason":"unrecognized fake mode"}\n'
    exit 0
    ;;
esac
FAKE
chmod +x "$SANDBOX/bin/heimdall-ctx-meter"

# payload <subagent_type> [session_id]
payload() {
  if [ -n "${2:-}" ]; then
    printf '{"session_id":"%s","tool_input":{"subagent_type":"%s","prompt":"hi"}}' "$2" "$1"
  else
    printf '{"tool_input":{"subagent_type":"%s","prompt":"hi"}}' "$1"
  fi
}

# fire <hook> <payload> <ctxmeter_mode> <gate_off:0|1>
# Hermetic: env -i wipes the ambient shell. ANTHROPIC_BASE_URL is pinned to
# the real Anthropic endpoint (never loopback-shaped) on every call, so the
# UNRELATED adjudication fence earlier in the same hook can never itself
# deny and confound a ctx-gate assertion here (see header note 4).
fire() {
  local hook="$1" payload="$2" mode="$3" gateoff="${4:-}"
  local pf; pf="$(mktemp)"
  printf '%s' "$payload" > "$pf"
  : > "$ERRF"
  rm -f "$ARGVMARK"
  OUT="$(env -i PATH="$REAL_PATH" HOME="${HOME:-/tmp}" \
      ANTHROPIC_BASE_URL="https://api.anthropic.com" \
      FAKE_CTXMETER_MODE="$mode" \
      FAKE_CTXMETER_ARGV_MARKER="$ARGVMARK" \
      HMD_CTX_GATE_OFF="$gateoff" \
      "$BASH_ABS" "$hook" <"$pf" 2>"$ERRF")"
  RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null)"
  rm -f "$pf"
}

# ── 1. static ────────────────────────────────────────────────────────────
if bash -n "$REAL_HOOK" 2>/dev/null; then
  ok "bash -n bin/heimdall-precheck-agent"
else
  bad "bash -n bin/heimdall-precheck-agent FAILED"
fi

if grep -q '^# -- context gate fence' "$REAL_HOOK" \
    && grep -q '^# -- end context gate fence' "$REAL_HOOK"; then
  ok "AC: context gate fence markers present (start and end)"
else
  bad "AC: context gate fence start/end markers missing — has the fence been renamed or removed?"
fi

COOP_END_LINE="$(grep -n '^# -- end coop native-spawn refusal fence' "$REAL_HOOK" | head -1 | cut -d: -f1)"
CTXGATE_START_LINE="$(grep -n '^# -- context gate fence' "$REAL_HOOK" | head -1 | cut -d: -f1)"
CTXGATE_END_LINE="$(grep -n '^# -- end context gate fence' "$REAL_HOOK" | head -1 | cut -d: -f1)"
BRIEF_START_LINE="$(grep -n '^# -- brief-adoption gate' "$REAL_HOOK" | tail -1 | cut -d: -f1)"
if [ -n "$COOP_END_LINE" ] && [ -n "$CTXGATE_START_LINE" ] && [ -n "$CTXGATE_END_LINE" ] && [ -n "$BRIEF_START_LINE" ] \
    && [ "$COOP_END_LINE" -lt "$CTXGATE_START_LINE" ] && [ "$CTXGATE_END_LINE" -lt "$BRIEF_START_LINE" ]; then
  ok "AC: context gate fence sits strictly after the coop fence and strictly before the brief-adoption gate"
else
  bad "AC: context gate fence placement out of order (coop-end=$COOP_END_LINE, ctxgate=[$CTXGATE_START_LINE,$CTXGATE_END_LINE], brief-start=$BRIEF_START_LINE)"
fi

FENCE_BODY="$(awk '/^# -- context gate fence/{f=1} /^# -- end context gate fence/{f=0} f' "$REAL_HOOK")"
if echo "$FENCE_BODY" | grep -q "HMD_CTX_GATE_OFF"; then
  ok "AC: fence documents its HMD_CTX_GATE_OFF escape hatch"
else
  bad "AC: fence's HMD_CTX_GATE_OFF escape hatch documentation is missing"
fi
FENCE_CODE="$(echo "$FENCE_BODY" | grep -v '^[[:space:]]*#')"
if ! echo "$FENCE_CODE" | grep -Eq 'heimdall-agents|git status'; then
  ok "AC: fence never re-derives the boundary itself in executable code (no direct heimdall-agents/git status call outside comments) — trusts gate's own verdict completely"
else
  bad "AC: fence appears to re-derive the boundary itself in executable code instead of trusting gate's verdict"
fi

# ── 2. sandboxed behavior ────────────────────────────────────────────────

# (a) decision=ok -> allowed; ctx-meter actually consulted (argv marker
#     present), proving the fence really calls gate rather than vacuously
#     passing.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-a)" ok
if [ "$RC" -eq 0 ]; then
  ok "decision=ok -> allowed (exit 0)"
else
  bad "decision=ok -> exit $RC, expected 0"
fi
[ -f "$ARGVMARK" ] && ok "decision=ok: ctx-meter was actually consulted (argv marker present)" \
                    || bad "decision=ok: ctx-meter argv marker missing — fence never called it"
[ -z "$OUT" ] && ok "decision=ok: allowed spawn prints nothing to stdout" || bad "decision=ok: allowed spawn unexpectedly printed to stdout: $OUT"

# (b) decision=checkpoint -> allowed (strong notice tier, never refuses).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-b)" checkpoint
[ "$RC" -eq 0 ] && ok "decision=checkpoint -> allowed (exit 0, checkpoint never refuses)" \
                || bad "decision=checkpoint -> exit $RC, expected 0"

# (c) decision=defer -> allowed. This is the never-interrupt guarantee:
#     boundary not clean (a live agent or dirty tree) must never become a
#     refusal, and this fence must never second-guess that by re-deriving
#     cleanliness itself.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-c)" defer
[ "$RC" -eq 0 ] && ok "decision=defer -> allowed (exit 0, never-interrupt guarantee honored)" \
                || bad "decision=defer -> exit $RC, expected 0"

# (d) decision=refuse -> DENIED (exit 2); JSON+stderr both name /hmd:save and
#     /compact as the exact remedy; ctx-meter was actually consulted.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-d)" refuse
if [ "$RC" -eq 2 ]; then
  ok "decision=refuse -> denied (exit 2)"
else
  bad "decision=refuse -> exit $RC, expected 2"
fi
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "deny stdout is valid JSON"
  ERRMSG="$(printf '%s' "$OUT" | jq -r '.error // empty')"
  case "$ERRMSG" in
    *"/hmd:save"*"/compact"*) ok "deny JSON .error names the exact remedy: /hmd:save then /compact" ;;
    *) bad "deny JSON .error missing /hmd:save + /compact remedy: $ERRMSG" ;;
  esac
  case "$ERRMSG" in
    *"HMD_CTX_GATE_OFF=1"*) ok "deny JSON .error also names the HMD_CTX_GATE_OFF=1 override" ;;
    *) bad "deny JSON .error missing the HMD_CTX_GATE_OFF=1 override mention: $ERRMSG" ;;
  esac
else
  bad "deny stdout is not valid JSON: $OUT"
fi
case "$ERR" in
  *BIFROST*"context gate"*"/hmd:save"*) ok "deny reason also written to stderr (redundant disclosure channel)" ;;
  *) bad "stderr missing BIFROST context-gate deny text: $ERR" ;;
esac
[ -f "$ARGVMARK" ] && ok "decision=refuse: ctx-meter was actually consulted before denying (argv marker present)" \
                    || bad "decision=refuse: ctx-meter argv marker missing"

# (e) rc=1 but non-JSON garbage output -> fails open, allowed (garbage output
#     must never deny).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-e)" garbage
[ "$RC" -eq 0 ] && ok "rc=1 + non-JSON garbage output -> fails open, allowed (exit 0)" \
                || bad "garbage-output case -> exit $RC, expected 0 (fail-open broke)"

# (f) rc=1 but JSON body claims decision=ok (contract violation) -> fails
#     open, allowed. Proves the fence's belt-and-suspenders double-check
#     (rc==1 AND decision=="refuse", not either alone) is real.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-f)" rc1-not-refuse
[ "$RC" -eq 0 ] && ok "rc=1 + decision!=refuse body (contract-violation probe) -> fails open, allowed (exit 0)" \
                || bad "rc=1-but-not-refuse case -> exit $RC, expected 0 (fail-open broke)"

# (g) ctx-meter binary missing entirely -> fails open, allowed.
mv "$SANDBOX/bin/heimdall-ctx-meter" "$SANDBOX/bin/heimdall-ctx-meter.hidden"
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-g)" refuse
[ "$RC" -eq 0 ] && ok "heimdall-ctx-meter binary missing -> fails open, allowed (exit 0)" \
                || bad "ctx-meter binary missing -> exit $RC, expected 0 (fail-open broke)"
mv "$SANDBOX/bin/heimdall-ctx-meter.hidden" "$SANDBOX/bin/heimdall-ctx-meter"
chmod +x "$SANDBOX/bin/heimdall-ctx-meter"

# (h) ctx-meter present but not executable -> fails open, allowed.
chmod -x "$SANDBOX/bin/heimdall-ctx-meter"
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-h)" refuse
[ "$RC" -eq 0 ] && ok "heimdall-ctx-meter not executable -> fails open, allowed (exit 0)" \
                || bad "ctx-meter not executable -> exit $RC, expected 0 (fail-open broke)"
chmod +x "$SANDBOX/bin/heimdall-ctx-meter"

# (i) ctx-meter hangs -> bounded by the perl-alarm idiom, fails open,
#     allowed, and returns well before the fake's own 30s sleep would.
T0=$(date +%s)
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-i)" hang
T1=$(date +%s)
ELAPSED=$((T1 - T0))
[ "$RC" -eq 0 ] && ok "heimdall-ctx-meter hangs -> fails open, allowed (exit 0)" \
                || bad "ctx-meter hang case -> exit $RC, expected 0 (fail-open broke)"
if [ "$ELAPSED" -lt 15 ]; then
  ok "heimdall-ctx-meter hang was bounded by the alarm (${ELAPSED}s, well under the fake's 30s sleep) — timeout, not a lucky race"
else
  bad "heimdall-ctx-meter hang took ${ELAPSED}s — the alarm bound does not appear to be firing"
fi

# (j) HMD_CTX_GATE_OFF=1 overrides even a refuse verdict -> allowed
#     regardless, and the escape hatch short-circuits BEFORE ctx-meter is
#     ever invoked (argv marker absent).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-j)" refuse 1
if [ "$RC" -eq 0 ]; then
  ok "HMD_CTX_GATE_OFF=1 + decision=refuse -> allowed regardless (exit 0)"
else
  bad "HMD_CTX_GATE_OFF=1 + decision=refuse -> exit $RC, expected 0"
fi
[ ! -f "$ARGVMARK" ] && ok "HMD_CTX_GATE_OFF=1 short-circuits BEFORE ctx-meter is ever invoked (argv marker absent)" \
                      || bad "HMD_CTX_GATE_OFF=1 still invoked ctx-meter -- the escape hatch is not short-circuiting"

# (k) session_id present in payload -> threaded through via --session.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder sess-k-actual-id)" ok
ARGV_SEEN="$(cat "$ARGVMARK" 2>/dev/null)"
case "$ARGV_SEEN" in
  *"--session sess-k-actual-id"*) ok "session_id from the payload is threaded through to ctx-meter via --session" ;;
  *) bad "session_id was not threaded through via --session (argv was: $ARGV_SEEN)" ;;
esac

# (l) session_id absent from payload -> falls back to no --session flag
#     (never fabricates one).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" ok
ARGV_SEEN="$(cat "$ARGVMARK" 2>/dev/null)"
case "$ARGV_SEEN" in
  *"--session"*) bad "no session_id in payload but --session was still passed (argv was: $ARGV_SEEN)" ;;
  *) ok "no session_id in payload -> no --session flag fabricated (argv was: $ARGV_SEEN)" ;;
esac

# ── 3. RED-PROOFS: mutation tests. A check that cannot fail is not a check. ──
# Mutants are built by scanning ONLY the context gate fence's own section
# (between its start/end markers), so neither mutation can touch the
# adjudication fence, the coop fence, or the brief-adoption gate beside it.
MUTANT_A="$SANDBOX/bin/mutant-a-noop-ctxgate-fence"
awk '
  /^# -- context gate fence/     { in_fence=1 }
  /^# -- end context gate fence/ { in_fence=0 }
  in_fence && /^[[:space:]]*exit 2[[:space:]]*$/ { print "        : # MUTANT-A-noop-ctxgate-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_A"
chmod +x "$MUTANT_A"

MUTANT_B="$SANDBOX/bin/mutant-b-always-ctxgate-fence"
awk '
  /^# -- context gate fence/     { in_fence=1 }
  /^# -- end context gate fence/ { in_fence=0 }
  in_fence && /if \[ "\$CTXGATE_DECISION" = "refuse" \]; then/ { print "      if true; then # MUTANT-B-always-ctxgate-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_B"
chmod +x "$MUTANT_B"

if bash -n "$MUTANT_A" 2>/dev/null; then
  ok "mutant A (no-op-ctxgate-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant A (no-op-ctxgate-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if bash -n "$MUTANT_B" 2>/dev/null; then
  ok "mutant B (always-ctxgate-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant B (always-ctxgate-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if grep -q 'MUTANT-A-noop-ctxgate-fence' "$MUTANT_A"; then
  ok "mutant A actually removed the context gate fence's exit 2 (mutation applied, not a no-op edit)"
else
  bad "mutant A's awk substitution did not apply — the context gate fence's exit 2 is still present"
fi
if grep -q 'MUTANT-B-always-ctxgate-fence' "$MUTANT_B"; then
  ok "mutant B actually replaced the decision==refuse condition (mutation applied, not a no-op edit)"
else
  bad "mutant B's awk substitution did not apply — the decision==refuse condition is still present"
fi

# Red-proof (a): the SAME deny-scenario from case 2d must now WRONGLY pass
# against the no-op mutant -- proving the real exit 2 was load-bearing.
fire "$MUTANT_A" "$(payload hmd:coder sess-redproof-a)" refuse
if [ "$RC" -eq 0 ]; then
  ok "RED-PROOF (a): no-op-ctxgate-fence mutant WRONGLY allows the same deny-scenario (decision=refuse) -- proves the real fence's exit 2 is the reason case 2d's deny happened"
else
  bad "RED-PROOF (a) did not go red: mutant A still exited $RC (expected 0) — case 2d's deny may not be caused by the code we think it is"
fi

# Red-proof (b): the SAME garbage-output scenario from case 2e must now
# WRONGLY get denied against the always-fence mutant -- proving the
# decision=="refuse" gate is a real discriminator, not vacuous.
fire "$MUTANT_B" "$(payload hmd:coder sess-redproof-b)" garbage
if [ "$RC" -eq 2 ]; then
  ok "RED-PROOF (b): always-ctxgate-fence mutant WRONGLY denies the same garbage-output scenario (exit 2) -- proves case 2e's allow is a real decision==refuse discrimination, not always-allow"
else
  bad "RED-PROOF (b) did not go red: mutant B exited $RC (expected 2) — case 2e's allow may not be discriminating on decision at all"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
