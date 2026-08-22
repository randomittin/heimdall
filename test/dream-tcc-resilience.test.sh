#!/usr/bin/env bash
# test/dream-tcc-resilience.test.sh — acceptance for the TCC-RESILIENT nightly /dream.
#
# THE INCIDENT THIS SUITE ENCODES. The owner's nightly LaunchAgent failed 10 CONSECUTIVE
# NIGHTS and he learned of it only by opening the log by hand. Every line read:
#   /Applications/Xcode.app/.../python3: can't open file
#     '/Users/rj/Downloads/heimdall/bin/heimdall-dream': [Errno 1] Operation not permitted
# The repo lives under ~/Downloads, which macOS TCC protects. A LaunchAgent holds no TCC
# grant, so launchd could not read the repo AT ALL — not the script, not the directory.
#
# MEASURED, NOT ASSUMED. A probe LaunchAgent whose program was /bin/sh at a NON-protected
# path was denied identically (read file / list repo / list ~/Downloads all EPERM) while a
# write to ~/.heimdall succeeded. So the denial follows the launchd JOB, not the location
# of the interpreter — which falsifies "just move the script" and "just relocate the
# output" as fixes, and is why the runner below DETECTS and REPORTS rather than pretending.
#
# TWO FAILURES, BOTH FIXED HERE:
#   (a) the job could not run at all under TCC, and
#   (b) NOTHING SAID SO — it wrote 12 error lines nobody reads, for 10 nights. A scheduled
#       job that fails invisibly is indistinguishable from one that never ran. (b) is the
#       worse bug and is what §2-§6 pin down.
#
# FALSIFIABLE claims proven:
#   (1) RUNNER on a REACHABLE repo execs the real dream and a REAL dated report appears;
#       status records result=ok. (The fix must not break the working case.)
#   (2) RUNNER on a DENIED repo NEVER exits 0 — it records result=blocked with the verbatim
#       OS error and exits EX_TEMPFAIL(75), so the failure is machine-detectable.
#   (3) NOTICE is LOUD when the last run was TCC-blocked: it names TCC, names the denied
#       path, and prints a runnable remedy.
#   (4) NOTICE is SILENT once today's report exists (no permanent nag on a healthy repo).
#   (5) NOTICE is LOUD on an ARTIFACT GAP with NO status file at all — the backstop for the
#       exact 10-night silence, where the job died before it could report anything.
#   (6) NOTICE SELF-CLEARS: a blocked status already superseded by a report goes quiet.
#   (7) SCHEDULE pins ProgramArguments[1] at a runner OUTSIDE the TCC-protected repo,
#       ProgramArguments[0] at a named interpreter (the private hmd-dream identity, or an
#       honest /bin/bash fallback) rather than relying on a shebang launchd's minimal PATH
#       may not resolve, still encodes the full overnight command, and never sets
#       WorkingDirectory to a path the job cannot getcwd() (the source of the
#       'shell-init: getcwd' lines in the real log).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUNNER="$ROOT/bin/heimdall-dream-runner"
NOTICE="$ROOT/bin/heimdall-dream-notice"
SCHED="$ROOT/bin/heimdall-dream-schedule"
DREAM="$ROOT/bin/heimdall-dream"
PY="$(command -v python3 || command -v python)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

[ -x "$RUNNER" ] || { echo "FATAL: $RUNNER not executable" >&2; exit 2; }
[ -x "$NOTICE" ] || { echo "FATAL: $NOTICE not executable" >&2; exit 2; }
[ -x "$SCHED" ]  || { echo "FATAL: $SCHED not executable" >&2; exit 2; }
[ -x "$DREAM" ]  || { echo "FATAL: $DREAM not executable" >&2; exit 2; }

