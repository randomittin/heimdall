---
name: system-health
description: Suggest whether the machine needs a DISK or MEMORY cleanup — and catch the case where Heimdall ITSELF is the hog (runaway orphaned python from the presence keeper). Use when the machine is slow / swapping / laggy, disk or "System Data" is full, memory is exhausted, at the start of a long session, or when the user asks to free up space or RAM. Detection + suggestion only; hands off deep disk cleanup to the mac-deep-clean skill.
---

# system-health

A read-only advisor: **does this machine need a cleanup, and is Heimdall causing it?** It grades
disk + memory pressure, counts Heimdall's own leaked python, and SUGGESTS the fix. It never
deletes or kills anything unless you explicitly ask for the scoped self-reap.

Pairs with **mac-deep-clean** (the executor that actually reclaims disk). This skill is the
*trigger* — the thing that notices you need it.

## Why this exists (the lesson it encodes)

A long Heimdall session leaks background python: the presence keeper's `presence-doctor`
spawns `mock_cp.py` (a mock control-plane) children that get **orphaned to launchd (ppid 1)**
and are never reaped. One session accumulated ~**692** of them, pinning all 16G of RAM and
thrashing swap 17G/17G. `heimdall-gc` reaps orphaned keeper *pidfiles*, but NOT these
launchd-reparented *children* (nothing tracks them) — so they slip the collector. **Most of a
real cleanup session was just purging these do-nothing python procs.** This advisor is the
check that catches them early.

## Run it — the unified core (both axes at once)

`bin/heimdall-cleanup` is the ONE entrypoint that covers BOTH axes — MEMORY (RAM/swap +
hmd's orphan leak) and DISK (hmd's own reclaimable garbage). It ORCHESTRATES the two
reapers below; it never re-implements them. Reach for it first:

```bash
heimdall-cleanup           # report (DEFAULT, read-only): unified health + reclaimable-now MB
heimdall-cleanup --json    # {severity, memory, disk, procs, reclaim} for programmatic use
heimdall-cleanup --apply   # reap hmd's OWN garbage only (orphaned hmd python + gc disk)
heimdall-cleanup --deep    # SUGGEST-only handoff to mac-deep-clean (confirm-gated, nothing auto)
```

`report` is provably read-only (sysmon with no mutating flag + `gc run --dry-run` + read-only
probes) — the cc-selfheal lesson: a "status" that secretly mutates causes the error it exists
to prevent. It is wired into SessionStart/End via `--auto` (runs gc always; reaps orphaned hmd
python ONLY on a genuine runaway so a live keeper is never killed). Opt out with
`HEIMDALL_NO_CLEANUP=1` or `~/.heimdall/no-cleanup`.

### The underlying reapers (the core delegates to these — use directly for a single axis)

```bash
heimdall-sysmon            # MEMORY axis: human report + a SUGGESTION block; exit 0 ok / 1 warn / 2 critical
heimdall-sysmon --quiet    # print ONLY when action is advised (ideal at session start)
heimdall-sysmon --json     # {severity, disk, memory, procs, ...} for programmatic use
heimdall-gc run            # DISK axis: reap merged worktrees / temp / logs / retired claude versions
```

Three graded sections:

| Section | Signal | WARN / CRIT |
|---|---|---|
| **disk** | true free on `/System/Volumes/Data` (via `diskutil` — `df /` lies) | ≥85% used / ≥93% |
| **memory** | swap in use (`vm.swapusage`) + wired RAM (`vm_stat`) | swap ≥40% / ≥70%; wired ≥55% |
| **procs** | Heimdall's OWN orphaned python (`mock_cp.py` / `presence-doctor`, ppid 1) + any interpreter runaway | ≥20 orphans / ≥80; any interpreter ≥120 |

Overall exit code = the worst section. Thresholds override via `HMD_SYSMON_*` env vars.

## Interpret + suggest

- **procs WARN/CRIT** → Heimdall is leaking. Suggest the scoped self-reap (below). This is the
  single highest-value action — it's do-nothing python pinning RAM.
- **memory WARN/CRIT** → after reaping, wired RAM + swap only fully clear on **reboot** (killing
  procs does not free non-pageable wired memory). Print `sudo reboot` as a manual step.
- **disk WARN/CRIT** → hand off to **mac-deep-clean** (tiered, read-only investigation first,
  then deletes only caches / dead repos / SDK-simulator bloat).

Do NOT auto-delete or auto-reboot. Suggest; let the user confirm.

## The one mutating action — scoped self-reap

```bash
heimdall-sysmon --reap-hmd-orphans
```

Kills **only** procs that are (a) orphaned to launchd (ppid 1) **and** (b) carry Heimdall's own
signature (`mock_cp.py`, `presence-doctor`, or a heimdall-tagged python), then stops the
presence spawner so they don't respawn. A **foreign** python (real parent, or no heimdall
marker) is **never** matched. The detector and the reaper share ONE matcher (`--filter-orphans`
is that matcher exposed for testing), so what it counts is exactly what it would kill.

Safety: this only reaps Heimdall's OWN garbage. For anything foreign, or a full disk sweep,
defer to the user / mac-deep-clean. Wired RAM after a long uptime is reboot-only — say so.

## Optional: proactive nudge at session start

Wire a non-nagging advisory (prints only on WARN/CRIT) into your session start:

```bash
# in a SessionStart hook / shell rc:
heimdall-sysmon --quiet || true
```

Left opt-in (not auto-wired) so it never adds startup noise or a hook dependency you didn't ask
for.

## Verification

- [ ] `heimdall-sysmon` prints disk / memory / procs sections and a severity, exits 0/1/2.
- [ ] `heimdall-sysmon --json | jq .` is valid JSON with the three sections.
- [ ] `--filter-orphans` matches `mock_cp.py`/`presence-doctor` orphans but NOT a foreign
      python nor a non-orphan (proven by `test/heimdall-sysmon.test.sh`).
- [ ] A reap suggestion appears iff `procs` is WARN/CRIT; a mac-deep-clean suggestion iff `disk` is.
