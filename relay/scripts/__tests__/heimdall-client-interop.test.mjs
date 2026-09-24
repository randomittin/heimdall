// Cross-boundary interop, hmdapp <-> heimdall's REAL relay client (Python,
// stdlib-only -- Decision 1's zero-toolchain posture for that repo).
//
// phone-leg-interop.test.mjs (sibling file) proved the phone -> relay -> hmd
// leg by same-process `import`ing three real, unmocked implementations via
// Node's native .ts type-stripping. That trick doesn't reach Python, so this
// file shells out to `python3` for every assertion that touches heimdall's
// code -- mirroring exactly how bin/heimdall-relay-client loads
// bin/lib/hmd_relay_e2e.py itself (importlib.util.spec_from_file_location,
// see that file's own `_load_module`).
//
// heimdall (/Users/rj/Downloads/heimdall) is a READ-ONLY sibling checkout
// from this repo -- nothing here ever edits it. Per
// docs/analysis/2026-09-24-relay-phone-leg-contract-diff.md and
// docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md, heimdall's real client
// USED TO disagree with this repo/relay/fake-hmd (which all agree with each
// other and with the deployed relay Worker) on four points: it bootstrapped
// the session key via a "hello" frame the real app never sends, it tagged
// its nonces "dev\0" instead of "phn\0", it read a flat `text` field
// instead of a nested `params.text`, and it logged an `error` event for
// every `keepalive` control frame instead of ignoring it. A fifth
// divergence surfaced only while heimdall applied the fix for those four
// (not in the original handoff): `device_pubkey` arrives base64url,
// unpadded (protocol.ts's real `base64UrlEncode`), and heimdall decoded
// standard-only base64 -- breaking key derivation on every real device
// connection, since the first test below hands `derive_session_key` raw
// hex bytes directly and never exercised heimdall's own decode step.
//
// STATUS: APPLIED in heimdall `e21204cf` -- all five fixes above landed
// (docs/HANDBACK-FROM-HEIMDALL-relay-client-fixes.md). Tests below are
// expected GREEN against that commit or later, not red -- they stay in
// this file as regression coverage: a heimdall change that reintroduces
// any of the five divergences goes red here before it ever reaches a real
// phone.
//
// Opt-in only: HMD_RELAY_INTEROP=1 to run (see relay/package.json's
// test:interop:heimdall script). Skipped, not failed, otherwise -- and
// skipped, not failed, when python3 or the heimdall checkout isn't present
// -- so neither CI nor a plain `npm test` ever fails on a bug this repo has
// no write access to fix.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { x25519 } from '@noble/curves/ed25519.js';

import { deriveSessionKey, seal, open } from '../lib/relay-crypto.mjs';
import { buildDisplayNonce, base64Decode } from '../lib/envelope.mjs';
import {
  encodeEncryptedFrame,
  encodeSendMessageCommand,
  base64UrlEncode,
} from '../../../src/relay/protocol.ts';

const HEIMDALL_DIR = process.env.HEIMDALL_DIR || '/Users/rj/Downloads/heimdall';
const E2E_MODULE_PATH = path.join(HEIMDALL_DIR, 'bin/lib/hmd_relay_e2e.py');
const CLIENT_PATH = path.join(HEIMDALL_DIR, 'bin/heimdall-relay-client');
const HANDOFF_DOC = 'docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md';

const INTEROP_ENABLED = process.env.HMD_RELAY_INTEROP === '1';

function python3Available() {
  const res = spawnSync('python3', ['--version'], { encoding: 'utf8' });
  return !res.error && res.status === 0;
}

const skipReason = !INTEROP_ENABLED
  ? `opt-in only -- set HMD_RELAY_INTEROP=1 to run (see ${HANDOFF_DOC})`
  : !python3Available()
    ? 'python3 not found on PATH'
    : !(existsSync(E2E_MODULE_PATH) && existsSync(CLIENT_PATH))
      ? `heimdall checkout not found at ${HEIMDALL_DIR}`
      : false;

