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
//   6. derive the session key (needs the phone's pubkey -- see the
//      "device_bound has no phone pubkey" branch below for a disclosed,
//      confirmed gap in the deployed relay, and the --phone-pubkey escape
//      hatch around it)
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
import { encodeHmdEnvelope, decodeEnvelope, base64Encode, base64Decode } from './lib/envelope.mjs';

const HERE = fileURLToPath(new URL('.', import.meta.url)); // .../relay/scripts/
const REPO_ROOT = join(HERE, '..', '..');
const DEFAULT_STATE_RELATIVE_PATH = 'docs/samples/state.json';
const STATE_SEND_INTERVAL_MS = 5000;

const USAGE = `Usage: node relay/scripts/fake-hmd.mjs --relay <https://...> [--state <path>] [--phone-pubkey <base64>]

  --relay <url>          relay base URL, e.g. https://hmd-relay.therishabh16.workers.dev
  --state <path>         sample state JSON to send (default: ${DEFAULT_STATE_RELATIVE_PATH},
                          resolved from the repo root regardless of cwd)
  --phone-pubkey <b64>   manual override for the phone's X25519 public key --
                          see relay/README.md's "fake-hmd.mjs" section for why
                          this is currently required against the live relay
  --help, -h             print this message
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

  // Step 4: open the hmd-leg stream (Bearer).
  const streamRes = await fetch(`${relayBase}/session/${sessionId}/stream`, {
    headers: { Authorization: `Bearer ${relaySessionToken}` },
  });
  if (!streamRes.ok || !streamRes.body) {
    throw new Error(`GET /session/:id/stream failed: HTTP ${streamRes.status}`);
  }
  console.error(`[fake-hmd] stream open, session_id=${sessionId}`);

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

  const nodeReadable = Readable.fromWeb(streamRes.body);
  let buffer = '';
  for await (const chunk of nodeReadable) {
    buffer += chunk.toString('utf8');
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);
      if (line.trim().length === 0) continue;

      const envelope = decodeEnvelope(line);
      if (envelope === null) {
        console.error('[fake-hmd] dropped malformed stream line');
        continue;
      }

      if (envelope.type === 'device_bound') {
        if (sessionKey !== null) continue; // already bound; ignore a duplicate frame
        const overridePub = args.phonePubkey ? base64Decode(args.phonePubkey) : null;
        const payloadPub =
          envelope.payload && typeof envelope.payload.device_pubkey === 'string'
            ? base64Decode(envelope.payload.device_pubkey)
            : null;
        const phonePub = overridePub ?? payloadPub;
        if (!phonePub) {
          console.error(
            '[fake-hmd] device_bound has no phone pubkey: the deployed relay ' +
              '(relay/src/session.ts acceptDeviceSocket) never forwards device_pubkey to ' +
              "hmd's leg, and RelayTransport.ts sends ?claim= while the relay reads " +
              '?pairing_code= -- see relay/README.md\'s "fake-hmd.mjs" section for detail. ' +
              'Pass --phone-pubkey <base64> to continue.'
          );
          await revoke();
          process.exit(1);
        }
        bindSessionKey(phonePub);
        continue;
      }

      if (envelope.type === 'session_ended') {
        console.error('[fake-hmd] session_ended received, exiting');
        if (stateTimer) clearInterval(stateTimer);
        return;
      }

      if (envelope.type === 'command') {
        if (sessionKey === null) {
          console.error('[fake-hmd] command received before device_bound, dropping');
          continue;
        }
        let plaintext;
        try {
          plaintext = open(sessionKey, 'phn', { seq: envelope.seq, ciphertext: envelope.ciphertext }, lastPhoneSeq);
        } catch (err) {
          const reason = err instanceof RelayCryptoError ? err.reason : 'unknown';
          console.error(`[fake-hmd] failed to open command envelope (${reason}): ${err.message}`);
          continue;
        }
        lastPhoneSeq = envelope.seq;

        const command = decodeSendMessageCommand(plaintext);
        if (command === null) {
          console.error('[fake-hmd] received an unrecognized command payload');
          sendAck(envelope.seq, false, 'malformed-command');
          continue;
        }
        console.error(`[phone] ${command.params.text}`);
        sendAck(envelope.seq, true);
        continue;
      }

      console.error(`[fake-hmd] unexpected frame type on hmd stream: ${envelope.type}`);
    }
  }

  if (stateTimer) clearInterval(stateTimer);
  console.error('[fake-hmd] stream closed, exiting');
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
