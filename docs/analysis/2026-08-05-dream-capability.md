# What `/dream` would actually conjure here — 2026-08-05

**Question (verbatim):** *"what were the improvements that dream could conjur?"*

**Short answer:** on this repo, today, the deterministic `/dream` returns an **honest-empty
report** — it has no evidence to reason from and it will say so. It cannot fix the open
test failures, cannot clear the launch blockers, and has never once run successfully on the
nightly schedule. It is safe to run mid-day, and it is nearly worthless right now for the
reason it was designed to be worthless: it refuses to invent findings.

Everything below is grounded in files on disk at commit `30a8073`. Anything I could not
verify is marked **UNVERIFIED**.

---

## 1. What dream actually is, mechanically

There are **two different things** wearing the name, and conflating them is the whole
source of the inflated expectation.

### (A) `bin/heimdall-dream` — the deterministic orchestrator

Stdlib python3, **no model in the loop**. A run is exactly five shell-outs:

| Step | Call | Reads |
|---|---|---|
| 1 | `heimdall-self-improve collect` | `.planning/metrics.jsonl` |
| 2 | `heimdall-self-improve hypotheses --min-samples 3` | same + `.planning/queue-stats.json` |
| 3 | `heimdall-self-improve status` | `.planning/routing-overrides.json`, `experiments.jsonl` |
| 4 | `heimdall-self-improve experiment evaluate --id <each open>` | metrics |
| 5 | `heimdall-issue-loop status` | the live issue queue |

It then renders three sections to `.planning/dream/YYYY-MM-DD.md`
(`bin/heimdall-dream:105-196`, `:201-345`).

**Its entire universe of "improvements" is one thing: which model tier a `task_type` routes
to.** `bin/heimdall-self-improve:180-192` defines the whole move set —
`haiku → sonnet → opus` (escalate a failing type) or the reverse (cheapen a flawless one).
That is it. It does not read source, does not read tests, does not open files, does not
reason about code.

**What it changes:** with `--start-experiment`, at most one key in
`.planning/routing-overrides.json` plus an append to `.planning/experiments.jsonl`. Without
that flag (the default, and what the schedule fires) it changes **nothing** but the report
file. `bin/heimdall-dream:20-21` is explicit: no `git push`, no `gh pr`, no merge — and
`grep -n 'push\|gh pr\|merge' bin/heimdall-dream` returns only comments and report prose.

**Bounded:** yes, hard. Five subprocesses, no network, no recursion, no agent spawn.
Wall time is seconds.

### (B) `/dream` — the slash command

`commands/dream.md` has `disable-model-invocation: true` — it is user-invoked only. Its
instruction to the model is to run (A) and **report the summary line**. `commands/dream.md:77-83`
explicitly says: on honest-empty, *"say so plainly … Do not manufacture findings."*

The rich, 73-line `.planning/dream/2026-07-12.md` that likely seeds the expectation was
**not** a vanilla `/dream`. Its own header (`:3-4`) says it was *"+ a requested eval pass
(optimization · virality · improvements · new-feature test · addyosmani/agent-skills)"* —
an owner-directed agent sweep that happened to be written into the dream folder. The
vanilla output is `.planning/dream/2026-07-11.md`: 30 lines, three empty sections.

### (C) The nightly job has never worked

`~/Library/LaunchAgents/com.heimdall.dream.plist` (read-only; not touched) fires
`bin/heimdall-dream --repo /Users/rj/Downloads/heimdall run --overnight` at 03:00.

`~/.heimdall/logs/dream.log` is **12 lines, all errors, zero successes**:

```
10 ×  /Applications/Xcode.app/.../python3: can't open file
      '/Users/rj/Downloads/heimdall/bin/heimdall-dream': [Errno 1] Operation not permitted
 1 ×  shell-init: error retrieving current directory: getcwd: ... Operation not permitted
 1 ×  job-working-directory: ... Operation not permitted
```

Log mtime `Aug 5 03:00:03 2026` — **this morning's run failed too**, and no
`.planning/dream/2026-08-05.md` exists. Cause: launchd-spawned processes have no TCC grant
for `~/Downloads`, so the interpreter cannot open the script. `test/heimdall-dream-schedule.test.sh`
cannot catch this — it shims `launchctl` and is hermetic by design, so it proves the plist
is well-formed and proves nothing about whether the job can read the disk.

