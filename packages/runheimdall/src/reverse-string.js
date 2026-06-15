'use strict';

/**
 * Reverse a string.
 *
 * Iterates Unicode code points (not UTF-16 code units) so characters outside
 * the Basic Multilingual Plane — emoji, many CJK extensions — survive the
 * reversal intact instead of splitting into broken surrogate halves.
 *
 * @param {string} input - the string to reverse
 * @returns {string} the input reversed
 * @throws {TypeError} if input is not a string
 */
function reverseString(input) {
  if (typeof input !== 'string') {
    throw new TypeError(`reverseString expects a string, got ${typeof input}`);
  }
  return Array.from(input).reverse().join('');
}

module.exports = { reverseString };
