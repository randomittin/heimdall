#!/usr/bin/env node
// INV-8: the relay must never log a full request URL — on the phone leg
// that URL carries `pairing_code`/`device_token` in its query string. Plain
// Node script (not a vitest test) because it needs real filesystem access,
// which the vitest-pool-workers runtime deliberately does not provide
// (Workers have no filesystem in production). Wired into `npm test` so it
// runs on every CI/local run, same as the vitest suite.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const srcDir = fileURLToPath(new URL("../src", import.meta.url));

function collectTsFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? collectTsFiles(full) : name.endsWith(".ts") ? [full] : [];
  });
}

const files = collectTsFiles(srcDir);
const failures = [];

for (const file of files) {
  const text = readFileSync(file, "utf8");
  const isLoggingModule = file.endsWith(`${join("src", "logging.ts")}`);
  const consoleCallCount = (text.match(/console\.(log|warn|error|info)\(/g) ?? []).length;

  if (consoleCallCount > 0 && !isLoggingModule) {
    failures.push(`${file}: raw console.* call outside logging.ts (route logging through logEvent)`);
  }
  if (/console\.[a-z]+\([^;]*\.url/i.test(text)) {
    failures.push(`${file}: a console.* call appears to reference a .url value`);
  }
}

if (failures.length > 0) {
  console.error("no-logged-urls check FAILED:");
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}

console.log(`no-logged-urls check passed (${files.length} source files scanned).`);
