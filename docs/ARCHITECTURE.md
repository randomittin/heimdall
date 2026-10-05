# Architecture and capabilities

What Heimdall is made of, what each part does, and how it is proven. Moved here verbatim from the README (RP10) so the README can stay a front door; the install disclosure lives in [INSTALL.md](INSTALL.md). Claims below are the same claims the README carried, checked by the same tests.

## Numbers and how to reproduce them

`bin/corpus run` replays the 13 real shipped-failure cases through the same gates and appends a per-version catch-rate row to [`evals/corpus/CORPUS-STATUS.md`](../evals/corpus/CORPUS-STATUS.md) — it writes to the tree, so it is not in the read-only block above. Its current score and the ❌ rows that are kept in view: [`evals/flagship/STATUS.md`](../evals/flagship/STATUS.md).

| Number | Reproduce it |
|---|---|
| **427** test suites | `ls test/*.test.sh \| wc -l` |
| **10,127** assertions passed, **412/412** suites, 0 failed — last full sweep, at commit `b43c4f4b` (suites added since account for 427 on disk) | `bash test/run-all.sh` (~17 min) writes `.heimdall/receipts/last-sweep.json`; then `jq .assertions_passed .heimdall/receipts/last-sweep.json` |
| **13/13** corpus cases caught (100%) | `bin/corpus run` (mutates `CORPUS-STATUS.md`); scoreboard row in [`evals/flagship/STATUS.md`](../evals/flagship/STATUS.md) |
| **1.0** falsifiability on both flagship oracles (6/6, 3/3) | the two `bin/falsify … --assert-score 1.0` commands above |

## Why Heimdall

