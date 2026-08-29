#!/usr/bin/env bash
#
# agent-fallback-adjudication.test.sh — Wave 1 Task 1.1 acceptance suite
# (docs/superpowers/plans/2026-08-29-agent-fallback-coverage.md).
#
# WHY THIS FILE EXISTS
# --------------------
# D2 (plan §0.3): an in-process Agent-tool subagent has no exec boundary, so
# hmd_gate_exec (bin/lib/hmd-gate-endpoint.sh) can never re-route it mid-
# session. When a parent session is fallback-routed (ANTHROPIC_BASE_URL points
# at the local OmniRoute gateway), every in-process subagent silently inherits
# it — including hmd:reviewer/verifier/security-auditor. A judge running on a
# degraded/free-tier model emits confident FALSE GREENS, which is the one
# failure this whole project exists to prevent. bin/heimdall-precheck-agent's
# "adjudication fallback fence" section (Task 1.1) is the fix; this suite is
# its proof.
#
# WHAT THIS SUITE PROVES
# -----------------------
#   1. bin/lib/hmd-adjudication-set.sh classifies the plan's explicit set
#      (reviewer, verifier, security-auditor, incident-responder) plus
#      namespaced (hmd:reviewer) and third-party glob-matched
#      (pr-review-toolkit:code-reviewer) forms as adjudication, and leaves
#      generation types (coder, docs-writer, ...) alone — literal plan
#      acceptance criteria, run for real against the shipped files.
#   2. Under a SANDBOXED, fully-controlled fallback state (a fake
#      heimdall-fallback binary driven by env vars, never the real network/
#      quota probe), the hook denies an adjudication spawn and discloses to
#      every spawn — but never denies a generation spawn — and fails OPEN
#      (unchanged, exit 0) the moment either the fallback binary or the
#      classification library is missing, exactly per the plan's fail-closed-
#      on-safety / fail-open-on-plumbing contract.
#   3. TWO RED-PROOFS (mutation tests), because a assertion that always
#      passes is not a check: a "no-op-fence" mutant (deny neutered to a
#      no-op) proves case 2's deny is load-bearing by making the SAME
#      adjudication spawn wrongly pass; an "always-fence" mutant (the
#      subagent_type condition removed) proves case 2's pass-through is a
#      real discrimination by type, by making the SAME generation spawn
#      wrongly get denied. Pattern: test/routing-var-scrub.test.sh.
#
# Usage: bash test/agent-fallback-adjudication.test.sh   (exit 0 = all green)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOOK="$REPO/bin/heimdall-precheck-agent"
REAL_LIB="$REPO/bin/lib/hmd-adjudication-set.sh"
BASH_ABS="$(command -v bash)"
REAL_PATH="$PATH"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "agent-fallback-adjudication (Wave 1 Task 1.1)  repo=$REPO"

SANDBOX="$(mktemp -d)"
ERRF="$(mktemp)"
cleanup() { rm -rf "$SANDBOX" "$ERRF"; }
trap cleanup EXIT

mkdir -p "$SANDBOX/bin/lib"
cp "$REAL_HOOK" "$SANDBOX/bin/heimdall-precheck-agent"
cp "$REAL_LIB" "$SANDBOX/bin/lib/hmd-adjudication-set.sh"
chmod +x "$SANDBOX/bin/heimdall-precheck-agent"

# Test double for bin/heimdall-fallback: mirrors cmd_base_url's own contract
# (stdout is EMPTY on every non-ROUTE/error path; the one case it ever prints
# is a verified endpoint) but driven entirely by env vars the test controls,
# never real network/quota/DB state. Ignores its argv (--repo ... base-url) —
# the real script's own contract does not depend on argv content for this
# hook to behave correctly, only on stdout/exit.
cat > "$SANDBOX/bin/heimdall-fallback" <<'FAKE'
#!/bin/sh
if [ "${FAKE_FALLBACK_RC:-1}" = "0" ]; then
  printf '%s\n' "${FAKE_FALLBACK_URL:-}"
  exit 0
fi
exit "${FAKE_FALLBACK_RC:-1}"
FAKE
chmod +x "$SANDBOX/bin/heimdall-fallback"

