# Lean core

A lean install is hmd with a smaller footprint: the install directory holds what runs, and everything else stays in git, one offline command away. A fresh install is lean. An existing install stays exactly as it is until its owner asks.

Plan and invariants: `docs/superpowers/plans/2026-11-12-3x-lean-core.md` and `.planning/lean-core/INVARIANTS.md` (INV-L1 to INV-L12). The measured numbers below come from `bin/heimdall-footprint`, one command, reproducible (see "Measure it").

## Who gets it

| Install | Profile | How it changes |
| --- | --- | --- |
| Fresh (`install.sh` finds no setup marker and no grandfathered `skills-config.json`) | `lean` | decided once, recorded in `$HEIMDALL_HOME/profile.json` |
| Existing (a setup marker, or `grandfathered: true`, or no record at all) | `full` | unchanged; a plain `install.sh` re-run changes nothing |
| Existing, on request | `lean` | `hmd reinstall --reset` or `hmd lean on` |

A re-run of `install.sh` applies the recorded profile and never decides again, so an upgrade cannot reset it (INV-L7). `full` is today's install, byte for byte (INV-L1, INV-L8).

## What moves

A lean install is the same clone narrowed by a sparse checkout (`bin/lib/lean_sparse.sh`). Every git object stays in `.git`, so what the tree lacks comes back without the network (INV-L4). The lean set is derived from HEAD of the clone:

- Stays: the files the code can reach (`release/runtime-files.txt`, derived by `bin/heimdall-runtime-closure`), and the core the host loads by name: `.claude-plugin/`, `agents/`, `commands/`, `hooks/`, `skills/heimdall/`, `settings.json`, `.mcp.json`, `LICENSE`, and `docs/superpowers/specs/2026-04-06-superx-design.md` (the one doc the prompt and the heimdall skill tell the model to read).
- Moves out (on demand): the five bundled skills `skills.manifest.json` marks on demand (`stacks`, `designmatch`, `self-improve`, `system-health`, `mac-deep-clean`) and `commands/designmatch.md`.
- Moves out (never runtime): `test/`, `.planning/`, most of `docs/`, `relay/`, `launch-docs/`, `deploy/` and most of `receipts-worker/`.
- Unchanged on purpose: every hook (56 registered), every `bin/` file, every guardrail (INV-L3). Nothing is gated by the profile.

Measured on this repository at the lean-core merge, 2026-11-22 (`session start` is what a session is handed before the first prompt; tokens are bytes / 4, an estimate):

| | full | lean |
| --- | --- | --- |
| tracked files on disk | 37.3 MB, 2,367 files | 15.6 MB, 1,122 files |
| `test/` | 14.9 MB, 716 files | 0 |
| `docs/` | 2.8 MB, 144 files | 0.14 MB, 11 files |
| `.planning/`, `relay/` | 1.1 MB, 1.0 MB | 0, 0.01 MB |
| `skills/` | 0.33 MB, 6 skills | 0.16 MB, 1 skill |
| session start context | 87,274 B (~21.8k tokens) | 84,581 B (~21.1k tokens) |
| skill / command descriptions in context | 6 skills, 20 commands | 1 skill, 19 commands |
| hooks registered | 56 | 56 |

The disk numbers move with every commit; the ceilings that keep them honest are in `release/lean-budget.json` (full tree) and `release/lean-install-budget.json` (a lean tree).

## Commands

```
hmd lean status                  the recorded profile, what the tree on disk is, the footprint now
hmd lean on                      record lean, narrow the clone; prints the footprint before and after
hmd lean off                     the whole tree back (git sparse-checkout disable), record full; idempotent
hmd lean restore <dir>           undo `hmd reinstall --reset` from the backup directory it printed
hmd reinstall --reset [--yes]    turn this install lean in place (a thin wrapper over install.sh --reset)
install.sh --reset               the same, run directly
hmd skills suggest               lists the skills a lean install left out, under [on demand]
hmd skills install <id>          puts a left-out skill back, offline (stacks, designmatch, ...)
```

