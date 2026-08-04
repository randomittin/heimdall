# First-Run Setup: Cascade / Queue Design

**Date:** 2026-08-04 · **Status:** proposal, not built · **Branch:** main
**Ask (verbatim):** "you can cascade first time setup requests or queue them for the setup to be done better"

**Revised design target (owner override, 2026-08-04):** default to FULL CAPABILITY as ONE
decision. Running the installer IS the decision. Do not scatter questions; do not gate
capability behind choices the user has no basis to evaluate. The failure this prevents is the
more likely one: fragmented opt-ins ship a lobotomized install, the user concludes hmd is
thin, and never sees the product.

This document is DESIGN. No implementation code is proposed as code; every item below is a
specification a coder agent executes later.

---

## 0. Method, and what I did NOT verify

**What I did:** read `install.sh`, `bin/heimdall-init`, `bin/heimdall`, `bin/heimdall-modules`,
`bin/heimdall-autoupdate`, `bin/heimdall-presence` (connect-prompt), `bin/heimdall-connect`,
`bin/heimdall-wrap`, `bin/heimdall-statusline-register`, `bin/heimdall-identity`,
`bin/heimdall-dream-schedule`, `bin/lib/cp-consent.sh`, `bin/lib/crontab-safe.sh`,
`bin/lib/real-home.sh`, `bin/lib/telemetry.py`, `hooks/hooks.json`, `modules/_classes/*.json`,
`modules/headroom/manifest.json`. Swept all of `bin/` for blocking-read sites (`read -r`,
`read -p`, `read -rs`, `</dev/tty`) and for python `input(` / `getpass`.

**What I did NOT verify (stated plainly, as instructed):**

| Not verified | Why | What it would take |
|---|---|---|
| Any prompt's live behaviour | I did not execute `install.sh`, `hmd init`, `heimdall-modules add`, the seed, or any SessionStart hook | A throwaway VM/container; `Dockerfile.install` exists and is the right harness |
| Whether the marketplace/plugin steps prompt | `ensure_claude_mem` shells out to `claude plugins marketplace add` / `claude plugins install`; the **external** `claude` CLI's own interactivity is not readable from this repo | Run the two commands against a scratch `CLAUDE_CONFIG_DIR` |
| Whether `ensure_crypto_backend` can prompt | It is PEP-668-aware and may invoke `pip`/`uv`; pip can prompt on some estates | Same container run |
| Real ordering of SessionStart hook output vs. the session prompt | Depends on Claude Code's hook scheduling, not on this repo | Instrumented session |
| Whether `connect-prompt`'s `read` actually gets a usable stdin under the SessionStart hook | Guard is `[ -t 0 ] && [ -t 1 ]`; whether a hook inherits a TTY is harness-dependent | Instrumented session |
| Windows/Linux behaviour of the launchd item | macOS-only path; non-Darwin is documented as a clean skip but not exercised here | CI matrix |
| Telemetry default-on end-to-end | `bin/lib/telemetry.py:124 enabled()` reads `HEIMDALL_TELEMETRY`; I read the function header, not every call site's `home` resolution | Read `telemetry.py` in full |

**Nothing was executed. `~/.heimdall`, `~/.claude`, `~/Library/LaunchAgents` and the crontab
were not touched.** Reads only.

---

## 1. Current-state inventory

### 1.A Blocking reads (the actual prompts) — 10 sites, 4 on the automatic path

| # | Site | What is asked | When | Blocks? | No-tty behaviour | Non-interactive answer |
|---|---|---|---|---|---|---|
| P1 | `install.sh:1237` | Team control-plane URL (blank = public default) | mid-install, step 6 of 13 | yes, on TTY | `[ -t 0 ]` false → skipped, prints a `⚠ no control-plane endpoint set` block | `HEIMDALL_CP_URL` |
| P2 | `bin/heimdall-modules:686` | "Install it? [y/N]" for a consent-required class | on `modules add`, i.e. **later than install** | yes | **REFUSES** (`return 1`) — will not install, will not default | `--yes`, or per-module `consent_waived` |
| P3 | `bin/heimdall-presence:1376` | "Keep Heimdall presence ON? [Y = keep on / n = disable]" | **SessionStart hook, first session** | yes, on TTY | stays ON + throttled one-line notice; **persists nothing**, so it re-surfaces | `HEIMDALL_CP_URL` / `BASE_URL` / `cp-endpoint.json` counts as consent |
| P4 | `bin/heimdall-wrap:112` | "Which coding tool should Heimdall wrap?" | first `hmd` launch with no tool configured | yes, on TTY | falls through to `claude` | `~/.heimdall` default file written by `remember_default` — **no env var** |
| P5 | `bin/heimdall-connect:486` | paste a connect token (`read -rs`, no echo) | only on explicit `hmd connect` | yes | 3 shape attempts, then a docs link | none (a secret; see §3.3) |
| P6 | `bin/heimdall-dashboard:157` | dashboard keypress (`</dev/tty`) | only on `hmd dashboard` | yes | read fails → empty | n/a |
| P7–P10 | `bin/heimdall:1870, 2380, 2445, 2489` | uninstall / reinstall / companion-removal confirms | teardown only | yes | refuse-rather-than-hang | `--yes` / `-y` |

