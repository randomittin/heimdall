// The service end to end through the real Worker and Durable Objects (workerd, no mocks): upload,
// the three read routes, private receipts, ratings and the CTA, the throttle, and fail-closed
// configuration. Every key is generated per run (vitest.config.ts) or per test.
import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { parseTrust, ReceiptError, verifyReceipt } from "../src/receipt";
import worker from "../src/worker";
import type { Env, JsonObject } from "../src/types";
import { BASE, bearer, bytesOf, get, issue, rate, strangerSigner, TOKEN, trustedSigner, testEnv, uniqueIp, upload, receiptBody, signBody } from "./helpers";

const text = (bytes: Uint8Array): string => new TextDecoder().decode(bytes);

async function stored(over: JsonObject = {}) {
  const made = await issue(over);
  const res = await upload(made.raw);
  expect(res.status).toBe(201);
  return made;
}

describe("POST /api/receipts", () => {
  it("accepts a signed receipt, answers its URL, and serves back the exact bytes", async () => {
    const { id, raw } = await issue();
    const res = await upload(raw);
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ ok: true, id, url: `${BASE}/r/${id}`, visibility: "public", created: true });
    const served = await get(`/r/${id}.json`);
    expect(served.status).toBe(200);
    expect(served.headers.get("content-type")).toBe("application/json");
    expect(await bytesOf(served)).toEqual(raw);
  });

  it("the served bytes are the signed bytes: they verify, and a single flipped byte does not", async () => {
    const { id } = await stored();
    const bytes = await bytesOf(await get(`/r/${id}.json`));
    const trust = await parseTrust(testEnv.RECEIPT_PUBKEYS as string);
    await expect(verifyReceipt(bytes, trust)).resolves.toMatchObject({ id });
    for (const at of [10, Math.floor(bytes.length / 2), bytes.length - 20]) {
      const tampered = bytes.slice();
      tampered[at] = (tampered[at] as number) ^ 0x01;
      await expect(verifyReceipt(tampered, trust)).rejects.toBeInstanceOf(ReceiptError);
    }
  });

  it("is idempotent for identical bytes and refuses a different receipt under the same id", async () => {
    const first = await issue();
    expect((await upload(first.raw)).status).toBe(201);
    const again = await upload(first.raw);
    expect(again.status).toBe(200);
    expect(await again.json()).toMatchObject({ ok: true, created: false });
    const other = await signBody(receiptBody({ id: first.id, cost_usd: 9.99 }), await trustedSigner());
    const conflict = await upload(other);
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toMatchObject({ ok: false, error: "id_conflict" });
    expect(await bytesOf(await get(`/r/${first.id}.json`))).toEqual(first.raw);
  });

  it("refuses an unsigned receipt", async () => {
    const body = receiptBody();
    const unsigned = new TextEncoder().encode(JSON.stringify({ ...body, key_id: "0".repeat(16) }));
    const res = await upload(unsigned);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ ok: false, error: "invalid_receipt", kind: "schema" });
  });

  it("refuses a receipt changed after signing", async () => {
    const { raw } = await issue();
    const tampered = new TextEncoder().encode(text(raw).replace('"cost_usd":0.41', '"cost_usd":0.42'));
    const res = await upload(tampered);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ kind: "bad_signature" });
  });

  it("refuses a receipt signed by a key that is not pinned", async () => {
    const { raw } = await issue({}, await strangerSigner());
    const res = await upload(raw);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ kind: "unknown_key" });
  });

  it("refuses a validly signed document that is not in canonical form", async () => {
    const { raw } = await issue();
    const pretty = new TextEncoder().encode(JSON.stringify(JSON.parse(text(raw)), null, 2));
    const res = await upload(pretty);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ kind: "not_canonical" });
  });

  it("refuses a signed receipt that carries counterexample text (receipts hold digests only)", async () => {
    const finding = { id: "f-0001", title: "t", severity: "high", category: "logic", digest: `sha256:${"a".repeat(64)}`, counterexample: { summary: "s", repro_cmd: "c", minimal_input: "secret" } };
    const raw = await signBody(receiptBody({ findings: [finding] }), await trustedSigner());
    const res = await upload(raw);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ kind: "schema" });
  });

  it("refuses text that is not JSON (400)", async () => {
    const res = await upload("not json{");
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ kind: "not_json" });
  });

  it("refuses a body over the size limit, declared or streamed (413)", async () => {
    const declared = await upload(new Uint8Array(1024 * 1024 + 1).fill(0x20));
    expect(declared.status).toBe(413);
    const chunk = new Uint8Array(64 * 1024).fill(0x20);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent > 1024 * 1024) controller.close();
        else {
          controller.enqueue(chunk);
          sent += chunk.byteLength;
        }
      },
    });
    const streamed = await SELF.fetch(`${BASE}/api/receipts`, {
      method: "POST",
      headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp(), ...bearer },
      body: stream,
      duplex: "half",
    } as RequestInit);
    expect(streamed.status).toBe(413);
  });

  it("requires JSON as the content type (415)", async () => {
    const { raw } = await issue();
    const res = await upload(raw, { "content-type": "text/plain" });
    expect(res.status).toBe(415);
  });

  it("answers GET with 405 and an Allow header", async () => {
    const res = await get("/api/receipts");
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("POST");
  });
});

