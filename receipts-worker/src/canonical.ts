// The canonical JSON form a runhmd.receipt/1 signature covers. A port of `canonical()` in
// bin/lib/runhmd_receipt.py: the two MUST write the same bytes for every value, and
// contract/vectors.json (replayed by test/vectors.spec.ts here and by
// test/receipts-worker-contract.test.sh against the Python) is what holds them to it.
//
// UTF-8, no insignificant whitespace, object members sorted by UTF-16 code unit, minimal string
// escapes, integral numbers without a fraction, other numbers as the shortest round-trip decimal
// and never an exponent. A value with no unambiguous spelling is REFUSED (CanonicalError), exactly
// where the Python refuses it: NaN/infinity, an integer a JavaScript reader would misread
// (>= 2**53), a number Python would spell with an exponent (a fraction below 1e-4), a lone
// surrogate (not encodable as UTF-8).

export class CanonicalError extends Error {}

const MAX_SAFE_INT = 2 ** 53;
const SMALLEST_PLAIN_FRACTION = 1e-4; // below this Python's repr() switches to exponent form

function canonNumber(value: number): string {
  if (!Number.isFinite(value)) throw new CanonicalError("NaN and infinity have no canonical form");
  if (Number.isInteger(value)) {
    if (Math.abs(value) >= MAX_SAFE_INT) {
      throw new CanonicalError(`number ${value} is outside the interoperable range`);
    }
    return String(value); // String(-0) is "0": 1.0 -> 1, -0.0 -> 0, 134.0 -> 134
  }
  const text = String(value);
  if (Math.abs(value) < SMALLEST_PLAIN_FRACTION || /e/i.test(text)) {
    throw new CanonicalError(`number ${value} needs an exponent; the canonical form never uses one`);
  }
  return text;
}

function canonString(value: string): string {
  if (!value.isWellFormed()) throw new CanonicalError("a lone surrogate is not encodable as UTF-8");
  return JSON.stringify(value); // the minimal RFC 8259 escapes: " \ and C0 controls, nothing else
}

export function canonical(value: unknown): string {
  if (value === null) return "null";
  if (value === true) return "true";
  if (value === false) return "false";
  if (typeof value === "string") return canonString(value);
  if (typeof value === "number") return canonNumber(value);
  if (Array.isArray(value)) return `[${value.map((item) => canonical(item)).join(",")}]`;
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    const members = Object.keys(record).sort(); // default sort: UTF-16 code unit order
    return `{${members.map((key) => `${canonString(key)}:${canonical(record[key])}`).join(",")}}`;
  }
  throw new CanonicalError(`cannot canonicalise a ${typeof value}`);
}

export function canonicalBytes(value: unknown): Uint8Array {
  return new TextEncoder().encode(canonical(value));
}
