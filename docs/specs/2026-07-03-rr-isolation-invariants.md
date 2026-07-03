# `rr`-over-Control-Plane — ISOLATION INVARIANT LEDGER + Cross-Tenant Coverage Matrix

**The security keystone. Written BEFORE the code. Every isolation gate below has a NAMED invariant and a TEST OBLIGATION.**

- Date: 2026-07-03 · Author: hmd-architect · Repo: `/Users/rj/Downloads/heimdall`
- Design basis: `docs/analysis/2026-07-03-public-rr-control-plane.md`; threat model `docs/specs/2026-06-27-multi-tenant-teams-threatmodel.md`
- Status: CONTRACT. The W1/W2 substrate, the W2 spine gates, and the W5 cross-tenant-denial oracle all cite THIS ledger. A gate with no invariant here is unspecified; an invariant with no RED-line test is unenforced.
- Model: `team_id` partitioning end-to-end. **One tenant must never touch another's repo, cred, queue, job, or GH install.** The partition key is `team_id = sha256(b"heimdall-team\x00" + team_secret)[:32]` (`cp_auth.derive_team_id`, cp_auth.py:482-492). The secret is the ONLY entropy; the id is a non-secret handle at rest (Firestore doc ids, store paths, SA-visible state).

Legend for each invariant: **EXISTS** = enforced in shipped `cp_*` code today (cite file:line); **NEW** = must be built (names the W1/W2 owner). The three NEW security-critical pieces are the repo↔team authz gate, the team-keyed queue, and per-team cred/installation resolution (design §5, §7).

---

## 1. THE INVARIANTS

### INV-1 — `team_id` is ALWAYS server-derived from the caller's verified binding, NEVER a request field
The partition key for any tenant-scoped operation is resolved server-side from the verified `haid`'s registry binding via `cp_auth.registered_team(haid)` (cp_auth.py:552-561), which reads the `team_id` stamped on the binding at enroll (`register_key`, cp_auth.py:511-530). A request body/param/header MUST NOT be able to set the operative `team_id`. The only place a raw `team_secret` is accepted is `POST /enroll`, where it is hashed and discarded inside `enroll()` (cp_enroll.py:298, `_resolve_team_id` cp_enroll.py:201-218) — never stored, never echoed. **EXISTS** for presence/enroll; the dispatch path (`dispatch_maintainer_cycle`) MUST adopt the identical rule (**NEW**, W2): derive `team_id = registered_team(identity.haid)`, never trust a body field.
- Testable: a signed dispatch whose body carries `"team_id": <other>` is IGNORED — the operative team is `registered_team(haid)`. Grep obligation: `grep -n "registered_team" bin/lib/cp_maintainer_runner.py` returns the gate call; `grep -n "params.*team_id\|body.*team_id\|clean.get(.team_id" bin/lib/cp_maintainer_runner.py` returns NOTHING (team_id is never read from validated params).

### INV-2 — every cred / GH-install / queue-entry / job access is KEYED by the caller's `team_id`; no API path reads or writes another team's partition
Each tenant-scoped store is addressed by `team_id`, and every read/write derives that key from INV-1 (the verified binding), never from the request:
- Model cred: Secret Manager secret named per `team_id` (`cp_team_creds`, **NEW** W1). The job injects ONLY its own team's cred.
- GH install map: `team_id → {installation_id, repo_slug}` on the StateBackend (`cp_ghinstall`, **NEW** W1).
- Task queue: keyed `(team_id, repo)` (`cp_rrqueue`, **NEW** W1 — today `issue_queue` is a repo-keyed local JSON file, NOT tenant-partitioned).
- Job rows: `create_job(..., instance_haid=actor)` already stamps the actor (cp_maintainer_runner.py:424); job STATUS/RESULT reads MUST be authorized to the owning team (**NEW** W2).
- Testable: a read/write helper in each store takes `team_id` as a REQUIRED positional and has no cross-team enumeration path. Grep: `grep -n "def .*(.*team_id" bin/lib/cp_team_creds.py bin/lib/cp_ghinstall.py bin/lib/cp_rrqueue.py` shows team_id on every public accessor.

