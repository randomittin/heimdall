#!/usr/bin/env bash
#
# heimdall-model-resolve.test.sh — acceptance for tier-based model resolution.
#
# WHY: Opus 5 shipped but Heimdall kept spawning the pinned claude-opus-4-8 —
# operational work ran on last-gen. The fix resolves models by TIER alias
# (opus|sonnet|haiku), which Claude Code maps to the LATEST of that tier, with a
# HEIMDALL_MODEL_<TIER> env override to PIN a full id for bench/eval repro.
#
# Guarantees proved:
#   1. Default float — each tier prints its bare alias (latest-resolving form).
#   2. Pin-override wins — HEIMDALL_MODEL_<TIER> prints that exact id instead.
#   3. Unknown tier — nonzero exit + stderr message.
#   4. Operational scripts float — NO hardcoded claude-(opus|sonnet|haiku)-N in
#      session-fork, decompose, or the bin/heimdall lead-launch + routing sites.
#
# Usage:  test/heimdall-model-resolve.test.sh   (exit 0 = all guarantees hold)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
RESOLVE="$REPO/bin/heimdall-model-resolve"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "heimdall-model-resolve harness  repo=$REPO"
echo "--------------------------------------------------------------------"

[ -x "$RESOLVE" ] && ok "bin/heimdall-model-resolve is executable" \
  || bad "bin/heimdall-model-resolve missing or not executable"

# ── 1. DEFAULT FLOAT — an ALIAS per tier, never a pinned id ──
# opus and haiku resolve bare. sonnet resolves to 'sonnet[1m]': the 1M-context
# alias, which still floats to the current generation (Claude Code 2.1.227
# labels it "Sonnet 5 with 1M context window"). The invariant under test is
# "float, don't pin" — not "no suffix" — so the expectation is per-tier.
for tier in opus haiku; do
  got="$(env -u HEIMDALL_MODEL_OPUS -u HEIMDALL_MODEL_SONNET -u HEIMDALL_MODEL_HAIKU \
         "$RESOLVE" "$tier" 2>/dev/null)"
  [ "$got" = "$tier" ] \
    && ok "resolve $tier (no override) -> '$got' (bare alias = latest)" \
    || bad "resolve $tier -> '$got', expected bare alias '$tier'"
done
got="$(env -u HEIMDALL_MODEL_SONNET "$RESOLVE" sonnet 2>/dev/null)"
[ "$got" = "sonnet[1m]" ] \
  && ok "resolve sonnet (no override) -> '$got' (1M-context alias = latest, long sessions stop compacting)" \
  || bad "resolve sonnet -> '$got', expected 'sonnet[1m]'"
# whatever the suffix, no tier may resolve to a pinned generation by default
for tier in opus sonnet haiku; do
  got="$(env -u HEIMDALL_MODEL_OPUS -u HEIMDALL_MODEL_SONNET -u HEIMDALL_MODEL_HAIKU \
         "$RESOLVE" "$tier" 2>/dev/null)"
  case "$got" in
    claude-*) bad "default resolve $tier -> '$got' — a pinned id, which silently ages" ;;
    *) ok "default resolve $tier names no model generation ('$got')" ;;
  esac
done

# ── 2. PIN-OVERRIDE WINS ──
got="$(HEIMDALL_MODEL_OPUS=claude-opus-9-9 "$RESOLVE" opus 2>/dev/null)"
[ "$got" = "claude-opus-9-9" ] \
  && ok "HEIMDALL_MODEL_OPUS pins opus -> '$got'" \
  || bad "opus override -> '$got', expected claude-opus-9-9"
got="$(HEIMDALL_MODEL_SONNET=claude-sonnet-9-9 "$RESOLVE" sonnet 2>/dev/null)"
[ "$got" = "claude-sonnet-9-9" ] \
  && ok "HEIMDALL_MODEL_SONNET pins sonnet -> '$got'" \
  || bad "sonnet override -> '$got', expected claude-sonnet-9-9"
