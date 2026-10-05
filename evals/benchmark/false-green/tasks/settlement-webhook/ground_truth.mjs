// ground_truth.mjs: the ground truth for the settlement-webhook task. Property checks of a
// candidate against rules R1-R4 of evals/oracles/attack/INVARIANTS.md, on a virtual-time store
// of its own. It imports nothing from the attack engine, its battery or its reference model.
//
// usage:  node ground_truth.mjs <candidate.mjs>
// stdout: one JSON line {"result":"pass"|"fail", ...}
// exit:   0 pass, 1 fail (a rule is violated), 2 the check itself could not run
//
// What it checks (PREREG.md section 6): SCENARIOS seeded random scenarios, then every gross
// from 1 to FEE_MAX against the exact fee formula.
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const SCENARIOS = 300;
const FEE_MAX = 20000;
const FEE_BATCH = 250;
const STORE_MS = 25;
const ACCOUNTS = ['acct_A', 'acct_B', 'acct_AB'];

const feeOf = (gross) => Math.floor((gross * 29 + 500) / 1000); // R2, exact integer arithmetic
const show = (value) => JSON.stringify(value === undefined ? null : value);

// ── virtual time: every store call completes STORE_MS later and takes effect atomically then ──
class Sim {
  constructor() {
    this.now = 0;
    this.seq = 0;
    this.timers = [];
  }

  after(ms, fn) {
    this.timers.push({ at: this.now + ms, seq: this.seq++, fn });
  }

  sleep(ms) {
    return new Promise((done) => this.after(ms, done));
  }

  fireNext() {
    let best = 0;
    for (let i = 1; i < this.timers.length; i++) {
      const a = this.timers[i];
      const b = this.timers[best];
      if (a.at < b.at || (a.at === b.at && a.seq < b.seq)) best = i;
    }
    const [timer] = this.timers.splice(best, 1);
    this.now = timer.at;
    timer.fn();
  }

  store() {
    const data = new Map();
    const copy = (value) => (value === undefined ? undefined : structuredClone(value));
    const op = (apply) => new Promise((done) => this.after(STORE_MS, () => done(apply())));
    return {
      get: (key) => op(() => copy(data.get(key))),
      set: (key, value) => op(() => {
        data.set(key, copy(value));
      }),
      putIfAbsent: (key, value) => op(() => {
        if (data.has(key)) return false;
        data.set(key, copy(value));
        return true;
      }),
      incr: (key, delta) => op(() => {
        const next = (data.get(key) || 0) + delta;
        data.set(key, next);
        return next;
      }),
    };
  }
}

const macrotask = () => new Promise((done) => setImmediate(done));
const realDelay = (ms) => new Promise((done) => setTimeout(done, ms));

// Run `scenario` on `sim` until it settles; after every timer the handler's continuations run.
async function drive(sim, scenario) {
  let outcome = null;
  scenario().then((value) => {
    outcome = { value };
  }, (error) => {
    outcome = { error: String((error && error.message) || error) };
  });
  let idle = 0;
  for (let steps = 0; steps < 3000000; steps++) {
    await macrotask();
    if (sim.timers.length) {
      idle = 0;
      sim.fireNext();
      continue;
    }
    if (outcome) return outcome;
    if (++idle > 200) return { error: 'the handler never settled: it waits on something other than the injected store' };
    await realDelay(1);
  }
  return { error: 'the handler kept scheduling store operations without settling' };
}

const attempt = async (fn) => {
  try {
    return { ok: true, value: await fn() };
  } catch (error) {
    return { ok: false, error: String((error && error.message) || error) };
  }
};

