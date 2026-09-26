#!/usr/bin/env node
// phone-sim.mjs -- scripted phone that mirrors src/transport/RelayTransport.ts's
// wire behavior exactly, for live diagnosis of the relay send-ack bug: every
// phone->hmd `command` (send-message) currently gets no ack (app times out
// after RelayTransport's own 10s ACK_TIMEOUT_MS), with no `frame_rejected` /
// `frame_undelivered` event on the relay Worker's own tail log.
//
// Opposite leg of fake-hmd.mjs (which plays hmd; this plays the phone),
// reusing the same "real code, not a reimplementation" discipline
// __tests__/phone-leg-interop.test.mjs established for that test.
//
// Wire encode/decode: the REAL app module, `src/relay/protocol.ts`, imported
// via Node's native `.ts` type stripping (Node >= 22.6, unflagged by 24.13 --
// same import phone-leg-interop.test.mjs already relies on). Crypto:
// `relay/scripts/lib/relay-crypto.mjs`, the Node-safe port of
// `src/relay/crypto.ts` (which can't be imported standalone -- it pulls in
// `@/relay/randomBytes`, a React Native/Hermes-only shim).
//
// Never logs a token, pairing code, key, or session key: redact() runs over
// every line this script prints, and the --out JSON never serializes the
// payload or any credential -- only round-trip bookkeeping (seq/timing/ok/
// detail). `protocol.ts` and `src/relay/protocol.ts` live under hmdapp's
// ROOT package.json (no `"type"`), a different module-type boundary than
// relay/'s own (`"type": "module"`) -- crossing it prints a harmless
// MODULE_TYPELESS_PACKAGE_JSON warning unless silenced, same as
// package.json's own `test` script does for phone-leg-interop.test.mjs:
//
//   node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON relay/scripts/phone-sim.mjs --payload <qr.json>
//
// Usage:
//   node relay/scripts/phone-sim.mjs --payload <qr.json> [options]
//   node relay/scripts/phone-sim.mjs --payload-json '{"v":1,"relay":"https://...",...}' [options]
//
// Options:
//   --count <n>            sends per round (default 3)
//   --text <str>            message text per send (default "phone-sim ping")
//   --device-name <str>     device_name on the fresh claim (default "phone-sim")
//   --ack-timeout-ms <n>    per-send ack wait, mirrors RelayTransport's
//                           ACK_TIMEOUT_MS (default 10000)
//   --reconnect             after the first round, disconnect and reconnect
//                           via the saved device_token (the app's relaunch
//                           path), then send another round
//   --dual-socket           after binding, open a SECOND device_token socket
//                           WITHOUT closing the first, then send the second
//                           round over the new socket only -- probes whether
//                           a lingering prior socket breaks ack routing
//   --replay-seq <n>        force the run's first send to use this literal
//                           seq instead of the next sequential one, leaving
//                           the tracker at INITIAL_SEQ for every send after
//                           it -- proves/disproves "a non-increasing seq is
//                           silently dropped rather than negatively acked"
//   --out <path>            write the full JSON result log here
//   --help, -h
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import {
  generateEphemeralKeyPair,
  deriveSessionKey,
  seal,
  open,
  RelayCryptoError,
} from './lib/relay-crypto.mjs';
import {
  encodeEncryptedFrame,
  encodeSendMessageCommand,
  decodeRelayFrame,
  decodeAckPayload,
  decodeStateFramePlaintext,
  base64Decode,
  base64UrlEncode,
} from '../../src/relay/protocol.ts';

/** Mirrors src/relay/crypto.ts's INITIAL_SEQ: the first seq a sender ever
 *  uses (INV-14: strictly increasing per sender, never 0). */
export const INITIAL_SEQ = 1;
/** Mirrors src/relay/crypto.ts's NO_HMD_SEQ_SEEN: the receiver floor before
 *  any hmd-originated frame has been opened, one below hmd's own real first
 *  seq (which is 1, not 0). */
export const NO_HMD_SEQ_SEEN = -1;
export const DEFAULT_ACK_TIMEOUT_MS = 10000;
const DEFAULT_COUNT = 3;
const DEFAULT_TEXT = 'phone-sim ping';
const DEFAULT_DEVICE_NAME = 'phone-sim';
const BIND_TIMEOUT_MS = 15000;
const DUAL_SOCKET_GRACE_MS = 2000;

