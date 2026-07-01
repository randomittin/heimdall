// UNDER-DELIVERY MUTANT (a) — the HARD PART was skipped.
//
// Models the ladder failure the user fears: an agent reads rung 1 ("does this
// need to exist?") as license to skip the hard sub-capability. Here the
// subtractive-notation branch (IV, IX, XL, XC, CD, CM) was never built — only
// the additive symbols are delivered. It LOOKS done and returns non-empty
// output for every input, but 4 -> "IIII", 9 -> "VIIII", 14 -> "XIIII": the
// hard part is hollow. The acceptance oracle catches it at the first
// subtractive case (roman(4)). This mutant MUST be REJECTED by the gate.
const MAP = [
  [1000, 'M'], [500, 'D'], [100, 'C'], [50, 'L'], [10, 'X'], [5, 'V'], [1, 'I'],
];

export default function roman(n) {
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
