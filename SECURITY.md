# Security Policy

Heimdall is a verification layer for coding agents, so we hold our own security
to the same standard we hold your code to: **nothing ships unproven — including
our own history.**

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue or pull
request. Two private channels, use whichever you prefer:

- **Email `security@runheimdall.dev`.** This reaches the maintainer directly.
  Encrypt if you like, or just send enough for us to reproduce.
- **A GitHub Security Advisory** on this repository, if private vulnerability
  reporting is enabled (Security → Advisories → *Report a vulnerability*). This
  keeps the report confidential until a fix is ready and gives us a private
  channel to coordinate. If you do not see the option, use the email above — the
  GitHub private-reporting toggle lives under the repo owner's Settings →
  Security and may not be enabled yet.

What to expect:

- **Acknowledgement target: within 72 hours.** We confirm receipt and let you
  know whether we can reproduce it.
- **Triage target: within 7 days** of acknowledgement — we tell you the severity
  we assigned, whether we accept the report, and our intended fix window.
- We work a fix and a coordinated disclosure timeline with you. We credit
  reporters who want credit; we honor requests to stay anonymous.
- **No bug bounty.** Heimdall is an MIT-licensed open-source project with no
  paid disclosure program. We are grateful for responsible reports regardless.

These are targets from a single maintainer, not a staffed rotation or a
contractual SLA. If you have not heard back within the acknowledgement window,
please assume the mail went astray and ping again rather than assume silence.

## Disclosure policy

We practice coordinated disclosure:

- **90 days** from acknowledgement is the default window to ship a fix before
  the report is made public. If we need longer, we tell you why and agree a new
  date with you rather than let it lapse silently.
- **A fix ships first, then the advisory.** We publish a GitHub Security
  Advisory once a fixed release is available, crediting you unless you asked to
  stay anonymous.
- **Actively-exploited issues move faster** — we fix and disclose as quickly as
  we can, and will not sit on a live exploit for 90 days.
- If you plan to disclose publicly on your own timeline, please tell us the
  date; we would rather ship a fix before it lands than be surprised by it.

## Supported versions

