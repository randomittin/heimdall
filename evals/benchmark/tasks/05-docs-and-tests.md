# Task 05 — docs + tests for existing module: document and cover a CSV parser

## Spec

`src/csv.js` is a working, intentionally undocumented CSV parser (seeded). It exports:
- `parseCSV(text, {delimiter=',', headers=true})` — parses CSV; if `headers=true`, returns
  array of objects keyed by the first row; if `false`, returns array of arrays.
- `stringifyCSV(rows, {delimiter=','})` — serialises array-of-arrays to CSV string.

The parser handles: quoted fields, escaped double-quotes (`""` inside quotes), embedded
newlines inside quotes, configurable delimiter.

The agent must, WITHOUT modifying `src/csv.js`:

1. **Write `docs/csv.md`** documenting both functions: signature, parameters, return shape,
   and at least two worked examples each (input → output), including quoting and escaping.
2. **Write `test/csv.test.js`** (Jest) covering:
   - Simple parse with headers.
   - Parse without headers (array of arrays).
   - Quoted fields containing the delimiter.
   - Escaped double-quotes inside a quoted field.
   - Embedded newlines inside a quoted field.
   - Round-trip: `parseCSV(stringifyCSV(rows), {headers:false})` returns original rows.
   - Custom delimiter (e.g. `;`).

All tests must pass against the existing implementation. The agent must read `src/csv.js`
to learn its exact behaviour rather than assuming.

## Difficulty

Medium. Comprehension task: the agent must read real code and produce both accurate prose
and meaningful test coverage. Silent-failure-prone because a test that doesn't exercise
the edge case (e.g., claims to test embedded newlines but doesn't include `\n` in the fixture)
passes but gives false confidence.

## Setup

```sh
npm init -y
npm pkg set type=commonjs
npm install --no-audit --no-fund jest
mkdir -p src test docs
# seed files written by harness
```

## Seed files

- `src/csv.js` — working, undocumented implementation (see JSON for exact content)

## Oracle / acceptance check

```sh
test -f src/csv.js
test -f docs/csv.md
test -f test/csv.test.js
git diff --quiet -- src/csv.js || (echo 'implementation was modified - not allowed' && false)
grep -qi 'parseCSV' docs/csv.md
grep -qi 'stringifyCSV' docs/csv.md
npx jest --silent
```

All commands must exit 0 for the task to be considered passing.

## Arm-invariant inputs

Both arms receive the same seeded `src/csv.js`. Neither arm is told the function signatures
upfront — they must read the source.

## Notes

- `git diff` oracle catches agents that simplify the implementation to match simpler tests.
- The task definition used by the harness is the canonical JSON at `05-docs-and-tests.json`.
