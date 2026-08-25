# OmniRoute local install — setup note

Companion to `docs/analysis/2026-08-25-omniroute-credential-isolation.md` (the
controlling audit). That doc says the mitigation holds *at the pinned commit*;
this note records the actual install performed against that exact commit, and
what a fresh install's real DB schema looks like in practice.

## Install method

**GitHub archive tarball of the exact pinned commit — not `git clone`.**

```
curl -fsSL https://github.com/diegosouzapw/OmniRoute/archive/d82b68274c75c14d258b4898a34edc25d9712b87.tar.gz -o omniroute-pinned.tar.gz
mkdir -p /Users/rj/omniroute
tar -xzf omniroute-pinned.tar.gz -C /Users/rj/omniroute --strip-components=1
```

This repo's own worktree-isolation guard blocks any `git` invocation whose
target can't be statically verified to stay inside this agent's worktree —
`git clone`/`git init` against a sibling directory (`/Users/rj/omniroute`,
deliberately outside the heimdall worktree so OmniRoute's install never
entangles with heimdall's git state) risked tripping that guard. A GitHub
archive tarball is not a git operation at all, sidesteps the question
entirely, and is *more* precise than a clone+checkout for this purpose: it is
byte-for-byte the tree at `d82b68274c75c14d258b4898a34edc25d9712b87`, nothing
else. Functionally identical to the project's documented "From Source" method
(`docs/getting-started/QUICK-START.md` Option C) — same source, same commit —
just fetched without git metadata. `/Users/rj/omniroute` has no `.git`
directory; `npm install`'s `prepare` script (`husky`) correctly no-ops with
`.git can't be found` rather than erroring.

Rejected alternatives: `npm install -g omniroute` and `docker run
...omniroute:latest` both resolve to whatever the *latest published* version
is, not the exact commit the audit's guarantees are scoped to — the audit is
explicit that its verdict holds "at the pinned commit," so anything
version-floating was disqualified regardless of convenience.

## What was installed

- **Version**: 3.8.51 (`package.json`)
- **Commit**: `d82b68274c75c14d258b4898a34edc25d9712b87` (pinned; default
  branch has since moved to `6435f618f4fd8d23679d20b126578b719622379c` — not
  used)
- **Location**: `/Users/rj/omniroute` (sibling to `heimdall/`, outside any git
  worktree)
- **Node**: v24.13.0 via `nvm exec 24.13.0` — satisfies both `package.json`
  `engines` (`>=22.22.2 <23 || >=24.0.0 <27`) and the project's own
  `.nvmrc`/`.node-version` (`24`). The environment's default Node (v20.20.0)
  does not satisfy `engines`; v24.13.0 and v24.10.0 were already available via
  nvm, so no new Node version needed installing.
- **`npm install`**: exit 0. 2432 packages, 0 vulnerabilities. Postinstall
  fixed native bindings for the host platform (playwright-core Android patch —
  inert on macOS —, sql.js, node-machine-id, LLMLingua optionals) and ran
  `sync-env.mjs`, which created `.env` from `.env.example` (47 keys, **0
  secrets generated** — confirmed by the install's own log line). No API key,
  credential, or provider config was written by this step; see "Credential
  safety" below.

## Launch

```
HOST=127.0.0.1 API_HOST=127.0.0.1 PORT=20128 \
  nvm exec 24.13.0 npm --prefix /Users/rj/omniroute run dev
```

Matches the documented "From Source" step 3 (`npm run dev`) with explicit
loopback overrides. Left unset, `HOST`/`API_HOST` both default to `0.0.0.0`
(confirmed in `docs/reference/ENVIRONMENT.md` and in
`scripts/dev/run-next.mjs:83`: `process.env.HOST || "0.0.0.0"`) — the
documented quickstart run unmodified would have violated the localhost-only
requirement, so the override is load-bearing, not defensive-only.

**Verified bind addresses** (`lsof -iTCP -sTCP:LISTEN`, and independently via
the server's own startup log):

| Port  | Service                  | Bind        |
|-------|---------------------------|-------------|
| 20128 | Dashboard + API (turbopack dev) | `localhost` (127.0.0.1) |
| 20131 | EmbedWsProxy               | `127.0.0.1` |
| 20132 | LiveWS (dashboard websocket) | `127.0.0.1` |

None bound `0.0.0.0` or `*`. None used port 8787 (Headroom's — untouched).

Process: PID 55050, backgrounded under this session's bash task `bpm87oymj`
(log: `bpm87oymj.output` in this session's task dir). Left running — stopping
it would immediately regress `heimdall-fallback check`'s `endpoint_reachable`
to FAIL, defeating the point of the install.

**Reachability check, no prompt content sent**:
```
curl -s -o /dev/null -w "HTTP:%{http_code}\n" --max-time 2 http://127.0.0.1:20128/
→ HTTP:307
```
A bare GET to `/` (redirect to the dashboard/login route) — never touched
`/v1/messages` or `/v1/chat/completions`.

## Data dir

Default `~/.omniroute` (unchanged; `DATA_DIR` never overridden):
- `storage.sqlite` — 159 migrations applied automatically on first boot
- `server.env` — bootstrap-generated secrets, **keys only** (values not
  reproduced here or inspected beyond key names):
  ```
  JWT_SECRET
  STORAGE_ENCRYPTION_KEY
  API_KEY_SECRET
  ```
  These three are local session/DB-encryption/API-key-HMAC material,
  generated by the server itself on first run (`[bootstrap] ✨ ... 
  auto-generated (first run)`) — not provider credentials, not anything this
  install step configured. `scripts/dev/sync-env.mjs` (read in full before
  running `npm install`) explicitly excludes these three from its own
  `.env`-fill step by design, precisely so they're never silently
  regenerated/rotated by a package update; the server owns them.
- `db_backups/` — one pre-migration backup, auto-created by the migration
  runner

## Credential safety — constraints honored

1. **No `claude`/`claude-web` `provider_connections` row.** Never ran
   `omniroute oauth login claude-code`, never used any claude-auth import
   route, never touched the VNC/browser login harvest, never opened the
   dashboard's Providers UI at all.
2. **No delegated sidecar installed.** `test -e ~/.cli-proxy-api` → absent.
   Never installed CLIProxyAPI or Dario (`@askalf/dario`).
3. **`OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS`** never set —
   confirmed default `false` in `docs/reference/ENVIRONMENT.md:286`, and
   `heimdall-fallback check`'s `prefer_claude_code_flag_off` reports `[OK]`.
4. **No root-CA MITM decrypt mode.** Never touched any `MITM_*` env var
   (`MITM_ROOT_CA_ENABLED` defaults `false`) and never invoked the MITM debug
   proxy subsystem (`src/mitm/*`) at all — it is a separate, explicitly-opt-in
   component that `npm run dev` does not start.
5. **No API key configured by me.** `.env` was populated only by the
   project's own `sync-env.mjs` (0 secrets generated at install time; the
   three bootstrap secrets above are self-generated by the server, not
   provider keys). I did not set, invent, or copy any Mistral/Anthropic key
   anywhere.
6. **`~/.claude/settings.json` / `ANTHROPIC_BASE_URL` / Headroom (127.0.0.1:8787)**
   untouched — never read or written.
7. **Port**: 20128 (OmniRoute's own documented default, matching
   `bin/heimdall-fallback`'s `DEFAULT_CFG["endpoint"]`), never 8787.

## SQL verification (direct, out-of-band)

```
$ sqlite3 "file:/Users/rj/.omniroute/storage.sqlite?mode=ro" \
    "SELECT provider, COUNT(*) FROM provider_connections GROUP BY provider;"
(no rows)

$ sqlite3 "file:/Users/rj/.omniroute/storage.sqlite?mode=ro" \
    "SELECT COUNT(*) FROM provider_connections;"
0

$ sqlite3 "file:/Users/rj/.omniroute/storage.sqlite?mode=ro" \
    "SELECT DISTINCT provider FROM provider_connections WHERE provider IN ('claude','claude-web');"
(no rows)

$ test -e ~/.cli-proxy-api && echo EXISTS || echo absent
absent
```

`provider_connections` has zero rows of *any* provider — not just zero
Tier-1 rows. Tier-1 is unreachable by construction on this install, exactly
as the audit describes.

## Finding for whoever owns `bin/heimdall-fallback` next

**`no_delegated_sidecar` has a schema-mismatch bug against this OmniRoute
version — flagging, not fixing (out of my scope; a background agent
("Add switch state and tier-aware on") was actively editing this file during
this install).**

`heimdall-fallback check` output:
```
[FAIL] no_delegated_sidecar -- OmniRoute DB at '/Users/rj/.omniroute/storage.sqlite' could not be queried for a delegated-sidecar connection (no such column: mode) -- cannot positively rule one out
```

Root cause, confirmed against the real schema:

```
$ sqlite3 "file:/Users/rj/.omniroute/storage.sqlite?mode=ro" "PRAGMA table_info(provider_connections);"
```
→ 46 columns, **no `mode` column** (id, provider, auth_type, name, email,
priority, is_active, access_token, refresh_token, ..., created_at,
updated_at, last_ping_at, last_pinged_reset_key).

The real `mode` column lives on **`upstream_proxy_config`**, added by
`src/lib/db/migrations/138_dario_fallback_backend.sql`:
```sql
-- mode is a free TEXT column already ('native' | 'cliproxyapi' | 'dario' | 'fallback')
ALTER TABLE upstream_proxy_config
  ADD COLUMN fallback_backend TEXT NOT NULL DEFAULT 'cliproxyapi';
```
```
$ sqlite3 "file:/Users/rj/.omniroute/storage.sqlite?mode=ro" "PRAGMA table_info(upstream_proxy_config);"
```
→ includes `mode TEXT NOT NULL DEFAULT 'native'` and `fallback_backend TEXT
NOT NULL DEFAULT 'cliproxyapi'`. On this fresh install
`SELECT COUNT(*) FROM upstream_proxy_config` → `0`, so a corrected check would
currently read `[OK]` here too.

Suggested corrected query (not applied — `bin/heimdall-fallback` is out of
scope for this task):
```sql
SELECT COUNT(*) FROM upstream_proxy_config
 WHERE mode IN ('cliproxyapi', 'dario')
    OR (mode = 'fallback' AND fallback_backend IN ('cliproxyapi', 'dario'));
```
This is in addition to, not instead of, the existing `~/.cli-proxy-api`
filesystem check the function already does first.

`tier1_credential_absent` needed no such fix — it only ever queried the
`provider` column, which does exist, and now correctly reads `[OK]`.

## `bin/heimdall-fallback check` — full output

```
heimdall-fallback check -- VERDICT: REFUSE
  [FAIL] state -- fallback state is 'off' (heimdall-fallback set on|auto)
  [FAIL] operator_key -- no operator_key_env configured -- an operator-owned key is required
  [OK  ] endpoint_local
  [OK  ] endpoint_reachable
  [OK  ] tier1_credential_absent
  [FAIL] anthropic_model_pinned -- ANTHROPIC_MODEL is not set -- Claude Code emits bare claude-* model IDs by default, which OmniRoute has an explicit branch to route to provider 'claude' if a connection exists (docs/analysis/2026-08-25-omniroute-credential-isolation.md S5)
  [OK  ] prefer_claude_code_flag_off
  [FAIL] no_delegated_sidecar -- OmniRoute DB at '/Users/rj/.omniroute/storage.sqlite' could not be queried for a delegated-sidecar connection (no such column: mode) -- cannot positively rule one out
  [FAIL] target_provider_allowed -- no target_provider configured
(exit 1)
```

`tier1_credential_absent` and `endpoint_reachable`/`endpoint_local` moving to
`[OK]` (previously "DB not found" / connection-refused before this install)
is the acceptance signal for *this* task. `no_delegated_sidecar`'s FAIL is now
DB-grounded rather than "DB not found" — but is not a clean OK, see the
schema-mismatch finding above. `operator_key` and `anthropic_model_pinned`
failing is expected — see below.

## Remaining steps — operator only, not performed here

None of these were done, per explicit instruction (no API key access, no
authority to make routing policy calls):

1. **Set the operator key env var.** Configure `operator_key_env` in
   `heimdall-fallback`'s own config (`bin/heimdall-fallback where` shows the
   config path) to name an environment variable, then export that variable
   with the operator's real Mistral key. Nothing in this install path touched
   or needs to touch that key.
2. **Pin `ANTHROPIC_MODEL`.** Must contain a `/` (provider-prefixed form) —
   e.g. `mistral/<model-name>` — per `anthropic_model_pinned`'s check and
   `docs/analysis/2026-08-25-omniroute-credential-isolation.md` S5's note that
   *bare* `claude-*` model IDs have an explicit OmniRoute branch back to
   provider `claude` if a connection ever exists.
3. **Set `target_provider`** in `heimdall-fallback`'s config to the intended
   routed provider (e.g. `mistral`) once the above two are set.
4. **`heimdall-fallback set on|auto`** when ready to actually allow routing —
   left at its safe default `off` here.
5. **Not one of the seven named constraints, but found during install and
   worth flagging**: the dashboard's management password is the published
   default. Server log: `[AUTH][SECURITY] Management password is set to the
   well-known default "CHANGEME" (INITIAL_PASSWORD in .env.example). Anyone
   can sign in to the dashboard with it — change it immediately via the
   dashboard or a strong INITIAL_PASSWORD.` Not touched here since touching it
   means logging into the dashboard, outside this task's "no provider UI"
   scope — but it's a real, live, standing exposure on this host and the
   operator should change it before ever relying on this instance.

## Not independently verified

- Whether `bin/heimdall-fallback`'s `no_delegated_sidecar` fix (above) is the
  *only* schema drift between what that script assumes and what this
  OmniRoute version actually ships — only this one path was exercised.
- Long-running stability of the dev server beyond the verification window in
  this session (it is a `next dev`/turbopack process, not the production
  `npm start`/standalone build — fine for local verification, but the
  operator may want to switch to `npm start` for anything longer-lived).
- Dashboard login flow, provider-connection UI, or any authenticated route —
  deliberately never exercised, per the "no provider UI" constraint.
