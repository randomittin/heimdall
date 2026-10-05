// The hosted runhmd receipt service (RP3). Routes:
//
//   POST /api/receipts                 upload a signed runhmd.receipt/1 file (bearer token)
//   GET  /r/<id>                       the receipt page (HTML)
//   GET  /r/<id>.json                  the exact signed bytes
//   GET  /r/<id>/card.png              the 1200x630 card (Open Graph image)
//   POST /r/<id>/f/<finding_id>/rate   {"label":"real"|"false"} (bearer token)
//   GET  /health                       liveness, answered without touching a Durable Object
//
// What is accepted: only a receipt whose Ed25519 signature verifies against the pinned public
// key(s) in RECEIPT_PUBKEYS, under the same canonical-JSON and schema rules as `hmd receipt
// verify` (src/receipt.ts is a port of bin/lib/runhmd_receipt.py, held to it by
// contract/vectors.json). Unsigned, mis-signed, non-canonical or over-size uploads are refused, and
// the first receipt filed under an id is the only one that id ever holds.
//
// What is served: the stored bytes, re-verified on every read (so removing a key from
// RECEIPT_PUBKEYS withdraws what it signed). A PRIVATE receipt is a plain 404, byte for byte the
// answer for an id that does not exist, unless the request carries a valid bearer token.
//
// Write routes are throttled per source IP, and fail closed: with no API tokens or no public key
// configured they answer 503 rather than running open.

import { version as PACKAGE_VERSION } from "../package.json";
import { authenticate } from "./auth";
import { renderCard } from "./card";
import type { Label } from "./do";
import { bytesResponse, jsonResponse, textResponse } from "./http";
import { humanLabel, pageCsp, renderPage } from "./page";
import { MAX_RECEIPT_BYTES, parseTrust, ReceiptError, type Trust, verifyReceipt } from "./receipt";
import { FINDING_ID_RE, ID_RE } from "./schema";
import type { Env, JsonObject } from "./types";

export { ReceiptDO, ThrottleDO } from "./do";

const WRITE_WINDOW_MS = 60_000;
const WRITE_MAX_PER_WINDOW = 30;
const MAX_RATING_BYTES = 1024;
const SOURCES = new Set(["cli", "pr", "mobile"]);
const BASE_URL_RE = /^https:\/\/[^\s/?#@]+(\/[^\s?#]*)?$/;
const RECEIPT_ROUTE = /^\/r\/([^/]+)$/;
const CARD_ROUTE = /^\/r\/([^/]+)\/card\.png$/;
const RATE_ROUTE = /^\/r\/([^/]+)\/f\/([^/]+)\/rate$/;

type Kind = "page" | "json" | "card";
type Gate = { response: Response } | { trust: Trust };

const notFound = (): Response => textResponse(404, "not found");
const methodNotAllowed = (allow: string): Response => textResponse(405, "method not allowed", { Allow: allow });
const disabled = (): Response =>
  jsonResponse(503, { ok: false, error: "disabled", message: "write routes are disabled: the service has no API tokens or no receipt public key configured" });

function baseUrl(env: Env, request: Request): string {
  const configured = (env.PUBLIC_BASE_URL ?? "").replace(/\/$/, "");
  return BASE_URL_RE.test(configured) ? configured : new URL(request.url).origin;
}

function ctaHref(env: Env, id: string): string | null {
  const configured = env.CTA_URL ?? "";
  return BASE_URL_RE.test(configured) ? `${configured}?receipt=${encodeURIComponent(id)}` : null;
}

/** The pinned trust set, or null when it is absent or malformed (never "trust nothing and accept"). */
async function trustFor(env: Env): Promise<Trust | null> {
  try {
    const trust = await parseTrust(env.RECEIPT_PUBKEYS ?? "");
    return trust.size > 0 ? trust : null;
  } catch (error) {
    if (error instanceof ReceiptError) {
      console.error("receipts: RECEIPT_PUBKEYS is unusable:", error.kind);
      return null;
    }
    throw error;
  }
}

/** Count this write attempt against the source IP. `CF-Connecting-IP` is set by Cloudflare's edge and
 *  cannot be spoofed; its absence (wrangler dev, the test pool) shares one "unknown" bucket and is
 *  throttled like any caller: fail closed, never "unlimited". */
async function throttle(request: Request, env: Env): Promise<Response | null> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const throttled = await env.THROTTLE.get(env.THROTTLE.idFromName(`write-throttle:${ip}`)).hit(WRITE_WINDOW_MS, WRITE_MAX_PER_WINDOW);
  return throttled
    ? jsonResponse(429, { ok: false, error: "too many requests", retry_after_s: WRITE_WINDOW_MS / 1000 }, { "Retry-After": String(WRITE_WINDOW_MS / 1000) })
    : null;
}