/** Any run of 24+ base64url-ish characters, standing in for a token, pairing
 *  code, or key regardless of which field it came from -- applied to every
 *  line this script prints. Matches the task's own redaction instruction
 *  byte for byte ("redact any 24+ char base64url run"). */
const REDACT_PATTERN = /[A-Za-z0-9_-]{24,}/g;

export function redact(value) {
  return value.replace(REDACT_PATTERN, (m) => `<redacted:${m.length}ch>`);
}

function log(...parts) {
  const line = parts.map((p) => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ');
  console.error(redact(`[phone-sim] ${line}`));
}

const USAGE = `Usage: node relay/scripts/phone-sim.mjs --payload <qr.json> [options]
       node relay/scripts/phone-sim.mjs --payload-json '<json>' [options]

  --payload <path>        QR pairing payload JSON file ({v,relay,session_id,pairing_code,hmd_pubkey})
  --payload-json <json>   QR pairing payload as an inline JSON string
  --count <n>             sends per round (default ${DEFAULT_COUNT})
  --text <str>            message text per send (default ${JSON.stringify(DEFAULT_TEXT)})
  --device-name <str>     device_name on the fresh claim (default ${JSON.stringify(DEFAULT_DEVICE_NAME)})
  --ack-timeout-ms <n>    per-send ack wait (default ${DEFAULT_ACK_TIMEOUT_MS})
  --reconnect             after the first round, reconnect via device_token and send another round
  --dual-socket           open a second device_token socket without closing the first, then send over it
  --replay-seq <n>        force the run's first send to use this literal seq
  --out <path>            write the full JSON result log here
  --help, -h              print this message
`;

function requireValue(argv, i, flag) {
  const value = argv[i + 1];
  if (value === undefined) throw new Error(`${flag} requires a value`);
  return value;
}

export function parseArgs(argv) {
  const args = {
    payload: undefined,
    payloadJson: undefined,
    count: DEFAULT_COUNT,
    text: DEFAULT_TEXT,
    deviceName: DEFAULT_DEVICE_NAME,
    ackTimeoutMs: DEFAULT_ACK_TIMEOUT_MS,
    reconnect: false,
    dualSocket: false,
    replaySeq: undefined,
    out: undefined,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
      continue;
    }
    if (arg === '--payload') {
      args.payload = requireValue(argv, i, '--payload');
      i += 1;
      continue;
    }
    if (arg === '--payload-json') {
      args.payloadJson = requireValue(argv, i, '--payload-json');
      i += 1;
      continue;
    }
    if (arg === '--count') {
      args.count = Number(requireValue(argv, i, '--count'));
      i += 1;
      continue;
    }
    if (arg === '--text') {
      args.text = requireValue(argv, i, '--text');
      i += 1;
      continue;
    }
    if (arg === '--device-name') {
      args.deviceName = requireValue(argv, i, '--device-name');
      i += 1;
      continue;
    }
    if (arg === '--ack-timeout-ms') {
      args.ackTimeoutMs = Number(requireValue(argv, i, '--ack-timeout-ms'));
      i += 1;
      continue;
    }
    if (arg === '--reconnect') {
      args.reconnect = true;
      continue;
    }
    if (arg === '--dual-socket') {
      args.dualSocket = true;
      continue;
    }
    if (arg === '--replay-seq') {
      args.replaySeq = Number(requireValue(argv, i, '--replay-seq'));
      i += 1;
      continue;
    }
    if (arg === '--out') {
      args.out = requireValue(argv, i, '--out');
      i += 1;
      continue;
    }
    throw new Error(`unrecognized argument: ${arg}`);
  }
  if (!args.help && !args.payload && !args.payloadJson) {
    throw new Error('one of --payload <path> or --payload-json <json> is required');
  }
  if (!Number.isInteger(args.count) || args.count < 1) {
    throw new Error('--count must be a positive integer');
  }
  return args;
}

/** Structural validation of a QR pairing payload -- fail-closed, same house
 *  style as src/store/relayPayload.ts (never trusts a field's shape). */
export function validatePayload(value) {
  if (typeof value !== 'object' || value === null) {
    return { ok: false, error: 'payload is not an object' };
  }
  const p = value;
  if (typeof p.relay !== 'string' || !p.relay.startsWith('https://')) {
    return { ok: false, error: 'payload.relay must be an https URL' };
  }
  if (typeof p.session_id !== 'string' || p.session_id.length === 0) {
    return { ok: false, error: 'payload.session_id must be a non-empty string' };
  }
  if (typeof p.pairing_code !== 'string' || p.pairing_code.length === 0) {
    return { ok: false, error: 'payload.pairing_code must be a non-empty string' };
  }
  if (typeof p.hmd_pubkey !== 'string' || p.hmd_pubkey.length === 0) {
    return { ok: false, error: 'payload.hmd_pubkey must be a non-empty string' };
  }
  return { ok: true, payload: p };
}

