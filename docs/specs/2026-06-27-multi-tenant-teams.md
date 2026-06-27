# Multi-Tenant Team Presence — Design Spec

**Date:** 2026-06-27
**Status:** DESIGN (no code written). Hand to implementer + parallel security threat-model.
**Author requirement (RJ, verbatim):** "a new token generated for every new team per repo —
then a token for just that team visible, i.e. only those teammates can see each other's HAID
and activity such as being online, edits etc."

So: a **team = a self-generated token scoped to a repo**; presence (HAID + online + current
file/edits) is visible **ONLY** to holders of that team token; cross-team and outsiders see
**NOTHING**.

---

## 0. The one-line idea (the mechanism the whole design rests on)

A **team secret** is a high-entropy bearer capability. Its **non-secret handle** is
`team_id = derive(team_secret)` (a one-way hash). All presence is **partitioned by team_id**;
the registry binds each member's HAID to their team_id. To read a team's roster you must
**possess the capability to address its partition** — either by presenting the secret (server
derives team_id) or by being an enrolled member (server reads team_id from your binding).

Because team_id is a **preimage-resistant hash**, knowing team_id (it appears in storage keys)
never yields the secret. Because presence is **keyed by team_id, not by anything in the request
body**, a member can only ever read/write *their own* team. That is the isolation guarantee,
and it is enforced by addressing, not by an ACL check that could be forgotten.

There is **no secret comparison anywhere on the server** — the secret is consumed once to
*compute a key*, never matched against a stored value. No stored secret ⇒ no leak from a server
compromise; no compare ⇒ no timing oracle.

---

## 1. Team model & `team_id` derivation

- **team = (project, team_secret).** `project` is the existing normalized-git-remote id
  (`bin/heimdall-presence:normalize_remote` — host+path, scheme/user/port stripped, `.git`
  dropped, lowercased; all clones of one remote collapse to one id). A repo can host ≥1 team
  (each distinct secret = a distinct team); the common case is **one token per repo**.

