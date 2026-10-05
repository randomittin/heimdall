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
  SessionEndedPayload,
  SessionEndReason,
  Envelope,
} from "./types";
import { isDeviceFrame, isHmdFrame } from "./types";
import {
  jsonResponse,
  MAX_ENVELOPE_BYTES,
  SECURITY_HEADERS,
  isPlaintextUpgrade,
  isWebSocketUpgrade,
} from "./http";
import {
  generatePairingCode,
  generateSessionToken,
  recordAttempt,
  recordClaimAttempt,
  mintDeviceToken,
  verifyDeviceToken,
  timingSafeEqual,
  base64UrlDecode,
  PAIRING_CODE_TTL_S,
  CLAIM_THROTTLE_RETRY_AFTER_S,
  DEVICE_TOKEN_TTL_S,
  PAIR_INIT_MAX_PER_WINDOW,
  PAIR_INIT_WINDOW_MS,
  PAIR_INIT_RETRY_AFTER_S,
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
  /**
   * `exp` (epoch seconds) of the `device_token` minted at bind — the point
   * past which this session can no longer be reconnected to, and therefore the
   * point its storage is reclaimable (see `alarm`). Absent on a record written
   * before this field existed; such a session is never purged early, only
   * re-scheduled a full TTL out.
   */
  device_token_exp?: number;
}

const DEVICE_TAG = "device";
const DEVICE_PUBKEY_BYTES = 32;

/** Storage key for a session's record. */
const RECORD_KEY = "state";
/**
 * Storage key for a `/pair/init` throttle bucket. A bucket lives in its own
 * Durable Object instance (`idFromName("pair-init-throttle:<ip>")`, see
 * worker.ts) — the same class, never a session: the two key spaces are
 * disjoint and an instance only ever holds one of them.
 *
 * Reusing `SessionDO` rather than declaring a second class is deliberate. A
 * new class needs a `[[migrations]]` entry, and a migration on the deploy that
 * ships this hardening would put a live paired session at risk for no
 * behavioural gain — the Durable Object is just "one serialization point per
 * name", which is exactly what a per-IP counter needs.
 */
const PAIR_INIT_KEY = "pair_init_attempts";

/**
 * Persisted alongside the session record so the most recent hmd->device
 * `state` envelope survives this Durable Object being evicted and rebuilt —
 * the same durability need `DeviceSocketAttachment` documents for per-socket
 * generation, and for the same reason a class field would not do.
 */
interface StoredHmdState {
  envelope: Envelope;
  /** epoch ms, this relay's own clock at write time — used only to answer
   *  "did this predate the current bind" in loadReplayableHmdState below. */
  stored_at: number;
}

/** Storage key for the session's most recent hmd->device `state` envelope —
 *  see StoredHmdState and loadReplayableHmdState/storeLastHmdState below. */
const LAST_HMD_STATE_KEY = "last_hmd_state";

/**
 * Storage key for the one control frame the relay may have to hold for hmd: the
 * `device_bound` that carries the phone's public key, which a claim can
 * produce before hmd's `GET /stream` is open. Never more than one — a session
 * binds at most once, and handleDeviceTokenClaim's reconnect path never calls
 * deliverToHmdStream. Stored as the encoded NDJSON line, byte for byte what
 * handleStream later writes.
 *
 * This was a field on the instance. Nothing keeps the object resident while
 * hmd is away (only an open `GET /stream` does), so an eviction between the
 * claim and hmd connecting dropped the frame, and hmd — which derives its
 * session key from that frame alone — never completed the pairing.
 * test/hibernation.spec.ts reproduces it.
 */
const PENDING_HMD_CONTROL_KEY = "pending_hmd_control_frame";

/**
 * Grace added to a purge deadline so a client that is merely late — a phone
 * reconnecting seconds after its token lapsed, hmd re-reading a just-revoked
 * session — meets a truthful `410`/`401` rather than a bare `404` from a
 * record that has already been deleted.
 */
const PURGE_GRACE_MS = 60_000;

/** How long an `ended` session's record is kept before it is reclaimed. */
const ENDED_GRACE_MS = 5 * 60_000;

/**
 * WebSocket close codes this relay originates on the phone leg, alongside
 * `4001` (revoked) and `4002` (superseded) which predate this file's hardening
 * pass. Both below tell the app the same thing operationally — reconnect, and
 * the upgrade will answer honestly (`401` for a lapsed token, `410` for an
 * ended session) — rather than leaving it pushing frames into a socket the
 * relay has stopped serving.
 */