FAKE_URL="http://127.0.0.1:8787"

# fire <hook_path> <payload> <anthropic_base_url> <fake_rc> <fake_url>
# Hermetic: env -i wipes the ambient shell (this dev machine really does
# export a live ANTHROPIC_BASE_URL, see bin/heimdall-fallback's own header),
# so only what is explicitly named below reaches the hook.
fire() {
  local hook="$1" payload="$2" abu="$3" frc="$4" furl="$5"
  local pf; pf="$(mktemp)"
  printf '%s' "$payload" > "$pf"
  : > "$ERRF"
  OUT="$(env -i PATH="$REAL_PATH" HOME="${HOME:-/tmp}" ANTHROPIC_BASE_URL="$abu" \
      FAKE_FALLBACK_RC="$frc" FAKE_FALLBACK_URL="$furl" \
      "$BASH_ABS" "$hook" <"$pf" 2>"$ERRF")"
  RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null)"
  rm -f "$pf"
}

payload() { printf '{"tool_input":{"subagent_type":"%s","prompt":"hi"}}' "$1"; }

# ── 1. static: syntax + literal plan acceptance criteria, against shipped files ──
if bash -n "$REAL_HOOK" 2>/dev/null; then
  ok "bash -n bin/heimdall-precheck-agent"
else
  bad "bash -n bin/heimdall-precheck-agent FAILED"
fi

if bash -n "$REAL_LIB" 2>/dev/null; then
  ok "bash -n bin/lib/hmd-adjudication-set.sh"
else
  bad "bash -n bin/lib/hmd-adjudication-set.sh FAILED"
fi

AC2_OK=1
for t in reviewer verifier security-auditor incident-responder code-review pr-audit; do
  ( . "$REAL_LIB"; hmd_is_adjudication "$t" ) || AC2_OK=0
done
[ "$AC2_OK" -eq 1 ] && ok "AC: reviewer/verifier/security-auditor/incident-responder/code-review/pr-audit all classify adjudication" \
                    || bad "AC: one or more of the six required-adjudication types classified as generation"

AC3_OK=1
for t in coder docs-writer design test-runner architect; do
  ( . "$REAL_LIB"; hmd_is_adjudication "$t" ) && AC3_OK=0
done
[ "$AC3_OK" -eq 1 ] && ok "AC: coder/docs-writer/design/test-runner/architect all classify generation" \
                    || bad "AC: one or more of the five required-generation types classified as adjudication"

if [ "$(grep -c 'HEIMDALL_ALLOW_NAMED_AGENT\|HEIMDALL_ALLOW_LONG_BRIEF' "$REAL_HOOK")" -ge 2 ] \
    && ! grep -qE 'HEIMDALL_ALLOW_(FALLBACK|ADJUDICATION|DEGRADED)' "$REAL_HOOK"; then
  ok "AC: no new bypass env var introduced (only the two pre-existing HEIMDALL_ALLOW_* flags exist)"
else
  bad "AC: a new HEIMDALL_ALLOW_(FALLBACK|ADJUDICATION|DEGRADED) bypass flag was introduced, or a pre-existing flag vanished"
fi

REAL_OUT="$(printf '{"tool_input":{"subagent_type":"coder","prompt":"hi"}}' | "$REAL_HOOK")"
REAL_RC=$?
[ "$REAL_RC" -eq 0 ] && ok "AC: a non-adjudication (coder) spawn against the REAL shipped hook is never denied (exit 0)" \
                     || bad "AC: coder spawn against the real shipped hook exited $REAL_RC, expected 0"

# ── 2. extended classification (namespaced + third-party glob), against shipped lib ──
check_adj() {
  local type="$1" expect="$2" got
  if ( . "$REAL_LIB"; hmd_is_adjudication "$type" ); then got=yes; else got=no; fi
  if [ "$got" = "$expect" ]; then
    ok "hmd_is_adjudication '$type' -> $expect"
  else
    bad "hmd_is_adjudication '$type' -> got $got, expected $expect"
  fi
}
check_adj "hmd:reviewer" yes
check_adj "hmd:verifier" yes
check_adj "hmd:security-auditor" yes
check_adj "hmd:incident-responder" yes
check_adj "hmd:coder" no
check_adj "hmd:docs-writer" no
check_adj "pr-review-toolkit:code-reviewer" yes
check_adj "pr-review-toolkit:silent-failure-hunter" yes
check_adj "" no
( . "$REAL_LIB"; hmd_is_adjudication ) && bad "hmd_is_adjudication with NO argument returned true" \
                                       || ok "hmd_is_adjudication with no argument returns false (unset \$1, set -u safe)"