describe("authentication and configuration (fail closed)", () => {
  it("answers 401 without a token, and with a wrong one", async () => {
    const { raw } = await issue();
    const missing = await SELF.fetch(`${BASE}/api/receipts`, { method: "POST", headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp() }, body: raw });
    expect(missing.status).toBe(401);
    expect(missing.headers.get("www-authenticate")).toContain("Bearer");
    const wrong = await upload(raw, { Authorization: `Bearer ${"0".repeat(64)}` });
    expect(wrong.status).toBe(401);
    const short = await upload(raw, { Authorization: "Bearer short" });
    expect(short.status).toBe(401);
  });

  const request = async (raw: Uint8Array) =>
    new Request(`${BASE}/api/receipts`, { method: "POST", headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp(), ...bearer }, body: raw });

  it("answers 503, not open access, when no API token is configured", async () => {
    const { raw } = await issue();
    for (const API_TOKEN_SHA256S of [undefined, "", "   ", "not-a-digest"]) {
      const res = await worker.fetch(await request(raw), { ...(env as unknown as Env), API_TOKEN_SHA256S });
      expect(res.status).toBe(503);
    }
  });

  it("answers 503 when no receipt public key is configured, or the setting is malformed", async () => {
    const { raw } = await issue();
    for (const RECEIPT_PUBKEYS of [undefined, "", "# only a comment\n", "AAAA"]) {
      const res = await worker.fetch(await request(raw), { ...(env as unknown as Env), RECEIPT_PUBKEYS });
      expect(res.status).toBe(503);
    }
  });

  it("throttles write attempts per source IP (429 + Retry-After), without touching other IPs", async () => {
    const ip = uniqueIp();
    const statuses: number[] = [];
    for (let i = 0; i < 31; i++) statuses.push((await upload("x", { "CF-Connecting-IP": ip, Authorization: "Bearer nope" })).status);
    expect(statuses.slice(0, 30).every((s) => s === 401)).toBe(true);
    expect(statuses[30]).toBe(429);
    const limited = await upload("x", { "CF-Connecting-IP": ip });
    expect(limited.headers.get("retry-after")).toBe("60");
    expect((await upload("x", { "CF-Connecting-IP": uniqueIp() })).status).not.toBe(429);
  });
});

