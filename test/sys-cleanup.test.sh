#!/usr/bin/env bash
#
# sys-cleanup.test.sh — acceptance for bin/heimdall-cleanup, the UNIFIED memory+disk
# health CORE. It ORCHESTRATES sysmon (memory + hmd-orphan scope) and gc (disk); this
# suite proves the ORCHESTRATION is safe, not the reapers (they have their own suites).
#
#   bash test/sys-cleanup.test.sh    (exit 0 = all cases pass)
#
# THE SAFETY PROPERTIES the task demands, each planted with a fixture a regression flips:
#   · a FOREIGN (non-hmd) process is NEVER in the reap set, and NEVER signalled  (cases 2,3,7)
#   · an in-use file / retired version is NEVER deleted        (delegated to gc — case 6 asserts
#     the orchestrator drives gc in a mode that honors its proofs; gc's own suite plants the
#     live-holder fixtures)
#   · `report` (the DEFAULT) mutates NOTHING — no file removed, no process signalled  (case 4)
#   · the opt-out env AND marker fully disable the --auto path                        (case 8)
#   · reclaimed-MB math is correct on a KNOWN fixture                                 (case 5)
#
# PROVE-RED: run with SYS_CLEANUP_PROVE_RED=1 to point the orchestrator at a DELIBERATELY
# BROKEN matcher stub (one that matches a foreign pid). The scope + kill-scope cases MUST go
# red — proof they are capable of failing (conventions R6). CI runs the real binary (green).
#
# All process fixtures are synthetic `pid ppid command…` rows fed via HMD_CLEANUP_PS_ROWS and
# a recording kill-stub via HMD_CLEANUP_KILL_CMD: NO real process is ever signalled, and the
# real ~/.heimdall / ~/.local/share/claude are never touched (every path is a temp fixture).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
CLEAN="$REPO/bin/heimdall-cleanup"
GC="$REPO/bin/heimdall-gc"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$CLEAN" ] || { echo "FATAL: $CLEAN not executable"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sys-cleanup-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "sys-cleanup.test.sh"

# ── the sysmon the orchestrator scopes through ───────────────────────────────────
# CI: the real sysmon matcher. PROVE-RED: a broken stub that ALSO emits a foreign pid,
# so the scope/kill-scope assertions flip red — demonstrating the checks can fail.
if [ "${SYS_CLEANUP_PROVE_RED:-0}" = "1" ]; then
  cat > "$WORK/sysmon-broken" <<'EOF'
#!/usr/bin/env bash
# BROKEN: for --filter-orphans, print EVERY pid on stdin (matches foreign procs too).
case "${1:-}" in
  --filter-orphans) awk '{print $1}' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK/sysmon-broken"
  export HMD_CLEANUP_SYSMON="$WORK/sysmon-broken"
fi

# ── fixture: a mix of hmd orphans + foreign processes as `pid ppid command…` rows ─
# 100/101/102 = hmd's OWN launchd-orphaned python (ppid 1, hmd signature) — REAP TARGETS.
# 200 = a foreign user python (ppid 1, no hmd marker) — NEVER a target.
# 300 = a mock_cp.py with a REAL parent (ppid 501) — not orphaned — NEVER a target.
# 301 = a foreign training job (ppid 1) — NEVER a target.
cat > "$WORK/ps-rows" <<'ROWS'
100 1 /usr/bin/python3 /var/folders/x/mock_cp.py --port 1
101 1 python3 /Users/rj/Downloads/heimdall/bin/presence-doctor
102 1 /usr/bin/python3 /Users/rj/.heimdall/keeper/loop.py
200 1 /usr/bin/python3 /Users/rj/myapp/server.py
300 501 /usr/bin/python3 /var/folders/x/mock_cp.py
301 1 /usr/bin/python3 /Users/rj/work/train.py
ROWS

# a recording kill-stub: appends every pid it is asked to signal (proves the reap SCOPE).
cat > "$WORK/kill-stub" <<EOF
#!/usr/bin/env bash
for p in "\$@"; do echo "\$p" >> "$WORK/killed"; done
exit 0
EOF
chmod +x "$WORK/kill-stub"
: > "$WORK/killed"

