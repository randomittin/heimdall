// Settlement REFERENCE model for the `attack` oracle (domain settlement-webhook/1).
//
// PROVENANCE: derived solely from evals/oracles/attack/INVARIANTS.md (rules R1-R4
// and its "Reference module contract" section). Authored independently of the
// attack engine and of any implementation under test: neither was read, so a
// misreading shared between them cannot hide in this model.
//
// Pure ES module: no imports, no I/O, no clock, no randomness, no state shared
// between calls. All money is whole US cents: fees are computed in BigInt and
// balances are guarded to stay inside Number's exact integer range, so no amount
// is ever rounded implicitly.

const MIN_GROSS_CENTS = 1;
const MAX_GROSS_CENTS = 1e12;

// Contract: feeCents / netCents throw RangeError unless grossCents is an integer in
// [1, 1e12]. Number.isInteger is false for every non-number (string, BigInt, null,
// object, symbol), for NaN and for +/-Infinity, so nothing is ever coerced. The
// message does not interpolate the offending value, so building it cannot throw a
// different error type.
function assertGrossCents(grossCents) {
  if (
    !Number.isInteger(grossCents) ||
    grossCents < MIN_GROSS_CENTS ||
    grossCents > MAX_GROSS_CENTS
  ) {
    throw new RangeError(
      `grossCents must be an integer in [${MIN_GROSS_CENTS}, ${MAX_GROSS_CENTS}]`
    );
  }
}

// R2 - fee: 2.9 % of the gross amount, rounded half-up to a whole cent, in exact
// integer arithmetic (never floating point):
//   fee_cents = floor((gross_cents * 29 + 500) / 1000)
// 29/1000 is the rate; adding 500/1000 (half a cent) before the floor is what makes
// the rounding half-up. BigInt division truncates toward zero, which is floor for
// the positive operands assertGrossCents guarantees. The fee is at most 2.9e10, so
// converting back to Number is lossless.
export function feeCents(grossCents) {
  assertGrossCents(grossCents);
  return Number((BigInt(grossCents) * 29n + 500n) / 1000n);
}

// R2 - net: what the fee leaves of the gross amount, so fee + net == gross exactly.
export function netCents(grossCents) {
  const fee = feeCents(grossCents); // also validates grossCents (RangeError)
  return grossCents - fee;
}

// R3 - the settlement record of one event, with fee and net split per R2. Because
// net = gross - fee, fee_cents + net_cents == gross_cents for every event: no cent is
// created or lost. Throws TypeError for a malformed event and RangeError (via
// feeCents) for a gross_cents outside the contract range. `currency` is not consumed
// by any rule, so it is not inspected.
function toSettlement(event) {
  if (event === null || typeof event !== 'object') {
    throw new TypeError('each delivery must be an event object');
  }
  const { id, account, gross_cents: grossCents } = event;
  if (typeof id !== 'string' || typeof account !== 'string') {
    throw new TypeError('event.id and event.account must be strings');
  }
  return {
    event_id: id,
    account,
    gross_cents: grossCents,
    fee_cents: feeCents(grossCents),
    net_cents: netCents(grossCents),
  };
}

// R1 + R3 - apply deliveries, in delivery order, to an empty ledger.
//
// deliveries: array of events { id, account, gross_cents, currency }; the same id may
// appear several times (provider retries). Deliveries that overlap in time are modeled
// by their position in the array: the earlier position is the one that is applied.
// Returns
//   balances:    { [account]: integer cents }  - an account never credited is absent
//   settlements: { [eventId]: { event_id, account, gross_cents, fee_cents, net_cents } }
//   statuses:    'applied' | 'duplicate' per delivery, parallel to `deliveries`
// The input is only read, never mutated, and the result is built from fresh plain
// objects and arrays.
export function applyEvents(deliveries) {
  if (!Array.isArray(deliveries)) {
    throw new TypeError('deliveries must be an array of events');
  }

  // Working state is local to this call, so nothing is shared between calls. Map keys,
  // unlike plain-object keys, make ids and accounts such as "__proto__", "constructor"
  // or "toString" ordinary data instead of prototype lookups.
  const balances = new Map();
  const settlements = new Map();
  const statuses = [];

  for (const event of deliveries) {
    const settlement = toSettlement(event);

    // R1 - idempotent application: an event id takes effect at most once. The first
    // delivery of an id is 'applied'; every later delivery of it is 'duplicate' and
    // changes nothing (first delivery wins). An id has taken effect exactly when a
    // settlement is recorded for it.
    if (settlements.has(settlement.event_id)) {
      statuses.push('duplicate');
      continue;
    }

    // R3 - credit: add net_cents to the named account's balance. A balance is a Number,
    // so a sum past Number.MAX_SAFE_INTEGER could no longer be exact: refuse instead of
    // silently losing cents.
    const balance = (balances.get(settlement.account) ?? 0) + settlement.net_cents;
    if (!Number.isSafeInteger(balance)) {
      throw new RangeError('account balance exceeds Number.MAX_SAFE_INTEGER');
    }

    // R3 - record the settlement, retrievable by event id.
    balances.set(settlement.account, balance);
    settlements.set(settlement.event_id, settlement);
    statuses.push('applied');
  }

  // Object.fromEntries defines own data properties, so a key such as "__proto__" stays
  // an ordinary own key of an ordinary (plain) object.
  return {
    balances: Object.fromEntries(balances),
    settlements: Object.fromEntries(settlements),
    statuses,
  };
}

// R4 - ownership: an account's balance and the settlement records credited to it are
// readable only by a caller whose identity equals the account id exactly: plain string
// equality, with no prefix match, case folding, trimming or normalization. The typeof
// guard refuses the anonymous caller (null) and every other non-string identity, and
// keeps `null === null` or `undefined === undefined` from ever granting a read. A
// refused read must be presented to the reader exactly like "not found"; this predicate
// only says whether the read may proceed.
export function mayRead(callerId, accountId) {
  return typeof callerId === 'string' && callerId === accountId;
}
