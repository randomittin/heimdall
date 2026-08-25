# Headroom is in the live request path — does it endanger caching, and is chaining OmniRoute behind it safe?

Date: 2026-08-25
Task: DELTA BRIEF `brief-1787643911-11058`
Scope: read-only measurement only. No file outside this document was created or
modified for this task. The running proxy (PID 6404) was never stopped,
restarted, reconfigured, or sent malformed traffic. The only two requests this
investigation made to it directly were `GET /health` and `GET /livez` — no
body, no state change, the same read-only status-endpoint class
`docs/analysis/headroom-did-it-help.md` §6 already used against this exact
process. Every other number below comes from reading source files, reading
this repo's own prior docs, reading Headroom's own on-disk ledger files, or
mining Claude Code's own session transcripts — none of it required touching
the proxy.

## Why this exists

`ANTHROPIC_BASE_URL=http://127.0.0.1:8787` is set on this machine and points
at a live, already-running Headroom proxy
(`/Users/rj/.local/bin/headroom proxy --host 127.0.0.1 --port 8787 --lossless`,
PID 6404, parent PID 1) that every Claude Code request from this machine —
including the session that produced the brief for this doc, and the session
that wrote this doc — already traverses. Nobody had connected that dot until
now. Four questions follow, in order of how much damage a wrong answer could
do to the operator's live session.

## Verdicts

