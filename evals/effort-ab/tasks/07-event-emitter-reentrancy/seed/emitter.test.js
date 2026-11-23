'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { Emitter } = require('./emitter');

test('listeners run in registration order and receive the arguments', () => {
  const emitter = new Emitter();
  const calls = [];
  emitter.on('data', (a, b) => calls.push(['first', a, b]));
  emitter.on('data', (a, b) => calls.push(['second', a, b]));
  emitter.emit('data', 1, 2);
  assert.deepStrictEqual(calls, [['first', 1, 2], ['second', 1, 2]]);
});

test('emit returns true only when a listener ran', () => {
  const emitter = new Emitter();
  assert.strictEqual(emitter.emit('data'), false);
  emitter.on('data', () => {});
  assert.strictEqual(emitter.emit('data'), true);
  assert.strictEqual(emitter.emit('other'), false);
});

test('once listeners run a single time', () => {
  const emitter = new Emitter();
  let count = 0;
  emitter.once('ready', () => { count += 1; });
  emitter.emit('ready');
  emitter.emit('ready');
  assert.strictEqual(count, 1);
  assert.strictEqual(emitter.listenerCount('ready'), 0);
});

test('off removes an on listener', () => {
  const emitter = new Emitter();
  let count = 0;
  const listener = () => { count += 1; };
  emitter.on('tick', listener);
  emitter.emit('tick');
  emitter.off('tick', listener);
  emitter.emit('tick');
  assert.strictEqual(count, 1);
  assert.strictEqual(emitter.listenerCount('tick'), 0);
});

test('off removes a listener that was registered with once', () => {
  const emitter = new Emitter();
  let count = 0;
  const listener = () => { count += 1; };
  emitter.once('tick', listener);
  emitter.off('tick', listener);
  assert.strictEqual(emitter.listenerCount('tick'), 0);
  emitter.emit('tick');
  assert.strictEqual(count, 0);
});

test('listenerCount counts on and once registrations per event', () => {
  const emitter = new Emitter();
  emitter.on('a', () => {});
  emitter.once('a', () => {});
  emitter.on('b', () => {});
  assert.strictEqual(emitter.listenerCount('a'), 2);
  assert.strictEqual(emitter.listenerCount('b'), 1);
  assert.strictEqual(emitter.listenerCount('c'), 0);
});
