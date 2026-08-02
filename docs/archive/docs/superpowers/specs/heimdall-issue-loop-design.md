# Heimdall — Autonomous Issue-Resolution Loop — DESIGN DOSSIER

> **Status:** design contract for parallel build-coders. READ-ONLY design — no code here.
> **Spec:** `/Users/rj/Downloads/heimdall-issue-resolution-loop-spec.md` (authoritative).
> **House style:** bash wrapper (`bin/heimdall-*`) over a pure python lib (`bin/lib/*.py`), mirroring
> `bin/heimdall-redum`+`bin/lib/redum.py` and `bin/heimdall-attest`+`bin/lib/attestation.py`.
> **Reuse-first:** orient=SI-1, attest=SI-2, gate-verdict=SI-2 `evidence.all_passed`, secret gate=`bin/secret-scan`+`.gitleaks.toml`,
> pluggable-adapter seam=mirror `bin/lib/designmatch_targets/__init__.py` (ABC + `_REGISTRY` + `register()`/`get()`/`available()`).
> **Commit identity (whoever builds):** `rj@runheimdall.dev`. **Agent NEVER pushes/publishes** — RJ holds GitHub creds; tests use fixtures/mocks, no live creds.
> **Located seam patterns:** AI-review adapter — *not located in the bounded look; propose fresh below.* Designmatch target seam — **located** (`bin/lib/designmatch_targets/`); it is the canonical pattern this dossier mirrors verbatim.

This dossier pins **interfaces + disjoint file layouts** so the five build-coder pieces (a)(b)(c)(d)(e) never collide
and never build mismatched seams. Each numbered section below is a hard contract.

---

## 0. The seam to mirror (canonical pattern, verbatim)

`bin/lib/designmatch_targets/__init__.py` is the pluggable-adapter seam the spec references. It is:
- an `abc.ABC` interface (`class Target`) with class-attr metadata (`name`, `language`, `extension`) + abstract methods,
- a module-level `_REGISTRY: Dict[str, X]`,
- `register(inst)` / `get_target(name)` (raises `KeyError` listing available — fail loud, never silently default) / `available()` / `is_registered(name)`,
- launch set declared in ONE place: the trailing `from . import rn` import-side-effect that calls `register(...)`.

**The connector seam (piece a) mirrors this exactly.** A 4th adapter = a new module + one `register(...)` import line; the loop is never edited.

---

## 1. Connector adapter interface (piece a — the seam)

**Lives at:** `bin/lib/connectors/__init__.py` (the ABC + registry), one module per adapter alongside.
**Depended on by:** piece (b) normalize, piece (c) loop, piece (d) writeback — they import `connectors`, never a concrete adapter.

```python
# bin/lib/connectors/__init__.py
class Connector(abc.ABC):
    name: str = ""          # registry key, lowercase: "github" | "slack" | "email"
    label: str = ""         # human label: "GitHub Issues"

    @abc.abstractmethod
    def configure(self, cfg: dict) -> None:
        """Bind per-connector config (creds, repo/channel/mailbox). Raises ConnectorConfigError
        on malformed config. NEVER reads creds from anywhere but `cfg` (the config layer, piece e)."""

    @abc.abstractmethod
    def health(self) -> dict:
        """{ name, active: bool, reason: str|None }. active=False (NOT raise) when creds absent —
        the MarkItDown lazy/optional contract: an absent connector -> inactive source, no crash."""

    @abc.abstractmethod
    def identity(self) -> dict:
        """{ name, label, kind: 'issue'|'chat'|'email' } — static descriptor, no IO. Used by
        normalize to tag `source` and by writeback to route the resolution back."""

    @abc.abstractmethod
    def fetch_issues(self, since: str | None = None) -> list[dict]:
        """Return RAW source items (adapter-native shape). `since` = cursor for incremental pull.
        On an inactive/unconfigured connector -> return [] (never raise). Deterministic ordering."""

    @abc.abstractmethod
    def post_resolution(self, raw_ref: dict, resolution: dict) -> dict:
        """Write the resolution BACK to the source (close issue / reply in thread / reply email).
        Called by piece (d) ONLY after a human merge. `raw_ref` is the adapter-native locator from
        the normalized issue's `links.source_ref`. Returns { ok, url|thread_ts|message_id }.
        On inactive connector -> { ok: False, reason: 'inactive' } (no crash)."""

    @abc.abstractmethod
    def close_issue(self, raw_ref: dict) -> dict:
        """Idempotent source-issue close. Separate from post_resolution so writeback can close
        WITHOUT a message and vice-versa. Inactive -> { ok: False, reason: 'inactive' }."""

# registry — mirrors designmatch_targets exactly
_REGISTRY: dict[str, Connector] = {}
def register(c: Connector) -> Connector: ...      # by c.name; re-register replaces
def get(name: str) -> Connector: ...              # KeyError lists available() — fail loud
def available() -> list[str]: ...                 # sorted keys
def active(cfg: dict) -> list[Connector]: ...     # configured + health().active only
class ConnectorConfigError(Exception): ...
# launch set declared in ONE place:
from . import github, slack, email   # import side-effect: each calls register(...)
```

