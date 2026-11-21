# Install

What `install.sh` runs, what it writes outside the repo, what leaves your machine, and the three ways to run it. The [README](../README.md#install) carries the pinned, sha256-checked one-liner; this page is the disclosure behind it. It was moved here verbatim from the README (RP10) and is the full text, not a summary.

Three paths. Each is labelled with what it actually does to your machine — pick the risk you are willing to take, not the shortest command.

| # | Path | What it runs | Honest risk |
|---|---|---|---|
| **1** | **One-liner** (below) | Downloads `install.sh`, checks its sha256, then **runs it as you** | **Highest.** A script fetched over the network, executing with your user's privileges — it can do anything you can do. The digest check is the only thing between you and whatever those bytes are. Verify it, or take path 3. |
| **2** | **npm** — `npx runheimdall` | The same `install.sh`, fetched over https and sha256-checked against a digest baked in at publish time ([`bin/runheimdall.js`](../packages/runheimdall/bin/runheimdall.js)), then handed to `bash` | **Same as path 1.** The wrapper is thin and the script still runs as you. You gain not having to hand-copy a digest. You gain no isolation. |
| **3** | **Docker sandbox** — [`Dockerfile.install`](../Dockerfile.install) | The same `install.sh`, **copied from your own clone** — nothing fetched, no digest to trust — run **inside a container** | **Lowest, with real caveats.** Every `$HOME` change lands in a layer you delete. It does **not** isolate a repo you mount, and it is not a macOS sandbox. [Caveats below.](#path-3--the-docker-sandbox) |

**Whichever you pick, this is what the installer writes outside the repo.** Measured from a real run against a throwaway `$HOME`, not asserted:

| Written | What it is |
|---|---|
| `~/.heimdall/` | A full git clone of this repo — the installed checkout `hmd` runs from |
| `~/.local/bin/hmd`, `~/.local/bin/heimdall` | Symlinks into `~/.heimdall/bin/heimdall` |
| `~/.claude/settings.json` | Adds `statusLine` + `subagentStatusLine`, and registers the plugin under `enabledPlugins` / `extraKnownMarketplaces`. Honors `$CLAUDE_CONFIG_DIR`, and never clobbers a `statusLine` you set yourself |
| `~/.zshrc` / `~/.bashrc` / `~/.profile` | One appended `export PATH=…` line for `~/.local/bin` — only when it is not already on `PATH` |
| `~/Library/LaunchAgents/com.heimdall.dream.plist` | **macOS only** — a nightly 03:00 LaunchAgent (`com.heimdall.dream`) that runs the overnight sweep with no session open and survives logout and reboot. Opt out with `HEIMDALL_NO_DREAM_SCHEDULE=1` |
| `~/.heimdall/team.json` | An auto-minted solo **team secret**, written by the post-install health check on every run (`heimdall-doctor-install`, deliberately pinned to `$HOME`) whether or not you supplied a team invite. A bearer capability — treat it like a credential |

One thing that table leaves out because it does not fit "outside the repo": pasting a team invite (`HEIMDALL_TEAM_SECRET='<secret>' curl -fsSL … | bash`) writes a SECOND, real team.json inside whatever repo your shell was in when you ran the installer — `<repo>/.heimdall/team.json`, resolved from that shell's git toplevel at install time, never `~/.heimdall` (`ensure_team_secret`, `install.sh:520-537`). Measured the same way as the table above: a throwaway git-toplevel cwd distinct from `$HOME` got the file; the throwaway `$HOME` did not.

No sudo. Idempotent — re-run to upgrade. `hmd uninstall` reverses all of it.

**Network posture is default-ON.** Team presence and the cloud features reach the control plane as soon as you use them: a signed heartbeat carrying your handle, verdict, and current filename — scoped to your team, never your code or file contents. That is a feature, and it is on until you switch it off. `hmd presence sever` gives zero egress. Field-by-field contract: [DATA.md](../DATA.md). The precisely scoped claims are under [Your code stays yours](../README.md#your-code-stays-yours).

**Headroom, a local proxy that can read your prompts, is off by default and used only on demand. Once you turn it on, `hmd wrap claude` and `hmd route claude` route generation traffic through it; not every `hmd wrap <tool>` does — see below.** [Headroom](ARCHITECTURE.md#headroom--the-one-shipped-module-and-its-honest-limits) is `default_included: false` in [`modules/headroom/manifest.json`](../modules/headroom/manifest.json): a **local** context-compression proxy which, once traffic is pointed at it, sits between your coding tool and the model provider, reads the prompts and context on their way out, and rewrites them to be smaller. `hmd headroom on` runs `hmd modules add headroom` when the module is absent, which installs the package, then measures each wire the manifest declares and reports what it found: the wrap chain measures `ROUTED`, meaning `bin/heimdall-wrap` offers the proxy hop to every tool it launches — not that every tool's traffic actually flows through it. Only `claude` reads the `ANTHROPIC_BASE_URL` this repo sets, so `hmd wrap claude` is the one launch that truly carries GENERATION traffic through the proxy; `hmd wrap codex`/`hmd wrap gemini` set the same variable on a CLI that never reads it, so their generation traffic is NOT routed despite the wire measuring `ROUTED`, and `hmd wrap cursor`/`hmd wrap aider` are unconfirmed either way. Bare `hmd` does not route. The storage-codec wire still measures `RECORDED, not routed`. JUDGMENT never traverses it — every verdict-producing call is scrubbed back to the real provider, which `test/gate-judgment-uncompressed.test.sh` goes red on. It runs as a process you own and can inspect, and it introduces no Heimdall-operated destination — that traffic goes to the same provider it went to before. Six things to know before you turn it on:

- **Nothing installs it for you, and nothing loads it.** A fresh install never installs it, never loads a launchd job for it and never points `ANTHROPIC_BASE_URL` at it. `install.sh` has no module code path at all, and the background updater only acquires a module whose manifest says `default_included: true`, which none does today. Until you run `hmd headroom on`, `hmd modules status headroom` reports `NOT ATTEMPTED`. An install that already has the module keeps it exactly as is until you run `hmd headroom off`.
- **On and off are `hmd headroom on|off|status`.** `on` runs `hmd modules add headroom` when the module is absent, clears a prior opt-out and re-enables a launchd job that `off --next-session` disabled. It does not start the proxy: that starts on the first launch routed through `hmd route claude` or `hmd wrap claude` (or a shell function you keep, `claude() { command hmd route claude "$@"; }`). `off` records the module opt-out (route and wrap then launch direct, or to the OmniRoute fallback when its gate says ROUTE), removes a launchd supervisor job if one was installed, removes an `ANTHROPIC_BASE_URL` entry in your Claude `settings.json` `env` when it equals the proxy URL, and stops the idle proxy when no session is routed through it. Inside a session that is routed through the proxy it refuses (exit 3, nothing changed) unless you pass `--next-session`, which changes configuration only and leaves a running proxy alone. Everything `off` changes is backed up first under `~/.heimdall/headroom/off-backup/<UTC-stamp>/`. `hmd headroom status` prints the module state, the proxy on the port, launchd supervision and whether this session is routed. The full list of what `off` changes: [SECURITY.md](../SECURITY.md#how-to-decline-it-or-remove-it).
- **Turning it on is a remote code install when the module is absent, and no digest is verified.** `hmd headroom on` runs `hmd modules add headroom`, which runs `uv tool install --python 3.13 "headroom-ai[all]==<pin>"` against PyPI. hmd hashes nothing on that path and does not claim to: the lifecycle step is named `install + provenance`, not `digest-verify`, and the receipt records `verified: false` alongside the pin it did not check. It also pulls an ML stack — Rust wheels, an ONNX runtime, HuggingFace tokenizers — so this is the one place hmd stops being near-stdlib.
- **The consent question is waived; the disclosure is not.** `consent_waived` sits on that one module's manifest. [`modules/_classes/traffic-proxy.json`](../modules/_classes/traffic-proxy.json) still reads `consent_required: true`, so every other traffic-proxy module hmd ships still asks. The consent text still prints, both declared class contracts still run their invariants, and the receipt records `granted_via: manifest-waiver`. This is a deliberate maintainer decision: disclosed, not asked. Now that Headroom is off by default, your own `hmd headroom on` is the request, so the question is not asked a second time.
- **Installing it is not routing to it, and hmd measures the difference out loud.** The manifest declares two wires. `[6/7] wire` prints each one next to the measurement that produced it: the wrap chain reads `ROUTED` because `bin/heimdall-wrap` references the module, so the chain it offers can reach it, and the memory-codec seam reads `RECORDED, not routed` because it reports `backend=plain`; `hmd modules status headroom` reads back that same record. Offering the hop moves no traffic by itself: only a launch through `hmd route claude` or `hmd wrap claude`, with the module on, carries generation traffic through the proxy. A declared wire whose kind the code has no handler for is refused at validate rather than quietly recorded, so a module cannot install while claiming a capability hmd does not deliver ([`test/wire-kind-dispatch.test.sh`](../test/wire-kind-dispatch.test.sh)).
- **Gates read raw, and signed traffic steps around it.** Route generation through a proxy — this one, or your employer's — and judgment still may not follow it. Verdict-producing commands run through `hmd_gate_exec`, and control-plane, enrollment and presence traffic through `hmd_signed_exec` ([`bin/lib/hmd-gate-endpoint.sh`](../bin/lib/hmd-gate-endpoint.sh)); both drop `ANTHROPIC_BASE_URL`, the proxy pairs and the whole `HEADROOM_*` namespace before pinning the endpoint to the real provider. [`test/gate-judgment-uncompressed.test.sh`](../test/gate-judgment-uncompressed.test.sh) goes red the moment a gate request reaches the proxy.

`hmd headroom off` turns it off and leaves the installed module in place; `hmd modules remove headroom` returns the tree byte-identically, and `uv tool uninstall headroom-ai` removes the tool itself. Threat model, the full reachability table and every way to decline it: [SECURITY.md](../SECURITY.md#the-headroom-proxy--a-local-process-that-reads-your-prompts). Mechanics and honest limits: [Modules](ARCHITECTURE.md#modules).

## Path 1 — the one-liner

The pinned one-liner is the first command in the [README](../README.md#install): it downloads the pinned tag's `install.sh`, checks its sha256, then runs it. The `&&` chain is load-bearing: if the bytes do not match the digest, `shasum -c` prints `FAILED` and **nothing runs** — so a tag moved under you, a CDN cache poisoning, or a truncated download stops the install instead of executing. On a Linux box without `shasum`, `sha256sum -c -` takes the same digest. Re-derive the digest yourself any time: hash the tag's `install.sh` (`curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/<tag>/install.sh | shasum -a 256`, with `<tag>` the tag the README pins) and compare it with the digest printed in the README.

No sudo. Idempotent — re-run to upgrade. Reversible:

```bash
hmd uninstall    # removes everything; nothing else was touched
```

**Prefer to inspect first?** Download the script to a file, run the same `shasum -a 256 -c -` check as the README block, read it (`less heimdall-install.sh` — function-wrapped, no eval, no base64: what you read is what runs), then `bash heimdall-install.sh`.

**Signature (stronger than the digest).** A digest you copy from the README only proves the bytes match what the README says; a signature proves they came from the maintainer's key. Every release signs `install.sh` with minisign and publishes `install.sh.minisig` as a release asset; the README shows the two commands that verify it. The public key ships in this repo at `release/heimdall-signing.pub`, so those commands assume a clone. [`SIGNING.md`](../SIGNING.md) has the full model — including the bundled pure-python verifier for machines with no `minisign` binary, and the fail-closed behavior of the auto-updater.

**Prerequisites:** Claude Code 1.0+ · Git · `jq` (`brew install jq`) — `install.sh` itself completes without `jq` (every call site there guards with `command -v jq`), but most `hmd` subcommands hard-require it afterward, so install it up front

hmd is itself a Claude Code plugin, so Claude Code is what installs and runs it. If Cursor CLI's `agent` (`cursor-agent`) is also on `PATH`, `hmd init` gates that host too — see [Also gates Cursor CLI](ARCHITECTURE.md#also-gates-cursor-cli).

## Path 2 — npm

[`npx runheimdall`](https://www.npmjs.com/package/runheimdall) — same pinned tag, same sha256 check, zero clone required. It fetches the pinned `install.sh`, verifies it against the digest baked in at publish time, and aborts before executing anything if the bytes disagree. Convenience, not containment: what finally runs is the same script, with the same privileges as path 1.

## Path 3 — the Docker sandbox

For a first look that does not touch your machine. Build from a clone, so the `install.sh` you read is byte-for-byte the one that runs — nothing is fetched, so there is no digest for you to trust:

```bash
git clone https://github.com/randomittin/heimdall && cd heimdall
less install.sh                                     # what you read is what runs
docker build -f Dockerfile.install -t heimdall-sandbox .
docker run --rm -it heimdall-sandbox                # hmd is already on PATH
```

`--rm` discards every `$HOME` mutation in the table above the moment the container exits. The image also drops the auto-minted `team.json` during the build, so containers never share one team secret.

**What the container does not isolate** — a sandbox you misunderstand is worse than no sandbox:

- **A mounted repo is not isolated.** `-v "$PWD:/work"` is a hole you punched on purpose: anything `hmd` writes under `/work` lands on your real disk. Mount `:ro` if you only want `hmd` to read your code.
- **It is not a macOS sandbox.** The image is Linux, so launchd and the keychain do not exist inside it and the nightly LaunchAgent step is skipped as `unsupported`. That is the container being a different OS — not a boundary defending your account. `launchctl` and the keychain are **account-scoped**: a fake `$HOME` relocates only the plist *file*, while `launchctl load` still registers the job in your real per-user session. A sandboxed test in this repo learned that the hard way, by rewriting the developer's live LaunchAgent. The switch is `HEIMDALL_NO_DREAM_SCHEDULE=1` — never `$HOME`.
- **The network is open.** The build clones from GitHub, and presence is on by default. `docker run --network none` gives the container zero egress; `hmd presence sever` does the same at the application level.

## Recommended skills and consent

The skill registry (`skills.manifest.json`) is behind the flag `skills.registry`, default off (env `HMD_SKILLS_REGISTRY`). With it off, install behaves as before.

- **Existing installs are grandfathered:** consent mode `auto`, today's behaviour, nothing new asked.
- **New installs default to `ask`:** hmd shows the recommended skills with their source and the reason, once, and installs only what you choose. A non-interactive run (an agent, mid-task) installs nothing and records the skill as `suggested`. Modes: `ask`, `allowlist`, `auto`; set with `hmd skills consent [ask|allowlist|auto]` and `hmd skills allow <id>`.
- `hmd skills suggest` lists recommended skills not installed and the ones this project's files trigger; it never installs. `--reset` forgets earlier declines.
- `hmd skills install <id|--recommended>` is the consented path. Without a tty it exits 3 ("consent required") unless you pass `--yes`.
- `hmd skills list` shows tier, state, source and pin; `hmd skills why <id>` shows why a skill is in the lock; `hmd skills lock [--verify]` rebuilds the lock from what is installed (`--verify` reports drift without writing).
- Consent settings are per operator (`$HEIMDALL_HOME/skills-config.json` or env); a repository cannot set them.
- Consent is cooperative for a raw `claude plugins install` typed by an agent: the Bash hook does not deny it. Agents are told to go through `hmd skills install`.

Guardrails are tiered in `guardrails.manifest.json`. `hmd guardrails list|why|off|on` shows and records the choice; `core` guards cannot be turned off. `hmd guardrails off` records the choice now; the per-guard switches inside the Bash and Agent hooks are pending operator approval and land with it.

## Disk clean-up

`hmd agents prune` compresses or deletes the transcripts of old, finished subagents (`~/.claude/projects/<project>/<session>/subagents/agent-*`, gigabytes after a long session): a dry run that lists the count and the bytes unless you pass `--compress` (gzip in place, read back with `gzip -dc FILE.gz`) or `--delete` (asks first, or `--yes`); it never touches a running session, a main transcript or anything outside `~/.claude/projects`; `hmd agents prune --help` lists the options.

Once a day, on session start, a detached hook (`agents-auto-prune`) runs `hmd agents prune --compress --older-than 14d` for you, so the transcripts of subagents that finished more than two weeks ago shrink without anyone remembering to. It compresses and never deletes (deleting stays a manual `hmd agents prune --delete`), it skips a session that has a live process or was written to in the last 10 minutes, it prints nothing, and it adds one line (the bytes reclaimed) to `~/.heimdall/logs/agents-prune.log`. It is on by default. Off: `HMD_AUTO_PRUNE=off` in the environment Claude Code runs in, or `hmd guardrails off agents-auto-prune` (back on with `hmd guardrails on agents-auto-prune`). The age is `HMD_AUTO_PRUNE_DAYS` (default 14, never fewer than 3); a run that hangs is stopped after `HMD_AUTO_PRUNE_TIMEOUT_S` seconds (default 600) and the next day continues from there.

## Self-maintenance (auto-update + self-heal)

hmd keeps itself and its host current, in the background, on session start — both are
throttled (~24h), detached (never block the session), idempotent, and opt-out:

- **Plugin auto-update** (`bin/heimdall-autoupdate`): checks the installed version vs the
  latest GitHub release; if newer, re-runs the latest installer in the background (takes
  effect next launch; never hot-swaps the running session). Off: `HEIMDALL_NO_AUTOUPDATE=1`
  or `~/.heimdall/no-autoupdate`.
- **Claude Code self-heal** (`bin/heimdall-cc-selfheal`): on a NATIVE Claude Code install,
  auto-repairs the "✘ Auto-update failed" class — a stale npm-global `@anthropic-ai/claude-code`
  conflicting with the native updater. It removes ONLY that conflicting package, ensures
  `autoUpdates:true`, and re-runs `claude update`. Never touches an npm/brew-managed install,
  never uninstalls anything else, never touches credentials. Off: `HEIMDALL_NO_SELFHEAL=1`
  or `~/.heimdall/no-selfheal`. Inspect: `heimdall-cc-selfheal status`.
- **Default module reconciliation** (same updater): compares the installed [modules](ARCHITECTURE.md#modules)
  against the default set, the manifests marked `default_included: true`. No module is in
  it today (Headroom is opt-in, `hmd headroom on`), so there is nothing for it to acquire.
  A module added to it later whose class requires consent, and which does not waive it, is
  **never** acquired here — it is named, with the `hmd modules add` command to run. Off: `HEIMDALL_NO_MODULES=1` or
  `~/.heimdall/modules-optout`. Inspect: `heimdall-autoupdate status`.
