# OmniRoute install audit: default management password (CHANGEME)

**Install:** `/Users/rj/omniroute` (source checkout, v3.8.51, pinned commit `d82b682`), data dir `/Users/rj/.omniroute`, bound to `127.0.0.1:20128` only.
**Auditor:** security-auditor subagent. **Date:** 2026-08-25/26.
**Verdict: FIXED.** The default management password has been rotated to a strong random value. Old password now rejected (401), new password accepted (200). `provider_connections` confirmed empty before and after. `bin/heimdall-fallback check` confirms the three required checks still `[OK]` post-restart.

## 1. What the management password actually protects

Read `src/lib/api/requireManagementAuth.ts` (the single authz gate used across OmniRoute's admin surface) and `src/server/authz/routeGuard.ts`. The management password, once exchanged for a session at `POST /api/auth/login`, is one of several ways to satisfy `requireManagementAuth`. Endpoints behind it include:

- **Provider connections**: create/import/delete, including `POST /api/providers/claude-auth/import` (the endpoint that ingests a Claude/Claude-web OAuth credential — see §2).
- **API key management**: create/rotate/revoke keys used by the token-authenticated `/v1/*` inference surface.
- **Settings**: CORS allowlist, `REQUIRE_API_KEY`, `bruteForceProtection`, `corsOrigins`, and other runtime-hydrated config (`src/server/cors/origins.ts`'s `setRuntimeAllowedOrigins()` is driven from here).
- **DB backup/restore**: `/api/settings/database`, `/api/db-backups`, `/api/settings/export-json`, `/api/settings/import-json` — `routeGuard.ts` calls the last two "a credential dump and an irreversible replace" in its own comments.
- Dashboard access broadly (any authenticated UI route).

This is not a narrow "view dashboard" password — it is the root credential for the entire admin/management plane, including the one action (§2) that determines whether Tier-1 is live.

## 2. Can the management password defeat the Tier-1 mitigation? Yes.

Per `docs/analysis/2026-08-25-omniroute-credential-isolation.md`, the Tier-1 mitigation (OmniRoute cannot repurpose a Claude/Claude Code subscription as a routing backend) rests entirely on `provider_connections` containing no row with `provider IN ('claude','claude-web')`. That doc's own "Residual risk 1" already names this precisely: *"Nothing enforces the invariant. No allowlist gates routing; any future operator action (or any agent with the management key) can add a claude connection and Tier-1 becomes live immediately, silently."*

Every path that creates such a row (manual paste, OAuth import via `POST /api/providers/claude-auth/import`) sits behind `requireManagementAuth`. So: **anyone who can authenticate as the management user can create the `claude`/`claude-web` connection and flip Tier-1 live** — no code change, no restart, no other control in between. A default, publicly-documented password means "anyone who can authenticate" collapses to "anyone who can reach the login endpoint," with zero guessing required. This is exactly why a CHANGEME default is more than a generic hygiene issue here: it is one HTTP request away from defeating a mitigation that another analysis in this repo depends on to protect the operator's Anthropic account.

## 3. Realistic exposure with a loopback-only bind — specifics, not reassurance

`127.0.0.1`-only is a real, meaningful restriction (no LAN/internet reachability), but it is not equivalent to "only the operator can reach it."

- **Other local processes / other OS accounts on the same machine**: loopback sockets have no cross-user isolation on macOS/Linux by default. Any other process or account on this machine could reach `127.0.0.1:20128` freely. On a genuinely single-user personal machine this is a smaller slice of the risk; on any shared/multi-account machine it is not.
- **Classic CSRF (background fetch/form-POST from a malicious webpage)**: mitigated. `src/app/api/auth/login/route.ts` sets the session cookie `httpOnly: true, sameSite: "lax"`, which blocks the browser from attaching it to a cross-site POST, and CORS (`src/server/cors/origins.ts`) is fail-closed by default (no wildcard unless `CORS_ALLOW_ALL=true`).
- **DNS rebinding — the sharper, unmitigated risk.** I read `src/server/authz/routeGuard.ts`, `src/lib/api/internalServiceAuth.ts`, and the CORS/cookie code above and found **no Host-header allowlist or anti-rebinding check** anywhere in this request path. A DNS-rebinding attack (victim visits `http://attacker.example/`, whose DNS TTL is manipulated so a follow-up connection to the *same hostname* resolves to `127.0.0.1`) makes the browser treat OmniRoute's response as same-origin — no CORS bypass needed, because from the browser's perspective there never was a cross-origin request. A rebound page can:
  1. Blind-POST `{"password": "<guess>"}` to `/api/auth/login` (a *necessarily* public, unauthenticated endpoint — login can't require what it's issuing) and receive a valid `auth_token` cookie scoped to `attacker.example`.
  2. From that point on, drive the real OmniRoute dashboard/API as an authenticated same-origin client — including `POST /api/providers/claude-auth/import`.
  - I checked whether OmniRoute's separate "trusted loopback" internal-service path (`isTrustedLoopbackInternalServiceRequest` in `internalServiceAuth.ts`) offers rebinding attackers a shortcut around the password entirely, since it keys partly off request locality. It does not: it additionally requires a `timingSafeEqual` match against a server-configured secret (`OMNIROUTE_INTERNAL_SERVICE_TOKEN[_FILE]`) that a remote page cannot supply (and that header isn't in the CORS-preflight allowlist either), and it returns `false` unconditionally when that token is unset. This path is not part of the exploitable surface.
  - **The bottleneck for the whole DNS-rebinding chain is step 1: knowing the password.** With `CHANGEME`, that requirement is zero — it is printed in OmniRoute's own shipped `.env.example`/`ENVIRONMENT.md`. The login brute-force guard (`src/server/auth/loginGuard.ts`: 5 attempts / 15-min lockout, per-IP) is irrelevant to a public default; it only matters once the password is actually secret, at which point it also meaningfully bounds any *guessing* attempt against the loopback IP the guard would see (the victim's own `127.0.0.1`) to 5 tries per 15 minutes — infeasible against a 256-bit random value.
  - **Net conclusion**: DNS rebinding against this service is a real, live structural gap in OmniRoute itself (not something I changed or was asked to change — it is third-party pinned-commit code), but the actual exploitability of that gap was entirely gated by password secrecy. Fixing the password closes the practical risk; the missing Host-header validation remains a residual, low-urgency hardening item for upstream OmniRoute (informational, not actioned here).

