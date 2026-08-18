# Headroom compression: why it's a near-no-op locally, and whether 31%-every-session is reachable

**Verdict: NO, not reachable locally — and the shortfall is not a bug.** The one measured
31% reduction (`docs/analysis/headroom-did-it-help.md` §6) is real, but it is the yield of
compressors operating on a deliberately tiny, cache-safe "live zone" of each request — not
a rate anything is failing to reach across the whole payload. Aggregate compression across
**19,168 real proxy events** (this machine, 2026-08-06 → 2026-08-18) is **0.56%**, and
across headroom's own lifetime ledger (**43,703 requests**) it is **0.27%**. Both numbers
converge on the same story: compression saved **$42.90** on this machine in twelve days;
prompt caching, over the identical window, saved **$17,360.72** — roughly **405×** more.
The architecture spends most of its engineering protecting that cache, correctly, and
compression gets whatever sliver is left over. Getting aggregate compression toward 31%
would mean compressing the cached prefix too, which every measured dollar on this machine
says is a bad trade.

This document also corrects the primary evidence used to frame the question. §0 leads with
that correction because it is the most important finding here — a headline number in the
existing analysis was computed from a file that structurally could not contain the data
being asked of it.

Cross-references `docs/analysis/headroom-did-it-help.md` §6 (the live-proxy evidence this
builds on) and `docs/analysis/token-spend-forensics.md` (the 95.56% cache-read rate and the
"do not shorten the 1h TTL" finding this document's §5 depends on). Neither is duplicated
here beyond what's needed to build the argument.

---

## 0. Correction: the log named as primary evidence cannot show most of what it was asked about

The investigation brief, and `headroom-did-it-help.md` §6, both anchor on
`~/.heimdall/headroom/proxy.log`. That file is real and its numbers are accurate — but it
is not headroom's log. It is hmd's own redirect target:

```sh
# bin/lib/hmd-headroom-chain.sh, read-only citation (not modified):
( "$bin" proxy --host 127.0.0.1 --port "$port" >>"$logdir/proxy.log" 2>&1 & echo $! > "$logdir/proxy.pid" )
```

`>>"$logdir/proxy.log" 2>&1` captures whatever the `headroom proxy` process writes to its
own **stdout/stderr**. Headroom, independently of that redirect, also runs its own file
logger at `~/.headroom/logs/proxy.log` (+ 5 size-rotated files, `.1`–`.5`) — a location hmd
does not create, redirect to, or know about. The two are disjoint in what they capture:

```
$ grep -c "diff_compressor finished" ~/.heimdall/headroom/proxy.log
176
$ grep -c "diff_compressor finished\|compression_ratio=" \
    ~/.headroom/logs/proxy.log ~/.headroom/logs/proxy.log.{1,2,3,4,5}
/Users/rj/.headroom/logs/proxy.log:0
/Users/rj/.headroom/logs/proxy.log.1:0
/Users/rj/.headroom/logs/proxy.log.2:0
/Users/rj/.headroom/logs/proxy.log.3:0
/Users/rj/.headroom/logs/proxy.log.4:0
/Users/rj/.headroom/logs/proxy.log.5:0

$ grep -ic kompress ~/.heimdall/headroom/proxy.log
0
$ grep -ic kompress ~/.headroom/logs/proxy.log ~/.headroom/logs/proxy.log.{1,2,3,4,5}
/Users/rj/.headroom/logs/proxy.log:489
/Users/rj/.headroom/logs/proxy.log.1:316
/Users/rj/.headroom/logs/proxy.log.2:407
/Users/rj/.headroom/logs/proxy.log.3:181
/Users/rj/.headroom/logs/proxy.log.4:367
/Users/rj/.headroom/logs/proxy.log.5:256
```

**Neither log alone is complete — each has a blind spot for the other's primary content.**
The redirected copy carries only `diff_compressor`'s Rust-shim tracing (unqualified logger
name `diff_compressor`); it never sees `headroom.proxy`, `headroom.transforms.pipeline`,
`headroom.transforms.content_router`, or `headroom.transforms.kompress_compressor` — the
loggers that carry everything else, including every kompress invocation. Unique logger
inventory, native log:

