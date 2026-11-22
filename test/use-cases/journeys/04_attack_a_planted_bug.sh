#!/usr/bin/env bash
# Journey 04 -- attack a planted bug (README "Then attack a planted bug", "What `hmd attack` does").
#
#   A developer has a settlement webhook that looks done. They ask `hmd attack` whether it can be broken:
#     1. with no terminal and no --yes it refuses to run anything (exit 3): hmd never assumes consent to execute code
#     2. with --yes the planted bug comes back DENIED (exit 1) with a minimal counterexample: a provider retry within 50ms credits the account twice
#     3. the counterexample's own repro command, run as printed, reproduces the same denial
#     4. the developer's project is untouched (the attack ran in a throwaway copy), nothing was left in HOME or TMPDIR
#     5. they make the claim atomic, attack again, and it is PROVEN (exit 0) over the same battery with nothing killed
#     6. it cost nothing: no model was called (the fake claude saw no call), no keychain was touched, cost is $0.00
#
# Engines reused: test/hmd-attack.test.sh [C] (CLI acceptance lines), fixtures/attack/{buggy-webhook,clean-sample}.
# Mutants (test/use-cases/mutants.list): consent assumed, the attack arm unrouted, the engine blind to the race.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"
uc_begin 04_attack_a_planted_bug
uc_need_node
uc_tree
uc_fakebin
uc_sandbox attack

HH="$UC_ROOT/attack/heimdall-home"       # hmd's own state, kept apart from HOME so that HOME can be asserted empty
mkdir -p "$HH"
: > "$HH/setup-done"                      # no first-run setup is part of this journey; an unrouted `attack` must fall into the fake claude, not a setup
PROJ="$UC_WORK/webhook-service"
cp -R "$UC_TREE/fixtures/attack/buggy-webhook" "$PROJ"
before="$(uc_manifest "$PROJ")"

attack() { uc_run "$UC_HOME" "$UC_WORK" HEIMDALL_HOME="$HH" -- "$UC_TREE/bin/hmd" attack "$@"; }

# 1. consent: no terminal, no --yes
attack webhook-service
uc_rc "attacking without --yes and without a terminal refuses" 3
if [ ! -s "$UC_OUT" ]; then uc_ok "the refusal prints no verdict"; else uc_bad "the refusal printed a verdict-like stdout" "$(head -c 200 "$UC_OUT")"; fi
uc_has "the refusal tells the developer to pass --yes" "$UC_ERR" '--yes'

# 2. the planted bug is DENIED, with a counterexample
attack webhook-service --json --yes
DENIED="$UC_ROOT/denied.json"; cp "$UC_OUT" "$DENIED"
uc_rc "the planted bug is DENIED" 1
uc_jq "the verdict is DENIED and carries at least one finding" '.verdict == "DENIED" and (.findings | length) >= 1' "$DENIED"
uc_jq "the finding is the 50ms duplicate-settlement race, high severity, with a two-delivery minimal input" \
  '.findings[0].title == "duplicate settlement (webhook+retry within 50ms)" and .findings[0].severity == "high" and (.findings[0].counterexample.minimal_input | fromjson | .deliveries | length) == 2' "$DENIED"
uc_jq "some attacks killed it and some survived, and they add up" '.attacks.killed >= 1 and .attacks.survived >= 1 and .attacks.total == (.attacks.killed + .attacks.survived)' "$DENIED"
uc_jq "it ran no model: cost 0, agent none" '.cost_usd == 0 and .agent.name == "none"' "$DENIED"

# the human card says the same thing
attack webhook-service --yes
uc_rc "the card run is DENIED too" 1
uc_has "the card shows the verdict" "$UC_OUT" 'VERDICT: DENIED'
uc_has "the card names the counterexample (the title wraps inside the box)" "$UC_OUT" 'duplicate settlement'
uc_has "…and the 50ms window" "$UC_OUT" 'within 50ms'

# 3. the printed repro command reproduces it
REPRO="$(jq -r '.findings[0].counterexample.repro_cmd' "$DENIED")"
case "$REPRO" in
  "hmd attack "*)
    # shellcheck disable=SC2086  # the repro command is an argv string: splitting it back into arguments is the point
    attack ${REPRO#hmd attack }
    uc_rc "the printed repro command (\`$REPRO\`) reproduces the denial" 1
    uc_jq "…with the same finding" '.findings[0].title == "duplicate settlement (webhook+retry within 50ms)"' "$UC_OUT" ;;
  *) uc_bad "the counterexample carries a runnable repro command" "got: $REPRO" ;;
esac

# 4. the developer's project and machine are left as they were
if [ "$before" = "$(uc_manifest "$PROJ")" ]; then uc_ok "the project is byte-identical after three attacks (the attack ran in a throwaway copy)"; else uc_bad "an attack modified the project under test"; fi
if [ -z "$(find "$UC_HOME" -mindepth 1 2>/dev/null)" ]; then uc_ok "HOME is untouched"; else uc_bad "an attack wrote into HOME" "$(find "$UC_HOME" -mindepth 1 | head -3 | tr '\n' ' ')"; fi
if [ -z "$(find "$UC_TMP" -mindepth 1 2>/dev/null)" ]; then uc_ok "the attack's temp dir is gone afterwards"; else uc_bad "an attack left files in TMPDIR" "$(find "$UC_TMP" -mindepth 1 | head -3 | tr '\n' ' ')"; fi

# 5. the developer makes the claim atomic: PROVEN over the same battery
cp "$UC_TREE/fixtures/attack/clean-sample/webhook.mjs" "$PROJ/webhook.mjs"
attack webhook-service --json --yes
PROVEN="$UC_ROOT/proven.json"; cp "$UC_OUT" "$PROVEN"
uc_rc "the fixed webhook is PROVEN" 0
uc_jq "PROVEN: no findings and nothing killed" '.verdict == "PROVEN" and .findings == [] and .attacks.killed == 0' "$PROVEN"
if [ "$(jq -r '.attacks.total' "$DENIED")" = "$(jq -r '.attacks.total' "$PROVEN")" ]; then uc_ok "it survived the same battery the bug was denied by"; else uc_bad "the battery size changed between the two verdicts"; fi

# 6. no model, no keychain
if [ ! -s "$UC_CLAUDE_LOG" ]; then uc_ok "no model session was started (the fake claude saw no call)"; else uc_bad "hmd attack started a claude session" "$(head -c 200 "$UC_CLAUDE_LOG")"; fi
if [ ! -s "$UC_SECURITY_LOG" ]; then uc_ok "the keychain was never asked"; else uc_bad "hmd attack asked the keychain" "$(head -c 200 "$UC_SECURITY_LOG")"; fi

uc_finish
