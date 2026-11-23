'use strict';
// Hidden acceptance test for 07-event-emitter-reentrancy. Loads emitter.js from the cwd.
const assert = require('node:assert');
const path = require('node:path');

const mod = require(path.join(process.cwd(), 'emitter.js'));
const Emitter = mod.Emitter || mod;

const cases = [];
const t = (name, fn) => cases.push([name, fn]);
const isUnhandled = (thrown) => thrown instanceof Error && thrown.message === 'Unhandled error';

t('listeners run in registration order across on and once, this is the emitter', () => {
  const e = new Emitter();
  const log = [];
  const seenThis = [];
  e.on('x', function () { log.push('a'); seenThis.push(this); });
  e.once('x', function () { log.push('b'); seenThis.push(this); });
  e.on('x', function () { log.push('c'); seenThis.push(this); });
  assert.strictEqual(e.emit('x'), true);
  assert.deepStrictEqual(log, ['a', 'b', 'c']);
  assert.strictEqual(e.emit('x'), true);
  assert.deepStrictEqual(log, ['a', 'b', 'c', 'a', 'c']);
  assert.ok(seenThis.length === 5 && seenThis.every((v) => v === e));
});

t('arguments are passed through unchanged to on and once listeners', () => {
  const e = new Emitter();
  const got = [];
  const obj = {};
  e.on('x', (...args) => got.push(args));
  e.once('x', (...args) => got.push(args));
  e.emit('x', 1, 'two', obj, undefined);
  assert.strictEqual(got.length, 2);
  assert.strictEqual(got[0].length, 4);
  assert.strictEqual(got[0][2], obj);
  assert.deepStrictEqual(got[1], got[0]);
});

t('emit returns false without listeners and after the last one is gone', () => {
  const e = new Emitter();
  assert.strictEqual(e.emit('x'), false);
  const f = () => {};
  e.on('x', f);
  e.off('x', f);
  assert.strictEqual(e.emit('x'), false);
  e.once('y', f);
  assert.strictEqual(e.emit('y'), true);
  assert.strictEqual(e.emit('y'), false);
});

t('on, once and off return the emitter, unknown listeners are ignored', () => {
  const e = new Emitter();
  const f = () => {};
  assert.strictEqual(e.on('x', f), e);
  assert.strictEqual(e.once('x', f), e);
  assert.strictEqual(e.off('x', f), e);
  assert.strictEqual(e.off('never', f), e);
  assert.strictEqual(e.off('x', () => {}), e);
  assert.strictEqual(e.listenerCount('x'), 1);
});

t('events and emitter instances are independent', () => {
  const e1 = new Emitter();
  const e2 = new Emitter();
  const log = [];
  e1.on('a', () => log.push('e1a'));
  e1.on('b', () => log.push('e1b'));
  e2.on('a', () => log.push('e2a'));
  e1.emit('a');
  assert.deepStrictEqual(log, ['e1a']);
  assert.strictEqual(e1.listenerCount('a'), 1);
  assert.strictEqual(e2.listenerCount('b'), 0);
  assert.strictEqual(e1.listenerCount('never'), 0);
});

t('once runs once and is unregistered before its callback runs', () => {
  const e = new Emitter();
  const counts = [];
  let calls = 0;
  e.once('x', () => { calls += 1; counts.push(e.listenerCount('x')); });
  assert.strictEqual(e.listenerCount('x'), 1);
  e.emit('x');
  e.emit('x');
  assert.strictEqual(calls, 1);
  assert.deepStrictEqual(counts, [0]);
  assert.strictEqual(e.listenerCount('x'), 0);
});

t('a once listener that re-emits its own event runs exactly once', () => {
  const e = new Emitter();
  let calls = 0;
  e.once('x', () => { calls += 1; e.emit('x'); });
  e.emit('x');
  assert.strictEqual(calls, 1);
});

t('an earlier listener re-entering emit runs a later once listener once in total', () => {
  const e = new Emitter();
  const log = [];
  let reentered = false;
  e.on('x', () => {
    log.push('a');
    if (!reentered) {
      reentered = true;
      e.emit('x');
    }
  });
  e.once('x', () => log.push('b'));
  e.on('x', () => log.push('c'));
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'a', 'b', 'c', 'c']);
  assert.strictEqual(e.listenerCount('x'), 2);
});

t('a nested emit returns false when the outer emit already consumed the only listener', () => {
  const e = new Emitter();
  let nested;
  e.once('x', () => { nested = e.emit('x'); });
  assert.strictEqual(e.emit('x'), true);
  assert.strictEqual(nested, false);
});

t('several once listeners all run in a single emit', () => {
  const e = new Emitter();
  const log = [];
  for (let i = 0; i < 5; i += 1) {
    e.once('x', () => log.push(i));
  }
  assert.strictEqual(e.emit('x'), true);
  assert.deepStrictEqual(log, [0, 1, 2, 3, 4]);
  assert.strictEqual(e.listenerCount('x'), 0);
  assert.strictEqual(e.emit('x'), false);
});

t('a once listener can re-arm itself for the next emit only', () => {
  const e = new Emitter();
  let n = 0;
  function f() {
    n += 1;
    if (n < 3) e.once('x', f);
  }
  e.once('x', f);
  e.emit('x');
  assert.strictEqual(n, 1);
  e.emit('x');
  assert.strictEqual(n, 2);
  e.emit('x');
  assert.strictEqual(n, 3);
  assert.strictEqual(e.emit('x'), false);
  assert.strictEqual(n, 3);
});

