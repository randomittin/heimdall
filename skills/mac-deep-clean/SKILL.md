---
name: mac-deep-clean
description: Deep-clean a macOS dev machine — reclaim disk (caches, dev-tool caches, dead repos, git worktrees, Android/Xcode/simulator bloat, System Data) and diagnose/fix memory exhaustion (runaway process leaks, swap thrashing, wired RAM). Use when disk is full, "System Data" is huge, the machine is swapping/slow, or the user asks to free up space or RAM.
---

# mac-deep-clean

Autonomous macOS storage + memory cleanup. Investigate first (read-only), present a tiered reclaimable map, delete only what's regenerable or user-approved. Destructive ops are irreversible — measure, confirm, then act.

Ships with Heimdall: invoke it as `hmd:mac-deep-clean` (a copy you installed by hand under `~/.claude/skills/mac-deep-clean/` is plain `mac-deep-clean`). `hmd:system-health` and `heimdall-cleanup --deep` notice the need and hand off here — they never delete anything outside Heimdall's own garbage; this skill is the confirm-gated executor.

## Golden rules
- **Measure before deleting.** Always `du -sh` / `df -h` before and after. Report reclaimed bytes.
- **Irreversible = confirm.** Deleting repos/files with uncommitted work needs explicit user naming. Never infer consent from background-task notifications.
- **Scope precisely.** `rm -rf` explicit paths only. Never `rm -rf` a parent when you mean a child. Verify exact version-dir names (Android SDK, NDK) before deleting "old" versions.
- **Caches regenerate; user data does not.** Keep: iMessage db, browser profiles, Notes, VSCode, source `.git`, loose documents. Delete: caches, build output, node_modules, old SDK versions, dead worktrees.
- **Delegate investigation to parallel read-only agents.** One agent per domain (repos / user Library / System Data). Spawn concurrently, `run_in_background: true`.

## macOS gotchas
- **`timeout` does not exist on macOS.** Use `run_in_background: true` or a background `&` + poll instead of `timeout N cmd`.
- **`df -h /` lies.** `/` is the sealed read-only system snapshot (a small, fixed-size volume). Real data lives on `/System/Volumes/Data`. Use `diskutil info /` → "Container Free Space" for true free.
- **"System Data" bucket** = swap + Preboot + caches + logs + diagnostics + purgeable. Not a folder — an aggregate.
- **`ps aux` RSS undercounts** (shared/compressed pages). For real memory use `top -l 1 -o mem` and `vm_stat`. Numbers in `vm_stat` end in `.` — strip with `sed 's/\.//'` before math.
- **`sudo -n true`** to test for cached sudo without prompting; if it fails, print the manual command instead of hanging.
- `pnpm store prune` / `go clean -cache` can hang — prefer `rm -rf ~/Library/Caches/{pnpm,go-build}` directly.

---

## PHASE 1 — Disk investigation (read-only, parallel agents)

Spawn 3 concurrent read-only agents:
1. **Repos** — skim a code dir: per-repo git state, merge-conflict markers, deps installed?, dual lockfiles, tracked build artifacts.
2. **User Library** — Android SDK, Xcode DerivedData/CoreSimulator, `~/Library/Caches`, Docker.raw, non-code `~/Downloads`, brew, Trash.
3. **System Data** — local Time Machine snapshots, swap/sleepimage, root `/Library`, `/private/var`, purgeable, APFS volumes.

Each returns a ranked table: `path | size | what | safe-to-delete | how-to-clean`.

## PHASE 2 — Present tiered map, get approval

- **Tier 1 — zero-risk caches** (auto-regenerate): browser caches, pkg-manager caches, updater caches.
- **Tier 2 — redundant dev** (re-downloadable): old SDK/NDK/build-tools/platform versions, non-code node_modules.
- **Tier 3 — state-wiping** (needs OK): emulator AVDs, iOS sim devices, app caches (Slack), Claude session history.
- **Tier 4 — sudo/reboot**: `xcrun simctl delete unavailable`, sleepimage, swap (reboot).

