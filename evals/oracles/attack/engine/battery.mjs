// engine/battery.mjs — the attack battery for profile settlement-webhook/1.
//
// Each attack is a self-contained scenario: a few webhook deliveries (and/or one read)
// replayed through the target on the virtual clock, and an expected outcome taken from
// the INDEPENDENT reference model (reference/settlement.ref.mjs, derived from
// INVARIANTS.md by someone other than the author of this engine or of any target).
// The engine decides nothing about correctness itself: it builds the scenario, runs the
// target, and compares what came back with what the reference says must have happened.
//
// An attack that makes the target diverge from the reference is KILLED (a defect found);
// one it withstands SURVIVED. Killed attacks are grouped into findings by `finding` key,
// so five concurrent-retry attacks that expose one race report ONE finding with all five
// as evidence, not five findings.

import { isDeepStrictEqual } from 'node:util';
import { applyEvents, mayRead } from '../reference/settlement.ref.mjs';
import { VirtualClock, createStore, drive, call, STORE_LATENCY_MS } from './harness.mjs';

export const SUITE = 'attack-suite/1';
export const PROFILE = 'settlement-webhook/1';

// finding key -> what a user reads. `category` is one of the runhmd.verdict/1 categories.
export const FINDINGS = {
  'dup-sequential': { title: 'duplicate settlement (event re-delivered after completion is credited twice)', severity: 'high', category: 'logic' },
  'dup-concurrent': { title: 'duplicate settlement (webhook+retry within 50ms)', severity: 'high', category: 'concurrency' },
  'dup-overdedupe': { title: 'distinct events are dropped as duplicates', severity: 'high', category: 'logic' },
  'idor-balance': { title: "another account's balance is readable (IDOR)", severity: 'high', category: 'auth' },
  'idor-settlement': { title: "another account's settlement record is readable (IDOR)", severity: 'high', category: 'auth' },
  'idor-prefix': { title: 'ownership check matches by id prefix, not identity', severity: 'high', category: 'auth' },
  'owner-denied': { title: 'the account owner cannot read their own balance or settlement', severity: 'medium', category: 'regression' },
  'rounding-fee': { title: 'fee rounding is off by one cent (not half-up)', severity: 'medium', category: 'logic' },
};

const OWNER = 'acct_A';
const OTHER = 'acct_B';
const LOOKALIKE = 'acct_A1';
const SETTLED = { id: 'evt_1001', account: OWNER, gross_cents: 10000, currency: 'USD' };
const ev = (id, account, gross) => ({ id, account, gross_cents: gross, currency: 'USD' });

const deliveries = (latency, list) => ({ kind: 'deliveries', latency_ms: latency, deliveries: list });
const reads = (setup, read) => ({ kind: 'reads', latency_ms: STORE_LATENCY_MS, setup, read });

function duplicateCases() {
  const twice = (at) => deliveries(STORE_LATENCY_MS, [{ at_ms: 0, event: SETTLED }, { at_ms: at, event: SETTLED }]);
  const retryAt = [0, 1, 10, 25, 49].map((at) => ({
    id: `duplicate.retry-at-${at}ms`,
    class: 'duplicate',
    finding: 'dup-concurrent',
    title: `same event delivered twice, the retry ${at}ms after the first delivery`,
    scenario: twice(at),
  }));
  return [
    {
      id: 'duplicate.sequential-retry',
      class: 'duplicate',
      finding: 'dup-sequential',
      title: 'same event delivered twice, 1000ms apart (the first has long completed)',
      scenario: twice(1000),
    },
    ...retryAt,
    {
      id: 'duplicate.burst-of-3',
      class: 'duplicate',
      finding: 'dup-concurrent',
      title: 'same event delivered three times, at 0ms, 5ms and 10ms',
      scenario: deliveries(STORE_LATENCY_MS, [
        { at_ms: 0, event: SETTLED },
        { at_ms: 5, event: SETTLED },
        { at_ms: 10, event: SETTLED },
      ]),
    },
    {
      id: 'duplicate.distinct-events-same-account',
      class: 'duplicate',
      finding: 'dup-overdedupe',
      title: 'two different events for one account delivered together',
      scenario: deliveries(STORE_LATENCY_MS, [
        { at_ms: 0, event: SETTLED },
        // 1000 gross is an exact 29-cent fee: no rounding in play, so only a duplicate defect can break this case
        { at_ms: 0, event: ev('evt_1002', OWNER, 1000) },
      ]),
    },
  ];
}

