# Task 01 — multi-file feature: rate-limiter middleware + store + tests

## Spec

Implement a token-bucket rate limiter as Express middleware in a Node.js project.

Create three source files:
- `src/store.js` — in-memory token-bucket store with `take(key, cost)` returning
  `{allowed, remaining, resetMs}`, configurable capacity and refillPerSec.
- `src/middleware.js` — Express middleware factory `rateLimit({capacity, refillPerSec, keyFn})`
  that uses the store, sets the `X-RateLimit-Remaining` header, and returns HTTP 429 with
  `{error:'rate_limited'}` when exhausted.
- `src/index.js` — re-exports both.

Write Jest tests in `test/store.test.js` and `test/middleware.test.js` covering:
- bucket starts full
- `take()` decrements tokens
- exhaustion returns `allowed=false`
- refill over time restores tokens
- middleware sets headers and returns 429

Wire `package.json` scripts: `test` (jest), `lint` (eslint). Add a minimal ESLint flat config.
All tests must pass; lint must report zero problems.

## Difficulty

Medium. Exercises parallel decomposition across multiple new files that share one contract
(the store API). Silent-failure-prone because wrong header names / off-by-one in the bucket
look correct until an integration test catches them.

## Setup

```sh
npm init -y
npm pkg set type=commonjs
npm install --no-audit --no-fund jest eslint express supertest
```

## Oracle / acceptance check

```sh
test -f src/store.js
test -f src/middleware.js
test -f src/index.js
test -f test/store.test.js
test -f test/middleware.test.js
npx jest --silent
npx eslint src test
```

All commands must exit 0 for the task to be considered passing.

## Arm-invariant inputs

No seed files. Both arms start from the same empty `npm init -y` workspace.

## Notes

- Refill-over-time tests are flaky if the bucket math is wrong — the oracle catches this.
- CommonJS modules only (no ESM) to keep the setup deterministic across node versions.
- The task definition used by the harness is the canonical JSON at `01-multifile-feature.json`.
  This `.md` is the human-readable spec for review and stranger-test validation.
