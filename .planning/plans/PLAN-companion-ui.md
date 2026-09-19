# PLAN — Companion Web UI for `hmd` (`hmd ui`)

Status: DESIGN ONLY. No code in this cycle. Write-only artifacts: this file +
`.planning/plans/companion-ui.waves.json`. Not committed (operator instruction:
do not git commit).

## 0. Interpretation of the ask (stated explicitly, per brief)

Operator's words: "a changing super customer FE supportive app that works
in-situ with HMD while it runs on machine or on remote one."

- **changing** = live-updating (SSE push, not a static dump).
- **customer** = the person running `hmd` (solo), and in team mode their
  teammates (read-only for teammates unless it's their own instance).
- **supportive** = shows state AND offers a small, explicit allowlist of safe
  actions (checkpoint save, view receipt, toggle *advisory* hooks, see agents,
  see gate verdicts). Never a general remote-control surface.
- **in-situ** = zero setup beyond `hmd ui`; reads state hmd already writes to
  disk; no new daemon, no new persistent service, no build step.
- **remote** = the same view for an `hmd` running on a different machine,
  without ever moving a secret off that machine.

## 1. Assumptions

- A1. The audience is the single operator (RJ) or, in TEAM MODE, one
  teammate at a time viewing their OWN machine's `hmd` — not a hosted
  multi-tenant dashboard. Confirmed by "in-situ" + the repo's existing
  loopback-only posture for every other local server in this codebase
  (OmniRoute, `bin/lib/cp_server.py` in dev mode).
- A2. "Remote" means *this operator's own other machine* (their laptop SSHs
  into their desktop, or a cloud dev box), not "any teammate, anywhere,
  browser-only." No public hosting is in scope this cycle.
- A3. The UI is READ-ONLY by default; the only writes it may ever trigger are
  the four named safe actions in Decision 4, each of which shells out to an
  existing, already-audited CLI — the UI process itself never re-implements
  gate/verdict/signing logic, mirroring the house rule `bin/lib/watch_data.py`
  already states for `hmd watch` ("RENDERER OVER EXISTING PLUMBING").
- A4. `python3` (or a pyenv/asdf shim resolved through `bin/lib/hmd-python.sh`)
  is present, matching every other Wave-1 hmd tool. No Node, no npm, no build
  step, no new pip package.

## 2. Inventory (what exists today, cited)

