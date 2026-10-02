#!/usr/bin/env node
// pairing-expiry-probe.mjs — plays hmd's relay client for a session no phone
// will ever claim, and reports whether the relay says why it ends that session.
//
// It is the 2026-10-02 field bug as a two-minute check: `POST /pair/init`, open
// `GET /session/:id/stream`, claim nothing, and hold the stream until the relay
// closes it (the storage-reclamation alarm, ~120 s after init: the 60 s pairing
// window plus 60 s grace). A relay that predates INV-38 closes with a bare EOF
// and answers the reconnect with 404 — what hmd's client logged as "stream
// closed by relay with no local cause" then `session_ended: stream-404`. A
// relay that has it writes `session_ended` with `payload.reason` first.
//
//   node relay/scripts/pairing-expiry-probe.mjs --relay https://<worker> [--hold-s 150]
//
// Exit 0: the relay announced a reason. 1: bare EOF (the field bug). 2: usage or
// a network/HTTP failure. 3: the stream was still open at the deadline.
//
// It creates one throwaway pending session on the relay it is pointed at, claims
// nothing, and lets the relay reclaim it. Output is timings, statuses and frame
// types only: never a token, a pairing code or a URL, and the session id is cut
// to 8 characters.

import { pathToFileURL } from 'node:url';

const DEFAULT_HOLD_S = 150;
/** The purge lands ~120 s after init; anything shorter cannot observe it. */
const MIN_HOLD_S = 125;
const RECONNECT_DELAY_MS = 2000;

export function parseArgs(argv) {
  let relay = null;
  let holdS = DEFAULT_HOLD_S;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--relay') relay = argv[++i] ?? '';
    else if (arg === '--hold-s') holdS = Number(argv[++i]);
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!relay) throw new Error('--relay is required');
  if (!/^https?:\/\//.test(relay)) throw new Error('--relay must be an http(s) URL');
  if (!Number.isFinite(holdS) || holdS < MIN_HOLD_S) {
    throw new Error(
      `--hold-s must be a number of at least ${MIN_HOLD_S} (the purge lands ~120 s after init)`
    );
  }
  return { relay: relay.replace(/\/+$/, ''), holdS };
}

/** One NDJSON line off the stream, reduced to what the report prints. */
export function summarizeFrame(line) {
  let frame;
  try {
    frame = JSON.parse(line);
  } catch {
    return { kind: 'unparseable' };
  }
  if (frame === null || typeof frame !== 'object') return { kind: 'unparseable' };
  if (frame.type === 'keepalive') return { kind: 'keepalive' };
  const reason =
    frame.payload && typeof frame.payload.reason === 'string' ? frame.payload.reason : null;
  return { kind: 'frame', type: frame.type, sender: frame.sender, reason };
}

export function verdictFor({ closed, announcedReason }) {
  if (!closed) {
    return {
      exitCode: 3,
      message:
        'INCONCLUSIVE: the stream was still open at the deadline -- raise --hold-s ' +
        '(the purge lands ~120 s after init)',
    };
  }
  if (announcedReason) {
    return {
      exitCode: 0,
      message: `OK: the relay announced "${announcedReason}" before closing the stream`,
    };
  }
  return {
    exitCode: 1,
    message:
      'FIELD BUG: the relay closed the stream with a bare EOF -- no session_ended frame ' +
      'says why (this relay predates INV-38)',
  };
}

async function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (err) {
    console.error(`pairing-expiry-probe: ${err.message}`);
    return 2;
  }
  const { relay, holdS } = options;
  const startedAt = Date.now();
  const stamp = () => `T+${((Date.now() - startedAt) / 1000).toFixed(1).padStart(6)}`;
  const log = (line) => console.log(line);

  try {
    const init = await fetch(`${relay}/pair/init`, { method: 'POST' });
    if (init.status !== 200) {
      log(`${stamp()} /pair/init answered ${init.status}`);
      return 2;
    }
    const session = await init.json();
    const sessionId = session.session_id;
    const auth = { Authorization: `Bearer ${session.relay_session_token}` };
    const windowS = session.exp - Math.floor(Date.now() / 1000);
    log(`${stamp()} init ok sid=${String(sessionId).slice(0, 8)} pairing window ~${windowS}s`);

    const stream = await fetch(`${relay}/session/${sessionId}/stream`, { headers: auth });
    log(`${stamp()} stream status=${stream.status}`);
    if (stream.status !== 200) return 2;

    const reader = stream.body.getReader();
    const decoder = new TextDecoder();
    const deadline = startedAt + holdS * 1000;
    let buffered = '';
    let keepalives = 0;
    let announcedReason = null;
    let closed = false;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const next = await Promise.race([
        reader.read(),
        new Promise((resolve) => setTimeout(() => resolve('deadline'), remaining)),
      ]);
      if (next === 'deadline') break;
      if (next.done) {
        closed = true;
        log(`${stamp()} stream closed by the relay (keepalives seen: ${keepalives})`);
        break;
      }
      buffered += decoder.decode(next.value, { stream: true });
      let newlineAt;
      while ((newlineAt = buffered.indexOf('\n')) !== -1) {
        const line = buffered.slice(0, newlineAt).trim();
        buffered = buffered.slice(newlineAt + 1);
        if (line.length === 0) continue;
        const summary = summarizeFrame(line);
        if (summary.kind === 'keepalive') {
          keepalives += 1;
        } else if (summary.kind === 'unparseable') {
          log(`${stamp()} unparseable line (${line.length} bytes)`);
        } else {
          if (summary.reason) announcedReason = summary.reason;
          log(
            `${stamp()} frame type=${summary.type} sender=${summary.sender} ` +
              `reason=${summary.reason ?? '-'}`
          );
        }
      }
    }
    if (!closed) await reader.cancel();

    await new Promise((resolve) => setTimeout(resolve, RECONNECT_DELAY_MS));
    const again = await fetch(`${relay}/session/${sessionId}/stream`, { headers: auth });
    log(`${stamp()} reconnect status=${again.status}`);
    await again.body?.cancel();

    const verdict = verdictFor({ closed, announcedReason });
    log(verdict.message);
    return verdict.exitCode;
  } catch (err) {
    console.error(`pairing-expiry-probe: ${err.message}`);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main(process.argv.slice(2)));
}
