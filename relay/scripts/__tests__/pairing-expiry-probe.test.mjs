// pairing-expiry-probe.mjs plays hmd for a session no phone ever claims, to show
// whether a relay announces why it ends that session (INV-38) or closes the
// stream bare — the 2026-10-02 field bug. Only the pure parts are covered
// here: argument parsing, per-line frame summaries and the verdict. The network
// loop needs a live relay and a two-minute wait, and is exercised by running
// the probe (relay/README.md, "Verifying a deploy").
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseArgs, summarizeFrame, verdictFor } from '../pairing-expiry-probe.mjs';

test('parseArgs holds the stream long enough to see the 120 s purge by default', () => {
  assert.deepEqual(parseArgs(['--relay', 'https://relay.example.test']), {
    relay: 'https://relay.example.test',
    holdS: 150,
  });
});

test('parseArgs takes an explicit --hold-s and strips a trailing slash from --relay', () => {
  assert.deepEqual(parseArgs(['--relay', 'https://relay.example.test/', '--hold-s', '200']), {
    relay: 'https://relay.example.test',
    holdS: 200,
  });
});

test('parseArgs requires --relay', () => {
  assert.throws(() => parseArgs([]), /--relay is required/);
});

test('parseArgs rejects a relay that is not an http(s) URL', () => {
  assert.throws(() => parseArgs(['--relay', 'relay.example.test']), /http\(s\) URL/);
  assert.throws(() => parseArgs(['--relay', 'ftp://relay.example.test']), /http\(s\) URL/);
});

test('parseArgs rejects a --hold-s too short to reach the purge', () => {
  assert.throws(
    () => parseArgs(['--relay', 'https://relay.example.test', '--hold-s', '100']),
    /--hold-s must be a number of at least 125/
  );
  assert.throws(
    () => parseArgs(['--relay', 'https://relay.example.test', '--hold-s', 'soon']),
    /--hold-s must be a number of at least 125/
  );
});

test('parseArgs rejects an unknown flag', () => {
  assert.throws(() => parseArgs(['--relay', 'https://relay.example.test', '--bogus']), /unknown argument/);
});

test('summarizeFrame sets a keepalive aside', () => {
  assert.deepEqual(summarizeFrame('{"v":1,"type":"keepalive","sender":"relay","payload":{"ts":1}}'), {
    kind: 'keepalive',
  });
});

test('summarizeFrame surfaces the reason on a session_ended frame', () => {
  const line = JSON.stringify({
    v: 1,
    session_id: 'x',
    seq: 0,
    sender: 'relay',
    type: 'session_ended',
    nonce: null,
    ciphertext: null,
    payload: { reason: 'pairing-expired' },
  });
  assert.deepEqual(summarizeFrame(line), {
    kind: 'frame',
    type: 'session_ended',
    sender: 'relay',
    reason: 'pairing-expired',
  });
});

test('summarizeFrame reports an unparseable line without echoing it', () => {
  assert.deepEqual(summarizeFrame('not json at all'), { kind: 'unparseable' });
});

test('verdictFor passes when the relay announced a reason before closing', () => {
  const verdict = verdictFor({ closed: true, announcedReason: 'pairing-expired' });
  assert.equal(verdict.exitCode, 0);
  assert.match(verdict.message, /announced "pairing-expired"/);
});

test('verdictFor flags a close with no reason as the field bug', () => {
  const verdict = verdictFor({ closed: true, announcedReason: null });
  assert.equal(verdict.exitCode, 1);
  assert.match(verdict.message, /bare EOF/);
});

test('verdictFor calls a stream still open at the deadline inconclusive', () => {
  const verdict = verdictFor({ closed: false, announcedReason: null });
  assert.equal(verdict.exitCode, 3);
  assert.match(verdict.message, /still open/);
});