| # | Question | Verdict |
|---|---|---|
| **Q1** (load-bearing) | Does `--lossless` mode break prompt-cache prefix matching? | **NO.** OBSERVED from source: `--lossless` sets exactly four flags, all consumed by the tool-output `ContentRouter` / `SmartCrusher` / CCR-marker machinery. `cache_control` and frozen-prefix protection live in an entirely separate module pair (`proxy/handlers/anthropic.py`, `cache/compression_cache.py`) that never reads `config.lossless` — confirmed by exhaustive grep, not assumption. |
| **Q2** | Is the cache actually working right now? | **YES.** OBSERVED: 94.85% of this live session's input-side tokens are cache reads (1,382 real usage records, re-measured fresh in this session). Machine-wide lifetime ledger: 54,299 / 59,375 requests hit (91.4%), bust rate 2.18% — down from 2.93% measured 2026-08-19. |
| **Q3** | What is Headroom actually saving today? | **Compression: ~0.35% of input tokens, $70.21 lifetime. Caching: ~86-95% hit rate, $23,671.90 lifetime — a 337x gap.** Both OBSERVED from the same live ledger. The mechanism sitting in the request path is worth a rounding error next to the mechanism it sits beside. |
| **Q4** | Chain OmniRoute behind Headroom for "efficiency + fallback"? | **NO.** Two independently-documented blockers from the same-day OmniRoute investigations still apply unchanged (unremovable Tier-1 OAuth-subscription reuse; `cache_control` dropped at OmniRoute's Anthropic→OpenAI translation for both backends actually in use). Q3 removes the efficiency case for accepting that risk: there is under half a percent of compression benefit to protect, and the chain would discard the 86-95% that actually matters before either backend ever saw it. |

## 0. Repo state and figure verification

Fast-forward check, before anything else:

```
$ git fetch origin main && git rev-parse HEAD origin/main
b5ed53b95ef690f3a78e62c0fb025cbad054501c
b5ed53b95ef690f3a78e62c0fb025cbad054501c
```

Already at current main. No action needed.

The brief cites "a remeasure putting compression at $63.95 against $22,375.72
from Anthropic prompt cache — a ~350x difference." That figure is real, not a
hallucination: it is `docs/analysis/2026-08-23-token-stack-remeasure.md`'s own
§1 table, sourced from `~/.headroom/proxy_savings.json` at 55,242 requests.
Re-reading that same live file now (traffic has kept accruing since
2026-08-23):

```
$ python3 -c "
import json
d = json.load(open('/Users/rj/.headroom/proxy_savings.json'))
lt = d['lifetime']
print(lt['requests'], lt['compression_savings_usd'], lt['cache_savings_usd'],
      lt['cache_savings_usd']/lt['compression_savings_usd'])"
59375 70.206993 23671.901884 337.1729919268868
```

59,375 requests now (up from 55,242 on 2026-08-23), $70.21 compression /
$23,671.90 cache, ratio 337.17x. **The brief's cited figures verify as
accurate for their snapshot** — no correction needed — and the fresher
measurement moves in the same direction, just with a slightly narrower ratio
(349.9x → 337.17x) because compression's dollar total grew a little faster
than cache's in this window. Neither number reversed sign or trend.

## Q1 — Does `--lossless` break prompt caching? (load-bearing)

**Method**: read Headroom's own source at the currently-installed, currently-
running version (0.35.0, confirmed live below), not inference from behavior.

**What `--lossless` is, verbatim from the CLI itself**
(`headroom/cli/proxy.py`, re-read this session):

```
@click.option(
    "--no-ccr",
    is_flag=True,
    envvar="HEADROOM_NO_CCR",
    help=(
        "Disable CCR entirely: no retrieval markers in compressed content AND no "
        "headroom_retrieve tool injected. Lossy compression with no recovery path "
        "(maximum savings; also right for streaming / non-MCP clients that can't "
        "resolve an injected tool). Env: HEADROOM_NO_CCR."
    ),
)
@click.option(
    "--lossless",
    is_flag=True,
    envvar="HEADROOM_LOSSLESS",
    help=(
        "No-CCR lossless mode: compress tool outputs with format-native lossless "
        "compaction (and marker-free SmartCrusher) without emitting any CCR "
        "retrieval marker, so no MCP retrieve tool is needed. Env: HEADROOM_LOSSLESS=1."
    ),
)
```

CCR ("Compressed Content Retrieval") is Headroom's **own** internal recovery
mechanism for reconstructing lossily-compressed tool output on demand
(`<<ccr:...>>` markers plus an injected `headroom_retrieve` MCP tool) — it has
nothing to do with Anthropic's prompt cache. Conflating the two is the
easiest way to get this question wrong, so it's worth stating plainly: CCR is
about Headroom recovering what Headroom itself compressed; prompt caching is
Anthropic serving a repeated prefix at a discount. `--lossless` only touches
the former.

**Where `--lossless` actually wires in**, `headroom/proxy/server.py`
(re-read this session, lines as currently laid out in 0.35.0):

```python
# server.py:840-853
            ccr_inject_marker=config.ccr_inject_marker,
            force_kompress_all=config.force_kompress_all,
            lossless=config.lossless,
        )
        ...
        # No-CCR lossless mode: compress tool outputs with format-native
        # lossless compaction and marker-free SmartCrusher, and suppress every
        # retrieval marker + the retrieve-tool injection so no MCP round-trip is
        # needed. Mirrors the force_kompress_all wiring precedent.
        if config.lossless:
            router_config.lossless = True
            router_config.smart_crusher_lossless_only = True
            router_config.ccr_inject_marker = False
            if hasattr(config, "ccr_inject_tool"):
                config.ccr_inject_tool = False
```

Four assignments, all of them fields on `router_config` (a `ContentRouter`
config) or the CCR-injection switch. `ContentRouterConfig.lossless` itself
(`headroom/transforms/content_router.py:1511-1516`, re-read this session) is
documented as scoped to **tool-output** compaction:

```python
    # No-CCR lossless mode. When True the router compresses LOG/SEARCH/DIFF
    # content with format-native lossless compaction (headroom.transforms.
    # lossless_compaction) instead of the lossy Rust drop path, and never
    # emits a CCR marker for that content ...
    lossless: bool = False
```

Grepping every one of the ~140 `lossless` occurrences in `content_router.py`
confirms all of them live inside `_lossless_first`, `_has_lossless_fold`,
`_apply_lossless_provider`, `_lossless_compact_excluded`, and the SmartCrusher
gating around them — the tool-output compaction pipeline. None of them touch
message roles, system prompts, or `cache_control` blocks.

**Where prompt-cache protection actually lives** — a disjoint module pair,
confirmed present and unconditional (not gated on `--lossless`) in the
currently-running 0.35.0 source, re-verified fresh this session:

```
$ grep -n "def compute_frozen_count" .../headroom/cache/compression_cache.py
287:    def compute_frozen_count(self, messages: list[dict]) -> int:
$ grep -n "_strict_previous_turn_frozen_count\|_restore_frozen_prefix" .../headroom/proxy/handlers/anthropic.py | head -6
342:    def _strict_previous_turn_frozen_count(
358:    def _restore_frozen_prefix(
1202:                frozen_message_count = self._strict_previous_turn_frozen_count(
4276:                    self._strict_previous_turn_frozen_count(original_messages, 0)
```

This three-function chain (documented in depth in
`docs/analysis/2026-08-19-headroom-compression-diagnosis.md` §4, function
names and general shape re-confirmed unchanged at the current pin) freezes
whatever portion of the message list the previous turn already sent to the
provider and byte-for-byte restores anything within that frozen region that
compression would otherwise have touched, before the request leaves the
proxy. It is a correctness backstop specifically for cache prefix integrity,
independent of which compression mode is active.

`proxy/handlers/anthropic.py` manages `cache_control` **directly and
extensively** — 30 distinct touchpoints on a fresh grep this session (marker
snapshotting, TTL-lane detection, breakpoint-placement normalization,
`enforce_cache_control_ttl_order`, stripping a client's transient marker only
to restore it after compression). Grepping the same file for `lossless`
returns 5 hits, and none of them intersect the 30 `cache_control` hits — two
separate subsystems, confirmed by direct inspection rather than assumed from
naming.

**Why `--lossless` was chosen at all** — and this is worth stating because it
reframes the whole question — per this repo's own
`modules/headroom/manifest.json` `pin_provenance` field (dated 2026-08-20,
re-read this session): the flag was adopted to fix a **streaming-integrity**
bug (Headroom's `headroom_retrieve` tool injection turning a client's
`stream:true` request into `stream:false` upstream — Headroom upstream issues
#3071/#3130, still unfixed in any released version), not primarily as a
cache- or compression-motivated choice:

> "`bin/lib/hmd-headroom-chain.sh` launches with `--lossless`, which
> suppresses the injection and makes the downgrade unreachable on BOTH
> versions."

`bin/lib/hmd-headroom-chain.sh` itself documents the same wiring in its own
comments (re-read this session, its "WHAT HEADROOM_LOSSLESS=1 DOES ABOUT IT"
block):

> "proxy/server.py's `if config.lossless:` branch sets `config.ccr_inject_tool
> = False` (and `ccr_inject_marker = False`, `router_config.lossless`,
> `smart_crusher_lossless_only`) — identical wiring in both versions... and
> caching is untouched — the proxy still reports `mode: cache` and a healthy
> cache component with this set."

That comment is this repo's own prior conclusion, arrived at independently of
this task. This investigation re-derived the same conclusion from the source
directly rather than trusting the comment, and they agree.

**Live confirmation of which mode is actually running**, `GET /health`
(re-run this session, read-only, no body):

```json
"config": {"backend":"anthropic","optimize":true,"cache":true,"savings_profile":"coding",
  "anthropic_api_url":null, ...}
```

`"cache":true` and `savings_profile":"coding"` (== `proxy_mode="cache"`) on
the live process, matching the manifest's account of what's actually
deployed.

**Answer**: `--lossless` changes how already-emitted tool output gets
byte-shrunk before being cached-in-the-router-sense for CCR purposes; it does
not touch which bytes of a message are frozen, how a breakpoint is placed, or
whether a breakpoint survives to the provider. The frozen-prefix protection
runs regardless of `--lossless`. No restart or reconfiguration was needed to
answer this — the answer was already fully determined by the pinned source.

## Q2 — Is the cache actually working right now?

**Method**: mine Claude Code's own session transcripts
(`~/.claude/projects/-Users-rj-Downloads-heimdall/*.jsonl`), the same
structured-field approach `docs/analysis/2026-08-25-transcript-529-detection.md`
established for this repo (trust `message.usage`, a stable JSON field Claude
Code itself writes, over any text-level inference) and
`docs/analysis/token-spend-forensics.py` established for token accounting
(dedup by `message.id` — usage is reported cumulatively per streaming chunk,
so naive per-line summing overstates). A throwaway script
(`cache_check.py`, scratchpad-only, not part of this repo) mirrors that exact
method.

**Fresh run this session, against the live current-session transcript**
(the session that is writing this very document, currently 07:45Z+):

```
$ python3 cache_check.py ~/.claude/projects/-Users-rj-Downloads-heimdall/01313446-ae34-4e0c-9f91-4ef0bd66593c.jsonl 8
deduped usage-bearing assistant records: 1382
totals: input=143828 cache_read=614767324 cache_create=33211977 output=1113239
cache_read % of input-side (input+cache_read+cache_create): 94.85%
```

94.85% of this session's input-side tokens are cache reads. Tail of the same
run shows healthy incremental behavior, including one clean self-heal worth
calling out explicitly:

```
2026-08-25T07:38:07.978Z  in=76   cread=0        ccreate=275301 (1h=275301)  cache%=0.0
2026-08-25T07:38:26.792Z  in=2    cread=275301   ccreate=1011   (1h=1011)    cache%=99.6
```

At 07:38:07 a 1-hour-TTL breakpoint had expired (cold `cache_create`, 0
`cache_read`) — a normal event after any idle gap, not a fault. 19 seconds
later, the very next turn reads back exactly the 275,301 tokens just created.
This is the cache lifecycle working correctly, not a miss going unnoticed.

**Cross-checked against two other recent session transcripts** (subagent
sessions from the same 2026-08-25 working window, re-run fresh this session):

```
$ python3 cache_check.py .../4a3b1900-58e2-4ce4-8efc-4a951c4785c6.jsonl
cache_read % of input-side: 77.14%   (6 records — small-sample cold-start effect)
$ python3 cache_check.py .../affb6871-d3b4-428d-83e3-b8d031ae842a.jsonl
cache_read % of input-side: 94.58%   (16 records)
```

Both consistent with healthy caching; the lower figure is explained by sample
size (6 records, necessarily including at least one cold turn) rather than by
any sign of breakage.

**Cross-checked a third way**, against Headroom's own machine-wide lifetime
ledger (`~/.headroom/proxy_savings.json`, `lifetime_metrics.prefix_cache`,
59,375 requests spanning every repo/session on this machine, not just this
one — a different, wider denominator than the transcript measurement above,
so the two numbers are expected to differ and both are reported rather than
reconciled to one figure):

```
$ python3 -c "import json; print(json.dumps(json.load(open('/Users/rj/.headroom/proxy_savings.json'))['lifetime_metrics']['prefix_cache'], indent=2))"
{
  "requests": 59375, "hit_requests": 54299,
  "cache_read_tokens": 6071115299, "cache_write_tokens": 721761381,
  "uncached_input_tokens": 260826531,
  "bust_count": 1293, "bust_tokens": 100823362,
  "misses_by_reason": {"prefix_change": 716, "unknown": 3, "ttl_expiry": 4},
  "by_provider": {"anthropic": 59374, "openai": 1}
}
```

54,299 / 59,375 requests hit (91.4%). Token-level:
`6,071,115,299 / (6,071,115,299 + 721,761,381 + 260,826,531)` = 86.07% of
input-side tokens machine-wide (lower than this session's 94.85% because it
averages in every cold session start across the whole machine, not just one
long-running one). Bust rate `1293/59375` = 2.18%, down from 2.93% measured
2026-08-19 in `2026-08-19-headroom-compression-diagnosis.md` — the cache is
not degrading over time, it has mildly improved. **One honestly-reported
inconsistency, not resolved here**: `misses_by_reason`'s three counts sum to
723, not the `bust_count` of 1293 they're presumably meant to explain. This
looks like the same class of unreconciled internal telemetry noted in this
same ledger's `display_session` block (`cache_read_tokens` there has
previously been observed to exceed `total_input_tokens`) — flagged as
OBSERVED-but-unexplained rather than papered over, and not load-bearing for
the verdict since the primary evidence for Q2 is the transcript measurement
above, not this ledger.

**Answer**: yes, observably, right now, by three independent measurements
(this session's own transcript, two sibling sessions, and Headroom's own
ledger) that all land in the same healthy range.

## Q3 — What is Headroom actually saving today?

Same live ledger, re-read fresh this session:

```
$ python3 -c "
import json
d = json.load(open('/Users/rj/.headroom/proxy_savings.json'))
lt, tok = d['lifetime'], d['lifetime_metrics']['tokens']
print(lt['requests'], lt['compression_savings_usd'], lt['cache_savings_usd'])
print('compression saved tokens pct of input:', 100*tok['saved']/tok['input'])"
59375 70.206993 23671.901884
compression saved tokens pct of input: 0.346482746932668
```

Compression: $70.21 lifetime, 0.346% of input tokens. Caching: $23,671.90
lifetime, 86-95% hit rate depending on denominator (Q2). Ratio 337x. This is
squarely consistent with every prior measurement in this repo — 0.27%-0.56%
(2026-08-19, three independent methods), 0.331%/349.9x (2026-08-23) — the
number has not moved outside its established band across three separate
measurement dates spanning six days and roughly 16,000 additional requests.

**The risk side, measured live and read-only this session** (`GET /health`,
re-run fresh):

```json
"uptime_seconds": 64744.315,
"kompress": {"enabled":true,"ready":false,"status":"degraded","backend":null},
"compression_executor": {"leaked_threads_total":0,"quarantine_active":false,
  "timed_out_workers":0,"run_seconds_max":0.452,"in_flight":0}
```

Two things, both already documented in this repo and both reconfirmed live
today rather than re-litigated:

- The kompress health-reporting bug from
  `2026-08-19-headroom-compression-diagnosis.md` §7
  (`_reconcile_kompress_health()`, `server.py:2767`) is **still present,
  unfixed, on this exact live process**: `/health` reports
  `backend: null` / `status: degraded` for kompress while the proxy is
  actively compressing traffic successfully (the `$70.21` above did not
  compress itself). A cosmetic-but-real observability defect, not a
  functional one.
- The leak/quarantine/cascade defect from the same doc's §5 is **not
  currently active** (`leaked_threads_total: 0`, `quarantine_active: false`,
  `run_seconds_max` 0.45s against a previously-measured worst case of
  64.75s). That defect is load-triggered and intermittent by its own prior
  description, not continuously present — this snapshot shows the proxy
  healthy at this instant, not that the defect was fixed. No claim either way
  beyond what this instant's reading shows.

**Answer**: compression is real but small (≈0.35% of tokens, ≈$70 lifetime);
caching is the thing actually saving money (≈86-95% hit rate, ≈$23,672
lifetime); and the proxy carries a live, reconfirmed observability bug plus a
dormant-but-documented reliability defect while sitting directly in the path
of every request. The benefit is genuinely small next to what's riding on top
of it.

## Q4 — Would chaining OmniRoute behind Headroom be safe?

Proposed chain: `Claude Code -> Headroom (8787) -> OmniRoute (20128) ->
provider`, for "token efficiency + fallback."

**Is it wired today?** No — confirmed live, read-only, this session
(`GET /health`):

```json
"upstream": {"enabled":true,"ready":true,"status":"healthy","url":"https://api.anthropic.com"},
"config": {"anthropic_api_url":null, "openai_api_url":null, ...}
```

Headroom's upstream is the real Anthropic API right now, not OmniRoute. This
is a single hop today, not a chain.

**Could it be wired?** Mechanically, yes — `headroom/proxy/models.py:136`
(re-read this session) exposes exactly the seam needed:

```python
anthropic_api_url: str | None = None  # Custom Anthropic API URL override
```

and the prior sibling investigation
(`docs/analysis/2026-08-25-omniroute-fallback-transport.md`) already
confirmed OmniRoute presents an Anthropic-Messages-API-compatible ingress
(that's the mechanism by which Claude Code itself, an Anthropic-API-only
client, can be pointed at it via `ANTHROPIC_BASE_URL` at all). So the chain
is buildable: point Headroom's `anthropic_api_url` (or
`HEADROOM_ANTHROPIC_API_URL`) at `http://localhost:20128` instead of
`https://api.anthropic.com`. **This mechanical possibility was not tested**
— doing so would mean reconfiguring the live proxy, which the brief
explicitly forbids. INFERRED from config schema + the sibling doc's finding,
not observed in a live test.

