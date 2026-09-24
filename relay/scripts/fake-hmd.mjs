#!/usr/bin/env node
// Plays the laptop (hmd) side of the relay protocol against a real deployed
// relay, for interop/dev testing (delta brief `hmdapp-fake-hmd-cli`). Not
// part of the app or the relay Worker -- a standalone dev tool, same
// "plain-Node script under relay/scripts/" family as check-no-logged-urls.mjs
// and trace-diff.mjs.
//
// Usage:
//   node relay/scripts/fake-hmd.mjs --relay <https://...> [--state <path>] [--phone-pubkey <base64>]
//
// Flow (spec: docs/superpowers/specs/2026-09-21-hmd-relay-design.md §2.1-2.3;
// invariants: docs/superpowers/specs/relay/INVARIANTS.md INV-11..25):
//   1. POST /pair/init
//   2. generate an X25519 keypair (relay/scripts/lib/relay-crypto.mjs)
//   3. print the QR/pairing payload as one JSON line on stdout
//   4. open GET /session/:id/stream (Bearer)
//   5. wait for a `device_bound` frame
//   6. derive the session key from the phone's pubkey, which the relay now
//      forwards in device_bound's payload (relay/src/session.ts
//      deliverToHmdStream); --phone-pubkey remains as a manual override for
//      testing without a real phone client
//   7. seal + POST a `state` envelope (the --state file) every 5s
//   8. decrypt incoming `command` envelopes, print send-message text to
//      stderr as `[phone] <text>`, POST an `ack` envelope back
//   9. on Ctrl-C, POST /revoke before exiting
//
// Tokens (`relay_session_token`, `device_token`) are never passed to
// console.log/console.error/Error -- grep this file for
// `relay_session_token` and `device_token`: both appear only as object keys
// destructured straight into a fetch Authorization header, never
// interpolated into any logged string (hmdapp CLAUDE.md "Never log tokens").
import { readFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Readable } from 'node:stream';
import {
  generateEphemeralKeyPair,
  deriveSessionKey,
  seal,
  open,
  RelayCryptoError,
} from './lib/relay-crypto.mjs';
import { encodeHmdEnvelope, decodeEnvelope, base64Encode, base64UrlDecode } from './lib/envelope.mjs';

const HERE = fileURLToPath(new URL('.', import.meta.url)); // .../relay/scripts/
const REPO_ROOT = join(HERE, '..', '..');
const DEFAULT_STATE_RELATIVE_PATH = 'docs/samples/state.json';
const STATE_SEND_INTERVAL_MS = 5000;

/** Reconnect ladder for the hmd-leg `GET /stream`. Cloudflare closes a
 *  long-lived chunked response that sits idle -- observed live on
 *  2026-09-24, a stream cut 5m01s after opening -- so a dropped stream is
 *  the normal steady state of a quiet session, not a failure. Base/cap
 *  mirror `src/transport/DirectTransport.ts`'s shape (INV-26); the base is
 *  1s rather than that leg's 2s because this drop is an expected periodic
 *  cut, not a sign the peer is unwell. */
export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_CAP_MS = 30000;

/** Next delay in the ladder: doubles `previousMs` up to the cap. An absent
 *  or nonsensical previous delay floors at the base rather than producing a
 *  NaN wait that would never fire. */
export function nextBackoffMs(previousMs) {
  if (!Number.isFinite(previousMs) || previousMs < BACKOFF_BASE_MS) return BACKOFF_BASE_MS;
  return Math.min(previousMs * 2, BACKOFF_CAP_MS);
}

/** A stream failure that reconnecting cannot fix -- a rejected bearer. Thrown
 *  past `runStreamWithReconnect` to `main`'s fatal handler, unlike an
 *  ordinary drop, which is retried. */
export class FatalStreamError extends Error {
  constructor(message) {
    super(message);
    this.name = 'FatalStreamError';
  }
}

/**
 * Runs `runOnce` for as long as the session lives, reconnecting with backoff
 * whenever the stream drops.
 *
 * `runOnce(isReconnect)` resolves to:
 *   - `'session-ended'`  the relay ended the session -- terminal, returned.
 *   - `'closed'`         the stream opened and later closed -- retry, and
 *                        reset the ladder, since the connection itself was
 *                        healthy (an every-5-minutes cut must not creep the
 *                        delay up to 30s over a long session).
 *   - `'open-failed'`    the stream never opened -- retry, escalating.
 * It may throw: a `FatalStreamError` propagates, anything else is retried
 * (undici raises a bare `TypeError('terminated')` for a cut response body).
 *
 * `sleep`/`isStopped` are injected rather than reached for directly so the
 * loop is testable without a real clock or a real relay -- the same seam
 * `src/transport/RelayTransport.ts` opens with its `createWebSocket` factory.
 */