WORK="$(mktemp -d -t "dream-tcc-test.$(printf 'X%.0s' 1 2 3 4 5 6)")"
# chmod the denied fixture back so rm -rf can always clean up.
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Hermetic home for the cases that do NOT set one per-invocation — case (1) especially.
# Case (1) is the SUCCESS path, so unredirected it stamps the real
# ~/.heimdall/liveness/dream.json with reached=yes for $WORK/okrepo. On this machine
# dream has been TCC-blocked for 27 days, so that receipt would report the dead
# subsystem as alive — the exact bug the receipt exists to catch, forged by its own test.
# Per-invocation HEIMDALL_HOME assignments below still override this.
export HEIMDALL_HOME="$WORK/home"

# dream dates its reports in UTC (time.gmtime), so every date in this suite is UTC.
TODAY="$(date -u +%Y-%m-%d)"

echo "dream TCC resilience acceptance"
echo "=============================="

# ── (1) RUNNER, reachable repo: the working case still works ─────────────────────
OKREPO="$WORK/okrepo"; mkdir -p "$OKREPO/.planning"
OKSTATUS="$WORK/ok-status.json"
run_rc=0
"$RUNNER" --dream "$DREAM" --repo "$OKREPO" --status "$OKSTATUS" run --overnight \
  >"$WORK/ok.log" 2>&1 || run_rc=$?

if [ "$run_rc" = 0 ] && [ -f "$OKREPO/.planning/dream/$TODAY.md" ]; then
  ok "(1) reachable repo: runner execs dream, REAL report at .planning/dream/$TODAY.md"
else
  bad "(1) reachable repo produced no report (rc=$run_rc); log: $(cat "$WORK/ok.log" 2>/dev/null | head -3)"
fi

if [ -f "$OKSTATUS" ] && grep -q '"result": "ok"' "$OKSTATUS"; then
  ok "(1) status records result=ok"
else
  bad "(1) status did not record ok: $(cat "$OKSTATUS" 2>/dev/null | head -5)"
fi

# ── (2) RUNNER, denied repo: NOW IT RUNS ANYWAY ──────────────────────────────────
# A user-owned dir at mode 000 yields a REAL kernel access denial without root. TCC's
# EPERM and this EACCES are the same class of event to the runner: the repo cannot be
# read at all.
#
# THIS CONTRACT DELIBERATELY INVERTED. It used to assert exit 75 + result=blocked,
# because dream kept its state inside the repo and genuinely could not run without it.
# It no longer does — the state lives under $HEIMDALL_HOME (bin/lib/dream_data.py), so a
# denied repo costs the run nothing it needs. Continuing to fail here would keep the
# nightly job dead for a reason that has been removed. The loud-failure path is NOT
# weakened by this: case (2b) below proves exit 75 still fires when dream truly cannot
# run, which is the case that mattered all along.
DENIED="$WORK/denied"; mkdir -p "$DENIED/.planning"
DENIED_HOME="$WORK/denied-home"; mkdir -p "$DENIED_HOME"
chmod 000 "$DENIED"
DSTATUS="$WORK/denied-status.json"
drc=0
HEIMDALL_HOME="$DENIED_HOME" "$RUNNER" --dream "$DREAM" --repo "$DENIED" \
  --status "$DSTATUS" run --overnight >"$WORK/denied.log" 2>&1 || drc=$?
chmod 755 "$DENIED"

if [ "$drc" = 0 ]; then
  ok "(2) denied repo now RUNS — the relocated state dir needs no grant"
else
  bad "(2) denied repo exit was $drc, expected 0: $(head -5 "$WORK/denied.log")"
fi

# THE ARTIFACT IS THE PROOF. A report on disk, written by a run that could not read one
# byte of the repo, is the whole claim of this change.
DENIED_REPORT="$(HEIMDALL_HOME="$DENIED_HOME" "$PY" \
  "$ROOT/bin/lib/dream_data.py" planning --repo "$DENIED" 2>/dev/null)/dream/$TODAY.md"
if [ -s "$DENIED_REPORT" ]; then
  ok "(2) the denied-repo run produced a real report at the relocated root"