export function loadPayload(args) {
  const raw = args.payloadJson ?? readFileSync(args.payload, 'utf8');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`payload is not valid JSON: ${err.message}`);
  }
  const result = validatePayload(parsed);
  if (!result.ok) {
    throw new Error(`payload failed validation: ${result.error}`);
  }
  return result.payload;
}

/** Builds the phone's own WS connect URL -- byte-for-byte the same query
 *  shape as src/transport/RelayTransport.ts's private `buildConnectUrl`
 *  (confirmed at RelayTransport.ts:685-706): `device_pubkey` rides both
 *  branches; `pairing_code`+`device_name` XOR `device_token` distinguish a
 *  fresh claim from a reconnect. Kept as an independent copy rather than
 *  imported, since that method is private to the class -- exercised for
 *  parity in __tests__/phone-sim.test.mjs instead. */
export function buildWsUrl(payload, { deviceToken, devicePubkeyB64u, deviceName }) {
  const host = payload.relay.slice('https://'.length).replace(/\/+$/, '');
  const url = new URL(`wss://${host}/session/${encodeURIComponent(payload.session_id)}/ws`);
  url.searchParams.set('device_pubkey', devicePubkeyB64u);
  if (deviceToken) {
    url.searchParams.set('device_token', deviceToken);
  } else {
    url.searchParams.set('pairing_code', payload.pairing_code);
    url.searchParams.set('device_name', deviceName);
  }
  return url.toString();
}

/** Builds one outgoing command frame's wire string, exactly
 *  RelayTransport.send's own two steps (seal, then encode). Exported so
 *  __tests__/phone-sim.test.mjs can prove it round-trips through
 *  decodeRelayFrame without a network, the same shape
 *  phone-leg-interop.test.mjs already proves for the app's own encoder. */