( . "$REAL_LIB"; . "$REAL_LIB"; hmd_is_adjudication "reviewer" ) && ok "double-source guard: function still callable after sourcing twice" \
                                                                  || bad "double-source guard broke the function on re-source"

# ── 3. sandboxed behavior: fake fallback, real hook + real lib ──────────────
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "$FAKE_URL" 0 "$FAKE_URL"
if [ "$RC" -eq 2 ]; then
  ok "confirmed-fallback + hmd:reviewer -> denied (exit 2)"
else
  bad "confirmed-fallback + hmd:reviewer -> exit $RC, expected 2"
fi
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "deny stdout is valid JSON"
  ERRMSG="$(printf '%s' "$OUT" | jq -r '.error // empty')"
  case "$ERRMSG" in
    *hmd:reviewer*"$FAKE_URL"*) ok "deny JSON .error names the agent type and the endpoint" ;;
    *) bad "deny JSON .error missing agent type or endpoint: $ERRMSG" ;;
  esac
else
  bad "deny stdout is not valid JSON: $OUT"
fi
case "$ERR" in
  *"adjudication deny"*) ok "deny reason also written to stderr (redundant channel per plan's U4 mitigation)" ;;
  *) bad "stderr missing 'adjudication deny' text" ;;
esac
case "$ERR" in *OmniRoute*) ok "disclosure names the provider (OmniRoute)" ;; *) bad "disclosure missing provider name" ;; esac
case "$ERR" in *free*no-auth*) ok "disclosure names free-tier status" ;; *) bad "disclosure missing free-tier status" ;; esac
case "$ERR" in *retention*) ok "disclosure names retention posture" ;; *) bad "disclosure missing retention posture" ;; esac

for role in verifier security-auditor incident-responder; do
  fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload "hmd:$role")" "$FAKE_URL" 0 "$FAKE_URL"
  [ "$RC" -eq 2 ] && ok "confirmed-fallback + hmd:$role -> denied (exit 2)" \
                  || bad "confirmed-fallback + hmd:$role -> exit $RC, expected 2"
done

fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$FAKE_URL" 0 "$FAKE_URL"
if [ "$RC" -eq 0 ]; then
  ok "confirmed-fallback + hmd:coder (generation) -> allowed (exit 0)"
else
  bad "confirmed-fallback + hmd:coder -> exit $RC, expected 0"
fi
[ -z "$OUT" ] && ok "allowed spawn prints nothing to stdout" || bad "allowed spawn unexpectedly printed to stdout: $OUT"
case "$ERR" in
  *"adjudication deny"*) bad "generation spawn's stderr wrongly contains 'adjudication deny'" ;;
  *) ok "generation spawn's stderr contains no deny text" ;;
esac
case "$ERR" in *OmniRoute*) ok "disclosure still fires for a generation spawn (unconditional per spec)" ;; *) bad "disclosure did not fire for a generation spawn under confirmed fallback" ;; esac

# gate=WAIT (fake rc=1, empty stdout -- heimdall-fallback itself reports no
# CURRENT ROUTE verdict) but ANTHROPIC_BASE_URL still points at the gateway --
# this is the exact stale-inherited-env regression found by live orchestrator
# testing, NOT caught by this suite's own first version (which asserted
# "allowed" here). See RED-PROOF (c) below for proof the OLD verdict-keyed
# trigger really did get this wrong. The fix denies it because the env var
# itself, not a freshly re-verified verdict, is what actually routes an
# in-process subagent's calls.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "$FAKE_URL" 1 ""
[ "$RC" -eq 2 ] && ok "gate=WAIT (fake rc=1) + ANTHROPIC_BASE_URL=gateway + hmd:reviewer -> denied (exit 2) [stale-env regression, fixed]" \
                || bad "gate=WAIT + gateway env + hmd:reviewer -> exit $RC, expected 2 (stale-env regression NOT fixed)"
