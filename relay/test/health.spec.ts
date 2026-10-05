// `GET /health` -- the relay's liveness probe (src/health.ts), and the endpoint the deploy
// pipeline's canary check (.github/workflows/relay-deploy.yml, scripts/health-check.sh) polls.
// Three properties matter and each is pinned here:
//   1. it answers 200 `{ok:true, version}` to anyone, with no credential of any kind;
//   2. it never reaches a Durable Object -- a probe that woke one per poll would turn an outage
//      of the Durable Object layer into an outage of the probe, and mint storage on every poll;
//   3. it reports the build that is actually serving (BUILD_ID, else package.json's version).
//
// (2) is checked by driving the Worker's own fetch handler with a hand-built env whose SESSION
// binding throws on contact -- on READING the property, not only on calling idFromName/get on it
// -- so a regression that reaches for the namespace fails loudly. The control cases at the bottom
// prove that tripwire does fire on the routes that DO use Durable Objects, i.e. that the
// "untouched" assertion is one that can actually fail.

import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { version as PACKAGE_VERSION } from "../package.json";
import worker from "../src/worker";
import type { Env } from "../src/types";

const BASE = "https://relay-health.test";

const TRIPWIRE_MESSAGE = "touched the SESSION Durable Object namespace";

/** An Env whose SESSION binding trips on ANY access, and records that it was touched. */
function tripwireEnv(extra: Partial<Env> = {}): { env: Env; touched: string[] } {
  const touched: string[] = [];
  const target: Record<string, unknown> = {
    RELAY_SIGNING_SECRET: "test-only-relay-signing-secret-not-real",
    ...extra,
  };
  const env = new Proxy(target, {
    get(obj, prop, receiver) {
      if (prop === "SESSION") {
        touched.push("SESSION");
        throw new Error(`request ${TRIPWIRE_MESSAGE}`);
      }
      return Reflect.get(obj, prop, receiver);
    },
  });
  return { env: env as unknown as Env, touched };
}

describe("GET /health", () => {
  it("answers 200 {ok:true, version} through the real Worker, with no credentials", async () => {
    const res = await SELF.fetch(`${BASE}/health`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    // The pool binds no BUILD_ID, so this is the package.json fallback. `toEqual` also pins the
    // body to exactly these two keys: nothing about sessions, secrets or the host.
    expect(await res.json()).toEqual({ ok: true, version: PACKAGE_VERSION });
  });

  it("is never cached by an intermediary", async () => {
    const res = await SELF.fetch(`${BASE}/health`);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("ignores credentials entirely: a bogus Authorization header does not turn it into a 401", async () => {
    const res = await SELF.fetch(`${BASE}/health`, {
      headers: { Authorization: "Bearer not-a-real-token" },
    });
    expect(res.status).toBe(200);
  });

  it("matches on the path alone: a query string does not change the answer", async () => {
    const res = await SELF.fetch(`${BASE}/health?probe=canary`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, version: PACKAGE_VERSION });
  });

  it("answers HEAD with the same status and headers and no body", async () => {
    const res = await SELF.fetch(`${BASE}/health`, { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await res.text()).toBe("");
  });

  it("is GET/HEAD only: any other method falls through to the router's 404", async () => {
    for (const method of ["POST", "PUT", "DELETE"]) {
      const res = await SELF.fetch(`${BASE}/health`, { method });
      expect(res.status, method).toBe(404);
    }
  });

  it("is an exact path: /health/deep, /health/ and /healthz are not the probe", async () => {
    for (const path of ["/health/deep", "/health/", "/healthz"]) {
      const res = await SELF.fetch(`${BASE}${path}`);
      expect(res.status, path).toBe(404);
    }
  });
});

describe("GET /health version", () => {
  it("reports BUILD_ID when the deploy injected one", async () => {
    const buildId = "0123456789abcdef0123456789abcdef01234567";
    const { env } = tripwireEnv({ BUILD_ID: buildId });
    const res = await worker.fetch(new Request(`${BASE}/health`), env);
    expect(await res.json()).toEqual({ ok: true, version: buildId });
  });

  it("falls back to package.json's version when BUILD_ID is absent or empty", async () => {
    for (const extra of [{}, { BUILD_ID: "" }]) {
      const { env } = tripwireEnv(extra);
      const res = await worker.fetch(new Request(`${BASE}/health`), env);
      expect(await res.json(), JSON.stringify(extra)).toEqual({ ok: true, version: PACKAGE_VERSION });
    }
  });
});

describe("GET /health never reaches a Durable Object", () => {
  it("answers 200 without reading the SESSION namespace at all", async () => {
    const { env, touched } = tripwireEnv();
    for (const method of ["GET", "HEAD"]) {
      const res = await worker.fetch(new Request(`${BASE}/health`, { method }), env);
      expect(res.status, method).toBe(200);
    }
    expect(touched).toEqual([]);
  });

  // The controls: the same tripwire, on the routes that do use a Durable Object. If these did not
  // reject, the assertion above would be vacuous.
  it("control: the tripwire fires on a session route", async () => {
    const { env, touched } = tripwireEnv();
    const sessionId = "7d9c2a1e-4b3f-4c6a-9e1d-2f8b5a6c7d90";
    await expect(
      worker.fetch(new Request(`${BASE}/session/${sessionId}/stream`), env)
    ).rejects.toThrow(TRIPWIRE_MESSAGE);
    expect(touched).toEqual(["SESSION"]);
  });

  it("control: the tripwire fires on POST /pair/init", async () => {
    const { env, touched } = tripwireEnv();
    await expect(
      worker.fetch(new Request(`${BASE}/pair/init`, { method: "POST" }), env)
    ).rejects.toThrow(TRIPWIRE_MESSAGE);
    expect(touched).toEqual(["SESSION"]);
  });
});
