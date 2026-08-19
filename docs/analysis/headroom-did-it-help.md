# Headroom: did it help?

**Verdict: MIXED, updated 2026-08-18.** Storage-codec: still not actually running
(§1-4, unchanged). Traffic-proxy: **is** actually running — found live and engaged
on this machine, contradicting this doc's original "zero usage evidence" framing for
that wire — and measured, from its own operational log, to deliver savings on 1 of
173 recorded attempts while carrying a real tail-latency and reliability defect. See
§6. Original 2026-08-11 finding preserved below unedited except where noted.

**Original verdict, 2026-08-11: NOT ACTUALLY RUNNING.**

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
number to report. **(2026-08-18: the "nothing measured" half of this sentence no
longer holds — see §6. "Zero repo-committed receipts" and "zero real-world usage"
turned out to be different claims; this doc originally conflated them.)**

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

## 6. Live proxy evidence, found independently (2026-08-18)

A user reported hmd feeling slow/expensive and asked whether Headroom was the cause,
citing `docs/analysis/token-spend-forensics.md` ($1,103.05 / 234 sessions). That
document was read in full for this update: it names its cost drivers explicitly
(Row 1, one 15-day session never restarted/compacted, $913.54, 82.8% of spend; Row 2,
a cache-write cliff above 800K context, $118.92) and **mentions Headroom zero times**.
`grep -ic headroom docs/analysis/token-spend-forensics.md` → `0`. The forensics doc's
own two comparison days make the actual driver unambiguous: 2026-08-05 at 731,707
mean context cost $0.366/request; 2026-08-07 at 118,678 mean context cost
$0.0593/request — a 6.17× difference **from context size alone, same repo, same
working style, nothing skipped**. Headroom is not part of that story at all. This
part of the user's concern rests on a misattribution, and it is corrected here
plainly rather than acted on.

That would have closed the investigation — except checking Headroom on its own
terms, independent of the forensics doc, surfaced something the doc's premise didn't
predict: this session's own environment was already routed through a live Headroom
proxy:

```
$ env | grep -i "ANTHROPIC_BASE_URL\|HEADROOM"
ANTHROPIC_BASE_URL=http://127.0.0.1:8787

$ curl -s --max-time 3 http://127.0.0.1:8787/health
{"service":"headroom-proxy","status":"healthy","ready":true,"version":"0.33.0",
 "uptime_seconds":41959.858,
 "checks":{"upstream":{"url":"https://api.anthropic.com"},
           "kompress":{"backend":"onnx"},"memory":{"enabled":false}},
 "runtime":{"compression_executor":{
    "max_workers":10,"run_seconds_total":3854.66,"run_seconds_max":64.75,
    "leaked_threads_total":10,"quarantine_activations_total":10,
    "timed_out_workers_max":1,"quarantine_skips_total":48}}}

$ ps aux | grep 8787
rj  5157  131.5  1.6 ... R+  7:41AM  93:49.49 .../headroom proxy --host 127.0.0.1 --port 8787
```

This does not contradict §2 — §2 searched exhaustively for *repo-committed* receipts
(tracked JSON, git history, the snapshot schema string) and correctly found none. A
live, gitignored, machine-local proxy with its own local log
(`~/.heimdall/headroom/proxy.log`) is a different category of evidence that no repo
search could surface. **"Zero repo-committed receipts" and "zero real-world usage"
are different claims — this machine falsifies the second while the first still
holds.**

**Delivered compression, measured directly from the proxy's own log** (2026-08-06
15:07:34 → 2026-08-18 19:17:17, 1,019 lines, gitignored, local to this machine):

```
$ grep -o "compression_ratio=[0-9.]*" ~/.heimdall/headroom/proxy.log | sort | uniq -c | sort -rn
    172 compression_ratio=1.0
      1 compression_ratio=0.6862745098039216
```

