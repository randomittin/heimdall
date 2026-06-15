'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { reverseString } = require('./reverse');

test('reverses a basic string', () => {
  assert.equal(reverseString('hello'), 'olleh');
});

test('reverses a single character', () => {
  assert.equal(reverseString('a'), 'a');
});

test('returns empty string for empty input', () => {
  assert.equal(reverseString(''), '');
});

test('is its own inverse', () => {
  const s = 'heimdall';
  assert.equal(reverseString(reverseString(s)), s);
});

test('handles whitespace and punctuation', () => {
  assert.equal(reverseString('ab c!'), '!c ba');
});

test('handles multi-byte characters without splitting surrogate pairs', () => {
  assert.equal(reverseString('a😀b'), 'b😀a');
});

test('throws TypeError on non-string input', () => {
  assert.throws(() => reverseString(42), TypeError);
  assert.throws(() => reverseString(null), TypeError);
  assert.throws(() => reverseString(undefined), TypeError);
});
