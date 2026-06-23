# Heimdall 🛡️

**Verification gates for AI coding agents** — catches what the model misses, proves it did.

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-e056a0?style=flat-square)](https://code.claude.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-9b59b6?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.5-00d4ff?style=flat-square)](CHANGELOG.md)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.0.5/install.sh | bash
```

No sudo. No telemetry. Idempotent — re-run to upgrade. Reversible:

```bash
hmd uninstall    # removes everything; nothing else was touched
```

**Prefer to inspect first?**

```bash
curl -fsSL https://raw.githubusercontent.com/randomittin/heimdall/v2.0.5/install.sh -o install.sh
less install.sh  # function-wrapped, no eval, no base64 — what you read is what runs
bash install.sh
```

**Prerequisites:** Claude Code 1.0+ · Git · `jq` (`brew install jq`)

---

## First run

```bash
hmd demo --run
```

Scaffolds a real full-stack task, builds it, ends with a summary card and a follow-up prompt. Safe to run sight-unseen — `hmd demo` (without `--run`) prints the plan and does nothing.

---

## Why Heimdall

- **Catches the silent failures** — ordering races, whole-sequence invariants, missing subsystems that pass a naive green suite.
- **Falsifiable gates** — every gate is proven able to go red before it is trusted green. The corpus of real failure cases replays on every change; a regression that once shipped can never ship twice.
- **Proof of correctness, not just generation** — the delta Heimdall sells is the receipt that proves the proof can fail. [Generalizes: 0.50 median reuse across 8 cold repos.](https://runheimdall.dev/proof)
- **Full audit trail** — `hmd report` produces a machine-readable telemetry report of every gate, mutation score, and corpus catch-rate from the last run.

---

## What's inside

| Capability | Command | Status |
|---|---|---|
| Verification gates (secret-scan, bloat, falsify) | `/hmd:verify` in Claude · `bin/falsify` | Shipped |
| Demo task runner | `hmd demo` / `hmd demo --run` | Shipped |
| Issue-resolution loop | `hmd` (auto-retries failures against corpus) | Shipped |
| Telemetry report | `hmd report` | Shipped |
| Design match (visual diff vs spec) | `hmd designmatch` | Shipped |
| Redum / conformance checker | `heimdall-redum` · `heimdall-check` | Shipped |
| Reuse engine (cold-repo analysis) | `bin/lib/reuse_analyzer.py` | Shipped |
| Debloat scanner | `heimdall-debloat --report-only` | Shipped |
| Parallel workers | `hmd --team N "task"` (N tmux panes, independent — no shared state) | Shipped (no coordination layer) |
| Benchmark suite | `heimdall-bench` | Shipped |

---

## Running on your own work

```bash
cd /path/to/your/project
heimdall --auto "build a real-time dashboard with auth and charts"
```

`--auto` runs a background safety classifier that blocks prompt injection and risky escalation. It is the default. `--dangerously-skip-permissions` exists but is not the default — only use it in a throwaway sandbox.

---

## Failures visible on purpose

Live flagship status: [`evals/flagship/STATUS.md`](evals/flagship/STATUS.md) — the ❌ rows are kept in view. The corpus dip log and golden provenance are at [`evals/corpus/CORPUS-STATUS.md`](evals/corpus/CORPUS-STATUS.md) and [`evals/oracles/emulator-gb/fixtures/golden/VERIFICATION.md`](evals/oracles/emulator-gb/fixtures/golden/VERIFICATION.md).

A verification system that can't show you its own failures can't be trusted with yours.

---

## Contributing

- **Stack packs** ([`skills/stacks/`](skills/stacks/)) — teach Heimdall a framework's conventions and build commands.
- **Oracle packs** ([`evals/oracles/`](evals/oracles/)) — add a falsifiable external gate for a new domain.

See [CHANGELOG.md](CHANGELOG.md) for release history.

---

## License

[MIT](LICENSE)