else
  bad "(2) no report at $DENIED_REPORT"
fi

# and it is HONEST about the denial — an ok that hid it would read as "the grant landed"
if grep -q '"repo_reachable": "no"' "$DSTATUS"; then
  ok "(2) status records repo_reachable=no — success is not mistaken for a grant"
else
  bad "(2) status hid the denial: $(cat "$DSTATUS" 2>/dev/null | head -10)"
fi

if [ -f "$DSTATUS" ] && grep -q '"result": "ok"' "$DSTATUS"; then
  ok "(2) status records result=ok for a run that genuinely produced its report"
else
  bad "(2) status did not record ok: $(cat "$DSTATUS" 2>/dev/null | head -8)"
fi

# nothing may be written INTO the denied repo — the point is that it is never touched
if [ ! -f "$DENIED/.planning/dream/$TODAY.md" ]; then
  ok "(2) FALSIFIER: nothing was written into the denied repo"
else
  bad "(2) the run wrote into the denied repo"
fi

# ── (2b) THE LOUD PATH SURVIVES: dream itself unreachable is still a hard failure ──
# Relaxing the repo probe must not relax the one that matters. The dream script IS the
# program; if it cannot be read, nothing ran, and that is the silent death this runner
# was built to make loud. Same fixture shape as the old (2), pointed at the right target.
GONE="$WORK/gone-dream"
GSTATUS="$WORK/gone-status.json"
grc=0
HEIMDALL_HOME="$DENIED_HOME" "$RUNNER" --dream "$GONE" --repo "$WORK" \
  --status "$GSTATUS" run --overnight >"$WORK/gone.log" 2>&1 || grc=$?

if [ "$grc" = 75 ]; then
  ok "(2b) an unreadable dream still exits 75 (EX_TEMPFAIL) — never a silent 0"
else
  bad "(2b) unreadable dream exit was $grc, expected 75"
fi
if [ -f "$GSTATUS" ] && grep -q '"result": "blocked"' "$GSTATUS"; then
  ok "(2b) status still records result=blocked when nothing could run"
else
  bad "(2b) status did not record blocked: $(cat "$GSTATUS" 2>/dev/null | head -8)"
fi
if grep -q 'denied_path' "$GSTATUS" && grep -qi 'no such file\|permitted\|denied' "$GSTATUS"; then
  ok "(2b) status preserves the denied path and the verbatim OS error"
else
  bad "(2b) status lost the denial detail: $(cat "$GSTATUS" 2>/dev/null | head -8)"
fi
if grep -qi 'BLOCKED' "$WORK/gone.log"; then
  ok "(2b) runner still shouts BLOCKED into the dream log"
else
  bad "(2b) runner failed quietly: $(head -3 "$WORK/gone.log")"
fi

# ── (2c/2d) THE PRODUCTION FAILURE MODE, REPRODUCED WITH A REAL EPERM ────────────
#
# WHY THE chmod 000 FIXTURE ABOVE IS NOT ENOUGH. It is a good stand-in for "the directory
# cannot be listed", but it is NOT the event TCC raises, and the difference is load-bearing:
#
#   chmod 000 dir   ->  ls: ... Permission denied      EACCES   os.path.isdir() == True
#   TCC-denied dir  ->  ls: ... Operation not permitted EPERM   os.path.isdir() == False
#
# stat() on a mode-000 directory SUCCEEDS, because it only needs lookup on the PARENT. TCC
# refuses the path itself, so stat() fails outright. Measured both ways on this machine.
# Every guard written as `os.path.isdir(repo)` therefore behaves OPPOSITELY under the real
# denial than it does under the fixture — which is exactly how a bug survives a green suite.
#
# sandbox-exec gives us the real errno without needing a TCC grant, a LaunchAgent, or any
# mutation of real state: it only RESTRICTS a child. `deny file-read*` on a subpath produces
# the same EPERM the nightly job gets, so these two cases test the condition RJ's machine is
# actually in, rather than a fixture that merely resembles it.
command -v sandbox-exec >/dev/null 2>&1 \
  || { echo "FATAL: sandbox-exec required to reproduce a real TCC-class denial" >&2; exit 2; }