# a gc that reaps a KNOWN-size fixture, so reclaimed-MB math is deterministic.
# temp root: one hmd-* file of exactly 2048 bytes, TTL 0 -> always reapable (=> ~2KB).
GTMP="$WORK/gctmp"; mkdir -p "$GTMP"
head -c 2048 /dev/zero > "$GTMP/hmd-fixture.tmp" 2>/dev/null
# versions fixture: a retired 3MB binary reapable via an lsof stub that reports NO holder.
GV="$WORK/versions"; GL="$WORK/locks"; GB="$WORK/bin/claude"; mkdir -p "$GV" "$GL" "$WORK/bin"
for v in 9.9.1 9.9.2; do head -c $((3*1024*1024)) /dev/zero > "$GV/$v"; done
touch -t 202607141200 "$GV/9.9.1"; touch -t 202607141201 "$GV/9.9.2"
ln -sf "$GV/9.9.2" "$GB"
cat > "$WORK/lsof-none" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/lsof-none"

# env that makes gc reap ONLY the fixtures above (KEEP=0 so the single retired 9.9.1 is reaped;
# 9.9.2 is the symlink target and is always kept). HMD_HOME points at an empty temp home so the
# real ~/.heimdall is never scanned. REPO points at a non-git dir so the worktree step is a no-op.
gc_env() {
  HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=0 \
  HMD_GC_CC_VERSIONS="$GV" HMD_GC_CC_BIN="$GB" HMD_GC_CC_LOCKS="$GL" \
  HMD_GC_CC_LSOF="$WORK/lsof-none" HMD_GC_CC_KEEP=0 \
  HEIMDALL_HOME="$WORK/home-empty" "$@"
}

# run the orchestrator with the process fixture + kill-stub + deterministic gc env.
run_clean() {
  gc_env env HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
    ${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
    bash "$CLEAN" --repo "$WORK/home-empty" "$@"
}

# ── 1. report runs, emits the unified sections, exits in {0,1,2} ─────────────────
mkdir -p "$WORK/home-empty"
out="$(run_clean report 2>&1)"; rc=$?
case "$rc" in 0|1|2) ok "report runs, exit in {0,1,2} (got $rc)";; *) bad "report unexpected exit $rc";; esac
for sec in memory procs disk reclaim; do
  grep -q "$sec" <<<"$out" && ok "report has a $sec section" || bad "report missing $sec section"
done

# ── 2. SCOPE: report counts EXACTLY the 3 hmd orphans, excludes all 3 foreign rows ─
js="$(run_clean --json 2>/dev/null)"
n="$(printf '%s' "$js" | sed -n 's/.*"hmd_orphans":\([0-9]*\).*/\1/p')"
if [ "$n" = "3" ]; then ok "orphan scope = 3 hmd-owned only (foreign 200/300/301 excluded)"
else bad "orphan scope wrong — want 3, got '$n' (a foreign proc leaked into the reap set)"; fi

# ── 3. KILL-SCOPE: --apply signals EXACTLY the 3 hmd pids, never a foreign one ────
: > "$WORK/killed"
run_clean --apply >/dev/null 2>&1
killed_sorted="$(sort -n "$WORK/killed" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
if [ "$killed_sorted" = "100 101 102" ]; then ok "reap signalled EXACTLY the 3 hmd orphans (got: $killed_sorted)"
else bad "reap kill-scope wrong — want '100 101 102' got '$killed_sorted'"; fi
for foreign in 200 300 301; do
  grep -qx "$foreign" "$WORK/killed" 2>/dev/null && bad "FOREIGN pid $foreign was signalled — must never touch a non-hmd proc" \
    || ok "foreign pid $foreign was NEVER signalled"
done

# ── 4. READ-ONLY: report mutates NOTHING (no kill, no file deleted) ──────────────
# plant a fresh temp fixture + fresh kill log, run report, assert both untouched.
head -c 4096 /dev/zero > "$GTMP/hmd-fixture.tmp"
: > "$WORK/killed"
run_clean report >/dev/null 2>&1
if [ -s "$WORK/killed" ]; then bad "report signalled a process — report MUST be read-only"
else ok "report signalled NOTHING (provably read-only on the process axis)"; fi
if [ -e "$GTMP/hmd-fixture.tmp" ]; then ok "report deleted NO file (gc driven in --dry-run)"
else bad "report DELETED a reclaimable file — report must never mutate disk"; fi