**172 of 173 recorded `diff_compressor` invocations (99.4%) show a compression ratio
of exactly 1.0 — no reduction.** One event in 12 days achieved a real ~31%
reduction. `grep -ic kompress ~/.heimdall/headroom/proxy.log` → `0` — the
manifest's other named compressor (ONNX-backed `kompress`) leaves no log trace
distinguishable from `diff_compressor` in this file; there is no log evidence it ran
at all, let alone that it offsets `diff_compressor`'s near-total ineffectiveness.

**A correction, made explicitly rather than left standing (2026-08-19):** the
`grep -ic kompress` result above is accurate but was read as "kompress never ran" —
it actually shows only that this specific file cannot see it. `~/.heimdall/headroom/proxy.log`
is hmd's own redirected-stdout capture of exactly one Rust component's logger
(`diff_compressor`, unqualified name); it was never wired to kompress's logger, and —
symmetrically — `diff_compressor`'s own summary lines never reach headroom's *own*
native log either. The two logs are disjoint, not overlapping subsets of the same
data. Headroom's native log (`~/.headroom/logs/proxy.log*`, not examined in this
section) and its structured savings ledger (`~/.headroom/savings_events.jsonl`,
`~/.headroom/proxy_savings.json`) show kompress running extensively: 1,181 recovered
events averaging a 31.24% reduction on the content it's permitted to touch, inside a
full lifetime aggregate of 0.27%–0.56% across 43,703 requests — against $17,360.72 in
cache savings over the same window versus $42.90 from compression, a ~405× gap. The
"172 of 173" `diff_compressor` figure above is unaffected and correctly characterizes
that one narrow component; it was never a valid stand-in for headroom's compression as
a whole. Full re-derivation, three independent measurement methods, and the
architecture explaining why the gap is by design, not a bug:
[`docs/analysis/2026-08-19-headroom-compression-diagnosis.md`](./2026-08-19-headroom-compression-diagnosis.md).

**Cost, same evidence:**

- `run_seconds_max=64.75` — a single worst-case compression job ran **64.75
  seconds, more than double** the package's own configured 30-second compression
  timeout. The timeout mechanism took over 2× its own ceiling to resolve in at
  least one real case.
- `leaked_threads_total=10`, `quarantine_activations_total=10` against ~173 total
  attempts — a materially high internal failure rate for the compression
  subsystem, not a rare tail.
- A live, isolated call to the proxy's own `/stats` endpoint measured **10.19s**
  (`http_code=200 time_total=10.186827`) against **16.5ms** for `/livez` on the
  same process, moments apart.
- `grep -ic "error|exception|traceback|timeout|leaked|quarantine|retry|failed"
  ~/.heimdall/headroom/proxy.log` → **53** matches over the 12-day window, including
  repeated `httpx.ReadError`/`httpcore.ReadError` frames from
  `headroom/proxy/helpers.py:915 in request_with_transient_retry`.

**A correction, made explicitly rather than left standing:** two `ps` samples taken
alongside the slow `/stats` call above read 82.4% and 131.5% CPU, and an intermediate
draft of this finding characterized the proxy as under sustained heavy CPU load. A
clean re-sample taken seconds later, no request in flight, read **18.0% → 0.7% →
0.1%** over 3 seconds. The accurate characterization: **idle at baseline**
(consistent with light real volume — 173 compression attempts over 12 days, roughly
one every two hours), **with real spikes tied to individual jobs**, at least one of
which ran 64.75s. "Sustained heavy CPU drain" would have been an overclaim against
this machine's actual traffic; it is retracted here rather than quietly dropped.

**Net, on this machine, right now:** the traffic-proxy wire works in the sense that
the process is healthy and genuinely engaged in real sessions — but against its one
stated purpose, it delivers savings on 1 of 173 measured attempts (0.6%) while
carrying a real tail-latency risk (up to 65s on a single call, past its own
configured timeout) and a nontrivial internal reliability defect rate (10 leaks / 10
quarantines per ~173 attempts). **This is not hmd's own code underperforming** —
`bin/lib/hmd-headroom-chain.sh` and `bin/heimdall-wrap` do exactly what they claim
(start or reuse a proxy, export one env var, fail open on any error) and are not
implicated in the thread leaks or the `/stats` latency, which live entirely inside
the pinned `headroom-ai==0.33.0` binary's own compression executor. The opt-in
machinery is honest and was never the problem; what it optionally invokes, at this
pin, is what the numbers above describe.

