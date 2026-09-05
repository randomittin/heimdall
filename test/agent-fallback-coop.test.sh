#!/usr/bin/env bash
#
# agent-fallback-coop.test.sh — proof for the "coop native-spawn refusal
# fence" in bin/heimdall-precheck-agent (commit 2bbb41d).
#
# WHY THIS FILE EXISTS
# --------------------
# coop (4th bin/heimdall-fallback state, beside off/auto/switch) routes ONLY
# an explicit, hand-curated per-role allowlist (`heimdall-fallback coop
# add/remove/list`) to the OmniRoute gateway; the MAIN session never routes
# at all. That per-role divergence is real ONLY on the exec'd
# bin/lib/hmd-route-claude path — a fresh process can read a fresh
# HMD_AGENT_TYPE. The native Agent-tool spawn path is different: it shares
# THIS session's own process env wholesale, with no per-child
# env-injection point anywhere in the PreToolUse contract or the Agent
# tool's own parameter schema. So a coop-listed role spawned natively would
# silently stay on api.anthropic.com while the operator, having explicitly
# allowlisted it, reasonably believes it is on the gateway. The fence this
# file proves refuses that spawn outright (exit 2) instead of silently
# doing the wrong thing convincingly.
#
# WHAT THIS SUITE PROVES
# -----------------------
#   1. Static: the fence exists (start/end markers), still has no bypass
#      flag, and the real hook still parses.
#   2. Sandboxed, fully-controlled behavior against a FAKE heimdall-fallback
#      test double (mirrors ONLY the two calls the fence itself makes —
#      `--repo <path> where` and `--repo <path> check --role <type>` —
#      driven by env vars, never real network/quota/DB state): denies only
#      the one combination that is actually broken (state==coop AND the
#      role would positively ROUTE), allows everything else, and fails OPEN
#      on every plumbing gap (missing binary, unresolvable config path,
#      corrupt config, no role identified). A marker-file side channel
#      proves not just the exit code but whether the fence's own heavier
#      `check --role` call was EVER reached — so the cheap state pre-filter
#      and the empty-role guard are proven to short-circuit, not just to
#      happen to agree with a case that would have passed anyway.
#   3. TWO RED-PROOFS (mutation tests, pattern: test/agent-fallback-
#      adjudication.test.sh): a "no-op-fence" mutant (deny neutered) proves
#      the real exit 2 is load-bearing by making the SAME deny-scenario
#      wrongly pass; an "always-fence" mutant (state check removed) proves
#      the state==coop gate is a real discriminator by making the SAME
#      state=off scenario wrongly get denied.
#
# Distinct from test/heimdall-fallback-coop.test.sh, which proves
# bin/heimdall-fallback's OWN coop CLI/routing logic end to end against the
# real binary. This file proves ONLY the precheck-agent fence's own
# decision logic, against a fake heimdall-fallback double — the two are
# complementary, neither substitutes for the other.
#
# Usage: bash test/agent-fallback-coop.test.sh   (exit 0 = all green)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
BASH_ABS="$(command -v bash)"
REAL_PATH="$PATH"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "agent-fallback-coop (precheck-agent coop native-spawn refusal fence)  repo=$REPO"

SANDBOX="$(mktemp -d)"
ERRF="$(mktemp)"
CFG_COOP="$(mktemp)"
CFG_OFF="$(mktemp)"
CFG_MALFORMED="$(mktemp)"
MARKER="$(mktemp -u)"
cleanup() { rm -rf "$SANDBOX" "$ERRF" "$CFG_COOP" "$CFG_OFF" "$CFG_MALFORMED" "$MARKER"; }
trap cleanup EXIT

mkdir -p "$SANDBOX/bin"
cp "$REAL_HOOK" "$SANDBOX/bin/heimdall-precheck-agent"
chmod +x "$SANDBOX/bin/heimdall-precheck-agent"

printf '{"state": "coop"}\n' > "$CFG_COOP"
printf '{"state": "off"}\n' > "$CFG_OFF"
printf 'not valid json{{{\n' > "$CFG_MALFORMED"

