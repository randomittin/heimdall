// UNDER-DELIVERY MUTANT (b) — a required ACCEPTANCE CRITERION was silently dropped.
//
// Models "YAGNI'd away the scope": the agent decided nobody really needs
// four-digit numbers and quietly narrowed the required 1..3999 range to 1..999.
// The subtractive notation is fully and correctly implemented for the range it
// kept, so the diff is small and the code reads as clean — but the thousands
// requirement (M) is gone. roman(1000) -> "" instead of "M". YAGNI cut SCOPE,
// not gold-plating. The acceptance oracle catches it at roman(1000). This
// mutant MUST be REJECTED by the gate.
const MAP = [
  [900, 'CM'], [500, 'D'], [400, 'CD'], [100, 'C'],
  [90, 'XC'], [50, 'L'], [40, 'XL'], [10, 'X'],
  [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I'],
];

export default function roman(n) {
  if (n >= 1000) {
    return '';
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
