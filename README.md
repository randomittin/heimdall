# Heimdall

**Nothing ships unproven.** Verification gates for coding agents — catches what the model misses, proves it did.

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-e056a0?style=flat-square)](https://code.claude.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-9b59b6?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.1.0-00d4ff?style=flat-square)](CHANGELOG.md)

## Install

Lead path — one command, zero to running:

```bash
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.0.1/install.sh | bash
```

> The branded one-liner `curl -fsSL https://runheimdall.dev/install | bash` is **coming** — it is a 302 to the pinned release tag on GitHub (brand on the line, verifiability intact). Until the redirect is live, the raw GitHub pinned-tag URL above is the working, byte-identical path.

**Prefer to read it first?** (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.0.1/install.sh -o install.sh
less install.sh        # short, function-wrapped, no sudo, no prompts, no telemetry —
                       # resolves to a pinned tag, so what you read is what runs
bash install.sh
```

**npm-native?** `npx runheimdall` is **coming** — a thin wrapper that fetches and runs the same pinned script. Until it is published, use the raw pinned-tag curl one-liner above.

**Already in the Claude Code plugin ecosystem?**

```bash
claude plugins marketplace add randomittin/heimdall
claude plugins install hmd@heimdall
```

## Then

```bash
hmd demo               # `heimdall demo` works too — hmd is the short form, same binary
```

## Inside Claude Code

```
/hmd:verify   /hmd:save   /hmd:debloat     # all commands live under the hmd: namespace
```

## What Heimdall will never do — and how to undo it

No telemetry. No network calls home. No sudo. No writes outside its own dir. MIT. Read the source.

```bash
hmd uninstall          # remove completely: deletes the plugin dir; nothing else was touched
```

Reversibility is the point — `hmd uninstall` is the trust line that lowers the activation energy of a curl-pipe install.

---

## What it is

Heimdall is a verification layer for coding agents. It brings and wires the canonical *external* oracle for a domain, makes every gate **falsifiable** — proven able to go red before it is trusted green — and catches the bug class that emits no local signal: ordering races, whole-sequence invariants, and missing subsystems that sail through a naive green test suite. It keeps a growing corpus of real failure cases and replays them on every change, so a regression that once shipped can never ship twice.

The delta Heimdall sells is verification, not generation. With the model held constant, raw agents and Heimdall produce roughly equivalent code; what Heimdall adds is the proof that the code is correct — and the receipt that proves the proof can fail.

---

## Five-minute entry doors

Each of these runs on a fresh machine with only the documented prerequisites. Doors marked *coming* are specified but not yet shipped.

```bash
hmd demo                          # scaffold a real full-stack task; --run builds it and ends in a summary card + reel + a follow-up prompt
heimdall-debloat --report-only    # zero-risk: point it at any repo, get a bloat scorecard, change nothing
heimdall-bench                    # reproduce the public benchmark table on your own machine (dry by default, zero API spend)
```

A fourth door — `heimdall spec`, which turns a spec into a wave-planned, gate-verified build — is **coming**; it is specified but not yet a shipped subcommand, so it is not listed as a runnable command above.

`hmd demo` (or `heimdall demo`) and `heimdall-bench` are **safe to run sight-unseen**: the demo
defaults to dry (it scaffolds the task + prints the paste-ready command and
executes nothing), and `heimdall-bench` defaults to a dry pass that validates the
suite and prints the capture plan **without spending a single API token**. Opt in
to the real thing with `hmd demo --run` and `heimdall-bench --live`.

The deeper proofs already in the tree are runnable today too:

```bash
bin/falsify exchange-lob          # inject every mutant; assert the gate goes red on each (score must be 1.0)
bin/corpus run                    # replay the failure corpus; print the real catch-rate
```

---

## The story that built the bar

Heimdall's own golden reference once carried a wrong byte — the H/C flag bits inverted in the Game Boy CPU trace — and it survived **every same-author layer**: self-verify, mutation proofs, and a 100% corpus catch-rate all stayed green on the wrong value. It was caught only by adversarial cross-family review anchored to an external source (the Pan Docs), then confirmed by a 3-model blind consensus that would have failed the old value 3-0. The corpus dipped from 9/9 to 7/9 the instant the reference was corrected, then recovered to 9/9 — and that dip is on the public record, because a verification system that can't show you its own failures can't be trusted with yours.

Receipts: [corpus dip log](evals/corpus/CORPUS-STATUS.md) · [golden provenance + blind consensus](evals/oracles/emulator-gb/fixtures/golden/VERIFICATION.md).

---

## Status — failures visible on purpose

The live flagship status table is at [`evals/flagship/STATUS.md`](evals/flagship/STATUS.md), with the ❌ rows kept in view: the descoped timer subsystem the coverage matrix predicted on day zero, and the calibration row where Heimdall shows no delta. We publish where it still fails — watch us close it.

---

## Running it on your own work

Once installed, run Heimdall over your own task in auto mode (the default — a background safety classifier blocks prompt injection and risky escalation while still letting Heimdall work autonomously):

```bash
cd /path/to/your/project
heimdall --auto "build a real-time dashboard with auth and charts"
```

The installer is idempotent — re-run it any time to update.

> **`--dangerously-skip-permissions`** exists as a flag but is **not** the default. It hands an agent full autonomy with no safety classifier in the loop; prefer `--auto`. Only reach for skip-permissions in a throwaway sandbox you are willing to lose.

### Prerequisites

- **Claude Code** 1.0+ with valid auth ([install guide](https://docs.claude.com/en/docs/claude-code/setup))
- **Git**
- **`jq`** (for the gate + state helpers): `brew install jq`

---

## Contributing

The two contribution doors are **stack packs** and **oracle packs**:

- **Stack packs** ([`skills/stacks/`](skills/stacks/)) teach Heimdall a framework's conventions, build/test commands, and gotchas. Adding one is the fastest way to make Heimdall fluent in a stack you know.
- **Oracle packs** ([`evals/oracles/`](evals/oracles/)) add a falsifiable external gate for a new domain — a reference implementation, a mutant set, and the proof the gate goes red on every mutant.

See [CHANGELOG.md](CHANGELOG.md) for release history and [`docs/superpowers/specs/`](docs/superpowers/specs/) for design docs.

---

## License

[MIT](LICENSE)
