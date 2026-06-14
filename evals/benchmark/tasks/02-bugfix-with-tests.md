# Task 02 — bug fix with tests: off-by-one + DST bug in date-range util

## Spec

`src/daterange.js` has two intentional bugs (seeded into the workspace):

1. **Off-by-one**: `daysBetween(a, b)` returns `floor(ms/86400000) + 1`; the `+1` is wrong.
   The function should return the number of whole calendar days from `a` to `b` (pure delta,
   not inclusive of both endpoints).
2. **DST unsafety**: both `daysBetween` and `eachDay` use local-time millisecond arithmetic
   and `setDate`, which stalls or skips a day when a daylight-saving transition crosses midnight.

The tests in `test/daterange.test.js` are pinned to the correct behaviour (DST-spanning
assertions included). They are already failing. The agent must:
- Root-cause both bugs in `src/daterange.js`.
- Fix the source using UTC-based date math.
- NOT edit `test/daterange.test.js`.
- Leave all originally-passing tests still green.

## Difficulty

Medium. Root-cause requires understanding DST interaction with JS Date; a naive fix of one
bug masks the other. Silent-failure-prone because tests only fail under certain date inputs.

## Setup

```sh
npm init -y
npm pkg set type=commonjs
npm install --no-audit --no-fund jest
mkdir -p src test
# seed files written by harness
```

## Seed files

- `src/daterange.js` — buggy implementation (see JSON for exact content)
- `test/daterange.test.js` — pinned tests (must not be modified)

## Oracle / acceptance check

```sh
test -f src/daterange.js
test -f test/daterange.test.js
git diff --quiet -- test/daterange.test.js || (echo 'tests were modified - not allowed' && false)
npx jest --silent
```

All commands must exit 0 for the task to be considered passing.

## Arm-invariant inputs

Both arms receive the same seeded buggy files. The agent must NOT be told where the bugs are;
the prompt describes symptoms only.

## Notes

- The `git diff` oracle is the key differentiator: it catches agents that "fix" tests by
  commenting out assertions.
- The task definition used by the harness is the canonical JSON at `02-bugfix-with-tests.json`.
