# runhmd adapters (RP9)

An adapter is how a *claim* reaches runhmd. The thesis is "agents say done falsely; attack the claim", and
the claim can come from Claude Code, Codex, Gemini, Cursor, a teammate or a CI job. Instead of teaching
runhmd about each tool, every source sits behind the same three calls and runhmd attacks whatever `claim`
returns. Cursor, or any tool with no adapter of its own, is the `gitdiff` adapter: give runhmd the diff.

This file is the contract. `python3 -m adapters.conformance --adapter <name>` is its executable form: an
adapter conforms when that exits 0. Each rule below carries the id the suite reports.

```
start(task: {id, prompt, repo, base_sha}) -> run_id
events(run_id) -> stream of {ts, kind: "tool|message|test|status", data}
claim(run_id) -> {claim: "done|failed|gave_up", diff: "<unified diff>", head_sha}
```

## The three calls

**task** is exactly these keys (any other key is refused):

| key | type | meaning |
|---|---|---|
| `id` | string, `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` | the caller's label for the task |
| `prompt` | string | what the agent is asked to do; may be empty for an adapter that runs no agent |
| `repo` | string | a directory inside a git repository |
| `base_sha` | string | the full lowercase hex id (40 or 64 chars) of a commit in `repo`: the state the work starts from. Never a ref name or an abbreviation; the caller resolves |
| `options` | object, optional | `{"<adapter name>": {...}}`. An adapter reads only its own key and ignores the rest, so one task can be handed to any adapter |

**run_id** is an opaque string, `^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$`, different on every `start`.

**events(run_id)** is a finite stream of `{ts, kind, data}` and nothing else per event:

- `ts`: RFC 3339 UTC, `YYYY-MM-DDTHH:MM:SS[.fff]Z`; never decreasing along the stream.
- `kind` and the keys `data` must carry (extra keys are welcome, `data` is always a JSON object):

| kind | required in `data` |
|---|---|
| `status` | `state`: `started` or a terminal state `done`, `failed`, `gave_up` |
| `message` | `role`: `agent`, `user` or `system`; `text`: string |
| `tool` | `name`: non-empty string (what was called) |
| `test` | `cmd`: string; `exit_code`: integer (a test, lint or build command and how it ended) |

- The stream opens with `status/started` and closes with exactly one terminal `status`. Status events mark those two
  moments and nothing between.
- A `test` event records what the **adapter observed** (a command and its exit status), never what the agent said
  about it. An adapter that cannot observe tests emits none; no `test` event means "unknown", not "tests did not run".
- Reading `events` twice on a finished run gives the same stream.

**claim(run_id)** returns exactly `{claim, diff, head_sha}` and blocks until the run is over:

- `claim`: `done` (the agent, or the human behind a diff, asserts the task is complete: this is what runhmd attacks),
  `failed` (the run ended in error, or the agent said it could not complete), `gave_up` (the run ended with no completion
  claim: limit, budget, interrupt, abandonment). Only `done` claims are attacked.
- `diff`: a unified diff (`git diff --binary` style, `a/` `b/` prefixes, UTF-8 text) from `base_sha` to the claimed state.
  A `done` claim has a non-empty diff: a change nobody can see cannot be attacked, and "done, changed nothing" is the
  false green this project exists to catch.
- `head_sha`: `null`, or the full hex id of a commit **in `repo`** that holds the claimed state. A bare patch has no commit,
  so its `head_sha` is `null` rather than a sha that points at nothing; an adapter must never invent one.
- The claim equals the stream's terminal status, whichever of `events` and `claim` is read first, and reading
  `claim` twice gives the same claim.

**Errors.** The only exception an adapter may raise is `adapters.AdapterError(kind, detail)`; any other exception that
escapes is a violation. Kinds the contract fixes: `bad_task` (the task is malformed, or `repo` is not a usable git
repository), `unknown_base` (`base_sha` is well formed but names no commit in `repo`), `unknown_run` (`events` or `claim`
of a run that never existed), `unavailable` (the adapter cannot run here: tool missing, not logged in). An adapter may
add kinds of its own, snake_case. A task an adapter cannot take is refused at `start`, never turned into a `failed` run.

**The caller's repo is only ever read.** `start`, `events` and `claim` leave HEAD, refs, the index, the working tree and
the list of registered worktrees exactly as they found them. An agent adapter works in a copy.

## Rules, as the conformance suite enforces them