# Test double for bin/heimdall-fallback: mirrors ONLY the two calls the
# coop fence makes on its own two subcommands, `where` and `check`
# (`$3` is the subcommand name in both call shapes: `--repo <path> where`
# and `--repo <path> check --role <type>`) — driven entirely by env vars
# the test controls. FAKE_COOP_CHECK_MARKER lets a case prove whether
# `check` was EVER invoked, independent of what it returned.
cat > "$SANDBOX/bin/heimdall-fallback" <<'FAKE'
#!/bin/sh
sub="$3"
case "$sub" in
  where)
    if [ -n "${FAKE_COOP_CFG_PATH:-}" ]; then
      printf '%s\n' "$FAKE_COOP_CFG_PATH"
    fi
    exit 0
    ;;
  check)
    if [ -n "${FAKE_COOP_CHECK_MARKER:-}" ]; then
      : > "$FAKE_COOP_CHECK_MARKER"
    fi
    exit "${FAKE_COOP_CHECK_RC:-1}"
    ;;
esac
exit 1
FAKE
chmod +x "$SANDBOX/bin/heimdall-fallback"

# fire <hook_path> <payload> <cfg_path> <check_rc>
# Hermetic: env -i wipes the ambient shell. ANTHROPIC_BASE_URL is pinned to
# the real Anthropic endpoint (never loopback-shaped) on every single call
# in this file, so the UNRELATED adjudication fence earlier in the same
# hook can never itself deny and confound a coop-fence assertion — this
# file isolates the coop fence only; test/agent-fallback-adjudication.test.sh
# already owns the adjudication fence's own behavior.
fire() {
  local hook="$1" payload="$2" cfgpath="$3" checkrc="$4"
  local pf; pf="$(mktemp)"
  printf '%s' "$payload" > "$pf"
  : > "$ERRF"
  rm -f "$MARKER"
  OUT="$(env -i PATH="$REAL_PATH" HOME="${HOME:-/tmp}" \
      ANTHROPIC_BASE_URL="https://api.anthropic.com" \
      FAKE_COOP_CFG_PATH="$cfgpath" FAKE_COOP_CHECK_RC="$checkrc" \
      FAKE_COOP_CHECK_MARKER="$MARKER" \
      "$BASH_ABS" "$hook" <"$pf" 2>"$ERRF")"
  RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null)"
  rm -f "$pf"
}

payload() { printf '{"tool_input":{"subagent_type":"%s","prompt":"hi"}}' "$1"; }
payload_no_type() { printf '{"tool_input":{"prompt":"hi"}}'; }

# ── 1. static ────────────────────────────────────────────────────────────
if bash -n "$REAL_HOOK" 2>/dev/null; then
  ok "bash -n bin/heimdall-precheck-agent"
else
  bad "bash -n bin/heimdall-precheck-agent FAILED"
fi

if grep -q '^# -- coop native-spawn refusal fence' "$REAL_HOOK" \
    && grep -q '^# -- end coop native-spawn refusal fence' "$REAL_HOOK"; then
  ok "AC: coop native-spawn refusal fence markers present (start and end)"
else
  bad "AC: coop fence start/end markers missing — has the fence been renamed or removed?"
fi

FENCE_BODY="$(awk '/^# -- coop native-spawn refusal fence/{f=1} /^# -- end coop native-spawn refusal fence/{f=0} f' "$REAL_HOOK")"
if echo "$FENCE_BODY" | grep -q "This deny has no bypass flag"; then
  ok "AC: fence documents it has no bypass flag"
else
  bad "AC: fence's own 'no bypass flag' statement is missing"
fi
if ! echo "$FENCE_BODY" | grep -qE 'HEIMDALL_ALLOW_(COOP|FALLBACK)'; then
  ok "AC: no new HEIMDALL_ALLOW_COOP/FALLBACK bypass env var introduced in the coop fence"
else
  bad "AC: a new HEIMDALL_ALLOW_COOP/FALLBACK bypass flag was introduced in the coop fence"
fi

# ── 2. sandboxed behavior ────────────────────────────────────────────────

# (a) state=coop, check-rc=0 (ROUTE) -> denied (exit 2); JSON+stderr disclose;
#     check WAS actually consulted (marker touched).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$CFG_COOP" 0
if [ "$RC" -eq 2 ]; then
  ok "state=coop + check-rc=ROUTE + hmd:coder -> denied (exit 2)"
else
  bad "state=coop + check-rc=ROUTE + hmd:coder -> exit $RC, expected 2"