got="$(HEIMDALL_MODEL_HAIKU=claude-haiku-9-9 "$RESOLVE" haiku 2>/dev/null)"
[ "$got" = "claude-haiku-9-9" ] \
  && ok "HEIMDALL_MODEL_HAIKU pins haiku -> '$got'" \
  || bad "haiku override -> '$got', expected claude-haiku-9-9"

# Override for one tier must NOT leak into another.
got="$(env -u HEIMDALL_MODEL_SONNET HEIMDALL_MODEL_OPUS=claude-opus-9-9 "$RESOLVE" sonnet 2>/dev/null)"
[ "$got" = "sonnet[1m]" ] \
  && ok "opus override does not leak into sonnet -> '$got'" \
  || bad "sonnet contaminated by opus override -> '$got', expected sonnet[1m]"

# ── 2b. THE 1M SUFFIX IS SCOPED AND ESCAPABLE ──
# A pin exists for bench/eval reproducibility; suffixing it would change the
# context window of a model someone pinned precisely to hold everything fixed.
got="$(HEIMDALL_MODEL_SONNET=claude-sonnet-9-9 "$RESOLVE" sonnet 2>/dev/null)"
case "$got" in
  *'[1m]'*) bad "pinned sonnet -> '$got' — the suffix must never be appended to a pin" ;;
  *) ok "a pinned sonnet is never suffixed -> '$got' (bench repro holds everything fixed)" ;;
esac
got="$(env -u HEIMDALL_MODEL_HAIKU "$RESOLVE" haiku 2>/dev/null)"
case "$got" in
  *'[1m]'*) bad "haiku -> '$got' — no haiku[1m] variant exists; this would be an invalid --model" ;;
  *) ok "haiku is exempt from the 1M policy ('$got') — no such variant, 200K window" ;;
esac
got="$(env -u HEIMDALL_MODEL_SONNET HEIMDALL_NO_1M=1 "$RESOLVE" sonnet 2>/dev/null)"
[ "$got" = "sonnet" ] \
  && ok "HEIMDALL_NO_1M=1 opts out -> '$got' (cost cap / pre-1M bench repro)" \
  || bad "HEIMDALL_NO_1M=1 gave '$got', expected bare 'sonnet'"

# ── 3. UNKNOWN TIER — nonzero + stderr ──
err="$("$RESOLVE" bogus 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] \
  && ok "unknown tier exits nonzero (rc=$rc)" \
  || bad "unknown tier exited 0 — should fail"
grep -qi 'unknown tier' <<<"$err" \
  && ok "unknown tier writes a message to stderr" \
  || bad "unknown tier produced no stderr diagnostic"

# ── 4. OPERATIONAL SCRIPTS FLOAT — no hardcoded pins remain ──
for f in bin/session-fork bin/decompose; do
  if grep -qE 'claude-(opus|sonnet|haiku)-[0-9]' "$REPO/$f"; then
    bad "$f still contains a hardcoded pinned model id"
  else
    ok "$f has no hardcoded pinned model id (floats via resolver)"
  fi
done

# bin/heimdall: lead-launch + routing sites must be resolver-driven. The bench
# HELP-TEXT example id in bin/heimdall-bench is intentionally excluded (pinned).
HITS="$(grep -nE 'claude-(opus|sonnet|haiku)-[0-9]' "$REPO/bin/heimdall" || true)"
if [ -z "$HITS" ]; then
  ok "bin/heimdall has no hardcoded pinned model id in operational sites"
else
  bad "bin/heimdall still pins a model id:"
  printf '       %s\n' "$HITS"
fi

# Positive wiring check: the resolver is actually invoked in bin/heimdall.
grep -q 'heimdall-model-resolve' "$REPO/bin/heimdall" \
  && ok "bin/heimdall invokes heimdall-model-resolve" \
  || bad "bin/heimdall never calls heimdall-model-resolve — not wired"

echo ""
echo "heimdall-model-resolve.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
