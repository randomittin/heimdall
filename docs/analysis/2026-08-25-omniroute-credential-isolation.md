# OmniRoute credential isolation — can Tier-1 be made structurally impossible?

**Date:** 2026-08-25 · **Question:** the prior pass
(`2026-08-25-omniroute-fallback-transport.md`, §4a) blocked on "no config flag
disables Tier-1 subscription reuse." This pass tests a stronger hypothesis:
**Tier-1 needs OmniRoute to HAVE Claude credentials; deny it those and Tier-1
cannot engage regardless of config.** Investigation only — no code written,
nothing installed, nothing configured, OmniRoute never run.

**Source pin:** OmniRoute `diegosouzapw/OmniRoute` at commit
`d82b68274c75c14d258b4898a34edc25d9712b87` — deliberately the SAME commit the
prior pass pinned, so the two documents compose. Retrieved as a
blobless/sparse read-only checkout (`src/ open-sse/ bin/ docs/`). The default
branch (`release/v3.8.51`) has ALREADY MOVED to
`6435f618f4fd8d23679d20b126578b719622379c` (pushed 2026-08-25T07:14:10Z) —
i.e. within hours of this analysis. See "Residual risk 4."

---

## VERDICT: **MITIGATION HOLDS — with three named residual risks that are not optional caveats**

At the pinned commit, **no code path was found in which OmniRoute acquires a
Claude/Anthropic subscription credential without an explicit, authenticated
operator action.** It does not read `~/.claude/.credentials.json`, it does not
read the macOS Keychain for Claude, it does not ingest an Anthropic token from
any environment variable, it has no Claude "auto-import" route (it has exactly
three auto-import routes — cursor, kiro, raycast — and no Claude equivalent),
and its boot sequence performs no credential discovery of any kind. Its MITM
layer, which does intercept `api.anthropic.com`, **masks** the `authorization`
header rather than capturing it.

So the hypothesis is CORRECT in its core claim: **Tier-1 is not a mode
OmniRoute enters, it is the consequence of a `provider_connections` row with
`provider = 'claude'` existing in OmniRoute's own SQLite DB.** No such row →
nothing for the router to select → Tier-1 is unreachable by construction, not
by policy. That is a genuine structural mitigation and it is stronger than any
config flag would have been.

Three things stop this from being a clean unqualified YES, and each one has to
be carried into whatever ships:

1. **The mitigation is credential-absence, and credential-absence is not
   enforced by anything.** There is no provider allowlist/denylist that gates
   routing. `blockedProviders` (Settings → Security) looks exactly like the
   kill switch an operator would reach for and **is not one** — its own UI
   string is *"Hide specific providers from the /v1/models response"*, and it
   is consulted only in model-listing, search, and no-auth-credential paths,
   never in `getProviderCredentials()` for an OAuth provider. An operator who
   "blocks claude" in the dashboard would have a hidden-but-fully-routable
   Claude provider. The control is therefore a **standing invariant that must
   be re-verified**, not a lock that can be set once. §3 gives the check.
2. **A delegated sidecar can hold the credential instead.** "OmniRoute holds no
   Claude token" ≠ "no Claude subscription is reachable through OmniRoute."
   OmniRoute supervises embedded services including CLIProxyAPI and **Dario,
   which its own source describes as a "Claude-subscription proxy"**. If either
   is installed and independently logged in, traffic can reach a Claude
   subscription without OmniRoute ever storing a token. Gate: they are skipped
   at boot unless installed. §4.
3. **The provider pin is load-bearing, not belt-and-braces.** Claude Code sends
   bare `claude-*` model IDs when `ANTHROPIC_MODEL` is unset. Bare `claude-*`
   resolution has an explicit branch that routes to provider `claude`. With no
   claude connection that branch cannot fire and the request fails with a clear
   error (safe-fail) — but the safety comes from the missing connection, NOT
   from the pin, and the two must both be true. §5.

