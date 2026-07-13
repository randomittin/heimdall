#!/usr/bin/env bash
# test/heimdall-gc.test.sh — falsifiable acceptance for bin/heimdall-gc.
#
# heimdall-gc auto-frees hmd's resource leftovers on a schedule (SessionStart quick,
# SessionEnd full, throttled keeper beat). Its ONE danger is deleting something it
# must not — a secret, a LIVE session's artifact, or unmerged work. So every proof
# here is built to CATCH the collector reaping something it must keep:
#
#   T (temp TTL)      an OLD /tmp/hmd-* file (past TTL) is reaped; a FRESH one is KEPT.
#   L (live session)  an OLD statusline temp keyed by a LIVE session (a live keeper
#                     pidfile names an alive pid) is KEPT despite being past TTL.
#   S (secrets)       team.json / *.seed / a ledger status.json / pki are NEVER
#                     deleted even when they sit in a swept dir past TTL.
#   C (cache TTL)     an OLD .sig sigil-cache + vis-cache entry is reaped; a FRESH
#                     one is KEPT; the self-heal .srcver sidecar is preserved.
#   G (logs)          an oversize log is ROTATED (kept, truncated); an old small log
#                     is deleted; a fresh log is kept.
#   P (orphan procs)  a DEAD-pid keeper pidfile is reaped; a LIVE keeper pidfile
#                     (mock kill -0 says alive + cmd is a heimdall keeper) is KEPT —
#                     never killed, its pidfile never removed (removing it would soft-
#                     stop a live keeper).
#   W (worktrees)     a MERGED agent worktree is reaped via heimdall-reap-idle; an
#                     UNMERGED one is KEPT (delegates, never duplicates the logic).
#   R (run)           `run` is idempotent (a 2nd run exits 0) and NON-FATAL (a broken
#                     sub-step never aborts the others) and prints a receipt of counts.
#
# Hermetic: HEIMDALL_HOME + HEIMDALL_KEEPER_DIR + HMD_GC_TMP_ROOTS point at a throwaway
# sandbox (NEVER the real ~/.heimdall or /tmp); liveness + proc-cmd are mocked via
# HMD_GC_LIVE_PIDS + HMD_GC_PROC_CMD; no process is ever really killed; no network.
#
# Exit 0 = every proof holds. Non-zero = a regression (prints which).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GC="$ROOT/bin/heimdall-gc"

[ -x "$GC" ] || { echo "FATAL: $GC not executable" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-gc-test.XXXXXX")"
trap 'git -C "$WORK/repo" worktree prune 2>/dev/null; rm -rf "$WORK"' EXIT

OLD='202401010000'   # Jan 2024 — past every TTL (temp 60m, cache 24h, log 168h).

# ── sandbox runtime home (never the real ~/.heimdall) ───────────────────────────
HOME_DIR="$WORK/home"
KEEPER_DIR="$HOME_DIR/presence-keeper"
SIGIL="$HOME_DIR/.sigil-cache"
VIS="$HOME_DIR/vis-cache"
LOGS="$HOME_DIR/logs"
LEDGER="$HOME_DIR/ledger"
PKI="$HOME_DIR/pki"
TMPR="$WORK/tmp"
mkdir -p "$KEEPER_DIR" "$SIGIL" "$VIS" "$LOGS" "$LEDGER" "$PKI" "$TMPR"

export HEIMDALL_HOME="$HOME_DIR"
export HEIMDALL_KEEPER_DIR="$KEEPER_DIR"
export HMD_GC_TMP_ROOTS="$TMPR"
# small cap so an oversize log is easy to build.
export HMD_GC_LOG_MAX_BYTES=50

# ── keeper pidfiles: one dead, one live ─────────────────────────────────────────
DEAD_PID=4000001         # NOT alive (absent from HMD_GC_LIVE_PIDS)
LIVE_PID=4000002         # alive + a genuine heimdall keeper
printf '%s\n' "$DEAD_PID" > "$KEEPER_DIR/proj__deadsess.pid"
printf '%s\n' "$LIVE_PID" > "$KEEPER_DIR/proj__livesess.pid"
export HMD_GC_LIVE_PIDS="$LIVE_PID"
PROC_STUB="$WORK/proc-cmd.sh"
cat > "$PROC_STUB" <<PS
#!/usr/bin/env bash
# mock ps -o command= -p <pid>: the live pid is a genuine heimdall keeper loop.
case "\$1" in
  $LIVE_PID) echo "heimdall-presence keeper-loop --pidfile /x --interval 20" ;;
  *) echo "" ;;
esac
PS
chmod +x "$PROC_STUB"
export HMD_GC_PROC_CMD="$PROC_STUB"

