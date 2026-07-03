// grade.mjs — the acceptance-oracle executor for the rr-multitenant-isolation gate.
//
// Imports a candidate isolation module and runs its default evaluate(attackId) against
// every cross-tenant attack case in the acceptance oracle, emitting one TAB-separated
// result line per case:
//
//     <attackId>\t<decision>          decision in {DENY, ALLOW}
//
// It performs NO comparison itself — run.sh (bash) is the single source of diff-truth
// and decides pass/fail by zipping these lines against the acceptance expecteds (all
// DENY). This mirrors the ponytail-underdelivery / emulator-gb / exchange-lob split:
// the node helper produces the subject output, the shell gate diffs it.
//
// Robustness: a candidate that fails to import, does not export a function, throws, or
// returns a non-string is NOT allowed to crash the grader — each is encoded into the
// output stream so run.sh always sees a gradable divergence (never a silent green from
// a dead process). Exit is always 0; the VERDICT is run.sh's to make from report.json.
//
// Usage: node grade.mjs <candidate-path> <acceptance-json-path>
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const encode = (s) =>
  String(s).replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\r/g, "\\r").replace(/\n/g, "\\n");

async function main() {
  const candPath = process.argv[2];
  const accPath = process.argv[3];
  if (!candPath || !accPath) {
    process.stdout.write("__LOADERR__\tusage: node grade.mjs <candidate-path> <acceptance-json-path>\n");
    return;
  }

  let acc;
  try {
    acc = JSON.parse(readFileSync(accPath, "utf8"));
  } catch (e) {
    process.stdout.write("__LOADERR__\tacceptance oracle unreadable: " + encode((e && e.message) || e) + "\n");
    return;
  }
  const cases = Array.isArray(acc.cases) ? acc.cases : [];

  const candUrl = candPath.startsWith("file:") ? candPath : pathToFileURL(resolve(candPath)).href;

  let evaluate;
  try {
    const mod = await import(candUrl);
    evaluate = mod && (mod.default || mod.evaluate);
  } catch (e) {
    process.stdout.write("__LOADERR__\tcandidate module failed to import: " + encode((e && e.message) || e) + "\n");
    return;
  }
  if (typeof evaluate !== "function") {
    process.stdout.write("__LOADERR__\tcandidate does not export a default evaluate(attackId) function\n");
    return;
  }

  for (const c of cases) {
    let got;
    try {
      got = evaluate(c.n);
    } catch (e) {
      got = "<threw:" + ((e && e.message) || String(e)) + ">";
    }
    if (typeof got !== "string") {
      got = "<nonstring:" + String(got) + ">";
    }
    process.stdout.write(String(c.n) + "\t" + encode(got) + "\n");
  }
}

main();