# PHYSICALLY RESOLVED: sandbox profiles match on the resolved path, and mktemp hands back
# /var/... while /var is a symlink to /private/var. An unresolved path would silently fail
# to match the deny rule and the case would pass for the wrong reason.
SBX="$(cd "$WORK" && pwd -P)/protected"
mkdir -p "$SBX/bin" "$SBX/.planning"
cp "$DREAM" "$SBX/bin/heimdall-dream"
SBX_HOME="$WORK/sbx-home"; mkdir -p "$SBX_HOME"
DENY="(version 1)(allow default)(deny file-read* (subpath \"$SBX\"))"

# FIRST, prove the fixture really does reproduce the recorded event. A sandbox that failed
# to deny would make every assertion below pass vacuously.
SBX_ERR="$(sandbox-exec -p "$DENY" /bin/ls "$SBX" 2>&1 || true)"
if grep -q 'Operation not permitted' <<<"$SBX_ERR"; then
  ok "(2c) the fixture reproduces the recorded EPERM verbatim — not a look-alike EACCES"
else
  bad "(2c) sandbox did not produce EPERM, so the cases below prove nothing: $SBX_ERR"
fi

# (2c) THE EXACT SHAPE OF THE INSTALLED PLIST: the runner is reachable, but the dream script
# it must exec lives inside the denied tree. This is what fires on RJ's machine every night.
# The earlier cases point at a MISSING dream, which classifies as missing-path; only a real
# EPERM can prove the tcc-denied branch — the one whose advice mentions Full Disk Access.
TSTATUS="$WORK/tcc-status.json"
trc=0
sandbox-exec -p "$DENY" env HEIMDALL_HOME="$SBX_HOME" "$RUNNER" \
  --dream "$SBX/bin/heimdall-dream" --repo "$SBX" --status "$TSTATUS" run --overnight \
  >"$WORK/tcc.log" 2>&1 || trc=$?

if [ "$trc" = 75 ]; then
  ok "(2c) a TCC-denied dream script exits 75 — the nightly block is never a silent 0"
else
  bad "(2c) TCC-denied run exit was $trc, expected 75: $(head -3 "$WORK/tcc.log")"
fi
if grep -q '"result": "blocked"' "$TSTATUS" 2>/dev/null; then
  ok "(2c) it records result=blocked — NON_VERIFIED, never a green it did not earn"
else
  bad "(2c) status did not record blocked: $(head -12 "$TSTATUS" 2>/dev/null | tr '\n' ' ')"
fi
if grep -q '"reason": "tcc-denied"' "$TSTATUS" 2>/dev/null; then
  ok "(2c) and classifies it as tcc-denied — the diagnosis, not a generic probe failure"
else
  bad "(2c) reason was not tcc-denied: $(grep '"reason"' "$TSTATUS" 2>/dev/null)"
fi
if grep -q 'Operation not permitted' "$TSTATUS" 2>/dev/null; then
  ok "(2c) the verbatim OS error survives into the status a human reads"
else
  bad "(2c) status lost the verbatim OS error: $(head -12 "$TSTATUS" 2>/dev/null | tr '\n' ' ')"
fi
if grep -qi 'BLOCKED' "$WORK/tcc.log" && grep -qi 'Full Disk Access\|heimdall-dream-permission' "$WORK/tcc.log"; then
  ok "(2c) the log shouts BLOCKED and routes to the remedy that actually applies"
else
  bad "(2c) the log did not shout a TCC remedy: $(head -6 "$WORK/tcc.log")"
fi