| Version | Supported |
|---|---|
| The latest released version (see [Releases](https://github.com/randomittin/heimdall/releases)) | Yes — security fixes land here |
| Any earlier release | No |

Heimdall ships from a single `main` line with no separately maintained release
branches, so a security fix is delivered as a **new release**, not a backport.
`hmd` is idempotent — re-running the installer upgrades in place. If you are
pinned to an older tag, the remedy for a security issue is to move to the latest
release.

## Safe harbor for good-faith research

We will not pursue, support, or threaten legal action against anyone who reports
a vulnerability in good faith through the private channels above — nor will we
retaliate in any other way. "Good faith" means: you make a reasonable effort to
avoid privacy violations, data loss, and service disruption; you only interact
with accounts and data you own or have explicit permission to test; and you give
us a reasonable window to remediate before public disclosure. If you are unsure
whether an action is authorized, ask us first at `security@runheimdall.dev`.

## Supported scope

| In scope                                                        | Out of scope                                              |
|-----------------------------------------------------------------|-----------------------------------------------------------|
| **The plugin:** the Heimdall harness, gates, sentinels, and hooks in this repo. | Vulnerabilities in Claude Code or the Anthropic platform — report those to their respective projects. |
| **The control plane:** the hosted presence/enrollment/dispatch service (multi-tenant team presence, enroll tokens, PKI, job dispatch). | Issues that require a user to run `--dangerously-skip-permissions` in a throwaway sandbox (that flag is documented as autonomy with no safety classifier in the loop). |
| **The site:** the public marketing/docs site and its install path. | Third-party dependencies — we will help upstream the report. |
| The latest released version on the default branch.              | Automated scanner output with no demonstrated impact, and best-practice suggestions that are not an exploitable weakness. |
| Bypasses of a quality or safety gate that let unproven code through; tenant-isolation breaks in the control plane; supply-chain integrity of the install path. |                                                           |

For which releases receive fixes, see [Supported versions](#supported-versions)
above.

## The Headroom proxy — a local process that can read your prompts

hmd has a module for **Headroom**
([`modules/headroom/manifest.json`](modules/headroom/manifest.json), Apache-2.0):
a local context-compression proxy that is **off by default** and used only on
demand. Point traffic at it and a process on your machine sits between your coding
tool and the model provider, reads the prompts and context on their way out, and
rewrites them to be smaller. That is what it is for. It is documented here because
someone auditing hmd's security posture should not have to discover it by reading a
manifest.

**A new install does not have it.** A fresh install never installs it, never loads a
launchd job for it and never points `ANTHROPIC_BASE_URL` at it; it exists on your
machine only after you run `hmd headroom on`. An install that already had the module
keeps it exactly as it is until you run `hmd headroom off`.

**Installing it is not routing traffic to it.** `hmd headroom on` installs the
package (through `hmd modules add headroom`) and starts nothing: the proxy starts,
lazily, on the first launch you route through `hmd route claude` or
`hmd wrap claude` (or a shell function of your own that calls one), and a launch
that goes another way, bare `hmd` for one, sends nothing through it, so your
traffic goes exactly where it went before. Both wires the manifest declares are
*measured* at add time rather than asserted here: `[6/7] wire` prints the wrap
chain as `ROUTED` (`bin/heimdall-wrap` references the module, so the chain it
offers can reach it, which is an offer and not traffic) and the memory-codec seam
as `RECORDED, not routed` (it reports `backend=plain`), and
`hmd modules status headroom` reads back the same record. What follows describes
what this module can reach **once you have turned it on and routed traffic
through it** — which is the state worth threat-
modelling, and the reason the scrubs below exist at all.

### What it is

- **Local, and not a Heimdall service.** It runs on your machine as a process you
  own and can inspect. hmd routes nothing to a Heimdall endpoint through it and it
  introduces no Heimdall-operated destination — your model traffic goes to the same
  provider it went to before, by way of a hop you control.
- **Not vendored.** None of Headroom's source is in this repo; hmd depends on the
  published package at the pin recorded in the manifest, which is the single source
  of truth for that pin. The forwarding behaviour is Headroom's own code, at that
  pin, under Apache-2.0 — readable at
  <https://github.com/headroomlabs-ai/headroom>.
- **Off by default, enabled by you.** `default_included: false` is a
  *distribution* fact, not a claim that it helps: the installer and the updater never
  acquire it, and no module is in the default set today. `install.sh` has no module
  code path, and `bin/heimdall-autoupdate` acquires only a module whose manifest says
  `default_included: true`. A module that requires consent and does not waive it is
  never acquired unattended even then — that would mean passing `--yes` on your
  behalf, which is a forged signature rather than an install path — so the updater
  names it and prints the command instead. You turn Headroom on with
  `hmd headroom on` and off with `hmd headroom off` (below).
- **One fixed upstream.** The chain is client → Headroom → `api.anthropic.com`. It
  pins the proxy's upstream to that provider and refuses a proxy whose own `/health`
  reports any other, so "no new destination" is checked from the running process
  rather than asserted here. OmniRoute is never chained behind it: when the OmniRoute
  fallback gate says ROUTE, `hmd route` sends that launch to OmniRoute and Headroom
  compression is off for it.

### What it can and cannot reach

| Traffic | Through the proxy? | What enforces that |
|---|---|---|
| Model **generation** traffic from your coding tool | **Only on a launch you route there, with the module on** — that is the module's purpose, and a fresh install routes nothing | Nothing points generation at the proxy until you run `hmd headroom on` and launch through `hmd route claude` or `hmd wrap claude`, and only `claude` reads the `ANTHROPIC_BASE_URL` those set. The `wrap-chain` wire is measured at add time, not asserted: `[6/7] wire` and `hmd modules status headroom` report it `ROUTED` because `bin/heimdall-wrap` references the module, which is an offer of the hop and not traffic. Falsifier: [`test/wire-kind-dispatch.test.sh`](test/wire-kind-dispatch.test.sh), which measures the wire against the repo and refuses any declared wire kind the code has no handler for |
| Any call that produces a **verdict** (gate, oracle, verifier, panel) | **No** | `hmd_gate_exec` in [`bin/lib/hmd-gate-endpoint.sh`](bin/lib/hmd-gate-endpoint.sh) unsets `ANTHROPIC_BASE_URL`, the HTTP/HTTPS/ALL/NO_PROXY pairs and the whole `HEADROOM_*` namespace, then pins the endpoint to the real provider. Falsifier: [`test/gate-judgment-uncompressed.test.sh`](test/gate-judgment-uncompressed.test.sh) |
| **Control-plane, enrollment, team and presence** traffic | **No** | `hmd_signed_exec` in the same file. [`test/cp-signed-no-rewriting-proxy.test.sh`](test/cp-signed-no-rewriting-proxy.test.sh) is a runtime differential with a positive control, and it **fails closed**: an unreachable control plane reports `NON_VERIFIED` and fails the invariant rather than passing quietly |

**Why judgment is the hard line.** A judge reading compressed context emits
confident false greens — the one failure mode this project exists to prevent. So
the scrub is applied at the gate-*execution* boundary rather than inside any single
client, which is what makes it cover the whole chain instead of one caller. The
signed path is deliberately narrower than the judgment path: a corporate
`HTTPS_PROXY` **survives** it, because such a proxy CONNECT-tunnels TLS, cannot
rewrite signed bytes, and is often an estate's only egress — blanket-bypassing it
would break hmd for those operators to defend against a threat their proxy does not
pose.

### Consent is waived. Disclosure is not.

Headroom carries `consent_waived: true` on its own manifest, so `hmd modules add
headroom` discloses and proceeds rather than stopping to ask. The waiver stays now
that Headroom is off by default: your own `hmd headroom on` is the request, so the
add path does not ask the same question a second time. This is a deliberate
decision by the maintainer, and its blast radius is exactly one module:
[`modules/_classes/traffic-proxy.json`](modules/_classes/traffic-proxy.json) still
reads `consent_required: true`, so every other traffic-proxy module hmd ever ships
still asks. Waiving the field on the *class* would have silently disarmed consent
for modules nobody has written yet.

What the waiver does **not** change: the consent text still prints at add time,
both declared class contracts still run their invariants with the module active,
and the receipt records `granted_via: manifest-waiver` so the waiver is visible
after the fact rather than indistinguishable from a yes you typed.

### The remote-install caveat

**Turning Headroom on performs a remote code install and verifies no digest.**
`hmd headroom on` runs `hmd modules add headroom` when the module is absent, and that
is where the install happens. Stated plainly, because it is the sharpest thing on
this page:

- The fetch is `uv tool install --python 3.13 "headroom-ai[all]==<pin>"`, resolved
  from PyPI at install time and executed as you.
- hmd hashes **nothing** on that path. The lifecycle step is named
  `install + provenance` rather than `digest-verify` precisely so it cannot imply a
  check that never ran. A digest is verified on exactly one path — a `local` module
  whose artifact ships in this repo — and Headroom is not one.
- The receipt records `verified: false` in every upstream state, together with the
  pin it did **not** check. Nothing re-checks it afterwards either: `hmd modules
  verify` re-runs the class invariants and reads no digest at all.
- Trust therefore rests on PyPI, on `uv`, and on the upstream project — the same
  trust any `pip install` asks for, stated here rather than left implied.
- It pulls an ML stack (Rust wheels, an ONNX runtime, HuggingFace tokenizers), so
  install size and time are materially larger than hmd's own. This is the one place
  hmd stops being near-stdlib.

A failed Headroom install breaks nothing: the module reports ABSENT with the blocker
named and rolls back, and hmd keeps working without it.

### How to decline it, or remove it

`hmd headroom off` is the first-class way to turn Headroom off, and a new install
does not have it at all unless you run `hmd headroom on`. Underneath, two surfaces
read opt-out signals, and they do **not** overlap — each verb honours the signals of
the surface it belongs to:

| Signal | Read by | Effect |
|---|---|---|
| `hmd headroom off` | `bin/heimdall-headroom` | the first-class way to turn it off: records the module opt-out, so `hmd route` and `hmd wrap` decline and launch direct (or to the OmniRoute fallback when its gate says ROUTE); unloads and removes a launchd supervisor job if one was installed; removes an `ANTHROPIC_BASE_URL` entry in your Claude `settings.json` `env` when it equals the proxy URL; stops the idle proxy when no session is routed through it. It **refuses** (exit 3, nothing changed) inside a session that is currently routed through the proxy unless `--next-session` is given. Everything it changes is backed up first under `~/.heimdall/headroom/off-backup/<UTC-stamp>/` (override: `--backup-dir DIR` or `HMD_HEADROOM_BACKUP_DIR`), with a `CHANGES.txt` giving the undo for each change |
| `hmd headroom off --next-session` | `bin/heimdall-headroom` | for a session that is running through the proxy: changes configuration only, leaves the running proxy alone, needs no tty, is idempotent and exits 0 when Headroom is already off; a launchd job it disables is re-enabled by `hmd headroom on` |
| `hmd modules optout headroom` | `bin/heimdall-modules` | persisted as this tool's own record; nothing re-installs it, and `repair`, `defer` and `pending` refuse to act |
| `HMD_MODULE_OPTOUT=headroom` | `bin/heimdall-modules` | the same, for a single invocation |
| `HEIMDALL_NO_MODULES=1` | `bin/heimdall-autoupdate` | no module is acquired automatically, at all |
| `~/.heimdall/modules-optout` | `bin/heimdall-autoupdate` | one module name per line, read on the updater's acquisition path. Nothing in this repo *writes* this file — an operator writes it by hand |

`install.sh` reads none of these, because it acquires no modules in the first
place: there is no installer flag to suppress and none is offered. Every module and
updater signal above governs acquisition that would happen **on your behalf**, so
`HEIMDALL_NO_MODULES=1` does not block an explicit `hmd modules add` — an operator
typing the command themselves is not what an opt-out for unattended installs is
trying to stop.

**Off is not removal; removal is total.** `hmd headroom off` switches Headroom off
and leaves the installed module in place. To delete the install entirely,
`hmd modules remove headroom` unwinds through the same `remove_module()` path a
failed install rolls back through, which is what makes the result byte-identical
rather than merely tidy, and `uv tool uninstall headroom-ai` removes the tool itself.

## Auto-commit — hmd can commit your working tree without being asked

hmd's own checkpoint mechanism (`bin/heimdall-autocommit`, wired from two call
sites in [`hooks/hooks.json`](hooks/hooks.json)) can create a git commit on your
behalf, mid-session, with no prompt — on by default. Anyone auditing a tool that
mutates repository history unattended should not have to find this by reading
hook JSON, so it is documented here.

### What it does

- **Two triggers.** Once 5 or more tracked files are dirty (a PostToolUse check),
  or at session end if anything is dirty at all (a SessionEnd check), hmd stages
  and commits a checkpoint titled `heimdall: <phase> (N files)`.
- **Scoped staging — never `git add -A`.** Only paths this session's own
  Write/Edit tool calls touched (per `edit-tracker paths`) *and* are currently
  dirty get staged: the intersection of the two, recomputed every time. A file
  that is dirty for any other reason — a different tool, a manual edit, an
  unrelated change already in progress — is left alone. An empty intersection,
  including a missing or empty edit ledger, commits nothing; there is no
  fallback to staging everything else in the tree.
- **The commit bypasses your commit gate.** It runs `git commit --no-verify`, so
  a local `pre-commit` hook (a secret scan, a lint check, anything `hmd init`
  wired for you) does **not** run for this commit. That is a deliberate
  trade-off — a checkpoint must never block on a slow or failing gate — but it
  means an auto-commit is, by construction, exactly as unproven as one made with
  `HMD_SKIP=1`.
- **The bypass is logged, never silent.** Every auto-commit appends a line to
  `.heimdall/receipts/unproven.log` — the same ledger `HMD_SKIP=1` writes to,
  tagged `AUTOCOMMIT` instead of `HMD_SKIP` — and prints a one-line stderr
  notice naming the receipt path. Grep that file to see how many of your
  commits never saw your gate.

### How to decline it

| Signal | Effect |
|---|---|
| `heimdall --no-autocommit` | creates `.heimdall-no-autocommit` in the repo root and disables both triggers there |
| `heimdall --autocommit` | removes it, re-enabling auto-commit |
| `/hmd:autocommit` (Claude Code command) | reports current state with no args; pass `on`/`off` to set it explicitly from inside a session |
| `.heimdall-no-autocommit` or `.superx-no-autocommit` (a file, dropped in the repo root by any means) | read directly by both the CLI and the hook — the marker, not the command, is the actual switch |

Declining it does not disable edit *tracking* — `edit-tracker` keeps logging what
you touch either way — it only stops hmd from committing on your behalf. You
keep full manual control of when, and what, to commit.

## Secret hygiene

Heimdall treats leaked credentials as a build defect, not an afterthought — and
it points that policy at itself first.

- **A standing secret-scan gate guards every push.** Heimdall's security sentinel
  runs [`gitleaks`](https://github.com/gitleaks/gitleaks) over the working tree
  and the commit range a push would publish, before any code leaves the machine.
  A finding is a hard fail: the push is blocked until the credential is removed
  and rotated. This is the same `git push` gate that re-triggers the
  falsifiability and corpus checks — security is part of the proof, not a
  side-channel.
- **It can run earlier too.** The same scan is safe to wire as a local
  pre-commit step so a credential is caught before it is ever recorded, not just
  before it is pushed. The gate is designed to run at whichever boundary you put
  it on.
- **It degrades honestly, never falsely.** If no scanner is installed, the gate
  reports *skipped* and names the missing tool — it never reports "clean" without
  a real scanner having actually run and found nothing. A pass means a real tool
  ran; a skip means go install one. (Install `gitleaks` to get a real verdict;
  `trufflehog` is a supported fallback.)
- **The principle:** a verification system that cannot prove its own history is
  clean cannot be trusted to prove yours. So the same secret scan that protects
  contributors protects this repository's own commits — credentials are kept out
  of history by construction, not by hope.

If you find a credential that did make it into the tree, please report it through
the private channel above rather than opening a public issue, so it can be
rotated before attention is drawn to it.

The same scan runs in CI as a bypass-proof backstop:
[`.github/workflows/public-repo-no-secrets.yml`](.github/workflows/public-repo-no-secrets.yml)
runs a sha256-pinned `gitleaks` over the full history on every push and pull
request, so a credential cannot land in the public repo even if a local gate was
skipped.

## Release integrity and verification

The install path is part of the attack surface, so it is signed and verifiable —
do not take our word that a downloaded `install.sh` is authentic, check it:

- **Every release signs `install.sh`** with [minisign](https://jedisct1.github.io/minisign/)
  (Ed25519) and publishes `install.sh.minisig` as a release asset. The public
  key ships in the repo at `release/heimdall-signing.pub`.
- **The one-liner in [`README.md`](README.md) is tag-pinned and sha256-checked** —
  it refuses to execute if the downloaded bytes do not match the digest.
- **The auto-updater is fail-closed:** with no signing public key present it
  refuses to apply a release rather than trusting it.

Full model — the verifier refusal codes, the bundled pure-python verifier for
machines without the `minisign` binary, and the signing workflow — is in
[`SIGNING.md`](SIGNING.md).