| Surface | File:line | What it holds | Reuse plan |
|---|---|---|---|
| Legacy single-verdict state | `.heimdall/statusline.json` (empty on this checkout) | `{verdict,passed,total,gate,ts}`, written by `bin/heimdall-status-json` | Read only via `hmd_ledger.read_status()`, never parsed raw (its own legacy-fallback branch, `sentinels/hmd_ledger.py:50-51`) |
| Per-repo ledger mirror | `${HEIMDALL_HOME}/ledger/repos/<repo_key>.json` (preferred), `${HEIMDALL_HOME}/ledger/status.json` (legacy-global) | `{daemon,gates[],verdict,team[],repo}` — the exact NORMALIZED shape the statusline renders | `sentinels/hmd_ledger.py:476` `read_status(session_id, repo=None)` returns this NORMALIZED dict directly — this is the canonical data source, not the raw files |
| Team roster cache | `.heimdall/.roster-cache.json` | list of `{haid,handle,branch,project,state,verdict,file,ts,activity_ts,age_seconds,online}` (confirmed live sample) | `bin/lib/watch_data.py:96` `read_roster(root)` already normalizes list-vs-dict payload shapes |
| Session handoff | `.planning/CHECKPOINT.md`, `.planning/STATE.md` | human-readable auto-checkpoint block (`<!-- heimdall-auto-checkpoint:begin -->…`), phase/goal/blockers | Show only the mechanically-derived summary line (branch, HEAD, phase, uncommitted count) — never dump the full markdown body (it can carry free-text notes an operator wrote for themself, not meant as a UI payload) |
| Coordination ledger | `.planning/ledger/{activity,checkpoints,verdicts,claims}/` | per-HAID JSON files (e.g. `.planning/ledger/checkpoints/haid_rj.rishabhs-macbook-air-46d5.json`); `activity/` and `verdicts/` were empty on this checkout | Read via `heimdall-checkpoint-share roster --json` (already scrubs/normalizes — see `bin/heimdall-checkpoint-share:1-20`), never read the raw per-HAID files directly (that engine owns a privacy boundary: "allowlist -> path-strip -> _scrub -> zero-content -> security-class -> secret-scan fail-closed") |
| Full-sweep receipt | `.heimdall/receipts/last-sweep.json` | `{finished_at,head_sha,tree_clean,exit_code,suites_total/passed/failed,duration_s,load_*}` (confirmed live sample, 412/412 passed) | Read directly — this file has no secret fields, confirmed by sample above |
| Metrics | `~/.heimdall/metrics.jsonl` | empty on this checkout; append-only JSONL elsewhere | Optional Wave-2+ sparkline source; not required for MVP |
| Hooks registry | `hooks/hooks.metadata.json` + `bin/heimdall-hooks list --json` | `{id,event,index,matcher,locked,enabled,description}[]` (confirmed live: `parallel-gate`…`bash-gate-chain` etc., `locked:true` on `secret-paste-filter`/`bash-gate-chain`) | Shell out to `bin/heimdall-hooks list --json` — never read `hooks.metadata.json` raw (that file's own header says "Edit id/description/locked by hand, never fingerprint" — the CLI is the contract) |
| Hook kill-switch | `bin/heimdall-hooks enable <id>` / `disable <id>` | advisory hooks toggle in `$HEIMDALL_HOME/hooks-disabled`; `disable` on a locked id exits 2 (confirmed: `bin/heimdall-hooks:24-42`) | THE action the UI shells out to for "toggle advisory hooks" — locked ids are refused by the CLI itself, so the UI needs no separate lock-check, only surfaces the `locked` field from `list --json` to grey the button |
| Parallelism grade | `bin/parallelism-tracker grade` | one-line text `"[heimdall] parallelism: N batched / M turns (ratio R, C calls) \| agents: ..."` (confirmed live) | Parse into `{batched,turns,ratio,calls,agent_calls,agent_batched}` for a small stat tile |
| Edit tracker | `bin/edit-tracker paths` | newline list of edited file paths this session | Optional Wave-2 "files touched this session" tile |
| Quality gate | `bin/heimdall-state check-quality-gates` | exit 0 = clear to push; nonzero + one-line reason on stderr/stdout (confirmed live: exit nonzero, "GATE FAILED: sweep receipt is STALE…") | THE gate-verdict tile: exit code + first line, refreshed every poll |
| Fallback/routing state | `bin/heimdall-fallback status --json` | `{state,endpoint,target_provider,operator_key_configured,...}` (confirmed live, `state:"coop"`) — CLAUDE.md: "never pin the main agent's model" | Read `state`/`target_provider` ONLY for an informational badge; **never** render `operator_key_configured` details beyond a boolean, per Decision 4 (routing/fallback internals are a NEVER-expose action surface, but a read-only informational badge of *which* provider is active is not an action and is low-sensitivity — still flagged as a judgment call in Risks) |
| Reels | `.planning/reels/` | directory exists at repo root per `find .planning -maxdepth 2 -type d` (not populated on this checkout) | Wave-2 "recent reel" link tile, degrade to empty state when absent |
| `hmd watch` data layer | `bin/lib/watch_data.py` (605 lines) | `resolve_root`, `read_roster`, `read_feed` (`.heimdall/feed.jsonl`), `read_receipt` (path-confined via `_confined_realpath`, `watch_data.py:196-215`), `build_shell_argv` (allowlisted ref charset `_REF_RE`, `-- ref` positional-after-terminator pattern, `watch_data.py:255-283`) | **Primary reuse target.** The companion server imports this module directly for roster/feed/receipt reads and for the safe-action argv builder — it does not re-implement any of it. This directly answers the brief's "can the web UI reuse their DATA layer rather than re-render?" — yes, verbatim. |
| `hmd watch` TUI | `bin/heimdall-watch-tui` (55 lines), `bin/lib/watch_tui.py`, `bin/lib/watch_entry.py` | The terminal-side consumer of `watch_data.py`; degrades to a static ANSI wall when Textual is absent | Sibling, not reused directly (different rendering target: browser vs TTY) — but its "renderer over existing plumbing, zero extra server calls" invariant is the exact posture the web UI must also hold |
| Statusline renderer | `sentinels/hmd-statusline.py` (2396 lines) | The 4-row watchman HUD; reads via `hmd_ledger.read_status` | Confirms `hmd_ledger` is the canonical, already-relied-upon reader; the web UI becomes a second consumer of the same normalized shape, not a third parallel parser |
| Presence / remote roster | `bin/heimdall-presence` (1615 lines) | `beat`/`roster [--json]`/`keeper-start`/`keeper-stop`; control-plane URL resolution order, per-dev Ed25519 signing, `X-Heimdall-Team-Secret` header | Confirms team-secret material exists (`.heimdall/team.json`) and must never be read by the UI (Decision 5 / secrets list below); `heimdall-presence roster --json` (already scrubbed to handle/haid/verdict/branch/state) is a safe SHELL-OUT source for a "teammates online" tile |
| Control plane server | `bin/lib/cp_server.py` (stdlib `http.server`, `dispatch`/`serve` split, `register_route` seam at `cp_server.py:132`) | Confirms the repo's own precedent for "stdlib http.server, allowlisted dispatch, audit every call" | **Pattern precedent for Decision 1/2** — the companion UI server is architected the same way: a pure dispatch core + a thin socket wrapper, action allowlist, no arbitrary command execution |
| MCP ledger server | `.mcp.json` → `bin/heimdall-ledger-mcp` | Tools: `read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`, `raise_conflict_pr` (`bin/heimdall-ledger-mcp:129-308`) | Claim/decision surface for MULTI-AGENT coordination within a Claude Code session, not a general state feed — **not reused as transport** (Decision 2); still shown read-only if `read_claims` conflicts are visible via `.planning/ledger/claims/` files, deferred to Wave 2 |
| Checkpoint (mechanical) | `bin/heimdall-checkpoint write` | LLM-free auto-save with a self-verifying "completeness gate" (digest-checks every resume-contract field survived the write) | THE "save checkpoint" safe action — deterministic, no LLM call, already self-verifying |
| Checkpoint (rich) | `commands/save.md` (`/hmd:save`) | An LLM PROMPT, not a CLI — cannot be shelled out to from a stdlib server | Explicitly NOT exposed as a UI button (no way to invoke an LLM turn from a headless server); the UI's "save" button is `heimdall-checkpoint write` only, labeled accordingly |
| Dispatcher | `bin/hmd` → `bin/heimdall` (`case "$1" in … esac`); `watch)` case at `bin/heimdall:2358-2372` | Exact pattern for adding a new verb | `ui)` case added immediately, mirroring `watch)` verbatim (resolve `$PLUGIN_DIR/bin/heimdall-ui`, exec with forwarded args) |
| Python resolver | `bin/lib/hmd-python.sh` | `hmd_python()` — cached, shim-avoiding interpreter resolution (`~/.heimdall/.python3-path` cache, `-c pass` liveness probe) | The launcher sources this and uses its resolved path, never bare `python3` — required by CLAUDE.md's own convention list in the brief |
| Team secret | `.heimdall/team.json`, `~/.heimdall/team.json`, `~/.heimdall/.team-gh-auto-stamp`, `~/.heimdall/team-auto.log` | Team secret + auto-team bookkeeping | **NEVER read by the UI process**, in any form, in any field |
| Signing / PKI | `~/.heimdall/pki/*.seed`, `~/.heimdall/signing/heimdall-signing.key`, `~/.heimdall/gh-app/key.pem` | Ed25519 seeds, HMAC signing key, GitHub App private key | **NEVER read by the UI process** |
| CP endpoint config | `~/.heimdall/cp-endpoint.json` | Control-plane URL only (not itself secret per `heimdall-presence`'s own docstring: "the URL is not a secret") | Safe to read *only* the `.url` field if a future tile needs it; not needed for MVP |

## 3. The five decisions

### Decision 1 — Runtime: python3-stdlib single-file-ish server

**Chosen:** a single `sentinels/hmd-ui.py` built on stdlib
`http.server.ThreadingHTTPServer`, structured as a pure `collect_state(root)` /
`dispatch_action(action, params)` core plus a thin socket wrapper — the exact
split `bin/lib/cp_server.py` already uses in this repo (`dispatch(...)` pure,
`serve(...)` the http wrapper, `cp_server.py:1-40`). One static HTML file
(`sentinels/hmd-ui.html`) with inline `<style>`/`<script>`, served
as a static asset; no template engine.

**Rejected — Node/Express or any JS toolchain:** the repo ships 300+
bash/python bins and zero `package.json`/build step at the tool level (only
`skills/designmatch/scripts/*.js` exists, and that's a design-diff renderer
invoked ad hoc, not a service). Adding Node as a *dependency of the base
install* contradicts the "zero-toolchain" posture the brief itself calls out,
and would need its own `node_modules` lockfile discipline this repo has
deliberately avoided everywhere else (see `bin/heimdall-web`'s explicit
rejection of Firecrawl as a dependency for the same reason: "self-host needs a
browser pool + Redis + Postgres" — the same allergy applies to a Node service
here).

**Rejected — static-file-only (no server, e.g. a `file://` HTML page that
polls JSON via `fetch`):** browsers refuse `fetch()` against `file://` JSON in
most configurations (CORS/file-scheme restrictions vary and are not reliably
scriptable), and a static page cannot do the SSE push the "changing" ask
requires — it would degrade to a manual-refresh page, which is not
"live-updating." A local server is required for the SSE decision below to
work at all.

### Decision 2 — Transport: SSE over the state files, polling with digest-diff

**Chosen:** Server-Sent Events (`GET /api/events`) over plain
`text/event-stream`. The server polls the same files `hmd_ledger.read_status`
and `watch_data.read_roster`/`read_feed` already poll, every 2 seconds
(matching the statusline's own `refreshInterval:2`, cited in
`sentinels/hmd-statusline.py`'s docstring: "Ships via hooks/statusline.sh …
refreshInterval:2"), and emits a new `data:` frame **only when the computed
state digest changes** (SHA-256 of the canonical JSON), so an idle session
emits nothing after the first frame — no busy-loop traffic.

**Rejected — WebSocket:** SSE is strictly sufficient for a one-directional
push (server → browser) and is implementable in ~30 lines of stdlib
`http.server` (a long-lived response with `Content-Type: text/event-stream`
and periodic writes); a WebSocket needs a handshake upgrade and framing that
stdlib `http.server` does not provide natively, which would force either a
hand-rolled RFC 6455 implementation (real risk of subtle bugs in a hand-rolled
protocol) or a third-party dependency — both worse than SSE for a
one-directional feed. Actions (the one thing that IS client → server) are a
plain POST, not a duplex channel, so WebSocket buys nothing here.

**Rejected — fs events (inotify/FSEvents/kqueue):** none is in Python's
stdlib cross-platform (Linux/macOS parity would need `watchdog`, a new pip
dependency, contradicting Decision 1's zero-dependency rule); the additional
latency win over a 2s poll (already matching the statusline's own cadence) is
not worth a new dependency for a "live-enough" target.

**Rejected — the `heimdall-ledger` MCP server as transport:** that server is
scoped to in-session multi-agent coordination tools (`read_claims`,
`make_claim`, …) invoked over MCP's stdio/JSON-RPC by an MCP CLIENT (Claude
Code itself) — it is not reachable from a browser, has no HTTP surface, and
mixing "a browser's HTTP GET" into an MCP server built for Claude-Code-side
tool calls would require bolting on a second transport to a server whose
contract is "every tool call is HAID-attributed to your client identity" (per
its own MCP instructions) — a browser tab is not that client.

### Decision 3 — Remote: SSH port-forward, launcher-only, zero new server code

**Chosen:** `hmd ui --remote user@host [--remote-port N]` runs
`ssh -N -L <local_port>:127.0.0.1:<remote_port> user@host 'hmd ui --port <remote_port> --print-url-only'`
in the background, waits for the remote print-url line over the SSH session's
stdout, rewrites its `127.0.0.1:<remote_port>` to the local forwarded port,
and opens the browser locally. The server itself is **unaware** it is being
reached remotely — it still binds `127.0.0.1` only, on the remote host too.
"Remote" is entirely an SSH-transport concern layered on top of an unchanged
local-only server.

**Rejected — (b) local UI pulls from the presence control plane:** the
control plane's `cp_presence` surface is deliberately scrubbed to
handle/haid/verdict/branch/state/ts (confirmed by `bin/heimdall-presence`'s
own docstring and the live `.heimdall/.roster-cache.json` sample above) — it
does not, and per the Control-Plane project's own security spine (bounded
action-allowlist, PKI-over-HAID) *should not*, carry hook lists, receipt
bodies, or gate detail. Building this option means either (i) extending the
CP's public surface with a new, more detailed state-mirroring route — new
attack surface, new audit burden, a second copy of gate/hook state now
living server-side — or (ii) settling for a materially thinner remote view
than the local one. Rejected for scope and for the secret-boundary reason in
(c) below.

**Rejected — (c) hmd publishes a scrubbed snapshot to the CP, hosted UI reads
it:** this is the worst option against "secret never leaves the machine":
even a "scrubbed" snapshot is a *persistent, server-side copy* of live
workflow state (which hooks are enabled, which gates are failing, what the
operator is doing right now) sitting on infrastructure this repo does not
control end-to-end for that purpose. It also requires the CP to grow a new
ingest+storage+serve path (three new surfaces) for a feature (b) already
shows is unnecessary once SSH is available. Not rejected forever — flagged in
§NEXT-CYCLES as a possible "no-SSH-access" fallback if ever needed — but SSH
is available in every environment this brief's operator uses (their own
machines), so it is not needed now.

### Decision 4 — Safe actions: exact allowlist

**Exposed (Wave 2), each a direct shell-out to an existing, already-gated
CLI — never a re-implementation:**

1. `save-checkpoint` → `bin/heimdall-checkpoint write` (mechanical, LLM-free,
   self-verifying; see Inventory).
2. `view-receipt` → read-only, serves the JSON already at
   `.heimdall/receipts/last-sweep.json` (or a `watch_data.read_receipt`-style
   confined read for a specific feed item) — no CLI call needed, it's a file
   read already covered by `_confined_realpath`'s path-traversal gate.
3. `hook-toggle` (advisory ids only) → `bin/heimdall-hooks enable <id>` /
   `disable <id>`. The server does not re-check `locked` itself beyond
   greying the button from the `list --json` response — the CLI's own exit-2
   refusal on a locked id is the actual gate, so there is exactly one place
   this rule lives.
4. `open-reel` → read-only, serves a file under `.planning/reels/` through
   the same `_confined_realpath`-style containment check `watch_data.py`
   already implements for receipts (reused verbatim, not reinvented).

**NEVER exposed, explicitly, with reasons:**

- Anything touching `bin/heimdall-fallback` routing/provider state (switch,
  set operator key, change target provider) — CLAUDE.md: "never pin the main
  agent's model," and provider routing is exactly the kind of irreversible,
  session-wide side effect a passive dashboard must not be able to trigger.
- Anything that runs `git push` or `git commit` — pushing is gated by
  `heimdall-state check-quality-gates` and the pre-push hook chain
  specifically because it is consequential and slow (the CLAUDE.md sweep-once
  rule); a UI button that fires it invites exactly the "ran the full gate
  mid-work" mistake that rule exists to prevent.
- Anything writing to `.heimdall/team.json`, PKI seeds, signing keys, or CP
  enrollment (`heimdall-presence`'s enroll/keygen path) — these are identity
  and secret material; the UI has no business touching them.
- Locked hooks (`secret-paste-filter`, `bash-gate-chain`, etc., per the live
  `hooks list --json` sample: `"locked": true`) — read-only display only.
- Any general file write/edit — the UI is a dashboard, not a second editor.

> **Correction (2026-09-19, found by the Wave 1 author):** `bin/parallelism-tracker grade` is the SessionEnd action — `do_grade()` appends to `.planning/metrics.jsonl` and `unlink()`s the session state, so it must never be polled. The server reads `$TMPDIR/heimdall-parallel/<session>.state` read-only (`parallelism.source:"live"`) and falls back to the last graded row in metrics.jsonl (`"last_graded"`). Any inventory line above naming `grade` as a poll source is superseded.

### Decision 5 — Local auth: loopback bind + per-launch random token, plus a Host-header allowlist

> **Contract settlement (2026-09-19, after the independent tester wrote
> `test/heimdall-ui.test.sh` from this PLAN and found the build brief had
> drifted from it).** The following supersede the text below wherever they
> differ, because the test is the oracle and the author was told to converge on
> the test: files are `bin/heimdall-ui` (bash launcher via
> `bin/lib/hmd-python.sh`), `sentinels/hmd-ui.py` (server), `sentinels/hmd-ui.html`;
> flags are `--repo DIR` (also honours `HEIMDALL_WATCH_ROOT`, then cwd),
> `--port N`, `--no-open`, `--print-sources` (lists every file the server reads
> -- the deny-list is asserted against it); the launcher prints exactly one
> stdout line `http://127.0.0.1:<port>/?token=<urlsafe>`; the token is accepted
> as `?token=` on **all** routes and additionally as `X-Heimdall-UI-Token` on
> `/api/state` (a superset of Decision 5, because an `EventSource` and a plain
> `curl` both need the URL form); a foreign `Host` is refused with **403**, not
> 400 -- the request is well-formed, it is forbidden. Everything else in
> Decision 5 (loopback-only bind, per-launch `secrets` token,
> `hmac.compare_digest`, Host allowlist `{127.0.0.1:<port>, localhost:<port>}`)
> stands.

**Chosen:** bind `127.0.0.1` only (never `0.0.0.0`), generate a 32-byte
`os.urandom` token per launch, require it as `?token=` on `/` and
`/api/events` (a `<script>` tag and an `EventSource` URL can't set custom
headers, so the token must ride the URL for those two) and as
`X-Heimdall-UI-Token` on `/api/state`/`/api/action` (which the SPA's own
`fetch()` calls CAN set), compared with `hmac.compare_digest` (constant-time).
**Additionally**, every request's `Host` header is checked against an
allowlist of `127.0.0.1:<port>` / `localhost:<port>` — a request with any
other Host is refused with 403 before the token check even runs.

**Justification against "loopback is not 'only me'":** this repo's own prior
audit of OmniRoute already established the exact failure mode a bare loopback
bind has: *"Other local processes / other OS accounts on the same machine:
loopback sockets have no cross-user isolation on macOS/Linux by default. Any
other process or account on this machine could reach `127.0.0.1:20128`
freely."* (`docs/analysis/2026-08-25-omniroute-install.md:29`). The same
audit separately flags that *"a loopback-only bind is not equivalent to
browser-unreachable"* because of DNS rebinding
(`docs/analysis/2026-08-25-omniroute-install.md:95,112`) — a malicious page
open in the operator's OWN browser can still issue a same-origin-looking
request to `127.0.0.1` if the server trusts the Host header blindly. The
companion UI is answerable to both halves of that same finding: the random
token closes the "other local account/process" gap (OmniRoute's finding #1
root cause — a *guessable* shared secret, `CHANGEME` — is avoided by using a
256-bit random value scoped to one launch, never a fixed default); the
Host-header allowlist closes the DNS-rebinding gap OmniRoute's finding #3
left "not actioned" upstream — this plan actions it inline instead of
inheriting the gap.

**Rejected — no auth (bare loopback bind only):** exactly the posture the
cited audit already measured as insufficient on a shared/multi-account
machine, and CI/build boxes in this org are plausibly shared. Rejected
outright, not just noted as residual risk.

### Decision 6 — Job panels: a job publishes descriptors, the closed-type
renderer draws them, `source` is OUT

> Amendment (2026-09-19). Operator's words: "aim is to have a custom built UI
> for whatever job hmd is running — say a dashboard, say graphing my
> database; even building hmd and showing the currently live number of
> people using hmd." Audience: the developer and their dev team watching the
> running job, not only `hmd`'s own telemetry. This decision governs the new
> `panels` surface layered on top of Decisions 1-5 (unchanged) and Wave 1's
> already-landed `/api/state`/`/api/events` contract (unverified — confirm
> the exact current shape of `sentinels/hmd-ui.py`'s `/api/state` handler in
> Wave 4's read-first; Wave 1 was mid-build by another agent when this
> amendment was written and was not read here per the brief's own
> instruction).

**Chosen:** a job (any `hmd` agent, or `hmd` itself) publishes one panel per
concern as a JSON file under `<repo>/.heimdall/ui/panels/<id>.json`:

```json
{
  "id": "db-orders-per-hour",
  "title": "Orders / hour",
  "type": "timeseries",
  "data": { "x": ["2026-09-19T09:00:00Z", "2026-09-19T10:00:00Z"], "y": [12, 31] },
  "refresh_s": 60,
  "updated_at": 1758276286.0
}
```

`type` is a CLOSED set the static HTML already knows how to render with zero
job-supplied code: **`kv | table | number | timeseries | bars | markdown |
log-tail`**. Per-type `data` shape:

- `kv` — `{"rows": [[label, value], ...]}` (order-preserving; mirrors
  `bin/summary-card`'s label/value row convention, the closest in-repo
  precedent for "turn a small state blob into a readable row list").
- `table` — `{"columns": [str, ...], "rows": [[cell, ...], ...]}`. Cells are
  always plain-escaped text — table never runs the `markdown` substitution
  pass, so its blast radius stays exactly "one type, one substitution
  algorithm."
- `number` — `{"value": num|str, "delta": num?, "format": "count"|"duration_s"|"bytes"|"percent"?}`.
  A `delta`'s sign is rendered with the `dataviz` skill's **status** palette
  (good/warning/serious/critical — reserved colors, never a generic hue),
  not an ad hoc red/green.
- `timeseries` — `{"x": [...], "y": [...]}` or multi-series
  `{"series": [{"name": str, "x": [...], "y": [...]}, ...]}`, capped at
  `MAX_SERIES = 6` (the `dataviz` skill's categorical-hue rule: hues are
  assigned in a fixed order and a 9th series is never a new generated hue —
  6 stays comfortably inside that before any "fold into Other" question
  arises). Colors: `dataviz`'s `references/color-formula.md` fixed
  categorical order; one axis only (`dataviz`'s non-negotiable: never a
  dual-axis chart) — a job wanting two differently-scaled measures gets two
  panels, not one two-axis panel.
- `bars` — `{"labels": [...], "values": [...]}` or the same multi-series
  shape as `timeseries`, same `MAX_SERIES = 6` cap.
- `markdown` — `{"text": str}`, a **sanitized subset only**: the renderer
  HTML-escapes the entire string FIRST (so no literal `<`/`>` from job data
  can survive), THEN substitutes exactly four patterns against the
  already-escaped text — `**bold**`, `` `code` ``, a leading `- ` line to a
  `<li>`, and `\n` to `<br>`. Links are NOT supported in Wave 4 (no
  `[text](url)` substitution at all) — a `javascript:`/`data:` URI is a real
  vector and the smallest closed set is the one that doesn't have to reason
  about URL schemes at all. Escape-first-then-substitute is the one
  invariant that makes this safe: after escaping, the only literal `<...>`
  tags in the output are the four the renderer's own code inserted, never
  substrings that arrived in `data`.
- `log-tail` — `{"lines": [str, ...]}`, plain-escaped, rendered `<pre>`,
  capped at `MAX_LIST_ITEMS = 200` (mirrors `bin/lib/watch_data.py`'s
  `read_feed(root, limit=200)` — the existing precedent for "how many trail
  lines is enough for a live dashboard, not a scrollback log").

**`source` (a job-supplied shell command the server runs on refresh) is
OUT of Wave 4, on purpose — not deferred, rejected.** Every existing safe
action in Decision 4 is a FIXED, hardcoded argv the UI's own author wrote
once and audited (`save-checkpoint`, `hook-toggle`, …); a job-authored
`source` string inverts that: it would make the loopback server itself
execute an untrusted, timer-driven command supplied by whichever process can
write a file under `.heimdall/ui/panels/` — i.e., any coding agent with
filesystem access to the repo. That is a straight escalation from "can write
a JSON file" to "gets unattended, recurring code execution as the operator's
own user," which is exactly the class of thing Decision 1's zero-toolchain
stance and Decision 4's allowlist-only stance exist to prevent, and it is
the loopback-server-side mirror of "the browser never executes job-provided
code." A job that wants "graph my database" already has a shell (it's an
`hmd` agent) — it runs its own query and writes the *numbers* to `data`.
Presence of a `source` key in a panel file is itself a hard validation
failure: the WHOLE panel is rejected (nothing partially honored), matching
`bin/heimdall-activity`'s own "reject, not truncate" posture for a
secret-shaped field.

**Size caps, staleness, one-writer-per-file, scrub, cleanup** (defaults,
enforced server-side, never trusted from the file alone):

- `MAX_FILE_BYTES = 65536` per panel file.
- `MAX_TITLE_CHARS = 120` (mirrors `bin/heimdall-activity`'s own
  `SCRUB_MAX=120` bound on a task/files field).
- `MAX_STRING_CHARS = 500` per leaf string value inside `data` (a table
  cell, a log-tail line, a markdown body, a series/bar label).
- `MAX_LIST_ITEMS = 200` per list (table rows, timeseries points-per-series,
  log-tail lines, kv rows) — same `read_feed(limit=200)` precedent as above.
- `id` must match `^[A-Za-z0-9_-]{1,64}$` (filename-safe, becomes `<id>.json`
  — no path traversal via the id itself).
- **Staleness display:** every panel carries `updated_at` (unix epoch,
  required); the server flags a panel `stale: true` once
  `now - updated_at > max(refresh_s * 3, 30)` seconds. `refresh_s` is
  advisory only — it never changes the server's own fixed 2s poll cadence
  (Decision 2); it only tunes when a panel greys out as "not being kept
  current."
- **One writer per file:** by convention the file's `id` names its owner (a
  task-scoped id, e.g. `<task-id>-progress`); concurrency safety is atomic
  replace — write to `<id>.json.<pid>.tmp`, then `os.replace` into place —
  mirroring the exact tmp-suffix-then-atomic-rename convention
  `bin/heimdall-presence` already uses for `.roster-cache.json.<pid>.tmp`
  (its own comment: "produced by piping THIS script's own `roster --json`");
  a stale orphaned `.tmp` from a crashed writer is reaped the same way that
  file's own reaper does, never touching the live `.json`.
- **Secret scrub (reuse, not reinvent):** before a panel is ever added to
  `/api/state`'s `panels` array, every string leaf (`title`, and every
  string inside `data` — table cells, kv values, markdown text, log-tail
  lines, series/bar labels; NOT numeric x/y values) is checked against
  `bin/heimdall-activity`'s own secret-shaped-field rejection — call it, cite
  it by name, do not re-derive a second regex family: `secret_shaped()` /
  `reject_if_secret()` (`bin/heimdall-activity:167-191`, the same
  gitleaks-pattern-plus-assigned-credential-shape check already gating the
  git-tracked activity record). A hit rejects the WHOLE panel (fail-closed,
  logged to stderr naming the field, never the value) — it never renders
  partially.
- **Deletion when the job ends:** `hmd ui panel rm <id>` is the clean path.
  For a job that crashes without calling it, a panel whose `updated_at` age
  exceeds `PANEL_TTL_SECONDS = 86400` (24h) is auto-deleted by the server on
  its next poll — the same heartbeat-plus-TTL-then-reap shape
  `bin/heimdall-activity`'s own liveness check already uses for an activity
  record, applied here to panels so an abandoned job's tile doesn't linger
  forever.

**Rejected — arbitrary HTML panels:** the browser would receive job-authored
markup rendered into the SAME origin as the operator's authenticated
dashboard tab, where Decision 5's token already lives in page JS scope — any
HTML injection is a same-origin token-theft/XSS vector. A closed type set
the static page already knows how to render, with untrusted data never
reaching `innerHTML` unescaped, is the only way to keep the interpreter
fixed and the data untrusted, which is the whole point of "the browser
never executes job-provided code."

**Rejected — iframe of a job-run server:** re-introduces Decision 1's
rejected per-job Node/service problem (every job stands up its OWN local
HTTP server, defeating "in-situ, zero setup, no new daemon"), multiplies the
auth surface (each iframed server needs its own token/Host-allowlist story
or inherits none), and breaks Decision 2's single digest-diffed SSE loop —
each iframe is a separate live connection outside that discipline entirely.

**Rejected — agent-generated React:** the "arbitrary code" problem in a
fancier wrapper, plus a per-panel build step Decision 1 already rejected at
the server level. The entire value of a closed type set is that the
RENDERER is fixed code the UI's own author wrote once and can audit — never
code a job supplies, however small the framework.

**Threat model.** A malicious or merely confused agent can write ANY bytes
to `.heimdall/ui/panels/<id>.json` — that is the whole trust boundary; the
file is data, not code, so the question is only "what can bad data make the
renderer do." Bounded by: (1) the closed `type` set — an unrecognized `type`
is refused, so a job cannot invent an eighth rendering mode; (2) inline
`data` only, no `source` — a job cannot make the SERVER execute anything,
only display something; (3) escape-first-then-substitute for `markdown` and
plain-escape everywhere else — a job cannot make the BROWSER execute
anything either, because no job-supplied byte sequence can produce a literal
`<script>`/`onerror=`/`javascript:` tag in the DOM (the four `markdown`
substitutions are inserted by the renderer's own code against
already-escaped text, never by concatenating raw job bytes into HTML); (4)
size caps — a job cannot exhaust memory or make one panel unreadable by
flooding it with rows/points/bytes; (5) the secret scrub — a job cannot use
the panel channel to smuggle a credential into a surface a teammate's
browser can read, closing the same class of leak `bin/heimdall-activity`
already closes for the activity record. This is the same posture the 2026-08-25
OmniRoute finding established for the base UI (loopback is not "only me" —
a confused OR actively hostile local peer is the threat, not a hypothetical
external attacker), applied to job-authored *data* instead of job-authored
*requests*.

**Publish API.** `hmd ui panel set <id> --type <t> --title <s> --data-json
<file|-> [--refresh-s N]` and `hmd ui panel rm <id>`, as a subcommand of the
already-landed `bin/heimdall-ui` launcher (a guard clause ahead of its
existing flag parser: `if [ "${1:-}" = "panel" ]; then shift; exec "$PY"
"$LIB_DIR/companion_ui_panels.py" "$@"; fi`, reusing the SAME `hmd_python()`
resolution Wave 1 already sources — no new bin/ file, no duplicated
interpreter-resolution logic). `--data-json -` reads from stdin so a job can
pipe a `jq` transform straight in. Validation/scrub/write/remove live in one
new shared module, `bin/lib/companion_ui_panels.py`, imported by BOTH the
CLI path above and `sentinels/hmd-ui.py`'s panel-serving code — exactly one
place the type-set/cap/scrub rule lives, mirroring Decision 4's own
"one place this rule lives" reasoning for the hook-toggle lock check. How an
`hmd:coder` learns this exists: a new subsection named **"Job UI Panels"**
in `agents/coder.md` (placed after its existing "## Pattern Discipline"
section, ~line 126) — named here, not written here, per this cycle's
write-only-two-files instruction.

**No CONFLICT with the zero-toolchain posture.** Validation/scrub/serving
stays pure Python stdlib (`json`, `re`, `os`, `hashlib`, `time`) — no new pip
package, matching Decision 1. The worked examples below use `sqlite3` and
`jq`; neither is a new dependency of the `hmd` *install* — `jq` is already
relied on throughout this very plan's own Wave 1/2 acceptance criteria and
test tasks, and a real "graph my database" job would use whatever DB client
the operator's own project already has, not one `hmd` ships.

## 4. Data contract — the exact JSON `GET /api/state` and each SSE `data:` frame carry

```json
{
  "schema_version": 1,
  "ts": 1758276286.0,
  "repo": "/Users/rj/Downloads/heimdall",
  "identity": { "handle": "rj", "haid": "haid:rj.rishabhs-macbook-air-46d5", "branch": "main" },
  "ledger": {
    "daemon": "down",
    "gates": [ { "id": "string", "state": "pass|running|deny", "detail": "string" } ],
    "verdict": { "state": "pass|running|deny", "label": "string" } | null,
    "team": [ { "user": "string", "sigil": "string", "branch": "string", "state": "string", "ts": 0 } ],
    "team_overflow": 0
  },
  "roster": [ { "haid": "string", "handle": "string", "branch": "string", "project": "string", "state": "active|idle", "verdict": "string|null", "online": true, "age_seconds": 0.0 } ],
  "quality_gate": { "clear_to_push": false, "reason": "GATE FAILED: sweep receipt is STALE ..." },
  "sweep_receipt": { "finished_at": "2026-09-19T09:04:46Z", "head_sha": "string", "tree_clean": true, "suites_total": 412, "suites_passed": 412, "suites_failed": 0, "duration_s": 1037 } | null,
  "hooks": [ { "id": "string", "event": "string", "locked": true, "enabled": true, "description": "string" } ],
  "fallback": { "state": "coop|full_switch", "target_provider": "string" },
  "parallelism": { "batched": 0, "turns": 0, "ratio": 0.0, "calls": 0, "agent_calls": 0, "agent_batched": 0 },
  "checkpoint": { "branch": "string", "head": "string", "phase": "string", "uncommitted_files": 0, "push_gate_open_warning": "string|null" } | null,
  "reels": [ { "name": "string", "mtime": 0.0 } ]
}
```

Field provenance (every field traces to Inventory §2 — nothing invented):
`ledger.*` = `hmd_ledger.read_status()` verbatim; `roster` =
`watch_data.read_roster()` verbatim; `quality_gate` = parsed exit code +
stdout of `heimdall-state check-quality-gates`; `sweep_receipt` = raw parse of
`.heimdall/receipts/last-sweep.json`; `hooks` = raw parse of
`heimdall-hooks list --json` stdout; `fallback` = the `state`/`target_provider`
keys only, filtered out of the full `heimdall-fallback status --json` object
(never forward `operator_key_configured`, `endpoint`, `config_path` — see Risk
table); `parallelism` = regex-parsed from `parallelism-tracker grade`'s one
line; `checkpoint` = a small mechanically-extracted summary of
`.planning/CHECKPOINT.md`'s auto-checkpoint block header fields (Branch, HEAD,
Phase, Uncommitted files, Open warnings) — never the free-text body; `reels`
= a directory listing of `.planning/reels/` (name + mtime only).

