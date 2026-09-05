#!/usr/bin/env bash
# test/heimdall-fallback-command.test.sh — /hmd:fallback slash command static contract.
#
# WHAT THIS GATES. bin/heimdall-fallback is a fully working three-state OmniRoute
# routing gate (see test/heimdall-fallback.test.sh) with, until now, no slash
# command exposing it — an operator who doesn't already know the raw bin/ tool
# exists has no way to discover or drive it from Claude Code. This locks the
# fix (commands/fallback.md):
#   1. The file exists with the correct frontmatter (name: fallback,
#      argument-hint, disable-model-invocation: true — it changes real state).
#   2. It documents the real subcommand set: status / set / check / arm /
#      base-url / token-file / model / where.
#   3. THE CORRECTION THAT MATTERS MOST: there is NO `heimdall-fallback
#      config` subcommand. build_parser() in bin/heimdall-fallback defines
#      exactly twelve subparsers (the original eight operator/seam commands
#      plus `coop` and its three nested `add`/`remove`/`list` subparsers,
#      added when the coop state landed); an earlier, unverified assumption
#      asserted a `config target_provider <x>` subcommand existed. This test locks in
#      the truth two ways — the doc must say plainly that no config
#      subcommand exists (target_provider/operator_key_env are set by
#      editing the JSON file directly), and the doc must never itself invoke
#      a `heimdall-fallback config ...` line as if it were real — AND it
#      cross-checks the doc's claim against the live source, so the claim
#      cannot silently go stale if the tool ever grows a real config verb.
#   4. It documents the three states in operator language, and that `auto`
#      reacts to the real ~95% exhaustion threshold.
#   5. It documents the operator-facing caveats: operator_key_env holds the
#      env-var NAME (never the key itself), no-auth providers need no key,
#      keyless providers can't do real agent work, and routing costs real
#      cache-miss money even against a free provider.
#   6. It does not overstate scope: model-independent via OmniRoute, NOT
#      harness-independent (the harness stays Claude Code either way).
#   7. It documents the three subcommands added since: `base-url`,
#      `token-file`, and `model` — programmatic seams bin/heimdall-route
#      consumes directly, not everyday operator commands — including each
#      one's real stdout contract (ROUTE-only for base-url, path-never-
#      contents plus a group/world-readable refusal for token-file).
#   8. It documents the `fallback_model` config field: empty by default,
#      blocking `auto` from ever reaching ROUTE unattended until set, and
#      that an operator-set ANTHROPIC_MODEL always outranks it.
#   9. It documents what gets sent when fallback actually routes: local
#      session context goes to the third-party provider (not Anthropic),
#      with the measured ~41k-tokens-in-one-request datapoint stated as a
#      measurement rather than a cap; that this is opt-in and safe by
#      default because fallback config is per-repo and `off` is the
#      default; and the practical guidance to route small, self-contained
#      tasks rather than long accumulated sessions to minimize exposure.
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

# ── 2. the real subcommand set is documented (5 operator-facing + 3 seams
#       bin/heimdall-route consumes directly: base-url/token-file/model) ───
for SUB in status set check arm base-url token-file model where; do
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
  if [ "$SUBCOUNT" = "12" ]; then
    ok "bin/heimdall-fallback still defines exactly 12 subparsers (status/set/check/arm/base-url/token-file/model/where/coop/coop-add/coop-remove/coop-list) — the doc's 'no config subcommand' claim still holds"
  else
    bad "bin/heimdall-fallback now defines $SUBCOUNT subparser(s) (expected 12) — re-check fallback.md's 'no config subcommand' claim against the live source"
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
if grep -q '| `on`' "$CMD_MD"; then bad "fallback.md still documents a removed 'on' state row"; else ok "fallback.md correctly has no 'on' state row (removed)"; fi
if grep -q '| `auto`' "$CMD_MD"; then ok "fallback.md documents 'auto'"; else bad "fallback.md missing 'auto' state row"; fi
if grep -q '| `switch`' "$CMD_MD"; then ok "fallback.md documents 'switch'"; else bad "fallback.md missing 'switch' state row"; fi
if grep -qiE 'reviewer, verifier, security-auditor|never route under .on.' "$CMD_MD"; then
  bad "fallback.md still documents the removed on-state's adjudication-tier language"
else ok "fallback.md correctly has no leftover on-state adjudication-tier language"; fi
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

# ── 8. the three seams (base-url/token-file/model) are documented with their
#       real behavioral contracts, and framed as programmatic seams rather
#       than everyday operator commands ─────────────────────────────────────
if grep -qiE 'only when the verdict is route' "$CMD_MD" && grep -qiE 'stdout stays byte-empty' "$CMD_MD"; then
  ok "fallback.md documents base-url prints a URL only on ROUTE and stays byte-empty otherwise"
else
  bad "fallback.md does not document base-url's ROUTE-only / byte-empty-otherwise stdout contract"
fi

if grep -qiE 'never its contents' "$CMD_MD" && grep -qiE 'group/world-readable' "$CMD_MD"; then
  ok "fallback.md documents token-file prints only a path and refuses a group/world-readable file"
else
  bad "fallback.md does not document token-file's path-only / group-world-readable-refusal contract"
fi

if grep -qF 'prints the model id hmd pins on a routed' "$CMD_MD"; then
  ok "fallback.md documents what the model subcommand prints"
else
  bad "fallback.md does not document the model subcommand's purpose"
fi

