# attack oracle — settlement-webhook/1 invariants

The business rules the `attack` oracle grades a settlement webhook against.
This file is the SPEC. The independent reference model
(`reference/settlement.ref.mjs`) is derived from it, and from nothing else: its
author never reads the attack engine or any candidate implementation, so a
misreading shared by the engine author and the implementation author cannot hide
in the reference (see `evals/oracles/README.md`, `reference.independent`).

## Domain

A payment provider delivers `payment.settled` webhook events to a merchant
service. The service credits the merchant's account ledger, and lets an account
owner read their own balance and their own settlement records. Providers retry
deliveries (timeouts, 5xx), so the same event can arrive more than once — one
delivery after the other, or overlapping in time.

- **Event**: `{ id: string, account: string, gross_cents: positive integer, currency: "USD" }`.
  `id` is unique per provider event; every redelivery of an event carries the
  same `id` and the same payload.
- **Caller**: the identity making a read is a string account id, or `null` for an
  anonymous caller.
- All money is whole US cents. There are no fractions of a cent anywhere.

## Rules

**R1 — idempotent application.** An event id takes effect at most once, however
many times it is delivered and however closely the deliveries overlap in time.
Exactly one delivery of an id is reported `applied`; every other delivery of that
id is reported `duplicate` and changes nothing.

**R2 — fee.** The processing fee is 2.9 % of the gross amount, rounded
half-up to a whole cent, computed in exact integer arithmetic (never floating
point): `fee_cents = floor((gross_cents * 29 + 500) / 1000)`.
`net_cents = gross_cents - fee_cents`. Worked examples: gross 500 is an exact
14.5-cent fee, which rounds UP to 15, so net is 485; gross 18 has an exact fee of
0.522 cents, which rounds to 1, so net is 17; gross 17 has an exact fee of
0.493 cents, which rounds to 0, so net is 17.

**R3 — credit.** Applying an event adds `net_cents` to the named account's
balance and records one settlement `{ event_id, account, gross_cents, fee_cents,
net_cents }`, retrievable by event id. For every applied event
`fee_cents + net_cents == gross_cents`: no cent is created or lost.

**R4 — ownership.** An account's balance, and the settlement records of events
credited to it, are readable only by a caller whose identity equals the account id
exactly (plain string equality — no prefix, case-folding or trimming). Every other
caller is refused: a different account, the anonymous caller, and a caller whose id
merely starts with the account id. A refused read is indistinguishable from "not
found".

## Reference module contract

`reference/settlement.ref.mjs` is a pure ES module: no imports, no I/O, no clock,
no randomness, no shared state between calls.

```js
export function feeCents(grossCents)   // integer; R2
export function netCents(grossCents)   // integer; R2
export function applyEvents(deliveries)
// deliveries: array of events in delivery order; the same id may appear several times.
// returns {
//   balances:    { [account]: integer cents }       // an account never credited is absent
//   settlements: { [eventId]: { event_id, account, gross_cents, fee_cents, net_cents } }
//   statuses:    Array<'applied' | 'duplicate'>      // parallel to `deliveries`
// }
// The first delivery of an id is 'applied'; every later delivery of it is 'duplicate'.
export function mayRead(callerId, accountId)  // boolean; R4 (callerId may be null/undefined/non-string => false)
```

`feeCents` / `netCents` throw `RangeError` unless `grossCents` is an integer in
`[1, 1e12]`.