### INV-3 — FAIL-CLOSED: missing / unresolved / mismatched `team_id` → DENY (never a default-open, never an unpartitioned write)
An operation whose `team_id` cannot be resolved from the verified binding, or whose requested resource (repo) is not owned by that `team_id`, is REFUSED before any side effect. Enroll already models this: no team_secret + no configured default → `team_required` (cp_enroll.py:216-218). The dispatch path MUST refuse identically (**NEW** W2): a `haid` whose binding has no team_id AND no default → deny; a repo not in the team's install map → `403 refused + audit`, before `create_job` runs.
- Testable: injecting a null/absent team resolution yields a refusal status (403/422), NOT a 200 and NOT a job row. The gate runs BEFORE `cp_jobstore.create_job` (cp_maintainer_runner.py:424 — the gate must be inserted between line 416 and line 424).

### INV-4 — secrets are NEVER logged / echoed / in argv / in a response body; they enter ONLY the isolated per-job child env
The Claude token (`CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY`), the GH App private key, and the minted installation token travel by ENV into the maintainer child ONLY. `select_maintainer_auth` returns the one selected var to be injected, never logged (cp_handlers.py:264-275); `run_maintainer_cycle` surfaces only the auth var NAME, never its value (cp_handlers.py:333, 372-373); the argv is token-free by construction (`build_maintainer_argv`, cp_handlers.py:295-304). `IsolatedContext.scrubbed_env()` drops every secret-bearing var to the `ISOLATED_ENV_ALLOW` allowlist (cp_handlers.py:61-66, 112-123); `resolve_path` refuses the PKI key dir + audit log (`_CONTROL_PLANE_DENY`, cp_handlers.py:71-76, 139-152). **EXISTS** — the per-team cred SELECTION becomes team-keyed (**NEW** W1/W2), but the never-log discipline is reused verbatim.
- Testable: `grep -rn "OAUTH_TOKEN\|ANTHROPIC_API_KEY\|APP_PRIVATE\|installation.*token" bin/lib/cp_*.py` shows the value only in env-assignment / selection, never in a `_log`/`cp_audit.write`/`json`/return-body position. The per-team cred store returns write-only from the client (never a read-back route).

### INV-5 — task text is scrubbed, bounded DATA enqueued by the public surface; the prompt is BUILT SERVER-SIDE, never a free-form allowlist param
No free-string param type exists in the allowlist by construction: every `Str` carries a mandatory `maxlen ≤ 256` AND a whitelist `pattern` excluding shell metachars/whitespace (cp_allowlist.py:70-96); there is no `FreeStr`/`Raw`/`Cmd` type. `run-maintainer-cycle` accepts only `repo` (slug), `max` (1..100), `budget_tokens?` (bounded int) (cp_allowlist.py:274-283), and `validate_params` REFUSES any extra key (cp_allowlist.py:213-219). The task string therefore travels as bounded, `telemetry._scrub`-cleaned DATA via `POST /rr-task` into the team-scoped queue (**NEW** W1/W2, design §3.2 Route A), and the maintainer prompt is assembled INSIDE `heimdall-maintain-loop` from the queued row — never from a wire param (cp_handlers.py:216-222, the fixed-argv contract).
- Testable: a dispatch carrying `{"repo":...,"prompt":"..."}` or `{"cmd":...}` is REFUSED on the extra key (`extra_param`, 422) — `grep -n "FreeStr\|Raw\|Cmd\|shell\|exec" bin/lib/cp_allowlist.py` returns only the NEGATIVE comments proving absence. The queue row body passes a scrub before persistence.