# (2d) THE GUARD THE FIXTURE COULD NOT REACH. With the toolchain readable and only the REPO
# denied, dream must not abort claiming the repo is "not a directory" — it exists and is
# healthy, and the runner has already decided (92daf9d) that a denied repo costs the run
# nothing it needs. A guard that cannot tell "denied" from "missing" turns the supported
# case into a hard stop AND reports a false cause for it.
DSTAT2="$WORK/sbx-dream-status.json"
srun=0
sandbox-exec -p "$DENY" env HEIMDALL_HOME="$SBX_HOME" "$PY" "$DREAM" \
  --repo "$SBX" run --overnight >"$WORK/sbx-dream.log" 2>&1 || srun=$?

if ! grep -qi 'repo not a directory' "$WORK/sbx-dream.log"; then
  ok "(2d) dream does NOT misreport a denied repo as 'not a directory'"
else
  bad "(2d) dream reported a FALSE cause for a healthy repo: $(head -2 "$WORK/sbx-dream.log")"
fi
if [ "$srun" = 0 ]; then
  ok "(2d) dream still completes its run when only the repo is out of reach"
else
  bad "(2d) dream aborted (exit $srun) on a denied repo: $(head -3 "$WORK/sbx-dream.log")"
fi
if [ ! -e "$SBX/.planning/dream" ]; then
  ok "(2d) FALSIFIER: the sandboxed run wrote nothing into the denied tree"
else
  bad "(2d) the run wrote into the denied tree"
fi

# ── notice fixtures ──────────────────────────────────────────────────────────────
LA="$WORK/LaunchAgents"; mkdir -p "$LA"
printf '%s\n' '<plist></plist>' > "$LA/com.heimdall.dream.plist"

write_status() { # write_status <file> <result> <reason> <date> <denied_path>
  cat > "$1" <<EOF
{
  "schema": 1,
  "ts": "${4}T03:00:04Z",
  "date": "$4",
  "label": "com.heimdall.dream",
  "result": "$2",
  "reason": "$3",
  "repo": "/Users/rj/Downloads/heimdall",
  "dream": "/Users/rj/Downloads/heimdall/bin/heimdall-dream",
  "denied_path": "$5",
  "detail": "ls: $5: Operation not permitted",
  "exit": 75
}
EOF
}

days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }

# ── (3) NOTICE is LOUD on a TCC-blocked run ──────────────────────────────────────
NREPO="$WORK/nrepo"; mkdir -p "$NREPO/.planning/dream"
NSTATUS="$WORK/notice-status.json"
write_status "$NSTATUS" blocked tcc-denied "$TODAY" "/Users/rj/Downloads/heimdall"

OUT="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$NREPO" --status "$NSTATUS" 2>&1)"

if grep -qi 'dream' <<<"$OUT"  && grep -qi 'not running\|blocked' <<<"$OUT"; then
  ok "(3) blocked run produces a LOUD operator-visible notice"
else
  bad "(3) no loud notice for a blocked run; got: $OUT"
fi

if grep -qi 'TCC' <<<"$OUT" && grep -q '/Users/rj/Downloads/heimdall' <<<"$OUT"; then
  ok "(3) notice names TCC as the cause and the exact denied path"
else
  bad "(3) notice omits TCC cause or denied path; got: $OUT"
fi

if grep -q 'heimdall-dream' <<<"$OUT" && grep -qi 'run' <<<"$OUT"; then
  ok "(3) notice prints a runnable remedy command"
else
  bad "(3) notice gives no runnable remedy; got: $OUT"
fi

# the hook must never be able to break a session
nrc=0
HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$NREPO" --status "$NSTATUS" >/dev/null 2>&1 || nrc=$?
[ "$nrc" = 0 ] && ok "(3) notice always exits 0 (hook-safe)" || bad "(3) notice exited $nrc"

# ── (4) NOTICE is SILENT on a healthy repo ───────────────────────────────────────
HREPO="$WORK/hrepo"; mkdir -p "$HREPO/.planning/dream"
printf '%s\n' '# dream' > "$HREPO/.planning/dream/$TODAY.md"
HSTATUS="$WORK/healthy-status.json"
write_status "$HSTATUS" ok "" "$TODAY" ""