export function buildCommandWire(sessionKey, sessionId, seq, text) {
  const sealed = seal(sessionKey, 'phn', seq, encodeSendMessageCommand(text));
  return encodeEncryptedFrame({
    sessionId,
    sender: 'device',
    type: 'command',
    seq: sealed.seq,
    ciphertext: sealed.ciphertext,
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * One live device WebSocket: opens it, derives/reuses the session key on
 * `device_bound`, tracks the phone's own outgoing seq and hmd's incoming seq
 * (mirrors RelayTransport's `outgoingSeq`/`lastHmdSeq`), and resolves a
 * pending-ack map exactly like RelayTransport.send does. One instance per
 * socket -- `--dual-socket` opens a second one that shares the derived
 * session key and seq state via `shared`.
 */
function createPhoneSocket(payload, shared, label) {
  const pendingAcks = new Map();
  let ws = null;
  let deviceBoundResolvers = [];
  const results = [];

  function noteHmdFrame(seq) {
    if (seq > shared.lastHmdSeq) shared.lastHmdSeq = seq;
  }

  function handleAck(frame) {
    let plaintext;
    try {
      plaintext = open(shared.sessionKey, 'hmd', { seq: frame.seq, ciphertext: frame.ciphertext }, shared.lastHmdSeq);
    } catch (err) {
      const reason = err instanceof RelayCryptoError ? err.reason : 'unknown';
      log(label, `ack frame seq=${frame.seq} failed to open (${reason})`);
      return;
    }
    noteHmdFrame(frame.seq);
    const ack = decodeAckPayload(plaintext);
    if (!ack) {
      log(label, `ack frame seq=${frame.seq} decoded but payload shape is invalid`);
      return;
    }
    const pending = pendingAcks.get(ack.of_seq);
    if (!pending) {
      log(label, `ack for seq=${ack.of_seq} arrived with no matching pending send (late? duplicate?)`);
      return;
    }
    pendingAcks.delete(ack.of_seq);
    clearTimeout(pending.timeoutHandle);
    pending.resolve({ acked: true, ok: ack.ok, detail: ack.detail, id: ack.id, ackedAt: Date.now() });
  }

  function handleState(frame) {
    let plaintext;
    try {
      plaintext = open(shared.sessionKey, 'hmd', { seq: frame.seq, ciphertext: frame.ciphertext }, shared.lastHmdSeq);
    } catch (err) {
      const reason = err instanceof RelayCryptoError ? err.reason : 'unknown';
      log(label, `state frame seq=${frame.seq} failed to open (${reason})`);
      return;
    }
    noteHmdFrame(frame.seq);
    const decoded = decodeStateFramePlaintext(plaintext);
    log(label, `state frame seq=${frame.seq} received (${decoded.ok ? 'parsed' : decoded.error})`);
  }

  function handleMessage(raw) {
    const frame = decodeRelayFrame(raw);
    if (!frame) {
      log(label, 'dropped an unparseable WS frame');
      return;
    }
    if (frame.type === 'device_bound') {
      log(label, 'device_bound received');
      shared.deviceToken = frame.device_token;
      shared.deviceTokenExp = frame.exp;
      const resolvers = deviceBoundResolvers;
      deviceBoundResolvers = [];
      for (const resolve of resolvers) resolve(frame);
      return;
    }
    if (frame.type === 'session_ended') {
      log(label, `session_ended received${frame.reason ? ` (reason=${frame.reason})` : ''}`);
      return;
    }
    if (frame.type === 'ack') {
      handleAck(frame);
      return;
    }
    if (frame.type === 'state') {
      handleState(frame);
      return;
    }
    log(label, `unexpected frame type: ${frame.type}`);
  }

  async function connect({ deviceToken }) {
    const url = buildWsUrl(payload, {
      deviceToken,
      devicePubkeyB64u: shared.devicePubkeyB64u,
      deviceName: shared.deviceName,
    });
    ws = new WebSocket(url);
    const openPromise = new Promise((resolve, reject) => {
      ws.addEventListener('open', () => resolve(), { once: true });
      ws.addEventListener(
        'error',
        (ev) => reject(new Error(`ws error: ${(ev && (ev.message || (ev.error && ev.error.message))) || 'unknown'}`)),
        { once: true }
      );
    });
    ws.addEventListener('message', (ev) => handleMessage(String(ev.data)));
    ws.addEventListener('close', (ev) => {
      log(label, `socket closed: code=${ev.code} reason=${ev.reason || '(none)'}`);
    });
    await openPromise;
    log(label, `socket open (${deviceToken ? 'device_token reconnect' : 'pairing_code claim'})`);
  }

  function waitForDeviceBound(timeoutMs) {
    if (shared.sessionKey !== null) {
      // Already bound from a prior socket sharing this `shared` state
      // (--dual-socket's / --reconnect's second leg) -- a repeat
      // device_bound is optional; either it arrives within the grace
      // window or we proceed anyway (the WS upgrade already succeeding on
      // a device_token claim implies the relay accepted it).
      return Promise.race([
        new Promise((resolve) => {
          deviceBoundResolvers.push(resolve);
        }),
        sleep(DUAL_SOCKET_GRACE_MS).then(() => null),
      ]);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timed out waiting for device_bound')), timeoutMs);
      deviceBoundResolvers.push((frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
    });
  }

  function send(text, { seqOverride } = {}) {
    const seq = seqOverride ?? shared.outgoingSeq;
    if (seqOverride === undefined) shared.outgoingSeq += 1;
    const wire = buildCommandWire(shared.sessionKey, payload.session_id, seq, text);
    const sentAt = Date.now();
    const resultPromise = new Promise((resolve) => {
      const timeoutHandle = setTimeout(() => {
        pendingAcks.delete(seq);
        resolve({ acked: false, ok: false, detail: 'ack-timeout', ackedAt: null });
      }, shared.ackTimeoutMs);
      pendingAcks.set(seq, { resolve, timeoutHandle });
    });
    ws.send(wire);
    log(label, `sent seq=${seq} text=${JSON.stringify(text)}`);
    return resultPromise.then((outcome) => {
      const record = {
        label,
        seq,
        sentAt,
        latencyMs: outcome.ackedAt ? outcome.ackedAt - sentAt : null,
        ...outcome,
      };
      results.push(record);
      log(
        label,
        outcome.acked
          ? `ack for seq=${seq}: ok=${outcome.ok}${outcome.detail ? ` detail=${outcome.detail}` : ''} (${record.latencyMs}ms)`
          : `NO ACK for seq=${seq} after ${shared.ackTimeoutMs}ms timeout`
      );
      return record;
    });
  }

  function close(code, reason) {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
      ws.close(code, reason);
    }
  }

  return { connect, waitForDeviceBound, send, close, results };
}

async function runRound(socket, { count, text, replaySeqOnFirst }) {
  const round = [];
  for (let i = 0; i < count; i += 1) {
    const seqOverride = i === 0 ? replaySeqOnFirst : undefined;
    // eslint-disable-next-line no-await-in-loop -- sends must stay ordered,
    // same reasoning as fake-hmd.mjs's enqueueSend.
    const record = await socket.send(`${text} #${i + 1}`, { seqOverride });
    round.push(record);
  }
  return round;
}

export async function main(argv) {
  const args = parseArgs(argv);
  if (args.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const payload = loadPayload(args);
  const deviceKeypair = generateEphemeralKeyPair();
  const hmdPubkey = base64Decode(payload.hmd_pubkey);
  if (!hmdPubkey) {
    throw new Error('payload.hmd_pubkey is not valid base64');
  }

  const shared = {
    sessionKey: null,
    deviceToken: null,
    deviceTokenExp: null,
    outgoingSeq: INITIAL_SEQ,
    lastHmdSeq: NO_HMD_SEQ_SEEN,
    devicePubkeyB64u: base64UrlEncode(deviceKeypair.publicKey),
    deviceName: args.deviceName,
    ackTimeoutMs: args.ackTimeoutMs,
  };

  const allResults = [];
  const socketA = createPhoneSocket(payload, shared, 'sockA');
  log('sockA', `connecting (session_id=${payload.session_id})`);
  await socketA.connect({ deviceToken: null });
  await socketA.waitForDeviceBound(BIND_TIMEOUT_MS);
  shared.sessionKey = deriveSessionKey(deviceKeypair.secretKey, hmdPubkey, payload.session_id);
  log('sockA', 'session key derived, bound');

  const round1 = await runRound(socketA, {
    count: args.count,
    text: args.text,
    replaySeqOnFirst: args.replaySeq,
  });
  allResults.push(...round1);

  if (args.dualSocket) {
    const socketB = createPhoneSocket(payload, shared, 'sockB');
    log('sockB', 'connecting via device_token WITHOUT closing sockA (dual-socket probe)');
    await socketB.connect({ deviceToken: shared.deviceToken });
    await socketB.waitForDeviceBound(DUAL_SOCKET_GRACE_MS);
    const round2 = await runRound(socketB, {
      count: args.count,
      text: `${args.text} dual`,
      replaySeqOnFirst: undefined,
    });
    allResults.push(...round2);
    socketB.close(1000, 'phone-sim done');
    socketA.close(1000, 'phone-sim done (dual-socket probe complete)');
  } else if (args.reconnect) {
    socketA.close(1000, 'phone-sim reconnect probe');
    await sleep(500);
    const socketC = createPhoneSocket(payload, shared, 'sockC');
    log('sockC', 'reconnecting via device_token (app relaunch path)');
    await socketC.connect({ deviceToken: shared.deviceToken });
    await socketC.waitForDeviceBound(DUAL_SOCKET_GRACE_MS);
    const round2 = await runRound(socketC, {
      count: args.count,
      text: `${args.text} reconnect`,
      replaySeqOnFirst: undefined,
    });
    allResults.push(...round2);
    socketC.close(1000, 'phone-sim done');
  } else {
    socketA.close(1000, 'phone-sim done');
  }

  const summary = {
    session_id: payload.session_id,
    relay: payload.relay,
    sends: allResults.length,
    acked: allResults.filter((r) => r.acked).length,
    timedOut: allResults.filter((r) => !r.acked).length,
    results: allResults.map(({ label, seq, sentAt, latencyMs, acked, ok, detail, id }) => ({
      label,
      seq,
      sentAt,
      latencyMs,
      acked,
      ok,
      detail,
      id,
    })),
  };
  log('summary', `${summary.acked}/${summary.sends} acked, ${summary.timedOut} timed out`);
  if (args.out) {
    writeFileSync(args.out, JSON.stringify(summary, null, 2));
    log('summary', `wrote ${args.out}`);
  } else {
    console.log(JSON.stringify(summary, null, 2));
  }
  return summary.timedOut > 0 ? 1 : 0;
}

function isMain() {
  if (!process.argv[1]) return false;
  return import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMain()) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err) => {
      log('fatal', err.message);
      process.exit(1);
    });
}
