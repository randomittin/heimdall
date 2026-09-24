// SessionDO — the Durable Object that owns one relay session's entire
// lifecycle: pairing, device binding, frame forwarding, and revocation.
//
// One instance per session_id (spec §1); Durable Object input gates give us
// automatic per-instance serialization, so no manual locking is needed here.
// The relay never decrypts anything (INV-18) — `ciphertext`/`nonce` pass
// through byte-identical; only the two relay-originated control frame types
// (`device_bound`, `session_ended`) carry a plaintext `payload`.

import type {
  Env,
  DeviceBoundToPhonePayload,
  DeviceBoundToHmdPayload,
  KeepalivePayload,
} from "./types";
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
  base64UrlDecode,
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
const DEVICE_PUBKEY_BYTES = 32;

/**
 * Stamped onto every accepted device socket via `serializeAttachment`, so
 * "which socket is the phone actually on" is a property of the socket set
 * itself rather than of anything this instance holds in memory.
 *
 * That distinction is the whole point. A Durable Object is evicted and
 * rebuilt freely while its hibernatable sockets stay connected, so a field on
 * `this` — a `deviceSocket` ref, a counter, a Map — is gone by the time the
 * next `POST /frames` arrives, while `getWebSockets(DEVICE_TAG)` still hands
 * back every socket and `deserializeAttachment()` still hands back this. Every
 * read below therefore re-derives from those two calls and caches nothing.
 */
interface DeviceSocketAttachment {
  /** Per-session, strictly increasing across accepts: the highest generation
   *  still attached is the socket the phone most recently connected. */
  gen: number;
}

/**
 * The generation of one device socket, or 0 for a socket accepted before this
 * attachment existed — a deploy rolling over live sessions leaves those
 * connected, and any socket accepted afterwards outranks them.
 *
 * Never throws: a malformed or absent attachment must degrade to "oldest
 * possible", never cost a frame.
 */
function deviceSocketGeneration(socket: WebSocket): number {
  let attachment: unknown;
  try {
    attachment = socket.deserializeAttachment();
  } catch {
    return 0;
  }
  if (typeof attachment !== "object" || attachment === null) return 0;
  const gen = (attachment as Partial<DeviceSocketAttachment>).gen;
  return typeof gen === "number" && Number.isFinite(gen) ? gen : 0;
}

/**
 * How long hmd's `GET /stream` may sit idle before the relay writes a
 * `keepalive` control frame down it.
 *
 * Cloudflare closes a long-lived chunked response that carries no bytes:
 * observed live on 2026-09-24, a stream that opened at 08:33:53 with a bound
 * phone and no traffic after was closed server-side at 08:38:54 — 5m01s. A
 * session is mostly idle by nature (hmd only sends `state` on a digest
 * change, INV-22), so without this the steady state is a stream that dies
 * every five minutes. 20s leaves generous headroom under any such cap while
 * costing ~4 KiB/hour of otherwise-empty stream.
 *
 * This is belt, not braces: the client still reconnects with backoff if the
 * stream is cut anyway (relay/scripts/fake-hmd.mjs, and the same contract
 * handed to hmd in docs/HANDOFF-TO-HEIMDALL-relay.md).
 */
const KEEPALIVE_INTERVAL_MS = 20_000;

/** Fail-closed: a malformed (non-base64) value must 400, never throw past
 * this boundary and crash the isolate — base64UrlDecode's atob call throws
 * on invalid input, and this is attacker-controlled query-string data. */
function isValidDevicePubkey(value: string | null): value is string {
  if (!value) return false;
  try {
    return base64UrlDecode(value).length === DEVICE_PUBKEY_BYTES;
  } catch {
    return false;
  }
}

