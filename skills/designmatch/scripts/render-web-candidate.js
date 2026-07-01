#!/usr/bin/env node
/*
 * render-web-candidate.js
 *
 * Render the CANDIDATE (your real web app) to a PNG at the locked designmatch
 * viewport (1080x2444, deviceScaleFactor=1) using Playwright ONLY — no adb, no
 * xcrun, no emulator. This is what kills the device dependency: the candidate
 * comes from a running web/Storybook URL or a static HTML build, exactly like
 * the canonical, so both sides of the diff are Playwright-rendered.
 *
 * Two candidate sources:
 *   --url  <http://...>   render a running server (Storybook / dev server / preview)
 *   --html <path/to.html> serve the file's directory statically and render it
 *
 * Required npm deps (install in the consumer project, same as the canonical
 * renderer): npm i playwright
 *
 * CLI:
 *   node render-web-candidate.js (--url <url> | --html <file>) --out <png> \
 *     [--state <state.json>] [--screen <Name>] [--wait <ms|selector>] \
 *     [--viewport <WxH>]
 *
 * Exit:
 *   0 on success, prints {"ok":true,...} to stdout
 *   1 on failure, prints {"ok":false,"error":"..."} to stdout (install-hint on
 *     a missing Playwright, matching the existing degrade-cleanly pattern)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const net = require('net');

const DEFAULT_WIDTH = 1080;
const DEFAULT_HEIGHT = 2444;

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.jsx': 'text/babel; charset=utf-8',
  '.ts': 'application/typescript; charset=utf-8',
  '.tsx': 'text/babel; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

function usage() {
  return (
    'Usage: node render-web-candidate.js (--url <url> | --html <file>) --out <png> ' +
    '[--state <state.json>] [--screen <Name>] [--wait <ms|selector>] [--viewport <WxH>]'
  );
}

function fail(msg, err) {
  const payload = { ok: false, error: String(msg) };
  if (err && err.stack) payload.stack = err.stack;
  process.stdout.write(JSON.stringify(payload) + '\n');
  process.exit(1);
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function safeJoin(root, reqPath) {
  let p = reqPath.split('?')[0].split('#')[0];
  try {
    p = decodeURIComponent(p);
  } catch (_) {
    return null;
  }
  const resolved = path.normalize(path.join(root, p));
  if (!resolved.startsWith(path.normalize(root))) return null;
  return resolved;
}

function startStaticServer(rootDir, port, indexBase) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let urlPath = req.url || '/';
      if (urlPath === '/' || urlPath === '') urlPath = '/' + indexBase;
      const filePath = safeJoin(rootDir, urlPath);
      if (!filePath) {
        res.writeHead(400);
        res.end('bad path');
        return;
      }
      fs.stat(filePath, (err, st) => {
        if (err || !st.isFile()) {
          res.writeHead(404);
          res.end('not found');
          return;
        }
        const ext = path.extname(filePath).toLowerCase();
        const ctype = MIME_TYPES[ext] || 'application/octet-stream';
        res.writeHead(200, {
          'Content-Type': ctype,
          'Content-Length': st.size,
          'Cache-Control': 'no-store',
        });
        const stream = fs.createReadStream(filePath);
        stream.on('error', () => {
          try {
            res.destroy();
          } catch (_) {}
        });
        stream.pipe(res);
      });
    });
    server.on('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

function parseViewport(v) {
  if (!v || v === true) return { width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT };
  const m = String(v).match(/^(\d+)x(\d+)$/i);
  if (!m) return { width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT };
  return { width: Number(m[1]), height: Number(m[2]) };
}

async function applyWait(page, args) {
  // Explicit wait wins: numeric ms or a CSS selector.
  if (args.wait !== undefined && args.wait !== true) {
    const w = String(args.wait);
    if (/^\d+$/.test(w.trim())) {
      await page.waitForTimeout(Number(w));
      return;
    }
    await page.waitForSelector(w, { timeout: 60_000 });
    return;
  }
  // Default: prefer an explicit readiness flag (generated candidates set it);
  // fall back to network idle + a short settle for arbitrary web apps.
  try {
    await page.waitForFunction(() => window.__APP_READY__ === true, null, {
      timeout: 3000,
    });
    return;
  } catch (_) {
    // no readiness flag — treat as a generic app.
  }
  try {
    await page.waitForLoadState('networkidle', { timeout: 15_000 });
  } catch (_) {}
  await page.waitForTimeout(400);
}

async function main() {
  const args = parseArgs(process.argv);
  const hasUrl = args.url && args.url !== true;
  const hasHtml = args.html && args.html !== true;
  if ((!hasUrl && !hasHtml) || (hasUrl && hasHtml) || !args.out) {
    fail(usage());
  }

  const outPath = path.resolve(String(args.out));
  const viewport = parseViewport(args.viewport);

  let state = null;
  if (args.state && args.state !== true) {
    const statePath = path.resolve(String(args.state));
    if (!fs.existsSync(statePath)) fail(`state not found: ${statePath}`);
    try {
      state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    } catch (e) {
      fail(`invalid state JSON: ${e.message}`);
    }
  }

  // Lazy require so usage errors don't require Playwright to be installed.
  let chromium;
  try {
    ({ chromium } = require('playwright'));
  } catch (e) {
    fail('playwright not installed. Run: npm i playwright', e);
  }

  fs.mkdirSync(path.dirname(outPath), { recursive: true });

  let server = null;
  let targetUrl;
  if (hasHtml) {
    const htmlPath = path.resolve(String(args.html));
    if (!fs.existsSync(htmlPath)) fail(`html not found: ${htmlPath}`);
    const rootDir = path.dirname(htmlPath);
    const htmlBase = path.basename(htmlPath);
    const port = await findFreePort();
    server = await startStaticServer(rootDir, port, htmlBase);
    targetUrl = `http://127.0.0.1:${port}/${encodeURIComponent(htmlBase)}`;
  } else {
    targetUrl = String(args.url);
  }

  let browser = null;
  const cleanup = async () => {
    try {
      if (browser) await browser.close();
    } catch (_) {}
    try {
      if (server) server.close();
    } catch (_) {}
  };

  const onSigint = () => {
    cleanup().finally(() => process.exit(130));
  };
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigint);

  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: viewport.width, height: viewport.height },
      deviceScaleFactor: 1,
      screen: { width: viewport.width, height: viewport.height },
    });

    if (state || (args.screen && args.screen !== true)) {
      const initScript = `
        (function(){
          try { ${state ? `window.__VQA_STATE__ = ${JSON.stringify(state)};` : ''} } catch(e) {}
          ${
            args.screen && args.screen !== true
              ? `try { window.__VQA_SCREEN__ = ${JSON.stringify(String(args.screen))}; } catch(e) {}`
              : ''
          }
        })();
      `;
      await context.addInitScript({ content: initScript });
    }

    const page = await context.newPage();
    page.on('pageerror', (e) => {
      process.stderr.write(`[pageerror] ${e.message}\n`);
    });
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        process.stderr.write(`[console.error] ${msg.text()}\n`);
      }
    });

    await page.goto(targetUrl, { waitUntil: 'load', timeout: 60_000 });
    await applyWait(page, args);

    await page.screenshot({
      path: outPath,
      fullPage: false,
      clip: { x: 0, y: 0, width: viewport.width, height: viewport.height },
      type: 'png',
    });

    process.stdout.write(
      JSON.stringify({
        ok: true,
        width: viewport.width,
        height: viewport.height,
        out: outPath,
        source: hasHtml ? 'html' : 'url',
      }) + '\n'
    );
  } catch (e) {
    await cleanup();
    process.off('SIGINT', onSigint);
    process.off('SIGTERM', onSigint);
    fail(`render failed: ${e.message}`, e);
    return;
  }

  await cleanup();
  process.off('SIGINT', onSigint);
  process.off('SIGTERM', onSigint);
  process.exit(0);
}

main().catch((e) => fail(e.message || String(e), e));
