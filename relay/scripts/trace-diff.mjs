#!/usr/bin/env node
// Wave-3 relay-protocol-trace-diff harness runner.
//
// Runs the golden transcript + mutant scenarios under relay/test/trace/**
// (independently authored against relay/docs/INVARIANTS.md
// and relay/README.md's documented API — relay/src/** is read, never
// modified, for this task) and prints one row per in-scope invariant:
// INV -> PASS / FAIL / UNCOVERED. Exits 1 if any row (or the golden
// transcript itself) is FAIL; UNCOVERED is a disclosed, non-failing state —
// see each such row's `uncovered` reason below.
//
// TRACE_UPDATE=1 node scripts/trace-diff.mjs (or: TRACE_UPDATE=1 npm run
// test:trace) regenerates test/trace/golden.json from a fresh run of
// golden.spec.ts, then falls through into the normal verification pass
// against the file it just wrote.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const relayDir = fileURLToPath(new URL("..", import.meta.url));
const srcDir = join(relayDir, "src");
const goldenPath = join(relayDir, "test", "trace", "golden.json");
const goldenSpecRelPath = join("test", "trace", "golden.spec.ts");

// The 17 relay-enforced invariants in scope for this task (delta brief
// `relay-protocol-trace-diff`), grouped as specified: INV-1..5 pairing,
// INV-6..10 auth, INV-16..18 caps, INV-24/25 ack+Retry-After, INV-29/30
// revoke. Mutant titles are copied verbatim from INVARIANTS.md's "Mutant
// (Wave-3)" column.
const INV_TABLE = [
  { inv: 1, title: "MUT-INV-1-double-claim", group: "pairing" },
  { inv: 2, title: "MUT-INV-2-no-ttl", group: "pairing" },
  { inv: 3, title: "MUT-INV-3-precock-leak", group: "pairing" },
  { inv: 4, title: "MUT-INV-4-no-throttle", group: "pairing" },
  { inv: 5, title: "MUT-INV-5-add-identity-gate", group: "pairing" },
  { inv: 6, title: "MUT-INV-6-token-in-query", group: "auth" },
  { inv: 7, title: "MUT-INV-7-allow-plaintext-ws", group: "auth" },
  {
    inv: 8,
    title: "MUT-INV-8-log-raw-url",
    group: "auth",
    uncovered:
      "No HTTP/WS-observable surface for relay-internal log contents -- logging is source-level " +
      "only (relay/src/logging.ts). Already gated at the source level by the pre-existing Wave-1/2 " +
      "relay/scripts/check-no-logged-urls.mjs (wired into `npm test`); re-wiring that same gate into " +
      "this Wave-3 harness would conflate two different gate mechanisms rather than add real coverage.",
  },
  { inv: 9, title: "MUT-INV-9-cache-trust", group: "auth" },
  { inv: 10, title: "MUT-INV-10-delayed-revoke", group: "auth" },
  { inv: 16, title: "MUT-INV-16-no-size-cap", group: "caps" },
  {
    inv: 17,
    title: "MUT-INV-17-unbounded-buffer",
    group: "caps",
    uncovered:
      "relay/src/session.ts's handleFrames (~lines 139-175) has no frame-buffering implementation " +
      "at all -- when no device socket is connected it returns {ok:true, delivered:false} " +
      "immediately and drops the frame (relay/README.md's 'Deviations' section discloses this). " +
      "There is no MAX_BUFFERED_FRAMES/300s-TTL code path to violate, so no mutant can be expressed " +
      "against the current implementation -- a disclosed implementation gap, not an untested path.",
  },
  { inv: 18, title: "MUT-INV-18-relay-holds-key", group: "caps", static: true },
  { inv: 24, title: "MUT-INV-24-duplicate-or-missing-ack", group: "ack-retry" },
  { inv: 25, title: "MUT-INV-25-ignore-retry-after", group: "ack-retry" },
  { inv: 29, title: "MUT-INV-29-partial-revoke", group: "revoke" },
  { inv: 30, title: "MUT-INV-30-token-resurrection", group: "revoke" },
];

function collectTsFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? collectTsFiles(full) : name.endsWith(".ts") ? [full] : [];
  });
}

/** Static check for INV-18 ("relay never possesses the 32-byte session key
 * in any form"). No HTTP/WS-observable surface exists for "absence of a
 * code path", so this greps relay/src for any key-derivation identifier
 * instead of driving a runtime scenario -- the same has-real-filesystem-
 * access reasoning as relay/scripts/check-no-logged-urls.mjs (a vitest test
 * file cannot do this; it runs inside workerd, which has no `fs`). */
function checkInv18StaticNoKeyDerivation() {
  const bannedPattern = /\b(ECDH|HKDF|deriveKey|deriveBits|X25519|session_key|sessionKey)\b/;
  const offenders = [];
  for (const file of collectTsFiles(srcDir)) {
    const text = readFileSync(file, "utf8");
    const match = text.match(bannedPattern);
    if (match) offenders.push(`${file}: matched "${match[0]}"`);
  }
  return { pass: offenders.length === 0, offenders };
}

