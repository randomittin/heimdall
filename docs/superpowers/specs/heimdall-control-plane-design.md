# Heimdall Control Plane — Design Dossier

**Status:** contract for build-coders. READ-ONLY design; no code written here.
**Spec (authoritative):** `/Users/rj/Downloads/heimdall-control-plane-spec.md`
**Authored:** 2026-06-24. **Scope:** internal-first (7-8 devs), per-org-isolation seam *architected not built*.

A self-hosted server that **observes, schedules, gates, notifies** across `hmd` instances. The whole design hangs off ONE decision: **the bounded action-allowlist** (§1). Everything else (PKI, job runner, ingest) is plumbing around that blast-radius control.

---

## STEP 0 — Reuse Inventory (confirmed in-repo)

Each piece read directly (not guessed). House style throughout: thin `bin/heimdall-*` bash CLI over `bin/lib/*.py` engine; runtime state gitignored under `${HEIMDALL_HOME:-<repo>/.heimdall}/` via `issue_queue.heimdall_home()`; `.bash` tests at `test/*.test.sh`.

| Piece | What it gives the control plane | Verdict |
|---|---|---|
| `bin/lib/telemetry.py` (`build_event`/`emit`, EVENT_TYPES enum `install_step\|phase\|gate\|token\|outcome\|commit\|issue_state`, `_scrub`/`_SECRET_PATTERNS`/`_ASSIGNED_OPAQUE`, `_SCRUB_MAX=120`) | The OBSERVE event schema + **no-secret-by-construction**. Instances already build these events. The store's secret-discipline comes free if events stay this shape. | **reuse-as-is** (schema + scrub). **needs-adapter** (it is a *local file writer*; ingest needs an HTTP push transport that re-runs `build_event` server-side so a malicious client cannot inject an off-schema line). |
| `bin/heimdall-report` + `bin/lib/report.py` (`run_detail`, `aggregate`: gate-firing frequency, failure patterns by `error.class`×step, token trends w/ cache ratio, **install drop-off** = failed/started per step) | The DASHBOARD read layer. Cross-dev aggregates are already written; dashboard is a thin web view over `aggregate()`. | **reuse-as-is** (compute). **needs-adapter** (reads a *single local* NDJSON; control-plane store is multi-instance — `aggregate()` gains an `instance_id` group-by). |
| `bin/lib/connectors/` (`Connector` ABC: `configure`/`health`/`identity`/`fetch_issues`; `github.py`/`slack.py`/`email.py`) | The INPUTS interface shape. NOTIFY (§8) is the *inverse* connector (server→instance/owner, **data only**) and reuses `slack.py`/`email.py` egress verbatim. | **reuse-as-is for notify egress**. Ingest does NOT generalize (connectors *pull* external issues; ingest is instances *pushing* in — different direction, new surface). |
| LOCAL GATE: `bin/heimdall-gate-surface` (verdict `PROVEN\|BLOCKED\|PENDING`, one-writer-per-file `.planning/ledger/verdicts/{haid}.json`, secret-free summary, NEVER manufactures a pass) + `bin/secret-scan` (gitleaks) | The OWNER-GATE is a **fleet extension** of this exact verdict model. PROVEN/BLOCKED/PENDING → the gate-approval queue's machine verdict; owner approval is the *human* layer on top. `secret-scan` is the store's CI gate. | **reuse-as-is** (verdict vocabulary + secret gate). **needs-adapter** (per-instance file → server-side approval queue w/ owner decision + override state). |
| `bin/heimdall-haid` (`haid:{human}.{machine}-{hash4}[/role]`, registry `.planning/ledger/agents.json`, **revocation = enforcement primitive**: revoked HAID's writes refused, `check` exits nonzero) | The IDENTITY basis + the **revocation primitive** PKI needs. | **needs-adapter (the biggest gap).** HAID is a *deterministic name*, NOT a keypair — there is **no crypto material today**. PKI (§3) BINDS an Ed25519 keypair to each HAID and makes `haid check` the cert-revocation check. HAID gives identity + revocation semantics; PKI adds the keys. |
| `bin/lib/holdout.py` (`savings_figure`/`require_measured`/`render_figure` — measured/estimated/blank refusal) | The HONESTY discipline for any dashboard NUMBER (token spend, drop-off %). A figure with no token event renders blank, never fabricated. | **reuse-as-is** — mirror for every reported metric. |
| House style `bin/heimdall-redum`, `issue_queue.heimdall_home()`, NDJSON-for-gitleaks | The runtime-home resolver + atomic-NDJSON-queue pattern; NDJSON chosen so the store scans as plaintext. | **reuse-as-is** (patterns). |

---

## 1. SECURITY SPINE — the BOUNDED ACTION-ALLOWLIST (THE decision)

The server NEVER dispatches an arbitrary command string. It dispatches ONLY a pre-defined, source-level `action_type` from a closed registry. **This is the falsifiable core.**

**Allowlist schema** — `bin/lib/cp_allowlist.py`, a frozen dict keyed by `action_type`:

```python
ALLOWLIST = {
  "run-task-X":  ActionSpec(handler="cp_handlers.run_task",  params={"task_id": Str(maxlen=64, pattern=TASK_ID_RE)}, requires_gate=False, isolated=True),
  "sync-queue":  ActionSpec(handler="cp_handlers.sync_queue", params={"queue": Enum("issue","gate")},                requires_gate=False, isolated=True),
  "run-suite":   ActionSpec(handler="cp_handlers.run_suite",  params={"suite": Enum("unit","integration","oracle")}, requires_gate=True,  isolated=True),
}
```

Rules (enforced, not advisory):
- `action_type ∉ ALLOWLIST` → **REFUSED** (audit row `dispatch_refused`, HTTP 422). No fallthrough, no shell, no `eval`, no command-string field anywhere in the wire schema.
- Each `param` is typed + bounded + pattern-validated by `ActionSpec` BEFORE the handler runs. An over-long or off-pattern param is refused (same discipline as `telemetry._SCRUB_MAX`).
- A handler receives only its validated params — never the raw request body, never a string to interpret.

**Adding a new action-type** = a **deliberate, reviewed, source-level commit** to `cp_allowlist.py` + a handler in `cp_handlers.py` + a `secret-scan`-clean test. It is **NEVER** a runtime string, env var, DB row, or API call. The allowlist is *code*, reviewed in PR, shipped in a release. There is no runtime path to extend it.

**Blast-radius property (the thesis):** a fully breached server can trigger ONLY the N allowlisted actions against the isolated job env (§2). It cannot run `curl evil | sh`, cannot read a dev laptop, cannot exfiltrate keys. The allowlist is the blast-radius wall; PKI (§3) only secures the channel.

**Falsifiable assertion (the integration gate's headline):** POST a dispatch with `action_type:"shell"` + `cmd:"rm -rf /"` → server returns 422, writes audit `dispatch_refused`, runs nothing. This test MUST be able to go RED (prove it by also asserting a *valid* `run-suite` dispatch succeeds — the gate distinguishes refuse-arbitrary from refuse-everything).

---

## 2. CONTROL-PLANE / DATA-PLANE SEPARATION (where the line is)

| | Control plane (the server) | Data plane |
|---|---|---|
| Runs | request handlers, scheduler, approval queue, observe store, notify | **server-hosted jobs** (in an isolated exec env) + **instances** running `hmd` locally |
| Holds | server PKI keys, owner identity, audit log, allowlist | NO control-plane secrets reachable from inside a job |
| Never | reaches into a dev laptop to execute (that is **RCE — REFUSED**) | — |

**The line:** the server runs ITS OWN jobs in an **isolated execution env** (worker: scrubbed env allowlist + path-deny + per-job scratch `HEIMDALL_HOME`, proven by integration test cardinal #8). A job dispatched via the allowlist executes there. The server **NEVER** opens a reverse channel into an instance to make it run something — instances *pull* notifications (§8, data) and *push* telemetry (§5), they never *receive commands*.

**Current isolation level:** in-process Python (env allowlist + path deny). Sufficient for the internal ~7-8 dev team — tested, not aspirational. **OS-level sandbox** (separate process + dropped privileges + container boundary) is the seam in `cp_worker.py`; it is built when job execution is opened to external/untrusted users. See ADR-2 in `heimdall-control-plane-decisions.md`.

**Isolation invariant (must be real, not aspirational):** a job process cannot read the control plane's PKI private key, the audit DB, or another job's workspace. Currently enforced by: in-process env allowlist (only validated params + scoped token), path-deny for PKI key dir + audit store, `HEIMDALL_HOME` pointed at a per-job scratch dir, no inbound socket to the control DB. Proven by integration test cardinal #8. When external users are added: upgrade to dedicated low-priv `cp-worker` uid + subprocess boundary (seam: `cp_worker.py`). **A control-plane compromise must NOT equal a fleet compromise** — that is the whole point of the separation.

---

## 3. PKI AUTH (HAID is the basis; keys are the gap)

- **Per-instance identity = HAID** (`haid:rj.mbp-7f3a`), already deterministic + stable per checkout. PKI **binds an Ed25519 keypair to each HAID**: instance generates a keypair on `register`, sends the public key, server stores `{haid → pubkey, status}` extending `agents.json`'s registry.
- **All instance↔server comms authenticated (Ed25519 PKI signing) and encrypted in transit (Cloud Run TLS).** Every request is **signed** with the instance private key; server verifies against the registered pubkey. Unsigned / bad-sig / unknown-HAID → 401. TLS termination is provided by Cloud Run — the control plane MUST NOT be exposed on plain HTTP outside Cloud Run. PKI signing proves identity and integrity; Cloud Run TLS provides confidentiality in transit. Together they satisfy the "authenticated and encrypted" requirement. (Decision: ADR-1 in `heimdall-control-plane-decisions.md`.)
- **Revocation reuses HAID's enforcement primitive verbatim:** `heimdall-haid revoke <haid>` → server refuses that HAID's signed requests (the existing `check` exits nonzero → 401). No new revocation machinery — PKI inherits it.
- **Owner identity** for gate-override (§7) = a distinguished HAID flagged `owner:true` in the registry; override requires an owner-signed approval.
- **OAuth/SSO seam (architect, do NOT build):** auth verification sits behind one `cp_auth.verify_identity(request) -> Identity` chokepoint. Internal uses HAID-signature; the external path later swaps in an OIDC verifier returning the same `Identity` shape. Single seam = no scatter. The OIDC verifier is a named interface point, not built now.

PKI secures the *channel*; it is **necessary, not sufficient**. The allowlist (§1) controls the *blast radius*. Both, independently.

---

## 4. SERVER-HOSTED JOB RUNNER (the flight fix)

Client kicks off → **DISCONNECTS** → job survives server-side → reconnect from any client to status/pause/resume/cancel.

**Job state model** (persisted, the source of truth) — states: `queued | running | paused | done | cancelled`. Legal transitions only; an illegal transition is refused + audited:

```
queued ──▶ running ──▶ done
   │          │  ▲  ╲
   │          ▼  │   ╲──▶ cancelled
   │        paused      ▲
   └────────────────────┘   (cancel valid from queued/running/paused)
```

**Persistence** — `bin/lib/cp_jobstore.py`, append-only NDJSON at `${HEIMDALL_HOME}/control-plane/jobs/{job_id}.ndjson` (one job = one file = one writer; state = fold of the event log). Survives server restart by replaying the log. Each line: `{job_id, ts, state, action_type, params, instance_haid, progress, last_heartbeat}`.

**Detach/resume protocol:**
1. Client `POST /jobs {action_type, params}` (allowlist-validated §1) → server enqueues, returns `job_id` immediately, spawns the isolated worker (§2). **Client may disconnect now — the worker is parented to the server, not the connection.**
2. Worker streams progress to the job log (NOT the client socket). Battery dies / laptop closes → job unaffected.
3. **Reconnect:** any client `GET /jobs/{job_id}` reads current folded state; `GET /jobs/{job_id}/stream` re-attaches to live progress (replays log tail + tails new lines). `POST /jobs/{job_id}/{pause|resume|cancel}` mutates state (owner or originating HAID only).
4. Pause = cooperative checkpoint flag the worker polls; resume clears it; cancel signals the worker + marks `cancelled`.

This is the entire flight case — no laptop-execution needed (§2).

---

## 5. OBSERVE INGEST (reuse the telemetry layer)

Instances push their `hmd report` NDJSON to the server → observability store → dashboard.

- **Push:** instance `POST /ingest` (PKI-signed §3) with a batch of telemetry events. Server **re-runs `telemetry.build_event` on each line server-side** — a client cannot inject an off-schema or secret-bearing line; anything not matching the EVENT_TYPES enum + `_scrub` is dropped. No-secret-by-construction is enforced at the *boundary*, not trusted from the client.
- **Store:** `${HEIMDALL_HOME}/control-plane/observe/{instance_haid}/events.ndjson` — partitioned by HAID, NDJSON so **`bin/secret-scan` (gitleaks) scans it as plaintext** in CI. The store is gitleaks-clean by construction (scrub) AND by gate (scan in the integration suite).
- **Dashboard:** thin web view over `report.aggregate()` (§0) with a new `instance_id` group-by → cross-dev install drop-off, gate frequency, failure patterns, token spend. Every number passes `holdout.render_figure` (no token event → blank, never fabricated).

---

## 6. SCHEDULER (allowlisted only)

Cron-style server-side runs of **allowlisted action-types only** ("run-suite 2am", "sync-queue hourly").

- `bin/lib/cp_scheduler.py` — schedule entries `{schedule_id, cron, action_type, params, owner_haid, enabled}` persisted at `${HEIMDALL_HOME}/control-plane/schedules/schedules.ndjson`.
- On tick, the scheduler **dispatches through the exact same §1 allowlist path** — a schedule cannot name an `action_type` outside `ALLOWLIST` (validated at create-time AND fire-time). A scheduled `run-suite` (which `requires_gate`) still surfaces to the approval queue (§7) before executing. The scheduler has **no privileged dispatch path** — it is just an automated client of §1.

---

## 7. GATE-APPROVAL QUEUE + OWNER OVERRIDE (fleet human-authority)

Irreversible/sensitive actions (`requires_gate:true` in `ActionSpec`) surface to the OWNER for approval; owner can OVERRIDE any gate.

**Approval state model:**
```
pending ──▶ approved ──▶ (action dispatches)
   │
   ├──▶ rejected ──▶ (action refused + audited)
   └──▶ overridden ──(owner force)──▶ (action dispatches, audit flags override)
```
- `bin/lib/cp_approval.py` — extends the `gate-surface` verdict model (PROVEN/BLOCKED/PENDING → approval `pending/approved/rejected/overridden`). One record per pending action at `${HEIMDALL_HOME}/control-plane/approvals/{action_id}.json`.
- A `requires_gate` action does NOT execute until an **owner-signed** (§3) decision lands. `approved`/`overridden` → dispatch; `rejected` → refuse + audit.
- **Override is the human-authority thesis, fleet-level:** the owner can force any gate to `overridden`, but the override is itself a signed, audited act (§9) — authority is exercised, never hidden.

NOTIFY (§8) fires when an action enters `pending` so the owner is pinged.

---

## 8. NOTIFY (data, NEVER commands)

Server → instance/owner messages, alerts, job-complete pings.

- `bin/lib/cp_notify.py` reusing `connectors/slack.py` + `connectors/email.py` egress verbatim (§0). Plus an in-band instance inbox: instances **poll** `GET /notifications` (PKI-signed); they NEVER receive an inbound command socket.
- **Payloads are DATA only** — `{kind: job_complete|approval_needed|alert, job_id?, action_id?, text}`. There is no `action_type`/`cmd`/`exec` field in any notification schema. An instance reading a notification renders text; it cannot be made to *run* anything. The command channel does not exist by construction — this preserves the §2 line.

---

## 9. AUDIT (every action/dispatch/approval)

`bin/lib/cp_audit.py` — append-only, searchable, exportable. NDJSON at `${HEIMDALL_HOME}/control-plane/audit/audit.ndjson` (gitleaks-scannable; fields scrubbed via the telemetry `_scrub`).

**Audit record schema:**
```json
{ "audit_id":"...", "ts":"ISO-8601", "actor_haid":"haid:rj.mbp-7f3a",
  "event":"dispatch|dispatch_refused|job_state|approval|override|ingest|auth_fail",
  "action_type":"run-suite|null", "action_id":"...", "job_id":"...",
  "decision":"approved|rejected|overridden|null", "outcome":"ok|refused|error",
  "detail":"<scrubbed, <=120 chars>" }
```
Every dispatch (incl. **refusals** §1), every job transition (§4), every approval/override (§7), every auth failure (§3) writes one row. Searchable by `actor_haid`/`event`/time range; exportable as NDJSON. This is the security record AND the 3am-debug record.

---

## 10. EXACT DISJOINT FILE LAYOUT (single owner per file)

Stack: **Python** — justified: reuses `telemetry.py` / `holdout.py` / `report.py` / `connectors/` / `secret-scan` directly; minimal self-host deps (stdlib `http.server` or a single small ASGI dep + `cryptography` for Ed25519); keeps house style (`bin/heimdall-*` CLI over `bin/lib/*.py`). Self-hostable: one process + a gitignored `${HEIMDALL_HOME}/control-plane/` state tree, no external DB required (NDJSON stores).

**Wave 1 — BLOCKING SUBSTRATE (the server skeleton + allowlist schema + audit + PKI gate everything else imports). Sequence first; downstream waves import these.**

- **(a) server skeleton + PKI + audit**
  - `bin/lib/cp_server.py` — request router, the `cp_auth.verify_identity` chokepoint, dispatch entry calling §1.
  - `bin/lib/cp_auth.py` — Ed25519 sign/verify, HAID↔pubkey registry adapter over `agents.json`, the OIDC seam interface point.
  - `bin/lib/cp_audit.py` — §9 audit writer + search/export.
  - `bin/lib/cp_allowlist.py` — §1 `ALLOWLIST` + `ActionSpec` validation.
  - `bin/lib/cp_handlers.py` — the bounded action handlers (run_task/sync_queue/run_suite), isolated-env launch.
  - `bin/heimdall-control-plane` — the thin CLI (serve / register / status).

**Wave 2 — parallel, file-disjoint (each imports wave-1; none shares a file with a sibling):**

- **(b) observe ingest** — `bin/lib/cp_ingest.py` (re-run `build_event` server-side, write partitioned store) + `bin/lib/cp_dashboard.py` (web view over `report.aggregate()` + `instance_id` group-by).
- **(c) scheduler + allowlist dispatch** — `bin/lib/cp_scheduler.py` (cron tick → §1 dispatch path). *(the allowlist itself owned by (a); (c) only consumes it.)*
- **(d) job runner + detach/resume** — `bin/lib/cp_jobstore.py` (NDJSON job log + state fold) + `bin/lib/cp_worker.py` (isolated worker, pause/resume/cancel, progress stream).
- **(e) gate-approval + override** — `bin/lib/cp_approval.py` (approval state model over the gate-surface verdict).
- **(f) notify** — `bin/lib/cp_notify.py` (reuse slack/email egress + instance inbox; data-only schema).

**Wave 3 — integration gate (§11):** `test/control-plane-integration.test.sh` + fixtures `test/fixtures/control-plane/`.

Disjointness: every file has exactly one owning piece. Waves 2(b)-(f) touch no shared file (each its own `cp_*.py`); they all *import* wave-1's `cp_server`/`cp_allowlist`/`cp_audit`/`cp_auth` but never edit them. **Wave 1 is the blocking substrate** — the allowlist schema + server skeleton + audit + PKI gate must exist before any of (b)-(f) can wire in.

---

## 11. REUSE LEDGER + INTEGRATION-GATE PLAN

**Reuse ledger (the build-coder contract):**

| Reused | From | Used by |
|---|---|---|
| `build_event` + `_scrub` + EVENT_TYPES | `telemetry.py` | (b) ingest — re-run at boundary |
| `run_detail`/`aggregate` | `report.py` | (b) dashboard |
| `Connector` egress (slack/email) | `connectors/` | (f) notify |
| verdict model PROVEN/BLOCKED/PENDING | `gate-surface` | (e) approval |
| HAID derive + registry + **revoke=enforcement** | `heimdall-haid` / `agents.json` | (a) PKI |
| `render_figure`/`require_measured` | `holdout.py` | (b) dashboard numbers |
| gitleaks scan | `secret-scan` | (b) store CI gate, wave-3 |
| `heimdall_home()` + atomic NDJSON queue | `issue_queue.py` | all `cp_*` stores |

**Integration gate — ONE real flow + the falsifiable refusal** (`test/control-plane-integration.test.sh`). Maps every Harness assertion to a concrete test:

| Spec Harness assertion | Concrete test |
|---|---|
| job survives client disconnect (flight fix) | Start `run-task` job, kill the client process, poll `GET /jobs/{id}` → reaches `done`. |
| dispatches ONLY allowlisted types; **arbitrary refused (falsifiable)** | POST `action_type:"shell"` → 422 + audit `dispatch_refused`; AND POST valid `run-suite` → dispatches. (Distinguishes refuse-arbitrary from refuse-all → the gate can go RED.) |
| irreversible needs owner approval + owner can override | `run-suite` (requires_gate) blocks at `pending`; owner-signed `approve` → runs; separate case owner `override` of a `rejected` → runs + audit flags override. |
| instance↔server PKI-authenticated + TLS-encrypted (Cloud Run) | Unsigned `POST /ingest` → 401; bad-sig → 401; valid sig → 200. (PKI = identity/integrity; TLS = confidentiality in transit. Never plain HTTP. See ADR-1.) |
| telemetry store no-secret-by-construction | Push a batch w/ a planted secret-shaped value → stored line is scrubbed; `bin/secret-scan` over the store exits clean. |
| audit captures every dispatch/approval | After the flow, grep `audit.ndjson` for the dispatch, the approval, and the refusal rows. |

**The headline flow (single test, end-to-end):** client starts a server-hosted job → **client disconnects** → job completes → **notify fires** (job_complete) → owner **approves** a gated action → AND an **arbitrary-command dispatch is REFUSED**. This is the falsifiable core; it must be able to go RED (the refusal half proven by also asserting a valid dispatch succeeds).

**Per-org isolation seam (architect, do NOT build):** every store path already namespaces by `instance_haid`; a later `org_id` prefix on `${HEIMDALL_HOME}/control-plane/{org_id}/...` + an `org` field on the `Identity` from `cp_auth` is the only change. The chokepoints (`cp_auth.verify_identity`, `heimdall_home()`-derived store roots) are designed so external multi-tenant drops in without touching (a)-(f) internals. **Internal-first — leave this as a seam.**

---

## OUT OF SCOPE

- **Multi-tenant / external self-host** — only the seam is architected (§11); no `org_id` partitioning built.
- **OAuth/SSO** — the `cp_auth` swap-point exists (§3); no OIDC verifier built.
- **The dashboard frontend's visual polish** — `cp_dashboard.py` exposes `aggregate()` data; UI styling beyond functional render is a separate plan.
- **Key rotation / HSM / cert lifecycle automation** — Ed25519 bind + HAID-revoke only (§3); rotation policy deferred.
- **Horizontal scaling / HA** — single self-hosted process + NDJSON stores; no clustering, no external DB.
- **Migrating existing local-gate / telemetry callers** — control plane consumes those libs; it does not refactor them.
- **`ship.sh` / release tagging** — RJ's (per spec §Delegation).

---

## Risks & Mitigations

| Risk | Prob | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Allowlist not truly bounded — a param smuggles a command, or a "flexible" action-type leaks a shell | med | **critical** | `ActionSpec` typed+bounded+pattern params; NO command-string field in any wire schema; falsifiable refusal test that must go RED; new action = reviewed source commit only | (a) allowlist + wave-3 gate |
| Job-env isolation aspirational not real — a job reads the control-plane key/audit | med | **critical** | In-process: env allowlist + path-deny + per-job scratch `HEIMDALL_HOME` + no inbound socket to control DB; proven by integration test cardinal #8 (isolation cardinal must stay green). OS-level sandbox (separate process + dropped privs) built when external users added — seam is `cp_worker.py`. See ADR-2. | (d) worker |
| Detach/resume loses state on server restart | med | high | state = fold of append-only NDJSON job log; replay-on-boot; reconnect test after simulated restart | (d) jobstore |
| HAID has no keys today — PKI bolt-on is incomplete | high | high | Ed25519 bind at register; reuse HAID `revoke` as cert-revocation; auth chokepoint test (unsigned/bad-sig/revoked → 401) | (a) cp_auth |
| Client can inject off-schema / secret telemetry at ingest | med | high | re-run `build_event`+`_scrub` server-side at the boundary; `secret-scan` over store in wave-3 | (b) ingest |
| Notify becomes a command channel by accretion | low | **critical** | data-only payload schema (no action_type/cmd field); instances poll, never receive inbound exec; schema test asserts no command field | (f) notify |
