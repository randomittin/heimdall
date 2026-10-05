// scripts/health-check.sh is the one piece of the deploy pipeline's canary logic that is not
// declarative YAML: the retry loop that decides whether a freshly deployed Worker is the build we
// just shipped (.github/workflows/relay-deploy.yml). These tests run the REAL script -- bash, curl
// and jq, as on the CI runner -- against an in-process fake relay whose /health answers are
// scripted, so every branch of that decision runs without a network or a Cloudflare account.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';

const SCRIPT = fileURLToPath(new URL('../health-check.sh', import.meta.url));

const OLD = '0'.repeat(40);
const NEW = '1'.repeat(40);

const healthy = (version) => ({ status: 200, body: JSON.stringify({ ok: true, version }) });

/**
 * Serves `script`'s answers to successive requests, repeating the last one forever, and records
 * every request so a test can say how many attempts the script made and what it asked for.
 */
async function fakeRelay(script) {
  const requests = [];
  const server = createServer((req, res) => {
    requests.push({ method: req.method, url: req.url });
    const answer = script[Math.min(requests.length, script.length) - 1];
    res.writeHead(answer.status, { 'content-type': 'application/json' });
    res.end(answer.body);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  const close = () => {
    server.closeAllConnections();
    return new Promise((resolve) => server.close(resolve));
  };
  return { url, requests, close };
}

async function withRelay(script, body) {
  const relay = await fakeRelay(script);
  try {
    await body(relay);
  } finally {
    await relay.close();
  }
}

/** Runs the real script. Resolves { code, stdout, stderr, output } whatever the exit status. */
function run(args, env = {}) {
  return new Promise((resolve) => {
    execFile(
      'bash',
      [SCRIPT, ...args],
      { env: { ...process.env, HEALTH_ATTEMPTS: '3', HEALTH_DELAY_S: '0', ...env }, timeout: 60_000 },
      (error, stdout, stderr) =>
        resolve({ code: error ? error.code : 0, stdout, stderr, output: stdout + stderr }),
    );
  });
}

test('passes on the first healthy answer and reports the version it saw', () =>
  withRelay([healthy(NEW)], async (relay) => {
    const { code, stdout } = await run([relay.url]);
    assert.equal(code, 0);
    assert.ok(stdout.includes(`healthy: ${relay.url}/health reports version ${NEW}`), stdout);
    assert.deepEqual(relay.requests, [{ method: 'GET', url: '/health' }]);
  }));

test('with an expected version it passes on exactly that version', () =>
  withRelay([healthy(NEW)], async (relay) => {
    const { code } = await run([relay.url, NEW]);
    assert.equal(code, 0);
  }));

test('a stale build that still answers 200 does not pass: it retries until the new version appears', () =>
  withRelay([healthy(OLD), healthy(OLD), healthy(NEW)], async (relay) => {
    const { code, stderr } = await run([relay.url, NEW], { HEALTH_ATTEMPTS: '5' });
    assert.equal(code, 0);
    assert.equal(relay.requests.length, 3);
    assert.ok(stderr.includes(`serving version ${OLD}, want ${NEW}`), stderr);
  }));

test('gives up with exit 1 after HEALTH_ATTEMPTS when the version never matches, naming both versions', () =>
  withRelay([healthy(OLD)], async (relay) => {
    const { code, stderr } = await run([relay.url, NEW], { HEALTH_ATTEMPTS: '4' });
    assert.equal(code, 1);
    assert.equal(relay.requests.length, 4);
    assert.ok(stderr.includes(`serving version ${OLD}, want ${NEW}`), stderr);
    assert.match(stderr, /unhealthy: .*never reported healthy at version 1{40} in 4 attempts/);
  }));

test('retries through server errors', () =>
  withRelay(
    [{ status: 503, body: 'upstream down' }, { status: 502, body: 'bad gateway' }, healthy(NEW)],
    async (relay) => {
      const { code } = await run([relay.url, NEW], { HEALTH_ATTEMPTS: '5' });
      assert.equal(code, 0);
      assert.equal(relay.requests.length, 3);
    },
  ));

test('{"ok":false} never passes, even carrying the right version', () =>
  withRelay([{ status: 200, body: JSON.stringify({ ok: false, version: NEW }) }], async (relay) => {
    const { code } = await run([relay.url, NEW], { HEALTH_ATTEMPTS: '2' });
    assert.equal(code, 1);
    assert.equal(relay.requests.length, 2);
  }));

for (const [label, body] of [
  ['an HTML page', '<html>not a relay</html>'],
  ['ok:true with no version', '{"ok":true}'],
  ['a numeric version', '{"ok":true,"version":7}'],
  ['ok as a string', '{"ok":"true","version":"v1"}'],
  ['an empty body', ''],
]) {
  test(`a 200 that is not the health shape never passes: ${label}`, () =>
    withRelay([{ status: 200, body }], async (relay) => {
      const { code } = await run([relay.url], { HEALTH_ATTEMPTS: '2' });
      assert.equal(code, 1);
      assert.equal(relay.requests.length, 2);
    }));
}

test('a version with unexpected characters is not trusted and never echoed into the log', () =>
  // A line starting `::` in a GitHub Actions log is a workflow command; whatever answers the probe
  // must not be able to author one.
  withRelay([healthy('v1\n::error::injected')], async (relay) => {
    const { code, output } = await run([relay.url], { HEALTH_ATTEMPTS: '2' });
    assert.equal(code, 1);
    assert.ok(!output.includes('::error::injected'), output);
  }));

test('prints the version it checks and nothing else from a passing response', () =>
  withRelay(
    [{ status: 200, body: JSON.stringify({ ok: true, version: 'v1', debug: 'LEAK-MARKER' }) }],
    async (relay) => {
      const { code, output } = await run([relay.url]);
      assert.equal(code, 0);
      assert.ok(!output.includes('LEAK-MARKER'), output);
    },
  ));

test('does not echo the body of a failing answer either', () =>
  withRelay(
    [{ status: 200, body: '<html>LEAK-MARKER</html>' }, { status: 503, body: 'LEAK-MARKER' }],
    async (relay) => {
      const { code, output } = await run([relay.url], { HEALTH_ATTEMPTS: '2' });
      assert.equal(code, 1);
      assert.equal(relay.requests.length, 2);
      assert.ok(!output.includes('LEAK-MARKER'), output);
    },
  ));

test('an unreachable relay fails after the attempts instead of hanging', async () => {
  const relay = await fakeRelay([healthy(NEW)]);
  const { url } = relay;
  await relay.close();
  const { code, stderr } = await run([url], { HEALTH_ATTEMPTS: '2' });
  assert.equal(code, 1);
  assert.match(stderr, /attempt 2\/2: request failed/);
});

test('a trailing slash on the base URL still requests exactly /health', () =>
  withRelay([healthy(NEW)], async (relay) => {
    const { code } = await run([`${relay.url}/`]);
    assert.equal(code, 0);
    assert.deepEqual(relay.requests, [{ method: 'GET', url: '/health' }]);
  }));

for (const [label, args, env] of [
  ['no base URL', [], {}],
  ['a base URL that is not http(s)', ['ftp://relay.example.test'], {}],
  ['HEALTH_ATTEMPTS=0', ['http://127.0.0.1:9'], { HEALTH_ATTEMPTS: '0' }],
  ['HEALTH_ATTEMPTS not a number', ['http://127.0.0.1:9'], { HEALTH_ATTEMPTS: 'many' }],
  ['HEALTH_DELAY_S negative', ['http://127.0.0.1:9'], { HEALTH_DELAY_S: '-1' }],
]) {
  test(`usage error exits 2 before any request: ${label}`, async () => {
    const { code } = await run(args, env);
    assert.equal(code, 2);
  });
}