case "$ERR" in *"BIFROST"*) ok "disclosure fires when gate=WAIT but env still points at the gateway" ;; *) bad "disclosure missing when gate=WAIT but env still points at the gateway" ;; esac

# same gate=WAIT + gateway-env condition, but a GENERATION type -> still allowed
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:coder)" "$FAKE_URL" 1 ""
[ "$RC" -eq 0 ] && ok "gate=WAIT + gateway env + hmd:coder (generation) -> allowed (exit 0)" \
                || bad "gate=WAIT + gateway env + hmd:coder -> exit $RC, expected 0"

# ANTHROPIC_BASE_URL unset entirely -- never loopback-shaped, must never deny,
# regardless of what a (fake) heimdall-fallback would say if asked.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "" 0 "$FAKE_URL"
[ "$RC" -eq 0 ] && ok "ANTHROPIC_BASE_URL unset + hmd:reviewer -> allowed (exit 0, no false positive)" \
                || bad "ANTHROPIC_BASE_URL unset + hmd:reviewer -> exit $RC, expected 0"
case "$ERR" in *"BIFROST"*) bad "disclosure wrongly fired with ANTHROPIC_BASE_URL unset" ;; *) ok "no disclosure with ANTHROPIC_BASE_URL unset" ;; esac

# ANTHROPIC_BASE_URL is the real api.anthropic.com -- never loopback-shaped,
# must never deny. The single most important false positive this fence must
# avoid: a non-routed session must never have its adjudication spawns
# refused. frc=0/furl=$FAKE_URL on purpose: proves the deny decision no longer
# depends at all on what a fresh heimdall-fallback call would claim.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "https://api.anthropic.com" 0 "$FAKE_URL"
[ "$RC" -eq 0 ] && ok "ANTHROPIC_BASE_URL=https://api.anthropic.com + hmd:reviewer -> allowed (exit 0, no false positive)" \
                || bad "ANTHROPIC_BASE_URL=https://api.anthropic.com case -> exit $RC, expected 0"

# the OTHER two loopback shapes the fix's case statement matches besides
# 127.* (already covered above via $FAKE_URL) -- localhost and bracketed
# IPv6 ::1 -- each proven to actually deny, not just parse, so the case
# statement's extra branches are exercised, not merely present.
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "http://localhost:8787" 1 ""
[ "$RC" -eq 2 ] && ok "ANTHROPIC_BASE_URL=http://localhost:8787 + hmd:reviewer -> denied (exit 2, localhost loopback shape)" \
                || bad "ANTHROPIC_BASE_URL=http://localhost:8787 case -> exit $RC, expected 2"

fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "http://[::1]:8787" 1 ""
[ "$RC" -eq 2 ] && ok "ANTHROPIC_BASE_URL=http://[::1]:8787 + hmd:reviewer -> denied (exit 2, bracketed IPv6 ::1 loopback shape)" \
                || bad "ANTHROPIC_BASE_URL=http://[::1]:8787 case -> exit $RC, expected 2"

# malformed JSON under confirmed fallback: disclosure (env-only) still fires, deny (payload-dependent) fails open
fire "$SANDBOX/bin/heimdall-precheck-agent" '{not json' "$FAKE_URL" 0 "$FAKE_URL"
[ "$RC" -eq 0 ] && ok "malformed JSON under confirmed fallback -> allowed (exit 0, fails open on the payload)" \
                || bad "malformed JSON under confirmed fallback -> exit $RC, expected 0"
case "$ERR" in *OmniRoute*) ok "malformed-JSON case still discloses (disclosure never depends on payload validity)" ;; *) bad "malformed-JSON case lost disclosure" ;; esac

# ── 4. fail-open on plumbing (missing binary / missing lib), safety question untouched ──
mv "$SANDBOX/bin/heimdall-fallback" "$SANDBOX/bin/heimdall-fallback.hidden"
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "$FAKE_URL" 0 "$FAKE_URL"
[ "$RC" -eq 0 ] && ok "heimdall-fallback binary missing -> fails open, hmd:reviewer allowed (exit 0)" \
                || bad "heimdall-fallback binary missing -> exit $RC, expected 0 (fail-open broke)"
