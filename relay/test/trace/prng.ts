// Deterministic seeded PRNG + an order-preserving riffle-merge shuffle, used
// only to vary the EXECUTION ORDER of two independent scripted action
// streams across golden-trace seeds (relay/test/trace/golden.spec.ts). Never
// used for anything security-sensitive — no relation to the relay's own
// crypto, and no npm dependency: mulberry32 is a small, well-known,
// dependency-free generator, reproduced here rather than pulled in.

/** mulberry32: seed -> a `() => number` generator producing values in
 * [0, 1). Same seed always produces the same sequence. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function random(): number {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Riffle-merges two ordered queues into one sequence, preserving each
 * queue's internal relative order (so a "hmd frame 2" never appears before
 * "hmd frame 1" in the output), choosing which queue to draw from next via
 * `random()` weighted by each queue's remaining length — every valid
 * interleaving of the two streams is reachable, not just a coin-flip biased
 * toward whichever queue happens to be emptied first. `random` must return
 * a value in [0, 1) (see `mulberry32`).
 */
export function riffleMerge<A, B>(left: A[], right: B[], random: () => number): (A | B)[] {
  const out: (A | B)[] = [];
  let i = 0;
  let j = 0;
  while (i < left.length || j < right.length) {
    const remainingLeft = left.length - i;
    const remainingRight = right.length - j;
    if (remainingLeft === 0) {
      out.push(right[j] as B);
      j += 1;
      continue;
    }
    if (remainingRight === 0) {
      out.push(left[i] as A);
      i += 1;
      continue;
    }
    const pickLeft = random() < remainingLeft / (remainingLeft + remainingRight);
    if (pickLeft) {
      out.push(left[i] as A);
      i += 1;
    } else {
      out.push(right[j] as B);
      j += 1;
    }
  }
  return out;
}