```
$ awk -F' - ' '{print $2}' ~/.headroom/logs/proxy.log | sort | uniq -c | sort -rn
18197 headroom.proxy
 2455 headroom.transforms.pipeline
 2102 headroom.transforms.content_router
  425 headroom.transforms.read_lifecycle
  298 headroom.transforms.kompress_compressor
  191 headroom.cache.compression_store
  188 headroom.ccr.context_tracker
    6 headroom.transforms.code_compressor
    5 headroom.ccr.response_handler
```

There is a third, more authoritative source neither log is: headroom's own **structured
savings ledger**, written independently of both text logs:

```
$ wc -l ~/.headroom/savings_events.jsonl
19168 /Users/rj/.headroom/savings_events.jsonl
$ python3 -c "import json; d=json.load(open('/Users/rj/.headroom/proxy_savings.json')); print(list(d.keys()))"
['schema_version', 'lifetime', 'display_session', 'history', 'projects', 'by_model', 'lifetime_metrics']
```

`savings_events.jsonl` is one JSON object per request with `before`/`after`/`saved` token
counts; `proxy_savings.json.lifetime` is headroom's own running total across **every**
request the proxy has ever handled on this machine (43,703 of them), not just the ones that
happened to log a `diff_compressor finished` line. §2 uses these instead of extrapolating
from either text log.

**The "172 of 173 no-op" figure from `headroom-did-it-help.md` §6 is arithmetically
correct and remains true of `diff_compressor` specifically** (§3 confirms and extends it).
What was wrong was treating a 176-line, single-logger stdout capture as a stand-in for
"headroom's compression" in general. It measures one narrow Rust component correctly; it
was never capable of measuring kompress, which is the component that does almost all of
the real work.

(A trivial note on the count drift: the brief cites 173 events / 1,019 lines; this session's
fresh read finds 176 events / 1,022 lines. The proxy wrote 3 more lines, all `ratio=1.0`,
between the original measurement and this one — same phenomenon, 3 more no-op samples, not
a discrepancy.)

## 1. The real aggregate, computed three ways

**Method 1 — `savings_events.jsonl`, every field summed directly, full 19,168-event window**
(2026-08-06T09:23:02Z → 2026-08-18T18:32:25Z, i.e. the same window as the redirected log):

```
$ python3 -c "
import json
n=sb=sa=ss=0
for line in open('/Users/rj/.headroom/savings_events.jsonl'):
    r=json.loads(line); n+=1
    sb+=r.get('before',0); sa+=r.get('after',0); ss+=r.get('saved',0)
print(n, sb, sa, ss, 100*ss/sb)
"
19168 1700338366 1690844973 9493393 0.5583237542497468
```

**Method 2 — headroom's own lifetime ledger**, `proxy_savings.json.lifetime` (43,703
requests — the full population, not just the subset that logged a savings event):

```json
{
  "requests": 43703,
  "tokens_saved": 9478072,
  "compression_savings_usd": 42.898918,
  "cache_read_tokens": 4041638546,
  "cache_savings_usd": 17360.715489,
  "total_input_tokens": 3483195321,
  "total_input_cost_usd": 5976.104686
}
```
`tokens_saved / attempted_input_tokens` (`lifetime_metrics.tokens.attempted_input` =
3,492,673,393) = **0.271%**.

**Method 3 — the periodic self-reported summary**, printed by the proxy itself at shutdown
into the native log (`~/.headroom/logs/proxy.log:23860-23869`, this machine's most recent
proxy run, a ~6.5-hour slice):

```
Total requests:        6316
Cached responses:      5749
Input tokens:          490,887,352
Tokens saved:          1,673,399
Active compression:    0.3%
  (attempted tokens:   492,560,751)
Of total wire traffic: 0.34%
Avg latency:           15154ms
```

Three independent counters — a per-event ledger summed by hand, headroom's own lifetime
total, and the proxy's own printed session report — land in the same **0.3%–0.6%** band.
This is not measurement noise; it is the same architecture measured three ways.

**Compression's own economic ceiling on this machine, lifetime: $42.90. Caching's measured
saving over the identical window: $17,360.72 — about 405× more** (17360.715489 /
42.898918 = 404.68). Whatever conclusion follows about compression has to be sized against
that ratio.