# ── temp files (TTL + live-session-keyed) ───────────────────────────────────────
touch "$TMPR/hmd-statusline-ledger-deadsess"; touch -t "$OLD" "$TMPR/hmd-statusline-ledger-deadsess"
touch "$TMPR/hmd-statusline-ledger-livesess"; touch -t "$OLD" "$TMPR/hmd-statusline-ledger-livesess"
touch "$TMPR/hmd-bar";                          touch -t "$OLD" "$TMPR/hmd-bar"
touch "$TMPR/hmd-fresh"    # now — under TTL

# ── secrets that MUST survive even inside swept dirs ────────────────────────────
printf '{"team_secret":"s3cr3t"}\n' > "$SIGIL/team.json"; touch -t "$OLD" "$SIGIL/team.json"
printf 'SEED\n'                      > "$VIS/agent.seed";   touch -t "$OLD" "$VIS/agent.seed"
printf 'REALSEED\n'                  > "$PKI/haid.seed";    touch -t "$OLD" "$PKI/haid.seed"
printf '{"team_secret":"real"}\n'    > "$HOME_DIR/team.json"
printf '{"verdict":"x"}\n'           > "$LEDGER/status.json"; touch -t "$OLD" "$LEDGER/status.json"

# ── cache entries (old reaped, fresh + .srcver kept) ────────────────────────────
touch "$SIGIL/old.sig";   touch -t "$OLD" "$SIGIL/old.sig"
touch "$SIGIL/fresh.sig"
touch "$SIGIL/.srcver";   touch -t "$OLD" "$SIGIL/.srcver"
touch "$VIS/old_project"; touch -t "$OLD" "$VIS/old_project"

# ── logs (oversize rotated, old small deleted, fresh kept) ──────────────────────
printf 'A%.0s' $(seq 1 200) > "$LOGS/big.log"        # >50B, fresh -> rotate
printf 'x\n'                > "$LOGS/old.log"; touch -t "$OLD" "$LOGS/old.log"
printf 'y\n'                > "$LOGS/fresh.log"       # small + fresh -> keep

# ── worktree fixture (merged reaped, unmerged kept) ─────────────────────────────
R="$WORK/repo"
if command -v git >/dev/null 2>&1; then
  git init -q "$R"
  git -C "$R" config user.email t@t.dev; git -C "$R" config user.name tester
  git -C "$R" config commit.gpgsign false
  echo base > "$R/base.txt"; git -C "$R" add -A; git -C "$R" commit -qm base; git -C "$R" branch -M main
  git -C "$R" worktree add -q -b wt-merged   "$R/.claude/worktrees/agent-merged"   main
  git -C "$R" worktree add -q -b wt-unmerged "$R/.claude/worktrees/agent-unmerged" main
  echo precious > "$R/.claude/worktrees/agent-unmerged/f.txt"
  git -C "$R/.claude/worktrees/agent-unmerged" add -A
  git -C "$R/.claude/worktrees/agent-unmerged" commit -qm "unmerged work"
fi

echo "── run the full collector ──────────────────────────────────────────────"
RECEIPT="$("$GC" run --repo "$R" 2>/tmp/hmd-gc-test.stderr.$$)"; RC=$?
rm -f /tmp/hmd-gc-test.stderr.$$
[ "$RC" = 0 ] && ok "run exited 0 (non-fatal)" || bad "run exited $RC (should be 0)"

# T — temp TTL
[ ! -e "$TMPR/hmd-bar" ] && ok "T: old /tmp/hmd-* reaped" || bad "T: old /tmp/hmd-bar survived"
[ -e "$TMPR/hmd-fresh" ] && ok "T: fresh /tmp/hmd-* kept" || bad "T: fresh /tmp/hmd-fresh was deleted"
[ ! -e "$TMPR/hmd-statusline-ledger-deadsess" ] \
  && ok "T: old dead-session statusline temp reaped" || bad "T: dead-session temp survived"

# L — live session artifact kept despite age
[ -e "$TMPR/hmd-statusline-ledger-livesess" ] \
  && ok "L: old temp keyed by a LIVE session KEPT (never reap a live session's artifact)" \
  || bad "L: FALSIFIER — reaped a LIVE session's statusline temp"

# S — secrets survive
[ -e "$SIGIL/team.json" ] && ok "S: team.json in a swept dir KEPT" || bad "S: team.json DELETED"
[ -e "$VIS/agent.seed" ]  && ok "S: *.seed in a swept dir KEPT"    || bad "S: agent.seed DELETED"
[ -e "$PKI/haid.seed" ]   && ok "S: pki/*.seed KEPT"               || bad "S: pki seed DELETED"
[ -e "$HOME_DIR/team.json" ] && ok "S: home team.json KEPT"        || bad "S: home team.json DELETED"
[ -e "$LEDGER/status.json" ] && ok "S: ledger status.json KEPT (active state)" || bad "S: ledger status.json DELETED"