Run Tier 1+2 freely. Tier 3 per-item confirm. Tier 4 hand the exact sudo/reboot commands to the user.

## PHASE 3 — Cleanup commands

### Claude / Heimdall caches
Tier 1 — regenerable:
```bash
rm -rf ~/.claude/{paste-cache,image-cache,cache,shell-snapshots,debug,telemetry}
```
Tier 3 — session history, confirm first (this is what `--resume` and rewind read). Each project dir under `~/.claude/projects/` also holds `memory/` — your auto-memory, not a cache — so never `rm -rf` the projects dir; remove transcripts only:
```bash
find ~/.claude/projects -name '*.jsonl' -mtime +30 -print    # list first; append -delete only after the user OKs the list
rm -rf ~/.claude/file-history                                # edit snapshots behind rewind
```
KEEP: `~/.claude/{plugins,skills,agents,commands,settings.json}`.

### Dev-tool caches (safe, biggest wins)
```bash
rm -rf ~/.gradle/caches        # can be 10G+
rm -rf ~/.cache/uv             # uv cache clean is SLOW — rm -rf is faster
rm -rf ~/.npm/_cacache
rm -rf ~/.cache/{ms-playwright,huggingface,chroma,node}
rm -rf ~/Library/Caches/{Yarn,ms-playwright,pip,Homebrew,CocoaPods}
```

### Dead repos / accidental git
```bash
# accidental `git init` in a parent dir breaks `git status` for all subdirs w/o own .git
# symptom: fatal: not a git repository: .../<x>/.git/worktrees/<y>
# first prove it IS accidental — no commits and no remotes; anything else is a real repo, ask:
git -C <parent> log --oneline -1                       # fails ("does not have any commits yet") if accidental
git -C <parent> remote -v                              # empty if accidental
rm -rf <parent>/.git                                   # removes overlay; child repos' .git untouched

# a dead repo itself goes only when the user names it; check for unpushed work first:
git -C <repo> status --short
git -C <repo> log --branches --not --remotes --oneline
```

### Git worktrees (parallel-agent leftovers)
Heimdall's agent worktrees live under `<repo>/.claude/worktrees/agent-*`; other setups use sibling `<repo>-wt-*` dirs. For Heimdall's own, `heimdall-gc run` and `heimdall-reap-idle --apply` are safer first stops — they leave any worktree holding uncommitted or unmerged work alone. For the rest, enumerate from the parent repo instead of guessing from directory names:
```bash
git -C <parent-repo> worktree list
git -C <worktree-path> status --short                  # any output = uncommitted work: name it to the user first
# valid parent → clean unregister (refuses a dirty worktree; add --force only after the user OKs discarding it):
git -C <parent-repo> worktree remove <worktree-path>
git -C <parent-repo> worktree prune
# orphaned parent (parent repo deleted — `cat <worktree-path>/.git` names a gitdir that no longer exists) → just rm:
rm -rf <orphaned-worktree>
```

### Dual lockfile drift (npm + yarn both present)
```bash
# yarn project with stray package-lock.json → keep yarn.lock, remove the npm intruder
# 1. list first (read-only):
find <code-dir> -maxdepth 2 -name package-lock.json -execdir test -f yarn.lock \; -print
# 2. delete exactly that list, once the user has OK'd it:
find <code-dir> -maxdepth 2 -name package-lock.json -execdir test -f yarn.lock \; -print -delete
```

### Android SDK (verify versions first!)
```bash
ls ~/Library/Android/sdk/{ndk,system-images,build-tools,platforms}   # SEE what's there
rm -rf ~/Library/Android/sdk/ndk/<OLD_VERSION>                       # keep newest
rm -rf ~/Library/Android/sdk/system-images/<OLD_API>
rm -rf ~/Library/Android/sdk/build-tools/<OLD>
rm -rf ~/Library/Android/sdk/platforms/<OLD_API>
rm -rf ~/.android/avd/<NAME>.avd ~/.android/avd/<NAME>.ini           # emulator disk (9G+), wipes state
```