if grep -qiE 'not everyday commands|not an operator-invoked subcommand' "$CMD_MD"; then
  ok "fallback.md frames base-url/token-file/model as seams bin/heimdall-route consumes, not everyday operator commands"
else
  bad "fallback.md does not frame base-url/token-file/model as internal seams rather than operator commands"
fi

# ── 9. fallback_model: empty by default, blocks auto until set, and an
#       operator-set ANTHROPIC_MODEL always outranks it ─────────────────────
if grep -qiE 'empty by default' "$CMD_MD" && grep -qiE 'auto.*can only ever wait' "$CMD_MD"; then
  ok "fallback.md documents fallback_model is empty by default and blocks auto from routing while empty"
else
  bad "fallback.md does not document fallback_model's empty-by-default / auto-blocking behavior"
fi

if grep -qiE 'operator-set.*ANTHROPIC_MODEL.*always outranks' "$CMD_MD"; then
  ok "fallback.md documents that an operator-set ANTHROPIC_MODEL always outranks fallback_model"
else
  bad "fallback.md does not document ANTHROPIC_MODEL's precedence over fallback_model"
fi


# ── 10. "What gets sent when fallback routes": the measured context-exposure
#        section — what leaves, why it's opt-in/per-repo, and how to
#        minimize it ─────────────────────────────────────────────────────────
if grep -qi 'what gets sent when fallback routes' "$CMD_MD"; then
  ok "fallback.md has a section documenting what gets sent when fallback routes"
else
  bad "fallback.md missing a section documenting what gets sent when fallback routes"
fi

if grep -qE '41,?000 tokens' "$CMD_MD"; then
  ok "fallback.md states the measured ~41k-tokens-in-one-request datapoint"
else
  bad "fallback.md does not state the measured ~41k-tokens context-exposure datapoint"
fi

if grep -qi 'measurement' "$CMD_MD" && grep -qiE 'not a cap|not a guarantee' "$CMD_MD"; then
  ok "fallback.md frames the 41k-token figure as a measurement, not a cap or guarantee"
else
  bad "fallback.md does not frame the 41k-token figure as a measurement rather than a cap/guarantee"
fi

if grep -qiE 'volunteered unrelated local details' "$CMD_MD"; then
  ok "fallback.md documents that the receiving model retained and echoed back unrelated local context (as a class, no specifics)"
else
  bad "fallback.md does not document that the receiving model retained/echoed unrelated local context"
fi

if grep -qiE 'fallback config is per-repo' "$CMD_MD" && grep -qF -e '--repo "$PWD"' "$CMD_MD"; then
  ok "fallback.md documents fallback config is per-repo (heimdall-route calls heimdall-fallback --repo \"\$PWD\")"
else
  bad "fallback.md does not document that fallback config is per-repo"
fi

if grep -qiE 'opt-in exposure, not exposure by default' "$CMD_MD"; then
  ok "fallback.md states plainly that this exposure is opt-in, not on by default"
else
  bad "fallback.md does not plainly state the exposure is opt-in rather than default"
fi

if grep -qiE 'prefer routing small, self-contained tasks' "$CMD_MD"; then
  ok "fallback.md gives the practical guidance to route small, self-contained tasks to minimize exposure"
else
  bad "fallback.md missing the practical minimize-exposure guidance (route small, self-contained tasks)"
fi

if grep -qiE "none of this touches the Tier-1 boundary" "$CMD_MD"; then
  ok "fallback.md cross-references the Tier-1 boundary rather than restating the full mechanism"
else
  bad "fallback.md does not cross-reference the Tier-1 boundary from the new context-exposure section"
fi

# ── 11. arm refusal must be unambiguous: checked and stated BEFORE relaying,
#        never left to a REFUSED: line buried in a verbatim relay -- this is
#        the exact ambiguity that let `/hmd:fallback switch` silently leave
#        state unchanged (operator ran `switch`; .heimdall/fallback.json's
#        state stayed `auto` afterward with no error surfaced) ────────────
if grep -qF 'arm refuses and the operator wants to supply their own provider/key by' "$CMD_MD"; then
  bad "fallback.md still gates the manual-set fallback behind the old ambiguous 'if arm refuses AND the operator wants' conditional -- this let /hmd:fallback switch silently leave state unchanged"
else
  ok "fallback.md no longer gates the manual-set fallback behind the old ambiguous conditional clause"
fi

if grep -qF 'state was NOT changed' "$CMD_MD"; then
  ok "fallback.md states plainly that a REFUSED arm means state was NOT changed"
else
  bad "fallback.md does not plainly state that a refusal leaves state unchanged"
fi

if grep -qF 'Before relaying or saying anything' "$CMD_MD"; then
  ok "fallback.md instructs checking arm's output for REFUSED: before relaying or saying anything else"
else
  bad "fallback.md does not instruct checking for REFUSED: before relaying anything else"
fi

if grep -qF 'proactively offer the manual fallback' "$CMD_MD"; then
  ok "fallback.md proactively offers the manual set fallback on an arm refusal, rather than waiting to be asked"
else
  bad "fallback.md does not proactively offer the manual fallback on an arm refusal"
fi

if grep -qF 'state was left unchanged and why' "$CMD_MD"; then
  ok "fallback.md's bare 'arm' subcommand branch also states plainly when state was left unchanged"
else
  bad "fallback.md's bare 'arm' subcommand branch does not plainly state when state was left unchanged"
fi

echo
echo "  Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