# C — cache TTL
[ ! -e "$SIGIL/old.sig" ] && ok "C: old sigil .sig reaped" || bad "C: old.sig survived"
[ -e "$SIGIL/fresh.sig" ] && ok "C: fresh sigil .sig kept" || bad "C: fresh.sig deleted"
[ -e "$SIGIL/.srcver" ]   && ok "C: sigil .srcver sidecar preserved" || bad "C: .srcver deleted"
[ ! -e "$VIS/old_project" ] && ok "C: old vis-cache entry reaped" || bad "C: old vis entry survived"

# G — logs
[ -e "$LOGS/big.log" ]     && ok "G: oversize log rotated in place (kept)" || bad "G: oversize log deleted"
[ ! -e "$LOGS/old.log" ]   && ok "G: old small log deleted" || bad "G: old.log survived"
[ -e "$LOGS/fresh.log" ]   && ok "G: fresh log kept" || bad "G: fresh.log deleted"

# P — orphan procs
[ ! -e "$KEEPER_DIR/proj__deadsess.pid" ] \
  && ok "P: DEAD keeper pidfile reaped" || bad "P: dead keeper pidfile survived"
[ -e "$KEEPER_DIR/proj__livesess.pid" ] \
  && ok "P: LIVE keeper pidfile KEPT (never soft-stop a live keeper)" \
  || bad "P: FALSIFIER — removed a LIVE keeper's pidfile"

# W — worktrees
if command -v git >/dev/null 2>&1; then
  [ ! -d "$R/.claude/worktrees/agent-merged" ] \
    && ok "W: merged agent worktree reaped (delegated to reap-idle)" \
    || bad "W: merged worktree survived"
  if [ -d "$R/.claude/worktrees/agent-unmerged" ] \
     && grep -q precious "$R/.claude/worktrees/agent-unmerged/f.txt" 2>/dev/null; then
    ok "W: UNMERGED agent worktree KEPT (unmerged work is never destroyed)"
  else
    bad "W: FALSIFIER — reaped UNMERGED work"
  fi
fi

# receipt
echo "$RECEIPT" | grep -qiE 'freed|worktree|temp' \
  && ok "receipt reports what was freed: $RECEIPT" || bad "no receipt of counts printed"

echo "── R: idempotent second run ────────────────────────────────────────────"
if "$GC" run --repo "$R" >/dev/null 2>&1; then ok "second run exited 0 (idempotent)"; else bad "second run errored"; fi

echo "── R: non-fatal — a broken sub-step never aborts the others ─────────────"
touch "$TMPR/hmd-nonfatal"; touch -t "$OLD" "$TMPR/hmd-nonfatal"
HMD_GC_BREAK=worktrees "$GC" run --repo "$R" >/dev/null 2>&1; NF_RC=$?
[ "$NF_RC" = 0 ] && ok "run with a broken worktree step still exited 0" || bad "broken sub-step aborted run (rc=$NF_RC)"
[ ! -e "$TMPR/hmd-nonfatal" ] \
  && ok "temp sweep still ran despite the broken worktree step" \
  || bad "a broken sub-step aborted the later temp sweep"

echo "── SYMLINKED temp root (macOS /tmp -> /private/tmp) is still swept ──────"
# find /symlink -maxdepth 1 refuses to descend a command-line symlink; gc must
# normalize with a trailing slash so a symlinked temp root is still swept.
REALTMP="$WORK/realtmp"; LINKTMP="$WORK/linktmp"
mkdir -p "$REALTMP"; ln -s "$REALTMP" "$LINKTMP"
touch "$REALTMP/hmd-symlinked"; touch -t "$OLD" "$REALTMP/hmd-symlinked"
HMD_GC_TMP_ROOTS="$LINKTMP" "$GC" temp >/dev/null 2>&1
[ ! -e "$REALTMP/hmd-symlinked" ] \
  && ok "old temp under a SYMLINKED root was reaped (trailing-slash descend)" \
  || bad "FALSIFIER — a symlinked temp root (macOS /tmp) was NOT swept"

echo "── quick mode skips worktrees but still sweeps temp ────────────────────"
touch "$TMPR/hmd-quick"; touch -t "$OLD" "$TMPR/hmd-quick"
"$GC" run --quick >/dev/null 2>&1; Q_RC=$?
[ "$Q_RC" = 0 ] && ok "run --quick exited 0" || bad "run --quick errored"
[ ! -e "$TMPR/hmd-quick" ] && ok "quick mode swept temp files" || bad "quick mode did not sweep temp"

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  ALL GREEN"; exit 0; } || { echo "  REGRESSION"; exit 1; }