**Wave 4 addendum:** `GET /api/state` and every SSE frame additionally carry
a top-level `"panels": [ { "id", "title", "type", "data", "refresh_s",
"updated_at", "stale": bool } ]` array — see Decision 6. `panels` is ADDITIVE
(a Wave 1-3 consumer that ignores unknown top-level keys keeps working
unmodified); provenance = `bin/lib/companion_ui_panels.py`'s `read_panels()`,
never a raw directory listing of `.heimdall/ui/panels/` served as-is.

## 5. Screens (wireframe-text, single page, no routing)

```
┌─ hmd ui ─────────────────────────────────────── ● live (2s) ──┐
│  ⛭ HEIMDALL   rj · haid:rj.rishabhs-macbook-air-46d5 · main   │
├─────────────────────────────────────────────────────────────┤
│  GATE VERDICT           QUALITY GATE (push)      SWEEP        │
│  ✓ pass / ▶ running /   ✓ clear to push /        412/412      │
│  ✗ deny  — label        ✗ GATE FAILED: <reason>  1037s         │
├─────────────────────────────────────────────────────────────┤
│  GATES (ledger.gates[])            │  TEAM (roster[])          │
│  ✓ secrets 0                       │  ● rj      main  active   │
│  ✓ tests 41/41                     │  ○ ana     wip   idle     │
│  ▶ designmatch .91                 │  +2 more                  │
├─────────────────────────────────────────────────────────────┤
│  HOOKS (locked = greyed, no toggle)                            │
│  [locked] secret-paste-filter      UserPromptSubmit    ON      │
│  [       ] caveman-level-context   UserPromptSubmit    ON  ⏻   │
│  [locked] bash-gate-chain          PreToolUse          ON      │
├─────────────────────────────────────────────────────────────┤
│  CHECKPOINT                         │  ACTIONS (Wave 2)        │
│  branch main · HEAD b43c4f4b        │  [ Save checkpoint ]     │
│  phase unknown · 1 uncommitted      │  [ View last receipt ]   │
│  ⚠ push gate RED                    │  [ Open latest reel ]    │
├─────────────────────────────────────────────────────────────┤
│  PARALLELISM  12 batched / 57 turns (0.21) · agents: 2 calls   │
└─────────────────────────────────────────────────────────────┘
```

