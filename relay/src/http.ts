// Tiny shared HTTP helpers used by both the top-level Worker router
// (src/worker.ts) and the per-session Durable Object (src/session.ts).

export function jsonResponse(
  status: number,
  body: unknown,
  extraHeaders?: Record<string, string>
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

export const MAX_ENVELOPE_BYTES = 1048576; // 1 MiB — INV-16 (raised 2026-09-24: real hmd state ~136 KB exceeded the old 128 KiB cap)

/** True when a phone-leg upgrade request is provably plaintext (never TLS).
 * Absence of both headers is treated as the local-dev fallback (delta brief:
 * "http in dev is fine") — only an EXPLICIT http-scheme signal rejects.
 * Checks the `Upgrade` header separately; this only inspects scheme hints. */
export function isPlaintextUpgrade(request: Request): boolean {
  const forwardedProto = request.headers.get("X-Forwarded-Proto");
  if (forwardedProto && forwardedProto.toLowerCase() === "http") return true;

  const cfVisitor = request.headers.get("cf-visitor");
  if (cfVisitor) {
    try {
      const parsed = JSON.parse(cfVisitor) as { scheme?: unknown };
      if (parsed && parsed.scheme === "http") return true;
    } catch {
      // Malformed header — not a confirmed http signal, fail open to dev-friendly default.
    }
  }
  return false;
}

export function isWebSocketUpgrade(request: Request): boolean {
  return (request.headers.get("Upgrade") ?? "").toLowerCase() === "websocket";
}