---

## 2. What it would plausibly fix here — ranked

First, the blunt part. **Dream's own evidence inputs are empty:**

- `.planning/metrics.jsonl` — 79 lines, **all** `metric:"parallelism"`. `_task_records()`
  (`bin/heimdall-self-improve:139-149`) keeps only `metric == "task"`. → `total_task_records = 0`.
- `.planning/queue-stats.json` — **absent**. → zero precheck hypotheses.
- `.planning/routing-overrides.json` — **absent**. → zero open experiments to evaluate.

So `honest_empty` (`bin/heimdall-dream:158-160`) evaluates **True**. A run today writes the
30-line "Nothing to suggest" report and exits 0. That is the literal answer to the question.

The table below therefore splits **what vanilla dream returns** from **what an
owner-directed overnight agent sweep** (the thing the 07-12 report actually was) could
return. Only the second column is interesting.

| # | Item | Evidence on disk | Vanilla `/dream`? | Agent sweep? | Value |
|---|---|---|---|---|---|
| 1 | **4 live tests `git checkout -- bin/` the REAL worktree from an EXIT trap** | `test/install-cp-endpoint.test.sh:66`, `install-validate.test.sh:111`, `install-team-secret.test.sh:76`, `share-card.test.sh:71` — each `REPO="$(cd "$SELF_DIR/.." && pwd)"`, each in `trap cleanup EXIT`, each triggered by a start-vs-exit snapshot diff | **No** | **Yes** — the fix is already written down: `install-crypto-backend.test.sh:118-129` documents this exact defect and fixes it with a private `git clone`. Propagate to 4 siblings | **Highest.** This is a data-loss bug, live, while agents edit `bin/` |
| 2 | **Installed pre-push hook is stale and still fails open** | `.heimdall/hooks/pre-push:29-34` = `if [ -n "$GATE" ] && [ -x "$GATE" ]; then …; fi; exit 0`. The generator `bin/heimdall-init:248-257` **was fixed** — it emits the BIFRÖST fail-closed branch. The live hook was never regenerated | **No** | **Yes** — `hmd init` refresh + a test pinning generator-vs-installed parity | **High.** This is the gate guarding the release push that comes next |
| 3 | `test/wrap-lifecycle.test.sh` 8a/8b/8e | `:737-758`. 8a asserts the stub saw `heimdall-wrap ARGS: launch`; 8b asserts the trace did *not* see `launch:task`; 8e asserts empty ≠ unknown. Same fall-through class fixed three times today | **No** | **Yes** — bounded, one launcher-routing branch, falsifier already written | High |
| 4 | Six unfixed HN-red-team findings (below) | `docs/analysis/2026-08-04-hn-red-team.md` | **No** | **Partly** (3 of 6) | Mixed |
| 5 | `test/heimdall-team-default.test.sh:95` `auto slow (3713ms)` vs 3000ms | Budget is a bare `[ "$((T1-T0))" -lt 3000 ]` around one `bash "$TEAM" auto`. Pre-existing at every commit incl. the one that introduced it (4386ms) | **No** | **Yes, but** — this is a *spec* decision (raise the budget to a measured p95, or cut spawns), not a bug hunt. Needs a human call on which | Medium |
| 6 | `bin/lib/repo_roster.py` ~55ms warm on a per-prompt statusline | 1351 lines; TTL caches at `:157-159` (`GIT_CACHE_TTL=300`, `GITHUB_CACHE_TTL=21600`); hot-path policy documented `:100-101` | **No** | **Yes** — profile-first, but the caching architecture is already correct, so the remaining 55ms is likely interpreter + import floor. **UNVERIFIED**: I did not re-measure the 55ms | Low-Medium |
| 7 | Feed dream its own evidence (emit `metric:"task"` records) | Schema documented `bin/heimdall-self-improve:44-47`; nothing writes it | **No** | **Yes** — this is the change that makes dream non-empty *next* time | Medium (compounding) |

