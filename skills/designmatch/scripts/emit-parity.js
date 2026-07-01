#!/usr/bin/env node
/*
 * emit-parity.js
 *
 * The parity-score RECEIPT emitter. Turns a metrics.json produced by the
 * UNCHANGED SSIM/pixelmatch harness (visual-diff.js) into two drop-in artifacts:
 *
 *   parity.json        { screen, ssim, pixel_diff_pct, parity_pct, pass,
 *                        harness_pass, threshold, triptych, metrics, ts }
 *   parity-badge.svg   a self-contained shields-style badge ("design parity 96%")
 *                      colored by pass — drop straight into a README or PR.
 *
 * This emitter COMPUTES NO SIMILARITY. It only transcribes the harness's real
 * numbers. If metrics.json is missing/invalid it errors — it never invents a
 * parity value (a skipped/absent run must stay absent, never a fabricated pass).
 *
 * Parity policy: `parity_pct` is round(ssim * 100) — the perceptual similarity.
 * `pass` is ssim >= threshold (default 0.95), the CI-relevant SSIM bar. The
 * harness's own OR-gate verdict (SSIM>=0.95 OR pixelDiff<=5%) is preserved
 * verbatim as `harness_pass` so nothing about the underlying math is lost.
 *
 * Deps: node built-ins only (fs, path) — works even when sharp/pixelmatch are
 * absent, since those were only needed to PRODUCE the metrics it reads.
 *
 * CLI:
 *   node emit-parity.js --metrics <metrics.json> --out-dir <dir> \
 *     [--screen <Name>] [--min <0.95>] [--triptych <composite.png>]
 *
 * Exit: 0 on success, 1 on error.
 */

'use strict';

const fs = require('fs');
const path = require('path');

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

function die(msg) {
  process.stderr.write(`emit-parity: ${msg}\n`);
  process.exit(1);
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// Approximate text width (px) for the badge geometry. 7px/char at 11px font is a
// good-enough monospace-ish estimate for a self-contained badge.
function textWidth(s) {
  return Math.max(10, String(s).length * 7 + 10);
}

function buildBadge(label, value, color) {
  const lw = textWidth(label);
  const vw = textWidth(value);
  const total = lw + vw;
  const labelX = lw / 2;
  const valueX = lw + vw / 2;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${total}" height="20" ` +
    `role="img" aria-label="${esc(label)}: ${esc(value)}">\n` +
    `  <title>${esc(label)}: ${esc(value)}</title>\n` +
    `  <linearGradient id="s" x2="0" y2="100%">\n` +
    `    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>\n` +
    `    <stop offset="1" stop-opacity=".1"/>\n` +
    `  </linearGradient>\n` +
    `  <clipPath id="r"><rect width="${total}" height="20" rx="3" fill="#fff"/></clipPath>\n` +
    `  <g clip-path="url(#r)">\n` +
    `    <rect width="${lw}" height="20" fill="#555"/>\n` +
    `    <rect x="${lw}" width="${vw}" height="20" fill="${color}"/>\n` +
    `    <rect width="${total}" height="20" fill="url(#s)"/>\n` +
    `  </g>\n` +
    `  <g fill="#fff" text-anchor="middle" ` +
    `font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">\n` +
    `    <text x="${labelX}" y="15" fill="#010101" fill-opacity=".3">${esc(label)}</text>\n` +
    `    <text x="${labelX}" y="14">${esc(label)}</text>\n` +
    `    <text x="${valueX}" y="15" fill="#010101" fill-opacity=".3">${esc(value)}</text>\n` +
    `    <text x="${valueX}" y="14">${esc(value)}</text>\n` +
    `  </g>\n` +
    `</svg>\n`
  );
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.metrics || args.metrics === true) die('--metrics <metrics.json> required');
  if (!args['out-dir'] || args['out-dir'] === true) die('--out-dir <dir> required');

  const metricsPath = path.resolve(String(args.metrics));
  const outDir = path.resolve(String(args['out-dir']));
  const screen = args.screen && args.screen !== true ? String(args.screen) : 'screen';
  const min = args.min && args.min !== true ? Number(args.min) : 0.95;
  if (!Number.isFinite(min) || min < 0 || min > 1) {
    die(`--min must be 0..1 (got ${args.min})`);
  }

  if (!fs.existsSync(metricsPath)) {
    die(`metrics not found: ${metricsPath} (run the SSIM/pixelmatch harness first)`);
  }
  let metrics;
  try {
    metrics = JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
  } catch (e) {
    die(`invalid metrics JSON: ${e.message}`);
  }

  const ssim = Number(metrics.ssim);
  const pixelDiffPct = Number(metrics.pixelDiffPct);
  if (!Number.isFinite(ssim) || !Number.isFinite(pixelDiffPct)) {
    die('metrics missing numeric ssim / pixelDiffPct — cannot transcribe a parity');
  }

  const parityPct = Math.round(ssim * 100);
  const pass = ssim >= min; // CI-relevant SSIM bar.
  const harnessPass = metrics.pass === true; // the harness OR-gate, preserved.

  let triptych = null;
  if (args.triptych && args.triptych !== true) {
    triptych = path.resolve(String(args.triptych));
  } else {
    const guess = path.join(path.dirname(metricsPath), 'composite.png');
    if (fs.existsSync(guess)) triptych = guess;
  }

  fs.mkdirSync(outDir, { recursive: true });

  const parity = {
    screen,
    ssim,
    pixel_diff_pct: pixelDiffPct,
    parity_pct: parityPct,
    pass,
    harness_pass: harnessPass,
    threshold: min,
    triptych,
    metrics: metricsPath,
    ts: new Date().toISOString(),
  };
  const parityPath = path.join(outDir, 'parity.json');
  fs.writeFileSync(parityPath, JSON.stringify(parity, null, 2) + '\n');

  // Green when it clears the bar; amber (deliberately NOT green) when it does not.
  const color = pass ? '#3fb950' : '#d29922';
  const mark = pass ? '✓' : '✗'; // ✓ / ✗
  const badge = buildBadge('design parity', `${parityPct}% ${mark}`, color);
  const badgePath = path.join(outDir, 'parity-badge.svg');
  fs.writeFileSync(badgePath, badge);

  process.stdout.write(
    `design parity ${parityPct}% ${mark} (ssim ${ssim.toFixed(4)} | ` +
      `pixel-diff ${pixelDiffPct.toFixed(2)}% | threshold ${min}) ` +
      `${pass ? 'PASS' : 'BELOW THRESHOLD'}\n` +
      `  receipt: ${parityPath}\n` +
      `  badge:   ${badgePath}\n` +
      (triptych ? `  triptych: ${triptych}\n` : '')
  );
  process.exit(0);
}

main();
