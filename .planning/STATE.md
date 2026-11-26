# State — 2026-11-26

- **Phase:** idle — 2.4.16 released (GitHub ccb9d1b1, site e3ed900); npm pending operator.
- **Done:** 2.4.14 (save absorbs continue; compact-window --bash-cap; ship.sh pins site), 2.4.15 (ship fetch guard, relay-client shutdown join + ghost fix 522e3019, journal prefix, read-dedup outline), 2.4.16 (/hmd:save auto-compacts via project .claude/settings.local.json trigger; sweep reds fixed eb4ca8de, 97aa9527).
- **In progress:** none.
- **Next:** operator npm publish 2.4.16; operator live /hmd:save auto-compact test; backlog (compact-now expiry check on UserPromptSubmit/Stop MEDIUM; 2.4.15 LOWs).
- **Blockers:** disk ~10.1% free = at hook floor; sweeps need inline HMD_MIN_FREE_PCT=8.
- **Decisions:** compact-now arms project settings.local.json only (review HIGH), consent per repo; release path = one review, cached sweep, --failed after red.
- **Key files:** bin/heimdall-compact-window, bin/lib/hmd_continue.py, commands/save.md, hooks/hooks.json, release/ship.sh, test/lib/view_scenarios.py.