mv "$SANDBOX/bin/heimdall-fallback.hidden" "$SANDBOX/bin/heimdall-fallback"
chmod +x "$SANDBOX/bin/heimdall-fallback"

mv "$SANDBOX/bin/lib/hmd-adjudication-set.sh" "$SANDBOX/bin/lib/hmd-adjudication-set.sh.hidden"
fire "$SANDBOX/bin/heimdall-precheck-agent" "$(payload hmd:reviewer)" "$FAKE_URL" 0 "$FAKE_URL"
[ "$RC" -eq 0 ] && ok "adjudication-set.sh missing -> fails open, hmd:reviewer allowed (exit 0)" \
                || bad "adjudication-set.sh missing -> exit $RC, expected 0 (fail-open broke)"
case "$ERR" in *OmniRoute*) ok "adjudication-set.sh missing -> disclosure still fires (only the deny needs the lib)" ;; *) bad "adjudication-set.sh missing wrongly suppressed disclosure too" ;; esac
mv "$SANDBOX/bin/lib/hmd-adjudication-set.sh.hidden" "$SANDBOX/bin/lib/hmd-adjudication-set.sh"

# ── 5. RED-PROOFS: mutation tests. A check that cannot fail is not a check. ──
# Mutants are built by scanning ONLY the "adjudication fallback fence" section
# (between its own header and the brief-adoption-gate header that follows it)
# so neither mutation can accidentally touch the brief-adoption gate's own,
# unrelated, legitimate exit 2 — same section-scoping idea as the fix applied
# to test/agent-name-gate.test.sh for the same underlying reason.
MUTANT_A="$SANDBOX/bin/mutant-a-noop-fence"
awk '
  /^# -- adjudication fallback fence/ { in_fence=1 }
  /^# -- brief-adoption gate/         { in_fence=0 }
  in_fence && /^[[:space:]]*exit 2[[:space:]]*$/ { print "          : # MUTANT-A-noop-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_A"
chmod +x "$MUTANT_A"

MUTANT_B="$SANDBOX/bin/mutant-b-always-fence"
awk '
  /^# -- adjudication fallback fence/ { in_fence=1 }
  /^# -- brief-adoption gate/         { in_fence=0 }
  in_fence && /hmd_is_adjudication/ && /then$/ && /-n "/ { print "        if true; then # MUTANT-B-always-fence"; next }
  { print }
' "$REAL_HOOK" > "$MUTANT_B"
chmod +x "$MUTANT_B"

if bash -n "$MUTANT_A" 2>/dev/null; then
  ok "mutant A (no-op-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant A (no-op-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if bash -n "$MUTANT_B" 2>/dev/null; then
  ok "mutant B (always-fence) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant B (always-fence) FAILED bash -n — red-proof below would be meaningless"
fi
if grep -q 'MUTANT-A-noop-fence' "$MUTANT_A" && ! grep -qE '^\s*exit 2\s*$' <(awk '/^# -- adjudication fallback fence/{f=1} /^# -- brief-adoption gate/{f=0} f' "$MUTANT_A"); then
  ok "mutant A actually removed the fence's exit 2 (mutation applied, not a no-op edit)"
else
  bad "mutant A's awk substitution did not apply — the fence's exit 2 is still present"
fi
if grep -q 'MUTANT-B-always-fence' "$MUTANT_B"; then
  ok "mutant B actually replaced the type-check condition (mutation applied, not a no-op edit)"
else
  bad "mutant B's awk substitution did not apply — the type-check condition is still present"
fi

# Red-proof (a): the SAME adjudication spawn that test section 3 proved denied
# against the real hook must now WRONGLY pass against the no-op-fence mutant —
# proving that real exit 2 was load-bearing, not incidental.
fire "$MUTANT_A" "$(payload hmd:reviewer)" "$FAKE_URL" 0 "$FAKE_URL"
if [ "$RC" -eq 0 ]; then
  ok "RED-PROOF (a): no-op-fence mutant WRONGLY allows hmd:reviewer under confirmed fallback (exit 0) -- proves the real fence's exit 2 is the reason section 3's deny happened"
else
  bad "RED-PROOF (a) did not go red: mutant A still exited $RC (expected 0) — the deny in section 3 may not be caused by the code we think it is"
fi

# Red-proof (b): the SAME generation spawn that test section 3 proved allowed
# must now WRONGLY get denied against the always-fence mutant — proving that
# real pass-through is a genuine discrimination by subagent_type, not vacuous.
fire "$MUTANT_B" "$(payload hmd:coder)" "$FAKE_URL" 0 "$FAKE_URL"
if [ "$RC" -eq 2 ]; then
  ok "RED-PROOF (b): always-fence mutant WRONGLY denies hmd:coder (generation) under confirmed fallback (exit 2) -- proves section 3's pass-through is a real type-based discrimination, not always-allow"
else
  bad "RED-PROOF (b) did not go red: mutant B exited $RC (expected 2) — the pass-through in section 3 may not be discriminating on type at all"
fi

# ── 6. RED-PROOF (c): the env-keyed TRIGGER itself, not just the deny/pass-
# through decisions downstream of it. Mutant C reconstructs the OLD
# verdict-keyed trigger this file's first version shipped with: it swaps only
# the span between the real hook's own "-- env-loopback trigger (the fix) --"
# and "-- end env-loopback trigger --" markers for a fresh heimdall-fallback
# query + exact-match against ANTHROPIC_BASE_URL -- the same shape the real
# fence had before this fix, expressed as a mutation of the CURRENT shipped
# file rather than a separately-maintained copy, so it can never drift from
# what the real trigger actually looks like. Proves the new gate=WAIT
# assertions above are not vacuous: they must go RED against the OLD trigger.
MUTANT_C="$SANDBOX/bin/mutant-c-verdict-keyed-trigger"
awk '
  /^    # -- env-loopback trigger \(the fix\) --$/ {
    print
    print "    ADJ_ENV_URL=\"$(\"$ADJ_FALLBACK_BIN\" --repo \"$PWD\" base-url 2>/dev/null)\" # MUTANT-C-verdict-keyed"
    print "    ADJ_TRIGGERED=0"
    print "    [ -n \"$ADJ_ENV_URL\" ] && [ \"$ADJ_ENV_URL\" = \"${ANTHROPIC_BASE_URL:-}\" ] && ADJ_TRIGGERED=1"
    skip=1
    next
  }
  /^    # -- end env-loopback trigger --$/ { skip=0; print; next }
  skip { next }
  { print }