export class SessionDO {
  private hmdStreamController: ReadableStreamDefaultController<Uint8Array> | null = null;
  // The one control frame that may need buffering (spec: device_bound to
  // hmd's stream can arrive before hmd's GET /stream is even open) — never
  // more than one, since a session binds at most once (handleDeviceTokenClaim's
  // reconnect path never calls deliverToHmdStream again).
  private pendingHmdControlFrame: string | null = null;
  // Bumped once per `GET /stream`, so a stream's own `cancel()` can tell
  // whether it is still the live one before tearing down shared state — a
  // reconnect installs its controller before the superseded stream's cancel
  // runs. Same generation guard as src/transport/RelayTransport.ts's
  // `gen !== this.generation` check on its socket callbacks.
  private hmdStreamGeneration = 0;
  private keepaliveTimer: ReturnType<typeof setTimeout> | null = null;
  // The session id from the last record read or written. The keepalive timer
  // fires outside any request and still has to stamp `session_id` on the
  // frame it writes; caching it here keeps that path free of a storage read
  // it cannot await synchronously.
  private cachedSessionId: string | null = null;

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
    const record = await this.ctx.storage.get<SessionRecord>("state");
    if (record) this.cachedSessionId = record.session_id;
    return record;
  }

  private async saveRecord(record: SessionRecord): Promise<void> {
    this.cachedSessionId = record.session_id;
    await this.ctx.storage.put("state", record);
  }

  /** Milliseconds of stream idleness before the next `keepalive`. Falls back
   * to the compiled-in default for an absent or nonsensical binding rather
   * than trusting a value that would disable the keepalive entirely. */
  private keepaliveIntervalMs(): number {
    const raw = this.env.RELAY_KEEPALIVE_MS;
    if (raw === undefined) return KEEPALIVE_INTERVAL_MS;
    const parsed = Number(raw);
    if (!Number.isFinite(parsed) || parsed <= 0) return KEEPALIVE_INTERVAL_MS;
    return parsed;
  }

  /** The single writer for hmd's `GET /stream`. Returns false when the line
   * could not be delivered: no stream open, or a controller the runtime has
   * already torn down. That second case is the real one — Cloudflare can
   * close a long-lived chunked response without the stream's `cancel()` ever
   * running, leaving a controller whose `enqueue` throws; before this, that
   * throw escaped `webSocketMessage` and took the phone's frame with it. A
   * failed write drops the stale controller so the next `/stream` starts
   * clean, and deliberately does not re-arm the keepalive (nothing to write
   * to). A successful one restarts the idle timer, so a stream carrying real
   * frames never pays for a keepalive it does not need. */
  private writeToHmdStream(line: string): boolean {
    const controller = this.hmdStreamController;
    if (!controller) return false;
    try {
      controller.enqueue(new TextEncoder().encode(line));
    } catch {
      this.hmdStreamController = null;
      this.clearKeepalive();
      return false;
    }
    this.armKeepalive();
    return true;
  }

  /** Ends hmd's current `GET /stream` response, if any, and stops its
   * keepalive. Called when a reconnect supersedes an older stream and on
   * revoke — never on an ordinary drop, which leaves the session intact. */
  private closeHmdStream(): void {
    const controller = this.hmdStreamController;
    this.hmdStreamController = null;
    this.clearKeepalive();
    if (!controller) return;
    try {
      controller.close();
    } catch {
      // Already closed or errored (client gone, or a runtime-side
      // teardown) — the stream is over either way.
    }
  }

  /** (Re)starts the idle timer that writes the next `keepalive`. A no-op
   * with no stream open, which is also what ends the chain: the timer
   * re-arms only via `writeToHmdStream`, and only on a write that landed. */
  private armKeepalive(): void {
    this.clearKeepalive();
    const sessionId = this.cachedSessionId;
    if (!this.hmdStreamController || sessionId === null) return;
    this.keepaliveTimer = setTimeout(() => {
      this.keepaliveTimer = null;
      const payload: KeepalivePayload = { ts: Math.floor(Date.now() / 1000) };
      this.writeToHmdStream(
        JSON.stringify({
          v: 1,
          session_id: sessionId,
          seq: 0,
          sender: "relay",
          type: "keepalive",
          nonce: null,
          ciphertext: null,
          payload,
        }) + "\n"
      );
    }, this.keepaliveIntervalMs());
  }

  private clearKeepalive(): void {
    if (this.keepaliveTimer === null) return;
    clearTimeout(this.keepaliveTimer);
    this.keepaliveTimer = null;
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
   * JSON envelopes (device-originated `command` frames) up to hmd.
   *
   * Reopening this is routine, not exceptional: the stream is expected to be
   * cut periodically (see KEEPALIVE_INTERVAL_MS) and hmd reconnects with
   * backoff. A reconnect supersedes whatever stream was open before — that
   * one is closed here rather than left as a ReadableStream nobody will read
   * or finish. Dropping this leg never touches the session: the phone stays
   * bound and connected, and only `POST /revoke` (or pairing expiry before a
   * bind) ends things. */
  private async handleStream(request: Request): Promise<Response> {
    const record = await this.loadRecord();
    if (!record) return jsonResponse(404, { error: "session not found" });
    if (!this.checkBearer(request, record)) {
      return jsonResponse(401, { error: "missing or invalid bearer token" });
    }

    this.closeHmdStream();

    const owner = this;
    const generation = ++this.hmdStreamGeneration;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        owner.hmdStreamController = controller;
        const pending = owner.pendingHmdControlFrame;
        if (pending !== null) {
          owner.pendingHmdControlFrame = null;
          if (!owner.writeToHmdStream(pending)) owner.pendingHmdControlFrame = pending;
        }
        owner.armKeepalive();
      },
      cancel() {
        // Only tear down if this is still the live stream — a newer
        // /stream may already have replaced it, and the superseded
        // stream's cancel runs after that swap.
        if (owner.hmdStreamGeneration !== generation) return;
        owner.hmdStreamController = null;
        owner.clearKeepalive();
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
      return jsonResponse(413, { error: "frame exceeds 1 MiB limit" });
    }
    const bodyText = await request.text();
    if (new TextEncoder().encode(bodyText).byteLength > MAX_ENVELOPE_BYTES) {
      return jsonResponse(413, { error: "frame exceeds 1 MiB limit" });
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

    const target = this.liveDeviceSocket();
    if (!target) {
      logEvent("frame_undelivered", {
        session_id: record.session_id,
        reason: "no_device_connected",
      });
      return jsonResponse(200, { ok: true, delivered: false });
    }
    target.send(JSON.stringify(envelope));
    // Only now — with a frame actually on its way to a known-live socket —
    // is it safe to end the older ones. See supersedeOlderDeviceSockets.
    this.supersedeOlderDeviceSockets(target);
    return jsonResponse(200, { ok: true, delivered: true });
  }

  /** Every device socket still attached to this session, highest generation
   *  first. Re-derived from `getWebSockets` on every call — see
   *  `DeviceSocketAttachment` for why none of this may be cached on the
   *  instance. */
  private deviceSocketsNewestFirst(): { socket: WebSocket; gen: number }[] {
    return this.ctx
      .getWebSockets(DEVICE_TAG)
      .map((socket) => ({ socket, gen: deviceSocketGeneration(socket) }))
      .sort((a, b) => b.gen - a.gen);
  }

  /** The generation to stamp on the socket being accepted right now: one
   *  above every socket currently attached. A socket that has left the set
   *  can never rejoin it, so "highest still attached, plus one" is all the
   *  monotonicity the comparisons below need — and it costs no storage write
   *  on the connect path. */
  private nextDeviceGeneration(): number {
    let highest = 0;
    for (const { gen } of this.deviceSocketsNewestFirst()) {
      if (gen > highest) highest = gen;
    }
    return highest + 1;
  }

  /**
   * The device socket to deliver to: the newest one that is open.
   *
   * Two live failures are pinned here, and the second is why generations
   * exist at all.
   *
   * This was once `getWebSockets(DEVICE_TAG)[0]`, and that index is what
   * broke a phone that had reconnected. A phone losing Wi-Fi sends no close
   * frame and no TCP reset, so Cloudflare keeps the old socket for as long
   * as its own timeout takes — minutes — while the phone notices immediately
   * and reconnects with `?device_token=`. Every `state` frame then went to
   * `[0]`, the dead one, and `POST /frames` answered `delivered: true` for
   * all of them. Reproduced live against the deployed relay on 2026-09-24:
   * the reconnected socket sat open and silent for 22s while the superseded
   * one took seq 3,4,5,6,7.
   *
   * The fix for that closed *every* tagged socket on each accept, which
   * traded an intermittent failure for a permanent one: a second
   * `/ws?device_token=` upgrade that the app then discarded (a retry, a
   * relaunch racing two connects) closed the socket the app was actually
   * using. Its TCP stayed up, so the phone still showed `live` and still
   * pushed `command` frames up, while this set held nothing open and every
   * frame came back `delivered: false` from then on. Reproduced against a
   * local `wrangler dev` on 2026-09-24, where the in-Durable-Object trace
   * ended at an empty socket set with the phone leg still connected.
   *
   * So: rank by generation, not by position and not by `readyState` alone.
   * `getWebSockets`' ordering is undocumented and a superseded socket can sit
   * in CLOSING for minutes, but the generation says outright which socket the
   * phone connected last — and it says it just as well after a hibernation
   * wake, since it lives on the socket rather than on this instance.
   */
  private liveDeviceSocket(): WebSocket | undefined {
    return this.deviceSocketsNewestFirst().find(
      (entry) => entry.socket.readyState === WebSocket.OPEN
    )?.socket;
  }

  /**
   * Ends every device socket older than the one now known to be live — the
   * phone leg's counterpart to `closeHmdStream` (which `handleStream` has
   * always called for exactly this reason on hmd's leg): one session, one
   * live device socket, newest wins.
   *
   * Deliberately driven by delivery rather than by `acceptDeviceSocket`. An
   * accept only proves a socket was *offered*; a delivered frame proves which
   * socket is being used. Closing on the accept is what let a discarded
   * duplicate upgrade take the app's real socket down with it (see
   * `liveDeviceSocket`), and nothing needs it earlier: delivery already
   * refuses to target anything but the newest open socket, so a lingering
   * older one is untidy, never wrong.
   *
   * Close code 4002 is deliberately distinct from `handleRevoke`'s 4001 —
   * this session is emphatically NOT over, and a client that conflated the
   * two would stop reconnecting after a routine network change.
   */
  private supersedeOlderDeviceSockets(live: WebSocket): void {
    const liveGen = deviceSocketGeneration(live);
    for (const { socket, gen } of this.deviceSocketsNewestFirst()) {
      if (gen >= liveGen) continue;
      try {
        socket.close(4002, "superseded");
      } catch {
        // Already closing or gone — either way it is not the live socket
        // any more, which is all this needs to guarantee.
      }
    }
  }

  /** Phone leg: `GET /ws?pairing_code=...&device_pubkey=<base64url 32 bytes>`
   * (first claim) or `?device_token=...` (reconnect). Must be a real `wss://`
   * WebSocket upgrade — checked via Upgrade header presence and an explicit
   * plaintext-scheme signal (INV: "ws without wss -> 400"). `device_pubkey`
   * is validated only on the pairing_code path (handlePairingCodeClaim) —
   * a device_token reconnect already proves the phone bound previously, and
   * hmd already learned its pubkey the first time (INV-7/8: this query
   * string, including both credentials, is never logged). */
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
    const devicePubkey = url.searchParams.get("device_pubkey");
    return this.handlePairingCodeClaim(record, pairingCode as string, devicePubkey);
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
    pairingCode: string,
    devicePubkey: string | null
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

    if (!isValidDevicePubkey(devicePubkey)) {
      return jsonResponse(400, {
        error: `device_pubkey is required and must decode to ${DEVICE_PUBKEY_BYTES} bytes`,
      });
    }

    const nowS = Math.floor(now / 1000);
    const exp = nowS + DEVICE_TOKEN_TTL_S;
    const deviceToken = await mintDeviceToken(this.env.RELAY_SIGNING_SECRET, {
      session_id: record.session_id,
      role: "device",
      exp,
    });
    record.status = "bound";
    await this.saveRecord(record);

    return this.acceptDeviceSocket(
      record.session_id,
      { device_token: deviceToken, exp },
      { device_pubkey: devicePubkey, bound_at: nowS }
    );
  }

  private acceptDeviceSocket(
    sessionId: string,
    bindPayload?: DeviceBoundToPhonePayload,
    hmdControlPayload?: DeviceBoundToHmdPayload
  ): Response {
    // Newest device socket wins, and this is where "newest" is recorded:
    // one above every generation currently attached, written onto the socket
    // so `liveDeviceSocket` can rank it against the others without this
    // instance remembering anything (see DeviceSocketAttachment). Nothing
    // already attached is closed here — see supersedeOlderDeviceSockets for
    // why that has to wait for a delivered frame.
    const generation = this.nextDeviceGeneration();

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [DEVICE_TAG]);
    const attachment: DeviceSocketAttachment = { gen: generation };
    server.serializeAttachment(attachment);
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
    if (hmdControlPayload) {
      this.deliverToHmdStream(sessionId, hmdControlPayload);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Writes device_bound's hmd-facing payload (device_pubkey, bound_at) into
   * hmd's GET /stream as a plaintext control frame — the one frame this
   * relay ever buffers (see pendingHmdControlFrame's own comment): if hmd's
   * stream isn't open yet, this parks the encoded line until handleStream's
   * `start()` flushes it, rather than dropping it because no one is
   * currently listening (unlike a `state`/`command`/`ack` frame's fire-once
   * `/frames` semantics, this control frame's only delivery describes a
   * one-time event that already happened and must eventually reach hmd). */
  private deliverToHmdStream(sessionId: string, payload: DeviceBoundToHmdPayload): void {
    const line =
      JSON.stringify({
        v: 1,
        session_id: sessionId,
        seq: 0,
        sender: "relay",
        type: "device_bound",
        nonce: null,
        ciphertext: null,
        payload,
      }) + "\n";
    if (!this.writeToHmdStream(line)) {
      this.pendingHmdControlFrame = line;
    }
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
    // this Durable Object otherwise never ends on its own. A revoked session
    // is fully over — this is the ONLY path that ends it deliberately, and
    // the only one that stops the keepalive for good. An ordinary stream
    // drop must never come through here: hmd is expected back.
    this.closeHmdStream();

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

    if (this.writeToHmdStream(JSON.stringify(envelope) + "\n")) return;

    // hmd's stream is down (mid-reconnect, or gone). The frame is dropped,
    // not queued — the same fire-once semantics `POST /frames` reports as
    // `delivered: false` when the phone is absent (relay/README.md's "no
    // persisted frame buffering"). The phone's own `ack` timeout is what
    // surfaces this to the operator (INV-28); the relay does not invent a
    // retry path it has no test for.
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
