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

**hmd's default module set includes a proxy that can read your prompts. `hmd wrap claude` routes generation traffic through it; not every `hmd wrap <tool>` does — see below.** [Headroom](ARCHITECTURE.md#headroom--the-one-shipped-module-and-its-honest-limits) is `default_included: true` in [`modules/headroom/manifest.json`](../modules/headroom/manifest.json): a **local** context-compression proxy which, once traffic is pointed at it, sits between your coding tool and the model provider, reads the prompts and context on their way out, and rewrites them to be smaller. `hmd modules add headroom` installs the package, then measures each wire the manifest declares and reports what it found: the wrap chain measures `ROUTED`, meaning `bin/heimdall-wrap` offers the proxy hop to every tool it launches — not that every tool's traffic actually flows through it. Only `claude` reads the `ANTHROPIC_BASE_URL` this repo sets, so `hmd wrap claude` is the one launch that truly carries GENERATION traffic through the proxy; `hmd wrap codex`/`hmd wrap gemini` set the same variable on a CLI that never reads it, so their generation traffic is NOT routed despite the wire measuring `ROUTED`, and `hmd wrap cursor`/`hmd wrap aider` are unconfirmed either way. Bare `hmd` does not route. The storage-codec wire still measures `RECORDED, not routed`. JUDGMENT never traverses it — every verdict-producing call is scrubbed back to the real provider, which `test/gate-judgment-uncompressed.test.sh` goes red on. It runs as a process you own and can inspect, and it introduces no Heimdall-operated destination — that traffic goes to the same provider it went to before. Five things to know before you install:

- **Nothing installs it for you.** `install.sh` has no module code path at all, and the background updater refuses to acquire a consent-required class unattended — it names the module and hands you the command. Until you run `hmd modules add headroom`, `hmd modules status headroom` reports `NOT ATTEMPTED`.
- **That command is a remote code install, and no digest is verified.** It runs `uv tool install --python 3.13 "headroom-ai[all]==<pin>"` against PyPI. hmd hashes nothing on that path and does not claim to: the lifecycle step is named `install + provenance`, not `digest-verify`, and the receipt records `verified: false` alongside the pin it did not check. It also pulls an ML stack — Rust wheels, an ONNX runtime, HuggingFace tokenizers — so this is the one place hmd stops being near-stdlib.
- **The consent question is waived; the disclosure is not.** `consent_waived` sits on that one module's manifest. [`modules/_classes/traffic-proxy.json`](../modules/_classes/traffic-proxy.json) still reads `consent_required: true`, so every other traffic-proxy module hmd ships still asks. The consent text still prints, both declared class contracts still run their invariants, and the receipt records `granted_via: manifest-waiver`. This is a deliberate maintainer decision: disclosed, not asked.
- **Installing it is not wiring it, and hmd measures the difference out loud.** The manifest declares two wires and hmd applies neither. `[6/7] wire` prints each one as `RECORDED, not routed` next to the measurement that produced it — `bin/heimdall-wrap` holds no reference to the module, and the memory-codec seam reports `backend=plain` — and `hmd modules status headroom` reads back that same record. A declared wire whose kind the code has no handler for is refused at validate rather than quietly recorded, so a module cannot install while claiming a capability hmd does not deliver ([`test/wire-kind-dispatch.test.sh`](../test/wire-kind-dispatch.test.sh)).
- **Gates read raw, and signed traffic steps around it.** Route generation through a proxy — this one, or your employer's — and judgment still may not follow it. Verdict-producing commands run through `hmd_gate_exec`, and control-plane, enrollment and presence traffic through `hmd_signed_exec` ([`bin/lib/hmd-gate-endpoint.sh`](../bin/lib/hmd-gate-endpoint.sh)); both drop `ANTHROPIC_BASE_URL`, the proxy pairs and the whole `HEADROOM_*` namespace before pinning the endpoint to the real provider. [`test/gate-judgment-uncompressed.test.sh`](../test/gate-judgment-uncompressed.test.sh) goes red the moment a gate request reaches the proxy.

`hmd modules remove headroom` returns the tree byte-identically. Threat model, the full reachability table and every way to decline it: [SECURITY.md](../SECURITY.md#the-headroom-proxy--a-local-process-that-reads-your-prompts). Mechanics and honest limits: [Modules](ARCHITECTURE.md#modules).

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
  against the default set. A module whose class requires consent is **never** acquired here —
  it is named, with the `hmd modules add` command to run. Off: `HEIMDALL_NO_MODULES=1` or
  `~/.heimdall/modules-optout`. Inspect: `heimdall-autoupdate status`.