A session reads skills and commands when it starts, so every change reaches it after a restart. `hmd reinstall` without `--reset` prints usage and exits 2: it is never read as a wipe, and it is not `hmd --reinstall`, which deletes `~/.heimdall` and is untouched.

`install.sh --reset` runs these steps, in order:

1. the route guard (below);
2. a backup under `$HEIMDALL_HOME/backups/<UTC-stamp>/` (mode 0700, a sha256 manifest, `bin/lib/lean_backup.py`);
3. skills consent set to `ask` and the install no longer grandfathered;
4. the lean profile recorded;
5. the lean tree applied;
6. the lean prompt selected, only if it is verified (below);
7. Headroom switched off for the next session (`hmd headroom off --next-session`; a release without that command warns and carries on);
8. the undo command printed: `hmd lean restore <dir>`.

A failed step 3 or 4 stops the reset and prints the undo; a failed 5, 6 or 7 warns and the install carries on, so lean never costs an install. Your ledger, receipts, memory, team, pairing and `data/` are never copied, edited or removed: they hash the same before the reset, after it and after a restore (INV-L10).

The first launch of a fresh install shows one checklist of the skills it left out, next to the recommended ones; a pick goes through `hmd skills install <id> --yes`. `hmd skills install <id>` itself runs `lean_sparse.sh add` for every path the manifest names for that skill and writes a lock row (reason and consent basis). Nothing is fetched or run. What it put back survives `hmd lean on`, an upgrade, and `lean off` then `on`.

## Rollback

Three ways back, from the smallest:

- A skill you want: `hmd skills install <id>`.
- The whole tree: `hmd lean off`. It restores every tracked file from the local objects and records `full`. Run on a clone that never was lean, it leaves the tracked files and `.git/config` as they are.
- A whole reset: `hmd lean restore <dir>`, `<dir>` being the backup directory `--reset` printed (INV-L9). It verifies every file of the backup against its sha256 first and writes nothing at all when one differs, so a damaged or mistyped directory is refused with the install as it was. Then it puts back `skills-config.json`, `profile.json`, the modules state and the hmd-managed slice of the user-level settings (the `agent` key, the env keys hmd routes with, the hook entries that run hmd), removes the unfinished-reset record, and brings the tree to the profile the backup recorded: a backup of a pre-lean install holds none, so the record goes and the tree is full. A second restore of the same backup changes nothing.

## Headroom and the route

A lean install installs no proxy and routes no session through one; the hmd launcher is kept as it is (INV-L12). Headroom is off by default on a new install and a separate opt-in (`hmd headroom on`). `hmd lean on|off` never run `hmd headroom` and edit no settings or environment.

`--reset` is the one place Headroom is switched off, and a live session may be routed through it right now, so the reset asks `bin/lib/lean_route_guard.sh check` first (INV-L11). The guard only reads (no socket, no write, no signal) and prints one line, `<verdict>: <reason>`:

| Verdict | Exit | Meaning | What the reset does |
| --- | --- | --- | --- |
| `ok` | 0 | this session is not routed through Headroom | every step runs, Headroom goes off for the next session |
| `defer` | 10 | this session routes to a loopback host on Headroom's port (`ANTHROPIC_BASE_URL`, `HEADROOM_*`, `HTTP(S)_PROXY`) | the profile, the tree and the Headroom switch are recorded as pending in `$HEIMDALL_HOME/backups/lean-reset-pending`, named on screen, never skipped silently; the next `--reset`, run after the session ends, does them and keeps the first backup, so the printed undo still returns to the original install |
| `refuse` | 11 | it cannot tell (unreadable state, a route that is not a host and port) | nothing changes (fail closed) |

The reset never stops the proxy and never edits a setting or environment the live route reads: a session already routed through Headroom keeps working. A route to another local proxy (a VPN client, a gateway) is not Headroom's to turn off; the guard names its host and port in the reason and the reset leaves it alone. Only the host and the port are ever printed, because a proxy URL can carry credentials.