**APM-later proof:** a Datadog source = `bin/lib/connectors/datadog.py` implementing `Connector` + adding it to the trailing import line. Zero edits to `__init__.py`'s logic, zero edits to (b)/(c)/(d).

---

## 2. Normalized issue schema (piece b — the single internal shape)

Every adapter's raw item normalizes to ONE shape. Normalization lives in piece (b), NOT in the adapters — the adapter
returns native data; `normalize.py` maps it. This keeps `fetch_issues` adapter-shaped and the normalizer the single mapping owner.

```python
# the normalized issue (bin/lib/issue_queue.py :: normalize())
{
  "source":   str,    # connector .name: "github" | "slack" | "email"
  "id":       str,    # STABLE dedup key: "<source>:<native-id>" (idempotency anchor, see section 3)
  "title":    str,    # one-line summary
  "body":     str,    # full text (markdown/plaintext)
  "priority_signal": {            # the prioritization inputs (section 3), all OPTIONAL/honest
     "severity": str | None,      # "critical"|"high"|"normal"|"low"|None (from labels/keywords)
     "age_seconds": int,          # now - created_at (caller supplies clock — deterministic lib)
     "source_priority": int,      # from config per-source weight (section 7); default 0
  },
  "links": {
     "source_ref": dict,          # ADAPTER-NATIVE locator passed verbatim to post_resolution/close_issue
     "url": str | None,           # human-clickable source URL
  },
  "created_at": str,              # source ISO-8601 (or normalize time if source has none)
}
```

**Source -> normalized mapping (the three launch adapters):**

| field | GitHub issue | Slack message | Email |
|---|---|---|---|
| `source` | `"github"` | `"slack"` | `"email"` |
| `id` | `github:<repo>#<number>` | `slack:<channel>.<ts>` | `email:<message-id>` |
| `title` | issue `title` | first line of text (<=120c) | `Subject` header |
| `body` | issue `body` | message `text` + thread | text/plain body (html stripped) |
| `priority_signal.severity` | from labels (`bug`/`critical`/`p0` map) | from keywords (`urgent`,`blocker`) | from `X-Priority` / subject keywords |
| `priority_signal.age_seconds` | now - `created_at` | now - `ts` | now - `Date` header |
| `links.source_ref` | `{repo, number}` | `{channel, ts, thread_ts}` | `{message_id, from, in_reply_to}` |
| `links.url` | issue `html_url` | permalink | `None` (email has no URL) |

`normalize(source_name, raw_item, cfg) -> issue` is a pure function: `connectors.get(source_name).identity()` tags `source`/kind;
the per-source field extraction is a small dispatch table inside `issue_queue.py`. **Honest fields:** a missing severity -> `None`, never guessed.

---

## 3. Queue + prioritization + in-flight tracking (piece b)

**Storage shape** — a JSON store under the gitignored runtime home (mirrors SI-1/SI-2 `${HEIMDALL_HOME:-<repo>/.heimdall}`):

```
${HEIMDALL_HOME:-<repo>/.heimdall}/issues/queue.json
{
  "schema_version": "1.0.0",
  "issues":   { "<id>": <normalized issue>, ... },          # dedup by stable id (section 2)
  "in_flight":{ "<id>": { "since": ISO, "state": "<machine state section 4>", "pr": str|None } },
  "resolved": { "<id>": { "pr": str, "merged": bool, "at": ISO } },
  "flagged":  { "<id>": { "reason": "gate-failed"|"out-of-scope", "evidence_ref": str, "at": ISO } }
}
```
Written atomically (`.tmp` -> `os.replace`), sorted keys — same discipline as `context.json` in SI-1.

