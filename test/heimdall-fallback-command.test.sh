#!/usr/bin/env bash
# test/heimdall-fallback-command.test.sh — /hmd:fallback slash command static contract.
#
# WHAT THIS GATES. bin/heimdall-fallback is a fully working four-state OmniRoute
# routing gate (see test/heimdall-fallback.test.sh) with, until now, no slash
# command exposing it — an operator who doesn't already know the raw bin/ tool
# exists has no way to discover or drive it from Claude Code. This locks the
# fix (commands/fallback.md):
#   1. The file exists with the correct frontmatter (name: fallback,
#      argument-hint, disable-model-invocation: true — it changes real state).
#   2. It documents the real subcommand set: status / set / check / arm / where.
#   3. THE CORRECTION THAT MATTERS MOST: there is NO `heimdall-fallback
#      config` subcommand. build_parser() in bin/heimdall-fallback defines
#      exactly four subparsers; an earlier, unverified assumption asserted a
#      `config target_provider <x>` subcommand existed. This test locks in
#      the truth two ways — the doc must say plainly that no config
#      subcommand exists (target_provider/operator_key_env are set by
#      editing the JSON file directly), and the doc must never itself invoke
#      a `heimdall-fallback config ...` line as if it were real — AND it
#      cross-checks the doc's claim against the live source, so the claim
#      cannot silently go stale if the tool ever grows a real config verb.
#   4. It documents the four states in operator language, including that
#      adjudication (reviewer/verifier/security-auditor) never routes under
#      `on`, and that `auto` reacts to the real ~95% exhaustion threshold.
#   5. It documents the operator-facing caveats: operator_key_env holds the
#      env-var NAME (never the key itself), no-auth providers need no key,
#      keyless providers can't do real agent work, and routing costs real
#      cache-miss money even against a free provider.
#   6. It does not overstate scope: model-independent via OmniRoute, NOT
#      harness-independent (the harness stays Claude Code either way).
#
# EXIT: 0 = all assertions pass; 1 = any FAIL.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CMD_MD="$REPO/commands/fallback.md"
FALLBACK_BIN="$REPO/bin/heimdall-fallback"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

# ── 0. file exists ──────────────────────────────────────────────────────────
if [ -f "$CMD_MD" ]; then ok "commands/fallback.md exists"; else bad "commands/fallback.md missing"; fi
if [ ! -f "$CMD_MD" ]; then
  echo "  FATAL: cannot continue without commands/fallback.md" >&2
  printf "\n  Results: %d passed, %d failed\n" "$PASS" "$((FAIL+18))"
  exit 1
fi

# ── 1. frontmatter ───────────────────────────────────────────────────────────
if grep -qE '^name:[[:space:]]*fallback[[:space:]]*$' "$CMD_MD"; then
  ok "fallback.md frontmatter name: fallback"
else bad "fallback.md frontmatter name is not 'fallback'"; fi

if grep -qE '^argument-hint:' "$CMD_MD"; then ok "fallback.md declares argument-hint"; else bad "fallback.md missing argument-hint"; fi
if grep -qE '^disable-model-invocation:[[:space:]]*true[[:space:]]*$' "$CMD_MD"; then
  ok "fallback.md sets disable-model-invocation: true (state-changing command)"
else bad "fallback.md does not set disable-model-invocation: true"; fi

# ── 2. the real subcommand set is documented ────────────────────────────────
for SUB in status set check arm where; do
  if grep -q "heimdall-fallback $SUB" "$CMD_MD"; then
    ok "fallback.md documents the real 'heimdall-fallback $SUB' subcommand"
  else
    bad "fallback.md never shows 'heimdall-fallback $SUB'"
  fi
done

# ── 3. THE CORRECTION: no config subcommand exists, and the doc never
#       invents one as a runnable line ──────────────────────────────────────
if grep -qE '^[[:space:]]*heimdall-fallback config([[:space:]]|$)' "$CMD_MD"; then
  bad "fallback.md invokes 'heimdall-fallback config' as a runnable line — IT DOES NOT EXIST"
else
  ok "fallback.md never invokes the nonexistent 'heimdall-fallback config' subcommand as a runnable line"
fi
if grep -qF 'no `config` subcommand' "$CMD_MD"; then
  ok "fallback.md states plainly that no config subcommand exists"
else
  bad "fallback.md does not call out the absence of a config subcommand"
fi
if grep -q 'target_provider' "$CMD_MD" && grep -q 'editing that JSON file directly' "$CMD_MD"; then
  ok "fallback.md documents the real mechanism: target_provider is set by direct JSON edit"
else
  bad "fallback.md does not document direct JSON-file editing for target_provider"
