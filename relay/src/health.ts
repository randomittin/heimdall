// `GET /health` -- the relay's liveness probe.
//
// Answered by the Worker alone, ahead of every route that builds a Durable Object stub (the router
// in src/worker.ts orders it first, and test/health.spec.ts holds it there). A probe that woke a
// Durable Object per poll would couple "is the Worker up" to "is the Durable Object layer up" and
// would mint storage on every uptime check; a check that DOES exercise the Durable Object belongs
// on its own path, never on this one.
//
// No credential is read, and the body says nothing about sessions, secrets or the host -- only
// that the Worker answered and which build is serving. The deploy pipeline's canary check
// (.github/workflows/relay-deploy.yml, via scripts/health-check.sh) polls this and compares
// `version` with the commit it just shipped, which is what lets it tell the NEW build from a stale
// one that still answers 200.

import { version as PACKAGE_VERSION } from "../package.json";
import { jsonResponse } from "./http";
import type { Env } from "./types";

export function handleHealth(request: Request, env: Env): Response {
  const response = jsonResponse(
    200,
    { ok: true, version: env.BUILD_ID || PACKAGE_VERSION },
    // A health answer must describe the Worker that is serving NOW, never a copy an intermediary
    // kept: a stale 200 is exactly the failure a canary check exists to catch.
    { "Cache-Control": "no-store" }
  );
  // HEAD gets GET's status and headers with no body (RFC 9110 section 9.3.2).
  return request.method === "HEAD" ? new Response(null, response) : response;
}