### INV-6 — the public surface holds NO dispatch capability and NO credential; it is ENQUEUE-ONLY
The public surface (`HEIMDALL_PUBLIC_SURFACE=1`) serves only `PUBLIC_ROUTES` and flat-404s every other route at the routing layer, before auth (cp_publicsurface.py:84-93, 204-208). It carries a throwaway PKI seed + the enroll token, never a model cred or the App key (design §3.1). Adding `POST /rr-task` and `POST /dispatch` to `PUBLIC_ROUTES` (**NEW** W2) MUST keep them SIGNED + ENQUEUE-ONLY: the public handler writes a durable team-scoped job/queue row and STOPS (no handler execution, no cred read). Execution happens on the gated worker / Cloud Run Job, which holds the per-team creds. A public-surface compromise then leaks only the ability to write rate-limited, team-scoped, budget-capped rows — never a credential, never arbitrary exec.
- Testable: on the public surface the `POST /dispatch` code path reaches `create_job` and returns, and NEVER calls `select_maintainer_auth` / `chosen.dispatch`. `grep -n "select_maintainer_auth\|\.dispatch(" bin/lib/cp_publicsurface.py` returns NOTHING. The gated-vs-public route parity check (`check-public-surface.sh`) still passes.

### INV-7 — per-team budget cap bounds runaway spend
Model spend is bounded twice: BYO-credential means the tenant pays their own tokens (design §1a), and the per-cycle `maintain_loop.budget_tokens` cap (default 600k, `--budget-tokens`) stops the loop over cap. `max` cycles is bounded `1..100` by the allowlist Int (cp_allowlist.py:279). A conservative per-team default budget is set server-side; only the team owner may raise it. Per-team dispatch rate is capped by reusing `cp_ratelimit` fixed-window buckets keyed on the hashed `team_id` (mirroring `check_enroll`'s per-team bucket, cp_publicsurface.py:342-374) (**NEW** W2 for the `/dispatch` + `/rr-task` scopes).
- Testable: `budget_tokens` is clamped to the allowlist Int range; a `/dispatch` flood from one team_id trips a 429 (`check_dispatch`, **NEW**). Grep: `grep -n "check_dispatch\|check_rr_task" bin/lib/cp_publicsurface.py` returns the per-team gate.

### INV-8 — replay / forgery resistance: every dispatch is Ed25519-signed over the canonical message, with a freshness/first-use nonce
`verify_identity` verifies the Ed25519 signature over `canonical_message(method, FULL-path-with-query, body)` against the caller's registered pubkey (cp_auth.py:667-714); unsigned/forged/unknown/revoked → `AuthError` → 401 + audit. The signed path includes the query string, so a post-signature tamper fails verification (cp_auth.py:667-687). A signed WRITE (dispatch / rr-task) MUST carry the same `{nonce, ts}` replay gate the beat uses (`cp_nonce.accept`, cp_publicsurface.py:411-420) so a captured request cannot be replayed (**NEW** W2 for the two write routes; reuse `check_presence_post_auth`'s nonce discipline verbatim).
- Testable: a replayed signed dispatch (same nonce) → 401; a body-tampered dispatch (signature over the original body) → 401 `bad_signature`.

### INV-9 — `team_id` is INERT; the wire never accepts `team_id` (the hash) as an auth credential
Authorization is EITHER a signed member request whose verified `haid` has a stored `(haid, team_id)` binding (`team_id` is a selector, useless without the binding) OR presenting the raw `team_secret` in the `X-Heimdall-Team-Secret` HEADER (hashed server-side). Presenting `team_id` ITSELF hashes to `sha256(team_id) ≠ team_id` → wrong partition → empty/403 (threat model Risk 3, tests 5-6). A `team_id` leaked from a log / Firestore export / SA-visible path is NOT a read capability.
- Testable: a browser read presenting `team_id_A` AS the secret → 403/empty (threat model §Risk-1 test 5). This is the single check that proves the hash is not a bearer token.

### INV-10 — self-enroll NEVER grants owner; a leaked team_secret is non-escalating
`enroll()` re-asserts `owner=False` unconditionally on every register (cp_enroll.py:333-337); `verify_identity` returns `owner=is_owner(haid)` (cp_auth.py:714) and no public path can set it. A leaked `team_secret`'s blast radius is "join + operate within that ONE team", bounded by the per-team member cap (`team_full`, 100, cp_enroll.py:326-327), the 409 `haid_pubkey_conflict` refusal (a leaked secret cannot hijack an enrolled HAID, cp_enroll.py:304-308), and per-team rate limits. Rotation = re-enroll under a new secret → new team_id.
- Testable: `grep -n "owner=True\|owner=1" bin/lib/cp_enroll.py` returns NOTHING; the enroll success body is only `{ok, haid, team_id}` (cp_enroll.py:432-434).