const CLOSE_SESSION_ENDED = 4001;
const CLOSE_TOKEN_EXPIRED = 4003;
/** RFC 6455's "message too big" — INV-16 on the phone leg. */
const CLOSE_MESSAGE_TOO_BIG = 1009;

/**
 * A rejected frame's `sender`/`type` are attacker-controlled and unbounded, so
 * only a value from the closed set is ever echoed into a log line; anything
 * else logs as `"other"`. Keeps a dropped frame diagnosable without letting it
 * write an arbitrary (or megabyte-long) string into the relay's logs.
 */
function loggableSender(value: unknown): string {
  return value === "hmd" || value === "device" || value === "relay" ? value : "other";
}

/** What hmd is told when storage reclamation is what ends its stream. A
 *  `pending` session reaching the purge is one whose pairing window lapsed
 *  unclaimed — the 2026-10-02 field case. */
function purgeEndReason(status: SessionStatus): SessionEndReason {
  if (status === "pending") return "pairing-expired";
  if (status === "bound") return "expired";
  return "ended";
}

function loggableType(value: unknown): string {
  return value === "state" ||
    value === "command" ||
    value === "ack" ||
    value === "device_bound" ||
    value === "session_ended" ||
    value === "keepalive"
    ? value
    : "other";
}

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
  /**
   * `exp` (epoch seconds) of the `device_token` this socket was admitted on.
   * INV-9 requires the token to be re-validated on every phone→relay request
   * post-bind rather than cached as "already trusted this connection"; a
   * socket that simply never drops would otherwise outlive its own token
   * indefinitely, turning a 30-day credential into an unbounded one (finding
   * 9). Stored on the socket, not on the instance, for the same reason `gen`
   * is: it has to survive the Durable Object being evicted underneath a
   * still-connected socket. Absent on a socket accepted before this field
   * existed — such a socket is served until it drops, since the relay has no
   * honest expiry to apply to it.
   */
  token_exp?: number;
  /**
   * The session this socket belongs to, so a freshly woken instance can name
   * the session in a log line written before it has read the record:
   * `cachedSessionId` is a field on `this`, and `this` is rebuilt on every
   * wake. Absent on a socket accepted before this field existed — such a line
   * falls back to the cached id, and to `"unknown"` when the instance has not
   * read the record yet either.
   */
  sid?: string;
}

/**
 * The generation of one device socket, or 0 for a socket accepted before this
 * attachment existed — a deploy rolling over live sessions leaves those
 * connected, and any socket accepted afterwards outranks them.
 *
 * Never throws: a malformed or absent attachment must degrade to "oldest
 * possible", never cost a frame.
 */
function deviceSocketAttachment(socket: WebSocket): Partial<DeviceSocketAttachment> {
  let attachment: unknown;
  try {
    attachment = socket.deserializeAttachment();
  } catch {
    return {};
  }
  if (typeof attachment !== "object" || attachment === null) return {};
  return attachment as Partial<DeviceSocketAttachment>;
}

