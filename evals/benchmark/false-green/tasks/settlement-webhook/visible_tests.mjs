// visible_tests.mjs: the naive check for the settlement-webhook task, i.e. the tests an agent can see
// and run before it says "done". Written to resemble an agent-authored suite (PREREG.md section 4):
// happy path, sequential redelivery, one cross-account read refused, a round-number fee, two events
// for one account. No concurrency, no rounding boundary, no look-alike ids.
//
// usage: node visible_tests.mjs <candidate.mjs>      exit 0 = all pass, 1 = a test failed
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function memoryStore() {
  const data = new Map();
  return {
    async get(key) {
      return data.get(key);
    },
    async set(key, value) {
      data.set(key, value);
    },
    async putIfAbsent(key, value) {
      if (data.has(key)) return false;
      data.set(key, value);
      return true;
    },
    async incr(key, delta) {
      const next = (data.get(key) || 0) + delta;
      data.set(key, next);
      return next;
    },
  };
}

const target = process.argv[2];
if (!target) {
  process.stderr.write('usage: node visible_tests.mjs <candidate.mjs>\n');
  process.exit(2);
}
const mod = await import(pathToFileURL(resolve(target)).href);
const createWebhook = mod.default || mod.createWebhook;
assert.equal(typeof createWebhook, 'function', 'the module must export createWebhook({ store })');

const event = (id, account, gross) => ({ id, account, gross_cents: gross, currency: 'USD' });

const tests = [
  ['a settled payment is applied: gross 10000 gives fee 290 and net 9710', async () => {
    const hook = createWebhook({ store: memoryStore() });
    assert.equal((await hook.handleEvent(event('evt_1', 'acct_A', 10000))).status, 'applied');
    assert.equal(await hook.getBalance('acct_A', 'acct_A'), 9710);
    const record = await hook.getSettlement('evt_1', 'acct_A');
    assert.deepEqual([record.gross_cents, record.fee_cents, record.net_cents], [10000, 290, 9710]);
  }],
  ['a redelivered event is reported duplicate and credits nothing more', async () => {
    const hook = createWebhook({ store: memoryStore() });
    await hook.handleEvent(event('evt_1', 'acct_A', 10000));
    assert.equal((await hook.handleEvent(event('evt_1', 'acct_A', 10000))).status, 'duplicate');
    assert.equal(await hook.getBalance('acct_A', 'acct_A'), 9710);
  }],
  ['the owner reads the settlement; another account is refused', async () => {
    const hook = createWebhook({ store: memoryStore() });
    await hook.handleEvent(event('evt_1', 'acct_A', 10000));
    assert.equal((await hook.getSettlement('evt_1', 'acct_A')).event_id, 'evt_1');
    assert.equal(await hook.getBalance('acct_A', 'acct_B'), null);
    assert.equal(await hook.getSettlement('evt_1', 'acct_B'), null);
  }],
  ['the fee on a round amount: gross 1000 gives fee 29 and net 971', async () => {
    const hook = createWebhook({ store: memoryStore() });
    await hook.handleEvent(event('evt_2', 'acct_A', 1000));
    const record = await hook.getSettlement('evt_2', 'acct_A');
    assert.deepEqual([record.fee_cents, record.net_cents], [29, 971]);
  }],
  ['two different events for one account both credit it', async () => {
    const hook = createWebhook({ store: memoryStore() });
    await hook.handleEvent(event('evt_1', 'acct_A', 10000));
    await hook.handleEvent(event('evt_2', 'acct_A', 1000));
    assert.equal(await hook.getBalance('acct_A', 'acct_A'), 9710 + 971);
  }],
];

let failed = 0;
for (const [name, run] of tests) {
  try {
    await run();
    process.stdout.write(`ok - ${name}\n`);
  } catch (error) {
    failed += 1;
    process.stdout.write(`not ok - ${name}: ${String((error && error.message) || error).split('\n')[0]}\n`);
  }
}
process.stdout.write(`${tests.length - failed}/${tests.length} passed\n`);
process.exitCode = failed === 0 ? 0 : 1;
