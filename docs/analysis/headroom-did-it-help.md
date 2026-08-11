# Headroom: did it help?

**Verdict: NOT ACTUALLY RUNNING.**

Reason: the storage-codec wire (`bin/lib/memory_codec.py`) never leaves the `plain`
backend. hmd's own Python cannot import `headroom` (`importlib.util.find_spec`
returns `None`) — but that import failure is not even the binding constraint: per
`modules/headroom/manifest.json`'s own 2026-08-04 measurement, running the identical
seam under the interpreter where `headroom` genuinely *does* import (the uv-tool
venv's own Python) still lands on `plain`, because headroom-ai 0.33.0 exposes no
encode/decode pair this seam can bind to. The other integration point — the
`hmd wrap` traffic-proxy chain — is technically wireable (the CLI is installed and on
`$PATH`) but has zero recorded snapshots anywhere in this repo's history. Nothing has
been measured on either wire, so there is no receipt to grade and no improvement
number to report.

This builds on `docs/analysis/2026-08-04-headroom-vs-claude-mem.md`, which found
Headroom "not installed" at all. That has since changed (headroom-ai v0.33.0 is now
installed via `uv tool`) — but the runtime effect is still verified-zero, for reasons
that are now understood precisely rather than assumed.

## 1. The A/B tool itself, post-fix

`bin/heimdall-headroom-ab` had two real bugs, both fixed today (2026-08-11), both
read via `git show <sha>`:

- **`ad62830`** — clause (a) of the pre-registered verdict rule ("a decision metric
  unavailable in either arm → INDETERMINATE") was printed in the tool's own
  `preregister` output but never implemented in `cmd_verdict`. Reproduced failure:
  an arm that swept 0 mutants (the falsifier never ran in that arm, out of 300
  mutants swept in the other arm across 30 paired tasks) still returned verdict
  `keep` — a false-positive KEEP for a metric that was never measured. Test suite
  went from 44 to 73 assertions after the fix.
- **`eab6e6b`** — a non-object `.metrics` field in a snapshot crashed the `jq` render
  mid-table with exit 0, silently truncating the report (no error surfaced — the
  report just stopped partway through the table). Fixed via a `pick()` accessor.
  79 passed / 0 failed after.

**Consequence for evidence:** any receipt generated before `ad62830` cannot be
trusted as evidence of improvement — it could read `keep` under conditions clause (a)
should have hard-stopped as `indeterminate`. This turns out to be moot for a stronger
reason: no receipt of any age exists at all (§2).

Post-fix, the tool's verdict order (`rule_text()`, `bin/heimdall-headroom-ab:108-158`)
is:

```
(a) a decision metric unavailable in either arm     -> INDETERMINATE
(b) falsify survivors increased in arm B            -> UNWRAP (categorical, hard stop)
(c) oracle pass-rate 95% interval entirely below 0   -> UNWRAP (statistical)
(d) interval half-width > 10pp                      -> UNDERPOWERED
(e) otherwise                                       -> KEEP
```

## 2. Receipt/snapshot count: zero, searched exhaustively

`cmd_snapshot` — the only subcommand that measures anything — writes to stdout unless
`--out <path>` is given. There is no default file location, so a real snapshot exists
only if an operator explicitly saved one. Searched every way a saved snapshot could
show up, in the worktree and in the full git history:

| Search | Result |
|---|---|
| `grep -rl "heimdall-headroom-ab" --include="*.json"` (repo-wide) | no matches |
| `grep -rl "heimdall-headroom-ab/v2"` (the snapshot schema string, unrestricted) | exactly 2 files, both **source**, not data: `test/headroom-ab.test.sh`, `bin/heimdall-headroom-ab` |
| `find . -iname "*.json" \( -path "*snap*" -o -path "*receipt*" -o -path "*arm*" \)` | no matches |
| `git log --all --oneline --diff-filter=A -- '*headroom-ab*.json' '*headroom*snapshot*'` | no matches — never even added-then-deleted |
| `git log --all --oneline --grep="headroom-ab.*snapshot\|snapshot.*headroom" -i` | no matches |
| `.heimdall/` (where the tool's neighboring state, e.g. gate-run logs, would live) | only two `*.example` template files — no real data |
| `find . -iname "*headroom*"` (broadest sweep) | 7 hits, all source/docs/module-registry: `test/headroom-module.test.sh`, `test/headroom-ab.test.sh`, `bin/heimdall-headroom-ab`, `launch-docs/HEADROOM-COMPANION-ASK.md`, `modules/headroom/`, `bin/lib/hmd-headroom-chain.sh`, `docs/analysis/2026-08-04-headroom-vs-claude-mem.md` — zero data files among them |

Count: **0 receipts, 0 snapshots, ever**, in the working tree or anywhere in git
history. Not "0 trustworthy out of some larger untrustworthy pool" — there is no pool
to begin with.

First-party corroboration, `modules/headroom/manifest.json` (`tier_note`):

> "`tier` is an EVIDENCE claim and `default_included` is a DISTRIBUTION fact... it has
> NOT earned `suggested` — that tier requires a green pre-registered A/B receipt under
> `tier_evidence`, and the A/B has not run."

Second corroboration, `launch-docs/log-compression-and-gates.md` — the tool's own
cited pre-registration source: its banner reads "⛔ NOT PUBLISHED. THE A/B HAS NOT
RUN. DO NOT POST THIS." Every result cell in its table is a literal
`[RECEIPT: ...]` / `[SOURCE: ...]` placeholder — zero real numbers anywhere in it.

## 3. The storage-codec wire: silent fallback, at call time, quoted

`bin/lib/memory_codec.py` is the seam that would compress hmd's verified-memory store
if a working backend were active. The "nail the silence" question is: does a caller
find out about the plain-codec fallback during a normal encode/decode call, or only
by separately invoking `status`? Tracing the exact call path:

`encode_text()` — every write goes through this (`bin/lib/memory_codec.py:373-375`):

```python
name = backend_name()
if name == PLAIN:
    return text
```

`backend_name()` returns `_detect()[0]`, and `_detect()` calls `_resolve_headroom()`
once and caches the result. When headroom isn't importable, `_resolve_headroom()`
(`memory_codec.py:266`) returns:

```python
return PLAIN, "headroom is not importable — using the plain codec"
```

The reason string is real and computed — but nothing at any call site (`encode_text`,
`decode_text`, `encode_entry`, `decode_entry`) ever reads or emits it. `encode_text`
just returns `text` unchanged, silently. Symmetrically on the read side,
`decode_text()` (`memory_codec.py:411`) checks `is_wire(value)` first; literal
(never-encoded) text simply isn't a wire envelope, so it returns unchanged — also
silently. A full-file grep for `logging|logger|print(|warn` turns up zero matches
anywhere in `memory_codec.py` outside the three `def` lines themselves.

This is not an oversight slipping through — the file's own docstring names it
outright as Invariant 3 (`memory_codec.py:54-59`):

> "CODEC ABSENCE DEGRADES TO PLAIN, SILENTLY. No feature may depend on any codec
> being installed. Detection failure, an incompatible library version, a backend that
> raises mid-encode — every one of them lands on plain, with the reason recorded for
> diagnostics and nothing printed to a user."

The only user-facing surface anywhere in the file is `maybe_hint()`
(`memory_codec.py:521`), and it's structurally rare: it fires **at most once per
store**, and only once that store exceeds 1 MiB (`HEAVY_STORE_BYTES`) with no codec
active (it early-returns `None` whenever `available()` is true). Below that size, or
once already hinted (a marker file makes it durable across processes), there is no
signal at all. And when it does fire, the wording — `"hmd can compress its memory
stores via Headroom if installed — optional."` — is written for the
never-installed case; on this machine it would still fire (headroom-ai 0.33.0 *is*
installed, just structurally unable to engage this seam), reading as an instruction
to do something that has already been done.

**Net: yes — silent at call time, in both directions, by design**, exactly as the
docstring specifies. This confirms the task's framing ("headroom could be 'on' but
doing nothing, and nothing goes red") as the actual, current, and *intentional*
behavior of this seam — not a bug waiting to be patched, but a documented invariant
whose practical side effect is exactly that failure mode.

Live confirmation, run fresh this session:

```
$ python3 bin/lib/memory_codec.py status --json
{
  "available": false,
  "backend": "plain",
  "headroom_importable": false,
  "reason": "headroom is not importable — using the plain codec",
  ...
}
```

## 4. Why "just fix the import" would not fix this

hmd's own python3 genuinely cannot import `headroom` — confirmed directly:

```
$ python3 -c "import importlib.util; print(importlib.util.find_spec('headroom'))"
None
```
(interpreter: `/Users/rj/.pyenv/versions/3.11.14/bin/python3`, not the one
`uv tool install` builds). `test/headroom-module.test.sh` documents this as
intentional: "the sanctioned install is `uv tool install`, which puts headroom-ai in
an isolated uv tool venv that hmd's python3 cannot see... the seam must stay on the
plain backend."

`modules/headroom/manifest.json` goes one step further, and this is the load-bearing
correction to an "import path is the whole story" framing. It records a **second**
measurement (2026-08-04) of the identical seam, run under the uv-tool venv's *own*
interpreter (python 3.13.13) — the one place `import headroom` genuinely succeeds,
natively, with zero bridging. Result: `headroom_importable=true`, but **`backend` is
still `plain`** — reason: `"headroom is importable but exposes no storage-codec
entrypoint this seam understands"`. At the pinned version (0.33.0): `headroom.compress`
exists with no `decompress`; `headroom.storage` has no encode/decode pair;
`headroom.codec` does not exist at all. It is a lossy semantic-context compressor by
design, not a reversible codec — so there is no encode/decode pair for this seam to
bind to, on *any* Python, on *any* machine, at this pin. The manifest states this
plainly, including its own prior mistake:

> "An earlier version of this note said engaging the codec would need an install that
> puts headroom on hmd's own import path; that was FALSE, and worse than merely
> false, it aimed maintenance at the packaging when the packaging is not what blocks
> it."

So two blockers stack, and only one is binding: the import path is real but
non-binding (fixing it flips one boolean and nothing else); the upstream API surface
is binding and is version-scoped (a future headroom-ai release publishing a real
encode/decode pair clears it with no change needed on hmd's side).

Scope of what was even at stake: the manifest also states only **one** store is wired
to this seam today — `verified-memory`, via `verified_memory._append` /
`verified_memory._read_raw`. The case corpus, branch context, and session-summary
capsule reserve payload field names (`PAYLOAD_FIELDS`) but are not routed through the
seam. Even in a counterfactual world where the codec worked, this wire's ceiling was
one store.

## 5. The other wire — traffic-proxy — is technically live, but has zero usage evidence

`headroom` (the CLI) is genuinely installed and on `$PATH`:

```
$ uv tool list
headroom-ai v0.33.0
- headroom
$ command -v headroom        # exit 0
$ ls -la ~/.local/bin/headroom
headroom -> /Users/rj/.local/share/uv/tools/headroom-ai/bin/headroom   (dated 4 Aug 15:16)
```

This is the wire the manifest calls "SATISFIABLE AT THE PINNED VERSION":
`hmd wrap <tool>` chains `hmd setup -> headroom proxy -> tool`, compressing
GENERATION traffic only — never judgment/gate traffic (`hmd_gate_exec` unsets every
Headroom env var before any verdict-producing call). This is presumably the wire
`heimdall-headroom-ab`'s oracle/falsify sweep exists to compare, before vs. after. But
there is no evidence anywhere that a real coding session has ever run through
`hmd wrap` — no snapshot was ever taken (§2), so nothing in this repo's history
distinguishes a wrapped session from an unwrapped one. Technically wireable is not
the same as ever exercised in a measured way.

## What to do next

Two separate follow-ups, because two separate wires are involved.

**Storage-codec wire — nothing actionable on hmd's side right now.** It is gated on
headroom-ai shipping a lossless `encode`/`decode` (or equivalent) pair upstream, at
one of `headroom.codec`, `headroom.storage`, or top-level `headroom`. When a version
does, re-run the manifest's own `round-trip-fidelity` and
`plain-fallback-when-absent` invariants against the new pin — those are the checks
that will flip `backend` away from `plain`. For completeness, since the exact command
was asked for: the command that flips `headroom_importable` (not `backend`) from
false to true on hmd's own interpreter is

```
uv pip install --python "$(command -v python3)" "headroom-ai[all]==0.33.0"
```

This is **not** a recommendation — per the manifest, it changes one boolean and
nothing else, and it also pulls Rust/ONNX/HuggingFace into hmd's base install, which
`bin/lib/memory_codec.py`'s own header says must stay near-stdlib. It was not run;
no uv/venv state was touched in producing this document.

**Traffic-proxy wire — the one that can actually produce a first receipt:**

```sh
# 1. Confirm the rule that will grade the data (prints rule + rule_hash, nothing to run)
bin/heimdall-headroom-ab preregister

# 2. Take a "before" snapshot now, unwrapped — absent Headroom IS the "before" arm.
#    This runs the real oracle/falsify sweep (bin/falsify, per-domain 300s alarm) —
#    real wall-clock cost, not free. The tool's own bugfix repro (ad62830) recorded
#    one arm sweeping 300 mutants across 30 paired tasks, as a scale reference; exact
#    runtime on this machine was not measured here, deliberately, since running it
#    was out of scope for this analysis.
bin/heimdall-headroom-ab snapshot --arm before --out .heimdall/headroom-before.json

# 3. Do real coding work for the pre-registered window (7 days by default,
#    --window-days) with Headroom actually in the chain:
hmd wrap <tool>

# 4. Take the "after" snapshot at the end of that window
bin/heimdall-headroom-ab snapshot --arm after --out .heimdall/headroom-after.json

# 5. Grade it
bin/heimdall-headroom-ab report  --before .heimdall/headroom-before.json --after .heimdall/headroom-after.json
bin/heimdall-headroom-ab verdict --before .heimdall/headroom-before.json --after .heimdall/headroom-after.json
```

No `--dry-run` or offline mode exists in the tool, so step 2 was left for RJ to
schedule rather than run speculatively inside this investigation.

**No environment was modified to produce this document.** `uv tool list`,
`python3 -c "import ..."`, and `memory_codec.py status --json` were run read-only;
nothing was installed, upgraded, or reconfigured. No `heimdall-headroom-ab snapshot`
was run, live or otherwise.