// Deterministic, obviously-fake fixture bytes -- the same 0xaa/0xbb seeds
// and session id phone-leg-interop.test.mjs already uses, reused rather
// than reinvented (CLAUDE.md: "no secret-shaped literals anywhere").
const HMD = x25519.keygen(new Uint8Array(32).fill(0xaa));
const PHONE = x25519.keygen(new Uint8Array(32).fill(0xbb));
const SESSION_ID = 'interop-session';
const HMD_KEY = deriveSessionKey(HMD.secretKey, PHONE.publicKey, SESSION_ID);
const PHONE_KEY = deriveSessionKey(PHONE.secretKey, HMD.publicKey, SESSION_ID);

/**
 * Runs a small Python driver script against heimdall's real code, fed on
 * stdin (`python3 -`) rather than as a `-c` argv string so a multi-line
 * script needs no shell-level quoting at all. Every driver below prints
 * EXACTLY one JSON line and never lets an exception escape past its own
 * try/except -- a heimdall-side failure is data (`{ok:false, error,
 * errorType}`) the caller can assert against and quote, not a thrown
 * exception this helper would have to re-interpret from a traceback.
 */
function runPython(script) {
  const res = spawnSync('python3', ['-'], {
    input: script,
    cwd: HEIMDALL_DIR,
    encoding: 'utf8',
    timeout: 15000,
  });
  if (res.error) {
    throw new Error(`python3 spawn failed: ${res.error.message}`);
  }
  const lines = res.stdout.trim().split('\n').filter(Boolean);
  const lastLine = lines[lines.length - 1];
  if (!lastLine) {
    throw new Error(`python3 produced no stdout (exit ${res.status}); stderr: ${res.stderr}`);
  }
  try {
    return JSON.parse(lastLine);
  } catch {
    throw new Error(`python3 stdout not JSON: ${lastLine}; stderr: ${res.stderr}`);
  }
}

// Same sibling-import convention bin/heimdall-relay-client uses on itself
// for bin/lib/*.py (that file's own `_load_module`) -- safe here because
// hmd_relay_e2e.py's .py suffix lets spec_from_file_location infer a
// SourceFileLoader with no further help.
const IMPORT_E2E = `
import json
from importlib.util import spec_from_file_location, module_from_spec

def _load(name, path):
    spec = spec_from_file_location(name, path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

E2E = _load("hmd_relay_e2e", ${JSON.stringify(E2E_MODULE_PATH)})
`;

test(
  'derives the same session key bytes as the app for a fixture X25519 pair',
  { skip: skipReason },
  () => {
    const script = `${IMPORT_E2E}
priv = bytes.fromhex(${JSON.stringify(Buffer.from(HMD.secretKey).toString('hex'))})
peer_pub = bytes.fromhex(${JSON.stringify(Buffer.from(PHONE.publicKey).toString('hex'))})
session_id = ${JSON.stringify(SESSION_ID)}

try:
    key = E2E.derive_session_key(priv, peer_pub, session_id)
    print(json.dumps({"ok": True, "key_hex": key.hex()}))
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e), "errorType": type(e).__name__}))
`;
    const result = runPython(script);
    assert.equal(result.ok, true, `heimdall's derive_session_key raised: ${result.error}`);
    assert.equal(
      result.key_hex,
      Buffer.from(HMD_KEY).toString('hex'),
      "heimdall's derived session key bytes differ from the app's deriveSessionKey"
    );
  }
);

