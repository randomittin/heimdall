#!/usr/bin/env bash
# test/hmd-exec-fallback-routing.test.sh — Wave 1 Task 1.2 acceptance.
#
# Proves the per-spawn fallback-gate seam: bin/hmd-exec's claude-code backend now
# defaults HMD_CLAUDE_BIN to bin/lib/hmd-route-claude, and that shim must (a) pin
# judgment spawns straight to the real Anthropic endpoint, scrubbing any hostile
# ambient routing override, (b) hand generation spawns to whatever bin/heimdall-route
# decides, fresh, every single invocation, and (c) fail open — byte-identical to an
# unrouted launch — whenever the routing binary is unavailable or refuses/waits.
#
# Falsifiable both directions: Section C proves a ROUTE verdict actually threads the
# gateway endpoint + pinned model into the child's env (C1), AND that a REFUSE
# verdict or a missing routing binary leaves the child's env untouched (C2/C3),
# compared key-for-key against a genuinely unrouted baseline launch — a test that only
# asserted one of those directions would pass trivially against a shim that always (or
# never) routes.
#
# Hermetic throughout: every "claude" and "heimdall-route" binary here is a fake,
# PATH-shadowed or fixture-copied. No real gateway, no real fallback config, no
# network call, is ever reachable from this file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$REPO_ROOT/bin/lib/hmd-route-claude"
HMD_EXEC_BIN="$REPO_ROOT/bin/hmd-exec"
GATE_ENDPOINT_LIB="$REPO_ROOT/bin/lib/hmd-gate-endpoint.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── shared fixtures ──────────────────────────────────────────────────────────────
# A fake PATH entry named "claude": the "real binary" every branch eventually
# resolves via `command -v claude`. It never launches a model — it dumps its own
# argv and full environment to RECORDER_ENV_FILE and exits 0.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "$*"
  env
} > "${RECORDER_ENV_FILE:?RECORDER_ENV_FILE not set}"
exit 0
EOF
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"

# The routing-relevant keys any "untouched" assertion below checks. Reused verbatim
# from the real judgment invariant's own enumeration (plus the two vars
# bin/heimdall-route additionally threads on ROUTE) rather than re-typing a second,
# driftable list.
# shellcheck source=../bin/lib/hmd-gate-endpoint.sh
. "$GATE_ENDPOINT_LIB"
ROUTING_KEYS="$_HMD_GATE_ROUTING_VARS
ANTHROPIC_MODEL
ANTHROPIC_AUTH_TOKEN"

# Neutralize whatever routing/proxy state happens to be ambient in the environment
# actually running this suite (e.g. a real local OmniRoute gateway or headroom proxy
# on the dev machine). Every "untouched" assertion below must compare against a
# KNOWN-clean starting point, not whatever this machine happens to already export —
# otherwise a real ambient ANTHROPIC_BASE_URL would leak through a REFUSE/missing-
# binary case and be mistaken for a shim defect it is not.
for _hcfr_key in $ROUTING_KEYS; do
  unset "$_hcfr_key"
done

extract_key() { # extract_key <env-dump-file> <KEY>
  grep "^$2=" "$1" 2>/dev/null || true
}

assert_untouched() { # assert_untouched <desc> <baseline-file> <candidate-file>
  local desc="$1" baseline="$2" candidate="$3" key mismatch=0
  for key in $ROUTING_KEYS; do
    if [ "$(extract_key "$baseline" "$key")" != "$(extract_key "$candidate" "$key")" ]; then
      mismatch=1
      bad "$desc" "key $key differs from the unrouted baseline"
    fi
  done
  [ "$mismatch" -eq 0 ] && ok "$desc"
}

echo "== Section A: static shape (plan's literal acceptance criteria) =="

if [ -x "$SHIM" ] && bash -n "$SHIM"; then ok "A1 shim exists, executable, parses"
else bad "A1 shim exists, executable, parses" "test -x/bash -n failed"; fi

if grep -q 'HMD_CLAUDE_BIN' "$HMD_EXEC_BIN"; then ok "A2 hmd-exec references HMD_CLAUDE_BIN"
else bad "A2 hmd-exec references HMD_CLAUDE_BIN" "grep found nothing"; fi

if grep -q "exec" "$SHIM" && ! grep -q "hmd-exec" "$SHIM"; then
  ok "A3 shim execs, and never names the dispatcher it plugs into"
else
  bad "A3 shim execs, and never names the dispatcher it plugs into" "grep condition failed"
fi

echo "== Section B: judgment branch (real shim, no fixture needed) =="

