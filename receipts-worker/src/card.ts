// GET /r/<id>/card.png: the 1200x630 social card (the Open Graph image). Built from nothing but
// the VERIFIED receipt's own fields -- verdict, attack counts, finding id/severity/title, cost,
// duration, tool version -- so it commits to no more than the receipt does (no counterexample, no
// path: the receipt has none). A PNG is plain bytes, so there is nothing to escape; text is drawn
// from the bitmap font (src/font.ts), which folds unknown characters to "?".
//
// No dependency: an 8-bit palette image, one filter byte per row, zlib through the platform's
// CompressionStream, and a table CRC. The result is deterministic: one receipt, one byte string.

import { GLYPH_H, GLYPH_W, glyph } from "./font";
import type { JsonObject } from "./types";

export const CARD_WIDTH = 1200;
export const CARD_HEIGHT = 630;

const BACKGROUND = 0;
const EDGE = 1;
const TEXT = 2;
const MUTED = 3;
const GOOD = 4;
const BAD = 5;
const WARN = 6;
const PALETTE = Uint8Array.from([
  0x0b, 0x0f, 0x14, // background
  0x2a, 0x33, 0x40, // edge
  0xe6, 0xed, 0xf3, // text
  0x8b, 0x98, 0xa5, // muted
  0x3f, 0xb9, 0x50, // proven
  0xf8, 0x51, 0x49, // denied / high
  0xd2, 0x99, 0x22, // medium
]);
export const COLOURS = { BACKGROUND, EDGE, TEXT, MUTED, GOOD, BAD, WARN } as const;

const ADVANCE = GLYPH_W + 1;

function textWidth(text: string, scale: number): number {
  return Math.max(0, Array.from(text).length * ADVANCE * scale - scale);
}

/** The largest scale (down to 2) at which `text` fits `maxWidth`, truncating with "..." below that. */
function fit(text: string, maxWidth: number, scale: number): { text: string; scale: number } {
  for (let s = scale; s >= 2; s--) if (textWidth(text, s) <= maxWidth) return { text, scale: s };
  const chars = Array.from(text);
  while (chars.length > 1 && textWidth(`${chars.join("")}...`, 2) > maxWidth) chars.pop();
  return { text: `${chars.join("")}...`, scale: 2 };
}

class Canvas {
  readonly pixels = new Uint8Array(CARD_WIDTH * CARD_HEIGHT);

  rect(x: number, y: number, w: number, h: number, colour: number): void {
    const x0 = Math.max(0, x);
    const x1 = Math.min(CARD_WIDTH, x + w);
    for (let row = Math.max(0, y); row < Math.min(CARD_HEIGHT, y + h); row++) {
      if (x1 > x0) this.pixels.fill(colour, row * CARD_WIDTH + x0, row * CARD_WIDTH + x1);
    }
  }

  text(text: string, x: number, y: number, scale: number, colour: number): void {
    let cursor = x;
    for (const ch of text) {
      glyph(ch).forEach((bits, row) => {
        for (let col = 0; col < GLYPH_W; col++) {
          if (bits & (1 << (GLYPH_W - 1 - col))) this.rect(cursor + col * scale, y + row * scale, scale, scale, colour);
        }
      });
      cursor += ADVANCE * scale;
    }
  }

  fitted(text: string, x: number, y: number, maxWidth: number, scale: number, colour: number): void {
    const f = fit(text, maxWidth, scale);
    this.text(f.text, x, y, f.scale, colour);
  }
}

// ── PNG ──────────────────────────────────────────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const byte of bytes) c = (CRC_TABLE[(c ^ byte) & 0xff] as number) ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.byteLength);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.byteLength);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  view.setUint32(8 + data.byteLength, crc32(out.subarray(4, 8 + data.byteLength)));
  return out;
}