**Pick-order heuristic (simple + configurable, section 7 supplies weights):**
`score = w_sev*severity_rank + w_age*normalized_age + w_src*source_priority`; highest score picked first; ties broken by `id`
for determinism. Weights default `{severity:3, age:1, source:1}` and are overridable in config. **Severity rank** is a fixed
map `{critical:3, high:2, normal:1, low:0, None:0}`.

**In-flight / idempotency (no double-work — the cardinal dedup discipline):**
- `pick()` skips any `id` already in `in_flight`, `resolved`, OR `flagged` — an issue is picked AT MOST once until it leaves those sets.
- On pick -> atomically move `id` into `in_flight` BEFORE the loop touches it (claim-before-work), so two concurrent loop
  iterations can never fight over one issue. This mirrors the heimdall-ledger "claim surfaces before editing" discipline.
- Re-ingest is idempotent: `fetch_issues` re-returning a known `id` does NOT re-queue it (the `id` already exists in some bucket).

CLI surface (piece b): `bin/heimdall-issue-queue {ingest|list|pick|status|release}` over `bin/lib/issue_queue.py`.

---

## 4. Resolution loop state machine (piece c — consumes a+b, calls SI-1 & SI-2)

`bin/heimdall-issue-loop` over `bin/lib/issue_loop.py`. **One issue per `run-once`** (the loop is the orchestrator of EXISTING
machinery — it does NOT introduce a new orchestration primitive; it sequences SI-1, the real Heimdall task, the gate, SI-2, piece d).

States (each persisted into `in_flight[id].state`):

```
PICKED -orient-> ORIENTED -fix-> FIXED -gate-> +-PASS-> ATTESTED -pr-> PR_OPEN (terminal-for-loop; section 6 human gate)
                                               +-FAIL-> GATE_FAILED (terminal; -> flagged section 5; NOT resolved)
any state -error-> ERRORED (-> release back to queue OR flagged 'out-of-scope'; honest, never silent)
```

**EXACT SI-1 reuse point (orient — reuse, never reimplement):**
- `PICKED -> ORIENTED`: shell out to `bin/heimdall-comprehend load <repo>` (exit 0 = fresh capsule, inject it);
  on exit 3 (stale/missing/corrupt) call `bin/heimdall-comprehend comprehend <repo>` then re-`load`. The loop reads the
  capsule JSON (`.heimdall/context.json`) for architecture/key-modules/build+test commands to brief the fix task.
  **No new orientation code** — this is exactly F1's wiring contract from `SI-1.md` section "Integration boundary".

**Fix (`ORIENTED -> FIXED`):** dispatch a **real Heimdall task with full gates** (the normal coder path) scoped to the issue,
briefed with the SI-1 capsule + the normalized issue body. The fix produces a working-tree diff in an isolated worktree.
**No incomplete or non-real fixes** — the zero-tolerance hook (`verify-edits`) and the gate (section 5) both reject a non-fix.

**Gate (`FIXED -> {PASS|FAIL}`) — see section 5, the cardinal rule.**

**EXACT SI-2 reuse point (attest — reuse, never reimplement):**
- `(PASS) -> ATTESTED`: shell out to `bin/heimdall-attest emit --repo <worktree> --base <base> --evidence "<test cmd>" --evidence "<gate cmd>" --print`.
  The emitted record `{claims,contracts,evidence,reuse,risk}` (schema `si-2.1`) is the attestation the PR body carries (piece d).
  The loop **reads** `evidence.all_passed` from this same record as the gate verdict (section 5) — one emission, two readers, zero re-analysis.

**Failure transitions:** GATE_FAILED -> `flagged{reason:'gate-failed'}` (section 5). ERRORED (task crash / un-fixable / out-of-scope
classification) -> `flagged{reason:'out-of-scope'}` or `release` back to queue. **No path silently drops an issue** — every exit is recorded.

---

## 5. THE CARDINAL RULE wiring — gate-before-propose (safety-critical, piece c)

