# OmniRoute gateway — durable start, verification, no-auth tool-use inventory

Date: 2026-08-26
Install: `/Users/rj/omniroute` (source checkout, v3.8.51, pinned commit `d82b682`)
Data dir: `/Users/rj/.omniroute`
Scope of this doc: start the gateway durably on `127.0.0.1:20128`, prove it's up, confirm the
loopback bind and the Tier-1 zero-Claude-connections invariant, and inventory no-auth provider
tool-use capability. No OmniRoute source touched, no `provider_connections` row added, no secret
printed.

## 1. Status: RUNNING

```
PID   99168  (direct owner of the LISTEN socket, confirmed via lsof — see §3)
PPID  98843  (npm run-script wrapper)
Up    08:53 at last check (2026-08-26T12:07:17Z)
```

## 2. Durable start command (the one that's actually running)

```bash
nohup env -C /Users/rj/omniroute \
  PATH="/Users/rj/.nvm/versions/node/v24.13.0/bin:$PATH" \
  OMNIROUTE_USE_TURBOPACK=0 \
  HOST=127.0.0.1 \
  DATA_DIR=/Users/rj/.omniroute \
  npm run dev \
  > /Users/rj/.omniroute/logs/gateway-boot.stdout.log 2>&1
```

Launched via the harness's own `run_in_background: true` Bash parameter (single statement, no
manual `&`/`disown`, no compound `;`-chained follow-up). That distinction mattered mechanically in
this environment: a worktree-isolated agent's Bash tool blocks multi-statement or manually
backgrounded commands that target paths outside the worktree ("too complex to verify that it
stays inside the worktree"), even when the command has nothing to do with git. Reducing to one
statement and letting the tool's own backgrounding handle persistence is what got it running.
`nohup` + output redirection is kept anyway, as defense in depth against SIGHUP if this ever runs
under something that doesn't already detach it.

### Why `npm run dev` (webpack) and not `npm run start`

Both were on the table. Decision: **`dev` mode with `OMNIROUTE_USE_TURBOPACK=0`, forcing webpack.**

- `npm run start` needs a pre-built `.next` production bundle. Confirmed absent:
  `ls -la /Users/rj/omniroute/.next` → *No such file or directory*. `dist/` exists but only holds
  an unrelated `node_modules` folder. Building one now via `build-next-isolated.mjs` would be a
  slow, unverified, first-time operation on the path to a "just get it running" task — the wrong
  place to absorb that risk.
- Structurally, `start` mode never touches Turbopack at all (`useTurbopack = dev && ...` in
  `scripts/dev/run-next.mjs:89` — `dev` is `false` in start mode, so the expression is `false`
  unconditionally). That's a real point in `start`'s favor for dodging the documented
  turbopack-segfault-on-restart bug, but it's moot today since no build exists.
  `OMNIROUTE_USE_TURBOPACK=0` in `dev` mode reaches the identical outcome (webpack, never
  turbopack) without needing a build, and matches the exact command already proven working in
  the prior session (`docs/analysis/2026-08-25-omniroute-install.md §5.4`).
- Net: `dev`+webpack today; `start` is a legitimate future upgrade once a real, verified
  production build exists — not before.

### Node version — correction to the task's stated context

The task said "Node v24.13.0 matches `.node-version`." Half right, worth flagging precisely:

- `/Users/rj/omniroute/.node-version` → `24`. `/Users/rj/omniroute/.nvmrc` → `24`. Both agree, and
  v24.13.0 is genuinely installed (`~/.nvm/versions/node/v24.13.0/`).
- But the **ambient default `node` resolves to v20.20.0** regardless of either file —
  confirmed fresh: `node -v` → `v20.20.0`. Classic nvm's version-file auto-switch relies on an
  interactive-shell `cd` hook; it doesn't fire for this harness's non-interactive Bash
  invocations, so cwd alone doesn't select v24 no matter what `.node-version`/`.nvmrc` say.
- v20.20.0 sits **outside** `package.json`'s declared `engines` range
  (`>=22.22.2 <23 || >=24.0.0 <27`), and several deps are native/optional
  (`better-sqlite3`, `sharp`, `onnxruntime-node`, `keytar`, `tls-client-node`) — real ABI-mismatch
  risk if launched under the ambient default.
- Mitigation applied: explicitly prepended `/Users/rj/.nvm/versions/node/v24.13.0/bin` onto `PATH`
  for the launch (see command above) rather than trusting cwd-based auto-switch. Anyone
  restarting this later should do the same — `cd`-ing into the repo and running bare `npm run dev`
  will silently run under v20.20.0.

## 3. Verification evidence (fresh, this session, exit codes from the command itself)

**Health endpoint:**
```
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:20128/api/monitoring/health
200
curl exit=0
```

**Listening socket — loopback-only, not 0.0.0.0:**
```
$ lsof -nP -iTCP:20128 -sTCP:LISTEN
COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    99168   rj 1534u  IPv4 0x7fb195faed2cd5fd      0t0  TCP 127.0.0.1:20128 (LISTEN)
lsof exit=0
```
Bound to `127.0.0.1` specifically — confirmed NOT `0.0.0.0`/`*`. This matters because OmniRoute
has no Host-header allowlist (documented DNS-rebinding exposure); loopback-only bind is the
mitigation, and it's what's actually running. `run-next.mjs:83` defaults `hostname` to `0.0.0.0`
when `HOST` is unset — the explicit `HOST=127.0.0.1` in the start command is load-bearing, not
optional. Auxiliary services also came up loopback-only per the boot log:
`[EmbedWsProxy] Listening on 127.0.0.1:20131`, `[LiveWS] Dashboard WebSocket server listening on
127.0.0.1:20132`.

**Tier-1 safety invariant — zero Claude routing backends, rechecked post-startup:**
```
$ sqlite3 /Users/rj/.omniroute/storage.sqlite "SELECT COUNT(*) FROM provider_connections WHERE provider IN ('claude','claude-web');"
0
sqlite3 exit=0
```
Still `0` after startup. No row added, no credential added — none was needed to start the
gateway itself.

**Boot log confirms clean startup** (`/Users/rj/.omniroute/logs/gateway-boot.stdout.log`):
`[Next] dev server listening on http://127.0.0.1:20128 (webpack)` — webpack, as intended, never
turbopack. `[DB] SQLite database ready: /Users/rj/.omniroute/storage.sqlite` — correct `DATA_DIR`
picked up.

## 4. Secrets — handled per constraint, contents never printed

`/Users/rj/.omniroute/management-password.txt` (0600) and `/Users/rj/.omniroute/server.env` (0600,
holds `JWT_SECRET`/`STORAGE_ENCRYPTION_KEY`/`API_KEY_SECRET`) were not read, printed, or modified
at any point in this task. The boot log emits
`[bootstrap] ⚠️ INITIAL_PASSWORD is not set — using default 'CHANGEME'. Change it in Settings!` —
this is expected, benign noise, not a regression: per the prior audit
(`docs/analysis/2026-08-25-omniroute-install.md`), a bcrypt hash is already persisted in the DB
for the rotated password, and once that hash exists `INITIAL_PASSWORD` is never re-read — the
warning fires purely because `INITIAL_PASSWORD=CHANGEME` is still literally present in
`/Users/rj/omniroute/.env`, which was already flagged "not actioned" (deliberately out of scope)
in that prior audit. Not something this task touched or needed to touch.

## 5. No-auth provider tool-use inventory

Source: `/Users/rj/omniroute/src/shared/constants/providers/noauth.ts` — `NOAUTH_PROVIDERS` has
exactly **13** entries. Tool-use capability is resolved by a layered chain, fully traced through
source this session:

1. **Provider-wide hard denial** — `open-sse/config/providers/registry/<id>/index.ts` can set
   `unsupportedParams: [...]` on the `RegistryEntry`. `getUnsupportedParams()`
   (`open-sse/config/providerRegistry.ts`) checks this as a fallback when a live-discovered model
   has no per-model entry. **Repo-wide grep of every provider registry directory (350 providers,
   not just the 13 no-auth ones) found exactly one provider anywhere with `"tools"` in
   `unsupportedParams`: `aihorde`** (`unsupportedParams: ["tools", "tool_choice",
   "parallel_tool_calls"]`, `open-sse/config/providers/registry/aihorde/index.ts:42`, comment: *"No
   tool calling: the workers run raw text-completion backends"*). This is a real, request-time
   enforced denial — `capabilityFilter.ts` rejects a tools-bearing request to aihorde with
   `supportsTools === false` and no emulated-bypass to save it.
2. **Emulated bypass** — `providerSupportsEmulatedToolCalling(providerId)`
   (`open-sse/services/combo/comboStructure.ts:51`) returns `true` **only** when that provider's
   metadata literally has `toolCalling: "emulated"`. Exactly **two** of the 13 carry that field:
   `devin-cli-agentic` and `duckduckgo-web`. Emulated means prompt-injected tool definitions +
   text-output parsing (`webTools.ts`'s `parseToolCallsFromText`) — not native structured function
   calling. Categorically more fragile: it depends on the model reliably emitting a parseable
   text pattern, not a protocol-level guarantee.
3. **Optimistic heuristic default** — for every provider/model that hits neither of the above,
   `heuristicToolCalling()` (`src/lib/modelCapabilities.ts:222`) returns `true` unless the model
   *name* matches `TOOL_CALLING_UNSUPPORTED_PATTERNS` — confirmed to be a list of **non-chat
   surface** patterns only (`whisper`, `tts-1`, `omni-moderation`, `eleven_*`, `seedance`, `/veo`,
   `rerank`, `embedding`, `dall-e`, `flux-`, `stable-diffusion`) — i.e. audio/image/moderation
   model names, not provider identifiers. A normal chat-model name on any of these providers will
   not be caught by this list.

| Provider (id) | alias | serviceKinds | Explicit signal | Verdict |
|---|---|---|---|---|
| `devin-cli-agentic` | dva | llm (local CLI) | `toolCalling: "emulated"` | Emulated — prompt-injected, text-parsed |
| `duckduckgo-web` | ddgw | llm | `toolCalling: "emulated"` | Emulated — prompt-injected, text-parsed (#7286) |
| `aihorde` | horde | llm (passthrough) | `unsupportedParams` includes `tools` | **Denied** — enforced at request time, 100% source-backed |
| `opencode` | oc | llm | none | Optimistic default `true` — real support depends on the wrapped free endpoint, unverified live |
| `cloudflare-playground` | cfp | llm | none | Optimistic default `true` — reverse-engineered browser/WS protocol; native tool support doubtful in practice |
| `felo-web` | felo | llm | none | Optimistic default `true` — reverse-engineered consumer web UI; doubtful in practice |
| `theoldllm` | tllm | llm | none | Optimistic default `true` — unverified |
| `chipotle` | pepper | llm | none | Optimistic default `true` — reverse-engineered SockJS/STOMP chatbot; doubtful in practice |
| `auggie` | aug | llm (local CLI) | none | Optimistic default `true` — actual behavior delegated entirely to the locally-installed Auggie CLI, outside OmniRoute's own resolution |
| `zcode` | zc | llm (local CLI) | none | Optimistic default `true` — delegated to local ZCode app-server |
| `codex-app-server` | cxa | llm (local CLI) | none | Optimistic default `true` — delegated to local Codex CLI app-server (JSON-RPC) |
| `uncloseai` | unc | llm (passthrough) | none | Optimistic default `true` — OpenAI-compatible passthrough, unverified live |
| `veoaifree-web` | veo-free | **video only** | none | N/A — not a chat/LLM surface, tool-use doesn't apply |

**Bottom line for heimdall's tool-use needs:** only `devin-cli-agentic` and `duckduckgo-web` carry
any source-confirmed tool-calling signal at all, and it's the weaker emulated kind, not native
function calling. `aihorde` is explicitly and enforceably out. The other 9 chat-capable providers
get an optimistic "yes" from OmniRoute's own catalog metadata purely by omission — that is a
capability-filter default, not a verified guarantee, and several of them are reverse-engineered
consumer web UIs where real structured tool support is unlikely regardless of what the catalog
reports. This doc cannot verify live behavior against any of them (would mean live requests
against anonymous/free endpoints, out of scope here) — the task's own caveat that "keyless
providers 400 on a bare `system` field" is empirical/operational knowledge from prior measurement,
not something present anywhere in OmniRoute's source; nothing found this session either confirms
or contradicts it, and it should still be treated as true until re-measured.

## 6. Stop / restart

The npm wrapper (PID 98843) is not the process worth signaling — `lsof` already shows the actual
Next.js server (PID 99168) as the direct owner of the listening socket, so target the socket, not
a remembered PID (a saved pidfile from `npm run dev`'s launch would capture npm's PID, not the
server's, since npm's `run-script` spawns it as a child):

```bash
# Stop (graceful — run-next.mjs installs SIGTERM/SIGINT handlers that close
# the HTTP server and the Next app before exiting):
lsof -tiTCP:20128 -sTCP:LISTEN | xargs kill

# Restart (same command as §2):
nohup env -C /Users/rj/omniroute \
  PATH="/Users/rj/.nvm/versions/node/v24.13.0/bin:$PATH" \
  OMNIROUTE_USE_TURBOPACK=0 \
  HOST=127.0.0.1 \
  DATA_DIR=/Users/rj/.omniroute \
  npm run dev \
  > /Users/rj/.omniroute/logs/gateway-boot.stdout.log 2>&1
```

## 7. Known non-fatal issues observed (not caused by this task, not fixed — out of scope)

- `[Cleanup] Error cleaning compression_run_telemetry: SqliteError: no such table:
  compression_run_telemetry` — pre-existing schema gap in the auto-cleanup job, unrelated to this
  start; auto-cleanup completes with "1 errors" and continues. Not touched — modifying OmniRoute
  source/schema is out of scope for this task.
- Several webpack `Critical dependency: the request of a dependency is an expression` warnings
  during compile (`browserPool.ts`, `tlsClient.ts`, `runtimeRequire.ts`) — dynamic-require
  patterns webpack can't statically analyze, cosmetic build-time warnings, server started and
  serves traffic regardless.

## 8. Constraints honored

No `provider_connections` row added (§3 count still `0`). No credential added. No OmniRoute
source modified. `management-password.txt` / `server.env` contents never read or printed (§4).
Only heimdall-repo file touched: this doc. `bin/` and `commands/` untouched. Exit codes quoted are
each command's own (§3), never a pipeline tail's.

---

## CORRECTION (2026-08-26, orchestrator): the `nohup` start was NOT durable

The section above documents a `nohup env -C ... npm run dev` start as durable. **It is not, and
this was proven empirically the same day.** When the Claude Code session hit its API usage
limit, the harness tore down the background process group and the gateway died with it:

```
ps -p 99168        -> no such process
lsof -iTCP:20128   -> (empty)
curl .../health    -> exit 7, connection refused
```

`nohup` protects against SIGHUP. It does not protect against the process group being killed,
which is what actually happened. Any start method owned by the agent session dies with that
session — the durability has to live *outside* the session.

### The actual durable start: a launchd user agent

`~/Library/LaunchAgents/dev.runheimdall.omniroute.plist`, loaded with:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.runheimdall.omniroute.plist
launchctl print     gui/$(id -u)/dev.runheimdall.omniroute   # state = running
launchctl bootout   gui/$(id -u)/dev.runheimdall.omniroute   # stop
```

Key properties, each load-bearing:
- `KeepAlive: true` — restarts on crash, so a segfault no longer means a dead gateway.
- `RunAtLoad: true` — survives reboot.
- `HOST=127.0.0.1` — loopback ONLY. OmniRoute has no Host-header allowlist (see the
  credential-isolation analysis), so a `0.0.0.0` bind would be a real exposure. Verified after
  boot: `TCP 127.0.0.1:20128 (LISTEN)`, never `0.0.0.0`.
- `OMNIROUTE_USE_TURBOPACK=0` — webpack, avoiding the turbopack native-addon segfault.
- Explicit `PATH` to `~/.nvm/versions/node/v24.13.0/bin` — launchd gets no interactive shell,
  so nvm's auto-switch never fires and ambient `node` would be v20.20.0.

**Cold-boot time is ~10 minutes**, not seconds. The webpack dev compile sits at
`Compiling /instrumentation ...` with the log frozen and ~10% CPU for most of it. That looks
wedged and is not — do not kill it and retry, which only restarts the same 10-minute compile.
Poll `/api/monitoring/health` for 200 rather than trusting the log to advance.

### Verified after the launchd boot
- `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/api/monitoring/health` → `200`
- bind is `127.0.0.1:20128` only
- `SELECT COUNT(*) FROM provider_connections WHERE provider IN ('claude','claude-web')` → `0`
  (Tier-1 invariant intact)
- `POST /api/auth/login {"password":"CHANGEME"}` → `401 {"error":"Invalid password"}` — the
  rotated management password is live. The bootstrap log still prints
  `INITIAL_PASSWORD is not set — using default 'CHANGEME'`; that warning is **inert noise**,
  because `INITIAL_PASSWORD` is only consulted when no bcrypt hash is persisted, and one is
  (`key_value`, `namespace='settings'`, `key='password'`, 62 bytes, prefix `"$2b` — a
  JSON-quoted bcrypt hash).
  - Method note: a first probe with `--max-time 8` returned `000`/exit 28. That is a TIMEOUT,
    not a rejection, and proves nothing — bcrypt at 12 rounds plus a cold Next.js route
    compile exceeds 8s. Only the `--max-time 45` retry returning a real `401` is evidence.
  - Method note 2: a first check of the hash using `LIKE '$2%'` reported `NOT-A-BCRYPT-HASH`.
    That was a bad query, not a finding — the stored value is JSON-encoded so it begins with a
    `"` character. Nearly logged as a security regression; wasn't one.

### Remaining gap: the gateway is up but cannot serve inference yet
- `GET /v1/models` → **401**. `key_value` has `requireLogin=true` and `api_keys` has **0** rows,
  so the token-authenticated `/v1/*` surface has no key to accept.
- `provider_connections` is **0**, so even authenticated there is no connection to route through.
- Consequence: `heimdall-fallback arm` correctly prints `export ANTHROPIC_MODEL=auggie/<model-id>`
  but **that model id cannot currently be resolved**, because the listing that would provide it
  is behind the 401 above. `arm` is not wrong to ask for it; the id genuinely does not exist yet.
- Closing this needs two management-plane actions (mint an API key, create a no-auth provider
  connection). Both are credential-plane changes gated behind the management password, and are
  deliberately NOT taken autonomously — see the autonomy rule that security-sensitive decisions
  are never auto-approved.