function readCases() {
  const setup = [SETTLED];
  const balance = (caller) => reads(setup, { op: 'balance', account: OWNER, caller });
  const settlement = (caller) => reads(setup, { op: 'settlement', event_id: SETTLED.id, account: OWNER, caller });
  return [
    { id: 'idor.balance-other-account', class: 'idor', finding: 'idor-balance', title: `${OTHER} reads ${OWNER}'s balance`, scenario: balance(OTHER) },
    { id: 'idor.settlement-other-account', class: 'idor', finding: 'idor-settlement', title: `${OTHER} reads ${OWNER}'s settlement ${SETTLED.id}`, scenario: settlement(OTHER) },
    { id: 'idor.balance-anonymous', class: 'idor', finding: 'idor-balance', title: `an anonymous caller reads ${OWNER}'s balance`, scenario: balance(null) },
    { id: 'idor.settlement-anonymous', class: 'idor', finding: 'idor-settlement', title: `an anonymous caller reads ${OWNER}'s settlement ${SETTLED.id}`, scenario: settlement(null) },
    { id: 'idor.balance-prefix-lookalike', class: 'idor', finding: 'idor-prefix', title: `${LOOKALIKE} (an id that starts with ${OWNER}) reads ${OWNER}'s balance`, scenario: balance(LOOKALIKE) },
    { id: 'idor.settlement-prefix-lookalike', class: 'idor', finding: 'idor-prefix', title: `${LOOKALIKE} (an id that starts with ${OWNER}) reads ${OWNER}'s settlement`, scenario: settlement(LOOKALIKE) },
    { id: 'owner.reads-own-balance', class: 'idor', finding: 'owner-denied', title: `${OWNER} reads their own balance`, scenario: balance(OWNER) },
    { id: 'owner.reads-own-settlement', class: 'idor', finding: 'owner-denied', title: `${OWNER} reads their own settlement ${SETTLED.id}`, scenario: settlement(OWNER) },
  ];
}

// Gross amounts where truncating the fee (floor) differs from rounding it half-up: a
// fractional fee above .5 (18, 34, 9999) and exact half-cent fees (500, 1500, 2500, 100500).
const ROUNDING_AMOUNTS = [18, 34, 500, 1500, 2500, 9999, 100500];

function roundingCases() {
  return ROUNDING_AMOUNTS.map((gross) => ({
    id: `rounding.fee-on-${gross}`,
    class: 'rounding',
    finding: 'rounding-fee',
    title: `one event of ${gross} gross cents`,
    scenario: deliveries(STORE_LATENCY_MS, [{ at_ms: 0, event: ev(`evt_r${gross}`, OWNER, gross) }]),
  }));
}

export const CASES = [...duplicateCases(), ...readCases(), ...roundingCases()];

// ── comparison helpers ──────────────────────────────────────────────────────────────

const sortedKeys = (key, value) => (value && typeof value === 'object' && !Array.isArray(value)
  ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
  : value);
const show = (value) => JSON.stringify(value === undefined ? null : value, sortedKeys);

const pickRecord = (value) => {
  if (!value || typeof value !== 'object') return value === undefined ? null : value;
  const { event_id, account, gross_cents, fee_cents, net_cents } = value;
  return { event_id, account, gross_cents, fee_cents, net_cents };
};
const observed = (result, pick = (v) => v) => (result.ok ? pick(result.value) : `threw: ${result.error}`);

// ── scenario runners ─────────────────────────────────────────────────────────────────