OUT4="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$HREPO" --status "$HSTATUS" 2>&1)"
if [ -z "$OUT4" ]; then
  ok "(4) healthy repo with today's report: notice is SILENT"
else
  bad "(4) notice nagged a healthy repo: $OUT4"
fi

# ── (5) BACKSTOP: artifact gap with NO status file (the real 10-night case) ──────
GREPO="$WORK/grepo"; mkdir -p "$GREPO/.planning/dream"
OLD="$(days_ago 10)"
printf '%s\n' '# old dream' > "$GREPO/.planning/dream/$OLD.md"

OUT5="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$GREPO" --status "$WORK/does-not-exist.json" 2>&1)"
if grep -qi 'dream' <<<"$OUT5" && grep -q '10' <<<"$OUT5"; then
  ok "(5) BACKSTOP: 10-night artifact gap is LOUD even with no status file"
else
  bad "(5) silent on a 10-night gap — the original bug; got: $OUT5"
fi

if grep -q "$OLD" <<<"$OUT5"; then
  ok "(5) notice names the last report date ($OLD)"
else
  bad "(5) notice omits the last report date; got: $OUT5"
fi

# ── (6) SELF-CLEARING: a blocked status superseded by a report goes quiet ────────
SREPO="$WORK/srepo"; mkdir -p "$SREPO/.planning/dream"
printf '%s\n' '# caught up' > "$SREPO/.planning/dream/$TODAY.md"
SSTATUS="$WORK/superseded-status.json"
write_status "$SSTATUS" blocked tcc-denied "$TODAY" "/Users/rj/Downloads/heimdall"

OUT6="$(HEIMDALL_LAUNCH_AGENTS_DIR="$LA" "$NOTICE" --repo "$SREPO" --status "$SSTATUS" 2>&1)"
if [ -z "$OUT6" ]; then
  ok "(6) blocked status superseded by a catch-up report: notice SELF-CLEARS"
else
  bad "(6) notice nags after the dream was caught up: $OUT6"
fi

# ── (7) SCHEDULE pins the runner OUTSIDE the protected repo ──────────────────────
# Same canonical-fixture discipline as heimdall-dream-schedule.test.sh: the register
# path refuses a linked worktree, and $ROOT is a worktree for an agent, so drive
# install from a purpose-built MAIN worktree to keep this deterministic for everyone.
SHIM="$WORK/mock-launchctl"
cat > "$SHIM" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM"

CANON="$WORK/canonical"
mkdir -p "$CANON/bin/lib"
cp "$SCHED" "$CANON/bin/heimdall-dream-schedule"
cp "$ROOT/bin/lib/real-home.sh" "$CANON/bin/lib/real-home.sh"
cp "$ROOT/bin/lib/tcc-paths.sh" "$CANON/bin/lib/tcc-paths.sh"
cp "$DREAM" "$CANON/bin/heimdall-dream"
cp "$RUNNER" "$CANON/bin/heimdall-dream-runner"
cp "$ROOT/bin/heimdall-dream-bundle" "$CANON/bin/heimdall-dream-bundle"
chmod +x "$CANON/bin/heimdall-dream-schedule" "$CANON/bin/heimdall-dream" \
         "$CANON/bin/heimdall-dream-runner" "$CANON/bin/heimdall-dream-bundle"
git -C "$CANON" init -q
git -C "$CANON" add -A >/dev/null 2>&1
git -C "$CANON" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1

SREPO7="$WORK/repo7"; mkdir -p "$SREPO7/.planning"
LA7="$WORK/LaunchAgents7"
HH7="$WORK/heimdall-home"
PLIST7="$LA7/com.heimdall.dream.plist"