function deviceSocketGeneration(socket: WebSocket): number {
  const gen = deviceSocketAttachment(socket).gen;
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

/**
 * The upper bound on how long a single `GET /stream` response may live,
 * however healthy it looks.
 *
 * Observed live on 2026-09-25, and the failure `KEEPALIVE_INTERVAL_MS` above
 * made possible. A deploy rolls this Durable Object to a new generation.
 * Hibernatable device sockets are re-delivered to that new generation, so
 * `POST /frames` keeps answering `delivered: true` and every operator-visible
 * signal reads healthy — but hmd's in-flight streaming Response stays pinned
 * to the OLD generation, whose `keepaliveTimer` keeps writing into it. hmd's
 * client bounds *silence* (`HMD_RELAY_STREAM_IDLE_S`, 60s) and that stream is
 * never silent, so it never reconnects, while the new generation — the one
 * holding the phone — has `hmdStreamController === null` and drops every
 * inbound `command` as `no_hmd_stream_connected`. Phone→hmd stays dead
 * indefinitely.
 *
 * Nothing outside that orphaned isolate can reach the response to close it:
 * the controller is in its memory, not in storage, and the generation now
 * serving the session has no handle to it. The only actor that can end it is
 * the stream itself, so every stream carries its own deadline. hmd treats a
 * closed stream as routine and reconnects with backoff (see `handleStream`),
 * which lands it on the live generation.
 *
 * 10 minutes bounds the post-deploy outage while costing one reconnect —
 * ~2s, hmd's `BACKOFF_BASE_MS` — per stream per 10 minutes.
 */
const MAX_STREAM_LIFETIME_MS = 10 * 60_000;

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
  // Bumped once per `GET /stream`, so a stream's own `cancel()` can tell
  // whether it is still the live one before tearing down shared state — a
  // reconnect installs its controller before the superseded stream's cancel
  // runs. Same generation guard as src/transport/RelayTransport.ts's
  // `gen !== this.generation` check on its socket callbacks.
  private hmdStreamGeneration = 0;
  private keepaliveTimer: ReturnType<typeof setTimeout> | null = null;
  // Deadline for the stream currently open, armed once per `GET /stream` and
  // never re-armed by traffic — unlike the keepalive, whose whole job is to
  // be pushed back. See MAX_STREAM_LIFETIME_MS.
  private streamLifetimeTimer: ReturnType<typeof setTimeout> | null = null;
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
      case "/throttle":
        return this.handlePairInitThrottle();
      default:
        return jsonResponse(404, { error: "not found" });
    }
  }

  private async loadRecord(): Promise<SessionRecord | undefined> {
    const record = await this.ctx.storage.get<SessionRecord>(RECORD_KEY);
    if (record) this.cachedSessionId = record.session_id;
    return record;
  }

  private async saveRecord(record: SessionRecord): Promise<void> {
    this.cachedSessionId = record.session_id;
    await this.ctx.storage.put(RECORD_KEY, record);
  }

  /**
   * Persists `envelope` as the session's most recent hmd->device `state`
   * frame, replacing whatever was stored before — one slot, newest always
   * wins, never a history. `envelope` is already under `MAX_ENVELOPE_BYTES`
   * by the time this is called (handleFrames enforces that first), and the
   * SQLite-backed Durable Object storage this project uses (wrangler.toml's
   * `new_sqlite_classes`) comfortably holds a value that size.
   *
   * Called from handleFrames on every valid `state` frame that reaches this
   * point, whether or not a device was there to receive it live: an
   * undelivered frame is the entire reason this exists (a phone reconnecting
   * with `?device_token=` used to get nothing until hmd's *next* digest
   * change — measured on device at ~170s), and a delivered one is stored
   * too, so a later reconnect is never replayed anything staler than the
   * last live delivery.
   */
  private async storeLastHmdState(envelope: Envelope): Promise<void> {
    const stored: StoredHmdState = { envelope, stored_at: Date.now() };
    await this.ctx.storage.put(LAST_HMD_STATE_KEY, stored);
  }

  /** Clears the stored last-`state` envelope. Called wherever a session ends
   *  (handleRevoke; handlePairingCodeClaim's expired-code and
   *  claim-throttle-exhausted paths, which also set status to "ended") —
   *  `alarm()`'s purge path needs no separate call, since its `deleteAll()`
   *  already wipes every key this or any other session ever wrote. */
  private async clearLastHmdState(): Promise<void> {
    await this.ctx.storage.delete(LAST_HMD_STATE_KEY);
  }

  /**
   * The stored last-`state` envelope eligible for replay to a freshly
   * accepted device socket, or undefined if nothing is stored or nothing
   * qualifies.
   *
   * Replaying it is safe even if the device already saw it: the app's
   * `open()` (src/relay/crypto.ts) rejects any envelope whose `seq` is <= the
   * last one it accepted from that sender *before* it ever attempts to
   * decrypt, so a replayed frame the app has already processed is silently
   * ignored, never double-applied (INV-14/INV-15). That is what makes an
   * unconditional resend on every accept correct, not merely convenient.
   *
   * `minStoredAtMs`, when given, excludes a frame stored strictly before it.
   * handlePairingCodeClaim is the only caller that passes it, with `now` from
   * the instant this claim started — the instant this device becomes bound.
   * INV-3 forbids relaying a `state`/`command` frame to an unclaimed
   * connection; a frame that reached `/frames` while this session was still
   * "pending" was necessarily stored before that instant, and replaying it
   * the moment the claim completes would relay pre-claim data to the newly
   * bound device — exactly what INV-3 forbids, even though the device has
   * since bound by the time of replay.
   *
   * hmd cannot derive a session key, and therefore cannot seal a real
   * `state` frame, before this very claim delivers `device_pubkey` to hmd's
   * own stream (see acceptDeviceSocket's `hmdControlPayload`) — so nothing
   * legitimate is ever actually eligible on this path. The check encodes
   * that reasoning in code rather than relying on hmd's client behaving, and
   * costs nothing on the reconnect path (handleDeviceTokenClaim), which
   * omits it: a reconnect is not a new bind, so whatever is stored was
   * written while this same device was already bound, and is always fair
   * game to resend.
   */
  private async loadReplayableHmdState(minStoredAtMs?: number): Promise<Envelope | undefined> {
    const stored = await this.ctx.storage.get<StoredHmdState>(LAST_HMD_STATE_KEY);
    if (!stored) return undefined;
    if (minStoredAtMs !== undefined && stored.stored_at < minStoredAtMs) return undefined;
    return stored.envelope;
  }

  /**
   * Internal contract, invoked only by worker.ts's `/pair/init` handler
   * against a per-IP instance — never reachable publicly (`throttle` is absent
   * from worker.ts's `PUBLIC_SESSION_SUBPATHS`, and an IP bucket's instance
   * name is not a UUID, so the public `/session/:id/*` route cannot address it
   * at all).
   *
   * Counts one attempt in a sliding window and reports whether it crossed the
   * bound. The bucket re-arms its own purge alarm on every call, so an IP that
   * stops calling reclaims its storage one window later instead of leaving a
   * row behind forever — the throttle must not itself become the unbounded
   * storage growth it exists to prevent.
   */
  private async handlePairInitThrottle(): Promise<Response> {
    const now = Date.now();
    const previous = (await this.ctx.storage.get<number[]>(PAIR_INIT_KEY)) ?? [];
    const { attempts, throttled } = recordAttempt(
      previous,
      now,
      PAIR_INIT_WINDOW_MS,
      PAIR_INIT_MAX_PER_WINDOW
    );
    await this.ctx.storage.put(PAIR_INIT_KEY, attempts);
    await this.ctx.storage.setAlarm(now + PAIR_INIT_WINDOW_MS + PURGE_GRACE_MS);
    return jsonResponse(200, { throttled });
  }

  /**
   * Schedules the next storage-reclamation pass. Last writer wins, deliberately:
   * every caller is a state transition that knows its own correct deadline —
   * a bind pushes the deadline out to the device token's expiry, an end pulls
   * it in to a short grace — and `alarm()` re-derives from the record anyway,
   * so an alarm that fires early only costs one re-schedule.
   */
  private async armPurgeAlarm(atMs: number): Promise<void> {
    await this.ctx.storage.setAlarm(atMs);
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

  /** Milliseconds a single `GET /stream` may live. Same fail-safe parse as
   * `keepaliveIntervalMs`: an absent or nonsensical binding falls back to the
   * compiled-in default rather than disabling the bound that keeps an
   * orphaned stream from outliving a deploy. */
  private streamMaxLifetimeMs(): number {
    const raw = this.env.RELAY_STREAM_MAX_LIFETIME_MS;
    if (raw === undefined) return MAX_STREAM_LIFETIME_MS;
    const parsed = Number(raw);
    if (!Number.isFinite(parsed) || parsed <= 0) return MAX_STREAM_LIFETIME_MS;
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
      this.clearStreamLifetime();
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
    this.clearStreamLifetime();
    if (!controller) return;
    try {
      controller.close();
    } catch {
      // Already closed or errored (client gone, or a runtime-side
      // teardown) — the stream is over either way.
    }
  }

  /**
   * Ends hmd's `GET /stream` because the SESSION is over, and says why first
   * (INV-38): a plaintext `session_ended` control frame — the shape
   * `handleRevoke` already sends the phone, and one hmd's client already reads
   * as terminal, logging `payload.reason` — then the close.
   *
   * Before this, a session the relay ended closed hmd's stream with a bare
   * EOF, and the next thing hmd met was `404` from the purged record. On
   * 2026-10-02 that read, twice, as "the relay's own stream-lifetime bound":
   * it was the pairing-expiry purge, 120s after `/pair/init`, of a session no
   * phone ever bound.
   *
   * Not for a close that leaves the session alive — a superseding reconnect
   * and the stream-lifetime bound go through `closeHmdStream` alone, since
   * hmd is expected back — nor for `POST /revoke`, where hmd is the one ending
   * it. With no stream attached there is nobody to tell: nothing is logged.
   */
  private endHmdStream(sessionId: string, reason: SessionEndReason): void {
    if (this.hmdStreamController !== null) {
      const payload: SessionEndedPayload = { reason };
      const told = this.writeToHmdStream(
        JSON.stringify({
          v: 1,
          session_id: sessionId,
          seq: 0,
          sender: "relay",
          type: "session_ended",
          nonce: null,
          ciphertext: null,
          payload,
        }) + "\n"
      );
      logEvent("session_end_announced", { session_id: sessionId, reason, delivered: told });
    }
    this.closeHmdStream();
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

  /** Arms the deadline for the stream at `generation`. The generation guard
   * is the same one `handleStream`'s `cancel()` uses and matters for the same
   * reason: this timer must never end a stream that has already superseded
   * the one that armed it. Cutting hmd off early would be a worse bug than
   * the orphaned stream this bounds. */
  private armStreamLifetime(generation: number): void {
    this.clearStreamLifetime();
    this.streamLifetimeTimer = setTimeout(() => {
      this.streamLifetimeTimer = null;
      if (this.hmdStreamGeneration !== generation) return;
      logEvent("stream_lifetime_expired", {
        session_id: this.cachedSessionId ?? "unknown",
      });
      this.closeHmdStream();
    }, this.streamMaxLifetimeMs());
  }

  private clearStreamLifetime(): void {
    if (this.streamLifetimeTimer === null) return;
    clearTimeout(this.streamLifetimeTimer);
    this.streamLifetimeTimer = null;
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
    // An unclaimed session is the cheap half of the abuse case in finding 7:
    // one Durable Object with a persistent row per `/pair/init`, previously
    // with no reaping path at all. Arm the reclamation pass now, while this is
    // the only thing that has ever written to this instance.
    await this.armPurgeAlarm(record.pair_exp + PURGE_GRACE_MS);
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

    // Read ahead of the swap below, so nothing is awaited between closing the
    // old stream and installing the new one.
    const pending = await this.ctx.storage.get<string>(PENDING_HMD_CONTROL_KEY);

    this.closeHmdStream();

    const owner = this;
    const generation = ++this.hmdStreamGeneration;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        owner.hmdStreamController = controller;
        owner.armKeepalive();
        owner.armStreamLifetime(generation);
      },
      cancel() {
        // Only tear down if this is still the live stream — a newer
        // /stream may already have replaced it, and the superseded
        // stream's cancel runs after that swap.
        if (owner.hmdStreamGeneration !== generation) return;
        owner.hmdStreamController = null;
        owner.clearKeepalive();
        owner.clearStreamLifetime();
      },
    });
    // The `device_bound` held while hmd's stream was down goes out first, and
    // leaves storage only once it has actually been written: a write that
    // failed keeps it for the next stream.
    if (pending !== undefined && this.writeToHmdStream(pending)) {
      await this.ctx.storage.delete(PENDING_HMD_CONTROL_KEY);
    }
    return new Response(stream, {
      status: 200,
      headers: { "content-type": "application/x-ndjson", ...SECURITY_HEADERS },
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
    // Provenance, not just shape (finding 1). hmd's bearer token authorises it
    // to speak *as hmd*, and nothing more: a `sender:"relay"` control frame or
    // a `sender:"device"` frame posted here would be forwarded to the phone as
    // if the relay or the phone's peer had sent it. `state` and `ack` are the
    // only frames hmd originates.
    if (!isHmdFrame(envelope)) {
      const rejected = envelope as Record<string, unknown>;
      logEvent("frame_rejected", {
        session_id: record.session_id,
        leg: "hmd",
        reason: "sender_or_type_not_hmd_originated",
        frame_sender: loggableSender(rejected.sender),
        frame_type: loggableType(rejected.type),
      });
      return jsonResponse(400, { error: "invalid envelope" });
    }

    // The session's most recent state snapshot, kept for a device that
    // connects (or reconnects) with nobody currently there to receive it
    // live — see storeLastHmdState. Stored regardless of what happens next:
    // whether or not a device socket is open right now, this is the frame a
    // device should see the moment one next connects.
    if (envelope.type === "state") {
      await this.storeLastHmdState(envelope);
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

    const devicePubkey = url.searchParams.get("device_pubkey");
    if (deviceToken) {
      return this.handleDeviceTokenClaim(record, deviceToken, devicePubkey);
    }
    return this.handlePairingCodeClaim(record, pairingCode as string, devicePubkey);
  }

  /**
   * Reconnect path. `device_pubkey` is now read here too: a token minted since
   * the finding-6 fix carries the claiming device's public key in its signed
   * claims, and `verifyDeviceToken` refuses the reconnect unless the same key
   * is re-presented — so an exfiltrated token is useless to a holder who
   * cannot also present the bound key.
   *
   * A token minted *before* that change carries no such claim and is accepted
   * with or without the query param, unbound, until its own expiry. That
   * tolerance is mandatory, not cosmetic: a phone paired before the deploy has
   * no way to obtain a bound token except a physical re-scan of a QR that
   * nobody is standing in front of.
   */
  private async handleDeviceTokenClaim(
    record: SessionRecord,
    deviceToken: string,
    devicePubkey: string | null
  ): Promise<Response> {
    const claims = await verifyDeviceToken(
      this.env.RELAY_SIGNING_SECRET,
      deviceToken,
      record.session_id,
      Date.now(),
      devicePubkey
    );
    if (!claims) return jsonResponse(401, { error: "invalid device token" });
    if (record.status === "ended") {
      return jsonResponse(410, { error: "session ended" });
    }
    // The fix this feature exists for: without this, a phone reconnecting
    // here got nothing until hmd's next digest change — see
    // loadReplayableHmdState for why replaying it unconditionally is safe.
    const replayEnvelope = await this.loadReplayableHmdState();
    return this.acceptDeviceSocket(
      record.session_id,
      claims.exp,
      undefined,
      undefined,
      replayEnvelope
    );
  }

  /**
   * The relay ends a session no phone ever bound: a late claim found the
   * pairing window lapsed, or the claim throttle tripped (INV-4). Both used to
   * flip the status and tell hmd nothing, leaving it holding a stream for a
   * session that could never bind until the purge closed it bare. The record
   * stays `ENDED_GRACE_MS` so a late phone meets a truthful `410`; hmd is told
   * now, not then.
   */
  private async endUnboundSession(
    record: SessionRecord,
    reason: "pairing-expired" | "claim-throttled"
  ): Promise<void> {
    record.status = "ended";
    await this.saveRecord(record);
    await this.clearLastHmdState();
    await this.armPurgeAlarm(Date.now() + ENDED_GRACE_MS);
    this.endHmdStream(record.session_id, reason);
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
      await this.endUnboundSession(record, "pairing-expired");
      return jsonResponse(410, { error: "pairing code expired" });
    }

    const { attempts, throttled } = recordClaimAttempt(record.claim_attempts, now);
    record.claim_attempts = attempts;
    if (throttled) {
      await this.endUnboundSession(record, "claim-throttled");
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
    // `device_pubkey` goes into the signed claims, so the token is only usable
    // by the device that claimed the code (finding 6). It is the same
    // base64url string the phone sent and hmd is about to receive — the relay
    // never re-encodes it anywhere on this path.
    const deviceToken = await mintDeviceToken(this.env.RELAY_SIGNING_SECRET, {
      session_id: record.session_id,
      role: "device",
      exp,
      device_pubkey: devicePubkey,
    });
    record.status = "bound";
    record.device_token_exp = exp;
    await this.saveRecord(record);
    // The session is now reachable for as long as that token is valid, so the
    // reclamation deadline moves out to match it.
    await this.armPurgeAlarm(exp * 1000 + PURGE_GRACE_MS);

    // See loadReplayableHmdState's own comment: provably never eligible here
    // (hmd cannot have sealed a `state` frame before this exact claim hands
    // it device_pubkey) — but the check is a real comparison against `now`,
    // not a hardcoded skip, so it stays correct if that ever changes.
    const replayEnvelope = await this.loadReplayableHmdState(now);

    return this.acceptDeviceSocket(
      record.session_id,
      exp,
      { device_token: deviceToken, exp },
      { device_pubkey: devicePubkey, bound_at: nowS },
      replayEnvelope
    );
  }

  private async acceptDeviceSocket(
    sessionId: string,
    tokenExp: number,
    bindPayload?: DeviceBoundToPhonePayload,
    hmdControlPayload?: DeviceBoundToHmdPayload,
    replayEnvelope?: Envelope
  ): Promise<Response> {
    // hmd's half goes first because it is the one step here that can fail (a
    // storage write, when hmd's stream is down). Failing after the socket was
    // accepted would leave one the phone never received — a ghost that
    // `liveDeviceSocket` ranks newest and delivers hmd's frames into.
    if (hmdControlPayload) {
      await this.deliverToHmdStream(sessionId, hmdControlPayload);
    }

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
    const attachment: DeviceSocketAttachment = {
      gen: generation,
      token_exp: tokenExp,
      sid: sessionId,
    };
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
    if (replayEnvelope) {
      // Always after device_bound, never before: a frame sealed under a
      // session key the app derives only once it has processed device_bound
      // cannot yet be opened by a socket that has not seen device_bound. On
      // a reconnect (bindPayload absent) there is no such ordering
      // constraint — the app has been bound since its original claim.
      server.send(JSON.stringify(replayEnvelope));
      logEvent("state_replayed", { session_id: sessionId, seq: replayEnvelope.seq });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Writes device_bound's hmd-facing payload (device_pubkey, bound_at) into
   * hmd's GET /stream as a plaintext control frame — the one frame this
   * relay ever holds back (see PENDING_HMD_CONTROL_KEY): if hmd's stream
   * isn't open yet, this parks the encoded line in storage until
   * handleStream flushes it, rather than dropping it because no one is
   * currently listening (unlike a `state`/`command`/`ack` frame's fire-once
   * `/frames` semantics, this control frame's only delivery describes a
   * one-time event that already happened and must eventually reach hmd). In
   * storage rather than memory because nothing keeps this object resident
   * while hmd is away. */
  private async deliverToHmdStream(
    sessionId: string,
    payload: DeviceBoundToHmdPayload
  ): Promise<void> {
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
      await this.ctx.storage.put(PENDING_HMD_CONTROL_KEY, line);
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
    await this.clearLastHmdState();
    // An ended session is dead weight, but not instantly: the grace keeps the
    // record long enough that a phone reconnecting right after the revoke gets
    // a truthful 410 rather than a 404 that reads like "wrong session id".
    await this.armPurgeAlarm(Date.now() + ENDED_GRACE_MS);

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

  /**
   * The phone leg's inbound path — and, before the 2026-09-24 audit, the
   * relay's single most dangerous line: it re-serialized anything that passed
   * a *structural* check straight into hmd's stream. Four gates now stand
   * between a phone socket and that stream, in cost order.
   */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;

    // Per-socket state, read once: the session id for the log lines below that
    // are written before the record is read (see DeviceSocketAttachment.sid —
    // a freshly woken instance has no cached id), and the token expiry for
    // gate 4.
    const attachment = deviceSocketAttachment(ws);
    const sessionId =
      typeof attachment.sid === "string" ? attachment.sid : (this.cachedSessionId ?? "unknown");

    // 1. INV-16, the half that was only ever enforced on `POST /frames`
    //    (finding 8). Checked before `JSON.parse` so an oversize message is
    //    never parsed, and length-first so the encode below is itself bounded:
    //    UTF-8 is never fewer bytes than characters, so a string longer than
    //    the cap is over it regardless of contents.
    if (
      message.length > MAX_ENVELOPE_BYTES ||
      new TextEncoder().encode(message).byteLength > MAX_ENVELOPE_BYTES
    ) {
      logEvent("frame_rejected", {
        session_id: sessionId,
        leg: "device",
        reason: "envelope_exceeds_size_cap",
      });
      this.closeDeviceSocket(ws, CLOSE_MESSAGE_TOO_BIG, "frame exceeds size cap");
      return;
    }

    let envelope: unknown;
    try {
      envelope = JSON.parse(message);
    } catch {
      return;
    }

    // 2. Provenance (finding 1). `command` is the only frame a device
    //    originates; `sender:"relay"` control frames forwarded from here were
    //    a full end-to-end break, since hmd re-derives its session key from
    //    any `device_bound` it reads off its stream.
    if (!isDeviceFrame(envelope)) {
      const rejected = envelope as Record<string, unknown>;
      logEvent("frame_rejected", {
        session_id: sessionId,
        leg: "device",
        reason: "sender_or_type_not_device_originated",
        frame_sender: loggableSender(rejected.sender),
        frame_type: loggableType(rejected.type),
      });
      return;
    }

    // 3. INV-9/INV-10 (finding 9): the session's current state, re-read per
    //    frame rather than cached as "this connection was trusted at upgrade".
    //    A `close()` that threw or raced — `handleRevoke`'s catch swallows one
    //    — otherwise leaves a socket whose frames are still forwarded.
    const record = await this.loadRecord();
    if (!record || record.status !== "bound") {
      logEvent("frame_rejected", {
        session_id: record?.session_id ?? sessionId,
        leg: "device",
        reason: "session_not_bound",
      });
      this.closeDeviceSocket(ws, CLOSE_SESSION_ENDED, "session ended");
      return;
    }

    // 4. And the token's own expiry, which nothing re-checked once a socket
    //    was open: a phone that never drops would have kept a 30-day
    //    credential working indefinitely.
    const tokenExp = attachment.token_exp;
    if (typeof tokenExp === "number" && Date.now() / 1000 > tokenExp) {
      logEvent("frame_rejected", {
        session_id: record.session_id,
        leg: "device",
        reason: "device_token_expired",
      });
      this.closeDeviceSocket(ws, CLOSE_TOKEN_EXPIRED, "device token expired");
      return;
    }

    if (this.writeToHmdStream(JSON.stringify(envelope) + "\n")) return;

    // hmd's stream is down (mid-reconnect, or gone). The frame is dropped,
    // not queued — the same fire-once semantics `POST /frames` reports as
    // `delivered: false` when the phone is absent (relay/README.md's "no
    // persisted frame buffering"). The phone's own `ack` timeout is what
    // surfaces this to the operator (INV-28); the relay does not invent a
    // retry path it has no test for.
    logEvent("frame_undelivered", {
      session_id: record.session_id,
      reason: "no_hmd_stream_connected",
    });
  }

  /** Ends a device socket the relay has decided to stop serving. Never throws
   * past this boundary: a socket already closing or gone is exactly the state
   * the caller wanted, and a throw here would take its `return` with it. */
  private closeDeviceSocket(socket: WebSocket, code: number, reason: string): void {
    try {
      socket.close(code, reason);
    } catch {
      // Already closing or gone — the frame is dropped either way.
    }
  }

  /**
   * Storage reclamation (finding 7). Before this, `SessionDO` wrote its record
   * at bind and deleted it on no path at all — not on revoke, not on pairing
   * expiry — so every `/pair/init`, including one from an unauthenticated
   * abuse loop, left a persistent row behind forever.
   *
   * Three deadlines, re-derived from the record on every pass rather than
   * trusted from whenever the alarm was set:
   * - unclaimed → purge once the pairing window plus grace has passed;
   * - bound → keep until the `device_token` that could reconnect it expires;
   * - ended → purge, the short grace having been the alarm's own schedule.
   *
   * A Durable Object instance holding a `/pair/init` throttle bucket rather
   * than a session has no record, and falls through to the same `deleteAll`.
   */
  async alarm(): Promise<void> {
    const record = await this.ctx.storage.get<SessionRecord>(RECORD_KEY);
    const now = Date.now();

    if (record) {
      if (record.status === "bound") {
        const expMs = (record.device_token_exp ?? 0) * 1000;
        // A record written before `device_token_exp` existed gives no honest
        // deadline, so it gets a full TTL from now rather than an early purge
        // — a live paired phone must never lose its session to this pass.
        if (expMs === 0) {
          await this.armPurgeAlarm(now + DEVICE_TOKEN_TTL_S * 1000);
          return;
        }
        if (now < expMs) {
          await this.armPurgeAlarm(expMs + PURGE_GRACE_MS);
          return;
        }
      } else if (record.status === "pending" && now <= record.pair_exp) {
        await this.armPurgeAlarm(record.pair_exp + PURGE_GRACE_MS);
        return;
      }

      logEvent("session_purged", { session_id: record.session_id, status: record.status });
      for (const socket of this.ctx.getWebSockets(DEVICE_TAG)) {
        this.closeDeviceSocket(socket, CLOSE_SESSION_ENDED, "session ended");
      }
      // hmd is told why before its stream goes (INV-38). Without it, a session
      // nobody bound ended as a bare EOF followed by a 404 — see endHmdStream.
      this.endHmdStream(record.session_id, purgeEndReason(record.status));
    }

    await this.ctx.storage.deleteAll();
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
