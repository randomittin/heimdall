# Statusline "many folks" investigation — 2026-08-29

**Owner question:** "why does the statusline show so many folks when only ritesh is
there as collaborator in this project"

**Read-only investigation.** No behavior changed. No fix implemented — proposal only,
at the end.

## Verdict

**(d), adjacent to (a).** Not a confirmed cross-team privacy leak (c). Not agents
miscounted as humans (a) in the literal sense — spawned sub-agents don't run their own
presence keeper and don't appear as extra rows. Not simple TTL staleness (b) — the
roster/wall caches have working TTL + reap logic and are currently fresh.

The actual mechanism is a **known, already-partially-fixed display defect**: the
statusline's team wall pulls from a machine-global mirror file
(`~/.heimdall/ledger/status.json`) that is shared by every repo on the machine and
overwritten by whichever repo's background "keeper" beats last. Two live sessions in
two different repos on the same machine can transiently show each other's rosters
before the scope guard (`_ledger_in_scope`) or the bigger-wins comparison in
`_team_members` corrects it a beat later. **This machine currently runs 60-70+ git
worktrees concurrently** (this agent itself is running from one of them:
`.claude/worktrees/agent-ac78ebdce51bc53fd`, a SuperSmartVerify worktree — itself
proof of the concurrency level), which is exactly the condition that maximizes how
often this race window gets hit — that volume is the most plausible reason the owner
caught it now rather than on a quieter machine.

Critically: **even in the buggy race window, the blast radius is same-owner,
cross-repo** (repo A's roster of names/HAIDs briefly rendered on repo B's wall, both
belonging to the same human) — **not** a different team_id's or a stranger's private
roster arriving via the network/control-plane path. The control-plane team_secret
scoping (Q4 below) is airtight by construction and was verified to have no bearing on
this. That distinction matters: it's a mis-scoped local file, not exposure of another
team's secret data.

The **current steady state, verified live at time of writing, is correct**: exactly
one non-self entry, `ritesh7792`, tier `member` — matching the owner's own expectation
exactly. The bug is real and worth fixing, but it is not actively firing right now.

---

## Q1 — Where does roster data come from?

Three layers, all local files, no direct control-plane read at render time:

1. **`bin/lib/repo_roster.py`** — identity-fusion engine. Reads three fragment
   sources: `presence_fragments()` (local presence cache), `git_fragments()` (`git
   log` authors of this repo), `github_fragments()` (`gh api
   repos/{slug}/collaborators`, **repo-scoped**, not org-wide — confirmed by reading
   the call). Fuses them via `unify()`/`would_merge()`/`signals()` into a `people[]`
   list, writes `<repo>/.heimdall/.wall-cache.json`.
2. **`sentinels/hmd_wall.py`** — pure reader/overlay over that cache
   (`read_wall()` → `overlay_presence()` → `wall_members()`), excludes self
   (`_not_self`), degrades to `[]` on any fault. Repo-scoped by construction — the
   cache path is `<repo>/.heimdall/.wall-cache.json`.
3. **`~/.heimdall/ledger/status.json`** (machine-global) — written by
   `bin/heimdall-status-json` on every presence-keeper "beat", sourced from
   `bin/heimdall-presence roster --json`, stamped with a `repo` field. **This one file
   is shared by every repo on the machine.** `sentinels/hmd-statusline.py`'s
   `_team_members()` reads it as a second candidate source and picks whichever of
   (repo-scoped wall) vs. (this global mirror) reports **more** members — the
   comparison that creates the race.

No control-plane HTTP call happens in the render path itself; the control plane is
only touched by the presence *keeper* daemon that periodically refreshes the local
caches (see Q4).

## Q2 — How many entries, and what are they?

Ground truth, captured live during this investigation:

```
$ python3 bin/lib/repo_roster.py --explain
counts: {"collaborators": 2, "people": 2}
people:
  handle=rj          tier=online  sources=[presence,git,github]  haid=haid:rj.rishabhs-macbook-air-46d5
  handle=ritesh7792  tier=member  sources=[github]                haid=null
```