| id | rule |
|---|---|
| M1 | module surface: `CONTRACT == "runhmd.adapter/1"`, `AGENT` is a verdict `agent.name`, `start`, `events` and `claim` are callable |
| T1 | `start()` returns a run id matching the run-id pattern |
| T2 | two `start()` calls of the same task return different run ids |
| T3 | every malformed task (wrong types, missing keys, bad id, bad `base_sha`, repo that is not a git repo, unknown keys) is refused with `bad_task`, never accepted, never a raw exception |
| T4 | a well-formed `base_sha` that names no commit is refused with `unknown_base` |
| T5 | the caller's repo is left as found after start, events and claim |
| E1 | every event is exactly `{ts, kind, data}`, `ts` is RFC 3339 UTC, `kind` is one of the four, `data` is an object, all JSON-serialisable |
| E2 | timestamps never go backwards |
| E3 | each event kind carries its required `data` keys with the right types |
| E4 | the stream opens with `status/started` and closes with exactly one terminal `status` |
| E5 | `events()` of a finished run replays the same stream |
| E6 | `events()` of an unknown run raises `unknown_run` |
| K1 | `claim()` is exactly `{claim, diff, head_sha}`: `claim` in the enum, `diff` a string, `head_sha` null or a full hex id |
| K2 | the claim equals the stream's terminal status, whether `claim()` or `events()` is read first |
| K3 | the scenario is a finished change, so the claim is `done` and its diff is non-empty |
| K4 | the claimed diff applies cleanly to the tree of `base_sha` |
| K5 | a non-null `head_sha` is a commit in the repo whose tree is `base_sha` plus the diff |
| K6 | `base_sha` plus the diff is exactly the change that was made (the claim reproduces the real tree, byte for byte, executable bit included) |
| K7 | `claim()` of a finished run replays the same claim |
| K8 | `claim()` of an unknown run raises `unknown_run` |

## Python binding

An adapter is `adapters/<name>.py` (`^[a-z][a-z0-9_]*$`). Modules starting with an underscore are helpers shared by
adapters and are never listed as one. The module defines:

```python
CONTRACT = "runhmd.adapter/1"   # the contract version; a new version needs a new suite
AGENT = "none"                  # the verdict's agent.name for runs of this adapter: claude-code | codex | gemini | cursor | none
def start(task) -> str
def events(run_id) -> iterable of dict
def claim(run_id) -> dict
```

`adapters/_common.py` has the helpers the shipped adapters share (`validate_task`, `resolve_commit`, run ids, timestamps,
and read-only git plumbing: `export_tree`, `apply_diff`, `materialize`). The conformance suite deliberately does not use it.

## Conformance suite

```
python3 -m adapters.conformance --adapter gitdiff            # exit 0 = conforms
python3 -m adapters.conformance --adapter gitdiff --json     # runhmd.adapter-conformance/1 report
python3 -m adapters.conformance --list                       # the adapters present
python3 -m adapters.conformance --rules                      # every rule id and title
python3 -m adapters.conformance --adapter-file F.py --driver gitdiff     # an adapter that lives elsewhere
```

Exit codes: `0` every rule passed; `1` a rule failed (an adapter that cannot even be imported fails M1); `2` usage
(unknown adapter, missing driver, unreadable file); `5` the suite could not run (git missing, fixture failed to build).
`test/adapter-conformance.test.sh` is the proof, and it picks adapters up from `--list`, so a new adapter is graded the
day it lands with no edit.

**How it judges.** The suite builds its own fixture repository (`adapters/conformance/fixture.py`): base commit B, then
head commit H = B plus a modified file, an added file, a deleted file and an executable-bit flip, with HEAD at H so an
adapter that works from HEAD instead of `base_sha` is caught. A **driver** turns that scenario into the tasks that make
this adapter claim exactly that change. The suite observes each task (start, events twice, claim twice, a second start,
a claim-before-events run), then every rule judges the recorded behaviour. Every expected value comes from the fixture and
from this document, never from an adapter.

**Independent by construction.** The suite core (`__main__.py`, `rules.py`, `fixture.py`) imports no adapter and not
`adapters/_common.py`; it keeps its own git plumbing, so a bug cannot sit on both sides of a check. Adapter-specific glue
lives only in `adapters/conformance/drivers/<name>.py` (`variants(fixture) -> [(name, task)]`), which translates and never
asserts. Authors of an adapter must not weaken the suite to fit it: the suite and its drivers are reviewed apart from adapters.

**Falsifiable.** A suite that cannot go red proves nothing. `test/fixtures/adapter-mutants/mutant.py` is the gitdiff adapter
broken one rule at a time (selected by `HMD_MUTANT`, one mutant or more per rule id); the test requires each to be rejected
with exit 1 and exactly the failing rule ids it targets.

