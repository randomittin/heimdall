// The JavaScript half of the cross-language contract: contract/vectors.json is written from the
// Python reference (scripts/gen-vectors.py) and replayed here and, against the Python again, by
// test/receipts-worker-contract.test.sh. Canonical bytes must be identical, and every receipt
// must come out with the same outcome (ok, or the same ReceiptError kind).
import { describe, expect, it } from "vitest";
import vectorsJson from "../contract/vectors.json";
import { canonical, CanonicalError } from "../src/canonical";
import { MAX_RECEIPT_BYTES, parseTrust, ReceiptError, verifyReceipt } from "../src/receipt";

interface Vectors {
  max_receipt_bytes: number;
  anchors: string[];
  canonical: { name: string; json: string; canonical: string | null; hex: string | null }[];
  receipts: { name: string; raw_b64: string; outcome: string; pad_to?: number }[];
}
const vectors = vectorsJson as Vectors;

const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function rawOf(vector: Vectors["receipts"][number]): Uint8Array {
  const bytes = Uint8Array.from(atob(vector.raw_b64), (c) => c.charCodeAt(0));
  if (!vector.pad_to) return bytes;
  const padded = new Uint8Array(vector.pad_to).fill(0x20);
  padded.set(bytes);
  return padded;
}

describe("cross-language vectors", () => {
  it("share the size limit with the Python reference", () => {
    expect(vectors.max_receipt_bytes).toBe(MAX_RECEIPT_BYTES);
  });

  it("cover every outcome and a meaningful number of cases", () => {
    expect(vectors.canonical.length).toBeGreaterThanOrEqual(100);
    expect(vectors.receipts.length).toBeGreaterThanOrEqual(60);
    expect(new Set(vectors.receipts.map((r) => r.outcome))).toEqual(new Set(["ok", "not_json", "schema", "not_canonical", "unknown_key", "bad_signature"]));
    expect(vectors.canonical.some((c) => c.canonical === null)).toBe(true);
    expect(vectors.canonical.some((c) => c.canonical !== null)).toBe(true);
  });

  describe("canonical form: the same bytes, or the same refusal", () => {
    for (const vector of vectors.canonical) {
      it(vector.name, () => {
        let written: string | null;
        try {
          written = canonical(JSON.parse(vector.json));
        } catch (error) {
          if (!(error instanceof CanonicalError)) throw error;
          written = null;
        }
        expect(written).toBe(vector.canonical);
        if (written !== null) expect(hex(new TextEncoder().encode(written))).toBe(vector.hex);
      });
    }
  });

  describe("receipt verification: the same outcome", () => {
    for (const vector of vectors.receipts) {
      it(`${vector.name} -> ${vector.outcome}`, async () => {
        const trust = await parseTrust(vectors.anchors.join("\n"));
        let outcome = "ok";
        try {
          await verifyReceipt(rawOf(vector), trust);
        } catch (error) {
          if (!(error instanceof ReceiptError)) throw error;
          outcome = error.kind;
        }
        expect(outcome).toBe(vector.outcome);
      });
    }
  });
});