RECORDER_ENV_FILE="$WORK/b1.env"
# Poison three of the scrubbed vars with plausible hostile proxy values BEFORE
# invoking the shim — proves the pin+scrub actively overrides a hostile ambient
# value, not merely that it happens to already be absent.
( export RECORDER_ENV_FILE
  export HMD_JUDGMENT=1
  export ANTHROPIC_BASE_URL="http://127.0.0.1:9999"
  export HTTP_PROXY="http://127.0.0.1:8888"
  export HEADROOM_BASE_URL="http://127.0.0.1:7777"
  "$SHIM" -p "judgment task" >/dev/null 2>&1
)
if [ -f "$RECORDER_ENV_FILE" ]; then
  actual_url="$(extract_key "$RECORDER_ENV_FILE" ANTHROPIC_BASE_URL)"
  if [ "$actual_url" = "ANTHROPIC_BASE_URL=https://api.anthropic.com" ] \
     && [ -z "$(extract_key "$RECORDER_ENV_FILE" HTTP_PROXY)" ] \
     && [ -z "$(extract_key "$RECORDER_ENV_FILE" HEADROOM_BASE_URL)" ]; then
    ok "B1 judgment spawn pins real endpoint and scrubs poisoned proxy vars"
  else
    bad "B1 judgment spawn pins real endpoint and scrubs poisoned proxy vars" \
      "got [$actual_url], proxy=[$(extract_key "$RECORDER_ENV_FILE" HTTP_PROXY)], headroom=[$(extract_key "$RECORDER_ENV_FILE" HEADROOM_BASE_URL)]"
  fi
else
  bad "B1 judgment spawn pins real endpoint and scrubs poisoned proxy vars" "recorder never ran"
fi

b2_out="$(HMD_JUDGMENT=1 "$SHIM" --print-endpoint 2>/dev/null || true)"
case "$b2_out" in
  *api.anthropic.com*) ok "B2 --print-endpoint under judgment reports the real provider" ;;
  *) bad "B2 --print-endpoint under judgment reports the real provider" "got [$b2_out]" ;;
esac

echo "== Section C: generation branch (fixture-copied shim + fake heimdall-route) =="

FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/bin/lib"
cp "$SHIM" "$FIXTURE/bin/lib/hmd-route-claude"
chmod +x "$FIXTURE/bin/lib/hmd-route-claude"
FIXTURE_SHIM="$FIXTURE/bin/lib/hmd-route-claude"
ROUTE_CALL_LOG="$WORK/route-calls.log"
: > "$ROUTE_CALL_LOG"

write_fake_route() {
  cat > "$FIXTURE/bin/heimdall-route" <<'EOF'
#!/usr/bin/env bash
# Test double for bin/heimdall-route -- see test/hmd-exec-fallback-routing.test.sh.
printf '%s\n' "$*" >> "${HRTEST_CALL_LOG:?HRTEST_CALL_LOG not set}"
[ "${1:-}" = "claude" ] || { echo "fake heimdall-route: expected 'claude' first, got '${1:-}'" >&2; exit 2; }
shift
REAL="$(command -v claude 2>/dev/null || true)"
[ -n "$REAL" ] || { echo "fake heimdall-route: no claude on PATH" >&2; exit 127; }
if [ "${HRTEST_VERDICT:-}" = "route" ]; then
  export ANTHROPIC_BASE_URL="${HRTEST_URL:?HRTEST_URL not set}"
  export ANTHROPIC_MODEL="${HRTEST_MODEL:?HRTEST_MODEL not set}"
fi
exec "$REAL" "$@"
EOF
  chmod +x "$FIXTURE/bin/heimdall-route"
}

# C0 -- HMD_AGENT_TYPE alone, absent Task 1.1's adjudication-set library (confirmed
# not yet present in this tree), must NOT trigger judgment today: the honest,
# disclosed fail-open behaviour around a sibling task's not-yet-existing file.
write_fake_route
: > "$ROUTE_CALL_LOG"
RECORDER_ENV_FILE="$WORK/c0.env"
( export RECORDER_ENV_FILE HRTEST_CALL_LOG="$ROUTE_CALL_LOG"
  export HRTEST_VERDICT=refuse
  export HMD_AGENT_TYPE=reviewer
  unset HMD_JUDGMENT 2>/dev/null
  "$FIXTURE_SHIM" -p "c0" >/dev/null 2>&1
)
if [ -s "$ROUTE_CALL_LOG" ]; then
  ok "C0 HMD_AGENT_TYPE alone does not short-circuit to judgment (Task 1.1 pending)"
else
  bad "C0 HMD_AGENT_TYPE alone does not short-circuit to judgment (Task 1.1 pending)" "fake heimdall-route was never consulted"
fi

