'use strict';

/**
 * Reverse a string.
 *
 * Uses Array.from so multi-byte characters (e.g. emoji, surrogate pairs)
 * are treated as single code points rather than split into broken halves.
 *
 * @param {string} input - the string to reverse
 * @returns {string} the reversed string
 * @throws {TypeError} if input is not a string
 */
function reverseString(input) {
  if (typeof input !== 'string') {
    throw new TypeError(`reverseString expects a string, got ${typeof input}`);
  }
  return Array.from(input).reverse().join('');
}

module.exports = { reverseString };