### Aggregate savings falls as request size rises

Bucketing all 19,168 events by `before` token count:

| bucket | n events | % saved |
|---|---|---|
| < 10K | 223 | 1.58% |
| 10K–50K | 5,702 | 1.36% |
| 50K–100K | 7,450 | 0.79% |
| 100K–500K | 5,678 | 0.30% |
| 500K+ | 115 | 0.016% |

Only **4 of 19,168 events (0.021%)** reach the ≥31% reduction the one `diff_compressor`
success achieved. The per-event distribution: min 0.0002%, median 0.29%, p95 3.88%, max
50.41%. `token-spend-forensics.md` Row 1 measured this repo's dominant cost driver as one
15-day session whose mean context was 501,000–731,707 tokens — precisely the size band
where this table shows compression contributing the least (0.016%–0.30%). **Compression
is weakest exactly where the money is.**

## 2. `diff_compressor`: what it actually does, and why 175 of 176 recorded attempts no-op

The brief's working hypothesis was that `diff_compressor` compresses *deltas between
successive requests* — an inter-request mechanism that should be near-ideal for Claude
Code's repeated-prefix workload. That hypothesis is wrong, and the log's own fields say so
directly.

Source (`headroom/transforms/diff_compressor.py`, read in full):

```python
"""Git diff output compressor — Rust-backed via PyO3.
The Python implementation has been retired (Stage 3b, 2026-04-25). All
diff compression now goes through `headroom._core.DiffCompressor`...
"""
@dataclass
class DiffCompressorConfig:
    max_context_lines: int = 2
    max_hunks_per_file: int = 10
    max_files: int = 20
    always_keep_additions: bool = True
    always_keep_deletions: bool = True
    enable_ccr: bool = True
    min_lines_for_ccr: int = 50
```

It is a single-request, structural, unified-diff-hunk compressor — it drops unchanged
context lines from a `git diff`-shaped text block and always keeps every added/removed
line. It has nothing to do with request-to-request deltas. It only receives content that
the content router's detector classified as `ContentType.GIT_DIFF` in the first place
(`content_router.py`'s `_strategy_from_detection` mapping: `GIT_DIFF → CompressionStrategy.DIFF`,
the only path that reaches `_get_diff_compressor()`).

The log's own fields (`files_total`, `hunks_total`) record whether the Rust parser found
any real diff structure in what it was handed:

```
# a representative failure (175 of 176 look like this):
diff_compressor finished input_lines=83 output_lines=83 compression_ratio=1.0
  files_total=0 files_kept=0 hunks_total=0 hunks_kept=0 context_lines_trimmed=0
  cache_key_emitted=false

# the one success:
diff_compressor finished input_lines=51 output_lines=35 compression_ratio=0.6862745098039216
  files_total=2 files_kept=2 hunks_total=2 hunks_kept=2 context_lines_trimmed=16
  largest_hunk_kept_lines=7 cache_key_emitted=true
```

