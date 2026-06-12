# conformance/ — Heimdall parity-conformance fixtures

These are **parity-conformance fixtures**: one canned, runnable check per
[`PARITY.md`](../PARITY.md) row that has *observable* behavior — a command that
exits, a gate that fires, a hook that is wired, an artifact that lands, a
statusline element that renders.

Each fixture asserts that **heimdall produces ≥ the superx (`v1.1.0`) baseline
outcome** for that row: the renamed command still works, the kept gate still
blocks, the improved hook still calls the (renamed) state binary plus its new
gates, and so on.

## Status: DEFINED, not yet CI-wired

This directory is the **inventory and the assertions only**. It is intentionally
**not** referenced by any CI config, `hooks/hooks.json`, GitHub Actions workflow,
or the pre-push gate chain. Wiring comes in a later step (see *Future CI wiring*
below). Nothing here runs automatically and nothing here changes heimdall's
runtime behavior.

## How a fixture is structured

Every `*.fixture.sh` follows the same shape and sources [`_lib.sh`](_lib.sh):

- `# PARITY-ROW:` — the exact PARITY.md item it proves (traceable back to the matrix).
- `# ASSERT:` — the superx-baseline outcome it must meet or beat.
- **setup** — arranges an isolated workspace / real inputs (a scratch git repo,
  an isolated `HEIMDALL_STATE_FILE`, a throwaway project). No faked data.
- **run** — invokes the real heimdall command / gate / hook surface.
- **assert** — real mechanical checks (`exit` code, output shape via `grep`,
  file presence, JSON field via `jq`). Each prints `OK [row] …` / `BAD [row] …`;
  the fixture exits nonzero iff any assert failed, and prints `RESULT [row] OK|N BAD`.

**No model is ever invoked.** These fixtures test heimdall's mechanical surface
(commands / gates / hooks / artifacts), not agent inference.

## The 100%-accounted rule

Every PARITY.md row whose Status is `kept`, `renamed`, or `improved` **and** that
has observable behavior gets a fixture. Every other such row is listed in
`INDEX.json` under `no_fixture[]` with an explicit rationale category
(model-gated, prose-only, net-new-without-baseline, covered-transitively, or
intentionally-dropped). Coverage of observable-behavior rows is therefore 100%;
anything unmappable is recorded as a **finding**, never silently skipped.

### Findings surfaced by these fixtures

1. **`hooks/hooks.json` superx fallback paths** — every hook command embeds
   `${CLAUDE_PLUGIN_ROOT:-/Users/rj/Downloads/superx}` (10 occurrences). Inert
   when `CLAUDE_PLUGIN_ROOT` is set, but a stale superx disk path otherwise.
   Asserted to be *only* in the `:-` fallback default position; recommended to
   retarget the default to a heimdall path.
   (`audits/no-superx-runtime.fixture.sh`)
2. **`bin/generate-changelog` requires bash ≥ 4** — it uses `declare -A`, which
   the macOS-default bash 3.2 rejects (`declare: -A: invalid option`). The
   behavioral run executes only if a bash ≥ 4 is on PATH; otherwise it is a
   documented SKIP + finding. (`files/generate-changelog.fixture.sh`)

### Documented SKIPs (not fake passes)

- **`authenticity-check` live score** — depends on the npm / GitHub network;
  only the offline usage surface is asserted.
- **`generate-changelog` behavioral run under bash 3.2** — see finding #2.

## Running them locally

```sh
# one fixture
bash conformance/gates/quality-gates.fixture.sh

# the whole suite (exit nonzero on any failure)
fail=0
for f in $(find conformance -name '*.fixture.sh' | sort); do
  bash "$f" || fail=1
done
exit $fail
```

## INDEX.json

[`INDEX.json`](INDEX.json) is the machine-readable inventory a future CI step
will iterate. Shape:

- `fixtures[]` — `{ row, class, fixture_path, asserts, observable: true, [note|finding] }`
- `no_fixture[]` — `{ row, class, observable: false, rationale }`
- `totals` — counts (fixtures, asserts, no_fixture rows, findings, skips).

## Future CI wiring (NOT done here)

When parity-conformance is promoted to CI, a job would:

1. `jq -c '.fixtures[]' conformance/INDEX.json` to enumerate fixtures.
2. Run each `fixture_path`; fail the job on the first nonzero exit (a parity
   regression — heimdall dropped below the superx baseline for that row).
3. Optionally export bash ≥ 4 and network access so the two documented SKIPs
   become live assertions.

That wiring is deliberately deferred — this commit only **defines** the
fixtures and the inventory.