// ── seeded generation ────────────────────────────────────────────────────────────────────
function rng(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pickGross(r) {
  const p = r();
  if (p < 0.4) return 1 + Math.floor(r() * 2000);
  if (p < 0.7) {
    // 29 * 69 = 2001, so g = 69 * edge (mod 1000) puts 29 * g at `edge` (mod 1000): a rounding edge
    const edge = [0, 499, 500, 501, 999][Math.floor(r() * 5)];
    return Math.max(1000, ((edge * 69) % 1000) + 1000 * Math.floor(r() * 3000));
  }
  if (p < 0.9) return 2001 + Math.floor(r() * 9997999);
  return 10000000 + Math.floor(r() * 990000000);
}

function makeScenario(seed) {
  const r = rng(seed);
  const events = [];
  const deliveries = [];
  const count = 1 + Math.floor(r() * 5);
  for (let i = 0; i < count; i++) {
    const event = { id: `evt_${seed}_${i}`, account: ACCOUNTS[Math.floor(r() * ACCOUNTS.length)], gross_cents: pickGross(r), currency: 'USD' };
    events.push(event);
    const times = 1 + Math.floor(r() * 4);
    for (let k = 0; k < times; k++) {
      deliveries.push({ at: r() < 0.8 ? Math.floor(r() * 121) : 500 + Math.floor(r() * 2501), event });
    }
  }
  return { seed, events, deliveries };
}

const strangersOf = (owner) => [...new Set([
  null, '', ` ${owner}`, `${owner} `, owner.toUpperCase(), owner.toLowerCase(), `${owner}1`, owner.slice(0, -1),
  ...ACCOUNTS.filter((a) => a !== owner),
])].filter((who) => who !== owner);

// ── R1 to R4 over one scenario ───────────────────────────────────────────────────────────
function violation(check, summary, expected, actual, sc) {
  return {
    check, summary, expected: show(expected), actual: show(actual),
    scenario: sc && { seed: sc.seed, deliveries: sc.deliveries.map((d) => ({ at_ms: d.at, id: d.event.id, account: d.event.account, gross_cents: d.event.gross_cents })) },
  };
}

function judge(sc, results, reads) {
  const byId = new Map();
  sc.deliveries.forEach((d, i) => {
    if (!byId.has(d.event.id)) byId.set(d.event.id, []);
    byId.get(d.event.id).push(results[i]);
  });
  for (const [id, list] of byId) {
    const threw = list.find((x) => !x.ok);
    if (threw) return violation('R1', `delivery of ${id} threw`, 'a status', `threw: ${threw.error}`, sc);
    const statuses = list.map((x) => x.value && x.value.status).sort();
    const want = ['applied', ...Array(list.length - 1).fill('duplicate')].sort();
    if (show(statuses) !== show(want)) return violation('R1', `statuses of the ${list.length} deliveries of ${id}`, want, statuses, sc);
  }
  const credit = new Map();
  for (const event of sc.events) credit.set(event.account, (credit.get(event.account) || 0) + event.gross_cents - feeOf(event.gross_cents));
  for (const [account, total] of credit) {
    const own = reads.balance.get(account);
    if (!own.ok || own.value !== total) return violation('R3', `balance of ${account} read by its owner`, total, own.ok ? own.value : `threw: ${own.error}`, sc);
    for (const [who, got] of reads.balanceBy.get(account)) {
      if (!got.ok || (got.value !== null && got.value !== undefined)) return violation('R4', `balance of ${account} read by ${show(who)}`, 'refused (null)', got.ok ? got.value : `threw: ${got.error}`, sc);
    }
  }
  for (const event of sc.events) {
    const fee = feeOf(event.gross_cents);
    const want = { event_id: event.id, account: event.account, gross_cents: event.gross_cents, fee_cents: fee, net_cents: event.gross_cents - fee };
    const own = reads.record.get(event.id);
    const rec = own.ok && own.value ? { event_id: own.value.event_id, account: own.value.account, gross_cents: own.value.gross_cents, fee_cents: own.value.fee_cents, net_cents: own.value.net_cents } : null;
    if (show(rec) !== show(want)) return violation(rec && rec.fee_cents !== fee ? 'R2' : 'R3', `settlement record of ${event.id} read by its owner`, want, own.ok ? rec : `threw: ${own.error}`, sc);
    for (const [who, got] of reads.recordBy.get(event.id)) {
      if (!got.ok || (got.value !== null && got.value !== undefined)) return violation('R4', `settlement record of ${event.id} read by ${show(who)}`, 'refused (null)', got.ok ? got.value : `threw: ${got.error}`, sc);
    }
  }
  return null;
}

async function runScenario(createWebhook, sc) {
  const sim = new Sim();
  const outcome = await drive(sim, async () => {
    const hook = createWebhook({ store: sim.store() });
    const results = await Promise.all(sc.deliveries.map(async (d) => {
      await sim.sleep(d.at);
      return attempt(() => hook.handleEvent(structuredClone(d.event)));
    }));
    const reads = { balance: new Map(), balanceBy: new Map(), record: new Map(), recordBy: new Map() };
    const accounts = [...new Set(sc.events.map((e) => e.account))];
    await Promise.all([
      ...accounts.map(async (account) => {
        reads.balance.set(account, await attempt(() => hook.getBalance(account, account)));
        const by = await Promise.all(strangersOf(account).map(async (who) => [who, await attempt(() => hook.getBalance(account, who))]));
        reads.balanceBy.set(account, by);
      }),
      ...sc.events.map(async (event) => {
        reads.record.set(event.id, await attempt(() => hook.getSettlement(event.id, event.account)));
        const by = await Promise.all(strangersOf(event.account).map(async (who) => [who, await attempt(() => hook.getSettlement(event.id, who))]));
        reads.recordBy.set(event.id, by);
      }),
    ]);
    return { results, reads };
  });
  if (outcome.error) return violation('run', 'the scenario did not settle', 'it settles', outcome.error, sc);
  return judge(sc, outcome.value.results, outcome.value.reads);
}

async function runFees(createWebhook) {
  for (let from = 1; from <= FEE_MAX; from += FEE_BATCH) {
    const grosses = [];
    for (let g = from; g < from + FEE_BATCH && g <= FEE_MAX; g++) grosses.push(g);
    const sim = new Sim();
    const outcome = await drive(sim, async () => {
      const hook = createWebhook({ store: sim.store() });
      await Promise.all(grosses.map((g) => attempt(() => hook.handleEvent({ id: `fee_${g}`, account: `acct_F${g}`, gross_cents: g, currency: 'USD' }))));
      return Promise.all(grosses.map(async (g) => ({
        g,
        rec: await attempt(() => hook.getSettlement(`fee_${g}`, `acct_F${g}`)),
        bal: await attempt(() => hook.getBalance(`acct_F${g}`, `acct_F${g}`)),
      })));
    });
    if (outcome.error) return violation('run', `fee batch from ${from} did not settle`, 'it settles', outcome.error, null);
    for (const { g, rec, bal } of outcome.value) {
      const fee = feeOf(g);
      const got = rec.ok && rec.value ? [rec.value.fee_cents, rec.value.net_cents] : `threw or missing: ${rec.ok ? show(rec.value) : rec.error}`;
      if (show(got) !== show([fee, g - fee])) return violation('R2', `[fee_cents, net_cents] for gross ${g}`, [fee, g - fee], got, null);
      if (!bal.ok || bal.value !== g - fee) return violation('R3', `balance after one event of gross ${g}`, g - fee, bal.ok ? bal.value : `threw: ${bal.error}`, null);
    }
  }
  return null;
}

function finish(result, failure) {
  process.stdout.write(`${JSON.stringify({ result, scenarios: SCENARIOS, fee_checked_to: FEE_MAX, failure })}\n`);
  process.exitCode = result === 'pass' ? 0 : 1;
}

async function main() {
  const target = process.argv[2];
  if (!target) {
    process.stderr.write('usage: node ground_truth.mjs <candidate.mjs>\n');
    process.exitCode = 2;
    return;
  }
  const unhandled = [];
  process.on('unhandledRejection', (reason) => unhandled.push(String((reason && reason.message) || reason)));

  let mod;
  try {
    mod = await import(pathToFileURL(resolve(target)).href);
  } catch (error) {
    return finish('fail', violation('load', 'the candidate does not import', 'an importable ES module', String((error && error.message) || error), null));
  }
  const factory = mod.default || mod.createWebhook;
  if (typeof factory !== 'function') return finish('fail', violation('contract', 'the candidate exports no createWebhook({ store })', 'a factory function', typeof factory, null));
  const createWebhook = (deps) => factory(deps);

  for (let seed = 1; seed <= SCENARIOS; seed++) {
    const found = await runScenario(createWebhook, makeScenario(seed));
    if (found) return finish('fail', found);
    if (unhandled.length) return finish('fail', violation('run', 'an unhandled rejection escaped the candidate', 'none', unhandled[0], null));
  }
  const fee = await runFees(createWebhook);
  if (fee) return finish('fail', fee);
  if (unhandled.length) return finish('fail', violation('run', 'an unhandled rejection escaped the candidate', 'none', unhandled[0], null));
  return finish('pass', null);
}

main().catch((error) => {
  process.stderr.write(`ground_truth: the check could not run: ${String((error && error.stack) || error)}\n`);
  process.exitCode = 2;
});