P1, P3, P4 are the three a first-time user actually hits, and they arrive at **three different
moments** — mid-install, first session, first launch. P2 arrives whenever a consent-gated
module is first attempted, which under `heimdall-autoupdate reconcile` is *deferred* rather
than asked (D23). That staggering is exactly the scatter the owner is describing.

**Doc/code divergence found:** `install.sh:10` claims *"no stdin reads, no interactive prompts
(stdin IS the script under a pipe)"*. `install.sh:1237` is a stdin read. The claim holds only
for the piped path; the header states it unconditionally.

### 1.B Decisions applied silently (no ask) — 23 more

These are what a queue must surface as **disclosure**, because today they are decided for the
user with no statement at all.

| # | Decision | Writes | Opt-out today | Reversible by |
|---|---|---|---|---|
| D1 | Clone/refresh plugin tree | `~/.heimdall` | — | `hmd uninstall` |
| D2 | Entry-point symlinks `hmd`, `heimdall` | `~/.local/bin` | `HEIMDALL_FORCE_HMD` (force, not skip) | `hmd uninstall` |
| D3 | Marketplace registration | `~/.claude` | — | not exposed |
| D4 | Plugin install (`heimdall`) | `~/.claude` | — | `claude plugins uninstall` |
| D5 | Statusline HUD registration | `~/.claude/settings.json` | `HEIMDALL_NO_STATUSLINE_REGISTER=1`, `~/.heimdall/no-statusline-register` | **no command exists** |
| D6 | claude-mem companion plugin | `~/.claude` + external marketplace | — | `claude plugins uninstall` |
| D7 | caveman companion plugin | `~/.claude` | — | `claude plugins uninstall` |
| D8 | `cp-endpoint.json` (0600) | `~/.heimdall` | absent → skipped | delete file |
| D9 | Team join from `HEIMDALL_TEAM_SECRET` | `<repo>/.heimdall/team.json` (0600) | no env → solo | `hmd team new` |
| D10 | Team **auto-mint / auto-join** (`heimdall-team auto`, SessionStart) | `<repo>/.heimdall/team.json` | — | `hmd team new` |
| D11 | Ed25519 PKI backend ensure (pip/uv into a python env) | system python env | — | not exposed |
| D12 | Presence **enroll + first beat** (network egress) | control plane | `hmd presence sever` | `hmd presence sever` |
| D13 | Local telemetry NDJSON, **default on** | `.heimdall/telemetry/events.ndjson` | `HEIMDALL_TELEMETRY=off`, `hmd telemetry off` | `hmd telemetry off` |
| D14 | Nightly `/dream` LaunchAgent 03:00 | `~/Library/LaunchAgents/com.heimdall.dream` + `launchctl gui/<uid>` | `HEIMDALL_NO_DREAM_SCHEDULE=1` | `hmd dream-schedule uninstall` |
| D15 | Autoupdate background check | `~/.heimdall` | `HEIMDALL_NO_AUTOUPDATE` | env only |
| D16 | Module reconcile: acquire defaults, **defer** consent-gated | `<plugin>/.heimdall/modules` | `HEIMDALL_NO_MODULES=1`, `hmd modules optout <n>` | `hmd modules remove <n>` |
| D17 | git `core.hooksPath` → `.heimdall/hooks` (chains existing) | `<repo>/.git/config` | not running `hmd init` | not exposed as a command |
| D18 | AGENTS.md fenced region | `<repo>/AGENTS.md` | `--agents-only` inverts; no skip | hand-edit |
| D19 | secret-scan + bloat gate wiring | `<repo>` | — | — |
| D20 | `heimdall-state init` in cwd | `<cwd>/heimdall-state.json` | — | delete file |
| D21 | `.planning/detected-stack.json`, tracker `clang` builds, `heimdall-cleanup --auto` | cwd, `<plugin>/bin` | — | — |
| D22 | Autocommit **on by default** | `<repo>` | `.heimdall-no-autocommit` file | `/hmd:autocommit off` |
| D23 | Identity handle/seed — **derived, never asked** | `<repo>/.heimdall/identity.json` | — | `hmd identity --set` |