**Recommended action for this machine:** `hmd unwrap claude` (see
`bin/heimdall-wrap:626-645` for the subcommand). Not run as part of this
investigation — the proxy at PID 5157 may be shared by other concurrently-running
sessions on this machine, and stopping a live, possibly-shared process is an
operator decision outside a single docs commit, not something to do silently from
inside an analysis pass.

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

**Traffic-proxy wire — updated 2026-08-18.** §6 found this wire already engaged,
unmeasured-by-receipt, on at least one machine, and delivering savings on 1 of 173
attempts. The immediate action on that machine is `hmd unwrap claude` (operator
call, not run here — see §6). The formal A/B below is still the right way to
produce a pre-registered, statistically-graded verdict; it just no longer starts
from a clean "before" — any new `before` snapshot on a machine that has already run
wrapped for 12 days is not a true unwrapped baseline. A fresh machine, or a real
`hmd unwrap` first, would be needed for a clean pair:

```sh
# 1. Confirm the rule that will grade the data (prints rule + rule_hash, nothing to run)

```sh
# 1. Confirm the rule that will grade the data (prints rule + rule_hash, nothing to run)
bin/heimdall-headroom-ab preregister

# 2. Take a "before" snapshot now, unwrapped (run `hmd unwrap claude` first if a
#    proxy is already engaged, per §6) — absent Headroom IS the "before" arm.
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

## 7. Kompress `backend: null` in `/health` while the log shows `backend=onnx` running (2026-08-19)

Follow-up from §6, explicitly flagged there and correctly left alone as out of
scope for that pass. Since §6, headroom-ai was upgraded on this machine 0.33.0
→ 0.35.0 (`uv tool install --python 3.13 "headroom-ai[all]==0.35.0"`), and
`/health`'s `checks.kompress` now reads `{"enabled":true,"ready":false,
"status":"degraded","optional":true,"backend":null}`. Upstream's own startup
log offers an explanation for that — 0.35.0's prefetch-at-startup behavior:
`"Kompress: prefetching model artifacts for chopratejas/kompress-v2-base
..."`, `"Kompress model preload deferred until first request"`, `"Kompress:
artifact prefetch complete ...; the model loads on first use without a
download stall."` — predicting `backend` flips from `null` to `onnx` once real
traffic forces the first load. Nobody had watched that happen end-to-end on
this machine. This section does, and finds a third outcome that neither of
this investigation's two anticipated branches predicted.

**Real traffic, confirmed first, from the proxy's own request log**
(`~/.headroom/logs/proxy.log`, not synthesized): live `POST
https://api.anthropic.com/v1/messages` calls with `status=200` and `PERF`
lines reporting real `tok_before`/`tok_after`/`tok_saved` figures, e.g. `PERF
model=claude-sonnet-5 msgs=14 tok_before=76661 tok_after=74801 tok_saved=1860
... client=claude-code` — ordinary wrapped-session traffic, not a call
originated for this investigation.

**Two `/health` polls, ~22 minutes apart, both showing `backend:null`:**

```
poll 1  timestamp 2026-08-19T01:56:12Z  uptime_seconds=23067.28
        "kompress":{"enabled":true,"ready":false,"status":"degraded","optional":true,"backend":null}
poll 2  timestamp 2026-08-19T02:18:04Z  uptime_seconds=24379.75
        "kompress":{"enabled":true,"ready":false,"status":"degraded","optional":true,"backend":null}
```

**But the log shows `backend=onnx` compressing real content, successfully, for
hours, well before either poll:**

```
2026-08-18 18:26:17  Kompress slow compress backend=onnx device=onnx words=22 chunks=1 inference_ms=1656 ratio=0.955 saved=1
2026-08-18 19:31:13  Kompress slow compress backend=onnx device=onnx words=1759 chunks=6 inference_ms=5772 ratio=0.699 saved=529
2026-08-18 23:07:21  Kompress slow compress backend=onnx device=onnx words=564 chunks=2 inference_ms=1457 ratio=0.764 saved=133
```