**The verdict is read from the deterministic gate, NEVER from the agent's claim.**

- **Where the verdict is read:** the loop runs the issue's acceptance/test command + the project gate (the same machinery a
  real Heimdall task uses: tests green, lint clean, review). It then emits SI-2 (section 4) with those commands as `--evidence`.
  `heimdall-attest` **executes** each `--evidence` command and records the **real exit code** (see `attestation.py::build_evidence`
  -> `ok = (code == 0)`; `all_passed = bool(checks) and all_ok`). The loop reads `record["evidence"]["all_passed"]` —
  **a recorded real exit, not the agent's self-report.** `attestation.py` comment is explicit: *"never the agent's self-assessment."*
- **PASS (`all_passed == True`) -> PR_OPEN.** Only here does piece (d) build the PR. An empty evidence list yields
  `all_passed == False` (`bool(checks)` is False) — so a fix with NO runnable proof is treated as FAIL, never PR'd.
- **FAIL (`all_passed == False`) -> GATE_FAILED -> `flagged{reason:'gate-failed', evidence_ref:<attestation id>}`.**
  The issue stays in `flagged` (OUT of `resolved`, never re-picked section 3). The honest failure is surfaced: the flag carries the
  attestation id whose `evidence` block shows exactly which command failed and `risk.flags` carries `code:"evidence-failed"`.
- **No PR is ever opened on a FAIL.** Piece (d)'s `open_pr()` asserts `attestation["evidence"]["all_passed"] is True` and
  refuses otherwise (structural, not convention — a FAIL physically cannot reach `open_pr`).

This is THE key test (section 9 cardinal-rule test): a fix that fails the gate produces NO PR and a truthful `flagged` record.

---

## 6. Human-approval gate — open PR and STOP (safety-critical, piece d)

`bin/heimdall-issue-pr` over `bin/lib/issue_pr.py`. **Autonomy ends at the PR. No self-merge, no self-close, ever.**

**Hard stop point:** `open_pr(issue, attestation)` builds a PR (branch + body carrying the SI-2 record) and **returns** —
it does NOT merge, does NOT close the source issue. State machine terminates at `PR_OPEN`. There is no `merge()` and no
auto-`close_issue()` reachable from the loop.

**Structural enforcement (not convention):**
1. **No merge capability exists in the loop.** `issue_pr.py` exposes `open_pr()` and `on_human_merge()` ONLY. There is NO
   `merge_pr` function anywhere in pieces (a)-(e). The loop literally cannot self-merge — the verb is absent from the code.
2. **`close_issue` / `post_resolution` are gated behind `on_human_merge()`**, which is invoked ONLY by an external human-merge
   signal (a `merged` webhook/poll result keyed to the PR), never by the loop. `on_human_merge(pr_id)` first VERIFIES the PR
   is merged via the source (`Connector`-side check), then and only then calls `close_issue` + `post_resolution`.
3. **The agent never pushes/publishes** (RJ holds GitHub creds): `open_pr` builds the PR *artifact* (branch, body, metadata);
   the live `gh pr create` / push uses **RJ's creds at runtime**. In tests, a `FakeConnector`/mock stands in — no live creds.
   `open_pr` writes the PR payload to the queue store (`in_flight[id].pr`) and emits the create-command; it does not execute a push.

**On human merge (`on_human_merge`):** -> `connectors.get(source).close_issue(issue.links.source_ref)` + `post_resolution(...)`
with the resolution (PR url + SI-2 evidence summary) -> move `id` to `resolved{merged:True}`. Writeback routes back to the
*originating* connector via `issue.source` (Slack thread / GitHub issue / email reply).

---

## 7. Config + credential handling (security surface — piece e; flag for security-auditor)

`bin/heimdall-issue-config` over `bin/lib/issue_config.py`. **Creds via config, NEVER committed; lazy/optional connectors.**

**Config shape** (committed file carries NO secrets — secrets via env-ref or a gitignored secrets file):