export async function runStreamWithReconnect({ runOnce, sleep, isStopped }) {
  let delayMs = BACKOFF_BASE_MS;
  let isReconnect = false;

  while (!isStopped()) {
    let outcome;
    try {
      outcome = await runOnce(isReconnect);
    } catch (err) {
      if (err instanceof FatalStreamError) throw err;
      outcome = 'closed';
    }
    if (outcome === 'session-ended') return 'session-ended';
    if (outcome === 'closed') delayMs = BACKOFF_BASE_MS;
    if (isStopped()) break;

    await sleep(delayMs);
    delayMs = nextBackoffMs(delayMs);
    isReconnect = true;
  }
  return 'stopped';
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const USAGE = `Usage: node relay/scripts/fake-hmd.mjs --relay <https://...> [--state <path>] [--phone-pubkey <base64url>]

  --relay <url>               relay base URL, e.g. https://hmd-relay.therishabh16.workers.dev
  --state <path>               sample state JSON to send (default: ${DEFAULT_STATE_RELATIVE_PATH},
                               resolved from the repo root regardless of cwd)
  --phone-pubkey <base64url>   override the phone's X25519 public key instead of using
                               the one the relay forwards in device_bound's payload
                               (see relay/README.md's "fake-hmd.mjs" section)
  --help, -h                   print this message
`;

export function parseArgs(argv) {
  const args = { relay: undefined, state: undefined, phonePubkey: undefined, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
      continue;
    }
    if (arg === '--relay') {
      args.relay = requireValue(argv, i, '--relay');
      i += 1;
      continue;
    }
    if (arg === '--state') {
      args.state = requireValue(argv, i, '--state');
      i += 1;
      continue;
    }
    if (arg === '--phone-pubkey') {
      args.phonePubkey = requireValue(argv, i, '--phone-pubkey');
      i += 1;
      continue;
    }
    throw new Error(`unrecognized argument: ${arg}`);
  }
  if (!args.help && !args.relay) {
    throw new Error('--relay <url> is required');
  }
  return args;
}

function requireValue(argv, i, flag) {
  const value = argv[i + 1];
  if (value === undefined) throw new Error(`${flag} requires a value`);
  return value;
}

export function resolveStatePath(stateArg) {
  const rel = stateArg ?? DEFAULT_STATE_RELATIVE_PATH;
  return isAbsolute(rel) ? rel : join(REPO_ROOT, rel);
}

/** Decodes the plaintext (post-`open`) body of a `command` frame. Mirrors
 *  src/relay/protocol.ts's `SendMessageCommand` shape and its
 *  `decodeAckPayload`'s fail-closed house style -- protocol.ts itself has no
 *  decoder for this direction since the phone only ever encodes it. */
export function decodeSendMessageCommand(bytes) {
  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
  if (parsed.action !== 'send-message') return null;
  const { params } = parsed;
  if (typeof params !== 'object' || params === null || Array.isArray(params)) return null;
  if (typeof params.text !== 'string') return null;
  return { action: 'send-message', params: { text: params.text } };
}

/** Builds the plaintext (pre-`seal`) body of an `ack` frame (INV-24). */
export function buildAckPayload(ofSeq, ok, detail) {
  return JSON.stringify(detail === undefined ? { of_seq: ofSeq, ok } : { of_seq: ofSeq, ok, detail });
}

/** Resolves the phone's X25519 pubkey for a device_bound frame: an explicit
 *  --phone-pubkey override always wins (useful for testing without a real
 *  phone client); otherwise falls back to the pubkey the relay forwards in
 *  the frame's own payload (relay/src/session.ts's deliverToHmdStream).
 *  Returns null if neither is present -- the caller treats that as fatal. */
export function resolvePhonePubkey(envelope, phonePubkeyArg) {
  const overridePub = phonePubkeyArg ? base64UrlDecode(phonePubkeyArg) : null;
  const payloadPub =
    envelope.payload && typeof envelope.payload.device_pubkey === 'string'
      ? base64UrlDecode(envelope.payload.device_pubkey)
      : null;
  return overridePub ?? payloadPub;
}