- **team_secret:** 32 random bytes → base64url, 43 chars (no padding) — byte-identical to
  `secrets.token_urlsafe(32)` and to what `heimdall-site/team.html` already mints client-side
  (`crypto.getRandomValues(32) → base64url`). 256 bits of entropy ⇒ unguessable, no salt needed
  (see §Security ruling). **Minimum accepted length: 32 chars** (reject shorter as
  `team_secret_weak` so a hand-typed weak secret can't collide into another team).

- **team_id derivation (the contract — client and server MUST agree byte-for-byte):**
  ```
  team_id = sha256(b"heimdall-team\x00" + team_secret.encode("utf-8")).hexdigest()[:32]
  ```
  - **Domain-separation prefix** `heimdall-team\0` so this hash can never alias another
    sha256(secret) use elsewhere in the system.
  - **Truncate to 32 hex (128 bits):** matches the codebase's existing `_HASH_HEX = 32`
    (cp_ratelimit/cp_nonce); 128-bit preimage resistance is infeasible to attack; collision
    among teams is a 2^64 birthday bound (irrelevant). 32 hex is **filesystem- and
    Firestore-safe** as a path segment (no `_`, so never the `__` run FirestoreBackend
    reserves).

- **Why no raw storage:** the server stores *only* `team_id` (in the registry binding and as a
  presence path segment). The raw `team_secret` is **never at rest server-side** — it arrives,
  is hashed to team_id, and is discarded. A server/DB compromise leaks team_ids (partition
  handles) but **never** team_secrets. This is the password-store discipline, except the
  "verifier" doubles as the partition key so there is nothing to compare.

---

## 2. Token generation — self-serve, no operator

No RJ/operator involvement; **first-enroll-creates-team** (no pre-registration).

- **Web (`team.html`):** already mints the 43-char token client-side and never transmits it
  from the page. Re-label it **"your team secret"** (today the copy calls it
  `HEIMDALL_ENROLL_TOKEN`/single-tenant — see §Migration). The page additionally uses it to
  **read** the team roster (§5).
- **CLI (new `heimdall-team`):**
  - `heimdall-team new` — mint a team_secret (`python3 -c secrets.token_urlsafe(32)`, or
    `cp_auth`-adjacent), write `<repo>/.heimdall/team.json` (0600), print the secret + the
    `heimdall-invite` join one-liner. Refuse to clobber an existing `team.json` without
    `--force`.
  - `heimdall-team join <secret>` — write `<repo>/.heimdall/team.json` with a teammate's secret
    (join their team).
  - `heimdall-team show` — print the **non-secret** team_id + whether configured (never prints
    the secret).
- **First use auto-creates the team server-side:** the first `/enroll` carrying a given
  team_secret implicitly *is* the team's creation — `team_id` simply starts appearing in the
  registry. No "create team" endpoint.

**Deprecates the global `HEIMDALL_ENROLL_TOKEN`:** the team_secret now both **authorizes**
enroll and **scopes** the team. (A configured global default-team secret is retained only for
back-compat — §8.)

> **Security note (hand to threat-model):** first-enroll-creates-team means enroll is
> *effectively open* — anyone can mint a secret and create a throwaway team. This is the
> intended self-serve model; abuse is bounded by the per-team + global registry caps and the
> rate limits (§3). It does **not** weaken isolation: a self-minted team contains only its
> creator.

---

## 3. Enroll (multi-tenant)

`POST /enroll` — body `{haid, pubkey, handle, project, team_secret}`; `team_secret` may instead
ride the `X-Heimdall-Team-Secret` header (the header path keeps it out of any body log).

Server flow (extends `bin/lib/cp_enroll.py:enroll`):
1. **Validate team_secret** present + ≥ MIN length → else `team_secret_weak` (422). (In the
   default-team back-compat mode an absent secret maps to the default team — §8.)
2. Compute `team_id = derive(team_secret)`. **Discard the raw secret.**
3. Validate `haid` / `pubkey` (32-byte Ed25519) as today.
4. **Anti-rebind / team-switch (the 409 rule, refined):**
   - existing binding, **same pubkey** → OK; **update team_id** to the new one (a key holder may
     move their *own* HAID between teams — they hold the private key, so this is not a hijack).
   - existing binding, **different pubkey** → `haid_pubkey_conflict` (409). A stolen secret can
     **never** move someone else's enrolled HAID into the attacker's team.
5. **Caps (bound registry growth):**
   - **per-team cap** — refuse a net-new HAID once the team already holds `TEAM_MAX_MEMBERS`
     (e.g. 100) bindings → `team_full` (429). Bounds how much one (possibly leaked) secret can
     bloat the registry.
   - **global cap** — the existing `HEIMDALL_ENROLL_MAX_KEYS` (default 1000) still applies →
     `enroll_registry_full` (429).
6. Bind `haid → {pubkey, owner:false, team_id, project}` via `cp_auth.register_key`
   (schema gains `team_id`, `project`).

Rate limits (`cp_publicsurface.check_enroll`, unchanged mechanics): per-IP, **per-team_id**
(re-key the existing per-token bucket on `team_id` — the hash is already what's stored), and the
deployment-wide `enroll_budget`.

---

## 4. Presence (team-scoped)

`POST /presence` (signed; unchanged wire body `{project, handle, verdict, file, nonce, ts}`).

Server (extends `cp_presence.beat_route` / `record_presence`):
- `haid` = the **verified** identity (as today).
- `team_id` = **looked up from the registry binding** (`cp_auth.registered_team(haid)`),
  **NEVER** from the beat body. ⇒ a member can only beat into **their** team.
- Store key becomes **`(project, team_id, haid)`**:
  ```
  presence/<project_slug>/<team_id>/<haid_slug>.json
  ```
  (`team_id` is 32-hex — safe path segment on local + Firestore.)
- A HAID with no team binding → the **default team_id** (§8 back-compat).

`project` stays a body field (the dev's active repo, scrubbed) — it coincides with the binding's
project because HAID is per-checkout; `team_id` is the load-bearing isolation key.

> **Implementer check:** `roster()` enumeration moves from a 2-level prefix
> (`presence/<project>/`) to a 3-level prefix (`presence/<project>/<team_id>/`). Confirm
> `FirestoreBackend.list_names` enumerates an arbitrary-depth prefix (the local backend does).

---

## 5. Roster read — team-private (THE visibility rule)

Returns the **full** view `{haid, handle, verdict, file, online, age_seconds}` for
`(project, team_id)` **only** to a caller who proves membership. Two auth paths, by client:

### (b) Signed member — the CLI path (primary; no secret on the wire)
`GET /roster?project=P` (signed, empty body — the existing GFE-safe shape). The server derives
`team_id` from the **caller's registry binding** and returns `roster(project, team_id)`. The
secret was consumed once at enroll; thereafter the **signature is the proof** and the secret is
never re-sent. **This replaces today's behavior where any signed member saw any project's full
roster** (cross-team leak) — now it is scoped to the caller's own team_id.

### (a) Presented secret — the browser path (browser can't PKI-sign)
`GET /roster-team?project=P` with header **`X-Heimdall-Team-Secret: <secret>`** and an **empty
body**. Server derives `team_id` from the header and returns `roster(project, team_id)` — the
full view **including haid** (members are entitled to see each other's HAID per the requirement).
+ `OPTIONS /roster-team` CORS preflight advertising `Access-Control-Allow-Headers:
X-Heimdall-Team-Secret`.

**Read-auth decision — header, not query, not body. Justification:**
- **Query REJECTED** — a secret in the URL leaks to server/proxy **access logs**, the
  **Referer** header, and **browser history**. This is the classic credential-in-URL leak; the
  codebase already treats query as logged (it moved `job_id` to query *because* query is safe to
  log — exactly why a secret must not go there).
- **GET body REJECTED** — Google's GFE rejects GET-with-a-body (HTTP 400; the documented reason
  `/roster` carries its project in the query). A browser `fetch` GET also cannot send a body.
- **Header CHOSEN** — a custom request header is **not** written to standard access logs, not in
  Referer, not in history, not cached. It triggers a CORS preflight (we already serve an OPTIONS
  preflight for the public read; extend `Access-Control-Allow-Headers`). No cookies/ambient
  credential are used (not `credentials: 'include'`), so `Access-Control-Allow-Origin: *` stays
  safe — `*` lets other origins *send* a request but never *read* the response without the
  user's explicit secret.

**No existence oracle / outsiders see nothing:** the server **always** returns the roster for
the derived team_id, empty when that partition has no online members. A random/unknown secret
derives a partition with no records → `{online: []}`. A nonexistent team and an idle team are
indistinguishable. Other teams' partitions are never enumerated (the read addresses exactly one
`team_id` dir).

### Reconciling the existing `/roster-public` (the migration of the public read)
Today `/roster-public` is **fully public**, handles-only, **haid-scrubbed**. Under the new model
the team roster **exposes haid + activity**, which must **not** be public. Therefore:
- **`/roster-public` is replaced by `/roster-team`** (header-gated, full view incl. haid).
- During migration `/roster-public` returns **`{online: []}`** (or 404) — it no longer leaks a
  public roster. `team.html` is updated to call `/roster-team` with the secret header.
- The `_public_view` projection (which dropped haid) is **superseded** by a `_team_view` that
  includes haid — but only a *proven member* ever receives it.

---

## 6. Client config & commands

**Where the secret lives — per-repo `<repo>/.heimdall/team.json` (NOT the global
`cp-endpoint.json`).** Rationale: a dev may be on **different teams in different repos**, so the
secret is per-repo — it sits next to the existing per-repo `identity.json`
(`bin/heimdall-identity`). The **CP URL stays global** in `~/.heimdall/cp-endpoint.json` (it is
not a secret). Shape:
```json
{ "team_secret": "<base64url-43>", "created": 1719500000 }
```
Mode 0600, **gitignored**.

**`bin/heimdall-presence`:**
- On **enroll/bootstrap**: read `<repo>/.heimdall/team.json:team_secret`, send it in the
  `/enroll` body (or `X-Heimdall-Team-Secret` header) along with `project`. No team configured →
  see open question §9.
- On **roster read**: unchanged wire (signed `GET /roster?project=P`); the server now scopes by
  the member's team. The statusline consumes this exactly as today.

**`bin/heimdall-invite`:** read the team secret from **`<repo>/.heimdall/team.json`** (not the
global `cp-endpoint.json:enroll_token`). The join one-liner distributes the **team secret**:
```
curl -fsSL <install.sh> | HEIMDALL_TEAM_SECRET='<secret>' bash
```
`install.sh` writes it to the joining dev's `<repo>/.heimdall/team.json`. The existing secret-
safety properties hold (stdout only, never argv, ⚠ caveat printed).

**`team.html`:** generates the secret (as today) **and** uses it as the
`X-Heimdall-Team-Secret` header to read `/roster-team`. Hold the secret **in memory only**
(see open question §9 on localStorage). The page now renders **haid + handle + verdict + file +
age** (a member's full view).

**New `bin/heimdall-team`** — `new` / `join <secret>` / `show` (§2).

---

## 7. Isolation guarantee (the falsifiable core)

**Mechanism:** presence is keyed by `team_id` (derived from the secret, never from the request
body); every roster read addresses exactly one `team_id` partition, where that team_id comes
from either the signed member's binding (path b) or the presented secret's hash (path a).
Different secret ⇒ different team_id ⇒ different `presence/<project>/<team_id>/` dir ⇒ a read
for team A never enumerates team B's records. Same secret ⇒ same team_id ⇒ same dir ⇒ mutual
visibility. No secret + not enrolled ⇒ no binding to read and no matching partition to address
⇒ nothing.

**Falsifying test (runnable):**
```sh
# same project P, two DIFFERENT team secrets
SA=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')
SB=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')

enroll  haid=A pubkey=KA project=P team_secret=$SA
enroll  haid=B pubkey=KB project=P team_secret=$SB
beat    as A (project=P);  beat as B (project=P)

# (b) signed-member read: A sees ONLY A, never B
roster_as A project=P | jq -e '[.roster[].haid] | index("B") | not'   # PASS
roster_as A project=P | jq -e '[.roster[].haid] | index("A")'         # PASS

# (a) header read: secret SA returns only A's team; SB only B's
GET /roster-team?project=P  -H "X-Heimdall-Team-Secret: $SA" | jq -e '[.online[].haid]==["A"]'
GET /roster-team?project=P  -H "X-Heimdall-Team-Secret: $SB" | jq -e '[.online[].haid]==["B"]'

# outsider: a random secret sees nothing
GET /roster-team?project=P  -H "X-Heimdall-Team-Secret: $(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')" \
  | jq -e '.online==[]'

# THE LEAK FALSIFIER: A's team roster (either path) containing B's haid ⇒ FAIL
```

---

## 8. Migration / back-compat

**Live deploy today:** single global `HEIMDALL_ENROLL_TOKEN`; presence keyed by `(project,
haid)` with **no** team_id segment.

- **Default team.** A reserved `DEFAULT_TEAM_ID` covers (a) registry bindings with no `team_id`
  field and (b) the existing single-tenant deploy. Set it from the current global token:
  `DEFAULT_TEAM_ID = derive(HEIMDALL_ENROLL_TOKEN)` (or a configured
  `HEIMDALL_DEFAULT_TEAM_SECRET`). The live deployment thus becomes **one team whose secret is
  the old global token** — it keeps working unchanged.
- **Registry: additive, non-destructive.** `team_id`/`project` are new optional fields. A
  binding lacking `team_id` reads as `DEFAULT_TEAM_ID`; the member's next enroll stamps the real
  value. No migration script.
- **Presence: NO migration needed (self-healing in one TTL).** Presence records TTL-expire in
  ~45s (`PRESENCE_TTL_SECONDS`). New beats write `presence/<project>/<team_id>/...`; legacy flat
  records at `presence/<project>/<haid>.json` simply age out within ~45s of a dev upgrading.
  During the grace window the **default-team** roster reader may union the legacy flat path so
  not-yet-upgraded devs stay visible; after one TTL the flat path is empty and the union can be
  dropped. (Ephemeral data ⇒ the migration is "wait 45s after rollout.")
- **Keep the default team** for the existing deploy while multi-tenant rolls out; flip
  `team.html` copy + `heimdall-invite` to per-repo team secrets; retire the global
  `HEIMDALL_ENROLL_TOKEN` once all teams are explicit.

---

## 9. Open questions for RJ

1. **No-team-configured behavior (zero-config tension).** Today presence auto-bootstraps with
   zero config. With per-repo teams, a dev with no `team.json` has no team. Options:
   (a) **explicit** — presence is offline until `hmd team new`/`join` (recommended: keeps
   privacy explicit, the `heimdall-invite` viral loop distributes the secret); (b)
   **auto-solo** — silently mint a per-repo secret on first run (dev sees only themselves until
   they share it); (c) **auto-from-remote** — `team_id = derive(repo_remote)` (**rejected:** the
   remote URL is not secret ⇒ anyone who knows the repo can read the roster — defeats privacy).
   **Recommend (a).** Confirm.
2. **Browser secret persistence** — `team.html` holds the secret in memory only (re-paste each
   visit) vs `localStorage` (convenient, but XSS-exfiltratable, persists on shared machines).
   Recommend memory-only with an opt-in "remember on this device."
3. **Multi-team membership per repo** — is one team per (repo, dev) sufficient, or must a dev be
   in several teams in one repo simultaneously? The design assumes **one active team per
   `team.json`** (switching = `hmd team join`). Multi-team-at-once would need a list + a roster
   picker.
4. **Per-team member cap** value (`TEAM_MAX_MEMBERS`) — 100? Sets the registry-bloat bound per
   secret.

---

## 10. Hand-offs to the security threat-model

- **first-enroll-creates-team ⇒ enroll effectively open** — confirm the per-team + global caps +
  rate limits are a sufficient bound; confirm a leaked secret's blast radius (read the team's
  presence; enroll *into* the team as a new HAID — but cannot hijack an existing HAID per the
  409 rule).
- **team_id = sha256(secret)[:128 bits], unsalted** — confirm 128-bit truncation + 256-bit
  secret entropy is adequate (no rainbow table feasible; no per-team salt needed). Confirm the
  domain-separation prefix.
- **No server-side secret comparison** — the secret only ever computes a partition key (capability
  model). Confirm there is no path where a stored secret/hash is compared (⇒ no timing oracle).
- **`X-Heimdall-Team-Secret` header + `Access-Control-Allow-Origin: *`** — confirm no
  confused-deputy/CSRF (no ambient credential; the secret is explicit, not a cookie). Confirm
  the header is not logged on the target platform (Cloud Run access logs path+query, not request
  headers).
- **No existence oracle** — confirm "always return roster for the derived team_id, empty when
  absent" removes any team-exists side channel (timing of an empty `list_names` vs a populated
  one — confirm constant-ish).
- **Capability/bearer secret** — it is shared deliberately (the viral loop). Confirm rotation
  story: rotating a team = `hmd team new` + re-invite; old team_id's presence ages out in one
  TTL.

---

## 11. API summary (exact request/response)

| Endpoint | Auth | Request | Response |
|---|---|---|---|
| `POST /enroll` | bootstrap (team_secret) | body `{haid, pubkey, handle, project, team_secret}` or `X-Heimdall-Team-Secret` header | `200 {ok:true, haid, team_id}` / `{ok:false, reason}` (`team_secret_weak`422, `haid_pubkey_conflict`409, `team_full`429, `enroll_registry_full`429) |
| `POST /presence` | signed member | body `{project, handle, verdict, file, nonce, ts}` | `200 {recorded:true, haid, project, team_id}` (team_id from binding) |
| `GET /roster?project=P` | signed member | empty body, project in query | `200 {project, team_id, roster:[{haid,handle,verdict,file,online,age_seconds}]}` — caller's team only |
| `GET /roster-team?project=P` | `X-Heimdall-Team-Secret` header | empty body, project in query | `200 {project, online:[{haid,handle,verdict,file,age_seconds}]}` — derived team_id; `[]` if unknown |
| `OPTIONS /roster-team` | — (CORS preflight) | — | `204` + CORS incl. `Access-Control-Allow-Headers: X-Heimdall-Team-Secret` |

**Registry binding schema (`auth/keys.json`):**
`{haid: {pubkey, owner, team_id, project}}` (`team_id`/`project` additive; absent ⇒
DEFAULT_TEAM_ID). New accessor `cp_auth.registered_team(haid) -> team_id`.

**Storage keys:** presence `presence/<project_slug>/<team_id>/<haid_slug>.json`; ratelimit
re-keyed on `team_id`.
</content>
</invoke>