### INV-11 — the repo↔team AUTHORIZATION gate (THE KEYSTONE, entirely NEW): a caller may dispatch ONLY against a repo its `team_id` owns
Before params validation succeeds into a job, the server asserts the requested `params.repo` is bound to the caller's `team_id` in the GH-install map (`cp_ghinstall.team_owns_repo(team_id, repo)`, **NEW** W1/W2). A caller naming another team's repo → `403 refused + audit`, before any job exists. **This gate does not exist today** — `dispatch_maintainer_cycle` accepts ANY repo slug from ANY enrolled identity (cp_maintainer_runner.py:416-425: `repo = clean.get("repo")` flows straight into `create_job` with no team check). Without INV-11, tenant A targets tenant B's repo and the App opens a PR on B's repo using B's install. This is the multi-tenant isolation keystone.
- Testable: A's signed dispatch naming B's repo → 403 + audit, no job row; A naming A's own repo → accepted. The gate is a hard `return` before `create_job` (cp_maintainer_runner.py, inserted at line ~417).

---

## 2. CROSS-TENANT COVERAGE MATRIX

Every cross-tenant ATTACK × the GATE that stops it × WHERE the gate lives × the TEST that proves it. `E` = gate EXISTS today; `N` = gate is NEW (W1/W2 must build it).