### Xcode / iOS simulators
```bash
xcrun simctl delete unavailable        # dead runtimes (run in background — can be slow)
xcrun simctl delete <DEVICE-UUID>      # specific device
# unmount stale runtime DMGs:
diskutil unmount force "/Library/Developer/CoreSimulator/Volumes/<vol>"
```

### System Data (mostly sudo/reboot)
```bash
diskutil info / | grep -i purgeable                    # true free space
tmutil listlocalsnapshots /                            # local TM snapshots (often the big culprit; delete with sudo tmutil deletelocalsnapshots <date>)
sudo pmset hibernatemode 0 && sudo rm /private/var/vm/sleepimage   # ~2G, if no hibernate
sudo reboot                                            # reclaims swap (VM volume) — the real fix
```

---

## PHASE 4 — Memory diagnosis + fix

When machine is slow / swapping:

```bash
# 1. Pressure snapshot
sysctl vm.swapusage                                    # swap used vs total
sysctl hw.memsize                                      # total RAM
memory_pressure | grep -i "free percentage"
vm_stat | sed 's/\.//' | awk '/page size of/{ps=$8} \
  /Pages free/{print "free "$3*ps/1e9"G"} \
  /Pages wired/{print "wired "$4*ps/1e9"G"} \
  /Pages occupied by compressor/{print "compressed "$5*ps/1e9"G"}'

# 2. Real top consumers (NOT ps RSS)
top -l 1 -n 15 -o mem -stats pid,mem,command

# 3. Runaway process detection — THE key check
for p in python3 node bun ruby java; do echo "$p: $(pgrep -x $p | wc -l)"; done
# hundreds of one proc type = a leak. Find the pattern:
ps aux | grep -w python3 | awk '{for(i=11;i<=NF;i++)printf "%s ",$i;print""}' | sort | uniq -c | sort -nr | head
# orphaned (reparented to launchd) = ppid 1:
ps -axo pid=,ppid=,command= | awk '$2==1 && /<pattern>/{print $1}'
```

### Kill a runaway (fast — avoid per-pid loops, they time out)
```bash
# preview the match first — a loose pattern kills things you meant to keep:
pgrep -fl '<pattern>'
# batch-collect PIDs in ONE ps pass, then xargs kill:
ps -axo pid=,ppid=,command= | awk '$2==1 && /<pattern>/ {print $1}' | xargs -r kill -9
# or by command match:
pkill -9 -f '<pattern>'
```
If the leak is Heimdall's own — orphaned `mock_cp.py` / `presence-doctor` python at ppid 1 — `heimdall-sysmon --reap-hmd-orphans` kills exactly those and stops their spawner; a foreign process is never matched.

### Find + kill the SPAWNER (else it respawns)
Killing leaked children isn't enough — find the daemon spawning them:
```bash
ps aux | grep -iE "<spawner-name>" | grep -v grep
pkill -9 -f '<spawner-name>'
# watch for respawn:
for i in 1 2 3; do sleep 5; echo "count: $(pgrep -f <pattern> | wc -l)"; done
```

### Wired memory
- Wired RAM (non-pageable kernel/driver) is **not freed by killing user procs**.
- High wired (>50% of RAM) after long uptime → **reboot is the only fix**.
- `sudo purge` frees inactive/cached, not wired.

---

## Verification checklist
- [ ] `df -h /` + `diskutil info / | grep purgeable` — before & after, report delta
- [ ] Every `rm -rf` path echoed + existence re-checked after
- [ ] Kept dirs confirmed intact (settings, active dbs, source `.git`, user data)
- [ ] Runaway proc count returned to baseline AND not respawning (watch 10-15s)
- [ ] Spawner daemon killed, not just children
- [ ] Handed user the exact sudo/reboot commands for wired RAM + swap + sleepimage