async function zlib(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new CompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function encodePng(width: number, height: number, pixels: Uint8Array, palette: Uint8Array): Promise<Uint8Array> {
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  header.set([8, 3, 0, 0, 0], 8); // 8-bit, palette, deflate, adaptive filter, no interlace
  const scanlines = new Uint8Array((width + 1) * height); // each row: filter byte 0, then the pixels
  for (let row = 0; row < height; row++) scanlines.set(pixels.subarray(row * width, (row + 1) * width), row * (width + 1) + 1);
  const parts = [
    Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("PLTE", palette),
    chunk("IDAT", await zlib(scanlines)),
    chunk("IEND", new Uint8Array(0)),
  ];
  const png = new Uint8Array(parts.reduce((sum, part) => sum + part.byteLength, 0));
  let offset = 0;
  for (const part of parts) {
    png.set(part, offset);
    offset += part.byteLength;
  }
  return png;
}

// ── the card ─────────────────────────────────────────────────────────────────────────────────

const MARGIN = 64;
const INNER = CARD_WIDTH - 2 * MARGIN;
const MAX_FINDING_ROWS = 3;

function severityColour(severity: unknown): number {
  return severity === "high" ? BAD : severity === "medium" ? WARN : MUTED;
}

/** `displayUrl` is the receipt's address without the scheme, e.g. runhmd.dev/r/abc123. */
export async function renderCard(doc: JsonObject, displayUrl: string): Promise<Uint8Array> {
  const canvas = new Canvas();
  canvas.rect(0, 0, CARD_WIDTH, CARD_HEIGHT, BACKGROUND);
  canvas.rect(24, 24, CARD_WIDTH - 48, 4, EDGE);
  canvas.rect(24, CARD_HEIGHT - 28, CARD_WIDTH - 48, 4, EDGE);
  canvas.rect(24, 24, 4, CARD_HEIGHT - 48, EDGE);
  canvas.rect(CARD_WIDTH - 28, 24, 4, CARD_HEIGHT - 48, EDGE);

  const verdict = String(doc.verdict);
  const attacks = doc.attacks as JsonObject;
  const findings = doc.findings as JsonObject[];
  const tool = doc.tool as JsonObject;

  canvas.text("RUNHMD ATTACK", MARGIN, 60, 5, MUTED);
  const id = fit(String(doc.id), 520, 5);
  canvas.text(id.text, CARD_WIDTH - MARGIN - textWidth(id.text, id.scale), 60, id.scale, MUTED);
  canvas.text(verdict, MARGIN, 130, 16, verdict === "PROVEN" ? GOOD : BAD);
  canvas.fitted(`${attacks.total} ATTACKS | ${attacks.survived} SURVIVED | ${attacks.killed} KILLED`, MARGIN, 270, INNER, 5, TEXT);

  findings.slice(0, MAX_FINDING_ROWS).forEach((finding, index) => {
    const y = 340 + index * 48;
    canvas.rect(MARGIN, y + 2, 20, 20, severityColour(finding.severity));
    canvas.fitted(`${finding.id} ${String(finding.severity).toUpperCase()}: ${finding.title}`, MARGIN + 40, y, INNER - 40, 4, TEXT);
  });
  if (findings.length > MAX_FINDING_ROWS) {
    canvas.text(`+${findings.length - MAX_FINDING_ROWS} MORE IN THE RECEIPT`, MARGIN + 40, 340 + MAX_FINDING_ROWS * 48, 3, MUTED);
  }
  if (findings.length === 0) canvas.text("NO FINDINGS", MARGIN, 340, 4, MUTED);

  canvas.fitted(`COST $${doc.cost_usd} | ${doc.duration_s}S | ${tool.name} ${tool.version}`, MARGIN, 520, INNER, 4, MUTED);
  canvas.fitted(displayUrl, MARGIN, 556, INNER, 4, TEXT);
  return encodePng(CARD_WIDTH, CARD_HEIGHT, canvas.pixels, PALETTE);
}