async function readJsonOrNull(res) {
  try {
    return await res.json();
  } catch {
    return null;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(USAGE);
    return;
  }

  const statePath = resolveStatePath(args.state);
  const stateJsonText = readFileSync(statePath, 'utf8');
  JSON.parse(stateJsonText); // fail fast on a bad --state file, before burning a pairing code

  const relayBase = args.relay.replace(/\/+$/, '');

  // Step 1: POST /pair/init (unauthenticated -- INV-5).
  const initRes = await fetch(`${relayBase}/pair/init`, { method: 'POST' });
  if (!initRes.ok) {
    const body = await readJsonOrNull(initRes);
    throw new Error(`POST /pair/init failed: HTTP ${initRes.status} ${body ? JSON.stringify(body) : ''}`);
  }
  // relay_session_token is destructured here and used ONLY inside the
  // Authorization headers below -- never logged.
  const { session_id: sessionId, pairing_code: pairingCode, relay_session_token: relaySessionToken, exp } =
    await initRes.json();

  // Step 2: generate hmd's ephemeral X25519 keypair.
  const keyPair = generateEphemeralKeyPair();

  // Step 3: print the pairing payload as one JSON line (src/store/relayPayload.ts's shape).
  const pairingPayload = {
    v: 1,
    relay: relayBase,
    session_id: sessionId,
    pairing_code: pairingCode,
    exp,
    hmd_pubkey: base64Encode(keyPair.publicKey),
  };
  console.log(JSON.stringify(pairingPayload));
  console.error(
    '[fake-hmd] QR printing skipped: correct QR encoding needs Reed-Solomon GF(256) ECC plus ' +
      'finder/alignment/timing pattern placement and BCH format/version info -- not achievable ' +
      'correctly in a small dependency-free encoder. Scan/paste is not available from this tool; ' +
      'use the JSON line above directly. See relay/README.md.'
  );

  let stopped = false;
  let revoked = false;
  async function revoke() {
    if (revoked) return;
    revoked = true;
    try {
      await fetch(`${relayBase}/session/${sessionId}/revoke`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${relaySessionToken}` },
      });
      console.error('[fake-hmd] revoked');
    } catch (err) {
      console.error(`[fake-hmd] revoke request failed: ${err.message}`);
    }
  }
  process.on('SIGINT', () => {
    stopped = true;
    console.error('[fake-hmd] SIGINT received, revoking session...');
    revoke().finally(() => process.exit(0));
  });

  let sessionKey = null;
  let hmdSeq = 0;
  let lastPhoneSeq = 0;
  let stateTimer = null;
  let sendChain = Promise.resolve();

  function enqueueSend(fn) {
    // Serializes every POST /frames this process makes so two concurrent
    // sends (the 5s state timer and an in-response ack) can never resolve
    // out of the seq order they were assigned in -- INV-14 requires a
    // strictly increasing seq per sender, and a receiver that sees a lower
    // seq arrive after a higher one will reject it as a replay.
    sendChain = sendChain.then(fn, fn);
    return sendChain;
  }

  async function sendEnvelope(type, plaintext) {
    hmdSeq += 1;
    const sealed = seal(sessionKey, 'hmd', hmdSeq, plaintext);
    const body = encodeHmdEnvelope({ sessionId, seq: sealed.seq, type, ciphertext: sealed.ciphertext });
    try {
      const res = await fetch(`${relayBase}/session/${sessionId}/frames`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${relaySessionToken}`, 'content-type': 'application/json' },
        body,
      });
      if (!res.ok) {
        console.error(`[fake-hmd] POST /frames failed for ${type} seq=${sealed.seq}: HTTP ${res.status}`);
        return;
      }
      const parsed = await readJsonOrNull(res);
      if (parsed && parsed.delivered === false) {
        console.error(`[fake-hmd] ${type} seq=${sealed.seq} not delivered (no phone connected)`);
      }
    } catch (err) {
      console.error(`[fake-hmd] POST /frames error for ${type} seq=${sealed.seq}: ${err.message}`);
    }
  }

  function sendState() {
    return enqueueSend(() => sendEnvelope('state', new TextEncoder().encode(stateJsonText)));
  }

  function sendAck(ofSeq, ok, detail) {
    return enqueueSend(() =>
      sendEnvelope('ack', new TextEncoder().encode(buildAckPayload(ofSeq, ok, detail)))
    );
  }

  function bindSessionKey(phonePub) {
    sessionKey = deriveSessionKey(keyPair.secretKey, phonePub, sessionId);
    console.error('[fake-hmd] device bound, session key derived');
    stateTimer = setInterval(() => {
      sendState();
    }, STATE_SEND_INTERVAL_MS);
    sendState();
  }

  /** Handles one NDJSON line off the stream. Returns 'session-ended' when
   *  the relay says the session is over, otherwise null. The session key,
   *  seq counters and state timer all live outside this (and outside
   *  streamOnce below), so they survive a reconnect intact -- `device_bound`
   *  fires once per session and is never re-sent on a stream reopen. */
  async function handleLine(line) {
    const envelope = decodeEnvelope(line);
    if (envelope === null) {
      console.error('[fake-hmd] dropped malformed stream line');
      return null;
    }

    if (envelope.type === 'keepalive') {
      // Relay-originated liveness filler on an otherwise-idle stream
      // (relay/src/session.ts's KEEPALIVE_INTERVAL_MS). Carries no session
      // state -- read and discarded, deliberately not logged, since at one
      // every 20s it would bury everything else.
      return null;
    }

    if (envelope.type === 'device_bound') {
      if (sessionKey !== null) return null; // already bound; ignore a duplicate frame
      const phonePub = resolvePhonePubkey(envelope, args.phonePubkey);
      if (!phonePub) {
        console.error(
          '[fake-hmd] device_bound has no phone pubkey: neither --phone-pubkey nor ' +
            "the frame's payload.device_pubkey was present. Pass --phone-pubkey " +
            '<base64url> to continue, or check that the phone client is sending ' +
            'device_pubkey on its claim (relay/src/session.ts handlePairingCodeClaim).'
        );
        await revoke();
        process.exit(1);
      }
      bindSessionKey(phonePub);
      return null;
    }

    if (envelope.type === 'session_ended') {
      console.error('[fake-hmd] session_ended received, exiting');
      return 'session-ended';
    }

    if (envelope.type === 'command') {
      if (sessionKey === null) {
        console.error('[fake-hmd] command received before device_bound, dropping');
        return null;
      }
      let plaintext;
      try {
        plaintext = open(sessionKey, 'phn', { seq: envelope.seq, ciphertext: envelope.ciphertext }, lastPhoneSeq);
      } catch (err) {
        const reason = err instanceof RelayCryptoError ? err.reason : 'unknown';
        console.error(`[fake-hmd] failed to open command envelope (${reason}): ${err.message}`);
        return null;
      }
      lastPhoneSeq = envelope.seq;

      const command = decodeSendMessageCommand(plaintext);
      if (command === null) {
        console.error('[fake-hmd] received an unrecognized command payload');
        sendAck(envelope.seq, false, 'malformed-command');
        return null;
      }
      console.error(`[phone] ${command.params.text}`);
      sendAck(envelope.seq, true);
      return null;
    }

    console.error(`[fake-hmd] unexpected frame type on hmd stream: ${envelope.type}`);
    return null;
  }

  /** Steps 4-8: open the hmd-leg stream (Bearer) and read it until it ends.
   *  One connection's worth of work -- runStreamWithReconnect owns getting
   *  back here after a drop. A fresh `buffer` per connection: a partial line
   *  from a cut stream is not a prefix of the reopened one. */
  async function streamOnce(isReconnect) {
    let res;
    try {
      res = await fetch(`${relayBase}/session/${sessionId}/stream`, {
        headers: { Authorization: `Bearer ${relaySessionToken}` },
      });
    } catch (err) {
      console.error(`[fake-hmd] could not reach the relay stream: ${err.message}`);
      return 'open-failed';
    }
    if (res.status === 401) {
      throw new FatalStreamError('GET /session/:id/stream rejected the bearer token (HTTP 401)');
    }
    if (!res.ok || !res.body) {
      console.error(`[fake-hmd] GET /session/:id/stream failed: HTTP ${res.status}`);
      return 'open-failed';
    }
    console.error(
      isReconnect ? '[fake-hmd] stream reconnected' : `[fake-hmd] stream open, session_id=${sessionId}`
    );

    let buffer = '';
    try {
      for await (const chunk of Readable.fromWeb(res.body)) {
        buffer += chunk.toString('utf8');
        let newlineIndex;
        while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
          const line = buffer.slice(0, newlineIndex);
          buffer = buffer.slice(newlineIndex + 1);
          if (line.trim().length === 0) continue;
          if ((await handleLine(line)) === 'session-ended') return 'session-ended';
        }
      }
    } catch (err) {
      // Cloudflare cutting the response body surfaces here as undici's bare
      // TypeError('terminated') -- the 2026-09-24 failure. Reconnect.
      console.error(`[fake-hmd] stream dropped (${err.message}), reconnecting`);
      return 'closed';
    }
    console.error('[fake-hmd] stream closed by the relay, reconnecting');
    return 'closed';
  }

  await runStreamWithReconnect({
    runOnce: streamOnce,
    sleep,
    isStopped: () => stopped,
  });

  if (stateTimer) clearInterval(stateTimer);
}

function isMain() {
  if (!process.argv[1]) return false;
  return import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMain()) {
  main().catch((err) => {
    console.error(`[fake-hmd] fatal: ${err.message}`);
    process.exit(1);
  });
}