```jsonc
// .heimdall/issue-loop.config.json  (committed: structure + non-secret knobs)
{
  "connectors": {
    "github": { "active": true,  "repo": "owner/name", "token_env": "HEIMDALL_GH_TOKEN" },
    "slack":  { "active": true,  "channel": "C123",    "token_env": "HEIMDALL_SLACK_TOKEN" },
    "email":  { "active": false, "mailbox": "...",      "password_env": "HEIMDALL_MAIL_PW" }
  },
  "prioritization": { "weights": { "severity": 3, "age": 1, "source": 1 }, "source_priority": { "github": 1, "slack": 0, "email": 0 } },
  "in_scope": { "labels": ["bug","dependencies","small"], "max_body_chars": 8000 }
}
```

- **Creds resolved at runtime from ENV** named by `*_env` (or a gitignored `.heimdall/issue-loop.secrets.json` — already covered
  by `.heimdall/` gitignore). The committed config holds ONLY the env-var NAME, never the value. **No token literal ever lands in a committed file.**
- **Lazy/optional (MarkItDown clean-install pattern):** if a connector's creds env is absent -> `health().active == False`,
  the source is simply **inactive**, `fetch_issues` returns `[]`, the loop skips it — **no crash, no abort.** With NO connectors
  configured the loop is **inert**: base install + stranger-test (`test/install-stranger.test.sh`) green, exactly the MarkItDown
  graceful-skip contract (`test/markitdown.test.sh` (c)).
- **gitleaks gate respected:** the existing `bin/secret-scan` + `.gitleaks.toml` catch any planted credential in the diff.
  **Do NOT add a broad allowlist glob** to `.gitleaks.toml` for this feature — only specific fixture files if a test must carry
  a secret-shaped string (the discipline the `.gitleaks.toml` header mandates). Config files carrying a real token must NEVER be
  committed — gitleaks fires if one is staged.

**Auditor pass:** piece (e) is the auth surface — security-auditor reviews cred resolution, the "never committed" guarantee,
and that an absent connector degrades silently.

---

## 8. EXACT FILE LAYOUT — disjoint per wave piece

Every new file belongs to **exactly one** piece. No two pieces share a file -> parallel coders never collide.
Commit identity for whoever builds: **`rj@runheimdall.dev`**.

### (a) connector adapter interface + 3 launch adapters — *parallel with (b)*
- `bin/lib/connectors/__init__.py`  — the `Connector` ABC + `_REGISTRY` + `register/get/available/active` + `ConnectorConfigError` + launch-import line
- `bin/lib/connectors/github.py`    — `GithubConnector(Connector)`
- `bin/lib/connectors/slack.py`     — `SlackConnector(Connector)`
- `bin/lib/connectors/email.py`     — `EmailConnector(Connector)`
- `bin/heimdall-connector`          — thin CLI: `list | health | fetch | identity` (mirrors `bin/designmatch-target`)
- `test/connectors.test.sh`         — seam shape + 3-adapter fetch + 4th-adapter-slots-in + inactive-degrades

### (b) normalization + queue + prioritization — *parallel with (a)*
- `bin/lib/issue_queue.py`          — `normalize()`, the queue store (`queue.json`), `ingest/pick/list/status/release`, in-flight tracking, scoring
- `bin/heimdall-issue-queue`        — thin CLI over it
- `test/issue-queue.test.sh`        — 3-sources->uniform issue, prioritization order, in-flight no-double-pick, idempotent re-ingest

### (c) the resolution loop — *consumes (a)+(b); calls SI-1 + SI-2*
- `bin/lib/issue_loop.py`           — the state machine (section 4), SI-1 orient call, fix dispatch, gate-read (section 5), SI-2 attest call
- `bin/heimdall-issue-loop`         — thin CLI: `run-once | run | status`
- `test/issue-loop.test.sh`         — pick->orient->fix->gate->attest->PR happy path; **gate-fail->NO PR->flagged (cardinal rule)**

### (d) PR creation + human-approval gate + writeback — *consumes (c); safety-critical*
- `bin/lib/issue_pr.py`             — `open_pr()` (asserts `all_passed`), `on_human_merge()` (close+writeback). **No `merge_pr` exists.**
- `bin/heimdall-issue-pr`           — thin CLI: `open | on-merge | status`
- `test/issue-pr.test.sh`           — PR carries SI-2 record; **no self-merge / no self-close**; on-merge->close+writeback

