# Should hmd fork Headroom to make it work better with hmd?

Date: 2026-08-19 · Status: design assessment (analysis only — nothing implemented, nothing forked) · Author: architect agent, this session

**Verdict: NO. Do not fork.** Every legitimate improvement this investigation could find is better captured by (in order) a config change hmd already controls, a small hmd-side change to `bin/lib/hmd-headroom-chain.sh`, or a narrowly-scoped upstream PR — and the one item that would justify real engineering (the synchronous-kompress-path cascade, upstream #1171) is **already being built by upstream right now**, unreleased but on `main`, at a release cadence (0.33.0→0.34.0→0.35.0, 7 days apart each) that makes "wait" cheaper than "fork and reconcile." The headline number the user's idea has to clear — compressing the cached prefix to chase 31% everywhere — is not reachable by a fork at all; it is barred by an architectural decision this codebase's own numbers say is correct. See §0.

This document does not decompose into implementation waves and carries no Oracle-Gate wiring, because the deliverable the user asked for is the analysis itself — "implement nothing, fork nothing." §4 below lists the follow-up actions (two upstream issues, one hmd-side config experiment, one hmd-side code change) as candidates for a *future* planning cycle if RJ wants to act on them; none is authorized by this document.

This builds on, and does not re-derive, `docs/analysis/2026-08-19-headroom-compression-diagnosis.md` (the 543-line local forensics), `docs/analysis/headroom-did-it-help.md` §6 (live-proxy evidence + dated self-corrections), and `docs/analysis/token-spend-forensics.md` (the $1,103/234-session cost study). Every number in §§0–2 is either quoted from those three documents or freshly measured in this session against the installed source and upstream's public repo — each fresh measurement is marked **[NEW]** with the command that produced it.

---

## 0. The hard constraint, answered first, because it decides everything else

**No fork reaches 31% compression in aggregate, and the shortfall is not a bug a fork could fix.** Three independent, deliberate protective layers stand between "the frozen prefix" and any compressor, all present in the *installed* source read for this assessment:

- `compute_frozen_count` (`headroom/cache/compression_cache.py:252-289`) computes how many leading messages are already anchored in the provider's prompt cache and refuses to touch them — the trailing message is excluded from the frozen prefix by construction, because it was never sent upstream and cannot be in any provider cache.
- `_restore_frozen_prefix` (`headroom/proxy/handlers/anthropic.py:322-345`, quoted in full in the diagnosis doc) force-overwrites, byte-for-byte and index-by-index, any part of the frozen region a compressor did touch, before the request leaves the proxy.
- `_strict_previous_turn_frozen_count`, combined via `min()` with the above at the call site, is a *more* conservative third policy that freezes all prior turns and leaves only the final turn mutable.

At this machine's measured 95.56% cache-read rate, roughly 95% of input tokens are structurally exempt from compression by these three layers acting together. The result, converged on three independent ways in the diagnosis doc (per-event ledger summed by hand, headroom's own lifetime counter, the proxy's own printed session report): **aggregate compression across 19,168 real events is 0.5583%**, and across headroom's full 43,703-request lifetime ledger it is **0.271%**. Only **4 of 19,168 events (0.021%)** ever reach ≥31%, and all four are cold starts with no frozen prefix to protect yet. The 31% figure is real — it is what both compressors (`diff_compressor` at 0.6862 ratio once, `kompress` at 31.24% averaged over 1,181 recovered events) actually achieve *on the sliver of content they are permitted to touch*. It was never a rate the architecture is failing to reach 99.4% of the time; it is the yield on a deliberately tiny live zone.

**The dollar reason the architecture is built this way**: headroom's own lifetime ledger, this machine, `~/.headroom/proxy_savings.json.lifetime`:

```json
{"compression_savings_usd": 42.898918, "cache_savings_usd": 17360.715489}
```

Cache saves **405× more than compression** (17360.715489 / 42.898918 = 404.68). Reaching toward 31% in aggregate would mean compressing inside the frozen prefix — which is exactly the trade this ratio says is catastrophic. `token-spend-forensics.md` independently corroborates from the billing side: this workload's cache-read rate is 95.56%, genuinely-uncached input is 0.0023% of all tokens, and the same document explicitly modeled shortening the cache TTL (a much smaller cache-disturbing change than compressing the frozen prefix) and found it would cost **~$590 more**, not less.

**No `HEADROOM_*` env var, and no fork of the compression code, moves this boundary without also widening cache-bust exposure** — the boundary isn't a knob, it's the frozen-prefix invariant itself. A fork that compressed the cached region to chase 31% would be trading $17,360.72/12-days of proven, working savings against, at absolute best, an additional few dollars of compression yield — a trade this workload's own numbers already answer.

**What a fork legitimately *could* still be worth building is a different, much smaller question: not "compress more," but "stop the compression subsystem from occasionally costing latency/reliability for ~zero benefit."** That is what §1 evaluates, on its own economic terms — none of it moves the 31% ceiling, and none of it should be read as walking back this section.

---

## 1. Where a fork could add value, scored against measured evidence

### 1a. Cache-mode background compression — real, bounded, but there's a cheaper path to the same effect

`HEADROOM_BACKGROUND_COMPRESSION`'s only call site sits inside `if is_token_mode(self.config.mode):` in `headroom/proxy/handlers/anthropic.py`. **[NEW, verified this session]** — the exact gate, `headroom/proxy/handlers/anthropic.py:1413-1419` (installed 0.35.0):

```python
if (
    getattr(self, "_background_compression_enabled", False)
    and frozen_message_count == 0
    and original_tokens >= self._background_compression_min_tokens
):
    accepted = self._background_compressor.enqueue(...)
```

That whole block sits under `if is_token_mode(self.config.mode):` (`anthropic.py:1381`), and hmd's default profile is `proxy_mode="cache"` (`agent_savings.py`'s `DEFAULT_PROFILE = "coding"`, confirmed live in `hmd-headroom-chain.sh`'s own comment: "hmd launches with no `--mode` flag... CACHE mode... applies"). **So this escape hatch is entirely inert for hmd's real traffic today** — matches the task brief's framing exactly.

What it would prevent, measured on this machine (`docs/analysis/headroom-did-it-help.md` §6, `/health` snapshot): **23 deadline events, 10 leaked threads, 10 quarantine activations, 48 requests forwarded uncompressed** (`quarantine_skips_total: 48`) over the observed window.

**But the precise condition that triggers deferral — `frozen_message_count == 0`, i.e. a true cold start with nothing cached yet — means the fix, if made, carries almost none of the cache-corruption risk §0 warns about.** At `frozen_message_count == 0` there is no frozen prefix to violate; deferring compression at that exact moment cannot bust a cache that doesn't exist yet. This is the one place in the whole compression subsystem where "defer more aggressively" and "protect the cache" are not in tension.

That makes this a genuinely good, narrowly-scoped **upstream PR candidate**, not a fork candidate: mirror the existing `anthropic.py:1413-1419` block at whatever the cache-mode delta call site is (the file's own comment names "all three `pipeline.apply` call sites (token / non-cache / cache-delta)" — the fix touches the third), reusing the already-built, already-tested `BackgroundCompressor` class and `HEADROOM_BACKGROUND_COMPRESSION_MIN_TOKENS` knob unchanged. Estimated surface: ~30-40 lines in one file, no new abstractions — smaller than most entries in upstream's own CHANGELOG's `### Fixed` section.

**A genuinely zero-cost, zero-code experiment is also available today, this machine, right now**, and is worth running before either a PR or a fork: **[NEW, verified this session]** — `HEADROOM_KOMPRESS_MAX_TOKENS` already exists in the *installed* 0.35.0 source (not just in Unreleased), defaulting to 50,000 (`headroom/transforms/content_router.py:1839-1843`), and the diagnosis doc measured it never fires (`grep -c "size-gate" ...` → 0 across all six log files). Lowering this env var (e.g. to 10,000–20,000) via `HEADROOM_COMPRESSION_TIMEOUT_SECONDS`'s own precedent in `hmd-headroom-chain.sh` — one more env var scoped to the one child process — would keep more of hmd's oversized cold-start content off the synchronous ML path *without any code change on either side*. This has not been tried; it is not proven to help; it is cheap enough that it should be tried before anything else in this section.

**Addendum, 2026-08-19 (same day, follow-up implementation session): tried.** `HEADROOM_KOMPRESS_MAX_TOKENS` is now set in `bin/lib/hmd-headroom-chain.sh`, scoped to the proxy child process exactly as proposed above. Chose **10,000** — the low end of the floated range — grounded in fresh measurement rather than the floated guess:

- The 1,181 kompress events this proxy has ever recovered via CCR (the same population behind the 31.24% figure above) top out at **2,464 tokens** (p99.9; mean 448.8, p99 1,963) — measured from `~/.headroom/logs/proxy.log*`'s `headroom_retrieve` events, `original_tokens` field.
- The broader, unfiltered population of every raw kompress ONNX invocation ever logged on this machine (775 calls, `"Kompress slow compress"` lines) tops out at **5,090 words** — a different unit than the gate's own `_estimate_tokens`, but the same order of magnitude.
- 10,000 is therefore roughly 2x the single largest real value ever observed under either measure — it costs nothing measured (all 1,181 events, 100% of the $42.90 lifetime compression savings, stay exactly as fast as today) while shrinking the no-man's-land between real traffic and the reconstructed cascade five-fold (50,000 → 10,000). There is no evidence-based reason to pick anything between 10,000 and 50,000 instead: nothing legitimate has ever lived in that range, so every value in it is equally safe for preserving today's savings, and only the low end adds real protective margin.
- Honest limit, found while gathering this evidence and not previously reported anywhere in this document: **kompress inference latency does not scale cleanly with block size on this machine.** The slowest ONNX calls in the full log history include a 47-word call at 15,736ms and a 31-word call at 11,534ms — both slower than several 800+-word calls. This means the size-gate mitigates exactly the large-single-block O(tokens) failure mode #1171 names, and it does **not** address a second, apparently contention- or model-load-driven latency source that already affects small blocks today. That second source is a distinct, unresolved mechanism, out of scope for this change.
- Test coverage: `test/headroom-wrap-chain.test.sh` guarantees 6-8 (hermetic, no network/ML/real proxy), falsified in both directions — reverting the default fallback reds guarantee 6 only; hardcoding the value so it ignores a caller override reds guarantee 7 only; every other guarantee, both vars, stays green in both cases.

This does not change the verdict above (still NO on forking) or the 31%-ceiling analysis in §0 — it is the one item §3 already flagged as "cheapest possible next step," now done.

### 1b. The synchronous kompress path for large cold-start contexts — already in progress upstream, do not fork it

**[NEW, verified this session]** — fetched `https://raw.githubusercontent.com/chopratejas/headroom/main/CHANGELOG.md` (2,266 lines) directly. The fix the task brief names is real and is sitting under the file's own `## Unreleased` header (line 9; the first version header, `## [0.35.0]`, the installed pin, is at line 287 — everything between is genuinely unreleased):

> "**proxy/transforms:** take large cold-start contexts off the synchronous kompress path — the root cause behind the `compression_first_stage` 30s-timeout + leaked-thread → executor-saturation cascade ([#1171](.../issues/1171)). A token size-gate inside the ML boundary routes oversized text away from ModernBERT (`HEADROOM_KOMPRESS_MAX_TOKENS`); a cooperative chunk-deadline bounds any kompress run that does proceed (`HEADROOM_COMPRESSION_DEADLINE_MS`); an opt-in off-path mode forwards uncompressed immediately and compresses in a single per-process background drain so the request never blocks on ML (`HEADROOM_BACKGROUND_COMPRESSION`); and a new native `TextCrusher`... All default off and fail-open."

This is exactly the diagnosis doc's §5 cascade (`hr_1787057836_004181`, 8.95MB / 727 messages / 24.5s pipeline time / one concurrent request collaterally failed), named by its own issue number, being fixed by the maintainer at this moment.

**Upstream's own release cadence**, measured **[NEW]** from the fetched CHANGELOG's own version headers: 0.33.0 (2026-07-29) → 0.34.0 (2026-08-05, 7 days) → 0.35.0 (2026-08-12, 7 days). Weekly. If that cadence holds, this fix ships within roughly one to two more release cycles of today (2026-08-19) — i.e. plausibly before a fork could even be scoped, branched, and validated against hmd's own test suite.

Forking to carry this now means: (a) re-implementing a change upstream is actively finishing on `main` right now — pure duplicated effort; (b) reconciling a merge the moment upstream actually ships it, which for a 202,599-line Python package (§3) is not free; and (c) carrying a diverged copy of the compression pipeline for however many weeks in between, accumulating drift on every other file upstream touches in parallel (§3 measures ~13 commits/day recently). **Recommendation: wait for the release, or — only if the cascade is actively hurting a session before then — apply the specific upstream commit(s) for #1171 as a small local patch once they land on `main` (not yet merged as of this measurement), not a fork of the repo.** A patch-on-top-of-a-pinned-release is a materially smaller commitment than a fork: it touches the files the fix touches, not the 202k-line surface a fork inherits responsibility for.

### 1c. Cross-session blast radius — the worst case is already capped upstream; the residual risk is hmd's own, and hmd can fix it without touching Headroom's code at all

The diagnosis doc's §5 reconstructed a ~10.8-second quarantine window (18:27:46.691 → 18:27:57.505) during which a wholly unrelated, concurrent request failed collaterally (`CompressionQuarantinedError`). **[NEW, verified this session]** — `hmd-headroom-chain.sh`'s own comment (lines 178-183, read in full for this assessment) already states that upstream 0.35.0 (the installed pin) ships `HEADROOM_COMPRESSION_QUARANTINE_MAX_SECONDS` (default 60s, upstream #2360) specifically to cap this: "bounds how long a leaked worker can block new compression for OTHER sessions." That fix is **already live on this machine's exact pin**, no action needed — the diagnosis doc's own 10.8s measurement is already below the current 60s cap, and the cap itself is what prevents a *worse* future cascade from being unbounded.

What is **not** capped by anything upstream ships is that `hmd_headroom_chain()`'s own reuse logic (`bin/lib/hmd-headroom-chain.sh:144-150`) reuses whatever proxy is "ALREADY LIVE" on the configured port with no per-repo distinction — so **one proxy process, and therefore one shared compression executor and one shared quarantine state, is common to every one of hmd's wrapped repos on a machine** (the task brief names 4). That is an hmd architecture choice, not a Headroom defect, and it is fixable entirely on hmd's side: derive a per-repo default port (e.g. a hash of the repo path, or an explicit `HEADROOM_PORT` set per-repo in each repo's own `.heimdall/` config) in `hmd_headroom_port()`. Zero Headroom code touched, zero fork. This is a genuine follow-up candidate but belongs in a future PLAN, not this one (see the note at the top of §4).

### 1d. Two candidate upstream defects — one confirmed genuinely unreported, one whose stated mechanism this session found and corrected

**`httpx.ReadError` — confirmed genuinely unreported. [NEW, verified this session]**: the installed source's `request_with_transient_retry` (`headroom/proxy/helpers.py:1241-1271`) retries only `httpx.RemoteProtocolError`, added by upstream PR #1513 (merged 2026-07-06, closes #1112), whose own description states the scope deliberately: *"issues a buffered httpx request and retries on a fresh connection when (and only when) `httpx.RemoteProtocolError` is raised. Every other exception... propagates immediately."* A GitHub search of the upstream repo for `ReadError` across all issues (`api.github.com/search/issues?q=repo:headroomlabs-ai/headroom+ReadError`) returns exactly **one** result, and it is unrelated (#1639, an HTTP/2 stream-reset issue, closed). The diagnosis doc's own local evidence — 53 `error|exception|traceback|timeout|leaked|quarantine|retry|failed` matches in the 12-day proxy log, including repeated `httpx.ReadError`/`httpcore.ReadError` frames from this exact function — is real production signal that PR #1513's scope decision (retry the "peer closed a pooled connection" case, not the "peer reset mid-read" case) may have been narrower than the failure modes actually seen in the wild. Worth filing as an issue/small PR mirroring #1513's own precedent; **not** a fork candidate — it is a ~10-20 line, single-function change.

**`/stats` latency — the diagnosis doc's own candidate mechanism does not hold up, and this session found and corrected the actual one.** The task brief named `_reconcile_kompress_health()` as the suspected cause of the measured 10.19s `/stats` call (vs 16.5ms `/livez`, same process, moments apart). **[NEW, verified this session]**: `grep -n "_reconcile_kompress_health" headroom/proxy/server.py` shows it is called from exactly three places — the `/health`/`/readyz` handler (`_health_checks`, line 2814) and `/debug/warmup` (line 3481) — **never from `/stats`**. The `/stats` handler (`server.py:4339`, `async def stats`) calls `_build_stats_payload()`, whose own body (read in full, `server.py:3792-3912`) does this on a cache-miss:

```python
async with _throughput_cache_lock:
    if _throughput_cache["expires_at"] < now or _throughput_cache["value"] is None:
        def _compute_throughput():
            from headroom.perf.analyzer import build_perf_summary, parse_log_files
            perf_report = parse_log_files(last_n_hours=1.0)
            return build_perf_summary(perf_report).get("throughput")
        throughput = await asyncio.to_thread(_compute_throughput)
```

**The actual candidate mechanism is `parse_log_files(last_n_hours=1.0)`** — parsing a full hour of proxy log files synchronously inside a thread, on every `/stats` call that misses `_throughput_cache`'s TTL. This is offloaded via `asyncio.to_thread` so it does not block the event loop for *other* requests, but it fully explains a slow single call without implicating `_reconcile_kompress_health` at all. A GitHub search for `parse_log_files` / `/stats` throughput slowness (`api.github.com/search/issues?q=repo:headroomlabs-ai/headroom+parse_log_files...`) returns 5 results, none matching this mechanism — genuinely unreported, but **low value**: it costs one dashboard poll's latency (bounded by `THROUGHPUT_CACHE_TTL_SECONDS` between misses), not a request in the generation path. Worth a low-priority upstream issue; not worth engineering time here, fork or otherwise.

---

## 2. Maintenance cost of carrying a fork — measured, not estimated

**[NEW, all four figures measured this session]**:

| Metric | Value | Command |
|---|---|---|
| Package size | **202,599 lines of Python** (`headroom/` tree only, installed 0.35.0) | `find .../headroom -name "*.py" \| xargs wc -l \| tail -1` |
| Total commits, all history | **2,629** | `curl .../commits?per_page=1` → `Link:` header `last=2629` |
| Commits, last 18 days (2026-08-01→19) | **237** (≈13/day) | `api.github.com/search/commits?q=repo:...+committer-date:>2026-08-01` |
| Release cadence | **~7 days** between 0.33.0→0.34.0→0.35.0 | CHANGELOG version headers, dated |
| Stars / open issues | **66,800 / 488** | `api.github.com/repos/headroomlabs-ai/headroom` |
| Issue-to-close latency, recent sample (n=15) | mostly **0.2–3.4 days**, two outliers at 10.5 and ~35–63 days | `api.github.com/search/issues?...is:closed&sort=updated` on 15 most-recently-touched closed issues |

A fork frozen at 0.35.0 diverges from a project shipping roughly 13 commits/day. Every one of those commits is a candidate for a fix hmd's fork would need someone to notice, evaluate, and manually backport — including safety-relevant ones already shipped upstream in just the last two release cycles that a fork made *before* 0.35.0 would have missed entirely without active tracking: the ONNX-thread-pool 100%-CPU-core bug (#2495, fixed by #2540), a macOS RSS-ratchet-to-~11GB memory bug (#2820, "verified fix + patch included"), and a `TrafficLearner` pending-pattern memory leak (#2579). None of these is hypothetical or old — all three are visible in the same CHANGELOG window this assessment already fetched.

There is no plausible "fork just the compression subsystem, ignore the rest" strategy either: `compression_cache.py`, `anthropic.py`'s request handler, `content_router.py`, and `kompress_compressor.py` are the files carrying the exact cache-protection logic §0 depends on being correct — a fork that touches compression necessarily inherits an ongoing obligation to track upstream's own compression-adjacent fixes (issue #2085's `PrefixCacheTracker` cross-contamination fix, shipped in the Unreleased section fetched above, is a second, independent example of exactly the failure class §0 is protecting against, being actively hardened by the people who wrote the freeze logic in the first place).

**Bottom line: the entire lifetime value a fork could plausibly ever capture from the compression subsystem — $42.90 (§0) — is dramatically smaller than the standing cost of tracking a 13-commits/day, 202,599-line dependency indefinitely.** This is true even before weighing the risk of a fork silently missing a real security or correctness fix (the loopback-guard / cache-race security patch visible near the bottom of the fetched CHANGELOG is exactly the class of fix a stale fork would miss without an active, ongoing tracking discipline nobody has proposed building here).

**If tracking upstream is needed at all** — and given the NO verdict, the only tracking this assessment actually recommends is lightweight and time-bounded, not an ongoing fork-maintenance discipline:

- For §1b (#1171, the one item worth waiting on): poll `https://github.com/chopratejas/headroom/issues/1171` for its close event, or diff `CHANGELOG.md`'s `## Unreleased` section against the pinned version's own header (`modules/headroom/manifest.json`'s `pinned_version`) at each `hmd modules add headroom` / periodic re-check — the moment `HEADROOM_KOMPRESS_MAX_TOKENS`'s in-ML-boundary variant, `HEADROOM_COMPRESSION_DEADLINE_MS`, and `TextCrusher` move from `## Unreleased` to a version header, the fix has shipped and the manifest's pin should move.
- For §1a/§1d (the two candidate PRs): a filed issue needs no ongoing tracking beyond normal GitHub notification — file it, wait for the maintainer (median close time in the 15-issue sample was under 3.5 days, §2 table), re-evaluate only if it's rejected as out-of-scope.
- **No standing "watch every commit" discipline is proposed or needed**, because nothing here recommends forking any part of the 202,599-line tree. That discipline would only become necessary if a future decision reverses this verdict — which this document does not recommend.

---

## 3. Ranked alternatives and recommendation

1. **Do nothing, for the 31% question — it is not reachable and forking cannot change that (§0).** No item below moves this number; none should be read as walking it back.
2. **Zero-cost, zero-code experiment, today: lower `HEADROOM_KOMPRESS_MAX_TOKENS`** (currently 50,000, confirmed never firing) via the same env-scoping precedent `hmd-headroom-chain.sh` already uses for `HEADROOM_COMPRESSION_TIMEOUT_SECONDS`. Untried, unproven, cheapest possible next step.
3. **Wait for upstream #1171 to ship** (§1b) — actively being finished on `main`, ~7-day release cadence, directly named as the root cause of the cascade this investigation independently reconstructed. If urgency demands acting sooner, apply the specific landed commit(s) as a small local patch once merged — not a fork.
4. **hmd-side code change (future planning cycle, not this document): per-repo `HEADROOM_PORT` derivation** in `bin/lib/hmd-headroom-chain.sh` to eliminate the residual cross-repo blast radius (§1c). Touches zero Headroom code.
5. **File two small upstream issues/PRs**: (a) extend the `HEADROOM_BACKGROUND_COMPRESSION` frozen==0 gate to the cache-mode call site (§1a) — small, safe by construction (nothing is frozen yet at that gate), matches the existing `BackgroundCompressor` machinery; (b) retry `httpx.ReadError` in `request_with_transient_retry` (§1d), mirroring the already-merged, already-accepted precedent of PR #1513.
6. **File one low-priority upstream issue**: `/stats` throughput cache-miss latency via `parse_log_files(last_n_hours=1.0)` (§1d, corrected mechanism) — diagnostic-only value, not urgent.
7. **Fork: not recommended.** Every value-bearing item above is served better and cheaper by 2–6. The one item large enough to matter (#1171) is already in progress upstream; forking it means redoing work already underway and then paying a merge-reconciliation cost against a 202,599-line, ~13-commits/day dependency (§2) for the rest of this fork's life.

None of items 2–6 is authorized to execute by this document — this is analysis only, per the task's explicit scope. If RJ wants to act on any of them, each is small enough to be its own short PLAN.

---

## 4. What no fork can fix, restated precisely

- **The 31%-everywhere ceiling.** `compute_frozen_count`, `_restore_frozen_prefix`, and `_strict_previous_turn_frozen_count` are deliberate, and the 405× cache-vs-compression dollar ratio (§0) says they are *correctly* deliberate for this workload. A fork that widened the live zone to chase 31% would be trading $17,360.72/12-days of measured, working cache savings for, at the theoretical best case (every byte in the widened zone compressing at kompress's own observed 31.24% average), a few additional dollars of compression yield — net negative on every plausible sizing.
- **The frozen-prefix protection is not a bug with a patch; it is the correct resolution of a real tension**, and headroom's own CHANGELOG shows the maintainers actively hardening it further (the `PrefixCacheTracker` lineage-splitting fix for #2085, fetched and quoted in §2) — a fork attempting to loosen this exact mechanism would be diverging in the opposite direction from where upstream is investing its own engineering effort.
- **No env var reaches this boundary either** — `hmd-headroom-chain.sh`'s own comment already establishes this for `HEADROOM_BACKGROUND_COMPRESSION` (a no-op in cache mode); the same is true of every other `HEADROOM_*` knob this assessment found: none relaxes `compute_frozen_count`'s positional guarantee, because relaxing it is precisely what issue #327 (cited in the diagnosis doc, already fixed once) and #2085 (cited here, fetched from the live CHANGELOG) show going wrong when it's tried.

---

## OUT OF SCOPE

- No code changes, config changes, or upstream filings were made by this document — analysis only, per the task's explicit instruction.
- No fork was created, and nothing under `/Users/rj/.local/share/uv/tools/` was modified.
- `modules/headroom/manifest.json` was read but not edited (a sibling agent owns concurrent edits to it this session).
- The per-repo port change (§1c), the two upstream PRs (§1a, §1d), and the `HEADROOM_KOMPRESS_MAX_TOKENS` experiment (§3.2) are named as candidates only — none is planned, scheduled, or executed here. Each would need its own short PLAN if RJ chooses to act on it.
- This document does not re-litigate `docs/analysis/2026-08-19-headroom-compression-diagnosis.md`'s own findings; it cites them and extends only into fork-viability questions that document did not ask.

---

## Provenance

Read, not modified: `docs/analysis/2026-08-19-headroom-compression-diagnosis.md`, `docs/analysis/headroom-did-it-help.md`, `docs/analysis/token-spend-forensics.md`, `bin/lib/hmd-headroom-chain.sh`, `bin/heimdall-wrap` (grepped, not edited), `modules/headroom/manifest.json` (read-only — a sibling agent owns it this session), and, read-only, the installed `headroom-ai==0.35.0` source at `/Users/rj/.local/share/uv/tools/headroom-ai/lib/python3.13/site-packages/headroom/` (`proxy/handlers/anthropic.py`, `proxy/server.py`, `proxy/background_compression.py`, `proxy/helpers.py`, `proxy/modes.py`, `transforms/content_router.py`, `cache/compression_cache.py`). Network reads only, against `raw.githubusercontent.com` and `api.github.com` for the upstream CHANGELOG and issue/commit history — no write access, no auth token used, all public data.

Every figure marked **[NEW]** above was produced fresh in this session; every unmarked figure is quoted verbatim from the three source analysis documents. `uv tool list` was run read-only to confirm the installed version (`headroom-ai v0.35.0`) matches the pin the source citations above were read against.
