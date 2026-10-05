# attack — coverage

The falsifiable gate behind `hmd attack`. It answers "can I break this?" for a
settlement webhook by replaying an adversarial battery against it and diffing every
observable outcome against an **independent reference model**. A target no attack can
break is PROVEN; one a single attack breaks is DENIED, with a minimal counterexample.

## The profile contract (`settlement-webhook/1`)

A target is an ES module exporting `createWebhook({ store })` (default or named):

```js
{ handleEvent(event)                 -> { status: 'applied' | 'duplicate' },
  getBalance(account, caller)        -> integer cents | null,
  getSettlement(eventId, caller)     -> { event_id, account, gross_cents, fee_cents, net_cents } | null }
```

The injected `store` is the only way a handler may reach the outside world:
`get`, `set`, `putIfAbsent` (atomic), `incr` (atomic). Every store call costs 25ms of
**virtual** time and takes effect atomically at completion, so a handler that does
`await get(); await set()` has a real race window — exactly like a real database — and the
whole battery is deterministic and takes milliseconds. A directory target declares itself
in `runhmd.attack.json`:
`{"schema":"runhmd.attack-target/1","profile":"settlement-webhook/1","module":"webhook.mjs"}`.
A directory with no manifest has no attack surface and exits 2: a verdict over nothing
would be a false green.

The rules the reference implements (R1 idempotent application, R2 half-up integer-cent
fee, R3 credit + record, R4 exact-identity ownership) are in `INVARIANTS.md`.

## Independence (the reference is not the implementation's author)

`reference/settlement.ref.mjs` was written by a separate agent session from
`INVARIANTS.md` alone — it never read the engine, the fixtures or any target. The golden
(written by the engine's author) passing against it is two independent derivations of the
same spec agreeing; any divergence is adjudicated against `INVARIANTS.md`, not by vote.
`test/hmd-attack.test.sh` also cross-checks the reference's fee against Python
`decimal` `ROUND_HALF_UP` for every gross in 1..200000.

## The battery — 23 attacks

| class | attacks | what they catch |
|-------|---------|-----------------|
| duplicate | `sequential-retry` (1000ms apart); `retry-at-{0,1,10,25,49}ms`; `burst-of-3`; `distinct-events-same-account` | no idempotency; the check-then-act race a sequential test never sees; over-eager dedupe |
| idor | `{balance,settlement}-other-account`; `…-anonymous`; `…-prefix-lookalike`; `owner.reads-own-{balance,settlement}` | missing ownership check; prefix-match ownership; fixing IDOR by locking the owner out |
| rounding | `fee-on-{18,34,500,1500,2500,9999,100500}` | truncated / mis-rounded fee at the amounts where it differs from half-up |

Killed attacks fold into **findings** by root cause (five concurrent-retry attacks that
expose one race are ONE finding with five pieces of evidence).

## Mutants — one defect each, pinned to the exact attacks they must break

| mutant | defect | breaks |
|--------|--------|--------|
| `missed-duplicate` | no idempotency claim | all 7 duplicate/retry attacks |
| `racy-duplicate` | check-then-act, marked processed too late | the 6 concurrent attacks; **not** `sequential-retry` |
| `dedupes-by-account` | claim keyed by account, not event id | `distinct-events-same-account` |
| `missed-idor` | no ownership check | the 6 refusal attacks |
| `prefix-ownership` | `startsWith` ownership | the 2 prefix-lookalike attacks |
| `denies-owner` | reads refuse everyone | the 10 owner-read / delivery read-back attacks + 7 rounding |
| `off-by-one-rounding` | fee truncated, not half-up | the 7 rounding attacks |

`bin/falsify attack --assert-score 1.0` requires golden GREEN and 7/7 killed.
`test/hmd-attack.test.sh` additionally pins each mutant's exact kill set from
`manifest.json`, and proves the battery is load-bearing: drop the concurrent-retry
attacks and `racy-duplicate` SURVIVES (score 6/7).

## Isolation

`run.sh` copies the target into a private temp dir, runs it there under `env -i` with
HOME/TMPDIR inside the temp dir and a wall-clock watchdog, and — where node has a
permission model — lets it read only the engine and its own copy and write only the
result dir (no writes outside the temp dir, no child processes). Limits: the target runs
in-process with the battery, so a target that deliberately subverts the harness can forge
a result (this is built for buggy AI-written code, not hostile code), and node's
permission model does not block the network.