fi
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "deny stdout is valid JSON"
  ERRMSG="$(printf '%s' "$OUT" | jq -r '.error // empty')"
  case "$ERRMSG" in
    *hmd:coder*"coop allowlist"*OmniRoute*) ok "deny JSON .error names the role, the coop allowlist, and OmniRoute" ;;
    *) bad "deny JSON .error missing expected content: $ERRMSG" ;;
  esac
else
  bad "deny stdout is not valid JSON: $OUT"
fi
case "$ERR" in
  *BIFROST*"coop deny"*) ok "deny reason also written to stderr (redundant disclosure channel)" ;;
  *) bad "stderr missing BIFROST coop-deny text: $ERR" ;;
esac
[ -f "$MARKER" ] && ok "check --role was actually consulted for this deny (marker touched)" \
                  || bad "check --role marker missing -- deny happened without consulting the real verdict"

# (b) state=coop, check-rc=1 (REFUSE, e.g. non-listed role) -> allowed;
#     check WAS still consulted (proves the fence doesn't blanket-deny
#     every coop-state spawn, only a confirmed ROUTE verdict).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:test-runner)" "$CFG_COOP" 1
if [ "$RC" -eq 0 ]; then
  ok "state=coop + check-rc=REFUSE (non-listed role) + hmd:test-runner -> allowed (exit 0)"
else
  bad "state=coop + check-rc=REFUSE + hmd:test-runner -> exit $RC, expected 0"
fi
[ -z "$OUT" ] && ok "allowed spawn prints nothing to stdout" || bad "allowed spawn unexpectedly printed to stdout: $OUT"
[ -f "$MARKER" ] && ok "check --role was consulted even though the verdict was REFUSE (not a blanket deny-on-state-coop)" \
                  || bad "check --role marker missing for the REFUSE case"

# (c) state=off (not coop) -> allowed; check NEVER consulted (cheap
#     pre-filter short-circuits before the heavier call is ever made) --
#     check-rc is deliberately 0 (would-be ROUTE) to prove this is a true
#     short-circuit, not a coincidence of the fake's own default.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$CFG_OFF" 0
if [ "$RC" -eq 0 ]; then
  ok "state=off + hmd:coder -> allowed (exit 0, coop not even the active state)"
else
  bad "state=off + hmd:coder -> exit $RC, expected 0"
fi
[ ! -f "$MARKER" ] && ok "state=off short-circuits BEFORE check --role is ever called (marker absent, even though check-rc=0 would have denied)" \
                    || bad "state=off still invoked check --role -- the cheap state pre-filter is not short-circuiting"

# (d) state=coop, subagent_type MISSING from payload -> allowed; check
#     NEVER consulted (empty-role guard short-circuits).
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload_no_type)" "$CFG_COOP" 0
if [ "$RC" -eq 0 ]; then
  ok "state=coop + no subagent_type in payload -> allowed (exit 0)"
else
  bad "state=coop + no subagent_type -> exit $RC, expected 0"
fi
[ ! -f "$MARKER" ] && ok "no subagent_type short-circuits BEFORE check --role is ever called (marker absent)" \
                    || bad "no subagent_type still invoked check --role -- the empty-role guard is not short-circuiting"

# (e) FAKE_COOP_CFG_PATH empty (heimdall-fallback where prints nothing) ->
#     fails open, allowed.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "" 0
[ "$RC" -eq 0 ] && ok "heimdall-fallback where prints no path -> fails open, allowed (exit 0)" \
                || bad "empty where-path case -> exit $RC, expected 0 (fail-open broke)"

# (f) FAKE_COOP_CFG_PATH points to a NONEXISTENT file -> fails open, allowed.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "/nonexistent-coop-fence-test-config-path.json" 0
[ "$RC" -eq 0 ] && ok "config path does not exist on disk -> fails open, allowed (exit 0)" \
                || bad "nonexistent config path case -> exit $RC, expected 0 (fail-open broke)"

# (g) config file exists but is MALFORMED JSON -> COOP_STATE parses empty
#     (never equals "coop") -> fails open, allowed; check never consulted.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$CFG_MALFORMED" 0
if [ "$RC" -eq 0 ]; then
  ok "malformed config JSON -> fails open, allowed (exit 0)"
