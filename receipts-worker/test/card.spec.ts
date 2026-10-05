// The PNG card, checked structurally (signature, chunk CRCs, header, inflated size) and by pixels,
// plus the bitmap font table it draws with.
import { describe, expect, it } from "vitest";
import { CARD_HEIGHT, CARD_WIDTH, COLOURS, crc32, renderCard } from "../src/card";
import { checkTable, GLYPH_KEYS, glyph } from "../src/font";
import type { JsonObject } from "../src/types";
import { receiptBody } from "./helpers";

async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function chunksOf(png: Uint8Array): { type: string; data: Uint8Array; crc: number }[] {
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  const out = [];
  for (let at = 8; at < png.length; ) {
    const length = view.getUint32(at);
    out.push({
      type: String.fromCharCode(...png.slice(at + 4, at + 8)),
      data: png.slice(at + 8, at + 8 + length),
      crc: view.getUint32(at + 8 + length),
    });
    at += 12 + length;
  }
  return out;
}

async function pixelsOf(doc: JsonObject): Promise<{ png: Uint8Array; pixels: Uint8Array }> {
  const png = await renderCard(doc, "runhmd.dev/r/test");
  const idat = chunksOf(png).find((c) => c.type === "IDAT") as { data: Uint8Array };
  const scanlines = await inflate(idat.data);
  const pixels = new Uint8Array(CARD_WIDTH * CARD_HEIGHT);
  for (let row = 0; row < CARD_HEIGHT; row++) pixels.set(scanlines.subarray(row * (CARD_WIDTH + 1) + 1, (row + 1) * (CARD_WIDTH + 1)), row * CARD_WIDTH);
  return { png, pixels };
}

const countIn = (pixels: Uint8Array, colour: number, x0: number, y0: number, x1: number, y1: number): number => {
  let n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) if (pixels[y * CARD_WIDTH + x] === colour) n++;
  return n;
};

describe("renderCard", () => {
  it("writes a valid 8-bit palette PNG of 1200x630 with correct chunk CRCs", async () => {
    const { png, pixels } = await pixelsOf(receiptBody());
    expect(Array.from(png.slice(0, 8))).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const chunks = chunksOf(png);
    expect(chunks.map((c) => c.type)).toEqual(["IHDR", "PLTE", "IDAT", "IEND"]);
    for (const c of chunks) {
      const typed = new Uint8Array([...Array.from(c.type, (ch) => ch.charCodeAt(0)), ...c.data]);
      expect(crc32(typed), c.type).toBe(c.crc);
    }
    const header = new DataView(chunks[0]?.data.buffer as ArrayBuffer, chunks[0]?.data.byteOffset);
    expect([header.getUint32(0), header.getUint32(4), chunks[0]?.data[8], chunks[0]?.data[9]]).toEqual([1200, 630, 8, 3]);
    expect(pixels.length).toBe(CARD_WIDTH * CARD_HEIGHT);
  });

  it("is deterministic: one receipt, one byte string", async () => {
    const body = receiptBody();
    const a = (await pixelsOf(body)).png;
    const b = (await pixelsOf(body)).png;
    expect(a).toEqual(b);
  });

  it("paints the verdict word red for DENIED and green for PROVEN", async () => {
    const denied = (await pixelsOf(receiptBody())).pixels;
    const proven = (await pixelsOf(receiptBody({ verdict: "PROVEN", findings: [], attacks: { total: 24, survived: 24, killed: 0 } }))).pixels;
    const region = [64, 130, 64 + 6 * 96, 130 + 112] as const;
    expect(countIn(denied, COLOURS.BAD, ...region)).toBeGreaterThan(500);
    expect(countIn(denied, COLOURS.GOOD, ...region)).toBe(0);
    expect(countIn(proven, COLOURS.GOOD, ...region)).toBeGreaterThan(500);
    expect(countIn(proven, COLOURS.BAD, ...region)).toBe(0);
  });

  it("draws findings, and never overruns the canvas for long or unusual titles", async () => {
    const many = Array.from({ length: 7 }, (_, i) => ({
      id: `f-000${i + 1}`, title: "very long title é✓\u{1F6E1} ".repeat(20).slice(0, 200), severity: ["high", "medium", "low", "info"][i % 4], category: "logic", digest: `sha256:${"a".repeat(64)}`,
    }));
    const { pixels } = await pixelsOf(receiptBody({ findings: many, attacks: { total: 24, survived: 21, killed: 3 } }));
    expect(countIn(pixels, COLOURS.TEXT, 64, 330, CARD_WIDTH - 64, 500)).toBeGreaterThan(300);
    expect(countIn(pixels, COLOURS.TEXT, CARD_WIDTH - 60, 0, CARD_WIDTH, CARD_HEIGHT)).toBe(0);
  });
});

describe("bitmap font", () => {
  it("decodes every glyph in the table", () => {
    expect(checkTable()).toBe(GLYPH_KEYS.length);
    expect(GLYPH_KEYS.length).toBeGreaterThanOrEqual(60);
  });

  it("folds lower case up, strips accents, and draws '?' for what it lacks", () => {
    expect(glyph("a")).toEqual(glyph("A"));
    expect(glyph("é")).toEqual(glyph("E"));
    expect(glyph("\u{1F6E1}")).toEqual(glyph("?"));
    expect(glyph("日")).toEqual(glyph("?"));
    expect(glyph("A")).not.toEqual(glyph("B"));
  });
});