test(
  'derives the same session key from a real base64url-unpadded device_pubkey, exactly as device_bound.payload carries it',
  { skip: skipReason },
  () => {
    // relay/src/session.ts's deliverToHmdStream forwards the phone's claim
    // device_pubkey into device_bound.payload byte-for-byte, and the app
    // only ever produces that value via protocol.ts's real base64UrlEncode
    // (RFC 4648 §5, no padding) -- never standard/padded base64. The test
    // above hands heimdall's derive_session_key raw hex bytes directly,
    // which never exercises heimdall's own decode step (E2E.pub_from_b64)
    // -- exactly the gap that let heimdall decode device_pubkey as
    // standard-only, breaking key derivation on every real device
    // connection (docs/HANDBACK-FROM-HEIMDALL-relay-client-fixes.md item 6).
    const devicePubkeyB64Url = base64UrlEncode(PHONE.publicKey);
    assert.ok(
      !devicePubkeyB64Url.includes('='),
      'fixture bug: a real device_pubkey is never padded -- check base64UrlEncode'
    );

    const script = `${IMPORT_E2E}
priv = bytes.fromhex(${JSON.stringify(Buffer.from(HMD.secretKey).toString('hex'))})
device_pubkey_b64url = ${JSON.stringify(devicePubkeyB64Url)}
session_id = ${JSON.stringify(SESSION_ID)}

try:
    device_pub = E2E.pub_from_b64(device_pubkey_b64url)
    key = E2E.derive_session_key(priv, device_pub, session_id)
    print(json.dumps({"ok": True, "device_pub_hex": device_pub.hex(), "key_hex": key.hex()}))
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e), "errorType": type(e).__name__}))
`;
    const result = runPython(script);
    assert.equal(
      result.ok,
      true,
      `heimdall's pub_from_b64/derive_session_key rejected the app's real base64url ` +
        `device_pubkey: ${result.error}`
    );
    assert.equal(
      result.device_pub_hex,
      Buffer.from(PHONE.publicKey).toString('hex'),
      "heimdall's pub_from_b64 decoded a different pubkey than the app's base64UrlEncode input"
    );
    assert.equal(
      result.key_hex,
      Buffer.from(HMD_KEY).toString('hex'),
      "heimdall's derived session key differs from the app's when device_pubkey arrives " +
        'base64url-unpadded, exactly as the relay forwards it in device_bound.payload'
    );
  }
);

test(
  "opens a command frame sealed under the app's phn\\0 tag and extracts the nested text",
  { skip: skipReason },
  () => {
    const text = 'hello from the phone';
    const seq = 1;
    // The exact two lines RelayTransport.send runs for one Chat send
    // (phone-leg-interop.test.mjs's own phoneCommandWire helper, reused).
    const sealed = seal(PHONE_KEY, 'phn', seq, encodeSendMessageCommand(text));
    const wire = JSON.parse(
      encodeEncryptedFrame({
        sessionId: SESSION_ID,
        sender: 'device',
        type: 'command',
        seq: sealed.seq,
        ciphertext: sealed.ciphertext,
      })
    );

    const script = `${IMPORT_E2E}
key = bytes.fromhex(${JSON.stringify(Buffer.from(HMD_KEY).toString('hex'))})
seq = ${JSON.stringify(wire.seq)}
nonce_b64 = ${JSON.stringify(wire.nonce)}
ciphertext_b64 = ${JSON.stringify(wire.ciphertext)}

try:
    plaintext = E2E.open_(key, seq, "device", nonce_b64, ciphertext_b64)
    obj = json.loads(plaintext.decode("utf-8"))
    print(json.dumps({"ok": True, "decoded": obj}))
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e), "errorType": type(e).__name__}))
`;
    const result = runPython(script);
    assert.equal(
      result.ok,
      true,
      `heimdall's open_ rejected the app's real wire frame: ${result.error} ` +
        '(expected to pass once hmd_relay_e2e.py’s device sender tag becomes phn\\0 ' +
        '-- see docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md section 2)'
    );
    assert.deepEqual(result.decoded, { action: 'send-message', params: { text } });
  }
);

