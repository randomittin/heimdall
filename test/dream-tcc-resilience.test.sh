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
#   (7) SCHEDULE pins ProgramArguments[0] at a runner OUTSIDE the TCC-protected repo, still
#       encodes the full overnight command, and never sets WorkingDirectory to a path the
#       job cannot getcwd() (the source of the 'shell-init: getcwd' lines in the real log).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUNNER="$ROOT/bin/heimdall-dream-runner"
NOTICE="$ROOT/bin/heimdall-dream-notice"
SCHED="$ROOT/bin/heimdall-dream-schedule"
DREAM="$ROOT/bin/heimdall-dream"

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

# ── (2) RUNNER, denied repo: never a silent success ──────────────────────────────
# A user-owned dir at mode 000 yields a REAL kernel access denial without root. TCC's
# EPERM and this EACCES are the same class of event to the runner: the repo cannot be
# read, so the run did not happen and must not be reported as if it had.
DENIED="$WORK/denied"; mkdir -p "$DENIED/.planning"
chmod 000 "$DENIED"
DSTATUS="$WORK/denied-status.json"
drc=0
"$RUNNER" --dream "$DREAM" --repo "$DENIED" --status "$DSTATUS" run --overnight \
  >"$WORK/denied.log" 2>&1 || drc=$?
chmod 755 "$DENIED"

if [ "$drc" = 75 ]; then
  ok "(2) denied repo exits 75 (EX_TEMPFAIL) — never a silent 0"
else
  bad "(2) denied repo exit was $drc, expected 75"
fi

if [ -f "$DSTATUS" ] && grep -q '"result": "blocked"' "$DSTATUS"; then
  ok "(2) status records result=blocked"
else
  bad "(2) status did not record blocked: $(cat "$DSTATUS" 2>/dev/null | head -8)"
fi

# the VERBATIM OS error is preserved — a diagnosis must not be paraphrased away
if grep -q 'denied_path' "$DSTATUS" && grep -qi 'permitted\|denied' "$DSTATUS"; then
  ok "(2) status preserves the denied path and the verbatim OS error"
else
  bad "(2) status lost the denial detail: $(cat "$DSTATUS" 2>/dev/null | head -8)"
fi

# and it SHOUTS into the log rather than dying quietly
if grep -qi 'BLOCKED' "$WORK/denied.log"; then
  ok "(2) runner shouts BLOCKED into the dream log"
else
  bad "(2) runner failed quietly: $(cat "$WORK/denied.log" 2>/dev/null | head -3)"
fi

# no report may be fabricated for a run that never happened
if [ ! -f "$DENIED/.planning/dream/$TODAY.md" ]; then
  ok "(2) FALSIFIER: no report fabricated for a run that never happened"
else
  bad "(2) a report exists for a blocked run"
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

if printf '%s' "$OUT" | grep -qi 'dream'  && printf '%s' "$OUT" | grep -qi 'not running\|blocked'; then
  ok "(3) blocked run produces a LOUD operator-visible notice"
else
  bad "(3) no loud notice for a blocked run; got: $OUT"
fi

if printf '%s' "$OUT" | grep -qi 'TCC' && printf '%s' "$OUT" | grep -q '/Users/rj/Downloads/heimdall'; then
  ok "(3) notice names TCC as the cause and the exact denied path"
else
  bad "(3) notice omits TCC cause or denied path; got: $OUT"
fi

if printf '%s' "$OUT" | grep -q 'heimdall-dream' && printf '%s' "$OUT" | grep -qi 'run'; then
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
if printf '%s' "$OUT5" | grep -qi 'dream' && printf '%s' "$OUT5" | grep -q '10'; then
  ok "(5) BACKSTOP: 10-night artifact gap is LOUD even with no status file"
else
  bad "(5) silent on a 10-night gap — the original bug; got: $OUT5"
fi

if printf '%s' "$OUT5" | grep -q "$OLD"; then
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
cp "$DREAM" "$CANON/bin/heimdall-dream"
cp "$RUNNER" "$CANON/bin/heimdall-dream-runner"
chmod +x "$CANON/bin/heimdall-dream-schedule" "$CANON/bin/heimdall-dream" \
         "$CANON/bin/heimdall-dream-runner"
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
if [ -f "$PLIST7" ]; then
  PA0="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST7" 2>/dev/null || true)"
fi

if [ -n "$PA0" ] && [ "$PA0" = "$HH7/bin/heimdall-dream-runner" ]; then
  ok "(7) ProgramArguments[0] is the runner installed OUTSIDE the repo ($PA0)"
else
  bad "(7) ProgramArguments[0] is '$PA0', expected $HH7/bin/heimdall-dream-runner"
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
