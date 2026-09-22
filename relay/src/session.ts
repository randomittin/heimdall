// SessionDO — the Durable Object that owns one relay session's entire
// lifecycle: pairing, device binding, frame forwarding, and revocation.
//
// One instance per session_id (spec §1); Durable Object input gates give us
// automatic per-instance serialization, so no manual locking is needed here.
// The relay never decrypts anything (INV-18) — `ciphertext`/`nonce` pass
// through byte-identical; only the two relay-originated control frame types
// (`device_bound`, `session_ended`) carry a plaintext `payload`.

import type { Env } from "./types";
import { isEnvelope } from "./types";
import {
  jsonResponse,
  MAX_ENVELOPE_BYTES,
  isPlaintextUpgrade,
  isWebSocketUpgrade,
} from "./http";
import {
  generatePairingCode,
  generateSessionToken,
  recordClaimAttempt,
  mintDeviceToken,
  verifyDeviceToken,
  timingSafeEqual,
  PAIRING_CODE_TTL_S,
  CLAIM_THROTTLE_RETRY_AFTER_S,
  DEVICE_TOKEN_TTL_S,
} from "./pairing";
import { logEvent } from "./logging";

type SessionStatus = "pending" | "bound" | "ended";

interface SessionRecord {
  session_id: string;
  pairing_code: string;
  pair_exp: number; // epoch ms
  relay_session_token: string;
  claim_attempts: number[]; // epoch ms, sliding window
  status: SessionStatus;
}

const DEVICE_TAG = "device";