# ── 5. RECLAIMED-MB MATH on a known fixture ──────────────────────────────────────
# fixture: 2048B temp (=> 2KB, ceil(2/1024)=1MB) + one retired 3MB version = 4MB reclaimable.
# restore both fixtures (case 3's --apply reaped 9.9.1 + the temp), so the math is deterministic.
head -c 2048 /dev/zero > "$GTMP/hmd-fixture.tmp"
for v in 9.9.1 9.9.2; do head -c $((3*1024*1024)) /dev/zero > "$GV/$v"; done
touch -t 202607141200 "$GV/9.9.1"; touch -t 202607141201 "$GV/9.9.2"; ln -sf "$GV/9.9.2" "$GB"
js="$(run_clean --json 2>/dev/null)"
disk_mb="$(printf '%s' "$js" | sed -n 's/.*"disk_mb":\([0-9]*\).*/\1/p')"
temp_kb="$(printf '%s' "$js" | sed -n 's/.*"temp_kb":\([0-9]*\).*/\1/p')"
cc_mb="$(printf '%s' "$js" | sed -n 's/.*"cc_mb":\([0-9]*\).*/\1/p')"
if [ "$temp_kb" = "2" ] && [ "$cc_mb" = "3" ] && [ "$disk_mb" = "4" ]; then
  ok "reclaimed-MB math correct (2KB temp -> 1MB + 3MB version = 4MB; got disk_mb=$disk_mb)"
else bad "reclaimed-MB math wrong — want temp_kb=2 cc_mb=3 disk_mb=4, got temp_kb=$temp_kb cc_mb=$cc_mb disk_mb=$disk_mb"; fi

# ── 6. IN-USE PROTECTION delegated to gc: a version with a LIVE lsof holder survives ─
# The orchestrator drives gc, which keeps any version an lsof stub reports as held. Prove
# the orchestrator does not bypass that: point gc at an lsof stub that reports 9.9.1 held.
head -c $((3*1024*1024)) /dev/zero > "$GV/9.9.1"   # restore (case 5's apply may have reaped it)
cat > "$WORK/lsof-holds" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in *9.9.1) echo 424242 ;; esac
exit 0
EOF
chmod +x "$WORK/lsof-holds"
HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=99999 \
HMD_GC_CC_VERSIONS="$GV" HMD_GC_CC_BIN="$GB" HMD_GC_CC_LOCKS="$GL" \
HMD_GC_CC_LSOF="$WORK/lsof-holds" HMD_GC_CC_KEEP=0 HMD_GC_LIVE_PIDS="424242" \
HEIMDALL_HOME="$WORK/home-empty" \
HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
bash "$CLEAN" --apply --repo "$WORK/home-empty" >/dev/null 2>&1
if [ -e "$GV/9.9.1" ]; then ok "an in-use retired version (live lsof holder) is NEVER deleted"
else bad "an in-use version was deleted — orchestrator bypassed gc's lsof proof"; fi

# ── 7. --deep reaps NOTHING (suggest-only handoff) ───────────────────────────────
head -c 2048 /dev/zero > "$GTMP/hmd-fixture.tmp"; : > "$WORK/killed"
out="$(run_clean --deep 2>&1)"
if [ -e "$GTMP/hmd-fixture.tmp" ] && [ ! -s "$WORK/killed" ] && grep -q "mac-deep-clean" <<<"$out"; then
  ok "--deep is suggest-only (deletes nothing, signals nothing, names mac-deep-clean)"
else bad "--deep mutated something or omitted the handoff: killed=$(cat "$WORK/killed" 2>/dev/null) out=$out"; fi