' "$REAL_HOOK" > "$MUTANT_C"
chmod +x "$MUTANT_C"

if bash -n "$MUTANT_C" 2>/dev/null; then
  ok "mutant C (verdict-keyed trigger) parses (bash -n) — the red-proof below tests real behavior, not a syntax error"
else
  bad "mutant C (verdict-keyed trigger) FAILED bash -n — red-proof below would be meaningless"
fi
if grep -q 'MUTANT-C-verdict-keyed' "$MUTANT_C"; then
  ok "mutant C actually replaced the env-loopback trigger (mutation applied, not a no-op edit)"
else
  bad "mutant C's awk substitution did not apply — the env-loopback trigger is still present"
fi

# The exact stale-env regression scenario from section 3 above (gate=WAIT,
# ANTHROPIC_BASE_URL still the gateway, hmd:reviewer) must WRONGLY pass
# against the OLD verdict-keyed mutant -- proving the new gate=WAIT
# assertions are a real regression test, not vacuously true.
fire "$MUTANT_C" "$(payload hmd:reviewer)" "$FAKE_URL" 1 ""
if [ "$RC" -eq 0 ]; then
  ok "RED-PROOF (c): verdict-keyed mutant WRONGLY allows hmd:reviewer when gate=WAIT but ANTHROPIC_BASE_URL still points at the gateway (exit 0) -- proves the env-keyed trigger, not the old fresh-verdict one, is why the real hook denies this case"
else
  bad "RED-PROOF (c) did not go red: verdict-keyed mutant exited $RC (expected 0) — may not faithfully reconstruct the old bug"
fi

echo "--------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
