# Multi-Tenant Private Team Presence — Threat Model

- Date: 2026-06-27
- Scope: making Heimdall team presence MULTI-TENANT + PRIVATE.
- Status: read-only threat model. No code changed. Controls below are implementation MUST-haves.
- Repo state read: `bin/lib/cp_enroll.py`, `cp_presence.py`, `cp_publicsurface.py`, `cp_ratelimit.py`, `cp_nonce.py`, `cp_auth.py`, `bin/heimdall-presence`, `heimdall-site/team.html`, `deploy/cloud-run/deploy-public-surface.sh`.

## New model (as designed in parallel by the architect)

- A TEAM = a self-generated `team_secret` (high-entropy, repo-scoped). `team.html` already mints 32 bytes → 43-char base64url client-side (`crypto.getRandomValues`).
- `team_id = SHA256(team_secret)` — the partition key. High-entropy hash, NOT a project name.
- Presence keyed by `(project, team_id)` instead of today's `(project, haid)`-under-`project`.
- A beat is signed by an enrolled member (existing PKI chokepoint, §3 `cp_auth.verify_identity`).
- The roster read returns full HAID + activity ONLY to a caller PROVING team membership.
- Goal: only teammates holding the team token see each other; other teams + outsiders see NOTHING.

## Today's reality (the baseline this must replace)

1. Presence is partitioned by `project` ONLY (`cp_presence._record_rel` → `presence/<project_slug>/<haid_slug>.json`). No team concept.
2. `project` is GUESSABLE: `heimdall-presence` derives it from the NORMALIZED git remote (`normalize_remote`). For any public repo, the project id is public knowledge.
3. `GET /roster` (signed, `roster_route`) returns the FULL roster — including `haid` — to ANY verified identity, with NO team/project-membership check. Any enrolled dev on the planet can read any project's full roster.
4. `GET /roster-public` (unsigned, `roster_public_route`) returns handle/verdict/file (scrubbed of `haid`) to ANYONE for ANY project, over CORS `*`.
5. Enroll registers `haid → pubkey` GLOBALLY (`cp_auth.register_key`), `owner=False`. No team binding. Any enrolled haid can beat into any project (`beat_route` keys by verified haid under a body-supplied project).

Net: there is no tenancy boundary today. Presence is a single global namespace keyed by a guessable project id. This is exactly the cardinal risk the new model must close.

---

## Risk 1 — CROSS-TEAM PRESENCE LEAK (cardinal)

The whole feature's reason to exist. Can anyone read team A's presence without team A's secret? Every path:

### 1a. Signed `GET /roster` returns everyone (CURRENT BREAK)
- Attack: team-B member (any enrolled haid) sends signed `GET /roster?project=<A's project>`. `roster_route` calls `roster(project)` and returns team A's full records incl. `haid`. Project id is guessable (1.2), so the attacker needs only their own valid enrollment.
- Impact: full cross-team disclosure of haid + handle + verdict + current file, to any enrolled outsider.
- REQUIRED control: the roster read MUST be scoped to a `team_id` the caller is PROVEN to belong to. Server resolves the roster from `(project, team_id)`; the `team_id` selector is authorized against a SERVER-SIDE membership record (`(haid, team_id)` established at enroll, §1d), NOT taken on trust from the request. A signed read for a `team_id` the verified haid is not enrolled in → 403/empty.