**Should it be wired?** No, and this doesn't require touching anything to
answer — the two same-day OmniRoute investigations already did the
measurement work, and their findings compose badly with each other and with
Q1-Q3 above:

1. **`cache_control` gets destroyed one hop later, for nothing.**
   `2026-08-25-omniroute-fallback-transport.md` §2b found that OmniRoute's
   Claude→OpenAI translator only preserves `cache_control` when a
   provider-credential entry sets `_preserveCacheControl === true`, and
   neither Mistral's nor LLM7's registry entry (the two backends actually in
   use) sets it — structural, not a bug OmniRoute could patch, since OpenAI's
   own request schema has no `cache_control` concept at all. Q1 above
   establishes that Headroom carefully preserves `cache_control` all the way
   through its own hop. Chaining OmniRoute behind it means that careful
   preservation buys nothing: the breakpoint survives Headroom only to be
   thrown away at the very next hop, before either real backend ever sees
   it.
2. **The efficiency goal is doubly unreachable.** Q3 already shows
   Headroom's own compression contributes ≈0.35% of tokens — not enough to
   justify a second proxy hop on its own. Behind OmniRoute the picture gets
   worse, not better: Mistral and LLM7 are not Anthropic, so there is no
   Anthropic-style prompt cache on the far side of that hop to protect in
   the first place, and the finding above just showed the one thing
   Headroom does protect gets stripped before arrival regardless. There is
   no efficiency case being made stronger by this chain; every measured
   number argues the other way.