| # | Cross-tenant attack | Gate (invariant) | Where it lives (file:line) | E/N | Proving test |
|---|---|---|---|---|---|
| A1 | **IDOR via repo slug** — team A dispatches `run-maintainer-cycle` naming team B's repo | repo↔team authz gate (INV-11) + server-derived team_id (INV-1) | `cp_ghinstall.team_owns_repo` (NEW) called in `cp_maintainer_runner.dispatch_maintainer_cycle` before `create_job` (cp_maintainer_runner.py:~417) | N | A-signed dispatch of B's repo → 403 + audit, no job; drop the gate → accepted → oracle RED |
| A2 | **Cred read across teams** — team A's job selects team B's Claude token | per-team cred key (INV-2) + env-only never-logged injection (INV-4) | `cp_team_creds` lookup keyed by `registered_team(haid)` (NEW W1); injected via `select_maintainer_auth`+`scrubbed_env` (cp_handlers.py:264-275, 329-332) | N (key) / E (injection) | A's job env contains A's cred only; assert B's secret name never resolved for A's team_id |
| A3 | **Queue read/drain across teams** — team A reads or drains team B's task rows | `(team_id, repo)`-keyed queue (INV-2) + server-derived team_id (INV-1) | `cp_rrqueue` accessors take team_id positional (NEW W1); caller passes `registered_team(haid)` | N | A's queue read for B's team_id → empty/403; A cannot enumerate B's rows |
| A4 | **Job status/result read across teams** — team A polls team B's job_id | per-team job authz (INV-2/INV-3) | job read route authorizes `job.instance_haid`'s team == caller's team (cp_jobstore + gated read route, NEW W2); jobs stamp actor at `create_job` (cp_maintainer_runner.py:424) | N | A reading B's job_id → 403/404 (indistinguishable), never B's result body |
| A5 | **GitHub installation_id swap** — team A supplies/uses team B's installation to PR on B's repo | server-side install resolution (INV-1/INV-2) — installation_id resolved from `team_id`, NEVER from the request | `cp_ghinstall` maps `team_id → installation_id`; `cp_maintainer_runner` sets `HEIMDALL_GH_APP_INSTALLATION_ID` from the team's map, not a param (NEW W1/W2); `heimdall-gh-app-token` scopes to that install + repo (heimdall-gh-app-token.py:137) | N | installation_id is never an allowlist param (`grep -n installation_id cp_allowlist.py` → NOTHING); A's job mints only A's install token |
| A6 | **Forged / replayed enroll signature** — attacker enrolls into or acts as another team without the secret | Ed25519 sig verify (INV-8) + team_secret hashed at enroll (INV-1) + 409 rebind refusal (INV-10) | `cp_auth.verify_identity` (cp_auth.py:692-714); `enroll` conflict guard (cp_enroll.py:304-308) | E | forged sig → 401; wrong/absent secret → wrong team_id; re-bind of an enrolled haid → 409 |
| A7 | **Replayed dispatch** — capture team A's signed dispatch, resend it | replay-nonce freshness/first-use (INV-8) | `cp_nonce.accept` in a `check_dispatch_post_auth` mirroring cp_publicsurface.py:411-420 (NEW W2) | N | replayed signed dispatch (same nonce) → 401; drop the nonce gate → replay accepted → oracle RED |
| A8 | **Task-text injection reaching the server prompt** — smuggle a prompt/command as a dispatch param | no-free-string allowlist (INV-5) + extra-key refusal | `cp_allowlist.Str`/`validate_params` (cp_allowlist.py:70-96, 213-229); prompt built in-loop (cp_handlers.py:216-222) | E | `{...,"prompt":"..."}`/`{...,"cmd":"..."}` → 422 `extra_param`; a shell payload in `repo` → 422 `bad_param` (fails REPO_SLUG_RE) |
| A9 | **Budget-cap bypass** — one team burns unbounded spend / floods dispatch | per-team budget + bounded `max` + per-team rate cap (INV-7) | `maintain_loop.budget_tokens`; allowlist `Int(1..100)` (cp_allowlist.py:279); `check_dispatch` per-team bucket (NEW W2, pattern cp_publicsurface.py:342-374) | E (budget/max) / N (rate) | out-of-range `max`/`budget` → 422; `/dispatch` flood per team_id → 429 |
| A10 | **Compromised public surface tries to dispatch or read a cred** — the internet-facing service is popped | intake/execution split — enqueue-only, no cred, no handler (INV-6) | `PUBLIC_ROUTES` + flat-404 boundary (cp_publicsurface.py:84-93, 204-208); public `/dispatch` handler stops at `create_job` (NEW W2) | E (boundary) / N (enqueue-only route) | public `/dispatch` never calls `select_maintainer_auth`/`chosen.dispatch`; the PKI key + model cred live only on the gated side |
| A11 | **Malicious repo (issue title) injects into the worker** — a crafted GitHub issue title/body carries a prompt-injection payload | prompt built server-side from scrubbed queued DATA (INV-5) + isolated low-priv job env (INV-4) + App-never-merges | `heimdall-maintain-loop` issue_loop prompt build (cp_handlers.py:216-222); `IsolatedContext` scrub/deny (cp_handlers.py:61-76, 112-152); App scoped Contents+PR, no main/merge (design §2) | E | the worker treats issue text as DATA, opens a PR on `heimdall/*` only; a human gates merge — no auto-merge, no main push |
| A12 | **`team_id` replayed as a read credential** — a leaked team_id (from a log / Firestore id) used as auth | team_id inert (INV-9) — auth is signed-member or raw-secret-in-header only | threat model Risk 3; `derive_team_id` one-way (cp_auth.py:482-492); read authz never accepts a presented team_id | E | present team_id AS the secret → 403/empty (Risk-1 test 5) |
| A13 | **Cross-team roster read** — team A reads team B's presence roster (adjacent surface, must not regress) | membership-scoped roster read (threat model Risk 1) | `/roster-team` X-Heimdall-Team-Secret header → team_id (cp_publicsurface.py:74-83); signed `/roster` scoped to `registered_team(haid)` | E | A's roster read for B → empty/403 (threat model Risk-1 tests 1-4,7) |
| A14 | **Unpartitioned write via missing team** — a haid with no team_id writes an unscoped row | fail-closed team resolution (INV-3) | `_resolve_team_id` `team_required` (cp_enroll.py:201-218); dispatch mirrors it (NEW W2) | E (enroll) / N (dispatch) | no team + no default → 422/403, never a 200 + row |