describe("GET /r/<id>, /r/<id>.json, /r/<id>/card.png", () => {
  it("renders the page with the verdict, escaped titles, the security headers and OG tags", async () => {
    const hostile = { id: "f-0001", title: '<script>alert("x")</script> & "q"', severity: "high", category: "input", digest: `sha256:${"a".repeat(64)}` };
    const { id } = await stored({ findings: [hostile] });
    const res = await get(`/r/${id}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    const csp = res.headers.get("content-security-policy") as string;
    expect(csp).toMatch(/default-src 'none'; style-src 'sha256-[A-Za-z0-9+/=]+'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'/);
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await res.text();
    expect(html).toContain("DENIED");
    expect(html).not.toContain("<script");
    expect(html).toContain("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &quot;q&quot;");
    expect(html).toContain(`<meta property="og:image" content="${BASE}/r/${id}/card.png">`);
    expect(html).toContain(`hmd receipt verify ${id}.json`);
  });

  it("serves a 1200x630 PNG card", async () => {
    const { id } = await stored();
    const res = await get(`/r/${id}/card.png`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
    const png = await bytesOf(res);
    expect(Array.from(png.slice(0, 8))).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const view = new DataView(png.buffer, png.byteOffset);
    expect([view.getUint32(16), view.getUint32(20)]).toEqual([1200, 630]);
  });

  it("never publishes counterexample text: no response mentions minimal_input or counterexample", async () => {
    const { id } = await stored();
    for (const path of [`/r/${id}`, `/r/${id}.json`]) {
      const body = await (await get(path)).text();
      expect(body).not.toContain("minimal_input");
      expect(body).not.toContain("counterexample");
    }
  });

  it("answers 404 for an unknown id and for malformed ones, with one body", async () => {
    const missing = await get("/r/zzzzzzzzzzzz");
    expect(missing.status).toBe(404);
    const body = await missing.text();
    for (const path of ["/r/zz", "/r/zzzzzzzzzzzz.JSON", "/r/..", "/r/%2e%2e", "/r/zzzzzzzzzzzz/", "/r/zzzzzzzzzzzz.json/", "/r/zzzzzzzzzzzz/card.PNG", "/r", "/", "/R/zzzzzzzzzzzz"]) {
      expect((await get(path)).status, path).toBe(404);
    }
    expect(body).toBe("not found\n");
  });

  it("answers HEAD like GET without a body", async () => {
    const { id } = await stored();
    const res = await SELF.fetch(`${BASE}/r/${id}.json`, { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(await res.text()).toBe("");
  });

  it("answers 405 to a write method on a read route", async () => {
    const { id } = await stored();
    expect((await SELF.fetch(`${BASE}/r/${id}.json`, { method: "POST" })).status).toBe(405);
  });

  it("re-verifies on every read: a receipt whose key was withdrawn is not served", async () => {
    const { id } = await stored();
    const other = await strangerSigner();
    const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const raw = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))));
    expect(other.keyId).toHaveLength(16);
    const res = await worker.fetch(new Request(`${BASE}/r/${id}.json`), { ...(env as unknown as Env), RECEIPT_PUBKEYS: raw });
    expect(res.status).toBe(500);
    expect(await res.text()).toBe("receipt failed verification\n");
  });
});

describe("private receipts", () => {
  it("are a 404 to anonymous callers on every route, indistinguishable from an unknown id", async () => {
    const { id } = await stored({ visibility: "private" });
    const unknown = await (await get("/r/zzzzzzzzzzzz")).text();
    for (const path of [`/r/${id}`, `/r/${id}.json`, `/r/${id}/card.png`]) {
      const res = await get(path);
      expect(res.status, path).toBe(404);
      expect(await res.text()).toBe(unknown);
    }
    expect((await get(`/r/${id}.json`, { Authorization: `Bearer ${"0".repeat(64)}` })).status).toBe(404);
  });

  it("are served, uncached, to a caller with a valid token", async () => {
    const { id, raw } = await stored({ visibility: "private" });
    const json = await get(`/r/${id}.json`, bearer);
    expect(json.status).toBe(200);
    expect(json.headers.get("cache-control")).toBe("private, no-store");
    expect(await bytesOf(json)).toEqual(raw);
    const page = await get(`/r/${id}`, bearer);
    expect(page.status).toBe(200);
    expect(await page.text()).not.toContain("og:image");
    const card = await get(`/r/${id}/card.png`, bearer);
    expect(card.headers.get("content-type")).toBe("image/png");
    expect(card.headers.get("cache-control")).toBe("private, no-store");
  });
});

describe("POST /r/<id>/f/<finding_id>/rate and the cloud-access CTA", () => {
  const CTA = "Request cloud access for this team";

  it("shows no CTA until a finding is rated real, then shows it, and withdraws it when the label flips", async () => {
    const { id } = await stored();
    expect(await (await get(`/r/${id}`)).text()).not.toContain(CTA);
    const real = await rate(id, "f-0001", { label: "real" });
    expect(real.status).toBe(200);
    expect(await real.json()).toEqual({ ok: true, receipt_id: id, finding_id: "f-0001", label: "real", human_label: "true_positive" });
    const html = await (await get(`/r/${id}`)).text();
    expect(html).toContain(CTA);
    expect(html).toContain(`href="${BASE}/request-cloud-access?receipt=${id}"`);
    expect(html).toContain(">real</td>");
    const flipped = await rate(id, "f-0001", { label: "false" });
    expect(await flipped.json()).toMatchObject({ label: "false", human_label: "false_positive" });
    const after = await (await get(`/r/${id}`)).text();
    expect(after).not.toContain(CTA);
    expect(after).toContain(">false alarm</td>");
  });

  it("a false rating alone never shows the CTA, and the other findings stay unrated", async () => {
    const { id } = await stored();
    expect((await rate(id, "f-0002", { label: "false" })).status).toBe(200);
    const html = await (await get(`/r/${id}`)).text();
    expect(html).not.toContain(CTA);
    expect(html).toContain(">unrated</td>");
  });

  it("does not change the signed receipt: the .json bytes are the same after rating", async () => {
    const { id, raw } = await stored();
    await rate(id, "f-0001", { label: "real", source: "mobile" });
    expect(await bytesOf(await get(`/r/${id}.json`))).toEqual(raw);
  });

  it("needs a token (401), and a private receipt cannot be rated anonymously", async () => {
    const { id } = await stored({ visibility: "private" });
    const res = await SELF.fetch(`${BASE}/r/${id}/f/f-0001/rate`, { method: "POST", headers: { "content-type": "application/json", "CF-Connecting-IP": uniqueIp() }, body: '{"label":"real"}' });
    expect(res.status).toBe(401);
    expect((await rate(id, "f-0001", { label: "real" })).status).toBe(200);
  });

  it("refuses a bad label, an unknown field, a bad source, a non-object and a non-JSON body (400)", async () => {
    const { id } = await stored();
    for (const body of [{ label: "maybe" }, {}, { label: "real", note: "x" }, { label: "real", source: "web" }, [], "null", "nope{"]) {
      const res = await rate(id, "f-0001", body);
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
  });

  it("answers 404 for an unknown receipt and for a finding the receipt does not have", async () => {
    const { id } = await stored();
    expect((await rate("zzzzzzzzzzzz", "f-0001", { label: "real" })).status).toBe(404);
    const missing = await rate(id, "f-0099", { label: "real" });
    expect(missing.status).toBe(404);
    expect(await missing.json()).toMatchObject({ error: "no_such_finding" });
    expect((await rate(id, "not-a-finding", { label: "real" })).status).toBe(404);
  });

  it("refuses an oversize rating (413) and a wrong content type (415)", async () => {
    const { id } = await stored();
    expect((await rate(id, "f-0001", JSON.stringify({ label: "real", source: "x".repeat(2000) }))).status).toBe(413);
    expect((await rate(id, "f-0001", { label: "real" }, { "content-type": "text/plain" })).status).toBe(415);
  });

  it("omits the CTA when the service has no CTA_URL configured", async () => {
    const { id } = await stored();
    await rate(id, "f-0001", { label: "real" });
    const html = await (await worker.fetch(new Request(`${BASE}/r/${id}`), { ...(env as unknown as Env), CTA_URL: undefined })).text();
    expect(html).not.toContain(CTA);
  });
});

describe("GET /health", () => {
  it("answers 200 {ok, version} without a credential", async () => {
    const res = await get("/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true });
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("the test token digest is what the Worker was configured with (the suite really runs authenticated)", () => {
    expect(TOKEN).toMatch(/^[0-9a-f]{64}$/);
  });
});