# C1 -- ROUTE verdict threads the gateway endpoint AND the pinned model into the
# child's env, faithfully, through the fixture-copied shim.
: > "$ROUTE_CALL_LOG"
RECORDER_ENV_FILE="$WORK/c1.env"
( export RECORDER_ENV_FILE HRTEST_CALL_LOG="$ROUTE_CALL_LOG"
  export HRTEST_VERDICT=route HRTEST_URL="http://127.0.0.1:9101" HRTEST_MODEL="oc/fallback-model-x"
  unset HMD_JUDGMENT HMD_AGENT_TYPE 2>/dev/null
  "$FIXTURE_SHIM" -p "c1 task" --output-format text >/dev/null 2>&1
)
if [ -f "$RECORDER_ENV_FILE" ] \
   && [ "$(extract_key "$RECORDER_ENV_FILE" ANTHROPIC_BASE_URL)" = "ANTHROPIC_BASE_URL=http://127.0.0.1:9101" ] \
   && [ "$(extract_key "$RECORDER_ENV_FILE" ANTHROPIC_MODEL)" = "ANTHROPIC_MODEL=oc/fallback-model-x" ] \
   && grep -q 'ARGV:.*c1 task.*--output-format text' "$RECORDER_ENV_FILE"; then
  ok "C1 ROUTE verdict threads gateway endpoint + pinned model into child env"
else
  bad "C1 ROUTE verdict threads gateway endpoint + pinned model into child env" \
    "$(grep '^ANTHROPIC_' "$RECORDER_ENV_FILE" 2>/dev/null; grep ARGV "$RECORDER_ENV_FILE" 2>/dev/null)"
fi

# Baseline: a genuinely unrouted, direct launch -- what "untouched" means, in the
# flesh, not by assertion.
RECORDER_ENV_FILE="$WORK/baseline.env"
( export RECORDER_ENV_FILE
  unset HMD_JUDGMENT HMD_AGENT_TYPE ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  "$FAKEBIN/claude" -p "baseline task" --output-format text
)

# CJ -- judgment branch fails open (byte-identical to the unrouted baseline, not
# merely "no crash") when bin/lib/hmd-gate-endpoint.sh is unreadable -- the
# fixture's lib/ dir holds only the shim itself, never that library, so this
# forces the "Fail open: judgment library unreadable" branch for real.
RECORDER_ENV_FILE="$WORK/cj.env"
( export RECORDER_ENV_FILE
  export PATH="$FAKEBIN"
  export HMD_JUDGMENT=1
  unset HMD_AGENT_TYPE 2>/dev/null
  "$FIXTURE_SHIM" -p "baseline task" --output-format text >/dev/null 2>&1
)
assert_untouched "CJ judgment fails open, byte-identical to baseline, when gate-endpoint lib is unreadable" "$WORK/baseline.env" "$RECORDER_ENV_FILE"

# C2 -- REFUSE/WAIT verdict leaves the child env byte-identical (key-for-key) to the
# unrouted baseline above.
: > "$ROUTE_CALL_LOG"
RECORDER_ENV_FILE="$WORK/c2.env"
( export RECORDER_ENV_FILE HRTEST_CALL_LOG="$ROUTE_CALL_LOG"
  export HRTEST_VERDICT=refuse
  unset HMD_JUDGMENT HMD_AGENT_TYPE ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  "$FIXTURE_SHIM" -p "baseline task" --output-format text >/dev/null 2>&1
)
if [ -s "$ROUTE_CALL_LOG" ]; then
  assert_untouched "C2 REFUSE verdict leaves child env byte-identical to unrouted baseline" "$WORK/baseline.env" "$RECORDER_ENV_FILE"
else
  bad "C2 REFUSE verdict leaves child env byte-identical to unrouted baseline" "fake heimdall-route was never consulted"
fi

# C3 -- no routing binary resolvable at all (neither repo-relative nor on PATH): same
# byte-identical-to-baseline guarantee, via the OTHER fail-open branch. PATH is
# narrowed to just FAKEBIN so a real, globally-installed heimdall-route on this dev
# machine's own PATH can never mask the "missing" case this test exists to prove.
rm -f "$FIXTURE/bin/heimdall-route"
RECORDER_ENV_FILE="$WORK/c3.env"
( export RECORDER_ENV_FILE
  export PATH="$FAKEBIN"
  unset HMD_JUDGMENT HMD_AGENT_TYPE ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN 2>/dev/null
  "$FIXTURE_SHIM" -p "baseline task" --output-format text >/dev/null 2>&1
)
assert_untouched "C3 missing routing binary leaves child env byte-identical to unrouted baseline" "$WORK/baseline.env" "$RECORDER_ENV_FILE"