```
$ ~/.heimdall/ledger/status.json  (mtime ~real-time-fresh)
repo: /Users/rj/Downloads/heimdall
team: [ {haid: haid:rj.rishabhs-macbook-air-46d5, user: rj, online: true, state: idle} ]
```

Live statusline render (realistic Claude-Code-shaped stdin, `hooks/statusline.sh`):
wall shows **exactly one** non-self entry — `ritesh7…` (truncated `ritesh7792`), tier
glyph `⌂mem`. No other names, no other HAIDs, anywhere in the rendered output.

**Two entries total (rj + ritesh7792), one shown after self-exclusion.** This matches
the owner's expectation exactly, right now.

## Q3 — Same machine/owner appearing multiple times, or genuinely other people?

Checked specifically for the "agents/worktrees each mint their own HAID and show up as
separate rows" failure mode, since this machine runs 60-70+ concurrent worktrees:

- Spawned agents **inherit the parent HAID** and append `/{role}`
  (`skills/heimdall/references/identity-and-ledger.md:21`); `_self_device_match()` in
  `repo_roster.py` matches on the human+machine prefix, so a spawned sub-agent's
  presence (if it emitted any) would still fold into the same "rj" person, not a new
  row.
- More directly: **spawned sub-agents don't appear to run a presence keeper /
  broadcast their own presence at all.** `.heimdall/.roster-cache.json` right now
  contains exactly one presence entry (`haid:rj.rishabhs-macbook-air-46d5`), despite
  dozens of worktree agents (including this one) being live at the moment of
  reading. If every worktree agent broadcast presence under a distinct HAID, this
  cache would show it — it doesn't.