- **Catches the silent failures** — ordering races, whole-sequence invariants, missing subsystems that pass a naive green suite.
- **Falsifiable gates** — every gate is proven able to go red before it is trusted green. The corpus of real failure cases replays on every change; a regression that once shipped can never ship twice.
- **Proof of correctness, not just generation** — the delta Heimdall sells is the receipt that proves the proof can fail. [Generalizes: 0.50 median reuse across 8 cold repos.](https://runheimdall.dev/proof)
- **Full audit trail** — `hmd report` produces a machine-readable telemetry report of every gate, mutation score, and corpus catch-rate from the last run.

## Get a bot PR on your repo

`rr` is the same gate, run in the cloud: a bot that fixes your GitHub issues and opens a PR whose fix has already passed a check the agent never wrote. You review, you merge. The bot opens it on a `heimdall/*` branch **as a scoped GitHub App** — never as you, never on `main`, and it never self-merges. A human always gates the merge.

Once you've installed the Heimdall Maintainer GitHub App on your repo and run `claude setup-token`, it's two commands:

```bash
rr connect                                    # registers your App install + captures your Claude cred
rr "fix the flaky test in payments and open a PR"
```

**What happens:** `rr` signs your task with your own Ed25519 key and enqueues it. A gated worker clones your repo with **your team's** Claude subscription and **your** GitHub App installation, runs the issue-resolution loop until the fix passes the gates, and opens a `heimdall/*` PR on your repo. You review it. You merge it.

**Nothing to paste — no token, no URL.** The public control plane is baked in and enrollment is automatic: your first signed call registers this device on first use. Just `rr connect` and go. (Running your own deployment, or need to re-gate enrollment behind a bootstrap token? That's an operator concern — see [`OPERATORS.md`](../OPERATORS.md).)

### Why it's safe to point at your repo

- **Tenant isolation is a falsifiable oracle, not a promise.** Every cross-tenant attack — IDOR by repo slug, cred read across teams, queue drain, installation-id swap, signed-request replay — has a named invariant and a red-line mutant test. Drop any gate and [`test/heimdall-cp-authz-gate.test.sh`](../test/heimdall-cp-authz-gate.test.sh) goes red; the keystone suite passes **only** when every mutant is caught. Full invariant + attack matrix: [`docs/specs/2026-07-03-rr-isolation-invariants.md`](specs/2026-07-03-rr-isolation-invariants.md).
- **BYOC — no shared keys.** You pay your own Claude tokens; your credential lands in **your own** per-team Secret Manager secret and is injected env-only into your job — never logged, never echoed, never readable by another tenant.
- **Least-privilege bot.** The App holds exactly Contents + Issues + Pull requests — **no** Administration, **no** Actions/Workflows, **no** merge capability. It can open a PR; it cannot touch branch protection or push to `main`.
- **Honest bring-up.** This loop was hardened over a live multi-tenant bring-up that shook out a run of production-only failures — Google's GFE rejecting GET-with-a-body, cold-start identity drift, jobs starving under scale-to-zero — each now documented as fixed in [`deploy/cloud-run/README.md`](../deploy/cloud-run/README.md) and the runbook.

Under the hood the bot runs the local engine installed above: every plan wires an external, falsifiable oracle so the implementation can never grade its own homework, and the merge stays blocked until that oracle is green — after it has been proven able to go red.

## What's inside

| Capability | Command | Status |
|---|---|---|
| Verification gates (secret-scan, falsify) | Automatic on commit/push (git hooks) · `bin/falsify <domain>` to run one directly | Shipped |
| Demo task runner | `hmd demo` / `hmd demo --run` | Shipped |
| Issue-resolution loop | `hmd` (auto-retries failures against corpus) | Shipped |
| Telemetry report | `hmd report` | Shipped |
| Design match (visual diff vs spec) | `hmd designmatch` | Shipped |
| Redum / conformance checker | `hmd redum` · `hmd check` | Shipped |
| Reuse engine (cold-repo analysis) | `bin/lib/reuse_analyzer.py` | Shipped |
| Debloat scanner | `heimdall-debloat --report-only` | Shipped |
| Parallel workers | `hmd --team N "task"` (N tmux panes, independent — no shared state) | Shipped (no coordination layer) |
| Benchmark suite | `heimdall-bench` | Shipped |
| Optional capability modules | `hmd modules` | Shipped |
| Cursor CLI host (gate + statusline HUD) | `hmd init` (auto-detects) · [details](#also-gates-cursor-cli) | Shipped |
| AI backend preference (Claude Code ⇄ Cursor CLI) | `heimdall-ai-select` · `/hmd:switch-ai` | Shipped |

## Modules

Optional capability modules. **The base install ships the module system and zero module payloads** — [`modules/`](../modules/) holds manifests and class contracts, never vendored code. The registry *is this repo*, so every pin is a reviewed commit rather than a network lookup, and there is no code path that resolves "latest". **Nothing self-installs.**

```bash
hmd modules                    # list — honest when nothing is installed
hmd modules add <name>         # the full ordered pipeline
hmd modules remove <name>      # total removal
hmd modules update [<name>]    # move to the manifest's human-set pin
hmd modules status <name>      # one module in detail
hmd modules verify [<name>]    # re-run class invariants (the CI entry point)
hmd modules preflight <name>   # can this install happen? read-only, asks nothing
hmd modules repair <name>      # retry an install, recording which stage failed
hmd modules defer <name>       # not now — hmd is ready, the module follows later
hmd modules pending            # what is deferred or awaiting a retry
hmd modules optout <name>      # decline; no install path may re-install it
hmd modules optin <name>       # undo an optout
```

Every verb accepts `--json`; `add` accepts `--yes`. `--registry` and `--state` relocate the registry and install state, which is how the suite runs hermetically.

### Four permission classes

A module declares its class — or several — in its manifest, and a missing or unknown class is **refused, not defaulted**: the class decides consent and which invariants are enforced, so picking one silently would be picking a security posture on the operator's behalf. When a module declares several, **the union of their invariants runs, never the first match.**

| Class | Consent | Invariants enforced |
|---|---|---|
| `traffic-proxy` | **required** | gates read raw · non-interactive passthrough · signed and control-plane traffic never routed through it |
| `tool-adapter` | **required** | wrap/unwrap byte-identical · hooksPath and AGENTS.md fences preserved |
| `storage-codec` | not required | round-trip fidelity · plain fallback when absent · never touches judgment inputs |
| `rule-pack` | not required | rules ship falsifiers · attribution preserved |

The two classes that mutate something you own — the wire, and your own config files — ask. The two that are transparent by contract do not, and their invariants are what make that transparency true rather than asserted: a codec that loses a byte, or a pack that flattens attribution, is rolled back rather than merely disclosed.

### The lifecycle order is the contract

```
[1/7] validate → [2/7] class contract → [3/7] preflight → [4/7] consent
    → [5/7] install + provenance → [6/7] wire → [7/7] class invariants (module active)
```

Steps 1–4 are read-only, so anything rejected at validate, class, preflight or consent mutates nothing at all. **Preflight sits before consent on purpose** — nobody should be asked to agree to an install that cannot happen. Step 5 is the first mutation, and from there every failure unwinds through **the same removal path `remove` uses**, so a module that fails its own class test leaves a byte-identical tree. Wiring precedes invariants deliberately: the contracts assert behaviour *with the module active*, so a check run against an unwired module would prove nothing.

**Step 5 is called `provenance`, not `digest-verify`, and the naming is load-bearing.** A digest is verified on exactly one path: a `local` module, whose artifact ships in this repo and is hashed here against its pin. An `upstream` module is fetched from a package index and hmd hashes **nothing** — it records the pin and asks the installer whether the payload arrived. The receipt reads `verified: false` in every upstream state, and nothing re-checks that pin later: `hmd modules verify` re-runs the class invariants and reads no digest at all. Printing `digest-verify` over that would assert a check that never ran.

### Consent leaves a receipt

An install that required consent records how it was granted — `granted_via` is one of `interactive`, `--yes`, or `manifest-waiver` — alongside the exact `consent_text` shown and its `consent_text_sha256`. Consent required with a non-TTY stdin is **refused, not prompted and not defaulted to yes**; `--yes` is the operator saying so on purpose.

A module in the default set reaches machines the author will never meet, so `default_included: true` is refused at **validate** time if any class it claims requires consent and the manifest ships no `consent_text`. A disclosure that only materialises at a prompt somebody may never be shown is not a disclosure.

### Opting out

Two surfaces read opt-out signals, and **they do not overlap** — each verb honours the signals of the surface it belongs to:

| Signal | Read by | Effect |
|---|---|---|
| `HEIMDALL_NO_MODULES=1` | `bin/heimdall-autoupdate` | no module is acquired automatically, at all |
| `~/.heimdall/modules-optout` | `bin/heimdall-autoupdate` | one module name per line; `#` starts a comment |
| `hmd modules optout <name>` | `bin/heimdall-modules` | persisted; `repair`, `defer` and `pending` all refuse to act |
| `HMD_MODULE_OPTOUT=a,b` | `bin/heimdall-modules` | the same, for one invocation |

**`install.sh` acquires no modules at all** — the installer has no module code path, so there is no installer flag to suppress and none is offered. Automatic acquisition lives in the background updater, which is why `HEIMDALL_NO_MODULES=1` bites there. The consequence, stated plainly: every one of these signals governs acquisition that happens **on your behalf**. `HEIMDALL_NO_MODULES=1` suppresses automatic acquisition and does **not** block an explicit `hmd modules add <name>` — an operator typing the command themselves is not what an opt-out for unattended installs is trying to stop.

### Headroom — the one shipped module, and its honest limits

[`modules/headroom/manifest.json`](../modules/headroom/manifest.json) pins [Headroom](https://github.com/headroomlabs-ai/headroom) (Apache-2.0), a local context-compression proxy. **Depend, don't clone** — none of its source is vendored here. The manifest is the single source of truth for the pin and its artifact digest; this page deliberately does not restate the version, because a second hand-maintained copy of a pin is how pins drift.

It is `default_included`, and its consent *question* is waived on the module itself. `modules/_classes/traffic-proxy.json` still reads `consent_required: true`, so every other traffic-proxy module hmd ever ships still asks; the waiver's blast radius is this one module. Waived is the question, never the disclosure — the consent text still prints, both declared classes still run their invariants with the module active, and `hmd modules remove headroom` still returns the tree byte-identically.

Being in the default set is a **distribution** fact, not a claim that it helps, and not an unattended install:

- **The background updater will not install it for you.** Acquisition reads the *class* contract, and `traffic-proxy` requires consent — so `heimdall-autoupdate` names the module, states the class, and hands you `hmd modules add headroom` rather than acquiring it. Until you run that command, `heimdall-autoupdate status` reports it `absent` with the reason and `hmd modules status headroom` reports `NOT ATTEMPTED`.
- **It is the one place hmd stops being near-stdlib.** The fetch is `uv tool install --python 3.13 "headroom-ai[all]==<pin>"`, which pulls an ML stack — Rust wheels, an ONNX runtime, HuggingFace tokenizers. Install size and time are materially larger than hmd's own.
- **A failed Headroom install does not fail `hmd install`.** hmd works; the module reports ABSENT with the blocker and the remedy named, and rolls back through the removal path. It is never silently assumed present.
- **The storage-codec half does not engage via the documented install.** `uv tool install` lands the package in an isolated per-tool venv that hmd's `python3` cannot import, so the memory codec stays on its `plain` backend on every machine that installs it the sanctioned way. The manifest records that as a measurement rather than letting a green `add` imply otherwise. Treat compression on the storage seam as a contract the seam honours *if* a backend ever arrives — not as a description of any running machine.
- **The proxy half is declared, not applied — hmd points no traffic at it.** `bin/heimdall-wrap` contains no reference to the module, so installing Headroom leaves your generation traffic going exactly where it went before. The `wrap-chain` wire records the chain hmd *would* offer; wiring it up is yours to do, deliberately, by pointing your tool at the proxy. hmd measures that wire at every `add` and prints `RECORDED, not routed` while it stays unapplied, and a wire kind with no handler behind it is refused outright rather than recorded — an install may not imply a capability the code cannot deliver ([`test/wire-kind-dispatch.test.sh`](../test/wire-kind-dispatch.test.sh)).
- **Gates read raw.** Generation traffic may traverse a proxy once you route it through one; judgment traffic may not follow. Every verdict-producing execution runs through `hmd_gate_exec`, which unsets `ANTHROPIC_BASE_URL`, the HTTP/HTTPS/ALL/NO_PROXY pairs and Headroom's own `HEADROOM_*` namespace before pinning the endpoint to the real provider. A judge reading compressed context emits confident false greens, which is the failure this whole project exists to prevent.

Full manifest schema, class-contract details and the lifecycle rationale: [`modules/README.md`](../modules/README.md).

## Viral statusline — watchman, team wall, gate animation

Heimdall's status bar is a full-width, four-row watchman HUD. It renders entirely shell-side (zero model, zero context cost) — `bin/heimdall-statusline` is one CLI-agnostic renderer shared by both hosts it wires into. Under Claude Code, `hooks/statusline.sh` reads the `statusLine` JSON Claude Code hands it on stdin. Under Cursor CLI it reads the same shape from Cursor's own `statusLine` plug-in point, swapping only the width signal — Cursor hands `render_width_chars` in that JSON instead of Claude Code's `$COLUMNS`, and the renderer already reads that field itself. Three surfaces, by how far they spread:

**Your sigil — the identity hook.** Every Heimdall identity (`HAID`) gets a unique, deterministic pixel watchman: same identity, same sigil, forever. It anchors the left of the line, prints big on the install card, and shares as a postable block:

```bash
python3 sentinels/hmd-sigil.py --seed $HMD_HAID --size large   # share/banner render
bash hooks/hmd-banner.sh --share                               # postable "my watchman" card
```

The seed is your **HAID by default** — automatic, stable, no PII in the art. Works solo on day one, before any teammate shows up.

**The team watch wall — the headline, and the moat.** When teammates also run `hmd` in the same repo, the bottom row becomes a live wall of their watchmen and what each agent is doing — gate state colored in, a teammate's cell flashing red the instant their gate denies. Nobody else can render this; it needs Heimdall's coordination substrate. The wall is empty until your team joins, so the feature recruits your team for you.

Two presence channels, two defaults. The **control-plane presence** (the signed heartbeat described under *Network posture* above) is **on by default**: `hmd presence off` silences this repo (`<repo>/.heimdall/presence.json` → `{"enabled": false}`), `hmd presence off --global` is the machine-wide kill switch (`~/.heimdall/presence-off`), and `hmd presence sever` is the zero-egress opt-out. The **file-based wall heartbeat** is separate and off until you ask for it: `sentinels/hmd-gate-event.sh` writes `<repo>/.heimdall/team/<haid>.json` (TTL ~30s; a stale file means the agent left) only when `<repo>/.heimdall/team/CONSENT` exists, and the statusline reads those files only when the server roster is empty. Names in that dir never leave the repo. The watchman watches your gates, not your team. At squad scale the wall caps at the **~6 most-recently-active** teammates plus a `+N more` tail so a wide terminal never wraps.

**The deny flash — the clip.** When a gate blocks, `hmd-gate-anim.sh` redraws the big watchman inline: a scanning pulse settling to a green sparkle on pass, or three red beats and `✗ BIFRÖST CLOSED` on deny. TTY-only — in CI or a pipe it collapses to one clean final frame so logs stay readable.

```bash
bash sentinels/hmd-gate-anim.sh deny "oracle/falsify" $HMD_HAID
```

**Wiring** (`settings.json`):

```json
{
  "statusLine":         {"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooks/statusline.sh"},
  "subagentStatusLine": {"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/sentinels/hmd-subagent-statusline.sh"}
}
```

`install.sh` wires this for you — it registers both entries into your `~/.claude/settings.json` (honoring `$CLAUDE_CONFIG_DIR`) using the **absolute installed path**, idempotently and without clobbering a `statusLine` you set yourself. The `${CLAUDE_PLUGIN_ROOT}` form above is the plugin-hook spelling; a user-level statusLine resolves no such variable, so the installer fills in the resolved absolute path — which is why the HUD now reaches every dev, not just whoever hand-wired it in dev setup.

Cursor CLI gets the identical renderer through its own plug-in point, registered automatically by `hmd init` — mechanics and the honest limits of that second host are in [Also gates Cursor CLI](#also-gates-cursor-cli) below.

`hooks/statusline.sh` drives the full-width watchman and falls back to the legacy single line if `python3` is missing — it never errors, never blocks. Already a ccstatusline (9.2k★) user? Keep your line and drop the watchman in as a Custom Command widget:

```bash
python3 sentinels/hmd-statusline.py --widget   # just the watchman + verdict segment
```

The sigil ships solo-first (viral-cheap, no team required); the watch wall is the team-gated headline that lights up once presence is wired into your gate hooks.

## Also gates Cursor CLI

hmd is itself a Claude Code plugin, but the gate it wires into git is not plugin-specific. Once a repo has been through `hmd init`, code written by Cursor CLI's `agent` (`cursor-agent`) is checked by the exact same `pre-commit`/`pre-push` → `bin/heimdall-gate-run` path as code written by Claude Code — same stub-scan, same falsify oracle, same `BIFRÖST` deny on the same terms. Cursor also reads `AGENTS.md` at session start the way Claude Code reads `CLAUDE.md`, so the fenced `hmd init` block that tells an agent "this repo is gated" reaches it too.

`hmd init` also auto-registers the watchman HUD into Cursor's own `~/.cursor/cli-config.json` `statusLine` the moment it detects `cursor-agent` on `PATH` (`bin/heimdall-statusline-register-cursor`, verbs `status` / `register` / `unregister`, also reachable as `hmd cursor-statusline`). It is idempotent, never clobbers a `statusLine` you set yourself, and never runs at all against a machine that has never touched Cursor. Opt out with `HEIMDALL_NO_CURSOR_STATUSLINE_REGISTER=1` or `~/.heimdall/no-cursor-statusline-register` (the shared `HEIMDALL_NO_STATUSLINE_REGISTER=1` / `~/.heimdall/no-statusline-register` markers suppress both hosts).

hmd's own sub-agent spawns can delegate work to more than one detected CLI backend. `heimdall-ai-select list --auth` shows what is on `PATH`, and `/hmd:switch-ai` (or `heimdall-ai-select select <letter|id>`) changes which one hmd *prefers*, persisted to `.planning/settings.json` under `ai_backend` with its provenance (`user` vs `auto-default`). That preference is not a live hot-swap: hmd is Claude Code code running inside a Claude Code process, and nothing restarts that process into a different CLI mid-session — switching takes effect for delegated spawns now and for the next session's default, never for the session you're already in.

### What you don't get under Cursor

The gate itself has the same teeth under Cursor as under Claude Code — nothing here weakens what gets blocked. What differs is *when* and *how* it fires:

- **Caught at commit, not at write.** Claude Code's live `PreToolUse` hook blocks a stub the instant it is written. Cursor CLI has no equivalent pre-write hook, so the same stub is instead caught at `git commit` by `bin/heimdall-gate-run`'s backstop — later, but the same gate, and the commit still does not land.
- **No SessionStart automation.** The auto-update check, `cc-selfheal`, the resume probe, the dream notice, the presence keeper, and `heimdall-ai-select session-start` all fire from Claude Code's SessionStart hook. Cursor has no such hook for hmd to fire from, so `hmd init` is a one-time, by-hand setup rather than something that re-arms itself every session.
- **No SessionEnd automation.** Checkpoint writes, `verify-edits`, and auto-commit likewise never fire under Cursor — there is no session-end hook to fire them from.
- **No subagent orchestration.** hmd's `Agent`/`SendMessage` spawning is Claude Agent SDK-specific; it does not run inside a `cursor-agent` process.
- **Cursor's own `.cursor/hooks.json` is untouched.** Cursor has a separate, unrelated hook mechanism (`sessionStart` / `preToolUse` / `beforeShellExecution`, allow/ask with an exit-code-2 deny); hmd does not populate it and has no plan to.

## Running on your own work

```bash
cd /path/to/your/project
heimdall --auto "build a real-time dashboard with auth and charts"
```

`--auto` runs Claude Code's auto permission mode (`--permission-mode auto`): a background safety classifier that blocks prompt injection and risky escalation. It is **not** the default. With no flag, `heimdall` launches Claude Code with `--dangerously-skip-permissions` (full autonomy) — `bin/heimdall` sets `PERMISSION_FLAG="--dangerously-skip-permissions"` and only a leading `--auto` overrides it. Pass `--auto` as the first argument for the safer opt-in; run the bare default only where you would accept a fully autonomous agent.