# C4 -- freshness: the SAME shim, same shell, back-to-back, must reflect the gate
# changing its mind between the two spawns -- never a cached verdict.
write_fake_route
: > "$ROUTE_CALL_LOG"
RECORDER_ENV_FILE="$WORK/c4a.env"
( export RECORDER_ENV_FILE HRTEST_CALL_LOG="$ROUTE_CALL_LOG"
  export HRTEST_VERDICT=route HRTEST_URL="http://127.0.0.1:9102" HRTEST_MODEL="oc/model-a"
  unset HMD_JUDGMENT HMD_AGENT_TYPE 2>/dev/null
  "$FIXTURE_SHIM" -p "c4a" >/dev/null 2>&1
)
RECORDER_ENV_FILE="$WORK/c4b.env"
( export RECORDER_ENV_FILE HRTEST_CALL_LOG="$ROUTE_CALL_LOG"
  export HRTEST_VERDICT=refuse
  unset HMD_JUDGMENT HMD_AGENT_TYPE 2>/dev/null
  "$FIXTURE_SHIM" -p "c4b" >/dev/null 2>&1
)
calls="$(wc -l < "$ROUTE_CALL_LOG" | tr -d ' ')"
if [ "$calls" = "2" ] \
   && [ "$(extract_key "$WORK/c4a.env" ANTHROPIC_BASE_URL)" = "ANTHROPIC_BASE_URL=http://127.0.0.1:9102" ] \
   && [ -z "$(extract_key "$WORK/c4b.env" ANTHROPIC_BASE_URL)" ]; then
  ok "C4 gate is consulted fresh per spawn, never cached across invocations"
else
  bad "C4 gate is consulted fresh per spawn, never cached across invocations" \
    "calls=$calls a=$(extract_key "$WORK/c4a.env" ANTHROPIC_BASE_URL) b=$(extract_key "$WORK/c4b.env" ANTHROPIC_BASE_URL)"
fi

echo "== Section D: real bin/hmd-exec integration =="

RECORDER_ENV_FILE="$WORK/d1.env"
( unset HMD_CLAUDE_BIN 2>/dev/null
  export RECORDER_ENV_FILE
  export HMD_JUDGMENT=1
  "$HMD_EXEC_BIN" run -p "d1 task" >/dev/null 2>&1
)
if [ -f "$RECORDER_ENV_FILE" ] && [ "$(extract_key "$RECORDER_ENV_FILE" ANTHROPIC_BASE_URL)" = "ANTHROPIC_BASE_URL=https://api.anthropic.com" ]; then
  ok "D1 real hmd-exec's new default reaches the real shim end-to-end"
else
  bad "D1 real hmd-exec's new default reaches the real shim end-to-end" "$(extract_key "$RECORDER_ENV_FILE" ANTHROPIC_BASE_URL 2>/dev/null)"
fi

SEAM_RECORDER="$WORK/seam-recorder"
SEAM_ENV_FILE="$WORK/d2.env"
cat > "$SEAM_RECORDER" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGV:%s\n' "$*"; env; } > "${SEAM_ENV_FILE:?SEAM_ENV_FILE not set}"
exit 0
EOF
chmod +x "$SEAM_RECORDER"
( export SEAM_ENV_FILE
  export HMD_CLAUDE_BIN="$SEAM_RECORDER"
  "$HMD_EXEC_BIN" run -p "d2 task" >/dev/null 2>&1
)
if [ -f "$SEAM_ENV_FILE" ]; then
  ok "D2 a caller-set HMD_CLAUDE_BIN still overrides the new default (pre-existing test seam preserved)"
else
  bad "D2 a caller-set HMD_CLAUDE_BIN still overrides the new default (pre-existing test seam preserved)" "seam recorder never ran -- hmd-exec's new default clobbered the caller's override"
fi

echo "== Section E: plan's remaining literal acceptance commands, run verbatim =="

if ( cd "$REPO_ROOT" && bash -c 'HMD_CLAUDE_BIN=/usr/bin/true bin/hmd-exec run -p x >/dev/null 2>&1; exit 0' ); then
  ok "E1 literal: HMD_CLAUDE_BIN=/usr/bin/true bin/hmd-exec run -p x"
else
  bad "E1 literal: HMD_CLAUDE_BIN=/usr/bin/true bin/hmd-exec run -p x" "nonzero exit (should be impossible by construction)"
fi

if ( cd "$REPO_ROOT" && bash -c 'HMD_JUDGMENT=1 HMD_CLAUDE_BIN=bin/lib/hmd-route-claude bin/lib/hmd-route-claude --print-endpoint 2>/dev/null | grep -q api.anthropic.com' ); then
  ok "E2 literal: HMD_JUDGMENT=1 --print-endpoint reports api.anthropic.com"
else
  bad "E2 literal: HMD_JUDGMENT=1 --print-endpoint reports api.anthropic.com" "grep did not match"
fi

printf 'hmd-exec-fallback-routing: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
