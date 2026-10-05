# NAMING

One product, one command, one engine. This file is the canonical list; `test/naming.test.sh` checks every `hmd <sub>` and `bin/<file>` named in the table below against the code, so a name that stops existing turns the suite red instead of lingering in prose.

## The decision (runhmd plan 3.2)

| Public name | Role | Rule |
|---|---|---|
| **runhmd** | The product and the brand. | What the verdict card, the schemas (`runhmd.verdict/1`, `runhmd.receipt/1`, `runhmd.prove/1`) and the planned `runhmd.dev` receipts call it. The `runhmd` npm wrapper lives in `packages/runhmd/`; claiming and publishing that npm name, and pointing `runhmd.dev` at a host, are operator steps that have not happened. |
| **`hmd`** | The only CLI a user has to learn. | Every user-facing capability is `hmd <subcommand>`. |
| **Heimdall** | The engine underneath, and the repo, plugin and state-directory name. | Used sparingly in copy. Identifiers do not change with copy: `randomittin/heimdall`, `.heimdall/`, `HEIMDALL_*`, `bin/heimdall-*`, `Heimdall v<version>` in `hmd version`. |

`heimdall` is a second spelling of the same binary: the installer symlinks both `~/.local/bin/hmd` and `~/.local/bin/heimdall` to `bin/heimdall`. It is supported and prints no notice.

## Every other name

Each codename is a subcommand, a helper binary, or internal. Internal means there is no command to learn: you meet it in output or on disk, never by typing it.

<!-- naming-table:begin -->
| Name | What it is | How you reach it |
|---|---|---|
| rr | Remote run: hand a task to the cloud bot that opens a gated PR on your repo. | `hmd rr`, implemented by `bin/rr` |
| Bifröst | Slang in product messages only (`BIFRÖST` on a denied gate: the merge is blocked). Never a command. | internal — printed by `bin/heimdall-gate-run` |
| dream | The overnight sweep, scheduled by the installer on macOS (`com.heimdall.dream`, opt out with `HEIMDALL_NO_DREAM_SCHEDULE=1`). | internal — `bin/heimdall-dream` |
| watchmen | The watchman HUD and the team wall of sigils. | `hmd status`, `hmd sigil`, `hmd watch` |
| designmatch | Visual diff of a screen against its spec. | `hmd designmatch` |
| bloat gates | The debloat scanner and its report ([BLOAT-REPORT.md](BLOAT-REPORT.md)). | internal — `bin/heimdall-debloat`, run directly |
| presence | The signed heartbeat that feeds the team wall. `hmd presence sever` is zero egress. | `hmd presence` |
| attack | Try to break a claim; PROVEN or DENIED with a counterexample. | `hmd attack` |
| prove | Do all gates pass, and has each been shown to fail first? | `hmd prove` |
| receipt | The signed record of one verdict. | `hmd receipt` |
| modules | Optional capability modules. | `hmd modules` |
| gates and oracles | The external checks a change must pass, each proven able to go red. | internal — `bin/falsify`, `bin/corpus`, `bin/heimdall-gate-run` |
<!-- naming-table:end -->

`hmd night` is the planned user-facing name for overnight work (plan 3.2). It is not shipped: there is no `night` arm in `bin/heimdall`, so it is not in the table.

## Deprecated aliases

When a user-facing name is renamed, the old spelling stays for one release and prints exactly `deprecated: use hmd <new>` on stderr before it does the work. Nothing is deprecated in this release: every name above is already an `hmd` subcommand, a helper binary or internal, and `heimdall` is a supported spelling, not an alias. The table is empty on purpose; a row added here without that notice in `bin/heimdall` turns `test/naming.test.sh` red.

<!-- deprecated-aliases:begin -->
| Old | New | Removed in |
|---|---|---|
<!-- deprecated-aliases:end -->

## Where this applies

This repository's docs and CLI output. The homepage and the install page live in the sibling `heimdall-site` repository and are not changed from here.
