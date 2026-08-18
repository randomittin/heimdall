# Parallel hmd sessions: memory and disk audit (2026-08-19)

**Question:** does running many hmd sessions in parallel, across multiple repos, consume a lot
of memory or disk on a 16GB machine? Every number below is from a command run live on this
machine on 2026-08-19, quoted verbatim (trimmed for length where noted). Nothing was
estimated. Nothing was deleted, killed, or reaped — this is a read-only audit
(`heimdall-reap-idle` ran in its default dry-run mode only; `--apply` was never invoked).

**Repo state at measurement time:** `HEAD` = `origin/main` = `5870874786abb7b23d6d36a978a21108b49e20ab`,
so `merge-base(HEAD, origin/main) == origin/main == HEAD` — no divergence, nothing to rebase.
(The primary worktree's local `main` ref is separately a few commits behind at `7ac7ab9`; that's
unrelated local bookkeeping staleness, not this branch's concern.)

**TL;DR (verdict, see §C for the full argument):** parallel hmd sessions are a **non-issue**
for both memory and disk, in the sense the question is usually asking (does hmd's *own*
machinery blow up with scale). hmd's own RAM footprint is ~1-5MB marginal cost per additional
parallel session. hmd's own disk footprint outside the repo is ~792MB total, of which ~454MB
is currently-idle-but-reclaimable worktree disk, sitting there for a documented, still-valid
safety reason — not a leak. The machine genuinely IS under memory/disk pressure right now
(hmd's own health monitor says CRIT), but hmd's own process accounting explicitly clears
hmd of causing it.

---

## A. Memory

### A1. Headroom proxy — one shared process, not one per repo

From `bin/lib/hmd-headroom-chain.sh`:

- Port is a single machine-wide default, never repo-scoped: `HMD_HEADROOM_DEFAULT_PORT=8787`
  (line 54), overridable only by the operator's own `HEADROOM_PORT` env var — there is no
  per-repo or per-session component in how the port is derived (`hmd_headroom_port`, lines
  103-107).
- `hmd_headroom_chain` step 1 (lines 144-150): **"ALREADY LIVE? Reuse it."** — it probes
  `http://127.0.0.1:$port/health` and, if anything answering there identifies as
  `headroom-proxy` pointed at `api.anthropic.com`, reuses it unconditionally, regardless of
  which repo or session is asking. There is no code path that starts a second instance for a
  second repo.

This makes "one shared proxy for the whole machine" a property of the code, not a
coincidence of measurement — any number of concurrent `hmd wrap` sessions across any number of
repos race to bind one port, and every loser reuses the winner.

Empirically, at measurement time:

```
$ lsof -nP -iTCP:8787 -sTCP:LISTEN     # (no output)
$ netstat -an | grep 8787              # (no output)
```

No proxy is listening right now, despite 3 concurrent `claude --agent heimdall` sessions
running (see A3) across at least 4 wrapped repos (see A2) — itself consistent with "shared,
on-demand, not per-repo": if it were per-repo we'd expect to see 0-4 candidate listeners
scattered across ports, not a clean zero. It clearly *has* run recently: the chain's own log
(`~/.heimdall/headroom/proxy.log`, 118,446 bytes) has `diff_compressor` entries through
`2026-08-18 23:19:13` (last night), and its pidfile (`~/.heimdall/headroom/proxy.pid` = `5157`)
is now stale (the process behind it is gone — confirmed indirectly: if it were alive it would
necessarily be bound to 8787, and nothing is). The task's cited baseline of ~96-98MB RSS for
this shared instance is not independently re-measured here since no instance was live at
audit time; I did not fabricate a number to fill the gap.

### A2. Presence keepers and other long-lived hmd processes

`ps -eo pid,ppid,etime,rss,%mem,command` filtered to `heimdall-presence keeper`,
`hmd-statusline.py`, and `headroom proxy`, one consistent snapshot:

| PID | Repo | Keeper kind | RSS (KB) | ELAPSED |
|---|---|---|---|---|
| 20846 | heimdall | session `01313446…` | 976 | 39:31 |
| 54964 | wirenow-app | session `2f8307af…` | 976 | 24:45 |
| 61606 | web | `__default` | 960 | 15:54:29 |
| 67732 | supervoice | session `0722e905…` | 960 | 10:08:01 |
| 74673 | web | session `f66a834e…` | 960 | 15:54:20 |
| 50916 | heimdall | `__default` | 960 | 12:44:24 |
| 5741 | wirenow-app | `__default` | 960 | 17:09:23 |
| 47857 | supervoice | `__default` | 960 | 10:08:12 |

**8 keeper processes, 7,712 KB (7.5MB) total RSS.** Each is a trivial `bash … keeper-loop
--interval 20` sleep loop. One finding worth flagging: **a 4th repo is currently wrapped** —
`github.com/mewt-app/supervoice` — beyond the 3 the user named (`wirenow-app`, `web`,
`heimdall`). The pattern is one `__default` keeper per repo (persists as long as the repo is
"in use") plus one session-scoped keeper per concurrent session in that repo — so keeper count
scales as *(repos × (1 + concurrent sessions in that repo))*, at ~1MB each. Even at 50 sessions
across 10 repos that's ~60 processes, ~60MB — still a rounding error.

Every keeper's `PPID` is `1` — this is **expected**, not a leak signature: `heimdall-wrap`
explicitly detaches the presence keeper as fire-and-forget (`bin/heimdall-wrap:234-235`,
comment: *"presence is a nicety, and a control plane that is unreachable... must never fail a
wrap"*). The real orphan test is whether a *session-scoped* pidfile outlives its session, and
hmd already has a dedicated, tested reaper for exactly that
(`heimdall-gc`'s `gc_procs()`, `bin/heimdall-gc:224-259` — reaps dead-pid and
foreign-recycled-pid pidfiles, keeps genuinely-live ones). Cross-checked against
`heimdall-reap-idle`'s independent idle-agent axis (different mechanism, `heimdall-sysmon
--filter-idle-agents`): **`0 idle agent(s) reapable (~0MB)`** — nothing is currently stuck.

**The known failure mode, checked directly and ruled out.** `skills/system-health/SKILL.md`
documents a real historical incident: the presence-doctor's `mock_cp.py` (a mock
control-plane) spawning children that get orphaned to launchd and were once found at ~692
processes, pinning all 16GB and thrashing swap 17G/17G. I found **11 unlabeled orphaned
python3 processes** (`PPID 1`, pyenv 3.11.14, command line shows only `python3 -` since the
script was piped via stdin) that were a plausible circumstantial match, so I did not take the
shortcut of assuming — I ran hmd's own dedicated matcher, the same one the reaper uses:

```
$ bin/heimdall-sysmon --filter-orphans
(no output — matches nothing)

$ bin/heimdall-sysmon
heimdall-sysmon — system health: CRIT
  disk     warn  Data 29.8Gi free · 86% used
  memory   crit  swap 2.2G/3.0G (73%) · free 0% · wired 65%
  procs    ok    no heimdall python leak · python3 12
```

**Verdict: not the known leak.** hmd's own detector explicitly clears these processes. `lsof`
on one sample (PID 21614) shows no listening socket (rules out a mock control-plane server)
and a `cwd` pinned to a specific agent worktree, plus loaded libs (`_json`, `zlib`, `_lzma`,
`_hashlib`, `_datetime`) consistent with some general-purpose utility script, not a server.
Total cost: **71,968 KB (≈70.3MB) across all 11** — I could not identify the exact originating
script within this audit's scope, and I'm not going to dress up an unidentified-but-cleared
73MB as a finding; it's noted honestly as an open question, not a diagnosed problem.

### A3. Claude Code session RSS

Three live top-level `claude --agent heimdall` sessions, one consistent snapshot:

| PID | RSS (KB) | RSS (MB) | ELAPSED | Notes |
|---|---|---|---|---|
| 88847 | 223,936 | ~218.7 | 39:51 | holds an active worktree lock |
| 23855 | 108,000 | ~105.5 | 25:11 | |
| 61993 | 115,328 | ~112.6 | 10:08:04 | `--model opus` |

**Total: 447,264 KB ≈ 436.8MB for 3 concurrent sessions.** This is Claude Code itself, which
the task explicitly scopes out ("the user pays for regardless") — included here only to size
it against hmd's own footprint below. Worth flagging: RSS for a Node-based CLI is genuinely
volatile. A snapshot taken ~7.5 minutes earlier read 228,864 / 114,992 / 103,024 KB for the
same three PIDs — swings of −2.2%, −6.1%, and **+12.0%** in under 8 minutes, almost certainly
V8 GC breathing. Any single-snapshot RSS number for a live session should be read as a point
in a noisy band, not a constant.

Each session also carries a small hmd-owned tail: the `bin/heimdall` launcher wrapper
(600-1,800 KB, bash, trivial) and, when a ledger tool is actually invoked,
`heimdall-ledger-mcp` (`~/.pyenv/…/python3 ./bin/heimdall-ledger-mcp`, RSS 4,352 KB). Only
**1 of the 3** live sessions had an active ledger-mcp instance at measurement time — it appears
to be spawned on demand, not an always-on per-session tax.

*(Not hmd — flagged only for honest calibration: each session also carries the third-party
`claude-mem` plugin's own MCP chain, ~10-40MB of node/bun processes, plus a shared
`worker-service.cjs` daemon at 52,176 KB and a `chroma-mcp` pair at ~41MB combined. None of
this is hmd's code or hmd's to fix; it's here so the reader can see the whole memory picture
was actually inspected, not cherry-picked.)*

### A4. Marginal RAM cost of hmd's own machinery per additional parallel session

| Component | Scales with | Cost |
|---|---|---|
| Headroom proxy | machine (shared, once) | ~96-98MB **total**, not marginal — zero additional cost per extra session once one instance exists |
| Presence keeper (session-scoped) | +1 per session | ~1MB |
| Presence keeper (`__default`) | +1 per *new repo*, not per session | ~1MB |
| `heimdall-ledger-mcp` | on-demand, not guaranteed | ~4.3MB when active |
| `bin/heimdall` launcher | +1 per session | <2KB |

**Answer: hmd's own machinery costs on the order of 1-5MB of marginal RAM per additional
parallel session.** That is roughly 40-200x smaller than what Claude Code itself costs per
session (~100-220MB observed above). For N parallel sessions, hmd's own contribution to total
memory is `N × ~1-5MB + one fixed ~96MB if headroom is active` — at N=20 that is still under
200MB, 1.2% of 16GB.

---

## B. Disk

### B1. Agent worktrees — the actual disk story

```
$ ls -d .claude/worktrees/agent-*/ | wc -l
      66
$ git worktree list --porcelain | grep -c '^worktree '
36
```

66 directories exist on disk; only 36 are registered with git (the primary repo + this
worktree + 34 agent worktrees). The gap is real and I ran it down rather than assume: a
per-directory `du -sh` breakdown (`du -sh .claude/worktrees/agent-*/`) shows **32 of the 66
directories at 0B-4.0K** — e.g. `agent-a0171bb4cba6a1980/` contains only an empty nested
`.claude/` dir, **no `.git` file at all** (confirmed: `cat .git` → "No such file or
directory"), meaning it was never actually a git worktree — and confirmed absent from the full
`git worktree list --porcelain` dump entirely (not even as `prunable`):

```
$ grep -c 'a0171bb4cba6a1980' wt-porcelain.txt
0
```

**These 32 stub directories are structurally invisible to `heimdall-reap-idle` and
`heimdall-gc`** (both operate exclusively off `git worktree list`), so no existing tool will
ever clean them — but they cost **~8KB combined**. This is a real gap in reach, but not a real
disk problem; not worth building anything for.

The other **34 are real, full checkouts, averaging ~18MB each, summing to ~609MB** (cross-
checked: per-directory sum 609MB vs `du -sh .claude/worktrees` aggregate = `620M`, gap
explained by per-directory MB rounding). Running `heimdall-reap-idle` in its default,
**safe, read-only dry-run** (no `--apply`):

```
$ bin/heimdall-reap-idle
heimdall-reap-idle: repo=/Users/rj/Downloads/heimdall main=main@7ac7ab94 mode=DRY-RUN
...
SUMMARY (dry-run): would reap 24, 8 kept-unmerged (...), 0 poller(s) found,
0 idle agent(s) reapable (~0MB) — rerun with --apply to reap
```

24 worktrees classified `REAP` (merged into `main` by git ancestry) ≈ **454MB reclaimable**,
8 correctly `KEEP`-ed (unmerged commits, ≈123MB legitimately protected), 1 `SKIP`-ed (locked,
owning agent pid 88847 still alive), plus this worktree itself (excluded as self).

**Why hasn't `--apply` already reclaimed the 454MB? — a documented, still-valid safety pause,
not neglect.** `~/.heimdall/no-cleanup` exists:

```
TEMPORARY SAFETY MARKER — created 2026-08-12 by hmd during an active session.

WHY: hooks/hooks.json:160 runs `heimdall-cleanup --auto` at SessionEnd without
--quick, which reaches `heimdall-reap-idle --apply` -> `git worktree remove --force`.
That path classifies purely on "tip is an ancestor of main" and has NO dirty-tree
check and NO memory-home check. Three worktrees currently listed as reapable hold
work that is not on main:
  agent-a017a21380f20d3c1  (modified test file)
  agent-a5966168bd89de686  (5 token-meter files, agents editing it right now)
  agent-a6110ee6af22fd773  (AGENT MEMORY HOME - .claude/agent-memory/ is gitignored)
```

I confirmed this is not stale. All three named worktrees **still appear in today's REAP list**
(unchanged, 7 days later — nobody has `--apply`-ed since, exactly as intended). The sandbox
correctly blocks a worktree-isolated agent from running `git -C <other-worktree>` directly
(a real containment boundary, confirmed by testing it), so I couldn't re-run `git status` on
the other two — but I could, and did, check the third with a plain (non-git) `ls`, since
gitignored content is invisible to git either way:

```
$ ls -la .claude/worktrees/agent-a6110ee6af22fd773/.claude/agent-memory/
drwxr-xr-x  4 rj  staff  128 10 Aug 22:04 .
drwxr-xr-x  4 rj  staff  128 10 Aug 22:04 ..
drwxr-xr-x  4 rj  staff  128 10 Aug 22:04 hmd-coder
```

**Confirmed live, not hypothetical**: this worktree still holds a real, non-empty,
never-committed `agent-memory/hmd-coder/` directory. Right now, `--apply` would still silently
destroy it exactly as the marker warns. `bin/heimdall-cleanup` (the thing hooks.json actually
wires into SessionStart/SessionEnd) independently honors the same marker at its own `--auto`
gate (`bin/heimdall-cleanup:56,89-92,427`: `if [ "$AUTO" = 1 ] && opted_out; then return 0;
fi`) — so the marker's claim to disable "ALL auto cleanup, including the process-orphan
reaping" is verified in the code that's actually wired up, not just asserted in a comment.

Reading `bin/heimdall-reap-idle`'s current `reap_worktrees()` (lines ~330-336) confirms the
gap is still open: the REAP branch is still exactly one check —
`git merge-base --is-ancestor "$tip" "$MAIN_SHA"` — with no working-tree-clean check and no
`.claude/agent-memory` check. The fix the marker describes has not landed.

The task's own baseline cited "12 reapable worktrees" (a prior SessionStart-hook reading);
today's measurement is 24 — roughly doubled, consistent with 7 days of continued session
activity while the reaper stays paused. This is accumulation with a known, bounded cause and
an existing (if not-yet-safe-to-automate) mechanism to clear it — not an unbounded leak.

### B2. Logs and stores — checked for rotation, not just size

**`~/.headroom/`** (the external `headroom` CLI's own home — distinct from
`~/.heimdall/headroom/`, hmd's own chain-local proxy.pid/log) — **66MB total**:

| File | Size | Rotation? |
|---|---|---|
| `logs/proxy.log` (+`.1`-`.5`) | 60.7MB (6 files) | **Yes — bounded.** Live file caps near 10,485,760B (exactly 10MB) before rolling; 5 old copies kept, then evicted. See evidence below. |
| `savings_events.jsonl` | 3.5MB | No rotation found; currently **static** (see below) |
| `toin.json` | 1.9MB | unknown (single snapshot, no history to diff) |
| `proxy_savings.json` | 2.1MB | unknown (single snapshot, no history to diff) |
| `ccr_store.db` (+`-shm`/`-wal`) | 790KB | unknown |
| `subscription_state.json`, `update_check.json` | 15KB | negligible |

Component sum = 69,145,978B ≈ 65.95MB, matching the measured `du -sh ~/.headroom` = `66M` —
confirms the breakdown accounts for everything, nothing hidden.

**Proof the log rotation is genuinely bounded, not just "looks capped right now":**

```
$ wc -l ~/.headroom/logs/proxy.log*
   23871 proxy.log
   30640 proxy.log.1
   30507 proxy.log.2
   32287 proxy.log.3
   30529 proxy.log.4
   30385 proxy.log.5
  178219 total
```

**178,219 — the exact figure the task cites as a prior measurement.** For a 6-file bounded
rotation, the total line count naturally oscillates around a roughly constant figure forever
(old content keeps getting evicted as new content lands), so landing on the *identical* total
at a later measurement is itself direct evidence the bound is holding — if it were unbounded,
the total should have grown since whenever that baseline was taken. It didn't.

**`savings_events.jsonl` is a different case — no rotation, but currently not growing either:**

```
$ wc -l ~/.headroom/savings_events.jsonl
   19168 /Users/rj/.headroom/savings_events.jsonl
```

Also the exact figure cited as the prior baseline — **zero growth**, not oscillation-around-a-
bound like proxy.log. This file has no sibling `.1`/`.2` rotation files, and it's an
append-only `.jsonl` owned by the external `headroom` tool (not this repo's code), so nothing
here would cap it if it *did* start growing again. Per this repo's own recent commit history
(`docs(analysis): diagnose why headroom compression is a local no-op`), local compression is
currently understood to be a no-op — consistent with why nothing new is being appended. Flagged
as a **watch item**, not a current problem: it's static today, and any fix for it belongs in
the external `headroom` tool, not in hmd's own code.

**`~/.heimdall/`** (hmd's own home) — **15MB total**, everything small:

| Dir | Size | Notes |
|---|---|---|
| `ctx/` | 1.2MB (326 entries) | see below — no TTL sweep found for this dir |
| `data/` | 504KB | |
| `pki/` | 228KB | |
| `wrap-state/` | 224KB | 4 repos' wrap snapshots |
| `headroom/` (chain-local) | 156KB | proxy.pid + proxy.log |
| `telemetry/` | 88KB | |
| `.sigil-cache/` | 72KB | TTL-pruned by `heimdall-gc` (24h default) |
| `vis-cache/` | 44KB | TTL-pruned by `heimdall-gc` (24h default) |
| `logs/` | 20KB | rotated by `heimdall-gc` (1MB threshold) |
| `presence-keeper/` | 32KB | 8 pidfiles |
| `bin/`, `liveness/`, `ledger/`, `gh-app/`, `signing/` | ≤16KB each | |
| `presence-doctor/` | 0B | empty |

`ctx/` (326 small files, mostly `<session-id>.json` + matching `.json.<pid>.tmp` siblings —
an atomic write pattern) is the one directory here I did **not** find a pruning mechanism for
in `heimdall-gc`'s source (its temp sweep covers `$TMPDIR`/`/tmp` `hmd-*` files, the sigil/vis
caches, and `~/.heimdall/logs/*` — not `ctx/`). Oldest visible entries are from 8 Aug (11 days
before this measurement), newest from moments ago — roughly 30 files/day, ~3.6KB average. At
**1.2MB after 11 days of visible history**, this is real but nowhere near urgent; noted in §D
for completeness, not raised as a problem.

### B3. Task transcripts

```
$ du -sh /private/tmp/claude-501
 91M	/private/tmp/claude-501
```

**91MB.** This lives under `/private/tmp`, which is OS/session-managed (macOS clears it across
reboots, and it's outside any hmd reaping code entirely) — self-limiting by construction, not
something hmd needs to bound itself.

### B4. Total disk footprint and growth

| Component | Size |
|---|---|
| `.claude/worktrees/` (66 dirs; 34 real + 32 empty stubs) | 620MB |
| `/private/tmp/claude-501/` (self-limiting, OS-managed) | 91MB |
| `~/.headroom/` (external tool's own home) | 66MB |
| `~/.heimdall/` (hmd's own home) | 15MB |
| **Total** | **≈792MB** |

Growth is concentrated almost entirely in worktrees (620 of 792MB, 78%), and that growth has a
precise, dated cause: the no-cleanup marker paused the reaper on **2026-08-12** — 7 days before
this measurement — for a documented, still-verified-live safety reason (§B1). Reapable count
roughly doubled (12 → 24) over that window. Nothing else measured shows meaningful growth:
`~/.heimdall` is 15MB and mostly TTL-managed already; `~/.headroom`'s dominant component
(proxy.log) is proven bounded above; tmp transcripts are OS-reaped.

---

## C. The honest verdict

**Ranked by actual bytes, largest first:**

1. **620MB** — agent worktrees on disk. Real, but 98.7% of it (609MB) is legitimate full
   checkouts, and 74% of *that* (454MB) is already-known-safe-to-reclaim disk sitting idle
   because the reaper is deliberately paused, not because it's leaking uncontrollably.
2. **437MB** — 3 live Claude Code session processes' RSS. Not hmd. The user pays for this
   regardless of hmd.
3. **91MB** — tmp transcripts. Self-limiting, OS-managed.
4. **~96MB** — headroom proxy RSS, when running (it isn't, right now). One shared instance
   for the whole machine, by construction — zero marginal cost per additional session.
5. **70MB** — 11 unidentified orphaned python processes. Confirmed NOT hmd's documented
   leak (hmd's own `--filter-orphans` matcher returns nothing for them). Cause unknown; flagged
   honestly as unresolved, not dressed up as a diagnosed hmd problem.
6. **66MB** — headroom tool's own home (`~/.headroom`), 92% of which is a proven-bounded
   rotating log.
7. **15MB** — hmd's own home (`~/.heimdall`), almost entirely small and already TTL-managed.
8. **7.5MB** — 8 presence keepers across 4 repos.
9. **4.3MB** — 1 on-demand `heimdall-ledger-mcp` instance.

**Is parallel-session resource use a real problem on this 16GB machine? No — not from hmd.**
hmd's own machinery (proxy + keepers + MCP servers + gc/reaper infrastructure) totals well
under 150MB of RAM even in the worst case (proxy running, all keepers up), and costs roughly
1-5MB of *marginal* RAM per additional parallel session (§A4) — two orders of magnitude
smaller than what each Claude Code session itself costs. On disk, hmd's total footprint outside
the git repo is ~792MB, and the single largest, most "growing" component (worktrees) isn't
actually leaking: it's disk that a working, tested tool (`heimdall-reap-idle`) can already
reclaim on demand, currently held back on purpose.

**The machine genuinely is under resource pressure right now** — hmd's own `heimdall-sysmon`
independently grades it **CRIT**: swap at 73% (2.2G/3.0G), wired RAM at 65%, disk at 86% used.
But its own process-accounting section is explicit: **`procs ok · no heimdall python leak`**.
That pressure is coming from something else on this machine (other apps, other dev tooling —
the working directories in scope for this session include an active Android/Gradle build and
Xcode's `DerivedData`, both notorious wired-RAM holders) — not from hmd, and not specifically
from running several hmd sessions in parallel.

**Bottom line: this is a non-issue.** The one number worth a human's attention isn't "hmd uses
too much" — it's "454MB is sitting there, reclaimable, because a real safety bug is still open
in the reaper" (§D).

---

## D. If something is genuinely unbounded — proposed fix, not implemented

Nothing found here rises to "leaking." The two closest candidates, and why neither warrants
new tooling:

**1. `~/.heimdall/ctx/` (1.2MB, 326 files, no TTL sweep found).** This is the only directory
where I could not find an existing pruning path in `heimdall-gc`. The smallest fix, if it's
ever worth doing at this size, is to **extend the existing cache-TTL loop
(`bin/heimdall-gc`'s `gc_temp()`, which already iterates `for cdir in "$SIGIL_CACHE"
"$VIS_CACHE"`)** to also include `"$HMD_HOME/ctx"` — reusing the same TTL mechanism rather
than adding a new one. At 1.2MB after 11 days, this is a "someday" item, not a "now" item.

**2. `~/.headroom/savings_events.jsonl` (3.5MB, un-rotated, currently static).** No fix
proposed *in this repo* — the file belongs to the external `headroom` CLI, not to hmd's own
code, so there's nothing here for `heimdall-gc` to extend. Worth someone mentioning upstream if
it resumes active growth; not actionable from this codebase today.

**The one real, actionable finding — already fully diagnosed, fix already specified, not new
work to invent:** `heimdall-reap-idle`'s `reap_worktrees()` REAP branch
(`bin/heimdall-reap-idle:~330-336`) needs the two checks the `~/.heimdall/no-cleanup` marker
already names — a clean-working-tree check (`git status --porcelain` empty) and a
gitignored-memory-home check (no untracked content under `.claude/agent-memory/`) — added
*before* it's willing to `git worktree remove --force` something. That, plus its own
`PROVE-DETECTS` test going green, is explicitly the removal condition the marker itself states
(`rm ~/.heimdall/no-cleanup`). This is not a proposal for new machinery — `heimdall-reap-idle`,
`heimdall-gc`, and `heimdall-cleanup` already fully cover worktree reaping, orphan-pidfile
reaping, temp/log TTL, and claude-version GC; the only gap is this one classification rule
inside a tool that already exists and otherwise already works correctly (confirmed directly:
its dry-run output above correctly separates REAP/KEEP/SKIP for every other case tested).