### (e) config + credential handling — *security surface; auditor pass*
- `bin/lib/issue_config.py`         — config load, env-ref cred resolution, active-connector resolution, in-scope filter
- `bin/heimdall-issue-config`       — thin CLI: `show | validate | active`
- `.heimdall/issue-loop.config.json.example` — committed EXAMPLE (no secrets); the live file is gitignored
- `test/issue-config.test.sh`       — no-connectors->inert + stranger-test green; absent-cred->inactive-no-crash; planted-leak->gitleaks catches

### Integration (owned by the integration-gate task, section 9) — *after (a)-(e) merge*
- `test/issue-loop-integration.test.sh` — the end-to-end real-path gate (section 9)

**Sequence:** (a) parallel (b) -> (c) -> (d); (e) parallel (a)/(b) (config is independent), auditor pass on (e). Integration test after all merge.
**Disjointness check:** no path appears under two pieces. OK.

---

## 9. Integration gate plan (the real pick->orient->fix->gate->attest->PR path — NOT unit-only)

`test/issue-loop-integration.test.sh` drives the **whole real path** in a throwaway git repo with **mock connectors + a fixture
fix task** (no live creds — RJ holds those). The metering/launcher lesson: integration bugs pass unit tests, so this exercises
the real seams end-to-end. Each spec **Harness assertion** + **Acceptance** bullet -> a concrete assertion:

| # | Spec assertion | Concrete test assertion |
|---|---|---|
| 1 | 3 connectors -> uniform issue | Feed a fixture GitHub issue, Slack msg, email -> `issue-queue list` shows 3 normalized issues each with all 7 fields; `id` prefixed by source |
| 2 | routine issue -> pick->fix->gate->PR with SI-2 | Queue a fixable fixture issue -> `issue-loop run-once` -> state reaches `PR_OPEN`; the PR body contains the SI-2 record (`grep -q '"schema": "si-2.1"'`) and `evidence.all_passed==true` |
| 3 | **gate-failing fix -> NO PR, flagged honestly (CARDINAL RULE)** | Queue an issue whose fix fixture FAILS its test -> `issue-loop run-once` -> state `GATE_FAILED`; assert NO PR artifact written (`! grep PR_OPEN`), `id` in `flagged{reason:'gate-failed'}`, attestation `evidence.all_passed==false` + `risk` has `evidence-failed` |
| 4 | never self-merge / self-close (human gate holds) | After `PR_OPEN`: assert source issue still OPEN (mock `close_issue` NOT called), PR NOT merged; grep proves no `merge_pr` symbol exists in any `bin/lib/issue_*.py` |
| 4b | on human merge -> close + writeback | Invoke `issue-pr on-merge <pr>` with mock-merged PR -> mock `close_issue` + `post_resolution` called once each; `id` -> `resolved{merged:true}` |
| 5 | 4th adapter slots in w/o loop edits | Register a `FakeJiraConnector` via a new module + import line; assert it `fetch`es into the queue with ZERO edits to `issue_loop.py` / `issue_queue.py` (git diff empty for those) |
| 6 | no-connectors -> inert + stranger-test green | Empty config -> `issue-loop run-once` exits 0 inert (nothing picked); `test/install-stranger.test.sh` still green |
| 7 | planted credential leak caught by gitleaks | Stage a fixture config carrying a `sk_live_`-shaped token -> `bin/secret-scan` exits 1 (finding); a clean config exits 0 |