export class SessionDO {
  private hmdStreamController: ReadableStreamDefaultController<Uint8Array> | null = null;

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/init":
        return this.handleInit(request);
      case "/stream":
        return this.handleStream(request);
      case "/frames":
        return this.handleFrames(request);
      case "/ws":
        return this.handleWsUpgrade(request);
      case "/revoke":
        return this.handleRevoke(request);
      default:
        return jsonResponse(404, { error: "not found" });
    }
  }

  private async loadRecord(): Promise<SessionRecord | undefined> {
    return this.ctx.storage.get<SessionRecord>("state");
  }

  private async saveRecord(record: SessionRecord): Promise<void> {
    await this.ctx.storage.put("state", record);
  }

  private checkBearer(request: Request, record: SessionRecord): boolean {
    const auth = request.headers.get("Authorization") ?? "";
    return timingSafeEqual(auth, `Bearer ${record.relay_session_token}`);
  }

  /** Internal contract, invoked only by worker.ts's `/pair/init` handler via
   * its own direct `stub.fetch("http://do-internal/init", ...)` call — never
   * reachable from a public request, since worker.ts's
   * PUBLIC_SESSION_SUBPATHS whitelist excludes "init" from the set of
   * subpaths it will ever forward here (a public `POST /session/:id/init`
   * now gets a 404 from worker.ts before this Durable Object is even
   * touched). Accepts an optional `pairing_ttl_s` override — production
   * callers never set it (default 60s applies); tests use it to construct an
   * already-expired session deterministically, without waiting or mocking
   * the clock. */
  private async handleInit(request: Request): Promise<Response> {
    const body = (await request.json()) as {
      session_id: string;
      pairing_ttl_s?: number;
    };
    const ttlS = body.pairing_ttl_s ?? PAIRING_CODE_TTL_S;
    const now = Date.now();
    const record: SessionRecord = {
      session_id: body.session_id,
      pairing_code: generatePairingCode(),
      pair_exp: now + ttlS * 1000,
      relay_session_token: generateSessionToken(),
      claim_attempts: [],
      status: "pending",
    };
    await this.saveRecord(record);
    return jsonResponse(200, {
      session_id: record.session_id,
      pairing_code: record.pairing_code,
      relay_session_token: record.relay_session_token,
      exp: Math.floor(record.pair_exp / 1000),
    });
  }

  /** hmd's laptop leg: long-lived chunked-HTTP GET carrying newline-delimited
   * JSON envelopes (device-originated `command` frames) up to hmd. */
  private async handleStream(request: Request): Promise<Response> {
    const record = await this.loadRecord();
    if (!record) return jsonResponse(404, { error: "session not found" });
    if (!this.checkBearer(request, record)) {
      return jsonResponse(401, { error: "missing or invalid bearer token" });
    }

    const owner = this;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        owner.hmdStreamController = controller;
      },
      cancel() {
        owner.hmdStreamController = null;
      },
    });
    return new Response(stream, {
      status: 200,
      headers: { "content-type": "application/x-ndjson" },
    });
  }

  /** hmd's laptop leg: POST of one envelope (`state` or `ack`) to forward to
   * the bound device's WebSocket, byte-identical (relay never touches
   * `ciphertext`/`nonce`). */
  private async handleFrames(request: Request): Promise<Response> {
    const record = await this.loadRecord();
    if (!record) return jsonResponse(404, { error: "session not found" });
    if (!this.checkBearer(request, record)) {
      return jsonResponse(401, { error: "missing or invalid bearer token" });
    }

    const contentLength = request.headers.get("content-length");
    if (contentLength && Number(contentLength) > MAX_ENVELOPE_BYTES) {
      return jsonResponse(413, { error: "frame exceeds 128 KiB limit" });
    }
    const bodyText = await request.text();
    if (new TextEncoder().encode(bodyText).byteLength > MAX_ENVELOPE_BYTES) {
      return jsonResponse(413, { error: "frame exceeds 128 KiB limit" });
    }

    let envelope: unknown;
    try {
      envelope = JSON.parse(bodyText);
    } catch {
      return jsonResponse(400, { error: "invalid JSON" });
    }
    if (!isEnvelope(envelope)) {
      return jsonResponse(400, { error: "invalid envelope" });
    }

    const target = this.ctx.getWebSockets(DEVICE_TAG)[0];
    if (!target) {
      logEvent("frame_undelivered", {
        session_id: record.session_id,
        reason: "no_device_connected",
      });
      return jsonResponse(200, { ok: true, delivered: false });
    }
    target.send(JSON.stringify(envelope));
    return jsonResponse(200, { ok: true, delivered: true });
  }

  /** Phone leg: `GET /ws?pairing_code=...` (first claim) or
   * `?device_token=...` (reconnect). Must be a real `wss://` WebSocket
   * upgrade — checked via Upgrade header presence and an explicit
   * plaintext-scheme signal (INV: "ws without wss -> 400"). */
  private async handleWsUpgrade(request: Request): Promise<Response> {
    if (!isWebSocketUpgrade(request)) {
      return jsonResponse(400, { error: "expected websocket upgrade" });
    }
    if (isPlaintextUpgrade(request)) {
      return jsonResponse(400, { error: "wss required" });
    }

    const record = await this.loadRecord();
    if (!record) return jsonResponse(404, { error: "session not found" });

    const url = new URL(request.url);
    const pairingCode = url.searchParams.get("pairing_code");
    const deviceToken = url.searchParams.get("device_token");
    if ((pairingCode && deviceToken) || (!pairingCode && !deviceToken)) {
      return jsonResponse(400, {
        error: "exactly one of pairing_code or device_token is required",
      });
    }

    if (deviceToken) {
      return this.handleDeviceTokenClaim(record, deviceToken);
    }
    return this.handlePairingCodeClaim(record, pairingCode as string);
  }

  private async handleDeviceTokenClaim(
    record: SessionRecord,
    deviceToken: string
  ): Promise<Response> {
    const ok = await verifyDeviceToken(
      this.env.RELAY_SIGNING_SECRET,
      deviceToken,
      record.session_id,
      Date.now()
    );
    if (!ok) return jsonResponse(401, { error: "invalid device token" });
    if (record.status === "ended") {
      return jsonResponse(410, { error: "session ended" });
    }
    return this.acceptDeviceSocket(record.session_id);
  }

  private async handlePairingCodeClaim(
    record: SessionRecord,
    pairingCode: string
  ): Promise<Response> {
    if (record.status !== "pending") {
      return jsonResponse(410, { error: "session no longer claimable" });
    }

    const now = Date.now();
    if (now > record.pair_exp) {
      record.status = "ended";
      await this.saveRecord(record);
      return jsonResponse(410, { error: "pairing code expired" });
    }

    const { attempts, throttled } = recordClaimAttempt(record.claim_attempts, now);
    record.claim_attempts = attempts;
    if (throttled) {
      record.status = "ended";
      await this.saveRecord(record);
      return jsonResponse(
        429,
        { error: "too many claim attempts", retry_after_s: CLAIM_THROTTLE_RETRY_AFTER_S },
        { "Retry-After": String(CLAIM_THROTTLE_RETRY_AFTER_S) }
      );
    }
    await this.saveRecord(record);

    if (!timingSafeEqual(pairingCode, record.pairing_code)) {
      return jsonResponse(401, { error: "invalid pairing code" });
    }

    const exp = Math.floor(now / 1000) + DEVICE_TOKEN_TTL_S;
    const deviceToken = await mintDeviceToken(this.env.RELAY_SIGNING_SECRET, {
      session_id: record.session_id,
      role: "device",
      exp,
    });
    record.status = "bound";
    await this.saveRecord(record);

    return this.acceptDeviceSocket(record.session_id, { device_token: deviceToken, exp });
  }

  private acceptDeviceSocket(
    sessionId: string,
    bindPayload?: Record<string, unknown>
  ): Response {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [DEVICE_TAG]);
    if (bindPayload) {
      server.send(
        JSON.stringify({
          v: 1,
          session_id: sessionId,
          seq: 0,
          sender: "relay",
          type: "device_bound",
          nonce: null,
          ciphertext: null,
          payload: bindPayload,
        })
      );
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** hmd-initiated kill switch (INV-29/30): ends the session, closes the
   * device's socket with 4001, and — since `status` becomes "ended" — makes
   * every future claim attempt (even with the original correct pairing_code
   * or a previously-valid device_token) return 410. */
  private async handleRevoke(request: Request): Promise<Response> {
    const record = await this.loadRecord();
    if (!record) return jsonResponse(404, { error: "session not found" });
    if (!this.checkBearer(request, record)) {
      return jsonResponse(401, { error: "missing or invalid bearer token" });
    }

    record.status = "ended";
    await this.saveRecord(record);

    const sockets = this.ctx.getWebSockets(DEVICE_TAG);
    for (const socket of sockets) {
      try {
        socket.send(
          JSON.stringify({
            v: 1,
            session_id: record.session_id,
            seq: 0,
            sender: "relay",
            type: "session_ended",
            nonce: null,
            ciphertext: null,
            payload: { reason: "revoked" },
          })
        );
      } catch {
        // Socket may already be closing — the close() below still proceeds.
      }
      socket.close(4001, "revoked");
    }

    // hmd's GET /stream leg (handleStream, above) is a long-lived response
    // this Durable Object otherwise never ends on its own — only the client
    // aborting ever closed it. A revoked session is fully over, so end that
    // side too instead of leaving it open indefinitely with nothing left to
    // ever write to it.
    if (this.hmdStreamController) {
      try {
        this.hmdStreamController.close();
      } catch {
        // Already closed/errored (e.g. client already disconnected) — no-op.
      }
      this.hmdStreamController = null;
    }

    return jsonResponse(200, { ok: true });
  }

  async webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let envelope: unknown;
    try {
      envelope = JSON.parse(message);
    } catch {
      return;
    }
    if (!isEnvelope(envelope)) return;

    if (this.hmdStreamController) {
      this.hmdStreamController.enqueue(
        new TextEncoder().encode(JSON.stringify(envelope) + "\n")
      );
      return;
    }
    const record = await this.loadRecord();
    logEvent("frame_undelivered", {
      session_id: record?.session_id ?? "unknown",
      reason: "no_hmd_stream_connected",
    });
  }

  async webSocketClose(
    _ws: WebSocket,
    code: number,
    _reason: string,
    wasClean: boolean
  ): Promise<void> {
    const record = await this.loadRecord();
    logEvent("device_socket_closed", {
      session_id: record?.session_id ?? "unknown",
      code,
      wasClean,
    });
  }

  async webSocketError(_ws: WebSocket, _error: unknown): Promise<void> {
    const record = await this.loadRecord();
    logEvent("device_socket_error", { session_id: record?.session_id ?? "unknown" });
  }
}