**On the prior pass's blocking finding:** it is confirmed, and sharpened. There
is no Tier-1 routing disable — I looked and did not find one either (§6). What
the prior pass could not know is that this does not matter, because the
credential is the gate and the credential gate is structural.

---

## 1. Every Claude/Anthropic-subscription credential path in OmniRoute

Exhaustive to the best of this pass. Labelled READ (verified in source at the
pinned commit) vs INFERRED. Where something was NOT found, the surfaces
searched are named so the residual uncertainty is visible.

### 1a. Provider `claude` — OAuth against Anthropic's Claude Code client (Tier-1 proper)

The OAuth client is Claude Code's own public client id
(`9d1c250a-e61b-44d9-88ed-5944d1962f5e`, named in
`src/app/api/services/dario/admin/import-from-omniroute/route.ts`), PKCE flow,
`redirect_uri` default `https://platform.claude.com/oauth/code/callback`
(`src/lib/oauth/constants/oauth.ts:41`). READ.

| # | Path | Trigger | Reads host FS? |
|---|---|---|---|
| 1 | Browser PKCE flow OmniRoute initiates itself — `/api/oauth/claude/<action>` (`src/app/api/oauth/[provider]/[action]/route.ts`, provider def `src/lib/oauth/providers/claude.ts`) | Operator clicks Connect; Anthropic consent page; code returned | No |
| 2 | Same flow from the CLI — `omniroute oauth login claude-code` (`bin/cli/commands/oauth.mjs:12,27` — `"claude-code" → "claude"` alias map, `flow: "browser"`) | Operator runs the command | No |
| 3 | `POST /api/providers/claude-auth/import` | Operator pastes/uploads JSON | **No** — see below |
| 4 | `POST /api/providers/claude-auth/import-bulk` (up to 50 files) | Operator uploads | No |
| 5 | `POST /api/providers/claude-auth/zip-extract` | Operator uploads a ZIP | No |
| 6 | `POST /api/oauth/claude/paste-credentials` (generic `/api/oauth/[provider]/paste-credentials`) | Operator pastes | No |
| 7 | `POST /api/providers` / `POST /api/providers/bulk` | Operator creates manually | No |
| 8 | **`POST /api/oauth/cliproxy-import`** | Operator POSTs | **YES — `~/.cli-proxy-api/*.json`** |

**#3 is the load-bearing one and it is clean.** READ,
`src/app/api/providers/claude-auth/import/route.ts`:

```ts
rawJson = source.kind === "json" ? source.json : JSON.parse(source.text);
...
const parsed = parseAndValidateClaudeAuth(rawJson);
```

The credential arrives **in the HTTP request body**. The route performs no
filesystem read whatsoever, and is behind `requireManagementAuth`. The
dashboard modal (`ImportClaudeAuthModal.tsx`) uses a browser file picker — the
OPERATOR selects `~/.claude/.credentials.json` and the browser reads it
client-side. The string `~/.claude/.credentials.json` appears in that file only
as **UI instruction text** (line 705) telling the human where to look.

**#8 is the one genuine filesystem-sourced Claude path.** READ,
`src/app/api/oauth/cliproxy-import/route.ts` + `src/lib/oauth/utils/cliProxyAuthImport.ts`:

```ts
function cliProxyConfigDir(): string {
  return process.env.CLIPROXYAPI_CONFIG_DIR || path.join(os.homedir(), ".cli-proxy-api");
}
export const CLIPROXY_TYPE_TO_PROVIDER: Record<string, string> = {
  anthropic: "claude", claude: "claude", codex: "codex", antigravity: "antigravity", kimi: "kimi",
};
```

It scans that directory for `*.json`, maps `type: anthropic|claude` → OmniRoute
provider `claude`, and creates connections. **But:** it reads
`~/.cli-proxy-api/`, never `~/.claude/`; GET is preview-only (returns
provider/email/type, explicitly never tokens); POST is what imports; both are
behind `requireManagementAuth`; and the directory only exists if the operator
installed CLIProxyAPI and logged it into Anthropic separately. It is also
loopback-gated at the route-guard layer alongside the other local-credential
routes.