One page, no client-side router, no framework — a handful of `<section>`s
updated in place by one `EventSource.onmessage` handler that does a shallow
diff-and-patch by field, matching the data contract 1:1 (field name → DOM id).

## 6. Wave plan

Sizes: S = ≤1 day / ≤5 files, M = 1-3 days / 6-10 files, L = >3 days (would
require splitting per the architect's own >3-day rule — none of these
waves reaches L).

### Wave 0 — Invariant ledger (S) — MUST land before Wave 1 code

- **Task:** `companion-ui-invariants`
- **Wave:** 0
- **Dependencies:** none
- **Agent:** `hmd:docs-writer`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `sentinels/hmd_ledger.py:1-60,476-520`, `bin/lib/watch_data.py:1-30,80-135,175-220`, `bin/heimdall-hooks:1-60`, `bin/heimdall-checkpoint:1-40`, this file's §4 (data contract)
- **Files:** Create: `evals/oracles/companion-ui/INVARIANTS.md`, `evals/oracles/companion-ui/COVERAGE.md`
- **Skills:** `superpowers:writing-plans`
- **Patterns:** `docs/superpowers/plans/2026-07-13-statusline-v1-fullbleed.md`'s wave-0 invariants-ledger task (same shape, same repo)
- **Acceptance criteria:**
  - [ ] `test -f evals/oracles/companion-ui/INVARIANTS.md`
  - [ ] `grep -q "schema_version" evals/oracles/companion-ui/INVARIANTS.md`
  - [ ] `grep -q "127.0.0.1" evals/oracles/companion-ui/INVARIANTS.md`
  - [ ] `grep -q "Host header" evals/oracles/companion-ui/INVARIANTS.md`
  - [ ] `grep -qi "digest" evals/oracles/companion-ui/INVARIANTS.md`
  - [ ] `test -f evals/oracles/companion-ui/COVERAGE.md`