**Falsifiability:** assertion #3 (cardinal rule) and #4 (human gate) are the load-bearing red tests — each must be shown to go
RED on a known-bad build (a loop that PR's on agent-claim fails #3; a loop with a `merge_pr` fails #4).

---

## 10. Reuse ledger

**REUSED (read/call, never reimplement):**
- **SI-1 orient** — `bin/heimdall-comprehend load|comprehend` + `.heimdall/context.json`. The loop's orient step IS F1's wiring contract. No new orientation code.
- **SI-2 attest** — `bin/heimdall-attest emit` -> `{claims,contracts,evidence,reuse,risk}`. The PR body carries this record verbatim; the loop reads `evidence.all_passed` AS the gate verdict. No diff re-analysis.
- **Gate verdict machinery** — `attestation.py::build_evidence` real-exit-code recording (`ok=(code==0)`, `all_passed`). The cardinal rule reuses this EXACT signal — the loop never re-derives pass/fail.
- **gitleaks gate** — `bin/secret-scan` + `.gitleaks.toml` catch planted leaks. Cred handling respects it; no new scanner.
- **Pluggable-adapter seam** — pattern mirrored from `bin/lib/designmatch_targets/__init__.py` (ABC + registry + register/get/available + launch-import line).
- **Runtime-home + atomic-write discipline** — `${HEIMDALL_HOME:-<repo>/.heimdall}`, `.tmp`->`os.replace`, sorted keys (from SI-1/SI-2).
- **House CLI shape** — bash wrapper over python lib, `sed`-extracted `--help`, exit-code conventions (from `heimdall-redum`/`heimdall-attest`).
- **MarkItDown lazy/optional + stranger-test** — `test/markitdown.test.sh` graceful-skip + `test/install-stranger.test.sh` inert-when-unconfigured.
- **Claim-before-work dedup** — heimdall-ledger "claim surfaces before editing" discipline, applied to in-flight tracking.
- **Real Heimdall task + full gates** — the fix step IS the existing coder path; the loop sequences it, adds no new fix engine.

**Genuinely NEW (justified — no existing equivalent):**
- `Connector` interface + 3 launch adapters (a) — no connector seam exists today; mirrors designmatch pattern but is new code.
- Normalized issue schema + queue + prioritization + in-flight (b) — no issue store exists.
- The resolution loop state machine (c) — new *sequencer* (NOT a new orchestration primitive; it calls existing machinery).
- PR-creation artifact + human-gate + writeback (d) — new, but reuses SI-2 for the body and connectors for writeback.
- Config + cred-resolution layer (e) — new, but reuses gitleaks + the gitignored-home convention.

**Nothing is reimplemented that already exists.** The only "new engine" is the loop sequencer, which is unavoidable and is
explicitly a sequencer of existing parts, not a parallel orchestrator.

---

## Risks & Mitigations

| Risk | Prob | Impact | Mitigation | Owner |
|---|---|---|---|---|
| Loop trusts agent "done" claim instead of the gate (the naive-AI-tickets disaster) | med | **high** | Gate verdict read ONLY from SI-2 `evidence.all_passed` (recorded real exit, section 5); `open_pr` ASSERTS it; #3 is a red test | (c)+(d) |
| Self-merge / self-close slips in | low | **high** | NO `merge_pr` verb exists in any `issue_*` file; close/writeback gated behind `on_human_merge`; #4 greps for absence | (d) |
| Committed credential leak | med | **high** | Config holds env-NAMES only; secrets gitignored; `bin/secret-scan` gate; auditor pass on (e); #7 red test | (e) |
| Two loop iterations fight over one issue | med | med | Claim-before-work: pick atomically moves id -> `in_flight` before any work; idempotent re-ingest | (b) |
| 4th adapter forces a loop edit (seam leak) | low | med | Loop imports `connectors` registry ONLY, never a concrete adapter; #5 asserts zero loop-file diff | (a)+(c) |
| Absent connector crashes base install | low | med | `health().active==False` -> inactive, `fetch` returns []; #6 inert + stranger-test | (a)+(e) |

---

## OUT OF SCOPE

- **APM / observability connectors** (Datadog, New Relic) — seam built so they slot in later; NOT implemented now.
- **Live PR publishing / `gh pr create` / git push** — RJ holds GitHub creds; the loop builds the PR *artifact*, RJ's creds open it at runtime. Tests use mocks/fixtures, no live creds.
- **Auto-merge / auto-close** — explicitly forbidden; autonomy ends at PR. No `merge_pr` verb is built.
- **Complex / non-routine issue resolution** — out-of-scope issues are flagged for a human, not force-attempted.
- **F4 collision/dedup cross-loop coordination** — in-flight tracking is intra-store only; cross-worktree F4 ties are future work.
- **New orchestration primitive** — the loop sequences EXISTING machinery (SI-1, real task, gate, SI-2); it adds no new orchestrator.
- **Tagging / release (`ship.sh`)** — RJ's. The build commits in worktrees and reports merges; it does not tag or release.
- **Test coverage of pre-existing SI-1/SI-2/gitleaks code** — reused as-is; their existing tests stand.
