# Task 04 — full-stack scaffold: notes API + static client + integration test

## Spec

Scaffold a tiny full-stack notes app in an empty Node project.

**Backend** (`server.js`) — Express `app` (do NOT auto-listen when required):
- `GET /api/notes` — returns all notes as a JSON array.
- `POST /api/notes` — accepts `{text}`, validates non-empty, assigns incrementing id,
  returns 201 with the created note; returns 400 `{error}` on empty text.
- Notes stored in memory.

**Frontend** (`public/index.html` + `public/app.js`) — vanilla JS, no framework:
- On load: fetch `/api/notes` and render into `<ul id="notes">`.
- Form `#note-form` with input `#note-text` POSTs a new note and re-renders.

**Entrypoint** (`bin/serve.js`) — imports `app` and listens on `process.env.PORT || 3000`.

**Integration test** (`test/api.test.js`) using supertest:
- Empty list initially.
- POST creates a note, returns 201 + id.
- Note appears in subsequent GET.
- POST with empty text returns 400.

Wire `package.json` `test` script to jest. All tests must pass.

## Difficulty

High. Three coordinated layers (server, client, test) must agree on the same contract.
Silent-failure-prone: `server.js` that auto-listens when `require()`d will cause supertest
to bind the wrong port; a client that hard-codes URLs will fail at runtime.

## Setup

```sh
npm init -y
npm pkg set type=commonjs
npm install --no-audit --no-fund express jest supertest
```

## Oracle / acceptance check

```sh
test -f server.js
test -f public/index.html
test -f public/app.js
test -f bin/serve.js
test -f test/api.test.js
grep -q 'id="notes"' public/index.html
grep -q 'id="note-form"' public/index.html
node -e "const a=require('./server'); if(typeof a!=='function' && typeof a.listen!=='function'){process.exit(1)}"
npx jest --silent
```

All commands must exit 0 for the task to be considered passing.

## Arm-invariant inputs

No seed files. Both arms start from the same empty workspace.

## Notes

- The `node -e` oracle verifies server.js exports the app without auto-listening — a very
  common mistake that silently breaks supertest.
- The task definition used by the harness is the canonical JSON at `04-fullstack-scaffold.json`.
