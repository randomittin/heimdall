// GOLDEN candidate — the fully-delivered roman(n) feature.
//
// This is what "lazy but complete" looks like: it is TERSE (one greedy loop, no
// scaffolding, no wrapper classes, no dependency) yet it delivers the WHOLE
// feature — subtractive notation and the full 1..3999 range are both present.
// Minimalism cut the gold-plating, never the requirements. It PASSES every case
// in fixtures/golden/acceptance.json.
const MAP = [
  [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'],
  [100, 'C'], [90, 'XC'], [50, 'L'], [40, 'XL'],
  [10, 'X'], [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I'],
];

export default function roman(n) {
  if (!Number.isInteger(n) || n < 1 || n > 3999) {
    throw new RangeError(`roman(n): n must be an integer in 1..3999, got ${n}`);
  }
  let out = '';
  let r = n;
  for (const [value, symbol] of MAP) {
    while (r >= value) {
      out += symbol;
      r -= value;
    }
  }
  return out;
}