**Total decision points found: 33** — 10 blocking reads + 23 silent decisions. **26 are
reachable on the automatic install → first-session → first-launch path** (excluding the four
teardown confirms, `hmd connect`, `hmd dashboard`, and D3's operator-only variants).

### 1.C What already exists that this design must REUSE, not reinvent

Four in-tree primitives already have the right shape. Building a parallel mechanism is the
mistake to avoid.

1. **Per-module waiver** — `modules/headroom/manifest.json`: `consent_waived: true` plus
   `consent_waived_reason`, declared on the **module**, deliberately NOT as
   `consent_required: false` on `modules/_classes/traffic-proxy.json`. The waiver's blast
   radius is exactly one module; the class contract still governs every other module,
   including ones nobody has written yet. The disclosure text still prints
   (`bin/heimdall-modules:643-652`) and the receipt records
   `granted_via: "manifest-waiver"`, so a waiver is machine-distinguishable from a human
   saying yes. **This is the shape to generalise.**
2. **Receipt** — `bin/heimdall-modules:996-1013` writes `receipt.json` with `manifest_sha256`,
   `digest`, `payload`, and a `consent` block carrying `granted_via`, `granted_at`,
   `consent_text`, `consent_text_sha256`. A hash of the disclosed text is pinned, so "what was
   I told" is answerable after the fact.
3. **Durable deferral** — `heimdall-modules defer` / `pending`
   (`bin/heimdall-modules:1807`, `:1843`) already implement the exact semantics §4 needs: a
   `deferred.json` state file, a `pending` sweep that is *file-existence tests only* (one
   `stat` per item, no preflight, no network), and `HMD_MODULE_RETRY_INTERVAL=86400` backoff so
   a permanently-broken item does not turn every session into a retry storm.
4. **Blast-radius self-detection** — `bin/lib/real-home.sh` reads the passwd database
   (`getpwuid`), a source `$HOME` cannot influence, and fails closed on every "don't know". Its
   header records the real incident: *an agent running a real install under a throwaway `HOME`
   reached the developer's REAL nightly scheduler and repointed it at an ephemeral agent
   worktree* — a path later reaped, so the nightly job was wired to something that ceases to
   exist. `bin/lib/crontab-safe.sh` is the same lesson for cron: fail-closed read, timestamped
   backup before replace.

### 1.D Gaps found

- **`--without <name>` does not exist.** Grep over `bin/heimdall-modules` and `install.sh`
  returns nothing. Today's only hatches are `HEIMDALL_NO_MODULES=1` (all-or-nothing env) and
  `hmd modules optout <name>` (per-module but **post-hoc** — hmd must already be installed).
  There is no way to say "install everything except X" at install time.
- **`hmd statusline off` does not exist.** `heimdall-statusline-register` exposes `register`
  and `status` only. D5 writes a shared file with no revert command.
- **`connect-prompt` persists nothing when non-interactive**
  (`bin/heimdall-presence:1362-1367`) — by design, so a later interactive session can still pin
  a decision. Right intent, wrong mechanism: the question genuinely re-surfaces mid-work
  forever until a TTY session catches it. That is the ambush the owner named.
- **`hmd init` is a separate, later, manual act.** Per-repo items (D17–D23) are not part of
  install at all, so "setup" is structurally two events with an unbounded gap between them.

---

## 2. The proposed model: a Setup Ledger

One artifact, two scopes, three verbs.

```
~/.heimdall/setup/ledger.json          scope: user   (D1–D16, P1, P3, P4)
<repo>/.heimdall/setup/ledger.json     scope: repo   (D17–D23, P5)
```

**Item schema** (generalising the module receipt and the headroom waiver):

```
id                  stable slug — "presence", "dream-schedule", "statusline"
scope               user | repo
title               one line a human reads
disclosure          full text of what this enables — printed always, batched or not
disclosure_sha256   pin of the exact text shown (generalises consent_text_sha256)
depends_on          [ids] — topological edge
class               clubbed | carved
carve_reason        only when class=carved: "blast-radius:<domain>"
apply_guard         only when class=carved: the predicate that must be true to apply
env                 the env var that answers this unattended
flag                the install-time flag that answers this
default             the full-capability answer
answer              { value, granted_via, at }
                      granted_via ∈ clubbed-default | interactive | env:<VAR> |
                                    flag:--without | waiver | deferred
applied             { ok, at, changed:[paths], revert:"<one command>" }
deferred            { at, reason, resurface_on:[...] }
```

**Three verbs** (`bin/heimdall-setup`, new):

- `plan` — resolve every item, emit the ordered list. **Writes nothing.** The dry-run seam and
  the acceptance harness's entry point.
- `apply` — execute the plan, writing `applied` per item as it lands.
- `receipts` — read the ledger back: what was enabled, when, on what basis, how to reverse.

### 2.1 Collect-then-ask, and the two orderings

There is no "ask". There is **collect → disclose once → apply as a batch**. But there are two
distinct orderings, and conflating them is a bug:

**Presentation order — highest-consequence first.** The human reads network egress and the
scheduler *first*, not buried under twelve lines of symlinks. Consequence rank:
`network egress > writes outside hmd's state > scheduler/daemon > per-repo tree writes > hmd's own state`.

**Apply order — topological, then most-reversible-first.** Dependencies are hard edges
(`cp-endpoint` before presence enroll; plugin tree before symlinks). *Within* a dependency
wave, apply the most reversible item first. This buys an **abort-anywhere property**: whatever
has landed at the moment of an abort is, by construction, the cheapest set to undo.
Cheapest-first would optimise for a progress bar; reversibility-first optimises for the state
you are left holding when the lid closes at step 9 of 13.

### 2.2 What the user actually sees — one screen, no prompt

```
  Heimdall is enabling all of it. This is the whole product, not a subset.

  [network]    team presence — your handle, online status, current filename +
               verdict, shared with holders of this repo's team secret. Never
               file contents, never code.                revert: hmd presence sever
  [scheduler]  nightly /dream at 03:00 (launchd)   revert: hmd dream-schedule uninstall
  [~/.claude]  statusline HUD, marketplace, claude-mem       revert: hmd statusline off
  [local]      git gates on commit/push, autocommit, telemetry (local file,
               never sent)                        revert: hmd telemetry off | ...
  [modules]    headroom — local context-compression proxy. Generation may run
               compressed; judgment never does.  revert: hmd modules remove headroom

  Not what you want:  --without <id>  ·  HEIMDALL_NO_MODULES=1  ·  hmd setup receipts
```

Then it applies. No `[y/N]`. **Running the installer is the decision.**

---

## 3. Clubbed-by-default vs carved-out-for-blast-radius

> This section replaces the "batchable vs standalone" framing in the original brief, per the
> owner's override. The test is no longer *"is this a security decision?"* — it is
> ***"can this be reversed with one command, and does it write somewhere `$HOME` cannot
> isolate?"***

**Definitions, stated precisely so "carved" cannot smuggle a consent gate back in:**

- **CLUBBED** — enabled by default as part of the one decision. Disclosed in full. One command
  reverses it.
- **CARVED** — *still enabled by default, still not a question.* Carved means it gets its own
  **apply guard**, its own **receipt line**, and its own **named revert command**, and it is
  **skipped rather than asked** when its guard says the domain is not ours to touch.
  **A carve-out is a guard, not a prompt.**

### 3.1 CLUBBED — the default posture, 26 items

Everything in §1.A and §1.B that is (a) local, or network already bounded and disclosed,
(b) inside hmd's own state or a fenced region of a shared file, and (c) one-command reversible:

D1, D2, D8, D9, D10, D11, D12, D13, D15, D16, D17, D18, D19, D20, D21, D22, D23, P1, P3, P4,
plus headroom (already waived), plus the per-repo gate wirings.

Two deserve a word:

- **Presence (D12/P3) is clubbed.** It is network egress, the loudest thing here — so it leads
  the disclosure screen. But it is already default-ON in code (`bin/lib/cp-consent.sh`:
  undecided ⇒ ON), the payload is bounded to handle + verdict + current filename (never file
  contents), and `hmd presence sever` is a genuine one-command total revert that *also* sends a
  retire beat so you vanish promptly rather than at TTL. Clubbing it and deleting the
  SessionStart `read` is a strict improvement: today an undecided user is ON **and** gets
  nagged; after this they are ON **and** told once, at setup, with the revert in hand.
- **headroom (traffic-proxy) is clubbed** — it already is, via the per-module waiver, and that
  waiver mechanism is precisely what §2's `granted_via` generalises. Note the class contract
  `consent_required: true` on `modules/_classes/traffic-proxy.json` **stays**: a future
  traffic-proxy module ships with the question intact until someone writes a per-module waiver
  *and* a recorded reason. That is the whole point of the headroom precedent and it must not be
  flattened into a class-level flip.

### 3.2 CARVED — four, each justified on blast radius, not on consent

**C1 · Nightly `/dream` LaunchAgent (D14).** `launchctl` targets `gui/<uid>` — the logged-in
user's GUI session domain — and `~/Library/LaunchAgents` is read by that same per-user launchd.
**`$HOME` does not isolate either.** Not hypothetical: `bin/lib/real-home.sh` records that an
agent running an install under `HOME=$(mktemp -d)` reached the developer's real nightly
scheduler and repointed it at an ephemeral worktree, later reaped, so the nightly job was wired
to something that ceases to exist.
*Carve = apply guard, not a question:* apply only when `heimdall_home_is_real` is true and
`heimdall_path_is_ephemeral <plugin>` is false. Guard false ⇒ **skip and record
`granted_via: "deferred"`, `reason: "blast-radius:launchd"`** — never ask, never silently
default. The header's own conclusion is the design rule: the env opt-out
`HEIMDALL_NO_DREAM_SCHEDULE=1` only works if every future caller remembers it, and one forgot.
The passwd-database self-detection is the floor underneath the opt-out, and **the ledger must
call the floor, not the opt-out.**

**C2 · crontab.** A single shared global resource with no per-app namespace, and the naive
replace form once wiped a user's entire crontab silently (`bin/lib/crontab-safe.sh` header).
`heimdall_crontab_install` already fixes it — fail-closed read, timestamped backup, path
printed. Today crontab is reached only by `deploy/` scripts, never by `install.sh`.
*Carve = keep it out of the first-run ledger entirely*, and if anything ever adds it, it routes
through `heimdall_crontab_install` or it does not ship.

**C3 · `~/.claude/settings.json` and the plugin/marketplace surface (D3–D7).** Four writers in
this repo touch that file (`skill-manager`, `heimdall-statusline-register`,
`heimdall-doctor-install`, `install.sh`), plus the external `claude` CLI, plus every other
plugin the user has installed. It is not ours; it is shared. The existing guards are already
right — `kept-custom` never clobbers a user's own `statusLine`, and the edit is atomic and
key-preserving. *Carve = backup-before-write plus a named revert command per item.*
**This carve is CONDITIONAL and should collapse into CLUBBED the moment `hmd statusline off`
exists** (§1.D). The reversibility test is buildable here; the honest move is to build the
revert and then club it, not to carve it forever because a revert is missing.

**C4 · Keychain — named, not used.** `security add-generic-password` appears nowhere in `bin/`
or `install.sh`; the only mention is a comment at `bin/heimdall:984` noting that `gh`'s tokens
live in the system keychain. Recorded here so a future item cannot slip into the clubbed
default unguarded: the keychain is `$HOME`-independent, survives uninstall, and has no
byte-identical-removal story. Anything that wants it is carved on arrival.

### 3.3 The one thing that genuinely cannot be clubbed — and it is not consent

**A datum only the user possesses has no default, so there is nothing to club.** Two items:

- **P5 · `hmd connect` token** (`bin/heimdall-connect:486`) — a secret pasted by the user.
- **D9 · `HEIMDALL_TEAM_SECRET`** — a bearer capability only the inviter can hand over.

These are **data-entry**, not decisions. The distinction preserves the owner's posture exactly:
**club the DECISION, queue the DATUM.** The decision *"team presence is on and you will be on a
team"* is clubbed and applied — you land in an auto-minted solo team (D10), which is a fully
working state, not a degraded one. The *datum* *"here is this specific team's secret"* is queued
as a deferred ledger item with a re-surface, because no default can substitute for a string the
user has not typed yet. Nothing is lobotomized: solo-team presence is the full product minus a
teammate, and the teammate arrives via `hmd invite` whenever the secret does.

**Identity handle (D23)** is a third, softer case. It has a derived default, so it is clubbed —
but it is also the *one* item a first-time user can actually evaluate and wants to choose. Ship
it as a post-setup nudge on the success card (`hmd identity --set <handle>`), never as a gate.

---

## 4. Deferral

A question that cannot be answered now must land somewhere durable and be re-surfaced — never
silently defaulted, never re-asked mid-work.

**Where it lives:** the ledger's `deferred` block. **Reuse `heimdall-modules defer`/`pending`
semantics wholesale** (§1.C.3) — the state-file shape, the stat-only sweep, and the
`HMD_MODULE_RETRY_INTERVAL=86400` backoff are already correct and already exercised.

**What re-surfaces it — three surfaces, none of them a blocking read:**

1. `hmd setup status` / `hmd doctor` — explicit, on demand, the primary path.
2. **SessionStart sweep** — a stat-only `heimdall-setup pending` in the existing hook chain.
   Non-empty ⇒ print **one** line:
   `[heimdall] 2 setup items pending — hmd setup status`. Same 24h backoff.
   **It never reads stdin.**
3. Statusline hint when the pending count > 0.

**The change this forces:** `bin/heimdall-presence:1355 connect-prompt` loses its blocking
`read`. It becomes a ledger resolution at setup time plus, at most, the one-line pending notice.
That single edit removes the mid-work ambush the owner named.

**Deferral is not a default.** `granted_via: "deferred"` is a distinct value from
`"clubbed-default"`. A receipt must be able to answer *"was this enabled, or merely not yet
attempted?"* — the same distinction `cmd_defer`'s own comment draws between "not yet attempted"
and "we tried and it failed".

---

## 5. Idempotence and resumability

- **Item key** is `(id, scope)`, unique. One writer per item.
- **`answer` present ⇒ never re-resolved.** An answered question is never asked again, in any
  session, on any surface.
- **`applied.ok == true` ⇒ never re-applied.** Re-running `apply` is a stat sweep that prints
  what is already done and exits 0 — preserving install.sh's existing idempotence contract
  (`install.sh:14`).
- **Resume = apply the first item with no `applied` block.** Interrupted setup resumes; it does
  not restart. Because apply order is most-reversible-first (§2.1), the set already applied at
  any interruption point is the cheapest to unwind.
- **Torn writes:** every ledger mutation is `mktemp` + atomic replace — the pattern
  `heimdall-identity` and `heimdall-statusline-register` already use.
- **Partial apply is a first-class state.** `applied: {ok:false, reason:...}` is a recorded
  outcome, distinct from absent. `hmd setup status` shows it; `hmd setup apply` retries it under
  backoff.

---

## 6. The non-interactive path stays first-class

Every ledger item carries `env` and `flag`. The unattended path reaches the **same
full-capability outcome**, not a reduced one.

| Item | env | flag |
|---|---|---|
| control-plane URL | `HEIMDALL_CP_URL` | — |
| team secret | `HEIMDALL_TEAM_SECRET` | — |
| presence | `HEIMDALL_CP_URL` (counts as consent today) | `--without presence` |
| all modules | `HEIMDALL_NO_MODULES=1` | `--without modules` |
| one module | — (**gap**) | `--without <name>` |
| dream schedule | `HEIMDALL_NO_DREAM_SCHEDULE=1` | `--without dream-schedule` |
| statusline | `HEIMDALL_NO_STATUSLINE_REGISTER=1` | `--without statusline` |
| autoupdate | `HEIMDALL_NO_AUTOUPDATE` | `--without autoupdate` |
| telemetry | `HEIMDALL_TELEMETRY=off` | `--without telemetry` |
| wrap tool | **`HEIMDALL_WRAP_TOOL` (new — gap)** | — |
| module consent | `--yes` (exists) | — |

**Two gaps to close:** `--without <id>` (absent everywhere in-tree) and `HEIMDALL_WRAP_TOOL`
(P4 has a file-based default but no env answer, so CI silently gets `claude`).

`HEIMDALL_NO_MODULES=1` and `--without` are **escape hatches, not consent gates** — they exist
for regulated estates and hardened CI, and the disclosure screen names them as such. The piped
install path (`curl | bash`, where stdin *is* the script and there is no tty) is why
`HEIMDALL_NO_MODULES` is an env var rather than a flag in the first place; the ledger keeps that
property and extends it.

---

## 7. What it must NOT become: receipts and reversal

The failure mode of every one-click setup is a wizard that hides what it changed.

- **`hmd setup receipts`** reads the ledger and prints, per item: what was enabled, when,
  `granted_via`, the exact `changed[]` paths, and the one-command `revert`. `--json` for
  machines.
- **`disclosure_sha256`** pins the exact text shown, so *"what was I told"* is answerable after
  the fact — generalising `consent_text_sha256` from the module receipt.
- **`granted_via` distinguishes a waiver from a human yes.** `clubbed-default` ≠ `interactive` ≠
  `env:HEIMDALL_CP_URL` ≠ `deferred`. A ledger that flattened these would make the clubbing
  unauditable — and *that* is the version of this that would be theatre.
- **Reversal is one command per item, and total.** The bar is the module lifecycle's, and it is
  already met there: `remove_module` (`bin/heimdall-modules:~740`) `rm -rf`s exactly one
  directory and prunes only directories the tool created, tracked by a `.hmd-created` marker —
  so a *rejected* module and a *removed* module are byte-identical outcomes. Every clubbed item
  must hit that bar. Two do not today (`statusline` D5, `core.hooksPath` D17); the migration
  builds their reverts.

---

## 8. Migration from today's scattered prompts

Strangler, not rewrite. The ledger becomes the single resolver; existing call sites become
readers.

- **Nothing is deleted in wave 1.** `install.sh`'s steps keep running; the ledger merely records
  what they decided. Wave 1 is therefore a pure-addition, zero-behaviour-change wave — which is
  what lets it land independently.
- **Wave 2 inverts the dependency:** P1/P3/P4 stop resolving their own answers and start reading
  the ledger. `install.sh:1235`'s `[ -t 0 ]` block becomes a ledger lookup; `connect-prompt`'s
  `read` is deleted; `heimdall-wrap`'s chooser reads the ledger before its own file default.
- **Escape hatches ship BEFORE prompts are removed** — `--without`, `hmd statusline off`,
  `HEIMDALL_WRAP_TOOL` all land in wave 1. Removing a prompt before its non-interactive answer
  exists would strand exactly the regulated/CI users the hatch is for.
- **Per-repo items (`hmd init`) join in wave 2** via the repo-scope ledger, so setup stops being
  structurally two disconnected events.
- **Rollback:** `HEIMDALL_SETUP_LEDGER=off` restores today's paths verbatim for one release.

---

## 9. Verification — how this is proven, not asserted

**No registry oracle matches.** `jq -r '.oracles|keys[]' evals/oracles/registry.json` yields
`emulator-gb, exchange-lob, issue-collection, ponytail-underdelivery,
rr-multitenant-isolation, symbol-reuse, team-checkpoint, team-copilot, triage-coord` — none
covers installer setup. A reviewer should decide whether to add a `setup-ledger` row. Until
then the gate below is authored **independently of the implementation, in its own wave, by a
different agent**.

**Gate type: `differential` (strongest available here).** The falsifiable claim is a whole-output
equality, not a per-item property:

> For a fixed item registry, the **applied-state set** produced by the unattended path (piped
> install, env answers only, no TTY) is **byte-identical** to the set produced by the
> interactive clubbed path given the same answers.

Concretely: `heimdall-setup plan --json` under a hermetic root, run once with `HEIMDALL_*` env
answers and once through a pty-driven clubbed run, diffed whole. This catches ordering drift,
dropped items and silent defaults — none of which a per-item property check would see.

**Why a property-only gate would be false-green here:** every item can individually report
"applied ok" while the *set* differs (an item skipped on one path, applied on the other), or
while apply *order* violates the reversibility rule. That is the same whole-sequence bug class
the repo already documents elsewhere.

**Falsifiability fixtures (required before the gate is trusted green)** — one golden fixture
that passes, plus injected-defect mutants each of which must be rejected:

- **m1** drop one item from the unattended path
- **m2** reorder apply so a high-radius item lands before a reversible one
- **m3** flip a `granted_via` from `deferred` to `clubbed-default`
- **m4** make apply non-idempotent (second run re-applies)

A gate that cannot go red on all four is not wired.

**Blast-radius safety for the suite itself:** every test runs with
`HEIMDALL_LAUNCH_AGENTS_DIR`, `LAUNCHCTL`, `HEIMDALL_REAL_HOME`, `CLAUDE_CONFIG_DIR`,
`HMD_CP_CONSENT_FILE` and `HEIMDALL_HOME` pointed at a temp root — the seams
`heimdall-dream-schedule` and `cp-consent.sh` already document. **`heimdall_home_is_real` must
be FALSE in CI**, which is exactly the guard C1 relies on, so the suite proves the guard by
running under it.

---

## 10. Effort — dependency waves

Nine tasks, four waves. Same-wave tasks touch disjoint files.

**Wave 0 — the ledger spec (no code).**
- `LEDGER.md` — item schema, `granted_via` vocabulary, the two ordering rules, the
  revert-command contract. Written *before* any implementation so the impl transcribes rather
  than guesses.
- `items.json` — the item registry, one entry per row of §1.A/§1.B, carrying `class`,
  `carve_reason`, `env`, `flag`, `default`, `revert`, `disclosure`. **Data, not code** — adding
  an item is a data change, mirroring `default_module_names()`'s existing design.

**Wave 1 — engine + missing reverts (parallel, disjoint files).**
- `bin/heimdall-setup` — `plan` / `apply` / `receipts` / `status` / `pending`.
- `hmd statusline off` in `bin/heimdall-statusline-register` (the C3 revert).
- `--without <id>` parsing in `install.sh`; `HEIMDALL_WRAP_TOOL` in `bin/heimdall-wrap`.
- Falsifiability fixtures (golden + m1–m4), authored by a **different agent** than the engine —
  the reference half must not share the impl's misconceptions.

**Wave 2 — rewire the call sites (parallel, disjoint files).**
- `install.sh` — replace the `[ -t 0 ]` CP-URL read with a ledger lookup; add the one-screen
  disclosure; preserve every step's existing graceful-degrade behaviour.
- `bin/heimdall-presence` — delete `connect-prompt`'s blocking `read`; resolve from the ledger;
  emit only the throttled one-liner.
- `bin/heimdall-init` — register D17–D23 as repo-scope ledger items.
- `hooks/hooks.json` — add the stat-only pending sweep to SessionStart.

**Wave 3 — the differential gate.**
- Wire the unattended-vs-interactive whole-output differential; prove falsifiability score 1.0
  against m1–m4; wire it into the push quality gates.

Critical path is 0 → 1 → 2 → 3; the wave-1 and wave-2 fan-outs are where the parallelism lives.

---

## 11. Risks

| Risk | Prob | Impact | Mitigation | Owner |
|---|---|---|---|---|
| Clubbing reads as a dark pattern to a security-minded user | med | high | Disclosure is loud, complete, printed once; every line carries its revert inline; `granted_via` makes clubbing auditable after the fact; `--without` is named on the same screen | wave 2 — `install.sh` disclosure |
| The C1 guard is bypassed by a future caller who forgets the env opt-out | med | high | Ledger calls `heimdall_home_is_real` (passwd DB, `$HOME`-independent) — the floor, not the opt-out. Suite runs where the guard is FALSE, so a regression goes red | wave 1 engine + wave 3 gate |
| Property-only gate ships and passes while the applied set differs | med | high | Gate is `differential` over the whole applied-state set, with m1–m4 mutants required red | wave 3 |
| `--without` lands after prompts are removed → regulated estates stranded | low | high | Wave-1 ordering: hatches ship **before** wave 2 removes any prompt | wave 1 |
| Class-level consent gets flattened (`consent_required:false` on traffic-proxy) as a shortcut to clubbing | med | high | Forbidden in §3.1; clubbing routes through the **per-module** waiver only; add a grep assertion over `modules/_classes/*.json` to the gate | wave 3 |
| Ledger becomes a second source of truth that drifts from module receipts | med | med | Ledger *references* module receipts for module items; it never copies `consent` blocks | wave 1 engine |
| SessionStart pending sweep becomes a per-session cost | low | med | Stat-only, no preflight, no network, 24h backoff — the `cmd_pending` design verbatim | wave 2 hooks |
| A carved item is silently skipped and the user never learns | med | med | Skip writes `granted_via:"deferred"` + `reason`; surfaces in `hmd setup status` and the pending count | wave 1 engine |

---

## OUT OF SCOPE

- **Rewriting `install.sh`'s step machinery.** The 13 steps, their graceful-degrade contract and
  their telemetry emission stay exactly as they are; only *decision resolution* moves.
- **Changing any module's consent class.** `modules/_classes/*.json` is untouched. Clubbing
  routes exclusively through the per-module waiver.
- **The control-plane server side.** Enrollment stays open-bounded and tokenless; no new server
  surface, no redeploy.
- **Uninstall / teardown UX** (P7–P10). Separate concern, separate plan.
- **The external `claude` CLI's own prompts** (marketplace / plugin install). Not ours; the
  ledger records the outcome, it cannot suppress a third-party prompt.
- **Windows / Linux scheduler parity** for C1. macOS launchd only; non-Darwin stays a clean skip.
- **crontab as a first-run item.** Explicitly excluded (§3.2 C2); `deploy/` keeps its own path.
- **Telemetry schema changes.** The ledger emits existing `install_step` events; no new fields.
- **A GUI or TUI setup wizard.** §7 is explicit that a wizard hiding its changes is the anti-goal.
