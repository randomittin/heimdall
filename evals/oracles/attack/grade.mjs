// grade.mjs — executor for the `attack` oracle gate.
//
// Imports the target module, runs the settlement-webhook/1 attack battery against its
// `createWebhook({ store })` factory, and writes the raw battery result as JSON to the
// path given as argv[3] (or stdout when omitted). It performs NO verdict logic: run.sh is
// the single source of pass/fail truth and turns this result into the typed report.json.
//
// The result goes to a FILE, never to stdout, because a target is free to print while it
// loads or runs and that must not be able to corrupt the result.
//
// A target that cannot be loaded is a gradable outcome (`load_error`), not a crash: it is
// the maximal failure, and run.sh reports it as a DENIED finding. An ENGINE fault (a bug
// here, a missing reference) is deliberately not caught: it exits non-zero and run.sh
// reports an infrastructure error, never a verdict.
//
// Usage: node grade.mjs <target-module> [<result.json>]
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runBattery, SUITE, PROFILE } from './engine/battery.mjs';

function emit(result, resultPath) {
  const text = `${JSON.stringify(result)}\n`;
  if (resultPath) writeFileSync(resultPath, text);
  else process.stdout.write(text);
}

async function loadFactory(targetPath) {
  let mod;
  try {
    mod = await import(pathToFileURL(resolve(targetPath)).href);
  } catch (error) {
    return { loadError: `target module failed to import: ${String((error && error.message) || error)}` };
  }
  const factory = mod.default || mod.createWebhook;
  if (typeof factory !== 'function') {
    return { loadError: 'target does not export a createWebhook({ store }) factory (default or named export)' };
  }
  return { factory };
}

async function main() {
  const [targetPath, resultPath] = process.argv.slice(2);
  if (!targetPath) {
    process.stderr.write('usage: node grade.mjs <target-module> [<result.json>]\n');
    process.exitCode = 2;
    return;
  }
  const { factory, loadError } = await loadFactory(targetPath);
  if (loadError) {
    emit({ suite: SUITE, profile: PROFILE, load_error: loadError }, resultPath);
    return;
  }
  emit(await runBattery(factory), resultPath);
}

await main();