`files_total=0` on every failure means: the router's content-type detector believed this
block looked diff-shaped, but the Rust parser found no `---`/`+++`/`@@` structure to act
on — so it returned the input byte-identical (`ratio=1.0`), correctly, because there was
nothing safe to drop. This is not "not seeing the prefix" and not "not matching against a
prior request" — it is "the content wasn't actually a parseable unified diff," full stop.
Given hmd's own workload — heavy `git status`/`git diff`/`git log` output, grep context
with `+`/`-`-looking lines, Edit-tool previews — the router's cheaper heuristic detector
plausibly over-classifies as `GIT_DIFF` relative to what the strict Rust hunk parser
accepts; that detector is itself Rust-native (`headroom._core.detect_content_type`, per
`content_router.py`'s own comment) and not further introspectable from Python source, which
is an honest limit of this investigation rather than a resolved mechanism.

The `min_lines_for_ccr=50` field explains `cache_key_emitted` precisely: the one success
had `input_lines=51` — **one line over the 50-line floor** — and only above that floor does
the Rust layer emit a CCR (headroom's own internal compressed-content-recovery marker,
persisted via `_persist_to_python_ccr` into `headroom.cache.compression_store`, unrelated to
Anthropic's prompt cache; see §4). Every other recorded input was well under that floor
(single digits to 43 lines) or, like the 83-line case above, over it but structurally
unparseable. Both gates — content-type match and the internal size floor — are visible
directly in the log's own fields, exactly as the brief asked.

## 3. `kompress`: genuinely running, and 31.24% on the slice it's allowed to touch

Confirmed present, loaded, and executing — not merely configured:

```
$ find ~/.cache/huggingface -iname "*.onnx"
/Users/rj/.cache/huggingface/hub/models--chopratejas--kompress-v2-base/snapshots/
  b1563631b35bfdcee37587ad530147497d820d4c/onnx/kompress-int8-wo.onnx
```
That commit hash matches `onnx_runtime.py:56` (`"chopratejas/kompress-v2-base":
"b1563631b35bfdcee37587ad530147497d820d4c"`) exactly — the model is downloaded and pinned
correctly, not missing. A live inference call, native log:

```
2026-08-18 18:27:45,975 - headroom.transforms.kompress_compressor - INFO -
  Kompress slow compress backend=onnx device=onnx words=16 chunks=1 inference_ms=1409 ratio=1.000 saved=0
```
(`/health`'s `checks.kompress.backend: "onnx"`, cited in `headroom-did-it-help.md` §6, is
correct and now directly corroborated by a log line naming the same backend.)

kompress's own size ceiling never fires on this machine — `_kompress_max_tokens` defaults
to 50,000 tokens (`content_router.py`, `~200,000` chars at the estimator's 4-chars/token):

```
$ grep -c "size-gate" ~/.headroom/logs/proxy.log ~/.headroom/logs/proxy.log.{1,2,3,4,5}
/Users/rj/.headroom/logs/proxy.log:0   (... all six: 0)
```
So kompress is never being turned away for being handed too much text. What limits it is
upstream of size: how much content ever reaches it at all (§4).

Every kompress compression that gets recovered through headroom's own CCR mechanism is
logged as a `headroom_retrieve` event with real before/after token counts. Independently
summed, across all six native log files:

```
$ python3 -c "
import json, re, glob
n=to=tc=0
for p in ['/Users/rj/.headroom/logs/proxy.log']+sorted(glob.glob('/Users/rj/.headroom/logs/proxy.log.*')):
    for line in open(p, errors='replace'):
        if 'headroom_retrieve' not in line: continue
        m=re.search(r'\{.*\}', line)
        if not m: continue
        r=json.loads(m.group(0))
        if r.get('original_tokens') is None: continue
        n+=1; to+=r['original_tokens']; tc+=r['compressed_tokens']
print(n, to, tc, 100*(1-tc/to))
"
1181 530013 364437 31.23998845311341
```

**1,181 kompress events, 530,013 → 364,437 tokens, a 31.24% reduction** — independent
verification, matching the sibling investigation's figure exactly. This is the real
explanation for the "31%" number: it is not a rare fluke `diff_compressor` stumbled into
once — it is roughly kompress's *typical* yield whenever it actually gets a block to work
on. The problem was never that compression underperforms on the content it touches. It's
that, per §5, very little content is ever offered to it.

## 4. The decisive finding: compression and prompt caching are in real tension, and the architecture already resolved it in caching's favor

This is the finding the brief asked to lead with if the evidence supported it, and it does.

### The mechanism is real, deliberate, and multi-layered

`compute_frozen_count` (`headroom/cache/compression_cache.py:252-289`) computes how many
leading messages are already anchored in the provider's cache and must not be rewritten —
**the trailing message is always excluded from the frozen prefix by construction**
("by definition it has not yet been sent upstream and therefore cannot be in any provider
prefix cache"). The same file documents a real, named prior bug in exactly this class of
risk:

```python
# `_stable_hashes` is CONTENT-KEYED, not positional... Anthropic's prefix cache is
# positional... Issue #327 was caused by such a misuse in the Anthropic token-mode
# walker... a previous version returned True here, which marked the freshest
# tool_result on every turn as "stable" and effectively disabled compression for
# typical Claude Code workloads where each tool_result is unique-per-turn.
```

That is a first-party admission that headroom has, in the past, shipped a bug in this exact
codebase that near-totally disabled compression specifically for Claude-Code-shaped traffic
— the same symptom this whole investigation was chasing, already once diagnosed and (per
the comment) fixed upstream.

A second, independent layer backstops the first — not just "avoid touching the frozen
region" but "even if something touched it, force it back":

```python
# headroom/proxy/handlers/anthropic.py:322-345
@staticmethod
def _restore_frozen_prefix(
    original_messages, candidate_messages, *, frozen_message_count,
) -> tuple[list[dict[str, Any]], int]:
    """Force frozen prefix bytes to match the original request exactly."""
    if frozen_message_count <= 0 or not original_messages:
        return candidate_messages, 0
    frozen = min(frozen_message_count, len(original_messages))
    restored = list(candidate_messages)
    if len(restored) < frozen:
        return list(original_messages[:frozen]) + restored, frozen
    changed = 0
    for idx in range(frozen):
        if restored[idx] != original_messages[idx]:
            restored[idx] = original_messages[idx]
            changed += 1
    return restored, changed
```

Byte-for-byte, index-by-index: anything inside the frozen region that differs from the
original is overwritten with the original before the request leaves the proxy. A third,
even more conservative policy exists alongside it — `_strict_previous_turn_frozen_count`:
"Freeze all prior turns; only the final turn is mutable" — and the two are combined via
`min()` at the call site (`anthropic.py:1319`), so the *more* conservative of the two always
wins.

This is not theoretical. It fires on essentially every observed request, live:

```
CCR: deferring tool injection (frozen_message_count=725) to preserve cache   [727-msg request]
CCR: deferring tool injection (frozen_message_count=113) to preserve cache   [115-msg request]
CCR: deferring tool injection (frozen_message_count=16) to preserve cache    [17-msg request]
CCR: deferring tool injection (frozen_message_count=626) to preserve cache   [626-msg request]
CCR: skipping proactive expansion append in cache mode to preserve next-turn prefix stability
```

In every sampled case, **all but one to three messages out of dozens-to-hundreds are
frozen**. That is the direct, mechanical explanation for §1's aggregate: compression is
architecturally permitted to touch only the newest sliver of each request. §3 already
showed that sliver compresses at ~31% when it's kompress-eligible content; the aggregate is
~0.3–0.9% because the sliver is a tiny fraction of the total.

### The dollar comparison, restated precisely

`token-spend-forensics.md` independently measured this workload's cache-read rate at
**95.56%**, uncached input at **0.0023%**, and explicitly recommended *against* shortening
the 1-hour cache TTL because doing so would cost **~$590 more**. Headroom's own lifetime
ledger, on the identical machine and largely overlapping window, is fully consistent:
`cache_savings_usd: $17,360.72` against `compression_savings_usd: $42.90`. Compression's
entire lifetime yield is **0.25%** the size of one month's caching benefit. Any
compression-driven cache degradation north of that fraction is a net loss for the user, and
the architecture evidently understands this — hence three independent protective layers
around the frozen prefix.

### What isn't fully resolved locally

Headroom's own telemetry tracks real cache instability:

```json
"prefix_cache": {
  "requests": 43703, "hit_requests": 40301,
  "bust_count": 1282, "bust_tokens": 100429499,
  "misses_by_reason": {"prefix_change": 541, "unknown": 3, "ttl_expiry": 2}
}
```

**2.9% of requests (1,282 / 43,703) recorded a cache bust**, and of the 546 classified
misses, **541 (99%) were attributed to `prefix_change`** against just 2 to `ttl_expiry` —
i.e. when caching misses on this machine, it is overwhelmingly because content differed
from what should have matched, not because time simply ran out. This is consistent with
(but does not, on its own, *prove*) some residual compression-driven cache disturbance
getting past the three protective layers above — Claude Code itself also legitimately
changes prefixes (context edits, compaction, branch switches, CLAUDE.md changes). Isolating
headroom's specific contribution to that 2.9% would need a controlled wrapped-vs-unwrapped
A/B, which is exactly what `headroom-did-it-help.md` §6 already prescribes and defers to
the user rather than running speculatively. This document does not run one either — stated
here as a limit, not filled in with a guess.

## 5. Cost: the leaked-thread → quarantine → cascade failure, fully reconstructed

`background_compression.py`'s own docstring predicts this failure mode by name:

> "When a cold-start-large request would otherwise run kompress synchronously under the 30s
> budget (and **leak a non-preemptible worker on timeout -> executor saturation ->
> cascade**), it instead forwards the already-cached/uncompressed messages immediately and
> enqueues the compression here... **only the token-mode cold-start path defers here --
> other modes compress synchronously**."

hmd's actual runtime configuration does not get this protection. `agent_savings.py` sets
`DEFAULT_PROFILE = "coding"`, and the `"coding"` profile sets `proxy_mode="cache"`
(confirmed live: `"CCR: skipping proactive expansion append **in cache mode**..."`).
`bin/lib/hmd-headroom-chain.sh` (read for this investigation, not modified) sets exactly one
env var, `ANTHROPIC_BASE_URL` — it never sets `HEADROOM_SAVINGS_PROFILE` or any other
`HEADROOM_*` variable, so headroom's own default applies unmodified. **Cache-mode requests
compress synchronously, on the request path, with no async escape hatch — precisely the
condition the docstring says leaks a thread when a job runs long.**

Total leak events (`"exceeded its request deadline"`) across the full native log history:

```
$ grep -c "exceeded its request deadline" ~/.headroom/logs/proxy.log ~/.headroom/logs/proxy.log.{1,2,3,4,5}
/Users/rj/.headroom/logs/proxy.log:14   /Users/rj/.headroom/logs/proxy.log.1:0
/Users/rj/.headroom/logs/proxy.log.2:1  /Users/rj/.headroom/logs/proxy.log.3:3
/Users/rj/.headroom/logs/proxy.log.4:5  /Users/rj/.headroom/logs/proxy.log.5:0
```
**23 events** across this machine's full log history (a longer, multi-process window than
the single `/health` snapshot's cumulative `leaked_threads_total=10` cited in
`headroom-did-it-help.md` §6 — the two are different measurement windows over different
proxy process lifetimes, not a contradiction).

One full cascade, reconstructed second-by-second from the native log
(`~/.headroom/logs/proxy.log:300-360`), request `hr_1787057836_004181`, 2026-08-18
18:27:32–18:27:57:

| time | event |
|---|---|
| 18:27:32.986 | Pipeline starts freezing 725/727 messages for this request |
| 18:27:46.617 | `content_router` finishes: 18,326.6ms just for this stage |
| 18:27:46.691 | **`Compression worker exceeded its request deadline and is still running; new compression is quarantined until timed-out workers exit`** |
| 18:27:46.691 | `[hr_...4181] Optimization failed: TimeoutError:` — this request's own compression fails |
| 18:27:47.223 | its outbound request finally goes out: **`body_bytes=8954259`** (8.95 MB) |
| 18:27:48.021 | a *different, concurrent* request (`hr_...4190`) fails: **`Optimization failed: CompressionQuarantinedError: compression quarantined: 1 timed-out worker(s) still running`** — collateral damage, not its own payload's fault |
| 18:27:47.806 | same window: `Token counting for model claude-sonnet-5 failed or timed out (CompressionQuarantinedError); falling back to estimation` — a second, concurrent request loses exact token accounting too |
| 18:27:50.743 | the triggering request's own response lands: **`duration_ms=34498.55`** |
| 18:27:57.504 | `Pipeline complete: 5871354 -> 5870252 tokens (saved 1102, 0.0% reduction)` — full pipeline: 24,520ms |
| 18:27:57.505 | `Compression quarantine cleared after all timed-out workers exited` |

**Answer to the brief's question directly: yes, this is correlated with large payloads, and
it recurs precisely where compression would matter most.** The triggering request here was
727 messages / 8.95MB / ~5.87M raw pipeline tokens (as logged; that figure is materially
larger than the outbound byte count would suggest by simple 4-bytes/token estimation, and
this investigation did not resolve that specific discrepancy — noted rather than
guessed at) — exactly the scale where compression's potential payoff is largest. The
mechanism spent 24.5 seconds of pipeline time and left one concurrent, unrelated request
degraded, to save **1,102 tokens (0.0%)** on the triggering request itself. The quarantine
window (18:27:46.691 → 18:27:57.505, ~10.8s) blocked *other* sessions' compression too, not
just the request that caused it — the "cascade" the docstring names is directly observable,
not hypothetical.

## 6. Verdict: is 31%-every-session reachable locally?

**No — not without accepting a trade this workload's own numbers say is bad.**

The 31% figure is real, reproducible, and roughly representative of what both compressors
achieve *on the content they're permitted to touch* (§2's single diff success at 31%; §3's
1,181-event kompress average at 31.24% — independently converging on the same number via
two different compressors and two different measurement methods). It was never a rate
being missed 99.4% of the time by malfunction. It is the yield on a **deliberately small
live zone** — typically the newest 1–3 messages of a request that can run to hundreds — and
that boundary is enforced by three independent, working protective layers (§4) because
compressing further in would touch the prefix a 95.56%-cache-read workload depends on.

Reaching anywhere near 31% in aggregate would require compressing inside the frozen prefix.
Given this machine's own measured economics — $42.90 lifetime compression savings against
$17,360.72 lifetime cache savings, a 405× gap — that trade only pays off if the induced
bust rate stays far smaller than what's already being tolerated. That is not a local
configuration knob (no `HEADROOM_*` env var moves the frozen-prefix boundary without also
widening cache-bust exposure), and the `"coding"` profile already active here is, by its own
code comments, specifically tuned for this exact workload shape (`protect_reads=True`,
`force_kompress=False` "don't override diff/log lossless with lossy ML",
`proxy_mode="cache"` for "delta-only compression at ~0 prefix-cache busts"). The shortfall
from 31% to <1% is that tuning working as designed, not a misconfiguration on hmd's side.

What **is** a real, fixable-adjacent cost, independent of the 31% question: the
leak/quarantine cascade in §5 is a genuine reliability defect (up to 34.5s added latency,
collateral compression/token-counting failures on unrelated concurrent requests) that fires
under exactly hmd's real default profile (`proxy_mode="cache"`, no async deferral), for
approximately zero compression benefit when it happens. That defect and the 31% ceiling are
separate findings: fixing the leak would not move the aggregate compression rate, and
raising the aggregate compression rate would not fix the leak.

## Provenance and what was and wasn't touched

Read-only throughout. No proxy was started; nothing under
`/Users/rj/.local/share/uv/tools/` was modified; `bin/heimdall-wrap`,
`bin/lib/hmd-headroom-chain.sh`, `bin/heimdall`, `hooks/hooks.json`, and `sentinels/` were
not edited (the wrap-chain script was read once, quoted above, for its env-var behavior).
Every number above is quoted from a command run fresh in this session against:

- `~/.heimdall/headroom/proxy.log` (hmd's redirected copy — 1,022 lines, gitignored, local)
- `~/.headroom/logs/proxy.log` + `.1`–`.5` (headroom's native rotating log — 178,219 lines,
  gitignored, local, newly identified by this investigation)
- `~/.headroom/savings_events.jsonl` (19,168 structured events) and
  `~/.headroom/proxy_savings.json` (headroom's own lifetime ledger, 43,703 requests) —
  both gitignored, local, newly identified by this investigation
- The installed package source, `/Users/rj/.local/share/uv/tools/headroom-ai/lib/python3.13/site-packages/headroom/`
  (read-only; `diff_compressor.py`, `agent_savings.py`, `compress.py`,
  `cache/compression_cache.py`, `proxy/handlers/anthropic.py`, `proxy/background_compression.py`,
  `proxy/compression_decision.py`, `transforms/content_router.py`,
  `transforms/kompress_compressor.py`, `transforms/compressor_registry.py`)

None of this repo's own tracked files, tests, or hooks were modified — see the companion
change to `docs/analysis/headroom-did-it-help.md` §6 (a short, dated pointer to this
document, matching that document's own established in-place-correction convention; no
existing content there was removed).