async function runDeliveries(createWebhook, sc) {
  const clock = new VirtualClock();
  const store = createStore(clock, sc.latency_ms);
  const accounts = [...new Set(sc.deliveries.map((d) => d.event.account))];
  const events = new Map(sc.deliveries.map((d) => [d.event.id, d.event]));
  const outcome = await drive(clock, async () => {
    const hook = createWebhook({ store });
    const results = await Promise.all(sc.deliveries.map(async (d) => {
      await clock.sleep(d.at_ms);
      return call(() => hook.handleEvent(structuredClone(d.event)));
    }));
    const balances = {};
    for (const account of accounts) balances[account] = await call(() => hook.getBalance(account, account));
    const settlements = {};
    for (const [id, event] of events) settlements[id] = await call(() => hook.getSettlement(id, event.account));
    return { results, balances, settlements };
  });
  if (!outcome.ok) return { killed: true, aspect: 'run', expected: 'the deliveries settle', actual: `threw: ${String((outcome.error && outcome.error.message) || outcome.error)}` };

  const order = sc.deliveries
    .map((d, i) => ({ d, i }))
    .sort((a, b) => a.d.at_ms - b.d.at_ms || a.i - b.i)
    .map(({ d }) => d.event);
  const ref = applyEvents(order);
  const { results, balances, settlements } = outcome.value;

  const gotStatuses = results.map((r) => (r.ok ? (r.value && r.value.status) || 'no-status' : `threw: ${r.error}`)).sort();
  const wantStatuses = [...ref.statuses].sort();
  if (!isDeepStrictEqual(gotStatuses, wantStatuses)) {
    return { killed: true, aspect: 'delivery statuses', expected: show(wantStatuses), actual: show(gotStatuses) };
  }
  for (const account of accounts) {
    const got = observed(balances[account]);
    if (got !== ref.balances[account]) {
      return { killed: true, aspect: `balance of ${account} (cents)`, expected: show(ref.balances[account]), actual: show(got) };
    }
  }
  for (const [id] of events) {
    const got = observed(settlements[id], pickRecord);
    if (!isDeepStrictEqual(got, ref.settlements[id])) {
      return { killed: true, aspect: `settlement record of ${id}`, expected: show(ref.settlements[id]), actual: show(got) };
    }
  }
  return { killed: false };
}

async function runReads(createWebhook, sc) {
  const clock = new VirtualClock();
  const store = createStore(clock, sc.latency_ms);
  const outcome = await drive(clock, async () => {
    const hook = createWebhook({ store });
    for (const event of sc.setup) await call(() => hook.handleEvent(structuredClone(event)));
    const { op, account, event_id: eventId, caller } = sc.read;
    return call(() => (op === 'balance' ? hook.getBalance(account, caller) : hook.getSettlement(eventId, caller)));
  });
  if (!outcome.ok) return { killed: true, aspect: 'run', expected: 'the read settles', actual: `threw: ${String((outcome.error && outcome.error.message) || outcome.error)}` };

  const ref = applyEvents(sc.setup);
  const { op, account, event_id: eventId, caller } = sc.read;
  const result = outcome.value;
  const refused = !result.ok || result.value === null || result.value === undefined;
  const aspect = op === 'balance' ? `balance of ${account}` : `settlement record of ${eventId}`;

  if (!mayRead(caller, account)) {
    return refused ? { killed: false } : { killed: true, aspect, expected: 'refused', actual: `returned ${show(op === 'balance' ? result.value : pickRecord(result.value))}` };
  }
  const want = op === 'balance' ? ref.balances[account] : ref.settlements[eventId];
  const got = refused ? 'refused' : (op === 'balance' ? result.value : pickRecord(result.value));
  return isDeepStrictEqual(got, want) ? { killed: false } : { killed: true, aspect, expected: show(want), actual: show(got) };
}

const RUNNERS = { deliveries: runDeliveries, reads: runReads };

export async function runCase(createWebhook, attack) {
  const verdict = await RUNNERS[attack.scenario.kind](createWebhook, attack.scenario);
  return { ...attack, ...verdict, status: verdict.killed ? 'killed' : 'survived' };
}

// Run the whole battery against a target factory and fold the killed attacks into findings.
export async function runBattery(createWebhook, cases = CASES) {
  const results = [];
  for (const attack of cases) results.push(await runCase(createWebhook, attack));

  const groups = new Map();
  for (const r of results.filter((x) => x.killed)) {
    if (!groups.has(r.finding)) groups.set(r.finding, []);
    groups.get(r.finding).push(r);
  }
  const findings = [...groups].map(([key, killed]) => {
    const first = killed[0];
    return {
      key,
      ...FINDINGS[key],
      attacks: killed.map((r) => r.id),
      counterexample: {
        attack_id: first.id,
        summary: `${first.title}: ${first.aspect} should be ${first.expected} but was ${first.actual}`,
        minimal_input: JSON.stringify(first.scenario),
      },
      evidence: killed.map((r) => ({ attack_id: r.id, title: r.title, aspect: r.aspect, expected: r.expected, actual: r.actual, scenario: r.scenario })),
    };
  });
  const killedCount = results.filter((r) => r.killed).length;
  const firstKilled = results.find((r) => r.killed);
  return {
    suite: SUITE,
    profile: PROFILE,
    attacks: { total: results.length, survived: results.length - killedCount, killed: killedCount },
    cases: results.map((r) => ({ id: r.id, class: r.class, status: r.status })),
    first_divergence: firstKilled ? { attack_id: firstKilled.id, expected: firstKilled.expected, actual: firstKilled.actual } : null,
    findings,
  };
}
