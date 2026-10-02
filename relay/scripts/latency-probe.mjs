#!/usr/bin/env node
// latency-probe.mjs -- measures the relay's two legs end to end, in ONE process, so
// every timestamp comes from the same monotonic clock (no clock-skew correction).
//
// It plays hmd AND the phone against a FRESH session of its own (POST /pair/init), never
// an operator's live one: a real hmd client is never touched, and the "send-message"
// commands it sends go to its own stream reader, not to anyone's inbox.
//
//   hmd -> phone   hmd seals + POSTs /session/:id/frames          -> phone WebSocket receives
//   phone -> hmd   phone seals + sends a command on its WebSocket -> hmd's GET /stream reads it
//   round trip     ... then hmd POSTs the ack                    -> phone receives the ack
//
// Two hmd-leg transport modes, the thing the analysis compares:
//   fresh      a new TCP+TLS connection for every POST (agent:false, Connection: close) --
//              what bin/heimdall-relay-client does today (docs/analysis/2026-10-02-sync-latency-deepdive.md)
//   keepalive  one persistent TLS connection reused for every POST (https.Agent keepAlive)
//
// Usage (Node >= 22.6, native .ts import like phone-sim.mjs):
//   node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON relay/scripts/latency-probe.mjs \
//        [--relay https://hmd-relay.therishabh16.workers.dev] [--modes fresh,keepalive] \
//        [--frames 30] [--fixture <name>=<path> ...] [--out <path>]
//
// Never prints a token, pairing code or key. Always revokes the sessions it created.
import https from 'node:https';
import { readFileSync, writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import {
  generateEphemeralKeyPair,
  deriveSessionKey,
  seal,
  open,
} from './lib/relay-crypto.mjs';
import { encodeHmdEnvelope, base64UrlEncode, base64UrlDecode, base64Encode } from './lib/envelope.mjs';
import { buildWsUrl, buildCommandWire } from './phone-sim.mjs';
import { decodeRelayFrame } from '../../src/relay/protocol.ts';

const DEFAULT_RELAY = 'https://hmd-relay.therishabh16.workers.dev';

/** p-th percentile (nearest rank) of a numeric array; null when empty. */
export function pct(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

export function summarize(values) {
  const ok = values.filter((v) => typeof v === 'number' && Number.isFinite(v));
  const r = (n) => (n === null ? null : Math.round(n * 10) / 10);
  return {
    n: ok.length,
    min: r(ok.length ? Math.min(...ok) : null),
    p50: r(pct(ok, 50)),
    p95: r(pct(ok, 95)),
    max: r(ok.length ? Math.max(...ok) : null),
    mean: r(ok.length ? ok.reduce((a, b) => a + b, 0) / ok.length : null),
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const args = { relay: DEFAULT_RELAY, modes: ['fresh', 'keepalive'], frames: 30, fixtures: {}, out: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      i += 1;
      if (argv[i] === undefined) throw new Error(`${a} needs a value`);
      return argv[i];
    };
    if (a === '--relay') args.relay = next().replace(/\/+$/, '');
    else if (a === '--modes') args.modes = next().split(',');
    else if (a === '--frames') args.frames = Number(next());
    else if (a === '--out') args.out = next();
    else if (a === '--cmd-only') args.cmdOnly = true;
    else if (a === '--fixture') {
      const [name, path] = next().split('=');
      args.fixtures[name] = path;
    } else throw new Error(`unknown argument ${a}`);
  }
  return args;
}

/** One POST over node:https with phase timestamps. */
function timedPost(relay, path, token, body, agent) {
  const url = new URL(relay + path);
  return new Promise((resolve, reject) => {
    const t0 = performance.now();
    const phases = { reused: false, tcp: null, tls: null, headers: null, family: null };
    const headers = {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    };
    if (agent === false) headers.connection = 'close';
    const req = https.request({ host: url.hostname, path: url.pathname, method: 'POST', agent, headers }, (res) => {
      phases.headers = performance.now() - t0;
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (c) => (raw += c));
      res.on('end', () => resolve({ t0, status: res.statusCode, raw, total: performance.now() - t0, ...phases }));
    });
    req.on('socket', (s) => {
      if (s.connecting) {
        s.once('connect', () => {
          phases.tcp = performance.now() - t0;
          phases.family = s.remoteFamily;
        });
        s.once('secureConnect', () => {
          phases.tls = performance.now() - t0;
        });
      } else {
        phases.reused = true;
      }
    });
    req.setTimeout(20000, () => req.destroy(new Error('post timeout 20s')));
    req.on('error', reject);
    req.end(body);
  });
}

async function runMode(mode, args, fixtures) {
  const relay = args.relay;
  const agent = mode === 'fresh' ? false : new https.Agent({ keepAlive: true, maxSockets: 1 });
  const initRes = await fetch(`${relay}/pair/init`, { method: 'POST' });
  if (!initRes.ok) throw new Error(`pair/init HTTP ${initRes.status}`);
  const init = await initRes.json();
  const sessionId = init.session_id;
  const token = init.relay_session_token;
  let revoked = false;
  const revoke = async () => {
    if (revoked) return;
    revoked = true;
    try {
      await fetch(`${relay}/session/${sessionId}/revoke`, { method: 'POST', headers: { authorization: `Bearer ${token}` } });
    } catch {
      /* best effort */
    }
  };

  const hmdKeys = generateEphemeralKeyPair();
  const devKeys = generateEphemeralKeyPair();
  let hmdKey = null;
  const devKey = deriveSessionKey(devKeys.secretKey, hmdKeys.publicKey, sessionId);

  // ---- hmd stream (phone -> hmd), one long-lived response ----
  const streamAbort = new AbortController();
  const hmdInbox = []; // waiters for a device command
  const streamRes = await fetch(`${relay}/session/${sessionId}/stream`, {
    headers: { authorization: `Bearer ${token}` },
    signal: streamAbort.signal,
  });
  if (streamRes.status !== 200) throw new Error(`stream HTTP ${streamRes.status}`);
  const boundByStream = new Promise((resolve) => {
    (async () => {
      const dec = new TextDecoder();
      let buf = '';
      try {
        for await (const chunk of streamRes.body) {
          const at = performance.now();
          buf += dec.decode(chunk, { stream: true });
          let nl;
          while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (!line.trim()) continue;
            let env;
            try {
              env = JSON.parse(line);
            } catch {
              continue;
            }
            if (env.type === 'device_bound' && env.sender === 'relay') {
              resolve(env.payload);
            } else if (env.type === 'command' && hmdKey) {
              const w = hmdInbox.shift();
              if (w) w(at, env);
            }
          }
        }
      } catch {
        /* aborted at teardown */
      }
    })();
  });

  // ---- phone WebSocket (hmd -> phone) ----
  const waiters = new Map(); // hmd seq -> {resolve}
  let lastHmdSeqSeen = 0;
  const wsUrl = buildWsUrl(
    { relay, session_id: sessionId, pairing_code: init.pairing_code },
    { deviceToken: undefined, devicePubkeyB64u: base64UrlEncode(devKeys.publicKey), deviceName: 'latency-probe' }
  );
  const ws = new WebSocket(wsUrl);
  const phoneBound = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('phone device_bound timeout')), 15000);
    ws.addEventListener('message', (ev) => {
      const at = performance.now();
      const raw = String(ev.data);
      const frame = decodeRelayFrame(raw);
      if (!frame) return;
      if (frame.type === 'device_bound') {
        clearTimeout(timer);
        resolve();
        return;
      }
      if (frame.type !== 'state' && frame.type !== 'ack') return;
      const w = waiters.get(frame.seq);
      if (!w) return;
      waiters.delete(frame.seq);
      let openMs = null;
      let parseMs = null;
      try {
        const o0 = performance.now();
        const plain = open(devKey, 'hmd', { seq: frame.seq, ciphertext: frame.ciphertext }, lastHmdSeqSeen);
        openMs = performance.now() - o0;
        lastHmdSeqSeen = frame.seq;
        const p0 = performance.now();
        JSON.parse(new TextDecoder().decode(plain));
        parseMs = performance.now() - p0;
      } catch {
        /* tracked as a missing sample */
      }
      w({ at, wireBytes: raw.length, openMs, parseMs });
    });
    ws.addEventListener('error', () => reject(new Error('phone ws error')));
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', () => reject(new Error('phone ws open error')), { once: true });
  });
  await phoneBound;
  const bound = await boundByStream;
  hmdKey = deriveSessionKey(hmdKeys.secretKey, base64UrlDecode(bound.device_pubkey), sessionId);

  let hmdSeq = 0;
  let devSeq = 0;
  const failures = [];

  async function hmdSend(type, plaintextBytes) {
    hmdSeq += 1;
    const seq = hmdSeq;
    const sealed = seal(hmdKey, 'hmd', seq, plaintextBytes);
    const body = encodeHmdEnvelope({ sessionId, seq, type, ciphertext: sealed.ciphertext });
    const arrival = new Promise((resolve) => waiters.set(seq, resolve));
    let post;
    try {
      post = await timedPost(relay, `/session/${sessionId}/frames`, token, body, agent);
    } catch (err) {
      // a failed POST is DATA (the real client counts it as a lost frame), not a reason to abort the run
      waiters.delete(seq);
      failures.push(String(err.code || err.name || 'error'));
      return { post: { t0: performance.now(), total: null, tcp: null, tls: null, reused: false, family: null, failed: true }, got: null, bodyBytes: Buffer.byteLength(body), seq };
    }
    if (post.status !== 200) throw new Error(`POST /frames HTTP ${post.status}`);
    const got = await Promise.race([arrival, sleep(15000).then(() => null)]);
    return { post, got, bodyBytes: Buffer.byteLength(body), seq };
  }

  const series = {};
  const record = (name, row) => (series[name] ||= []).push(row);

  async function hmdToPhoneSeries(name, type, plaintext, count) {
    for (let i = 0; i < count; i += 1) {
      const r = await hmdSend(type, plaintext);
      record(name, {
        e2e_ms: r.got ? r.got.at - r.post.t0 : null, // POST start -> phone parsed-frame arrival
        post_resp_ms: r.post.total, // POST start -> HTTP response complete
        tcp_ms: r.post.tcp,
        tls_ms: r.post.tls !== null && r.post.tcp !== null ? r.post.tls - r.post.tcp : null,
        reused: r.post.reused,
        family: r.post.family,
        open_ms: r.got ? r.got.openMs : null,
        parse_ms: r.got ? r.got.parseMs : null,
        body_bytes: r.bodyBytes,
      });
      await sleep(400 + Math.random() * 1600);
    }
  }

  if (mode === 'keepalive') {
    // warm the persistent connection so the series measures steady state; recorded separately
    const w = await hmdSend('state', new TextEncoder().encode('{"state":{}}'));
    record('warmup_first_post', { e2e_ms: w.got ? w.got.at - w.post.t0 : null, post_resp_ms: w.post.total, tcp_ms: w.post.tcp });
    await sleep(500);
  }

  for (const [name, type, plaintext] of fixtures.hmdToPhone) {
    await hmdToPhoneSeries(name, type, plaintext, name.includes('111k') ? Math.min(args.frames, 20) : args.frames);
  }

  // ---- phone -> hmd command, then hmd's ack back ----
  for (let i = 0; i < args.frames; i += 1) {
    devSeq += 1;
    const cmdSeq = devSeq;
    const wire = buildCommandWire(devKey, sessionId, cmdSeq, 'latency probe ping');
    let waiter;
    const hmdGot = new Promise((resolve) => {
      waiter = (at, env) => resolve({ at, env });
      hmdInbox.push(waiter);
    });
    const t0 = performance.now();
    ws.send(wire);
    const g = await Promise.race([hmdGot, sleep(15000).then(() => null)]);
    if (!g) {
      const at = hmdInbox.indexOf(waiter);
      if (at >= 0) hmdInbox.splice(at, 1); // a lost command must not swallow the next one
      record('cmd_to_ack', { phone_to_hmd_ms: null, ack_post_to_phone_ms: null, total_ms: null });
      continue;
    }
    const ackPlain = new TextEncoder().encode(JSON.stringify({ ok: true, of_seq: cmdSeq }));
    const ackStart = performance.now();
    const r = await hmdSend('ack', ackPlain);
    record('cmd_to_ack', {
      phone_to_hmd_ms: g.at - t0,
      hmd_handle_ms: ackStart - g.at,
      ack_post_to_phone_ms: r.got ? r.got.at - ackStart : null,
      ack_post_resp_ms: r.post.total,
      total_ms: r.got ? r.got.at - t0 : null,
      tcp_ms: r.post.tcp,
      reused: r.post.reused,
    });
    await sleep(400 + Math.random() * 1600);
  }

  ws.close(1000, 'probe done');
  streamAbort.abort();
  await revoke();
  if (agent) agent.destroy();

  const summary = {};
  for (const [name, rows] of Object.entries(series)) {
    const cols = {};
    for (const key of Object.keys(rows[0])) {
      if (rows.every((r) => r[key] === null || typeof r[key] === 'number')) cols[key] = summarize(rows.map((r) => r[key]));
    }
    summary[name] = cols;
  }
  return { mode, summary, series, post_failures: failures };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const defaults = {
    tiny: null,
    '12k': new URL('../../docs/samples/state.json', import.meta.url).pathname,
    '50k': null,
    '111k': new URL('../../docs/samples/state-real-hmdapp.json', import.meta.url).pathname,
  };
  const enc = (obj) => new TextEncoder().encode(JSON.stringify({ state: obj }));
  const load = (p) => JSON.parse(readFileSync(p, 'utf8'));
  const fx = { ...defaults, ...args.fixtures };
  const hmdToPhone = [
    ['state_tiny', 'state', enc({ ts: 0 })],
    ['state_12k', 'state', enc(load(fx['12k']))],
  ];
  if (fx['50k']) {
    const p50 = enc(load(fx['50k']));
    hmdToPhone.push(['state_50k', 'state', p50], ['ack_50k_no_storage', 'ack', p50]);
  }
  hmdToPhone.push(['state_111k', 'state', enc(load(fx['111k']))]);
  if (args.cmdOnly) hmdToPhone.length = 0;
  const out = { relay: args.relay, at: new Date().toISOString(), node: process.version, results: [] };
  for (const mode of args.modes) {
    process.stderr.write(`[probe] mode=${mode} ...\n`);
    out.results.push(await runMode(mode, args, { hmdToPhone }));
  }
  for (const r of out.results) {
    process.stderr.write(`\n== ${r.mode}\n`);
    for (const [name, cols] of Object.entries(r.summary)) {
      const main = cols.e2e_ms || cols.total_ms;
      if (!main) continue;
      process.stderr.write(`${name.padEnd(20)} n=${main.n} p50=${main.p50} p95=${main.p95} max=${main.max}\n`);
    }
  }
  if (args.out) writeFileSync(args.out, JSON.stringify(out, null, 1));
  process.exit(0);
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  main().catch((err) => {
    process.stderr.write(`[probe] failed: ${err.message || err.code || err}\n${err.stack || ''}\n`);
    process.exit(1);
  });
}
