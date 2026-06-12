# Task 03 — lint/refactor batch: zero ESLint warnings on a messy module

## Spec

`src/orders.js` is functional but intentionally messy (seeded):
- uses `var` instead of `const`/`let`
- has an unused variable
- uses loose equality (`==`)
- uses string concatenation instead of template literals
- has an `else` after a `return`

An ESLint flat config (`eslint.config.js`) is already present and enforces:
`no-var`, `prefer-const`, `eqeqeq`, `no-unused-vars`, `prefer-template`, `no-else-return`.

The agent must:
- Refactor `src/orders.js` so `npx eslint src` reports **zero** problems.
- NOT change the observable behaviour — `test/orders.test.js` must pass unchanged.
- NOT weaken the ESLint config or add disable comments — fix the code itself.

## Difficulty

Low-medium. Mechanical, but many small edits must all land. Silent-failure-prone because
forgetting one rule passes lint on a quick glance but fails the oracle.

## Setup

```sh
npm init -y
npm pkg set type=commonjs
npm install --no-audit --no-fund jest eslint
mkdir -p src test
# seed files written by harness
```

## Seed files

- `src/orders.js` — messy implementation (see JSON for exact content)
- `test/orders.test.js` — tests (must not be modified)
- `eslint.config.js` — strict config (must not be weakened)

## Oracle / acceptance check

```sh
test -f src/orders.js
npx eslint src
npx jest --silent
```

All commands must exit 0 for the task to be considered passing.

## Arm-invariant inputs

Both arms receive identical seeded files. The ESLint config is fixed.

## Notes

- The task is a stress test for "many small edits that must all land" — a pattern where
  agents that lose context midway leave one or two violations behind.
- The task definition used by the harness is the canonical JSON at `03-lint-refactor-batch.json`.