---

## 3. RED-LINE TEST OBLIGATIONS (the falsifiable checks — what W5's oracle implements)

For each invariant: the mutant to inject → the cross-tenant attack that then succeeds → the oracle goes RED. The W5 oracle (`test/rr-multitenant-isolation.test.sh`, authored by a SEPARATE agent in a SEPARATE wave, disjoint file scope — `independent: true`) drives two enrolled identities in DIFFERENT teams (A, B) through a FIXED deterministic sequence and asserts the WHOLE outcome sequence. Golden build → all GREEN; every mutant below → the named assertion flips RED. Falsifiability score MUST be 1.0 (golden passes AND every mutant is caught).

| Invariant | Mutant injected (drop/weaken the gate) | Cross-tenant attack that then succeeds | Oracle assertion that goes RED |
|---|---|---|---|
| INV-11 (keystone) | remove the `team_owns_repo` check in `dispatch_maintainer_cycle` | A dispatches against B's repo → PR on B's repo | A→B-repo dispatch returns 200 + job created (must be 403 + no job) |
| INV-1 | make dispatch read `team_id` from the body instead of `registered_team(haid)` | A sets `"team_id": B` → operates as B | body-supplied team_id changes the partition (must be ignored) |
| INV-2 (cred) | resolve the model cred from a global secret, not per-team | A's job runs on B's cred | A's job auth resolves B's secret name |
| INV-2 (queue) | make the queue repo-keyed only (drop team_id) | A drains B's task rows for the same repo name | A's queue read returns B's rows |
| INV-3 | default-open when team_id unresolved | a no-team haid writes an unpartitioned job | unresolved team → 200 + row (must be deny) |
| INV-4 | log/echo the selected auth var value | cred leaks to audit/logs/response | the token value appears in a log/audit/body field |
| INV-5 | add a `FreeStr`/`prompt` param to `run-maintainer-cycle` | A injects a server-side prompt/command | `{...,"prompt":...}` accepted (must be 422 extra_param) |
| INV-6 | let the public `/dispatch` handler execute (call the runner) | public-surface compromise reads a cred / dispatches | public `/dispatch` calls `select_maintainer_auth`/`.dispatch` |
| INV-7 | remove the per-team dispatch rate cap / unclamp `max` | one team floods dispatch / unbounded cycles | flood not 429'd, or `max` > 100 accepted |
| INV-8 | drop the replay-nonce on the write routes | replay A's captured signed dispatch | replayed dispatch (same nonce) returns 200 |
| INV-9 | authorize a read on a presented `team_id` | leaked team_id replayed as a read cred | team_id-as-secret read returns B's data (must be 403/empty) |
| INV-10 | let enroll set `owner=True` | leaked team_secret mints an owner | enroll body/binding shows owner=True |
| A5 (install) | resolve installation_id from a request param | A uses B's installation to PR on B's repo | installation_id honored from the wire |

Gate-type: this is a **differential-style cross-tenant DENIAL oracle** (the strongest available — no registry oracle matches this domain; `evals/oracles/registry.json` covers only `emulator-gb`/`exchange-lob`/`raytracer-calib`, confirmed via `jq -r '.oracles|keys[]'`). It asserts the WHOLE cross-tenant sequence is denied, NOT per-request properties alone (property gates are insufficient for a stateful multi-tenant target). A reviewer may add an `isolation` row to the registry later; until then the W5 oracle is the authored-independent gate. **Verify (final wave):** `bash test/rr-multitenant-isolation.test.sh` exits 0 (golden green + all mutants rejected).

---

## 4. INVARIANT / ATTACK → W1/W2 COMPONENT MAP

Each invariant and attack maps to the component that MUST enforce it. `EXISTS` components are reused verbatim (no edit); `NEW` components are the build.