/** Bearer token valid, and a trust set configured. */
async function gateWrite(request: Request, env: Env): Promise<Gate> {
  const auth = await authenticate(request, env);
  if (auth === "disabled") return { response: disabled() };
  if (auth !== "ok") {
    return { response: jsonResponse(401, { ok: false, error: "unauthorized" }, { "WWW-Authenticate": 'Bearer realm="runhmd-receipts"' }) };
  }
  const trust = await trustFor(env);
  return trust ? { trust } : { response: disabled() };
}

/** The body, or null when it is larger than `cap` (the declared length is not trusted: the stream is counted). */
async function readCapped(request: Request, cap: number): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > cap) return null;
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array(0);
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const part of chunks) {
    body.set(part, offset);
    offset += part.byteLength;
  }
  return body;
}

const isJson = (request: Request): boolean =>
  (request.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() === "application/json";

const receiptStub = (env: Env, id: string) => env.RECEIPT.get(env.RECEIPT.idFromName(`receipt:${id}`));

function invalid(error: ReceiptError): Response {
  return jsonResponse(error.kind === "not_json" ? 400 : 422, { ok: false, error: "invalid_receipt", kind: error.kind, detail: error.detail.slice(0, 400) });
}

async function upload(request: Request, env: Env): Promise<Response> {
  const limited = await throttle(request, env);
  if (limited) return limited;
  const gate = await gateWrite(request, env);
  if ("response" in gate) return gate.response;
  if (!isJson(request)) return jsonResponse(415, { ok: false, error: "content-type must be application/json" });
  const raw = await readCapped(request, MAX_RECEIPT_BYTES);
  if (!raw) return jsonResponse(413, { ok: false, error: "receipt too large", max_bytes: MAX_RECEIPT_BYTES });
  let doc: JsonObject;
  try {
    doc = await verifyReceipt(raw, gate.trust);
  } catch (error) {
    if (error instanceof ReceiptError) return invalid(error);
    throw error;
  }
  const id = doc.id as string;
  const visibility = doc.visibility as "public" | "private";
  const outcome = await receiptStub(env, id).put(raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer, visibility);
  if (outcome === "conflict") {
    return jsonResponse(409, { ok: false, error: "id_conflict", message: `a different receipt is already stored as ${id}; receipts are immutable` });
  }
  return jsonResponse(outcome === "created" ? 201 : 200, {
    ok: true, id, url: `${baseUrl(env, request)}/r/${id}`, visibility, created: outcome === "created",
  });
}

async function serve(request: Request, env: Env, id: string, kind: Kind): Promise<Response> {
  if (!ID_RE.test(id)) return notFound();
  const stub = receiptStub(env, id);
  const stored = await stub.get();
  if (!stored) return notFound();
  // A private receipt is a 404 to everyone without a token: the same answer as no such id.
  if (stored.visibility !== "public" && (await authenticate(request, env)) !== "ok") return notFound();
  const trust = await trustFor(env);
  if (!trust) return jsonResponse(503, { ok: false, error: "disabled", message: "the service has no receipt public key configured" });
  const raw = new Uint8Array(stored.raw);
  let doc: JsonObject;
  try {
    doc = await verifyReceipt(raw, trust);
    if (doc.id !== id || doc.visibility !== stored.visibility) {
      throw new ReceiptError("id_mismatch", `filed as ${id} but it is receipt ${String(doc.id)}`);
    }
  } catch (error) {
    if (error instanceof ReceiptError) {
      console.error("receipts: refusing a stored receipt:", error.kind);
      return textResponse(500, "receipt failed verification");
    }
    throw error;
  }
  const isPublic = doc.visibility === "public";
  const volatile = isPublic ? "no-store" : "private, no-store";
  if (kind === "json") return bytesResponse(raw, "application/json", { "Cache-Control": volatile });
  const base = baseUrl(env, request);
  if (kind === "card") {
    const png = await renderCard(doc, `${base.replace(/^https:\/\//, "")}/r/${id}`);
    return bytesResponse(png, "image/png", { "Cache-Control": isPublic ? "public, max-age=300" : "private, no-store" });
  }
  const page = await renderPage(doc, { labels: await stub.labels(), cta: ctaHref(env, id), base });
  return bytesResponse(page.html, "text/html; charset=utf-8", {
    "Cache-Control": volatile,
    "Content-Security-Policy": `${await pageCsp()}; frame-ancestors 'none'`,
  });
}

/** `{"label":"real"|"false"}`, optionally `"source":"cli"|"pr"|"mobile"`; anything else is a 400. */
function parseRating(raw: Uint8Array): { label: Label; source: string } | string {
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return "body must be a JSON object";
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) return "body must be a JSON object";
  const fields = body as Record<string, unknown>;
  const unknown = Object.keys(fields).filter((key) => key !== "label" && key !== "source");
  if (unknown.length) return `unknown field: ${unknown[0]}`;
  if (fields.label !== "real" && fields.label !== "false") return 'label must be "real" or "false"';
  const source = fields.source ?? "cli";
  if (typeof source !== "string" || !SOURCES.has(source)) return 'source must be "cli", "pr" or "mobile"';
  return { label: fields.label, source };
}