## 4. Why the fix is `reset-password.mjs`, not an `.env` edit

The task's default preference was a non-interactive env/config fix over a dashboard login. I read `src/lib/auth/managementPassword.ts` and confirmed `INITIAL_PASSWORD` is **only** consulted by `ensurePersistentManagementPasswordHash()` when no bcrypt hash is yet stored (`isBcryptHash(storedPassword)` returns early otherwise). The live app log (`/Users/rj/.omniroute/logs/application/app.log`, line 14, `2026-08-25T13:16:02.072Z`) already shows `"[AUTH] Migrated INITIAL_PASSWORD to bcrypt hash during startup"` — the hash was already persisted in `key_value` (`namespace='settings', key='password'`) in `/Users/rj/.omniroute/storage.sqlite`. Editing `INITIAL_PASSWORD` in any `.env` at this point would be **inert** — it would never be re-read.

OmniRoute ships a first-party, non-interactive alternative for exactly this: `bin/reset-password.mjs --password-stdin`, documented for CI/Docker use. It calls `resetManagementPassword()` directly against the persisted DB value (bcrypt, `SALT_ROUNDS=12`) — no HTTP request, no dashboard, no browser session. This is the tool actually used here, and it satisfies the spirit of "prefer non-interactive fix" more precisely than the literal env-var suggestion would have (which would not have worked).

## 5. What was changed

1. **Generated a strong random password** (`openssl rand -hex 32`, 256 bits of entropy) and wrote it directly to a **new file, never printed, never logged, never committed**:
   - `/Users/rj/.omniroute/management-password.txt` — permissions `-rw-------` (0600), owner `rj`, 65 bytes. This matches this repo's own precedent (`bin/heimdall-invite`'s secret-by-reference pattern; `.heimdall/team.json` at 0600).
2. Applied it via `DATA_DIR=/Users/rj/.omniroute node bin/reset-password.mjs --password-stdin < management-password.txt` (Node v24.13.0, matching `.node-version`) — exit 0, `"Password reset successfully!"`.
3. **Incidental finding, fixed**: `/Users/rj/.omniroute/server.env` (contains `JWT_SECRET`, `STORAGE_ENCRYPTION_KEY`, `API_KEY_SECRET`) was `-rw-r--r--` (0644, world/group-readable). Changed to `-rw-------` (0600).
4. Restarted OmniRoute. The prior boot had been running via `npm run dev` (Next.js dev server, turbopack) and had already been cleanly stopped (SIGTERM, `"[Shutdown] Bye."`, 2026-08-25T14:15:50Z) before this audit began — no server was killed to make this change. For the restart I deliberately used the documented webpack fallback (`OMNIROUTE_USE_TURBOPACK=0`) instead of turbopack: a separate agent working in this same repo session had already diagnosed a turbopack-native-addon segfault on dev-mode restart (session memory, not independently reproduced by me) and identified webpack as the fix; reusing that finding avoided reproducing a known crash for what should be a narrowly-scoped verification restart. `HOST=127.0.0.1` and `DATA_DIR=/Users/rj/.omniroute` were set explicitly. This is an operational choice about *how* to boot, not a code change to OmniRoute.

Nothing in the heimdall repo itself was modified except this document. `bin/heimdall-fallback`, `bin/hmd-exec`, `bin/lib/issue_loop.py`, `hooks/`, `sentinels/`, `~/.claude/settings.json`, and port 8787 were not touched.

## 6. Verification evidence

**Before restart**, `provider_connections` (baseline):
```
$ sqlite3 /Users/rj/.omniroute/storage.sqlite "SELECT COUNT(*) FROM provider_connections;"
0
```