- **Done when:** the exact JSON contract (§4), the auth rule (token + Host allowlist + loopback bind), the digest-diff SSE emission rule, and the safe-action allowlist (Decision 4) are transcribed as checkable statements, not prose.
- **Risks & Mitigation:** see table below (`INV-drift`).

### Wave 1 — Local-only MVP (S)

- **Task:** `companion-ui-server-core`
- **Wave:** 1
- **Dependencies:** `companion-ui-invariants`
- **Agent:** `hmd:coder`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `evals/oracles/companion-ui/INVARIANTS.md`, `bin/lib/cp_server.py:1-60,120-140`, `sentinels/hmd_ledger.py:476-520`, `bin/lib/watch_data.py:80-135`, `bin/heimdall-watch-tui` (whole file, 55 lines), `bin/lib/hmd-python.sh` (whole file), `bin/heimdall:2358-2372`
- **Files:** Create: `bin/heimdall-ui`, `sentinels/hmd-ui.py`, `sentinels/hmd-ui.html`. Modify: `bin/heimdall` (add a `ui)` case block immediately after the `watch)` case, i.e. after line 2372, mirroring its structure exactly: resolve `$PLUGIN_DIR/bin/heimdall-ui`, `exec` it with forwarded args, same missing-bin error message shape).
- **Skills:** none (mechanical port of an existing pattern; no external research needed)
- **Patterns:** `bin/lib/cp_server.py:1-40` (pure-dispatch/socket-wrapper split), `bin/lib/watch_data.py:96-176` (`read_roster`/`read_feed`/`_confined_realpath`, reused by import, not copied), `bin/heimdall-watch-tui` (bash launcher shape: resolve python, check entry file exists, `exec`)
- **Acceptance criteria:**
  - [ ] `test -x bin/heimdall-ui`
  - [ ] `test -f sentinels/hmd-ui.py`
  - [ ] `test -f sentinels/hmd-ui.html`
  - [ ] `grep -q "ui)" bin/heimdall`
  - [ ] `grep -q "import.*watch_data\|from watch_data\|watch_data\." sentinels/hmd-ui.py` (proves data-layer reuse, not re-implementation)
  - [ ] `grep -q "hmd_ledger" sentinels/hmd-ui.py`
  - [ ] `grep -q "127.0.0.1" sentinels/hmd-ui.py`
  - [ ] `grep -q "compare_digest" sentinels/hmd-ui.py`
  - [ ] `grep -qi "Host" sentinels/hmd-ui.py`
  - [ ] `bash -n bin/heimdall-ui` exits 0 (shell syntax check)
  - [ ] `python3 -c "import ast; ast.parse(open('sentinels/hmd-ui.py').read())"` exits 0
- **Done when:** `hmd ui` starts a loopback-only server on a free port, prints a URL carrying a random token, serves `index.html` at `/`, serves the §4 JSON at `/api/state`, and pushes digest-diffed frames on `/api/events`.
- **Risks & Mitigation:** see table (`token-leak-via-referrer`, `port-collision`).