| Component | Wave | Status | Enforces (invariants / matrix rows) | Contract it MUST honor |
|---|---|---|---|---|
| `cp_team_creds.py` (per-team model-cred store over Secret Manager) | W1 | NEW | INV-2 (cred), INV-4; A2 | Keyed by `team_id`; write-only from client (no read-back route); returns the one selected var for env-only injection; never logs the value |
| `cp_ghinstall.py` (`team_id → {installation_id, repo}` map over StateBackend) | W1 | NEW | INV-2, INV-11; A1, A5 | `team_owns_repo(team_id, repo)` exact-match authz; `installation_id` resolved from team_id, NEVER a param; not a secret (Firestore-durable) |
| `cp_rrqueue.py` (team-keyed task/queue store) | W1 | NEW | INV-2, INV-5; A3 | `(team_id, repo)` key on every accessor; body scrubbed (`telemetry._scrub`) + length-bounded before persist; no cross-team enumeration |
| repo↔team authz gate in `cp_maintainer_runner.dispatch_maintainer_cycle` | W2 | NEW | INV-11, INV-1, INV-3; A1, A14 | Derive `team_id = registered_team(identity.haid)`; assert `team_owns_repo`; 403 + audit BEFORE `create_job` (insert at cp_maintainer_runner.py:~417) |
| per-team `base_env` assembly in `cp_maintainer_runner` | W2 | NEW | INV-2, INV-4; A2, A5 | Assemble base_env per team: that team's model cred (cp_team_creds) + that team's App install token (cp_ghinstall→heimdall-gh-app-token); env-only, never logged |
| enqueue-only public routes in `cp_publicsurface` (`POST /rr-task`, `POST /dispatch`) | W2 | NEW | INV-6, INV-7, INV-8; A7, A9, A10 | Add to `PUBLIC_ROUTES` signed-only; handler writes team-scoped row and STOPS (no cred, no runner); `check_dispatch`/`check_rr_task` per-team+per-IP rate + nonce gates (reuse cp_ratelimit/cp_nonce) |
| `cp_allowlist` (frozen registry) + `cp_handlers` (fixed-argv, cred selection) | EXISTS | E | INV-4, INV-5; A8, A11 | Reused verbatim; per-team cred SELECTION swaps in via `select_maintainer_auth`(team's source_env); NO free-string type added |
| `cp_auth` (derive_team_id, registered_team, verify_identity) | EXISTS | E | INV-1, INV-8, INV-9; A6, A12 | Reused verbatim; the single source of `team_id` (server-derived) and signature verification |
| `cp_enroll` (owner=False, team gate, 409, caps) | EXISTS | E | INV-3, INV-10; A6, A14 | Reused verbatim; fail-closed team resolution + non-escalating enroll |
| `test/rr-multitenant-isolation.test.sh` (cross-tenant denial oracle) | W5 | NEW (independent agent) | ALL (§3 RED-lines) | Two-team fixed sequence, whole-sequence denial assertion, golden + per-invariant mutants, falsifiability 1.0 |

---

## OUT OF SCOPE

- **Metered/service-billed credentials** — BYO only (design §1a); metering deferred until billing + ZDR/DPA exist.
- **Automatic `/gh-install-callback` route** — MVP binds installation_id by paste; the callback (with a state-nonce browser round-trip) is a later cycle.
- **Multi-repo per team, multi-region** — MVP is one repo per team, single region; the repo↔team gate is exact-match against one bound repo.
- **Any change to the bounded-allowlist spine, PKI signing, `IsolatedContext`, or the enroll/presence threat-model controls** — reused verbatim, cited here, not redesigned.
- **RJ's single-user `--mode vm`** — unchanged fallback; not tenant-partitioned, out of this ledger's scope.
- **GCP project/billing provisioning + creating the public GitHub App** — human deployment decisions (design §6), not code gates.
- **PII in file paths / handle-haid correlation within a trusted team** — advisory (threat model Risk 4), not an isolation gate; documented, not enforced here.
- **The implementation of the W1/W2/W5 components** — this ledger is the CONTRACT they cite; the substrate/gate/oracle agents build against it.
</content>
</invoke>