### 1b. Provider `claude-web` — a claude.ai session cookie

Same Anthropic account, different surface. OmniRoute's own catalog flags it
`subscriptionRisk: true` (READ, `src/shared/constants/providers/web-cookie.ts:104-117`).

| # | Path | Trigger |
|---|---|---|
| 9 | Operator pastes the `claude.ai` session cookie from DevTools | Operator |
| 10 | VNC browser-login harvest (`src/lib/vncSession/{manifest,harvest,service}.ts`) — cookies pulled via CDP `Network.getCookies` from a containerized Chromium | Requires the `omniroute-vnc-chromium` image to be BUILT, an operator-started container, and the operator logging into claude.ai inside it |

`open-sse/services/claudeTurnstileSolver.ts` launches Playwright at claude.ai
but extracts only `cf_clearance` (Cloudflare anti-bot), and only matters once a
claude-web connection already exists. READ — no `userDataDir`,
`launchPersistentContext`, or `executablePath` in that file; it does not touch
the operator's real browser profile.

### 1c. Reverse and derived paths (not acquisition)

- **`POST /api/providers/[id]/claude-auth/apply-local`** — writes an EXISTING
  OmniRoute claude connection's token INTO `~/.claude/.credentials.json`
  (`src/lib/oauth/utils/claudeAuthFile.ts::writeClaudeAuthFileToLocalCli`).
  READ: it does `fs.readFile(authPath)` first, but purely read-modify-write to
  preserve sibling keys (source comment: *"READ-MODIFY-WRITE: preserve mcpOAuth
  and any other keys the Claude CLI may have written alongside claudeAiOauth"*),
  then overwrites `claudeAiOauth` with its own. **It never ingests the existing
  token.** This is the direction that would clobber the operator's own Claude
  Code login — a distinct hazard, listed in §3's "must not do."
- **`/api/services/dario/admin/import-from-omniroute`** — copies an existing
  OmniRoute claude connection into Dario's account store. Derivative; requires
  a claude connection to already exist.

### 1d. What was NOT found, and where I looked

Stated as "not found in <surfaces>", never as "does not exist."

- **No read of `~/.claude/.credentials.json` or `~/.config/claude/credentials.json`
  for import.** Repo-wide sweep across `src/`, `open-sse/`, `bin/`, `docs/` and
  `tests/` (`*.ts,tsx,mjs,cjs,js,md,json`) returns exactly two non-i18n hits:
  `src/shared/services/cliRuntime.ts:31` (the static `CLI_TOOLS.claude.paths.auth`
  table — `auth: [".claude/.credentials.json", ".config/claude/credentials.json"]`)
  and `ImportClaudeAuthModal.tsx:705` (UI text). **READ:** the accessor
  `getCliConfigPaths("claude")` has exactly two consumers repo-wide, both
  WRITERS — `claudeAuthFile.ts` (apply-local, §1c) and `claudeProfileAutoSync.ts`
  (writes `~/.claude/profiles/<name>/settings.json`). Nothing reads that path to
  obtain a credential.
- **No Keychain read for Claude.** Keychain access exists for exactly two
  providers: Zed (`src/lib/zed-oauth/keychain-reader.ts`, and
  `KEYCHAIN_IMPORT_ONLY_PROVIDERS = new Set(["zed"])` gates it behind an
  explicit Import button) and Raycast (`src/lib/oauth/services/raycastLocal.ts`,
  `security find-generic-password -s Raycast`). Grepped `src/ open-sse/ bin/
  docs/` case-insensitively for `Claude Code-credentials`, `claude-code-credentials`,
  `keychain.*claude`, `claude.*keychain` → **zero hits.**
- **No environment-variable ingest of an Anthropic credential.** Enumerated
  every `process.env.ANTHROPIC*` / `process.env.CLAUDE*` in `src/ open-sse/ bin/`:
  `ANTHROPIC_AUTH_TOKEN` (2 hits, both in `bin/cli/` — the token used to
  authenticate *to* OmniRoute), `ANTHROPIC_API_URL` (vision-bridge base URL),
  `CLAUDE_CODE_REDIRECT_URI`, `CLAUDE_DISABLE_TOOL_NAME_CLOAK`. That is the
  complete set. `open-sse/config/credentialLoader.ts` overrides only OAuth
  *client* config (`clientId, clientSecret, tokenUrl, authUrl, refreshUrl`) —
  never user tokens.
- **No Claude auto-import route.** Auto-import exists for cursor, kiro, raycast
  and nothing else (READ — `src/shared/constants/publicApiRoutes.ts:111-113`,
  `src/server/authz/routeGuard.ts:60-62`).
- **No boot-time credential discovery.** `src/instrumentation-node.ts::registerNodejs()`
  read end to end: DB init, secrets, catalog warm, combo-collision scan, lane
  warm, schedulers, settings hydration. Nothing scans the host for credentials.
- **No browser cookie-store harvesting.** Grepped for `cookies.sqlite`,
  `Local State`, `Login Data`, `Application Support/Google/Chrome`,
  `Application Support/Firefox`, `Safari/Cookies` → no reads of any real
  browser profile.
- **MITM does not capture the bearer.** `src/mitm/handlers/claudeCode.ts`
  parses the body, rewrites `model`, and forwards to OmniRoute's own router via
  `MitmHandlerBase::fetchRouter`, which applies `sanitizeHeaders()` —
  `authorization`, `cookie`, `x-api-key`, `proxy-authorization` are **masked**
  (`src/mitm/sanitizeHeaders.ts`). `src/mitm/detection/claudeCode.ts` only does
  `fs.existsSync` on `~/.claude` and binary paths (installation detection).
  Interception also requires root-CA install (sudo) and an explicitly enabled
  DNS route — the target descriptor says so itself: *"The DNS-routing tutorial
  therefore is opt-in."*
- **Actively scrubbed, not harvested:** `open-sse/executors/devin-cli-agentic.ts:74`
  defines `CLAUDE_ENV_BLOCKLIST = ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", …]`
  — env vars STRIPPED from a spawned CLI. The opposite of an acquisition path.

**Not covered by this pass (stated, not assumed safe):** the ~15k-file tree was
searched by targeted grep, not read exhaustively; `src/app/(dashboard)` client
components beyond the Claude/Raycast/Cursor modals; `docker/` and `scripts/`
beyond `scripts/raycast/extract-credentials.mjs`; the ~350 non-Claude provider
registry entries; and any behavior that exists only in built/published npm
artifacts rather than in this git tree.

---

## 2. Can OmniRoute acquire them WITHOUT explicit operator action? — **No, at this commit**

Every one of paths 1-10 requires an authenticated, deliberate operator act:
clicking through Anthropic's own consent screen, pasting/uploading a file, or
issuing a POST behind `requireManagementAuth`. The closest thing to
self-initiative is `POST /api/oauth/cliproxy-import` (path 8), and even that is
(a) a POST, (b) management-auth'd, (c) loopback-gated, and (d) reading a
directory that only exists if the operator installed a *different* tool and
logged it into Anthropic.

**Therefore: not configuring Claude credentials DOES deny OmniRoute access.**
The hypothesis survives the test. This is the finding the brief asked to be
tested rather than assumed, and it is the honest result of looking for the
counter-evidence.

The reason it holds is architectural, not accidental: OmniRoute's credential
resolution (`src/sse/services/auth.ts::getProviderCredentials`) reads from the
`provider_connections` SQLite table and from nowhere else, with exactly one
exception — a synthetic `"noauth"` connection for providers in
`NOAUTH_PROVIDERS` / no-auth `WEB_COOKIE_PROVIDERS`. READ: that list is
`devin-cli-agentic, opencode, duckduckgo-web, cloudflare-playground, felo-web,
theoldllm, chipotle, veoaifree-web, auggie, zcode, codex-app-server, uncloseai,
aihorde`. **`claude` and `claude-web` are not in it.** There is no env fallback,
no file fallback, no ambient-credential path.

---

## 3. What the operator must NOT do, and how to VERIFY at runtime

### Must not do

1. Never run `omniroute oauth login claude-code`, and never click Connect on
   the Claude provider card.
2. Never call `/api/providers/claude-auth/import`, `/import-bulk`,
   `/zip-extract`, or `/api/oauth/claude/paste-credentials`.
3. Never call `POST /api/oauth/cliproxy-import`. Better: **do not install
   CLIProxyAPI or Dario at all** (§4).
4. Never add a `claude-web` connection (a claude.ai session cookie is the same
   account by another door), and never start the VNC browser-login flow for it.
5. Never call `POST /api/providers/[id]/claude-auth/apply-local` — that is the
   reverse direction and would overwrite the operator's own
   `~/.claude/.credentials.json` (it does take a timestamped `.bak` first, but
   this is still a live-login-clobbering operation on the very account being
   protected).
6. Do not set `OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS=1`, and
   do not enable the equivalent dashboard toggle
   (`settings.preferClaudeCodeForUnprefixedClaudeModels`). Default is `false`
   (READ, `open-sse/services/model.ts:406`). Inert while no claude connection
   exists — enforce it anyway, so two independent things must go wrong.
7. **Do not rely on `blockedProviders`.** Adding `claude` there hides it from
   `/v1/models` and does not stop routing. Documented above; it is the most
   likely operator misunderstanding in this whole design.

### Positively verifiable at runtime

The invariant is *"zero `provider_connections` rows whose provider is a Tier-1
subscription provider."* Two independent checks, one in-band, one out-of-band:

**In-band** (READ — `src/app/api/providers/route.ts` returns
`{ connections, total }`, with `accessToken`/`refreshToken`/`idToken` stripped;
`requireManagementAuth` required):

```
curl -s -H "Authorization: Bearer $OMNIROUTE_MGMT_KEY" \
  'http://127.0.0.1:20128/api/providers?provider=claude' | jq '.total'
```
Must be `0`. Repeat for every id in `OAUTH_PROVIDERS`
(`src/shared/constants/providers/oauth.ts`) plus `claude-web`. The Tier-1 set
per OmniRoute's own `docs/guides/TIERS.md` is Claude Code OAuth, Codex, GitHub
Copilot, Cursor, Antigravity/Devin Desktop — but the full OAuth id list is the
safer sweep: `claude, claude-web, codex, copilot-web, ghe-copilot,
copilot-m365-web, cursor, antigravity, agy, devin-desktop, devin-cli, kiro,
raycast, zed, zed-hosted, trae, qoder, kimi-coding, cline, clinepass, kilocode,
xai-oauth, grok-cli, amazon-q, gitlab-duo, openference, codebuddy-cn`.

**Out-of-band** (authoritative — bypasses the API layer entirely):

```
sqlite3 ~/.omniroute/storage.sqlite \
  "SELECT provider, COUNT(*) FROM provider_connections GROUP BY provider;"
```
`provider_connections` is created in
`src/lib/db/migrations/001_initial_schema.sql:6`; the data dir resolves to
`~/.omniroute` by default (`src/lib/dataPaths.ts`; overridable via `DATA_DIR`
or `XDG_CONFIG_HOME`). The output must contain no Tier-1 id.

**Negative control on the host:** `test ! -e ~/.cli-proxy-api` — the only
directory from which OmniRoute can pull a Claude token off the filesystem.

This is a real control, not a hope: it is a positive assertion about observable
state, checkable in one command, from outside the process being audited. It
should run on a schedule, not once — because of Residual risk 1.

---

## 4. Does process isolation help, or is it required?

**Not required for the mitigation as established — genuinely useful anyway.**
Since no code path reads `~/.claude` or the Keychain for Claude, denying
filesystem access changes nothing about today's behavior. What isolation buys
is that the mitigation stops depending on *this audit having been exhaustive*
and on *the code not changing* (Residual risk 4). It converts "we checked every
path at commit `d82b682`" into "even an unaudited or future path cannot reach
it." That is worth having.

If isolating, it must cover the right things:

- **`~/.claude`** — belt-and-braces only; nothing reads it for credentials today.
- **`~/.cli-proxy-api`** — this is the one that actually matters, the single
  real filesystem→Claude-credential route (path 8).
- **The macOS Keychain.** Containerization already demonstrably severs this —
  OmniRoute's own error string says so: *"OmniRoute is running inside Docker and
  cannot access the host keychain"* (READ, `src/app/api/providers/zed/discover/route.ts:52`).
- **Do NOT set `CLI_CONFIG_HOME`.** Documented in `docs/reference/ENVIRONMENT.md`
  as *"Override home directory for reading CLI configs (`~/.claude`, `~/.codex`)…
  in a container, a bind-mounted path (that is how `/host-home` works)"*. Setting
  it is precisely how you undo the isolation you just built.

**What isolation does NOT protect against, stated plainly:** the browser OAuth
flow needs only network access and a human, and paste-import needs only a human.
A separate UID, a container, and a sandbox all leave paths 1-7 and 9 fully
open. Isolation defends against *silent* acquisition. It does not defend
against operator action, and operator action is where every actual path lives.
So isolation is a second layer under §3's verification, never a replacement
for it.

---

## 5. Fallback cascade — can an error path degrade into Tier-1?

This was the sharpest version of the question ("a pin that holds on the happy
path but degrades to OAuth reuse on an error is worse than no pin"). Traced in
source. **Answer: no cascade reaches Tier-1, and the reasons are structural
rather than incidental.**

**Tier/auto routing is opt-in by model string.** READ,
`src/sse/handlers/autoRouting.ts:97`:

```ts
const isAutoRouting = model === "auto" || model.startsWith("auto/");
```
and `createVirtualAutoCombo()` returns the combo unchanged when
`!state.isAutoRouting`. A request for `mistral/mistral-large-latest` never
enters the multi-provider candidate pool. Stored combos engage only when
`getComboForModel(modelStr)` matches a stored combo NAME
(`src/sse/handlers/chat.ts:877`). Neither fires for a pinned provider/model.

**On the direct path, the only cross-provider hop is emergency fallback**, and
its destination is hardcoded. READ, `open-sse/services/emergencyFallback.ts`:

```ts
export const EMERGENCY_FALLBACK_CONFIG = {
  enabled: true, provider: "nvidia", model: "openai/gpt-oss-120b",
  triggerOn402: true, triggerOnBudgetKeywords: true, skipForToolRequests: true, ...
};
```
It fires at most once, only on HTTP 402 or a budget-keyword match, is skipped
when the request carries tools, and is disableable with
`OMNIROUTE_EMERGENCY_FALLBACK=false`. It cannot select `claude` — the target is
a literal in source, not a tier lookup.

**Other retry/fallback layers, and why each is contained:**

- `open-sse/services/modelFamilyFallback.ts` — sibling models only, and when a
  provider prefix was explicit it pins the prefix:
  `outputPrefix: explicitProvider ? \`${registryEntry.id}/\` : ""` (line 196).
  Cannot cross providers.
- `open-sse/services/accountFallback.ts` — cooldowns, model lockouts, 429
  classification, next-ACCOUNT rotation. Operates within a provider; it marks
  things unavailable, it does not choose a different provider.
- `settings.globalFallbackModel` — fires only INSIDE the combo branch, only on
  502/503, only after a combo exhausted, and only if the operator set it
  (`src/sse/handlers/chat.ts:1138-1146`). Unreachable from a pinned direct
  request; its value is operator-chosen if used at all.
- `chatCore.ts:2733` states the design intent directly: *"Direct/pinned requests
  (isCombo: false) have no other target to fail over to."*

**The one branch that CAN name `claude` — and why the pin matters.** READ,
`open-sse/services/model.ts:810-824`, for a BARE (unprefixed) `claude-*` id:

```ts
if (/^claude-/i.test(modelId)) {
  if (shouldPreferClaudeCodeForUnprefixedClaudeModel(modelId, activeProviders, preferClaudeCode)) {
    return { provider: "claude", model: modelId, extendedContext };
  }
  if (activeProviders?.has("anthropic")) {
    return { provider: "anthropic", model: modelId, extendedContext };
  }
}
// ... "Last resort: no provider could be inferred — return a clear error instead"
```

and the guard (line 414-422) requires BOTH the flag AND
`activeProviders.has("claude")`. So a bare `claude-*` request reaches Tier-1
only if the operator turned the flag on *and* a claude connection exists. With
no connection it errors out cleanly. **This is why `ANTHROPIC_MODEL` must be
pinned:** Claude Code emits bare `claude-*` IDs by default, so an unpinned
setup relies entirely on connection-absence for safety, with no second line.
Pin it, and connection-absence becomes the second line rather than the only one.

---

## 6. On the prior pass's blocking finding

Confirmed, and now explained. This pass also searched for a routing-level
Tier-1 disable and did not find one — the nearest candidates and what they
actually do:

- `blockedProviders` — **visibility only**, per its own UI copy and its call
  sites (`v1/search`, `modelRouteProjection`, `searchRegistry`, MCP provider
  enums, and the no-auth credential branch). Not consulted in
  `getProviderCredentials()` for an OAuth provider. Not a kill switch.
- `OMNIROUTE_PREFER_CLAUDE_CODE_FOR_UNPREFIXED_CLAUDE_MODELS` — the opposite
  polarity: a Tier-1 *widening* flag, default `false`. Its presence in
  `ENVIRONMENT.md:286` is worth recording because the prior pass reported the
  Tier-1 search as finding nothing relevant; this entry is relevant, but it is
  a knob to keep OFF, not the disable that was being looked for.
- `BIFROST_ENABLED` — as the prior pass said, a sidecar killswitch. Unrelated.

The correct conclusion is not "the flag exists after all." It is: **a flag was
never the right control.** A routing flag would be one boolean between the
operator's Anthropic account and a plausible ToS breach. Credential-absence is
a missing row in a database, verifiable in one SQL query, with no code path
able to recreate it unattended.

---

## Residual risks — carry these, do not drop them

1. **Nothing enforces the invariant.** No allowlist gates routing; any future
   operator action (or any agent with the management key) can add a claude
   connection and Tier-1 becomes live immediately, silently. The §3 check must
   be periodic, and ideally automated as a gate rather than run by hand.
2. **Delegated sidecars can hold the credential instead.** READ,
   `src/lib/services/bootstrap.ts`: OmniRoute supervises `9router`, `cliproxy`,
   `mux`, `bifrost`, and `dario` — the last commented in-source as *"Dario
   (@askalf/dario): Claude-subscription proxy… /health is 503 'degraded' until
   the first Claude account is added."* A connection in `mode: "cliproxyapi"`
   routes through CLIProxyAPI using a dedicated key
   (`open-sse/handlers/chatCore/cliproxyapiCredentials.ts`), so the Claude
   subscription can sit behind the sidecar with OmniRoute holding no token at
   all — and the §3 check would show zero claude connections while Tier-1
   traffic flowed. **Gate (READ):** `bootstrapEmbeddedServices()` skips any tool
   whose version-manager row is absent or `status === "not_installed"`, and only
   auto-starts when `row.autoStart`. **Therefore: do not install CLIProxyAPI or
   Dario.** Add to the §3 sweep: `GET /api/v1/management/...` service list, or
   simply confirm nothing is listening on the Dario/CLIProxyAPI default ports.
3. **claude-web is the same account by another door.** Easy to overlook when
   thinking about "Claude Code OAuth." A claude.ai session cookie is the
   operator's Anthropic consumer session; OmniRoute itself marks it
   `subscriptionRisk: true`. It is in the §3 sweep list for that reason.
4. **Version drift is not hypothetical here.** Findings are pinned to
   `d82b682`; the default branch moved to `6435f61` during this session. Every
   enumeration in §1 is a statement about one commit. Any OmniRoute upgrade
   invalidates it and requires re-running at minimum: the `~/.claude` /
   Keychain / env sweeps, the auto-import route list, and the boot sequence.

---

## Sources

**OmniRoute source, commit `d82b68274c75c14d258b4898a34edc25d9712b87`**
(read-only sparse checkout; `src/ open-sse/ bin/ docs/`):
- `src/app/api/providers/claude-auth/{import,import-bulk,zip-extract}/route.ts`
- `src/app/api/providers/[id]/claude-auth/{apply-local,export}/route.ts`
- `src/app/api/oauth/cliproxy-import/route.ts`, `src/lib/oauth/utils/cliProxyAuthImport.ts`
- `src/app/api/oauth/[provider]/[action]/route.ts`, `.../keychainImportOnly.ts`, `.../paste-credentials/route.ts`
- `src/app/api/oauth/{cursor,kiro,raycast}/auto-import/route.ts` (the complete auto-import set)
- `src/lib/oauth/providers/claude.ts`, `src/lib/oauth/constants/oauth.ts`, `src/lib/oauth/utils/{claudeAuthImport,claudeAuthFile}.ts`
- `src/shared/services/cliRuntime.ts` (`CLI_TOOLS`, `getCliConfigPaths`)
- `src/lib/zed-oauth/keychain-reader.ts`, `src/lib/oauth/services/raycastLocal.ts` (the complete Keychain set)
- `src/sse/services/auth.ts` (`getProviderCredentials`, synthetic no-auth), `src/sse/services/noAuthProviderSettings.ts`
- `src/sse/handlers/chat.ts` (combo dispatch, emergency + global fallback), `src/sse/handlers/autoRouting.ts`
- `open-sse/services/{emergencyFallback,modelFamilyFallback,accountFallback,model}.ts`
- `open-sse/handlers/chatCore.ts` (`isCombo`, pinned-request comment), `.../chatCore/cliproxyapiCredentials.ts`
- `open-sse/config/credentialLoader.ts`
- `src/mitm/{detection,handlers,targets}/claudeCode.ts`, `src/mitm/{sanitizeHeaders,handlers/base}.ts`
- `src/lib/vncSession/{manifest,harvest}.ts`, `open-sse/services/claudeTurnstileSolver.ts`
- `src/lib/services/bootstrap.ts`, `src/instrumentation-node.ts`, `src/lib/warmupScheduler.ts`, `src/lib/services/quotaAutoPing.ts`
- `src/shared/constants/providers/{oauth,noauth,web-cookie}.ts`, `src/shared/constants/publicApiRoutes.ts`, `src/server/authz/routeGuard.ts`
- `src/app/api/providers/route.ts`, `src/lib/dataPaths.ts`, `src/lib/db/migrations/001_initial_schema.sql`
- `docs/guides/TIERS.md`, `docs/providers/CLAUDE_WEB.md`, `docs/reference/ENVIRONMENT.md`
- `bin/cli/commands/{oauth,setup-claude,configure}.mjs`
- `api.github.com/repos/diegosouzapw/OmniRoute` (default branch + current tip)

**This repo:**
- `docs/analysis/2026-08-25-omniroute-fallback-transport.md` (§4a blocking finding — resolved here)
- `docs/analysis/2026-08-23-omniroute-assessment.md` (prior verdict, not re-litigated)

## OUT OF SCOPE

- Data-handling/no-train/retention posture of Mistral or LLM7 — owner has
  explicitly accepted that risk; deliberately not re-litigated.
- The 2026-08-23 cost-routing verdict and the prompt-caching loss (unchanged).
- Whether the fallback-transport feature should ship at all — this pass answers
  only whether the Tier-1 blocker can be structurally closed.
- Auditing the ~350 non-Claude providers, `docker/`, and dashboard client
  components beyond those named in §1.
- Any code, hook, config, install, or run. Nothing was executed; OmniRoute was
  read, never started.