async function rate(request: Request, env: Env, id: string, findingId: string): Promise<Response> {
  const limited = await throttle(request, env);
  if (limited) return limited;
  const gate = await gateWrite(request, env);
  if ("response" in gate) return gate.response;
  if (!isJson(request)) return jsonResponse(415, { ok: false, error: "content-type must be application/json" });
  const raw = await readCapped(request, MAX_RATING_BYTES);
  if (!raw) return jsonResponse(413, { ok: false, error: "rating too large", max_bytes: MAX_RATING_BYTES });
  const rating = parseRating(raw);
  if (typeof rating === "string") return jsonResponse(400, { ok: false, error: "bad_rating", message: rating });
  if (!ID_RE.test(id) || !FINDING_ID_RE.test(findingId)) return jsonResponse(404, { ok: false, error: "not_found" });
  const stub = receiptStub(env, id);
  const stored = await stub.get();
  if (!stored) return jsonResponse(404, { ok: false, error: "not_found" });
  let doc: JsonObject;
  try {
    doc = await verifyReceipt(new Uint8Array(stored.raw), gate.trust);
  } catch (error) {
    if (error instanceof ReceiptError) {
      console.error("receipts: refusing a stored receipt:", error.kind);
      return jsonResponse(500, { ok: false, error: "receipt failed verification" });
    }
    throw error;
  }
  if (!(doc.findings as JsonObject[]).some((finding) => finding.id === findingId)) {
    return jsonResponse(404, { ok: false, error: "no_such_finding" });
  }
  await stub.rate(findingId, rating.label, rating.source);
  return jsonResponse(200, { ok: true, receipt_id: id, finding_id: findingId, label: rating.label, human_label: humanLabel(rating.label) });
}

async function route(request: Request, env: Env, method: string): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/health") {
    return method === "GET" ? jsonResponse(200, { ok: true, version: env.BUILD_ID || PACKAGE_VERSION }) : methodNotAllowed("GET, HEAD");
  }
  if (pathname === "/api/receipts") return method === "POST" ? upload(request, env) : methodNotAllowed("POST");
  const rating = RATE_ROUTE.exec(pathname);
  if (rating) return method === "POST" ? rate(request, env, rating[1] as string, rating[2] as string) : methodNotAllowed("POST");
  const card = CARD_ROUTE.exec(pathname);
  if (card) return method === "GET" ? serve(request, env, card[1] as string, "card") : methodNotAllowed("GET, HEAD");
  const receipt = RECEIPT_ROUTE.exec(pathname);
  if (receipt) {
    const name = receipt[1] as string;
    const json = name.endsWith(".json");
    return method === "GET" ? serve(request, env, json ? name.slice(0, -".json".length) : name, json ? "json" : "page") : methodNotAllowed("GET, HEAD");
  }
  return notFound();
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const head = request.method === "HEAD";
      const response = await route(request, env, head ? "GET" : request.method);
      // HEAD gets GET's status and headers with no body (RFC 9110 section 9.3.2).
      return head ? new Response(null, response) : response;
    } catch (error) {
      console.error("receipts: unhandled error:", error instanceof Error ? error.message : String(error));
      return jsonResponse(500, { ok: false, error: "internal" });
    }
  },
};