3. **Second-hop failure modes compound, they don't cancel.** Two independent
   sets of already-documented reliability and data-handling risk would sit
   in series in the same live request path: Headroom's own reconfirmed
   kompress health-reporting bug and load-triggered
   leak/quarantine/cascade defect (Q3), plus OmniRoute's own
   unremovable Tier-1 OAuth-subscription-reuse finding
   (`2026-08-25-omniroute-fallback-transport.md` §4a — "NOT FOUND", an
   explicit blocking finding) and its failure to clear this repo's
   ZDR-equivalent bar for either Mistral or LLM7 (§4b/4c). Chaining does not
   average these risks, it adds a second, independent point of failure and a
   second, independent data-handling exposure in front of the same live
   session this brief was written to protect.

A recommendation against the chain is what the evidence supports here, not a
default assumed going in — the brief asked for exactly this if that's what
the numbers said, and this is what they said.

## Proxy safety confirmation

PID, uptime, and version were checked before writing any live-observation
number above and are unchanged from the values already on record earlier in
this same investigation session:

```
$ ps -p 6404 -o pid,ppid,etime,command
 6404     1 17:57:50 /Users/rj/.local/share/uv/tools/headroom-ai/bin/python3 /Users/rj/.local/bin/headroom proxy --host 127.0.0.1 --port 8787 --lossless
```

Same PID (6404), same parent (1, i.e. never re-parented by a restart), same
command line, monotonically increasing uptime throughout this session. The
only traffic sent to it directly by this investigation was two `GET` requests
to its own `/health` and `/livez` endpoints — no POST, no config change, no
signal. It was never in any state other than "already running, serving the
operator's real traffic" for the entire duration of this task.
