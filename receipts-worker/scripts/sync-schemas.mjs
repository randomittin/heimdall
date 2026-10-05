// The receipt schemas have ONE source: docs/schemas/ (bin/lib/runhmd_schema.py reads them there).
// The Worker bundles its own copies in schema/ so it deploys and tests as a self-contained package.
//
//   node scripts/sync-schemas.mjs           copy docs/schemas/* over schema/*
//   node scripts/sync-schemas.mjs --check   exit 1 if any copy differs (what `npm test` runs)
//
// Outside the heimdall tree (docs/schemas absent) --check has nothing to compare and says so.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = join(here, "..", "..", "docs", "schemas");
const target = join(here, "..", "schema");
const NAMES = ["runhmd.receipt.v1.json", "runhmd.verdict.v1.json"];
const check = process.argv.includes("--check");

if (!existsSync(source)) {
  process.stdout.write(`sync-schemas: ${source} does not exist; nothing to ${check ? "check" : "copy"}\n`);
  process.exit(0);
}

let drift = 0;
for (const name of NAMES) {
  const want = readFileSync(join(source, name));
  const have = existsSync(join(target, name)) ? readFileSync(join(target, name)) : null;
  const same = have !== null && want.equals(have);
  if (check) {
    if (!same) {
      process.stderr.write(`sync-schemas: schema/${name} differs from docs/schemas/${name}; run npm run sync-schemas\n`);
      drift += 1;
    }
  } else if (!same) {
    mkdirSync(target, { recursive: true });
    writeFileSync(join(target, name), want);
    process.stdout.write(`sync-schemas: updated schema/${name}\n`);
  }
}
process.exit(drift ? 1 : 0);