else
  bad "malformed config JSON case -> exit $RC, expected 0 (fail-open broke)"
fi
[ ! -f "$MARKER" ] && ok "malformed config JSON short-circuits BEFORE check --role is ever called (marker absent)" \
                    || bad "malformed config JSON still invoked check --role"

# (h) heimdall-fallback binary missing entirely -> fails open, allowed.
mv "$SANDBOX/bin/heimdall-fallback" "$SANDBOX/bin/heimdall-fallback.hidden"
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$CFG_COOP" 0
[ "$RC" -eq 0 ] && ok "heimdall-fallback binary missing -> fails open, allowed (exit 0)" \
                || bad "heimdall-fallback binary missing -> exit $RC, expected 0 (fail-open broke)"
mv "$SANDBOX/bin/heimdall-fallback.hidden" "$SANDBOX/bin/heimdall-fallback"
chmod +x "$SANDBOX/bin/heimdall-fallback"

# ── 3. RED-PROOFS: mutation tests. A check that cannot fail is not a check. ──
# Mutants are built by scanning ONLY the coop fence's own section (between
# its start/end markers), so neither mutation can touch the adjudication
# fence or the brief-adoption gate beside it.
MUTANT_A="$SANDBOX/bin/mutant-a-noop-coop-fence"
awk '
  /^# -- coop native-spawn refusal fence/     { in_fence=1 }
  /^# -- end coop native-spawn refusal fence/ { in_fence=0 }
  in_fence && /^[[:space:]]*exit 2[[:space:]]*$/ { print "            : # MUTANT-A-noop-coop-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_A"
chmod +x "$MUTANT_A"

MUTANT_B="$SANDBOX/bin/mutant-b-always-coop-fence"
awk '
  /^# -- coop native-spawn refusal fence/     { in_fence=1 }
  /^# -- end coop native-spawn refusal fence/ { in_fence=0 }
  in_fence && /if \[ "\$COOP_STATE" = "coop" \]; then/ { print "      if true; then # MUTANT-B-always-coop-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_B"
chmod +x "$MUTANT_B"

if bash -n "$MUTANT_A" 2>/dev/null; then
  ok "mutant A (no-op-coop-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant A (no-op-coop-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if bash -n "$MUTANT_B" 2>/dev/null; then
  ok "mutant B (always-coop-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant B (always-coop-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if grep -q 'MUTANT-A-noop-coop-fence' "$MUTANT_A"; then
  ok "mutant A actually removed the coop fence's exit 2 (mutation applied, not a no-op edit)"
else
  bad "mutant A's awk substitution did not apply — the coop fence's exit 2 is still present"
fi
if grep -q 'MUTANT-B-always-coop-fence' "$MUTANT_B"; then
  ok "mutant B actually replaced the state==coop condition (mutation applied, not a no-op edit)"
else
  bad "mutant B's awk substitution did not apply — the state==coop condition is still present"
fi

# Red-proof (a): the SAME deny-scenario from case 2a must now WRONGLY pass
# against the no-op mutant -- proving the real exit 2 was load-bearing.
fire "$MUTANT_A" "$(payload hmd:coder)" "$CFG_COOP" 0
if [ "$RC" -eq 0 ]; then
  ok "RED-PROOF (a): no-op-coop-fence mutant WRONGLY allows the same deny-scenario (state=coop, check-rc=ROUTE, hmd:coder) -- proves the real fence's exit 2 is the reason case 2a's deny happened"
else
  bad "RED-PROOF (a) did not go red: mutant A still exited $RC (expected 0) — case 2a's deny may not be caused by the code we think it is"
fi

# Red-proof (b): the SAME state=off scenario from case 2c must now WRONGLY
# get denied against the always-fence mutant -- proving the state==coop
# gate is a real discriminator, not vacuous.
fire "$MUTANT_B" "$(payload hmd:coder)" "$CFG_OFF" 0
if [ "$RC" -eq 2 ]; then
  ok "RED-PROOF (b): always-coop-fence mutant WRONGLY denies the same state=off scenario (exit 2) -- proves case 2c's allow is a real state==coop discrimination, not always-allow"
else
  bad "RED-PROOF (b) did not go red: mutant B exited $RC (expected 2) — case 2c's allow may not be discriminating on state at all"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