## The gitdiff adapter

`adapters/gitdiff.py`: the universal fallback, `AGENT = "none"`. The change already exists as a diff, so nothing runs;
the claim is `done` with that diff. Source, exactly one under `task.options.gitdiff`:

| option | meaning |
|---|---|
| `patch` | the unified diff as text |
| `patch_file` | a path to a file holding it |
| `head` | a revision of the repo; the diff is `git diff --binary base_sha head`, and `head_sha` is that commit |

`start` proves the diff applies to `base_sha` by applying it in a throwaway tree. The base tree is the **committed bytes**
(`ls-tree` plus raw blobs), not `git archive`, which would drop files a repository marks `export-ignore`. `git apply` runs
as a plain directory (never inside a repository, where it silently skips paths outside its subdirectory); it refuses paths
outside the tree, `.git` paths and writes through symlinks. Events: `status/started` (with the source), one `tool`
(`git.apply`, with file and line counts), `status/done`. There are no `test` events: gitdiff cannot observe the change being
tested. Errors added to the contract's: `bad_diff` (not a diff, does not apply, not UTF-8), `empty_diff`, `unknown_head`,
`too_large` (diff over `HMD_ADAPTER_MAX_DIFF_BYTES`, default 5 MiB; base tree over `HMD_ADAPTER_MAX_EXPORT_FILES` /
`HMD_ADAPTER_MAX_EXPORT_MB`, default 20000 files / 256 MB).

`gitdiff.task_for_spec(repo, spec, read_stdin=...)` turns the text after `hmd attack --diff` into a task: a patch file
(applied on the repo's HEAD), `A..B`, `A...B` (base is the merge-base) or `-` (the patch comes from `read_stdin()`; the
module never reads the process's stdin). Revisions are resolved to full shas there; a file that exists wins over a range of the
same name.

**`hmd attack --diff SPEC [<path>]`** (`bin/lib/runhmd_attack.py`) is the consumer: `task_for_spec`, `start`, `claim`, then
the claimed diff is applied to `base_sha` in a private copy of the repo and that copy is attacked; `<path>` (default `.`)
may be a subdirectory, whose copy is the attack surface. The verdict says `target.kind: "diff"`, `target.ref: <SPEC>`,
`target.head_sha: <claim.head_sha>` and `agent.name: "none"`. `--diff -` needs `--yes` (stdin carries the patch, so it
cannot also carry a consent answer); `--diff` cannot be combined with `--batch`. Needs no dispatch change: the existing
`attack)` arm of `bin/heimdall` forwards every argument verbatim.

## Writing the next adapter (claude, codex, gemini)

A different author from this wave's, deliberately. Follow the rules, do not bend them.

1. `adapters/<name>.py` with the binding above; `AGENT` is the verdict name (`claude-code`, `codex`, `gemini`).
2. It runs the agent **in a copy** (a fresh export of `base_sha`, or a worktree it removes again): T5 fails on anything left
   in the caller's repo, a registered worktree included. The diff is taken from that copy against `base_sha`.
3. `events` are translated from the tool's native stream; `test` events come from commands the adapter saw run and exit,
   never from the agent's prose. `claim` is `done` only when the agent asserted completion **and** the diff is non-empty;
   an empty diff with a "done" is `failed` or `gave_up`, never `done`.
4. It must be exercisable with no credentials, no network and no model: the binary it launches is overridable
   (convention `HMD_ADAPTER_<NAME>_BIN`) and a recorded native stream stands in for a live run. A live run is a smoke test
   on top, never the conformance verdict.
5. Add `adapters/conformance/drivers/<name>.py` (`variants(fixture)`) that makes the recorded run produce the fixture's
   change (`fixture.diff`, `fixture.patch_path`, `fixture.head_sha`, `fixture.expected_dir`). Without a driver the suite exits 2.
6. `python3 -m adapters.conformance --adapter <name>` exits 0 with nothing skipped.

## Limits, stated

- The suite proves the contract, not that an adapter's translation of its tool's native stream is faithful; that is what
  the recorded streams and a reviewer are for.
- `gitdiff` trusts the diff's author about intent: a patch is a claim of "done" by definition. Whether it is *right* is what
  `hmd attack` decides.
- Exporting the base tree copies the whole repository tree once per `start` and once per `hmd attack --diff`; the size caps
  above turn a monorepo into a clear `too_large` instead of a hang.