fi
# Cross-check against the live source so this claim cannot silently go stale.
if [ -x "$FALLBACK_BIN" ]; then
  SUBCOUNT="$(grep -c 'add_parser(' "$FALLBACK_BIN" || true)"
  if [ "$SUBCOUNT" = "5" ]; then
    ok "bin/heimdall-fallback still defines exactly 5 subparsers (status/set/check/arm/where) — the doc's 'no config subcommand' claim still holds"
  else
    bad "bin/heimdall-fallback now defines $SUBCOUNT subparser(s) (expected 5) — re-check fallback.md's 'no config subcommand' claim against the live source"
  fi
else
  bad "bin/heimdall-fallback is missing or not executable — cannot cross-check the subparser count"
fi

# ── 3b. `arm` self-provisioning is documented: never invents a credential,
#       the mandatory ANTHROPIC_MODEL export guidance, and that arm does not
#       start the gateway itself ────────────────────────────────────────────
if grep -qi 'never invents a credential' "$CMD_MD"; then
  ok "fallback.md documents that arm never invents a credential"
else
  bad "fallback.md does not state that arm never invents a credential"
fi
if grep -qF 'export ANTHROPIC_MODEL=' "$CMD_MD"; then
  ok "fallback.md shows the export ANTHROPIC_MODEL= guidance arm prints"
else
  bad "fallback.md missing the export ANTHROPIC_MODEL= guidance"
fi
if grep -qiE 'does not start the.*gateway|never starts the.*gateway' "$CMD_MD"; then
  ok "fallback.md states arm does not start the OmniRoute gateway itself"
else
  bad "fallback.md missing the 'arm does not start the gateway' caveat"
fi

# ── 4. the four states, in operator language ────────────────────────────────
if grep -q '| `off`' "$CMD_MD"; then ok "fallback.md documents 'off'"; else bad "fallback.md missing 'off' state row"; fi
if grep -q '| `on`' "$CMD_MD"; then ok "fallback.md documents 'on'"; else bad "fallback.md missing 'on' state row"; fi
if grep -q '| `auto`' "$CMD_MD"; then ok "fallback.md documents 'auto'"; else bad "fallback.md missing 'auto' state row"; fi
if grep -q '| `switch`' "$CMD_MD"; then ok "fallback.md documents 'switch'"; else bad "fallback.md missing 'switch' state row"; fi
if grep -qiE 'reviewer, verifier, security-auditor|adjudication' "$CMD_MD"; then
  ok "fallback.md documents that adjudication roles never route under 'on'"
else bad "fallback.md missing the adjudication-never-routes-under-on caveat"; fi
if grep -qiE '95%|five_hour' "$CMD_MD"; then
  ok "fallback.md documents auto's real ~95% exhaustion threshold"
else bad "fallback.md missing the auto exhaustion-threshold explanation"; fi

# ── 5. keys: no-auth needs none, keyed needs the env var NAME not the value ──
if grep -qiE 'no-auth|no key' "$CMD_MD"; then ok "fallback.md documents no-auth/keyless providers"; else bad "fallback.md missing no-auth provider documentation"; fi
if grep -q 'duckduckgo-web' "$CMD_MD"; then ok "fallback.md cites duckduckgo-web as the no-auth example"; else bad "fallback.md does not cite duckduckgo-web"; fi
if grep -q 'operator_key_env' "$CMD_MD" && grep -qiE 'name.*of the.*environment variable|never the key' "$CMD_MD"; then
  ok "fallback.md documents operator_key_env holds the env-var NAME, never the key itself"
else
  bad "fallback.md does not clearly document operator_key_env as a NAME, not a secret"
fi

# ── 6. the two honest caveats ────────────────────────────────────────────────
if grep -qiE "can't do real agent work" "$CMD_MD"; then
  ok "fallback.md states keyless providers can't do real agent work"
else bad "fallback.md missing the keyless-cannot-do-agent-work caveat"; fi
if grep -qiE 'cache' "$CMD_MD" && grep -qiE 'not free|real money|cache.*miss' "$CMD_MD"; then
  ok "fallback.md states routing is not free even when the provider is free (cache-miss cost)"
else bad "fallback.md missing the routing-is-not-free cache-cost caveat"; fi

# ── 7. scope honesty: model-independent, NOT harness-independent ───────────
if grep -qiE 'model.*independent' "$CMD_MD" && grep -qiE 'harness.*independent' "$CMD_MD"; then
  ok "fallback.md distinguishes model-independence from harness-independence"
else bad "fallback.md does not carry the model-vs-harness-independence scope caveat"; fi
if grep -q 'docs/analysis/2026-08-25-harness-independence-design.md' "$CMD_MD"; then
  ok "fallback.md cites the harness-independence design doc"
else bad "fallback.md does not cite docs/analysis/2026-08-25-harness-independence-design.md"; fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