## The lean prompt (gated, not active yet)

`agents/heimdall-lean.md` is the main prompt with its three procedure sections (2, 4 and 5: prompt analysis, the planning pipeline, agent spawning) moved to `skills/heimdall/references/lean-procedures.md` behind short pointers: 29,336 bytes against 67,385, about 9.5k tokens less at every session start: a lean tree whose `settings.json` points at it measures 46,532 B (~11.6k tokens) at session start, against 84,581 B (~21.1k tokens) with the full prompt (a scratch measurement with `bin/heimdall-footprint --root`, not an install anyone runs yet). Every other section is byte-equal to `agents/heimdall.md` (`test/lean-prompt-sections.test.sh`), which is untouched.

It is selected by step 6 of `--reset` (`agent: hmd:heimdall-lean` in the user-level settings) and only when `evals/lean/prompt-parity.receipt.json` says `green` for that exact prompt (its sha256). The gate (`evals/lean/prompt-parity.sh`) runs the same fixed tasks through both prompts and requires the same ordered trace of agents spawned, gates run and files touched. Only a trace recorded from a live run counts; a fixture never turns it green.

Today no live trace is recorded: the verdict is `unverified`, a reset skips the lean prompt with one line, and every install still runs `agents/heimdall.md`. The lean profile therefore saves disk now and context only after the operator records the traces (this spends model budget) and the verdict is green:

```
bash evals/lean/prompt-parity.sh --record     # live, operator-run
bash evals/lean/prompt-parity.sh              # compare, write the receipt
hmd reinstall --reset                         # an install that is already lean takes the prompt at its next reset
```

## Measure it

```
bin/heimdall-footprint                        # disk, context handed to a session, hooks: this tree
bin/heimdall-footprint --check                # the full-tree ceilings, release/lean-budget.json
git clone -q --depth 1 file://$PWD /tmp/hmd-lean
bash bin/lib/lean_sparse.sh apply lean /tmp/hmd-lean
bin/heimdall-footprint --check --root /tmp/hmd-lean --budget release/lean-install-budget.json
```

A ceiling is a number a metric may not exceed; a hook, a skill or a byte of prompt added later fails the check until the budget is raised on purpose. The full-tree budget lists no disk ceiling (a dev checkout grows with every test and doc); the lean one does, because the lean tree is derived from HEAD by a fixed rule.

## What is NOT lean yet

- Installing hmd straight from the marketplace entry on GitHub (without `install.sh`): the copy the host's plugin manager makes is still the whole repository, and sparse checkout does not reach it. The disk win above is for the install directory.
- `evals/` stays (2.8 MB of the 15.6 MB): code names its corpus and oracle files, so the closure keeps it.
- `bin/` is two thirds of the lean tree (10.5 MB): the phone, app, relay client, inbox, presence and team tools are named by hooks, so they stay.
- The 56 hooks are unchanged on purpose; a hook diet is a later cycle.
- The session prompt: gated, see above. Until the receipt is green, the context saving is five skill descriptions and one command, about 2.7 KB.
- `install.sh` grew a profile step and `--reset`, so a release has to re-sign it (`install.sh.minisig`) and refresh the pinned digests in `packages/*/package.json`. That is a release step and is not done by this change.

## Proof

`test/lean-sparse.test.sh`, `test/lean-runtime-closure.test.sh`, `test/lean-footprint.test.sh`, `test/lean-profile.test.sh`, `test/install-lean-profile.test.sh`, `test/install-noflag-identical.test.sh`, `test/install-reset.test.sh`, `test/install-reset-userdata.test.sh`, `test/lean-backup-restore.test.sh`, `test/lean-route-guard.test.sh`, `test/lean-command.test.sh`, `test/lean-dispatch.test.sh`, `test/skills-install-pack.test.sh`, `test/lean-prompt-sections.test.sh`, `test/lean-prompt-parity.test.sh`. `test/lean-gate-falsify.test.sh` breaks each of those gates with a mutant and requires it to turn red.