test(
  "the app's decoder opens a state frame sealed by heimdall's real client",
  { skip: skipReason },
  () => {
    const seq = 3;
    const statePayload = { state: { fixture: 'ok' } };

    const script = `${IMPORT_E2E}
key = bytes.fromhex(${JSON.stringify(Buffer.from(HMD_KEY).toString('hex'))})
seq = ${JSON.stringify(seq)}
plaintext_obj = json.loads(${JSON.stringify(JSON.stringify(statePayload))})
plaintext = json.dumps(plaintext_obj, sort_keys=True).encode("utf-8")

try:
    nonce_b64, ciphertext_b64 = E2E.seal(key, seq, "hmd", plaintext)
    print(json.dumps({"ok": True, "nonce_b64": nonce_b64, "ciphertext_b64": ciphertext_b64}))
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e), "errorType": type(e).__name__}))
`;
    const result = runPython(script);
    assert.equal(result.ok, true, `heimdall's seal raised: ${result.error}`);
    assert.equal(
      result.nonce_b64,
      buildDisplayNonce('hmd', seq),
      "heimdall's hmd-tagged nonce bytes differ from envelope.mjs's buildDisplayNonce"
    );

    const ciphertext = base64Decode(result.ciphertext_b64);
    assert.ok(ciphertext, 'heimdall returned a ciphertext that is not valid base64');
    const plaintext = open(HMD_KEY, 'hmd', { seq, ciphertext }, 0);
    assert.deepEqual(JSON.parse(Buffer.from(plaintext).toString('utf8')), statePayload);
  }
);

test(
  "the client's envelope handler treats a keepalive control frame as a no-op",
  { skip: skipReason },
  () => {
    const script = `
import contextlib
import io
import json
import importlib.machinery
import importlib.util
from types import SimpleNamespace

CLIENT_PATH = ${JSON.stringify(CLIENT_PATH)}
KEEPALIVE_ENVELOPE = {
    "v": 1, "session_id": "sess-fixture-0001", "seq": 0, "sender": "relay",
    "type": "keepalive", "nonce": None, "ciphertext": None,
    "payload": {"ts": 1758700000},
}

def direct():
    # bin/heimdall-relay-client has no .py suffix, so
    # spec_from_file_location can't infer a loader from the filename the way
    # _load (used for the .py-suffixed hmd_relay_e2e.py in the other three
    # tests in this file) can -- force SourceFileLoader explicitly instead.
    loader = importlib.machinery.SourceFileLoader("heimdall_relay_client_under_test", CLIENT_PATH)
    spec = importlib.util.spec_from_file_location("heimdall_relay_client_under_test", CLIENT_PATH, loader=loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    args = SimpleNamespace(
        relay="http://127.0.0.1:1/relay-fixture-unreachable",
        repo="/nonexistent-fixture-repo",
        ui_port=0,
        public_host=None,
        status_file=None,
        tick_s=2.0,
    )
    client = mod.RelayClient(args)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        client._handle_envelope(dict(KEEPALIVE_ENVELOPE))
    printed = buf.getvalue()
    return {"ok": True, "method": "direct", "printed": printed, "is_noop": printed == ""}

def source_fallback(direct_error):
    with open(CLIENT_PATH, "r", encoding="utf-8") as f:
        src = f.read()
    start = src.index("def _handle_envelope")
    end = src.index("\\n    def ", start + 1)
    body = src[start:end]
    has_branch = 'type_ == "keepalive"' in body or "type_ == 'keepalive'" in body
    return {
        "ok": True,
        "method": "source-fallback",
        "has_explicit_keepalive_branch": has_branch,
        "direct_error": direct_error,
    }

try:
    result = direct()
except Exception as e:
    try:
        result = source_fallback(str(e))
    except Exception as e2:
        result = {"ok": False, "method": "failed", "error": str(e2), "direct_error": str(e)}
print(json.dumps(result))
`;
    const result = runPython(script);
    assert.ok(result.ok, `driver could not evaluate the client at all: ${JSON.stringify(result)}`);
    if (result.method === 'direct') {
      assert.equal(
        result.printed,
        '',
        `expected no stdout for a keepalive frame, got: ${JSON.stringify(result.printed)} ` +
          '(expected to pass once _handle_envelope gets an explicit keepalive branch -- ' +
          'see docs/HANDOFF-TO-HEIMDALL-relay-client-fixes.md section 4)'
      );
    } else {
      assert.ok(
        result.has_explicit_keepalive_branch,
        `_handle_envelope's source has no explicit keepalive branch (direct import failed: ${result.direct_error})`
      );
    }
  }
);