### 1b. Unauthenticated `GET /roster-public` (CURRENT BREAK)
- Attack: anyone, no auth, `GET /roster-public?project=<any>` → handle/verdict/file for that project's online devs.
- Impact: outsider + cross-team disclosure of activity (no haid, but handles + file paths). Incompatible with a PRIVATE model.
- REQUIRED control: REMOVE the fully-public `/roster-public`, or TEAM-GATE it (require `team_secret` in a header, hashed server-side to `team_id`; return only that team's records). Recommendation: KEEP the route name for the browser dashboard but require the `team_secret` header — without it, 403 (not an empty 200). Drop `Access-Control-Allow-Origin: *` to an allowlist if the dashboard origin is known; `*` is acceptable only because the read now requires a secret header the attacker doesn't have.

### 1c. `team_id` must be high-entropy, not derived from project
- Attack: if `team_id` were `hash(project)` or any low-entropy/guessable input, an attacker enumerates team_ids offline and reads every team.
- Impact: total isolation bypass.
- REQUIRED control: `team_id = SHA256(team_secret)` where `team_secret` is ≥32 bytes CSPRNG (the `token_urlsafe(32)` / `crypto.getRandomValues(32)` shape already used in `team.html`). team_id MUST NOT incorporate the project name as its entropy. Project remains a non-secret namespace; the secret is the only entropy that matters.

### 1d. Membership bound SERVER-SIDE, not from the request body
- Attack: if the beat/read trusts a `team_id` (or worse a `team_secret`) field from the body without binding it to the verified identity, a team-B member writes/reads team A by just naming team A's id.
- Impact: write-poisoning (inject fake teammates into A) + read bypass.
- REQUIRED control: at ENROLL the caller presents `team_secret`; server computes `team_id` and records membership `(haid, team_id)` durably (next to the key registry, on the StateBackend seam). Thereafter:
  - BEAT: keyed by `(project, team_id, verified-haid)`. The `team_id` is accepted only if `(haid, team_id)` is a recorded membership; otherwise 403. The partition is `(project, team_id)`; the record key stays the VERIFIED haid (a dev still cannot overwrite a teammate's record — today's `cp_ingest §5` discipline, preserved).
  - READ: `team_id` is a SELECTOR; authorized iff `(verified-haid, team_id)` membership exists.

### Falsifiable cross-team isolation test (the implementation MUST pass)
Two teams on ONE project P:
- secret_A → team_id_A; member A1 enrolls into team A (presents secret_A) + beats to (P, team A).
- secret_B → team_id_B; member B1 enrolls into team B (presents secret_B) + beats to (P, team B).

Assertions:
1. A1 signed `GET /roster` for (P, team_id_A) → roster contains A1, does NOT contain B1.
2. B1 signed read for (P, team_id_B) → contains B1, NOT A1.
3. A1 signed read naming team_id_B (a team A1 never joined) → 403/empty (membership selector rejected).
4. Outsider (no secret, no enrollment) browser read for P with NO `team_secret` header → 403.
5. Browser read presenting `team_id_A` AS the secret (the hash, not the pre-image) → 403/empty (team_id is inert — see Risk 3).
6. Browser read presenting secret_B for P → only team B records; never team A (mismatch either direction isolates).
7. `GET /roster-public?project=P` with no team header → 403 (the old fully-public read is gone).

Test 5 + 6 are the load-bearing falsifiers: break the hashing/membership binding and one of them flips.

---

## Risk 2 — TOKEN HANDLING / SAFE TRANSPORT

`team_secret` is a bearer secret. Where it travels decides whether it leaks.

- URL QUERY (`?team_secret=…`) — UNSAFE. Leaks to: GFE/Cloud Run access logs (they log path+query), any proxy/CDN, browser history, and the `Referer` header sent to every third-party asset the page loads. This is the same class of bug the codebase already fought for `job_id` (signed-query saga). NEVER put the secret in the query.
- HEADER (e.g. `X-Heimdall-Team-Secret: <secret>`) — SAFE. GFE logs the request line + standard fields, not arbitrary request headers; not in history, not in `Referer`. Works for a GET (only GET-with-a-BODY is rejected by GFE; a GET with a custom header is fine).
- POST BODY — SAFE (not logged), but the roster read is a GET; GFE rejects GET-with-body. So for the GET read, the HEADER is the only safe transport.

RULING:
- BROWSER dashboard: send `team_secret` in the `X-Heimdall-Team-Secret` HEADER over HTTPS on the roster read. Server hashes it to `team_id`, returns that partition. (This changes `team.html`'s "the token never leaves your browser" copy — see Risk 4 note; the secret MUST now be sent, in a header, over TLS, to the team's own control plane. Update the copy to "sent only to your control plane, over TLS, in a header — never in the URL, never logged.")
- CLI (`heimdall-presence`): present `team_secret` ONCE at enroll/join (header `X-Heimdall-Team-Secret` on `POST /enroll`, GFE-safe as a POST). After enrollment the `(haid, team_id)` membership is server-side, so signed beats/reads carry the `team_id` SELECTOR only — NO secret on the wire per beat. Secret exposure is minimized to the single join call.

SERVER storage + logging:
- Store ONLY `team_id = SHA256(team_secret)`. NEVER persist the raw secret. NEVER log it (no echo in any response, same discipline as `HEIMDALL_ENROLL_TOKEN` in `cp_enroll`).
- Derive `team_id` by one-way hash of the presented secret and use it directly as the partition key. Because authorization is "hash what the caller sent and look up that partition", there is no secret-to-secret comparison and thus no timing oracle to defend. If any code path DOES compare two secret/id values, it MUST use `hmac.compare_digest` (as `cp_enroll._token_matches` already does).
- Rate-limit keys derived from the secret/team_id MUST be hashed before they touch the store/logs — `cp_ratelimit._key_hash` already does exactly this; reuse it.

---

## Risk 3 — `team_id` AS A BEARER CAPABILITY

If reads were authorized by presenting `team_id` (the hash) directly, then a `team_id` leaked from ANY log/store grants read. `team_id` WILL appear in: store paths (`presence/<project>/<team_id>/…`), Firestore doc ids, and operator/SA-visible state. So it is NOT secret at rest.

- Attack: an operator log line, a Firestore export, or a stray debug print exposes `team_id`; an attacker replays it as the read credential and gets the roster.
- Impact: isolation bypass from a low-sensitivity leak (a hash, not the secret).
- REQUIRED control: `team_id` alone is INERT. The wire NEVER accepts `team_id` as the auth credential. Read authorization is one of:
  - (preferred, CLI) a SIGNED member request whose verified `haid` has a stored `(haid, team_id)` membership; the request's `team_id` is only a selector, useless without the membership row, and the membership row was only created by presenting the secret at enroll.
  - (browser) presenting the `team_secret` (the PRE-image), which the server hashes to `team_id`. Presenting `team_id` itself hashes to `SHA256(team_id) ≠ team_id` → wrong partition → empty/403.
- Falsifiable: test 5 above (present the hash as the secret → 403/empty). This is the single check that proves team_id is not a capability.

VERDICT: require the SECRET (hashed server-side) or a signed member request. Do NOT authorize on a presented `team_id`.

---

## Risk 4 — HAID + ACTIVITY EXPOSURE (intended, bounded)

- Intended scope CONFIRMED: RJ wants teammates to see each other's HAID + edits (current file). The new team read INTENTIONALLY exposes `haid` (and handle/verdict/file/age) to MEMBERS of the same `team_id`. This is the deliberate difference from today's `_public_view`, which scrubs `haid`.
- REQUIRED bound: exposure is to same-`team_id` members ONLY. A non-member gets NOTHING (no haid, no handle, no file) — enforced by Risk 1's membership gate. There is no haid/file leak to outsiders or other teams.
- Secret hygiene preserved: every free field still passes `telemetry._scrub` at write (`build_record → _clean`), so a credential cannot enter a record. Keep this.
- PII WARNING (document for users; not a hard blocker within a trusted team):
  - `file` is a path. It may contain the local OS username (`/Users/<name>/…`), internal/customer project names, and directory structure. These are exposed to ALL team members. Within a trusted team this is the point; still, RECOMMEND relativizing file paths (strip `$HOME`/repo-root prefix) before they enter the record so a member's local username + tree are not broadcast. Optional but cheap.
  - `handle` may be a real name. Acceptable (it is the display identity), but note it is now joined to `haid` for members.
  - `haid` is a stable cross-project correlator. Exposed only to members, but a member can correlate a teammate's activity across every shared team. Acceptable within the trust model; document it.

---

## Risk 5 — ABUSE / DoS

Existing controls (keep, all already present): per-IP + per-token enroll caps, deployment-wide `enroll_budget`, hard registry-size cap (`HEIMDALL_ENROLL_MAX_KEYS`), per-IP + per-haid presence caps, replay-nonce on beats, fixed-window durable counters, fail-open limiter / fail-closed token gate. The new tenancy ADDS these:

### 5a. Per-team flood / registry bloat
- Attack: one (leaked or legit) `team_secret` floods enroll or presence, or grows the roster store under one team unbounded.
- REQUIRED: add a per-`team_id` enroll cap and per-`team_id` presence cap (new `cp_ratelimit` scopes keyed by the hashed team_id), plus a cap on members-per-team and records-per-`(project, team_id)`. Reuse `cp_ratelimit.allow` / the `enroll_budget_ok` pattern; the team_id is hashed by `_key_hash` before it is a path segment.

### 5b. Team CREATION spam (NEW, unbounded by default)
- Attack: first use of a fresh `team_secret` springs a new `team_id` partition into existence (first enroll/beat). On the `--allow-unauthenticated` surface, an attacker rotates secrets to create UNBOUNDED distinct teams → store/registry bloat, cost, Firestore document explosion. Because `team_id` is high-entropy, per-team caps do NOT help (every secret is a new team).
- Impact: resource exhaustion / cost DoS on the open surface.
- REQUIRED: a per-IP team-CREATE cap (creating a not-yet-seen team_id counts against the caller's IP bucket) AND a GLOBAL team-count ceiling (a deployment-wide cap on distinct team_ids per window, mirroring `enroll_budget_ok`'s single global counter). A net-new team beyond the global cap → 429. Net-new team detection = "this team_id has no membership/records yet".

### 5c. Presence store growth
- Note: today there is no per-project record cap; a flood of distinct haids bloats a project dir. Under teams, cap records per `(project, team_id)` (5a) and rely on the TTL fold (`roster()` drops > TTL) + the create caps (5b) for the global bound.

### 5d. Replay
- Keep the replay-nonce gate on beats (`cp_nonce.accept`, `check_presence_post_auth`) unchanged. The team_id selector rides inside the SIGNED body so it is tamper-evident; it does not weaken the nonce gate.

---

## Risk 6 — LEAKED TEAM TOKEN: blast radius

What a leaked `team_secret` grants:
- JOIN that team (enroll a haid into `team_id`) + SEE that team's presence (roster of `(project, team_id)`).
- That is ALL. Bounded and NON-escalating:
  - Enroll always sets `owner=False` (`cp_enroll.enroll` re-asserts `owner=False` unconditionally, line 252). A team token can NEVER mint an owner.
  - Presence-only: a beat/roster is DATA, no `action_type`/handler/dispatch path (`cp_presence` §2 line; `build_record` is a closed schema).
  - The public-surface boundary still 404s every gated route (`PUBLIC_ROUTES` allowlist), and the least-privilege SA has NO `run.jobs.run` (deploy PREFLIGHT P2/P3). So even a leaked token + a hypothetical handler bug cannot dispatch a job.
  - Cannot hijack an already-enrolled haid (the `haid_pubkey_conflict` 409 holds).
- CONFIRMED: a leaked team token's blast radius is "join + read one team's presence", non-escalating, bounded by the same SA/boundary that bounds everything else.

ROTATION:
- A team rotates by generating a NEW `team_secret` → NEW `team_id` → NEW partition. Distribute the new secret to members.
- Rotation does NOT auto-de-enroll: old presence records under the OLD `team_id` remain readable by anyone still holding the OLD secret UNTIL they TTL out (≤ `PRESENCE_TTL_SECONDS`, default 45s) — but no NEW beats land there once members re-point, so the old roster empties within one TTL. Members must RE-JOIN with the new secret (re-enroll membership `(haid, new_team_id)`); a member who is not given the new secret is effectively evicted after one TTL.
- To force-evict a compromised member: rotate + redistribute to everyone EXCEPT them. There is no per-member revoke within a team_id (membership is by secret possession); rotation is the eviction primitive. Document this.

---

## Risk 7 — the `--allow-unauthenticated` public surface

- enroll + roster read are unauthenticated AT THE EDGE; the `team_secret` (hashed → team_id, + signed membership) is the APP-LAYER auth. This is robust GIVEN: per-IP/per-team/global rate limits (Risk 5), one-way hashing of the secret (no stored/logged secret, Risk 2/3), and TLS transport in a header (Risk 2). The edge being open is fine because the app layer now enforces tenancy.
- The boundary is UNTOUCHED by this feature: `PUBLIC_ROUTES` (`cp_publicsurface`) still serves only `{enroll, presence, roster, roster-public, health}` and flat-404s every gated route; the deploy's PREFLIGHT P1/P2/P3 + least-privilege SA (no `run.jobs.run`) are unchanged. The new team-gating is PURE app-layer authz added to the read/beat handlers — it does not add a route, a write seam, or an SA permission.
- CONFIRMED ROBUST, with the two MUST-haves: (a) `/roster-public` stops being fully public (Risk 1b) — otherwise the app-layer auth is a no-op for the browser path; (b) the global team-create cap (Risk 5b) — otherwise the open edge allows unbounded team creation.

---

## Ranked risks + REQUIRED controls (implementation MUST-haves)

1. CROSS-TEAM READ via signed `GET /roster` (CRITICAL, current break) → scope every read to a `team_id` authorized by SERVER-SIDE `(haid, team_id)` membership; `team_id` from the request is a selector only. [Risk 1a, 1d]
2. CROSS-TEAM/OUTSIDER READ via `GET /roster-public` (CRITICAL, current break) → remove the fully-public read or require `team_secret` header; no secret → 403, not empty-200. [Risk 1b]
3. `team_id` AS CAPABILITY (HIGH) → authorize on the SECRET (hashed server-side) or a signed member request; never accept `team_id` as the credential; team_id stays inert. [Risk 3]
4. SECRET TRANSPORT (HIGH) → `team_secret` in the `X-Heimdall-Team-Secret` HEADER over TLS (browser read + CLI join); NEVER in the URL query; store ONLY the hash; never log it. [Risk 2]
5. team_id ENTROPY (HIGH) → `team_id = SHA256(team_secret)`, `team_secret` ≥32 bytes CSPRNG; never project-derived. [Risk 1c]
6. TEAM-CREATE DoS (MEDIUM) → per-IP create cap + GLOBAL distinct-team ceiling on the open surface. [Risk 5b]
7. PER-TEAM ABUSE (MEDIUM) → per-`team_id` enroll/presence caps + members-per-team + records-per-`(project,team_id)` caps. [Risk 5a/5c]
8. BEAT WRITE BINDING (MEDIUM) → beat partition `(project, team_id, verified-haid)`; `team_id` accepted only on stored membership; record key stays the verified haid. [Risk 1d]
9. PII IN FILE PATHS (LOW, advisory) → relativize file paths (strip `$HOME`/repo-root) before they enter a record; document handle/haid exposure to members. [Risk 4]
10. KEEP: replay-nonce, owner=False enroll, registry cap, boundary 404 allowlist, no-dispatch SA — all unchanged. [Risk 6/7]

## Read-auth ruling (the one decision the implementation hangs on)

Authorize the roster read by EITHER (a) a signed member request whose verified `haid` has a server-side `(haid, team_id)` membership recorded at enroll, OR (b) presenting the `team_secret` in a HEADER, hashed server-side to `team_id`. NEVER by a presented `team_id` (a hash is not a secret), and NEVER via a query parameter. The secret is stored only as its hash and never logged. This makes Risk-1 test 5 (present-the-hash → 403) and test 6 (present-other-team-secret → only that team) the falsifiable isolation guarantees.