496 `kompress`-tagged lines in the current log file alone (316 more in the one
prior rotation checked), the large majority genuine `backend=onnx ...
saved=N` successes. Exactly 13 are a distinct `WARNING`: `"Kompress execution
saturated after ~3000ms; skipping chunk=0 for backend=onnx device=onnx after
deadline path"` — a real per-chunk compression-deadline issue, worth its own
follow-up, but not an initialization failure and not this section's subject.
Zero other kompress-tagged `WARNING`/`ERROR`/`CRITICAL` lines exist in the
current log. One `"Kompress: prefetching model artifacts ..." / "... preload
deferred until first request" / "... artifact prefetch complete ..."`
sequence appears once, at 2026-08-19 01:01:49–01:01:57 — roughly an hour
after the last compression observed in this excerpt, and not immediately
followed by another confirmed `slow compress` success in the lines checked.
Separately, the proxy's periodic `TOIN: 699 patterns, 2403 compressions, 4285
retrievals, 178.3% retrieval rate` heartbeat read identically across eleven
consecutive 5-minute samples from 05:31:57 to 07:26:24 — no new compression
in that ~2h window either. So real, successful `onnx` compression is
well-established earlier in this same process's uptime; what is
under-determined from the log alone is whether `/health` would have read
`onnx` DURING that earlier active window — both polls taken here happened to
land after it had already gone quiet.

**Traced to source rather than left as a correlation.** headroom-ai 0.35.0's
own `headroom/proxy/server.py` computes `/health`'s (and `/debug/warmup`'s)
kompress status via `_reconcile_kompress_health()` (`server.py:2767`), which
tries two ways to detect a loaded model before ever calling
`proxy.warmup.kompress.mark_loaded(...)`: (a) ask the live `ContentRouter`'s
own `_kompress`/`_kompress_remote` compressor instance whether `is_ready()` /
`ready_backend()` report loaded, or (b) fall back to a module-level
`_kompress_cache.get(HF_MODEL_ID)` lookup in
`headroom.transforms.kompress_compressor`. Only if one of those two finds a
loaded model does `warmup.kompress` ever flip away from its startup default.

**Live-confirmed, right now, that neither path has fired.** The proxy's own
`/debug/warmup` endpoint — named in the source as the single source of truth
`/health` and `/readyz` are built from — currently reads:

```
$ curl -s http://localhost:8787/debug/warmup
"kompress":{"status":"null","info":{"source_status":"deferred"}}
```

`status` is still the literal string it starts at, `source_status` is still
`"deferred"` — `mark_loaded()` has never fired for kompress on this process,
despite the log proving its compressor loaded and ran successfully hundreds
of times. This was queried live, read-only, with no restart and no config
change, exactly like the `/health` polls above.

**Verdict: neither of this investigation's two anticipated outcomes.** The
lazy-load story is correct for the compressor itself — it loads, and it
works, delivering real measured savings across hundreds of real requests
(more volume than 0.33.0's single 31%-reduction event referenced in §6, not a
functional regression). But it is wrong for what `/health` reports about it:
the health surface and the runtime it claims to describe are simply out of
sync, on a mechanism now identified by name and file:line rather than
inferred from a black box. This reads as a headroom-ai 0.35.0
health-reporting bug — most plausibly in whichever code path actually serves
the real compressions not being one of the two paths
`_reconcile_kompress_health()` checks — not a functional regression, and not
confirmation of the "it flips once traffic arrives" explanation as literally
stated. Anything that gates or alerts on `checks.kompress.backend`
specifically (rather than the proxy's own log or its savings ledger) is
reading a signal that is demonstrably wrong on this machine, on this version.
Filed as a finding, not patched here — a fix, if any, belongs upstream in
headroom-ai; neither `modules/headroom/manifest.json` nor
`bin/lib/hmd-headroom-chain.sh` computes or reports this field.