t('a throwing once listener is still consumed and its error propagates', () => {
  const e = new Emitter();
  const boom = new Error('boom');
  let calls = 0;
  e.once('x', () => { calls += 1; throw boom; });
  assert.throws(() => e.emit('x'), (thrown) => thrown === boom);
  assert.strictEqual(e.listenerCount('x'), 0);
  assert.strictEqual(e.emit('x'), false);
  assert.strictEqual(calls, 1);
});

t('listeners added during an emit do not run in that emit', () => {
  const e = new Emitter();
  const log = [];
  let added = false;
  e.on('x', () => {
    log.push('a');
    if (!added) {
      added = true;
      e.on('x', () => log.push('late-on'));
      e.once('x', () => log.push('late-once'));
    }
  });
  e.on('x', () => log.push('b'));
  assert.strictEqual(e.emit('x'), true);
  assert.deepStrictEqual(log, ['a', 'b']);
  assert.strictEqual(e.listenerCount('x'), 4);
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'b', 'a', 'b', 'late-on', 'late-once']);
  assert.strictEqual(e.listenerCount('x'), 3);
});

t('removing a listener during an emit does not skip the next listener', () => {
  const e = new Emitter();
  const log = [];
  const a = () => { log.push('a'); e.off('x', a); };
  e.on('x', a);
  e.on('x', () => log.push('b'));
  e.on('x', () => log.push('c'));
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'b', 'c']);
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'b', 'c', 'b', 'c']);
});

t('a listener removed during an emit still runs in that emit but not in later ones', () => {
  const e = new Emitter();
  const log = [];
  const c = () => log.push('c');
  const d = () => log.push('d');
  e.on('x', () => { log.push('a'); e.off('x', c); e.off('x', d); });
  e.on('x', () => log.push('b'));
  e.on('x', c);
  e.once('x', d);
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'b', 'c', 'd']);
  e.emit('x');
  assert.deepStrictEqual(log, ['a', 'b', 'c', 'd', 'a', 'b']);
  assert.strictEqual(e.listenerCount('x'), 2);
});

t('off removes a once listener registered with the same function', () => {
  const e = new Emitter();
  let calls = 0;
  const f = () => { calls += 1; };
  e.once('x', f);
  e.off('x', f);
  assert.strictEqual(e.listenerCount('x'), 0);
  assert.strictEqual(e.emit('x'), false);
  assert.strictEqual(calls, 0);
});

t('off removes the most recent registration even when on and once are mixed', () => {
  const e1 = new Emitter();
  let calls1 = 0;
  const f = () => { calls1 += 1; };
  e1.on('x', f);
  e1.once('x', f);
  e1.off('x', f);
  e1.emit('x');
  e1.emit('x');
  assert.strictEqual(calls1, 2);
  const e2 = new Emitter();
  let calls2 = 0;
  const g = () => { calls2 += 1; };
  e2.once('x', g);
  e2.on('x', g);
  e2.off('x', g);
  e2.emit('x');
  e2.emit('x');
  assert.strictEqual(calls2, 1);
});

t('the same function registered twice runs twice, off removes only the latest registration', () => {
  const e = new Emitter();
  const log = [];
  const f = () => log.push('f');
  const g = () => log.push('g');
  e.on('x', f);
  e.on('x', g);
  e.on('x', f);
  e.emit('x');
  assert.deepStrictEqual(log, ['f', 'g', 'f']);
  e.off('x', f);
  assert.strictEqual(e.listenerCount('x'), 2);
  log.length = 0;
  e.emit('x');
  assert.deepStrictEqual(log, ['f', 'g']);
  e.off('x', f);
  log.length = 0;
  e.emit('x');
  assert.deepStrictEqual(log, ['g']);
  e.off('x', f);
  assert.strictEqual(e.listenerCount('x'), 1);
});

t('emit error without a listener throws the Error it was given', () => {
  const e = new Emitter();
  const err = new Error('boom');
  assert.throws(() => e.emit('error', err), (thrown) => thrown === err);
  const typed = new TypeError('typed');
  assert.throws(() => e.emit('error', typed), (thrown) => thrown === typed);
});

t('emit error without a listener and without an Error throws Error("Unhandled error")', () => {
  const e = new Emitter();
  for (const value of ['boom', 42, null, undefined, { message: 'x' }, ['a']]) {
    assert.throws(() => e.emit('error', value), isUnhandled);
  }
  assert.throws(() => e.emit('error'), isUnhandled);
});

t('error with a listener is delivered, and throws again once the listeners are gone', () => {
  const e = new Emitter();
  const got = [];
  const listener = (value) => got.push(value);
  const err = new Error('first');
  e.on('error', listener);
  assert.strictEqual(e.emit('error', err), true);
  assert.deepStrictEqual(got, [err]);
  e.off('error', listener);
  assert.throws(() => e.emit('error', err), (thrown) => thrown === err);
  e.once('error', listener);
  assert.strictEqual(e.emit('error', 'text'), true);
  assert.deepStrictEqual(got, [err, 'text']);
  assert.throws(() => e.emit('error', err), (thrown) => thrown === err);
});

t('other events without listeners never throw', () => {
  const e = new Emitter();
  assert.doesNotThrow(() => e.emit('warning', new Error('w')));
  assert.strictEqual(e.emit('warning', new Error('w')), false);
});

let failed = 0;
for (const [name, fn] of cases) {
  try {
    fn();
    console.log(`ok   ${name}`);
  } catch (err) {
    failed += 1;
    const detail = String(err && err.message).split('\n')[0];
    console.log(`FAIL ${name}\n     ${detail}`);
  }
}
console.log(`${cases.length - failed}/${cases.length} passed`);
process.exit(failed === 0 ? 0 : 1);