**Server back up**, loopback-only, healthy:
```
$ lsof -nP -iTCP:20128 -sTCP:LISTEN
COMMAND   PID USER   FD   TYPE  ... NAME
node    29102   rj 1526u  IPv4  ... TCP 127.0.0.1:20128 (LISTEN)

$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:20128/api/monitoring/health
200
```
No `0.0.0.0` or `*` binding for port 20128 — confirmed loopback-only, both via `lsof` and `netstat`.

**Old password now rejected, new password now accepted** (`POST /api/auth/login`):
```
CHANGEME              -> http_code=401
<new password, from the 0600 file, never printed> -> http_code=200, Set-Cookie: auth_token=<redacted>; HttpOnly; SameSite=lax; Max-Age=2592000
```

**Application log** (`/Users/rj/.omniroute/logs/application/app.log`): the `[AUTH][SECURITY] ... well-known default "CHANGEME"` warning appears exactly once, at the *original* boot (`2026-08-25T13:16:02.072Z`), and does **not** reappear on the post-fix boot (`2026-08-25T18:41:07Z` onward) — consistent with the persisted hash no longer matching a known-insecure default.

**`provider_connections` after restart** (task's explicit ask):
```
$ sqlite3 /Users/rj/.omniroute/storage.sqlite "SELECT provider, COUNT(*) FROM provider_connections GROUP BY provider;"
(no rows)
$ sqlite3 /Users/rj/.omniroute/storage.sqlite "SELECT COUNT(*) FROM provider_connections;"
0
```
Tier-1 mitigation intact, unchanged by the restart.

**`bin/heimdall-fallback check`** (read-only, not modified), run after the restart:
```
[OK  ] endpoint_local
[OK  ] endpoint_reachable
[OK  ] tier1_credential_absent
[OK  ] prefer_claude_code_flag_off
[OK  ] no_delegated_sidecar
```
(Overall verdict is `REFUSE` — driven by `state=off`, missing `operator_key`, `anthropic_model_pinned`, `target_provider_allowed`; these are unrelated fallback-routing configuration toggles, not affected by this fix, and were already in this state before it. The three checks this task asked about are exactly the three that report `[OK]`.)

## 7. What the operator must do

- **The new management password lives at `/Users/rj/.omniroute/management-password.txt` (mode 0600, this machine only).** Read it with `cat /Users/rj/.omniroute/management-password.txt` to log into the OmniRoute dashboard at `http://127.0.0.1:20128`. It is not printed anywhere in this document, any log, or any commit.
- Recommended next step for the operator (not done here — requires the dashboard session this task was told to avoid): log in once with the file's password and rotate it again via Dashboard → Settings → Security to a password only you know, then delete or clear the file. Until then the file is the credential of record and is protected at the filesystem level (0600, single owner).
- If OmniRoute's data directory (`/Users/rj/.omniroute`) is ever wiped/recreated, `INITIAL_PASSWORD` in `/Users/rj/omniroute/.env` will again bootstrap a *fresh* hash — and it is still literally `CHANGEME` in that file today. This was deliberately left alone (out of scope for a "small" fix, and writing a new plaintext password into a 169KB hand-authored `.env` risks corrupting it for no runtime benefit — `INITIAL_PASSWORD` is dead until/unless a wipe happens). Operator may want to blank it or set it to a throwaway strong value as separate, low-urgency hardening.

## Findings

| # | Severity | Category | Finding | Location | Fix |
|---|----------|----------|---------|----------|-----|
| 1 | CRITICAL | Broken auth / default credential (OWASP A07) | Management password left at well-known default `CHANGEME`; gates provider-connection creation (incl. Claude OAuth import), API key mgmt, DB export/import, full dashboard. Directly capable of defeating the Tier-1 mitigation with zero guessing. | `/Users/rj/.omniroute/storage.sqlite` (`key_value` table), OmniRoute `src/lib/auth/managementPassword.ts` | **Fixed.** Rotated via `bin/reset-password.mjs --password-stdin` to a 256-bit random value stored at `/Users/rj/.omniroute/management-password.txt` (0600). Verified old password now 401s, new password 200s. |
| 2 | MEDIUM | Sensitive data exposure | `server.env` (contains `JWT_SECRET`, `STORAGE_ENCRYPTION_KEY`, `API_KEY_SECRET`) was world/group-readable (0644). | `/Users/rj/.omniroute/server.env` | **Fixed.** `chmod 600`. |
| 3 | INFO | Security misconfiguration (residual, not actioned) | No Host-header allowlist / anti-DNS-rebinding check found in OmniRoute's request path; a loopback-only bind is not equivalent to browser-unreachable. Exploitability was fully gated by password secrecy, now closed by finding #1's fix. | OmniRoute `src/server/authz/routeGuard.ts`, `src/server/cors/origins.ts` (third-party, pinned commit `d82b682`) | Not actioned — upstream OmniRoute hardening opportunity, out of scope for this task. |
| 4 | INFO | Config hygiene (residual, not actioned) | `INITIAL_PASSWORD=CHANGEME` remains in `/Users/rj/omniroute/.env`; inert today (bcrypt hash already persisted) but would re-bootstrap the same insecure default if the data dir is ever wiped. | `/Users/rj/omniroute/.env` | Not actioned — flagged for operator as optional follow-up. |