# ── 8. OPT-OUT fully disables the --auto path (env AND marker) ────────────────────
# Force a runaway (>= CRIT via a low threshold) so --auto WOULD reap; assert opt-out stops it.
: > "$WORK/killed"
HMD_SYSMON_ORPHAN_CRIT=1 HEIMDALL_NO_CLEANUP=1 \
HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=0 HMD_GC_CC_VERSIONS="$WORK/none" \
HEIMDALL_HOME="$WORK/home-empty" \
HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
bash "$CLEAN" --auto --repo "$WORK/home-empty" >/dev/null 2>&1
if [ ! -s "$WORK/killed" ] && [ -e "$GTMP/hmd-fixture.tmp" ]; then ok "HEIMDALL_NO_CLEANUP=1 fully disables --auto (no reap, no disk sweep)"
else bad "opt-out env ignored — --auto reaped despite HEIMDALL_NO_CLEANUP=1"; fi
# marker file variant
: > "$WORK/killed"; mkdir -p "$WORK/home-optout"; : > "$WORK/home-optout/no-cleanup"
HMD_SYSMON_ORPHAN_CRIT=1 HEIMDALL_HOME="$WORK/home-optout" \
HMD_GC_TMP_ROOTS="$GTMP" HMD_GC_TEMP_TTL_MIN=0 HMD_GC_CC_VERSIONS="$WORK/none" \
HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
bash "$CLEAN" --auto --repo "$WORK/home-optout" >/dev/null 2>&1
if [ ! -s "$WORK/killed" ]; then ok "~/.heimdall/no-cleanup marker fully disables --auto"
else bad "opt-out marker ignored — --auto reaped despite the no-cleanup file"; fi

# ── 9. --auto WITHOUT opt-out and BELOW crit does NOT kill (protects live keeper) ─
# 3 orphans < default CRIT(80): --auto must NOT reap (a normal session's keeper survives).
: > "$WORK/killed"
gc_env env HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
  ${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
  bash "$CLEAN" --auto --repo "$WORK/home-empty" >/dev/null 2>&1
if [ ! -s "$WORK/killed" ]; then ok "--auto below ORPHAN_CRIT reaps NO process (live keeper protected)"
else bad "--auto killed below the runaway threshold — could kill a live session's keeper: $(cat "$WORK/killed")"; fi

# ── 10. --auto ON a runaway DOES reap (the 692-orphan emergency) ─────────────────
: > "$WORK/killed"
HMD_SYSMON_ORPHAN_CRIT=1 \
gc_env env HMD_CLEANUP_PS_ROWS="$WORK/ps-rows" HMD_CLEANUP_KILL_CMD="$WORK/kill-stub" \
  ${HMD_CLEANUP_SYSMON:+HMD_CLEANUP_SYSMON="$HMD_CLEANUP_SYSMON"} \
  bash "$CLEAN" --auto --repo "$WORK/home-empty" >/dev/null 2>&1
killed_sorted="$(sort -n "$WORK/killed" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
if [ "$killed_sorted" = "100 101 102" ]; then ok "--auto on a runaway reaps EXACTLY the hmd orphans"
else bad "--auto runaway reap wrong — want '100 101 102' got '$killed_sorted'"; fi

# ── 11. --deep's handoff HONESTLY reflects whether mac-deep-clean is actually installed ──
# mac-deep-clean is a SEPARATE, user-installed skill, never bundled with heimdall — pointing
# at it when it's absent is an overclaim (the launch-audit lesson). Isolate both branches with
# their own HOME/REPO fixtures so the result never depends on this machine's real state.
mkdir -p "$WORK/home-with-mdc/.claude/skills/mac-deep-clean" "$WORK/proj-no-mdc"
printf -- '---\nname: mac-deep-clean\n---\nfixture\n' > "$WORK/home-with-mdc/.claude/skills/mac-deep-clean/SKILL.md"
mkdir -p "$WORK/home-no-mdc"

out_has="$(HOME="$WORK/home-with-mdc" bash "$CLEAN" --deep --repo "$WORK/proj-no-mdc" 2>&1)"
printf '%s\n' "$out_has" | grep -q "invoke the 'mac-deep-clean' skill" \
  && ok "--deep: skill installed (user-level) -> handoff names it" \
  || bad "--deep: skill installed but handoff text missing: $out_has"

out_no="$(HOME="$WORK/home-no-mdc" bash "$CLEAN" --deep --repo "$WORK/proj-no-mdc" 2>&1)"
if printf '%s\n' "$out_no" | grep -q "invoke the 'mac-deep-clean' skill"; then
  bad "--deep: skill NOT installed but handoff still tells the user to invoke it (overclaim)"
else
  ok "--deep: skill not installed -> no overclaim in the handoff text"
fi
printf '%s\n' "$out_no" | grep -q 'heimdall-cleanup --apply' \
  && ok "--deep: absent-skill fallback still points at hmd's own safe subset" \
  || bad "--deep: absent-skill fallback missing the --apply pointer: $out_no"

echo
printf 'sys-cleanup: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