- **Task:** `companion-ui-oracle-test`
- **Wave:** 1 (sequenced after `companion-ui-server-core` completes; NOT the same wave-parallel slot — the file `test/heimdall-ui.test.sh` is disjoint from Wave 1's file set, so it is listed as `id: 2` in `waves.json` to keep author≠tester separation explicit even though both carry `"wave": 1` conceptually here)
- **Dependencies:** `companion-ui-server-core`, `companion-ui-invariants`
- **Agent:** `hmd:test-runner` (deliberately NOT `hmd:coder` — this is the independent-reference author; see Risk `impl-authored-gate`)
- **Model + effort:** `sonnet` + `default`
- **Read first:** `evals/oracles/companion-ui/INVARIANTS.md` and this PLAN's §4 data contract ONLY — explicitly do not read `sentinels/hmd-ui.py`'s implementation before writing assertions, so the test is derived from the CONTRACT, not from whatever the implementation happened to do
- **Files:** Create: `test/heimdall-ui.test.sh`, `test/fixtures/companion-ui/` (a minimal fixture repo dir: `.heimdall/receipts/last-sweep.json`, `.heimdall/.roster-cache.json`, `.planning/CHECKPOINT.md`, each with one planted, known, distinctive value, e.g. `"suites_total": 999`)
- **Skills:** `superpowers:systematic-debugging` (only if the first run doesn't go red-then-green as expected)
- **Patterns:** `test/heimdall-watch-live.test.sh:83-84` (the `TIMEOUT="$(command -v timeout || command -v gtimeout || true)"` macOS-portable pattern — this repo already solves the "macOS has no `timeout`" problem this way, reuse verbatim)
- **Acceptance criteria** (every line below IS the test script's own body — each must independently exit 0 when run against a correct server, and the script overall must exit 0):
  - [ ] `PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')` picks a free port
  - [ ] server started against `test/fixtures/companion-ui/` via `HEIMDALL_WATCH_ROOT=test/fixtures/companion-ui bin/heimdall-ui --port "$PORT" --no-open` backgrounded; script captures the printed token
  - [ ] `curl -sf "http://127.0.0.1:$PORT/api/state"` (NO token) returns HTTP 401 — asserted via `curl -s -o /dev/null -w '%{http_code}'` == `401`
  - [ ] `curl -sf -H "X-Heimdall-UI-Token: $TOKEN" "http://127.0.0.1:$PORT/api/state"` returns HTTP 200 and `jq -e '.sweep_receipt.suites_total == 999'` (the PLANTED fixture value — proves the response is DERIVED from the fixture, not a hardcoded/tautological stub)
  - [ ] `curl -sf -H "Host: evil.example" -H "X-Heimdall-UI-Token: $TOKEN" "http://127.0.0.1:$PORT/api/state"` returns HTTP 403 (Host-header allowlist rejects a foreign Host even with a valid token)
  - [ ] SSE sequence check: open `curl -N -H "X-Heimdall-UI-Token: $TOKEN" "http://127.0.0.1:$PORT/api/events"` in the background (bounded by `${TIMEOUT:+$TIMEOUT 8s}`, or a `read -t 8` loop if neither `timeout` nor `gtimeout` exists), capture the FIRST `data:` frame, assert `jq -e '.sweep_receipt.suites_total == 999'` on it; THEN mutate the fixture's `last-sweep.json` to `"suites_total": 111`, wait 3s (> the 2s poll), capture the SECOND `data:` frame, assert `jq -e '.sweep_receipt.suites_total == 111'` — this is the falsifiability proof: a server that caches/never re-reads, or that fabricates the field, fails this exact assertion
  - [ ] teardown: `kill "$SERVER_PID"` and `wait "$SERVER_PID" 2>/dev/null`; script exits 0 only if every assertion above passed
- **Oracle gate:** No `evals/oracles/registry.json` domain matches this target (`jq -r '.oracles|keys[]' evals/oracles/registry.json` lists `emulator-gb, exchange-lob, issue-collection, ponytail-underdelivery, rr-multitenant-isolation, symbol-reuse, team-checkpoint, team-copilot, triage-coord` — none is a UI/dashboard/local-server domain). Flagged per Oracle-Gate Protocol point 3 for a reviewer to decide whether `companion-ui` (or a general `local-http-tool` domain) belongs in the registry. In its absence, the gate above is an INDEPENDENTLY-AUTHORED falsifier: `gate_type` is `example`+`verdict` (planted-value assertions + HTTP status codes), sequenced across two states (before/after fixture mutation) so it cannot pass by construction — a server that always returns the SAME cached value fails the second assertion, and a server with no auth fails the 401/400 assertions. `independent: true` — authored by `hmd:test-runner` in a separate wave-slot from `hmd:coder`'s `companion-ui-server-core`, reading only the contract (§4) and the invariant ledger, never the implementation.
- **Verify:** `bash test/heimdall-ui.test.sh`
- **Done when:** the test exits 0 against a correct server and is proven capable of going red (run it once against a deliberately-broken server — e.g., temporarily hardcode `suites_total: 999` as a constant instead of a file read — and confirm the second SSE assertion fails, per the falsifiability requirement; this manual proof run is NOT itself committed, it's a one-time check the task performs before marking done).
- **Risks & Mitigation:** see table (`impl-authored-gate`, `flaky-2s-poll-timing`).

### Wave 2 — Safe actions + hooks toggle (M)

- **Task:** `companion-ui-actions`
- **Wave:** 2
- **Dependencies:** `companion-ui-server-core`, `companion-ui-oracle-test` (must be green before adding write-capable surface)
- **Agent:** `hmd:coder`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `evals/oracles/companion-ui/INVARIANTS.md`, `bin/lib/watch_data.py:236-270` (`build_shell_argv`, `_safe_ref`, `_REF_RE`), `bin/heimdall-checkpoint:1-40`, `bin/heimdall-hooks:1-50`, this PLAN's Decision 4
- **Files:** Create: `bin/lib/companion_ui_actions.py` (the allowlist dispatch: `{"save-checkpoint","view-receipt","hook-toggle","open-reel"}` → argv, mirroring `watch_data.build_shell_argv`'s allowlist-then-`--`-terminator pattern verbatim for `hook-toggle`'s `<id>` argument). Modify: `sentinels/hmd-ui.py` (add `POST /api/action` route, importing `companion_ui_actions.dispatch`), `sentinels/hmd-ui.html` (add the 3-button Actions panel + hook-toggle switches, wire to `fetch('/api/action', {method:'POST', headers:{'X-Heimdall-UI-Token':TOKEN}, body: JSON.stringify({action, params})})`).
- **Skills:** none
- **Patterns:** `bin/lib/watch_data.py:255-283` (`build_shell_argv` — the exact allowlist-and-terminator shape to copy for the new action set)
- **Acceptance criteria:**
  - [ ] `grep -q "ALLOWED_ACTIONS" bin/lib/companion_ui_actions.py`
  - [ ] `grep -q '"save-checkpoint"' bin/lib/companion_ui_actions.py`
  - [ ] `grep -q '"hook-toggle"' bin/lib/companion_ui_actions.py`
  - [ ] `grep -q -- "--\", ref\|'--', ref\|\"--\"" bin/lib/companion_ui_actions.py` (proves the `-- <ref>` terminator pattern is present for the id-consuming action)
  - [ ] `python3 -c "import ast; ast.parse(open('bin/lib/companion_ui_actions.py').read())"` exits 0
  - [ ] `bash test/heimdall-ui-actions.test.sh` exits 0 (a sibling test, same author-independence rule as Wave 1: written by `hmd:test-runner` in a follow-on task `companion-ui-actions-test`, disjoint file, asserting: an unknown action returns 422 and RUNS NOTHING (assert via a marker file that a fake "action" would have touched, confirming it wasn't touched); `hook-toggle` on a LOCKED id returns the CLI's exit-2 as an HTTP 409, not a silent 200; `hook-toggle` on an advisory id actually flips `bin/heimdall-hooks list --json`'s `enabled` field)
- **Done when:** the 4 safe actions work end-to-end from the browser and every never-exposed surface (routing/fallback, git push/commit, team secret, locked hooks) is provably unreachable through `/api/action` (422 on anything not in `ALLOWED_ACTIONS`).
- **Risks & Mitigation:** see table (`action-allowlist-bypass`).

### Wave 3 — Remote via SSH port-forward (S/M)

- **Task:** `companion-ui-remote`
- **Wave:** 3
- **Dependencies:** `companion-ui-server-core`
- **Agent:** `hmd:coder`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `bin/heimdall-ui` (as landed in Wave 1), this PLAN's Decision 3
- **Files:** Modify: `bin/heimdall-ui` (add `--remote user@host [--remote-port N]` flag handling: pick a local free port, `ssh -N -L "$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" "$REMOTE_HOST" "hmd ui --port $REMOTE_PORT --print-url-only --no-browser" &`, capture the remote-printed URL's token off the SSH session's stdout via a FIFO or `ssh ... 2>&1 | tee`, rewrite the port in that URL to `$LOCAL_PORT`, open it locally).
- **Skills:** none
- **Patterns:** none new — this is additive flag-parsing on top of Wave 1's launcher, no new architecture
- **Acceptance criteria:**
  - [ ] `grep -q -- "--remote" bin/heimdall-ui`
  - [ ] `grep -q "ssh -N -L\|ssh -L" bin/heimdall-ui`
  - [ ] `bash -n bin/heimdall-ui` exits 0
  - [ ] `bash test/heimdall-ui-remote.test.sh` exits 0 — **conditional test**: if `command -v ssh` and a local `sshd` answering on `127.0.0.1:22` are both present (checked via `ssh -o BatchMode=yes -o ConnectTimeout=2 127.0.0.1 true`), runs a real self-loopback SSH tunnel (`ssh 127.0.0.1` as the "remote") and asserts the forwarded local port serves the same `/api/state` JSON as a direct local run; if either precondition is absent, the test SKIPS with exit 0 and a printed reason (never a hard fail for an environment without sshd — this is the descoped/expected-skip row in the coverage matrix below, not a silent pass-by-omission: it prints exactly why)
- **Done when:** `hmd ui --remote user@host` opens a local browser tab showing a remote machine's live state, with the remote server still bound to its own loopback only.
- **Risks & Mitigation:** see table (`ssh-forward-orphan-process`, `ci-no-sshd`).

### Wave 4 — Job panels (job-published dashboard tiles) (M)

- **Task:** `companion-ui-panel-invariants`
- **Wave:** 4a
- **Dependencies:** `companion-ui-invariants` (Wave 0)
- **Agent:** `hmd:docs-writer`
- **Model + effort:** `sonnet` + `default`
- **Read first:** this PLAN's Decision 6 (verbatim), `evals/oracles/companion-ui/INVARIANTS.md`, `bin/heimdall-activity:1-40,155-192` (`secret_shaped`/`reject_if_secret`/`SCRUB_MAX`), `bin/lib/watch_data.py:174-193` (`read_feed`'s 200-line cap precedent)
- **Files:** Create: `evals/oracles/companion-ui/PANEL-INVARIANTS.md`. Modify: `evals/oracles/companion-ui/COVERAGE.md` (append the job-panels rows from §7 below).
- **Skills:** `superpowers:writing-plans`
- **Patterns:** the existing `evals/oracles/companion-ui/INVARIANTS.md` (same transcribe-the-contract shape, not prose)
- **Acceptance criteria:**
  - [ ] `test -f evals/oracles/companion-ui/PANEL-INVARIANTS.md`
  - [ ] `grep -q "kv|table|number|timeseries|bars|markdown|log-tail" evals/oracles/companion-ui/PANEL-INVARIANTS.md`
  - [ ] `grep -qi "source" evals/oracles/companion-ui/PANEL-INVARIANTS.md` (the reject-`source` rule must be transcribed)
  - [ ] `grep -qi "secret_shaped\|reject_if_secret" evals/oracles/companion-ui/PANEL-INVARIANTS.md`
  - [ ] `grep -qi "65536\|MAX_FILE_BYTES" evals/oracles/companion-ui/PANEL-INVARIANTS.md`
  - [ ] `grep -qi "job panel" evals/oracles/companion-ui/COVERAGE.md` (proves COVERAGE.md was actually updated, not just the invariants doc created standalone)
- **Done when:** the closed type set, the `source`-is-rejected rule (with the RCE reasoning), every size cap, the staleness formula, the one-writer-per-file atomic-write convention, the secret-scrub reuse, and the 24h TTL cleanup rule are transcribed as checkable statements.
- **Risks & Mitigation:** see table (`INV-drift` — same row as Wave 0, this is its Wave-4 instance).

- **Task:** `companion-ui-panels`
- **Wave:** 4b
- **Dependencies:** `companion-ui-panel-invariants`, `companion-ui-server-core` (Wave 1), `companion-ui-actions` (Wave 2 — sequencing only: both tasks modify `sentinels/hmd-ui.py`/`sentinels/hmd-ui.html`, so this task must land after Wave 2's edits exist, not because of any semantic dependency), `companion-ui-remote` (Wave 3 — sequencing only: both tasks modify `bin/heimdall-ui`)
- **Agent:** `hmd:coder`
- **Model + effort:** `sonnet` + `default`
- **Read first:** `evals/oracles/companion-ui/PANEL-INVARIANTS.md`, this PLAN's Decision 6, `bin/heimdall-ui` (as landed through Wave 3), `sentinels/hmd-ui.py` (as landed through Wave 2), `bin/lib/watch_data.py:174-283` (`read_feed`, `_confined_realpath`, `_safe_ref`, `build_shell_argv`), `bin/heimdall-activity:1-40,155-192`, `bin/heimdall-presence:275-304` (the `.roster-cache.json.<pid>.tmp` atomic-write-and-reap precedent to mirror)
- **Files:** Create: `bin/lib/companion_ui_panels.py` (constants `PANEL_TYPES`, `MAX_FILE_BYTES=65536`, `MAX_TITLE_CHARS=120`, `MAX_STRING_CHARS=500`, `MAX_LIST_ITEMS=200`, `MAX_SERIES=6`, `PANEL_TTL_SECONDS=86400`, `ID_RE`; functions `secret_shaped(v)` ported from `bin/heimdall-activity:167-179`, `validate_panel(obj)`, `write_panel(root,id,obj)` (atomic tmp+rename), `remove_panel(root,id)`, `read_panels(root,now=None)` (drops invalid/secret-shaped/TTL-expired, annotates `stale`), and a `if __name__=="__main__":` CLI implementing `set <id> --type T --title S --data-json FILE_OR_DASH [--refresh-s N]` and `rm <id>`). Modify: `bin/heimdall-ui` (add the `panel` subcommand guard clause immediately after `hmd_python()`/`$PY` is resolved, before existing flag parsing: `if [ "${1:-}" = "panel" ]; then shift; exec "$PY" "$LIB_DIR/companion_ui_panels.py" "$@"; fi`). Modify: `sentinels/hmd-ui.py` (import `companion_ui_panels`, add its `read_panels(root)` output as the `panels` key in `collect_state()`'s return dict; each poll tick, in-process — no subprocess — call `companion_ui_panels.write_panel(root, "hmd-live-users", {...})` with `data.value = len(state["roster"])`, `type="number"`, `title="hmd — live users"`, `updated_at=now`, dogfooding the same publish path an agent uses). Modify: `sentinels/hmd-ui.html` (add a generic panel-rendering section: one render function per `type` in `PANEL_TYPES`, the `markdown` renderer implementing escape-first-then-substitute exactly as specified in Decision 6, `timeseries`/`bars` colors assigned via the `dataviz` skill's fixed categorical order up to `MAX_SERIES`, `number`'s `delta` colored via `dataviz`'s status palette).
- **Skills:** `dataviz` (for the `timeseries`/`bars`/`number`-delta color and form choices — invoke it before writing the chart-rendering code, not after)
- **Patterns:** `bin/summary-card` (label/value row convention for `kv`), `bin/lib/watch_data.py:174-193,255-283` (list-cap and allowlist-argv shapes), `bin/heimdall-presence:275-304` (tmp-suffix atomic-write-and-reap)
- **Acceptance criteria:**
  - [ ] `grep -q "PANEL_TYPES" bin/lib/companion_ui_panels.py`
  - [ ] `grep -q '"kv"' bin/lib/companion_ui_panels.py`
  - [ ] `grep -q "source" bin/lib/companion_ui_panels.py` (proves the reject-on-`source`-key check exists, not merely absent from the schema)
  - [ ] `grep -q "MAX_FILE_BYTES" bin/lib/companion_ui_panels.py`
  - [ ] `grep -q "secret_shaped" bin/lib/companion_ui_panels.py`
  - [ ] `grep -q "os.replace\|os\.rename" bin/lib/companion_ui_panels.py` (atomic write)
  - [ ] `python3 -c "import ast; ast.parse(open('bin/lib/companion_ui_panels.py').read())"` exits 0
  - [ ] `grep -q "panel" bin/heimdall-ui`
  - [ ] `bash -n bin/heimdall-ui` exits 0
  - [ ] `grep -q "companion_ui_panels" sentinels/hmd-ui.py`
  - [ ] `python3 -c "import ast; ast.parse(open('sentinels/hmd-ui.py').read())"` exits 0
  - [ ] `grep -qi "panels" sentinels/hmd-ui.html`
- **Done when:** `hmd ui panel set <id> --type <t> --title <s> --data-json <f>` writes a validated, scrubbed, capped panel file; `GET /api/state`'s `panels` array reflects it within one poll cycle; an unrecognized `type` or a `source` key is refused with nothing written; `hmd-live-users` self-refreshes every poll tick with no agent action required.
- **Risks & Mitigation:** see table (`panel-xss-markdown`, `panel-secret-leak`, `panel-file-overlap`).

- **Task:** `companion-ui-panels-test`
- **Wave:** 4c
- **Dependencies:** `companion-ui-panels`, `companion-ui-panel-invariants`
- **Agent:** `hmd:test-runner` (independent-reference author, same author≠tester rule as `companion-ui-oracle-test`)
- **Model + effort:** `sonnet` + `default`
- **Read first:** `evals/oracles/companion-ui/PANEL-INVARIANTS.md` and this PLAN's Decision 6 ONLY — do not read `bin/lib/companion_ui_panels.py`'s implementation before writing assertions
- **Files:** Create: `test/heimdall-ui-panels.test.sh`, `test/fixtures/companion-ui-panels/` (a planted valid panel file + planted invalid fixtures used inline by the script)
- **Skills:** `superpowers:systematic-debugging`
- **Patterns:** `test/heimdall-ui.test.sh` (hermetic HOME/HEIMDALL_HOME redirection, token-capture pattern), `test/heimdall-watch-live.test.sh:83-84` (macOS `timeout`/`gtimeout` portability)
- **Acceptance criteria** (every line below is the test script's own body):
  - [ ] `hmd ui panel set demo --type timeseries --title Demo --data-json -` (via a piped valid `{"x":[...],"y":[...]}`) exits 0 and `test -f .heimdall/ui/panels/demo.json`
  - [ ] a panel JSON with an unrecognized `type` (e.g. `"chart3d"`) is refused: `hmd ui panel set bad --type chart3d ...` exits nonzero and `test ! -f .heimdall/ui/panels/bad.json`
  - [ ] a panel JSON carrying a `"source"` key is refused outright: exits nonzero, file not written
  - [ ] a panel whose `data` contains a secret-shaped string (e.g. `a Stripe-live-shaped token (the sk_live_ prefix followed by 24 alphanumerics -- written out in words here on purpose: GitHub push protection and gitleaks both flag the literal shape, correctly)`) is refused: exits nonzero, file not written, asserted via `bin/heimdall-activity`'s own `secret_shaped` pattern family being the one that fired (cite it, don't reinvent an assertion pattern)
  - [ ] a `markdown` panel whose `data.text` is `"<script>alert(1)</script>"` renders, via `curl` against `/api/state`'s `panels[].data`, WITHOUT a literal `<script>` substring anywhere in the served JSON's rendered HTML fixture check (asserted by starting the server, fetching `/`, and grepping the served page's eventual DOM output for the literal string `<script>alert` — must NOT appear unescaped)
  - [ ] an oversized panel (`data` exceeding `MAX_LIST_ITEMS` rows) is refused
  - [ ] `hmd ui panel rm demo` removes `.heimdall/ui/panels/demo.json` and the next `/api/state` poll no longer lists it
  - [ ] falsifiability proof (performed once, not committed): temporarily comment out the `secret_shaped` call inside a LOCAL COPY of `bin/lib/companion_ui_panels.py`, re-run the secret-shaped-panel assertion above, confirm it goes RED (the panel is wrongly accepted), then discard the edit — report this red-then-green proof in the completion summary
- **Oracle gate:** No `evals/oracles/registry.json` domain matches (same absence as `companion-ui-oracle-test`, flagged per Oracle-Gate Protocol point 3). `gate_type` is `example`+`verdict` (planted-fixture accept/reject pairs plus an XSS-non-execution assertion), `independent: true` (authored by `hmd:test-runner` from `PANEL-INVARIANTS.md` only, in a separate wave slot from `hmd:coder`'s `companion-ui-panels`).
- **Verify:** `bash test/heimdall-ui-panels.test.sh`
- **Done when:** every accept/reject pair above is green, the XSS assertion is green, and the falsifiability proof (secret-scrub disabled → red) has been performed and reported once.
- **Risks & Mitigation:** see table (`impl-authored-gate` — same row as Wave 1's instance, applied here).

## 7. Coverage matrix

| Subsystem | In scope? | Oracle row affected | Expected result |
|---|---|---|---|
| Local read-only state feed (ledger/roster/receipt/hooks/checkpoint) | yes | `companion-ui-oracle-test` (Wave 1) | green |
| Auth (token + Host allowlist + loopback bind) | yes | `companion-ui-oracle-test`'s 401/400 assertions | green |
| SSE digest-diff push | yes | `companion-ui-oracle-test`'s two-frame mutation assertion | green |
| Safe actions (save-checkpoint / view-receipt / hook-toggle / open-reel) | yes | `companion-ui-actions.test.sh` (Wave 2) | green |
| Never-exposed actions (routing, push/commit, secrets, locked hooks) | yes (as a negative test) | `companion-ui-actions.test.sh`'s 422/409 assertions | green |
| Remote via SSH, real two-machine test | descoped this cycle (single-machine CI has no second host) | `companion-ui-remote.test.sh` | **expected-skip** on a machine without a reachable local sshd; expected-green on a machine with one (self-loopback proof only, not a true second host) |
| Public/hosted multi-tenant dashboard | descoped (Decision 3, rejected option c) | none | not built |
| Metrics sparkline (`~/.heimdall/metrics.jsonl`) | descoped this cycle | none | not built — file was empty on this checkout, no live data to render yet |
| Team-mode "view a teammate's remote instance without SSH" | descoped this cycle (Decision 3, rejected option b) | none | not built |
| `evals/oracles/registry.json` canonical domain | descoped — none exists for this target | flagged in `companion-ui-oracle-test`'s Oracle gate field | reviewer decides whether to add a `local-http-tool` or `companion-ui` registry domain |
| Job panels: closed-type render (kv/table/number/timeseries/bars/markdown/log-tail) | yes | `companion-ui-panels-test` (Wave 4) | green |
| Job panels: `source` (agent-supplied shell command) rejection | descoped, permanently (Decision 6, RCE surface) | `companion-ui-panels-test`'s reject-on-`source`-key assertion | green (as an expected-reject, not a built feature) |
| Job panels: secret-scrub / size caps / TTL cleanup | yes | `companion-ui-panels-test` | green |
| `hmd-live-users` self-published number panel | yes | `companion-ui-panels-test` + manual check against `/api/state`'s `roster` count | green |
| Per-panel access control (viewing panel A but not panel B) | descoped this cycle | none | not built — every panel visible to whoever holds the Decision 5 token, same as every other `/api/state` field |
| In-browser panel authoring/editing | descoped (publish is CLI-only, per Decision 6) | none | not built |
| Historical panel data / time-travel across updates | descoped (only the latest `data` per `id` is ever shown) | none | not built |

## 8. Risks

| Risk | Probability | Impact | Mitigation | Owner-task |
|---|---|---|---|---|
| Token leaks via browser `Referer` header if the SPA ever links out to an external URL | low | med | Set `Referrer-Policy: no-referrer` on every response from `companion_ui_server.py`; never place the token in an `<a href>` to a third-party origin | `companion-ui-server-core` |
| Port collision (another local tool already bound the chosen port) | med | low | Launcher binds port 0 (OS-assigned free port) by default unless `--port` is explicit; prints the actual bound port | `companion-ui-server-core` |
| Impl-authored gate (the coder who writes the server also writes a test that shares its misconceptions) | med | high | `companion-ui-oracle-test` is a SEPARATE task assigned to `hmd:test-runner`, reading only the contract (§4) and the invariant ledger, never the server's source, per Oracle-Gate Protocol rule 3 | `companion-ui-oracle-test` |
| 2-second poll window makes the SSE mutation test flaky under CI load | low | med | Test waits 3s (1.5x the poll interval) before asserting the second frame, and retries the read up to 3 times with a 1s backoff before failing | `companion-ui-oracle-test` |
| Hook-toggle action bypasses the locked-id gate through a race or a param the CLI doesn't validate the way the UI assumes | low | high | The UI performs NO local lock-check — every toggle request round-trips through `bin/heimdall-hooks enable/disable`, whose own exit-2 refusal is the single source of truth; the actions test asserts the HTTP layer surfaces that exit-2 as 409, never swallowing it into a 200 | `companion-ui-actions` |
| `fallback.state`/`target_provider` read-only badge is a judgment call — could be seen as leaking routing info | low | low | Field list is explicitly capped to `state`+`target_provider` only (never `operator_key_configured`, `endpoint`, `config_path`); flagged here for the plan-verification reviewer to confirm this framing is acceptable | `companion-ui-invariants` |
| SSH background process (`ssh -N -L ...`) orphaned if the browser/user kills the terminal without `hmd ui --remote` cleaning up | med | low | Launcher writes the SSH child PID to `${HEIMDALL_HOME}/.ui-remote-<port>.pid` and traps `EXIT`/`INT`/`TERM` to kill it; a stale pidfile from a crashed prior run is checked-and-reaped on next `--remote` launch | `companion-ui-remote` |
| No registry oracle domain exists for this target, so the correctness gate is bespoke rather than canonical | med | med | Explicitly flagged in the Oracle gate field and the coverage matrix for a human reviewer to decide on adding a registry domain; the bespoke gate still satisfies falsifiability (two-state mutation proof) even without registry backing | `companion-ui-oracle-test` |
| `.planning/CHECKPOINT.md`'s free-text body could contain something the operator wrote for themselves and didn't expect to see mirrored to a browser tab | low | med | §4's `checkpoint` field is capped to the mechanically-derived header fields (branch/HEAD/phase/uncommitted count/warnings) only — the free-text TL;DR/Completed/blockers prose is never forwarded | `companion-ui-server-core` |
| `panel-xss-markdown`: the `markdown` type's substitution pass reintroduces an XSS vector if implemented as "regex-replace into `innerHTML`" instead of "escape first, substitute only against the already-escaped text" | low | high | Decision 6 states escape-first-then-substitute as the one invariant; `companion-ui-panels-test` plants a literal `<script>alert(1)</script>` in a `markdown` panel and asserts it never appears unescaped in the served page | `companion-ui-panels`, `companion-ui-panels-test` |
| `panel-secret-leak`: a job accidentally writes a live credential into a panel's `data` (e.g. pasting a `.env` value into a `kv` row) | low | high | Every string leaf in `data` (plus `title`) is checked against `bin/heimdall-activity`'s own `secret_shaped()` family before the panel is ever added to `/api/state`; a hit rejects the WHOLE panel, fail-closed | `companion-ui-panels` |
| `panel-file-overlap`: `companion-ui-panels` (Wave 4) and `companion-ui-actions` (Wave 2) / `companion-ui-remote` (Wave 3) all modify `sentinels/hmd-ui.py` and/or `bin/heimdall-ui` | n/a (sequencing, not a live risk) | med if mis-sequenced | Wave 4's task lists Wave 2 and Wave 3 as explicit dependencies for FILE-sequencing reasons even though there is no semantic dependency; it may never run in the same parallel batch as either | `companion-ui-panels` |
| `panel-rce-via-source`: a future contributor re-adds a `source` field "for convenience," reopening the RCE surface Decision 6 explicitly closed | low | high | `companion-ui-panels-test`'s reject-on-`source`-key assertion is a permanent regression guard, not a one-time check — it must stay green across every future change to `bin/lib/companion_ui_panels.py` | `companion-ui-panels-test` |

## 9. The two paths and six decisions, one line each (per brief)

- **Path A (this cycle, chosen):** local stdlib server + one static HTML file, SSE push, SSH-port-forward for remote, four shelled-out safe actions, token+Host-header auth — zero new dependencies, zero new servers, zero hosted surface.
- **Path B (rejected, deferred to NEXT-CYCLES if ever needed):** control-plane-mediated remote view (Decision 3 options b/c) — would let a teammate view another's `hmd` without SSH access, at the cost of a new CP ingest/storage surface and a materially weaker secret boundary; not pursued because SSH already covers every environment this brief's operator uses.
- **Decision 1 (runtime):** python3-stdlib server + one static HTML file — Node/JS toolchain rejected (zero-toolchain posture), static-file-only rejected (no live push possible).
- **Decision 2 (transport):** SSE with digest-diffed 2s polling of the same files the statusline already polls — WebSocket rejected (duplex not needed, no stdlib support), fs-events rejected (new dependency, `watchdog`), MCP-ledger-as-transport rejected (wrong client, no HTTP surface).
- **Decision 3 (remote):** SSH port-forward, server stays loopback-only and transport-unaware — CP-mediated view rejected (new attack surface, thinner data, breaks secret-never-leaves-machine).
- **Decision 4 (actions):** exactly 4 shelled-out safe actions (save-checkpoint, view-receipt, hook-toggle-advisory-only, open-reel) — routing/fallback, push/commit, secrets, and locked hooks are never exposed.
- **Decision 5 (auth):** loopback bind + per-launch random token + Host-header allowlist — bare loopback-only rejected per this repo's own prior OmniRoute audit finding that loopback has no cross-user isolation and is not equivalent to browser-unreachable.
- **Decision 6 (job panels):** a job publishes JSON panel descriptors under `.heimdall/ui/panels/<id>.json` in a closed `kv|table|number|timeseries|bars|markdown|log-tail` type set with inline `data` only — arbitrary-HTML panels, an iframed job-run server, and agent-generated React are all rejected because each reintroduces "the browser (or the server) executes job-provided code," and a job-supplied `source` command is rejected outright as an RCE surface (file-write privilege escalating to unattended, timer-driven code execution).


## Wave 4 worked examples (runnable acceptance-criteria command sequences, per Decision 6)

**(a) "graph my database"** — an agent runs its own query and writes a `timeseries` panel (no `source`, no DB driver added to `hmd`):

```bash
sqlite3 -json /tmp/demo.db "select strftime('%Y-%m-%dT%H:00:00Z',created_at) h, count(*) c from orders group by h order by h" \
  | jq -c '{x:[.[].h], y:[.[].c]}' \
  | HEIMDALL_WATCH_ROOT="$REPO" bin/heimdall-ui panel set db-orders-per-hour \
      --type timeseries --title "Orders / hour" --data-json -
test -f "$REPO/.heimdall/ui/panels/db-orders-per-hour.json"
jq -e '.type=="timeseries" and (.data.x|length)==(.data.y|length)' "$REPO/.heimdall/ui/panels/db-orders-per-hour.json"
```

**(b) "live users of hmd"** — hmd itself republishes this every poll tick from the SAME roster count `/api/state` already computes (no team secret read, no new call — `read_roster()`'s own count):

```bash
# manual proof the publish path works end-to-end with a real presence-derived number:
bin/heimdall-presence roster --json | jq -c '{value: length}' \
  | bin/heimdall-ui panel set hmd-live-users --type number --title "hmd — live users" --data-json -
jq -e '.type=="number" and (.data.value|type=="number") and .data.value>=0' .heimdall/ui/panels/hmd-live-users.json
# the shipped behavior: hmd's own poll loop does this automatically every 2s using
# len(collect_state(root)["roster"]) in-process — never re-reading team.json, never
# a new presence call the operator has to remember to run.
```

**(c) plain progress dashboard for the current task** — `kv` from `.planning/CHECKPOINT.md`'s header + `log-tail` from the task ledger:

```bash
BR="$(git rev-parse --abbrev-ref HEAD)"; HD="$(git rev-parse --short HEAD)"
PH="$(grep -m1 '^Phase:' .planning/CHECKPOINT.md | cut -d: -f2- | sed 's/^ *//')"
jq -cn --arg b "$BR" --arg h "$HD" --arg p "$PH" \
  '{rows:[["Branch",$b],["HEAD",$h],["Phase",$p]]}' \
  | bin/heimdall-ui panel set task-progress --type kv --title "Task progress" --data-json -
jq -e '.type=="kv" and (.data.rows|length)==3' .heimdall/ui/panels/task-progress.json

jq -cs '{lines: (map("\(.active_task // "-") @ \(.branch // "-")") | .[:200])}' \
  .planning/ledger/activity/*.json 2>/dev/null \
  | bin/heimdall-ui panel set task-log --type log-tail --title "Recent activity" --data-json -
jq -e '.type=="log-tail" and (.data.lines|length) <= 200' .heimdall/ui/panels/task-log.json
```


## OUT OF SCOPE

- Building any code this cycle — this PLAN and `companion-ui.waves.json` are the only deliverables; implementation is a future cycle's `hmd:coder`/`hmd:test-runner` work.
- Public or multi-tenant hosting of the UI (Decision 3, option c) — explicitly rejected, not deferred-and-forgotten: see §NEXT-CYCLES note if it ever becomes necessary.
- A general remote-control surface (arbitrary command execution, file editing, git push/commit from the browser) — Decision 4's NEVER-exposed list is final for this plan, not a starting point to expand ad hoc.
- Any new pip/npm dependency (`textual`, `watchdog`, Node, etc.) — Wave 1-3 are all stdlib-only by design.
- Mobile-responsive layout, dark/light theme switching, or any visual polish beyond a single readable desktop-width page — functional MVP only.
- Historical trends/analytics/scrollback (the `hmd watch` freemium-locked features: `history`, `trends`, `analytics`, `archive`, per `bin/lib/watch_data.py`'s `DEFAULT_LOCKED`) — this plan does not touch or duplicate that entitlement boundary.
- Populating `~/.heimdall/metrics.jsonl` or `.planning/reels/` if they are empty on a given machine — the UI renders their absence as an empty state, it does not backfill them.
- Rewriting or extending `hmd watch` (the TUI) — it remains a separate, terminal-native sibling; this plan does not merge or deprecate it.
- Extending `heimdall-ledger-mcp`'s tool surface to serve the browser — Decision 2 explicitly rejects that transport.
- A true two-machine remote test in CI (Wave 3's test is a self-loopback proof only, honestly labeled as such in the coverage matrix).
- A `source` field / job-supplied shell-command panels (Decision 6) — rejected permanently, not deferred: see `panel-rce-via-source` in §8.
- Per-panel access control, in-browser panel authoring/editing, and historical/time-travel panel data (Decision 6 / §7 coverage matrix) — one token sees all panels, publish is CLI-only, only the latest `data` per `id` is ever shown.
- `hmd ui panel list`/`get` convenience read subcommands — the three Wave 4 worked examples above only need `set`/`rm`; a listing subcommand is not required by any acceptance criterion and is not built this cycle.
- Extending `heimdall-ledger-mcp` to serve as the job-panel publish channel — Decision 6 uses a plain CLI + JSON files (one-writer-per-file, matching `.planning/ledger/activity/`'s own per-HAID-file convention), not the MCP server, for the same "wrong client, no HTTP surface, browser can't reach it" reason Decision 2 already gives for the base state feed.

