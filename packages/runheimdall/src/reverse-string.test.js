'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { reverseString } = require('./reverse-string.js');

test('reverses a simple ascii string', () => {
  assert.equal(reverseString('hello'), 'olleh');
});

test('reverses an empty string to empty', () => {
  assert.equal(reverseString(''), '');
});

test('single character is unchanged', () => {
  assert.equal(reverseString('a'), 'a');
});

test('reverses a palindrome to itself', () => {
  assert.equal(reverseString('racecar'), 'racecar');
});

test('preserves spaces and punctuation', () => {
  assert.equal(reverseString('a b!c'), 'c!b a');
});

test('reverses multi-byte emoji without splitting surrogate pairs', () => {
  assert.equal(reverseString('ab😀cd'), 'dc😀ba');
});

test('throws TypeError on non-string input', () => {
  assert.throws(() => reverseString(42), TypeError);
  assert.throws(() => reverseString(null), TypeError);
  assert.throws(() => reverseString(undefined), TypeError);
});