HEIMDALL_LAUNCH_AGENTS_DIR="$LA7" \
HEIMDALL_HOME="$HH7" \
HEIMDALL_DREAM_LOG="$WORK/logs7/dream.log" \
LAUNCHCTL="$SHIM" \
  "$CANON/bin/heimdall-dream-schedule" install --repo "$SREPO7" >/dev/null 2>&1 || true

if [ -f "$PLIST7" ]; then
  ok "(7) install wrote a plist"
else
  bad "(7) install wrote no plist"
fi

PA0=""
PA1=""
if [ -f "$PLIST7" ]; then
  PA0="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST7" 2>/dev/null || true)"
  PA1="$(plutil -extract ProgramArguments.1 raw -o - "$PLIST7" 2>/dev/null || true)"
fi

# ProgramArguments[1] is the runner now — [0] is the INTERPRETER that execs it (below),
# named outright so launchd's minimal PATH never has to resolve a shebang.
if [ -n "$PA1" ] && [ "$PA1" = "$HH7/bin/heimdall-dream-runner" ]; then
  ok "(7) ProgramArguments[1] is the runner installed OUTSIDE the repo ($PA1)"
else
  bad "(7) ProgramArguments[1] is '$PA1', expected $HH7/bin/heimdall-dream-runner"
fi

# ProgramArguments[0]: the hmd-dream bundle when codesign can build one (this fixture
# ships heimdall-dream-bundle, so on any macOS box with codesign it always can), else the
# documented, honest /bin/bash fallback — never anything else.
BUNDLE_EXEC7="$HH7/bin/hmd-dream.app/Contents/MacOS/hmd-dream"
if command -v codesign >/dev/null 2>&1; then
  if [ "$PA0" = "$BUNDLE_EXEC7" ] && [ -x "$BUNDLE_EXEC7" ]; then
    ok "(7) ProgramArguments[0] is the private hmd-dream identity ($PA0)"
  else
    bad "(7) ProgramArguments[0] is '$PA0', expected the built $BUNDLE_EXEC7"
  fi
else
  if [ "$PA0" = "/bin/bash" ]; then
    ok "(7) no codesign on this box: ProgramArguments[0] honestly fell back to /bin/bash"
  else
    bad "(7) ProgramArguments[0] is '$PA0', expected the documented /bin/bash fallback"
  fi
fi

if [ -x "$HH7/bin/heimdall-dream-runner" ]; then
  ok "(7) runner installed executable outside the TCC-protected tree"
else
  bad "(7) runner not installed at $HH7/bin/heimdall-dream-runner"
fi

# the full overnight command must still be encoded (nothing about the fix may erase it)
if [ -f "$PLIST7" ] \
   && grep -q "$CANON/bin/heimdall-dream" "$PLIST7" \
   && grep -q "<string>$SREPO7</string>" "$PLIST7" \
   && grep -q "<string>run</string>" "$PLIST7" \
   && grep -q "<string>--overnight</string>" "$PLIST7"; then
  ok "(7) plist still encodes the full 'heimdall-dream --repo <repo> run --overnight'"
else
  bad "(7) plist lost the overnight command"
fi

# WorkingDirectory must not be a path the job may be unable to getcwd()
WD=""
if [ -f "$PLIST7" ]; then
  WD="$(plutil -extract WorkingDirectory raw -o - "$PLIST7" 2>/dev/null || true)"
fi
if [ "$WD" != "$SREPO7" ]; then
  ok "(7) WorkingDirectory is not the protected repo (no 'getcwd: Operation not permitted')"
else
  bad "(7) WorkingDirectory still pinned to the repo — reproduces the getcwd errors"
fi

# the plist the fix produces must be a VALID plist on the real platform
if [ -f "$PLIST7" ] && plutil -lint "$PLIST7" >/dev/null 2>&1; then
  ok "(7) generated plist passes plutil -lint"
else
  bad "(7) generated plist is not lint-clean"
fi

echo "------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf "dream-tcc: \033[32m%d passed\033[0m, 0 failed\n" "$PASS"
else
  printf "dream-tcc: %d passed, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  exit 1
fi
