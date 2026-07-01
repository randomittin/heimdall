// UNDER-DELIVERY MUTANT (c) — small-but-broken (terse diff that fails acceptance).
//
// Models the exact trap the spec warns about: "Ponytail can make the diff
// smaller; it can NEVER make a failing acceptance pass by being terse." This is
// the smallest, cleverest-looking one-liner reduce — full subtractive map, full
// range — but it carries an off-by-one: `n > value` where it must be
// `n >= value`. So the exact-match boundaries collapse: roman(1) -> "",
// roman(4) -> "", roman(1000) -> "". Terse is not done; small-but-broken FAILS.
// The acceptance oracle catches it at roman(1). This mutant MUST be REJECTED.
export default function roman(n) {
  const m = [
    [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'], [100, 'C'], [90, 'XC'],
    [50, 'L'], [40, 'XL'], [10, 'X'], [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I'],
  ];
  return m.reduce((o, [v, s]) => {
    while (n > v) { o += s; n -= v; }
    return o;
  }, '');
}