- The `.planning/ledger/checkpoints/` directory *does* contain dozens of
  `haid_unknown.rishabhs-macbook-air-XXXX.json` files with differing hash4 per
  worktree path (human unresolved to `unknown`, likely because `git config
  user.email` isn't resolvable in whatever context wrote them). This looked
  superficially like the "many folks" mechanism, but **confirmed unrelated**: grepped
  `sentinels/hmd-statusline.py`, `sentinels/hmd_wall.py`, `bin/lib/repo_roster.py`,
  `bin/heimdall-presence`, `bin/heimdall-status-json` for any reference to
  `ledger/checkpoints` — zero hits. That directory belongs to the separate
  Coordination Ledger (claims/collision-prevention for cooperating agents,
  `skills/heimdall/references/identity-and-ledger.md:30-34`, explicitly "not a
  security boundary"), and does not feed the statusline wall at all. Worth a
  separate cleanup pass, but it is not this bug.

**Conclusion: no evidence of the same owner/machine fragmenting into multiple rows.**
The one real non-self entry (`ritesh7792`) is a genuinely distinct GitHub collaborator
on this repo.

## Q4 — Is any entry from a different team_id or different human than the owner?

**No — ruled out, with high confidence, via two independent mechanisms:**

1. **GitHub collaborator source is repo-scoped.** `github_fragments()` calls `gh api
   repos/{slug}/collaborators`, not `/orgs/{org}/members` — cannot pull in
   org-wide or cross-repo people.
2. **team_secret / team_id resolution is per-repo by construction, never global.**
   Traced `bin/heimdall-presence:413-435`: `TEAM_DIR` resolves to `git rev-parse
   --show-toplevel`/`.heimdall` (falling back to `$PWD/.heimdall` only when *not*
   inside a git repo at all) — it **never** falls back to `$HEIMDALL_HOME`/
   `~/.heimdall`. The code comment states this explicitly: "the SINGLE canonical file
   every reader... resolves from, NOT the global cp-endpoint.json (a dev may be on
   different teams in different repos)." Confirmed this machine has two *different*
   `team_secret` values — `<repo>/.heimdall/team.json` (created 1782572213) vs.
   `~/.heimdall/team.json` (created 1783369903, tagged `source: auto-solo`) — but the
   presence keeper for the heimdall repo **always** signs with the repo-local one; the
   global file is a disjoint binding from some other, non-repo invocation context and
   has no code path into this repo's roster. `derive_team_id()` (server-side,
   `sha256("heimdall-team\x00" + team_secret)`) means these two secrets necessarily
   produce two different team_ids that never mix.
3. Every identity observed across every cache/file inspected in this investigation
   (`.wall-cache.json`, `.roster-cache.json`, `.repo-roster-*.json`,
   `~/.heimdall/ledger/status.json`, the live render) traces to exactly two people:
   `rj`/`randomittin` (self, in all forms) and `ritesh7792`. No third identity, no
   foreign team_id, no unfamiliar handle appeared anywhere.

**The one architecturally real cross-boundary risk is the machine-global *ledger
mirror* (`~/.heimdall/ledger/status.json`), which is not team_secret-gated at all —
it's a bare local file written by whichever repo's keeper beat last.** In the window
before `_ledger_in_scope()` catches a mismatch, what could leak is *this machine's
other repos'* rosters onto this repo's wall — same owner, different project, still
not a foreign team_id. See Verdict above and the historical-incident evidence in Q5/Q6.

## Q5 — Does the roster filter by team secret, and dedupe human vs. agent?

**Team-secret filtering:** yes, at the control-plane layer. `cp_presence.py`'s
roster-team endpoint requires `team_secret` in the request (403 `team_secret_required`
otherwise) and derives `team_id` server-side — never client-supplied, never
client-held plaintext beyond the one local file. This is the layer that makes (c)
structurally hard to hit.

**The local ledger-mirror file is *not* team-secret gated** — it's read/written as a
bare filesystem object, trusted implicitly by path. That's the layer `_ledger_in_scope`
exists to police instead:

```python
# sentinels/hmd-statusline.py — _ledger_in_scope()
if root != here and os.path.commonpath([root, here]) != root:
    return {}
```

Docstring, quoted verbatim (this is the closest code-documented match to the owner's
symptom): *"THE DEFECT THIS CLOSES (reported live): 'the wall is now showing folks
from other repos as well initially and then updates it back to the current
project.' The mirror comes from ONE machine-global file... Its `team` is therefore the
roster of the LAST repo to write it... Two live sessions in two repos fight over the
one slot, so this repo's wall rendered the OTHER repo's people as present
here. ... THE RULE: an UNKNOWN scope renders as NOTHING, never as EVERYTHING."*

**Human vs. agent dedupe:** `_not_self()` is "the one membership gate" applied
uniformly across all three sources (wall cache, ledger mirror, live-presence
fallback) — its own docstring records that this uniformity was a deliberate fix for a
prior bug where the three sources applied self-exclusion inconsistently, causing the
owner to reappear on his own wall.

## Q6 — Staleness / TTL / reaping?

- `hmd_wall.py`: `WALL_CACHE_TTL=900.0`, `ONLINE_TTL=45.0`,
  `OFFLINE_WINDOW=7*24*60*60.0`. `refresh_due()` adds a **producer-mtime rule**: the
  cache is cold if the *producer script* is newer than the cache file, regardless of
  the cache's own age — this exists specifically because of a documented past
  incident (quoted verbatim in the code): *"repo_roster gained the identity merge at
  10:07 while the wall cache had been written at 10:05, so for the next fifteen
  minutes the renderer served the PRE-FIX snapshot and put the owner on his own wall
  as a second person."*
- `repo_roster.py` has cache TTLs per source (`git: 300s`, `github: 21600s`,
  `github_negative: 600s`) and a working, age-based `_reap_orphan_tmps()` for its own
  atomic-write tmp files (age-based, not pid-liveness, since PIDs get reused).
- **All caches checked were fresh** at investigation time (`~/.heimdall/ledger/status.json`
  mtime real-time-current; repo-local caches consistent with the live render).
  No evidence of a long-dead stale entry currently being displayed.
- **Minor, separate finding:** hundreds of orphaned `.roster-cache.json.<pid>.tmp` /
  `.agents-count-cache.<pid>.tmp` files, spanning several days, are still present on
  disk. These are inert — every reader opens the exact canonical filename, never a
  glob — so they don't feed any rendering path, but they are disk-hygiene debt.
  `repo_roster.py`'s own `_reap_orphan_tmps()` docstring records "1161 orphans beside
  a single live cache" as the scale of this problem for *its* cache family
  (`.wall-cache.json`); `.roster-cache.json` (written by `bin/heimdall-presence`, a
  different writer) appears not to share that same reaper — worth a follow-up, not
  related to the "many folks" question.

## Historical incidents on record (why this is a known defect class, not a new one)

Three separate, previously-fixed-or-mitigated incidents were found narrated directly
in code comments, all producing symptoms matching or adjacent to "extra people shown
that shouldn't be there":

1. **23-people-computed-but-never-rendered** (opposite direction: under-counting,
   historical, fixed by wiring `repo_roster` into the renderer at all).
2. **Wall-cache producer-rule race** (`hmd_wall.refresh_due()`) — stale pre-fusion
   cache briefly duplicated the owner as a second person on his own wall. Fixed via
   the producer-mtime check.
3. **`_ledger_in_scope` / global-mirror cross-repo contention** — closest verbatim
   match to the owner's report ("showing folks from other repos... then updates it
   back"). Mitigated via the scope guard (fail closed to `{}`) and the
   bigger-source-wins comparison in `_team_members`, but the underlying single-slot
   contention (many concurrent repos/worktrees on one machine sharing one mirror
   file) still exists — the guard bounds the *symptom*, not the *contention*.

## Residual, not-yet-fully-closed observation (flagged, not confirmed as a bug)

In `_team_members()`, the mirror-derived path caps at 3 (`return members[:3],
overflow`) but the repo_roster/wall-derived path, when it wins the "which is bigger"
comparison, returns uncapped (`return wall, 0`) — real width-based capping happens
later in `team_zone_alloc()` (confirmed present at
`sentinels/hmd-statusline.py:2166`), so this is very likely intentional (the
docstring says explicitly "NOT capped here... the cap is made by the code that knows
the real width"). Flagging only because the asymmetry is easy to misread as a bug;
the live render test performed in this investigation shows correct behavior end to
end for the current data shape, so this is not implicated in the owner's report.

## Proposed fix (NOT implemented — per instruction)

1. **Eliminate the single-slot contention at the source** rather than only bounding
   its symptom: key `~/.heimdall/ledger/status.json` (or its keeper-beat writer path)
   per-repo — e.g. a per-repo-hash subpath or filename under `$HEIMDALL_HOME/ledger/`
   — so concurrently running repos never share one write slot in the first place.
   This turns "two repos fight over one file, guarded after the fact" into "two repos
   each own their own file," which removes the race window `_ledger_in_scope` currently
   has to catch, rather than just catching it faster.
2. If a shared mirror file must remain (e.g. for a future "what's running
   machine-wide" view), make it a **list of per-repo entries** (keyed by repo path)
   rather than a single last-writer-wins record, and have `_team_members` read only
   the entry keyed to `cwd` — same effect as (1) without a file-layout migration.
3. Extend `_reap_orphan_tmps()` (or an equivalent) to cover the
   `.roster-cache.json.*.tmp` / `.agents-count-cache.*.tmp` families currently left
   un-reaped by `bin/heimdall-presence`'s own writer, for disk hygiene (separate,
   minor).
4. Optional hardening: tighten the "bigger source wins" comparison in
   `_team_members` to also require the winning source's own scope/freshness check to
   have passed, rather than size alone — today the guard is applied to the mirror
   before comparison, then whichever source has more entries wins outright; a belt
   sponsor here would double-gate the union rather than relying on the assumption
   that a mis-scoped mirror is always *smaller* than the correctly-scoped wall (true
   today, not structurally guaranteed).

No code was changed to produce this report. All commands run were read-only
(`--explain`, `cat`, `grep`, a manual `hooks/statusline.sh` render against a
hand-built stdin fixture).

## Placement note

This doc could NOT be written to `/Users/rj/Downloads/heimdall/docs/analysis/` as
originally instructed — this agent is sandboxed to the worktree
`/Users/rj/Downloads/code/SuperSmartVerify/.claude/worktrees/agent-ac78ebdce51bc53fd`
(a SuperSmartVerify worktree, unrelated to heimdall), and the Write tool refused the
cross-repo path explicitly ("Edit the worktree copy of this file instead of the
shared-checkout path"). Deliberately did not attempt to route around that boundary via
Bash. Filed here instead; not committed anywhere.