function runVitestJson(workDir) {
  const outputFile = join(workDir, "report.json");
  const result = spawnSync(
    "npx",
    ["vitest", "run", "test/trace", "--reporter=json", `--outputFile=${outputFile}`],
    { cwd: relayDir, encoding: "utf8" }
  );
  if (result.error) throw result.error;
  const raw = readFileSync(outputFile, "utf8");
  return JSON.parse(raw);
}

function regenerateGolden() {
  const result = spawnSync("npx", ["vitest", "run", goldenSpecRelPath], {
    cwd: relayDir,
    encoding: "utf8",
  });
  const stdout = result.stdout ?? "";
  const startMarker = "###GOLDEN_TRACE_START###";
  const endMarker = "###GOLDEN_TRACE_END###";
  const startIdx = stdout.indexOf(startMarker);
  const endIdx = stdout.indexOf(endMarker);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    console.error("TRACE_UPDATE=1: could not find golden trace markers in vitest output.");
    console.error("--- vitest stdout ---");
    console.error(stdout);
    if (result.stderr) {
      console.error("--- vitest stderr ---");
      console.error(result.stderr);
    }
    process.exit(1);
  }
  const jsonText = stdout.slice(startIdx + startMarker.length, endIdx).trim();
  const parsed = JSON.parse(jsonText);
  writeFileSync(goldenPath, `${JSON.stringify(parsed, null, 2)}\n`);
  console.log(`TRACE_UPDATE=1: regenerated ${goldenPath}`);
}

function extractAssertionResults(report) {
  const results = [];
  for (const fileResult of report.testResults ?? []) {
    for (const assertion of fileResult.assertionResults ?? []) {
      results.push({
        title: assertion.fullName ?? assertion.title ?? "",
        status: assertion.status,
        file: fileResult.name ?? "",
      });
    }
  }
  return results;
}

function statusForRow(row, assertionResults) {
  if (row.uncovered) return { status: "UNCOVERED", note: row.uncovered };
  if (row.static) {
    const { pass, offenders } = checkInv18StaticNoKeyDerivation();
    return pass
      ? { status: "PASS", note: "static source check: no key-derivation identifier found in relay/src" }
      : { status: "FAIL", note: `static source check found: ${offenders.join("; ")}` };
  }
  const matches = assertionResults.filter((a) => a.title.includes(row.title));
  if (matches.length === 0) {
    return { status: "FAIL", note: `no test found with title containing "${row.title}"` };
  }
  const failed = matches.filter((m) => m.status !== "passed");
  return failed.length === 0
    ? { status: "PASS", note: `${matches.length} test(s) passed` }
    : { status: "FAIL", note: `${failed.length}/${matches.length} test(s) failed` };
}

function printTable(goldenStatus, goldenNote, rows) {
  const invCol = 6;
  const titleCol = 40;
  const statusCol = 11;
  const header = `${"INV".padEnd(invCol)}${"Title".padEnd(titleCol)}${"Status".padEnd(statusCol)}Note`;
  console.log(header);
  console.log("-".repeat(header.length + 40));
  console.log(
    `${"golden".padEnd(invCol)}${"golden protocol transcript (5 seeds)".padEnd(titleCol)}${goldenStatus.padEnd(
      statusCol
    )}${goldenNote}`
  );
  for (const row of rows) {
    console.log(
      `${String(row.inv).padEnd(invCol)}${row.title.padEnd(titleCol)}${row.status.padEnd(statusCol)}${row.note}`
    );
  }
}

function main() {
  if (process.env.TRACE_UPDATE === "1") {
    regenerateGolden();
  }

  const workDir = mkdtempSync(join(tmpdir(), "relay-trace-diff-"));
  let report;
  try {
    report = runVitestJson(workDir);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }

  const assertionResults = extractAssertionResults(report);
  const goldenResults = assertionResults.filter((a) => a.file.endsWith(goldenSpecRelPath.replace(/\\/g, "/")));
  const goldenStatus =
    goldenResults.length === 0
      ? "FAIL"
      : goldenResults.some((a) => a.status !== "passed")
        ? "FAIL"
        : "PASS";
  const goldenNote =
    goldenResults.length === 0 ? "no golden.spec.ts test result found" : `${goldenResults.length} assertion(s)`;

  const rows = INV_TABLE.map((row) => ({ ...row, ...statusForRow(row, assertionResults) }));

  printTable(goldenStatus, goldenNote, rows);

  const anyFail = goldenStatus === "FAIL" || rows.some((r) => r.status === "FAIL");
  const uncoveredCount = rows.filter((r) => r.status === "UNCOVERED").length;
  console.log("");
  console.log(
    `${rows.filter((r) => r.status === "PASS").length + (goldenStatus === "PASS" ? 1 : 0)} passed, ` +
      `${rows.filter((r) => r.status === "FAIL").length + (goldenStatus === "FAIL" ? 1 : 0)} failed, ` +
      `${uncoveredCount} uncovered`
  );

  process.exit(anyFail ? 1 : 0);
}

main();
