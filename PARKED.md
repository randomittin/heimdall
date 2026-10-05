# PARKED

What is deliberately not being built now. Seeded from section 16 of the runhmd execution plan ("Parked: do not build in the next 8 weeks"), with the rule that feeds it.

## The rule (plan 2.1, feature freeze)

A change ships only if it directly improves one of:

1. **Proof**: catching more real defects, fewer false denials.
2. **Trial**: time to first wow under 60 seconds.
3. **Distribution**: the PR comment, the receipt, the benchmark.
4. **Team value**: one install pulling in teammates.
5. **Cost visibility**: dollars per proven PR.

If a feature maps to none of them it goes in this file, not on a branch. A commit may say which one it serves with an optional trailer, `Maps-to: proof|trial|distribution|team-value|cost-visibility`. It is a convention for reviewers; no hook reads or enforces it.

## Parked

| Parked | Why it waits |
|---|---|
| Four-layer product packaging and pricing tiers | Not proof, trial, distribution, team value or cost visibility, and there is no usage data to price against. |
| Enterprise "organisational intelligence" features | Same rule; they need real team usage that does not exist yet. |
| Team presence beyond "what's blocked and why" | The presence wall that exists today stays as it is; extending it is parked. |
| New agent capabilities unrelated to proof | Every agent capability must improve a verdict or its trial; otherwise it waits. |
| Terminal emulation on mobile | The phone companion sends sealed, scoped commands, never a shell: `bin/heimdall-relay-client` holds no `shell=True` call. |
| Auto-merge of any kind | Not parked so much as refused: the human merge boundary is permanent (plan 2.3). Overnight and cloud work may observe, research, experiment, prove and open a PR, and may never merge or deploy by default. `test/no-auto-merge.test.sh` fails when a shipped code path merges or deploys without an explicit human action. |

Revisit the parked rows after week 8 of the plan, with real usage data.