### The six red-team findings NOT fixed today

Verified individually against current disk state. (Fixed and confirmed: #5 corpus regex —
`bin/heimdall-gate-run` now anchors on `^corpus-catch-rate:`; #6 `--json` — now emits at
`:144-145`; #11's *command* half — `hmd team rotate` exists at `bin/heimdall-team:70`.)

| Finding | State today | Agent-doable? |
|---|---|---|
| **#7** spend cap fails open, advertised flat | `bin/lib/cp_daily_budget.py` unchanged (correct by design); the offending copy is `heimdall-site/index.html:245` — **separate repo** at `/Users/rj/Downloads/heimdall-site` | **No** from this repo. A `SECURITY.md` paragraph here *is* doable |
| **#8** 29 `[RECEIPT:]` markers | Still 16 in `launch-docs/SHOW-HN-DRAFT.md`, 13 in `log-compression-and-gates.md` = 29 exactly | **NO — owner-blocked.** See §3 |
| **#9** tag vs main diverged | `git describe` → `v2.3.8`; `origin/main` → `063155f`; **259** unpushed | **No — owner decision** (cut the tag) <!-- HEIMDALL:PIN:FROZEN — a git-describe reading taken on the audit date, paired with the sha it was read beside --> |
| **#10** pre-push fails open | Generator fixed, **installed hook stale** — see row 2 above | **Yes** |
| **#11** bearer secret in shell history | `grep -n 'bearer\|shell history' SECURITY.md` → **no match**. Rotate command shipped, disclosure did not | **Yes** — one SECURITY.md paragraph |
| **#12** `cp-funnel` 4d absence-grep | `test/cp-funnel.test.sh:427` still `if ! grep -qE … "$LIB/funnel.py" 2>/dev/null`, no `[ -f ]` guard | **Yes** — one line, ~5 min |
| **#13** `docs/analysis/` gitignored | `.gitignore:35` still ignores it; 10+ files are force-added. *This document needed `git add -f`* | **Yes**, but it is a policy call |

---

## 3. What dream CANNOT touch

Be clear-eyed: **dream will not clear a single launch blocker.**

- **The 29 `[RECEIPT:]` markers are structurally unresolvable by any agent.** They are
  parameterised on a **founding cohort that never ran** — real teams, real two weeks, real
  numbers. `SHOW-HN-DRAFT.md:9` is a self-imposed hard gate: *"if a single `[RECEIPT:]`
  marker is still in the text, the post does not go out."* An agent filling those in would
  be fabricating evidence, which is the exact failure the whole repo is built to prevent.
  The only agent-doable move is to **write the different post** — the one supported by
  evidence that exists today (isolation oracle 23/23, the 29-bug bring-up ladder, 0.50
  median reuse at `ae88a55`). That is a judgement call, not a dream output.
- **Cutting v2.3.9** — six digest/tag sites across two repos, one of which is not here.
  Owner decision, and red-team #9's own advice is *"do not launch mid-release."*
- **Anything in `heimdall-site/`** — separate repo, not this working tree.
- **The `metric:"task"` history** — dream cannot conjure the past. Even after wiring the
  emitter, the first useful hypothesis needs `min_samples = 3` real task outcomes.
- **The team-default 3000ms budget** — whether that number is wrong or the code is slow is
  a spec judgement. An agent that "fixes" it by raising the constant has deleted a gate.
- **Anything credentialed** — dream runs no `git push`, no `gh`, no deploy, by construction.

---

## 4. Is it safe to run right now?

**Yes for `bin/heimdall-dream run` (no flag). No for a broad agent sweep until the tree is
quiet — and in both cases, commit first.**

Reasoning, in order of how much it matters:

1. **`bin/heimdall-dream run` writes exactly one file** — `.planning/dream/2026-08-05.md`.
   It runs no git command at all. It cannot conflict with the agents live in `bin/`,
   `sentinels/`, `modules/`, README, or the site. The 259 unpushed commits are irrelevant
   to it — it never touches refs. Verdict: **safe, mid-day, right now.**
2. **`--start-experiment` is a no-op today** (zero routing hypotheses → `cand` is `None` at
   `bin/heimdall-dream:138-141`), but do not pass it anyway: there is no reason to arm a
   write path that has nothing to write.
3. **The real hazard is not dream, it is the board.** Do **not** run the full suite while
   other agents hold uncommitted work in `bin/`. Four tests — `install-cp-endpoint`,
   `install-validate`, `install-team-secret`, `share-card` — will, on **any** exit path,
   diff `git status --porcelain -- bin/` against a snapshot taken ~30s earlier and run
   `git -C "$REPO" checkout -- bin/` if it differs. A teammate's or agent's concurrent edit
   is misattributed to the installer and **silently reverted**. This is not speculation:
   `install-crypto-backend.test.sh:118-129` records it happening (*"DESTRUCTIVE: … discarding
   a teammate's uncommitted work"*) and fixed **only itself** with a private clone.
4. **Commit before anything.** The working tree is clean at this moment
   (`git status --porcelain` → 0 lines), which is the good state. It will not stay that way
   while other agents write. Any dream-adjacent work should start from a committed tree so
   that a stray `checkout -- bin/` costs nothing.
5. **Do not push.** 259 unpushed commits + a stale fail-open pre-push hook (§2 row 2) means
   the gate that is supposed to guard the push is currently a no-op if `heimdall-gate-run`
   cannot be resolved. Fix the hook before the release push, not after.

**One-line policy:** run `bin/heimdall-dream run` now if you want the receipt; run the
board only from a committed tree with no other agents live in `bin/`.

---

## 5. The honest ceiling

**A vanilla dream run tonight returns a 30-line "Nothing to suggest" report.** That is not
a failure — `bin/heimdall-dream:217-222` is doing exactly what it was built to do: refuse
to fabricate. But it means the answer to *"what improvements could dream conjure?"* is,
today, **none, autonomously.**

The ceiling on the *other* thing — an owner-directed overnight agent sweep — is real but
narrower than it feels:

- **It mostly re-finds what today's agents already found.** Every candidate in §2 was
  already written down: the red-team doc named six of them yesterday, the wrap failures are
  named in the test's own assertion strings, and the destructive-trap fix is documented
  verbatim inside a sibling test. A sweep's value here is **execution, not discovery** —
  it would be doing known work, not finding unknown work.
- **The one genuinely new thing this assessment surfaced** is item 1 (four live destructive
  traps) and the stale pre-push hook — and both were found by reading, in minutes, not by
  an overnight run.
- **Three of the six open red-team findings are 5-to-30-minute mechanical fixes**
  (#10 hook, #11 disclosure, #12 existence guard). A night is not required.
- **The expensive-looking items resist automation.** #8 needs a cohort that does not exist.
  #9 needs an owner to cut a tag. The 3000ms budget needs a human to decide whether the
  number or the code is wrong.
- **The compounding play** is item 7: wire `metric:"task"` emission so that dream has
  evidence *next* time. That is the only change that raises dream's own ceiling. Right now
  the loop is a well-built engine with an empty fuel tank, and it has been failing to start
  on a schedule for 10 consecutive nights on top of that.

**Do not spend a night on this before the release.** Spend 45 minutes on items 1, 2, and
the three mechanical red-team fixes, from a committed tree, then ship.

---

## Scope of this assessment

Read-only. Modified nothing but this file. Did not run `/dream`, `bin/heimdall-dream`, the
board, or any test. Did not read, write, load, unload, or otherwise touch
`~/Library/LaunchAgents` beyond a single `Read` of the plist and `stat` of its mtime. Did
not touch `~/.heimdall`, `~/.claude`, or crontab. Repo root verified as
`/Users/rj/Downloads/heimdall` before any other command.

**UNVERIFIED items:** the 55ms `repo_roster.py` warm cost (not re-measured); the exact
count of "7 red-team findings fixed today" (I verified 3 fixes on disk — #5, #6, and #11's
command half — and verified 7 findings still open; the remainder are in the separate
`heimdall-site` repo, which I did not read); whether the TCC denial on the LaunchAgent is
resolvable by granting Full Disk Access to `launchd`-spawned python or requires relocating
the repo out of `~/Downloads`.
