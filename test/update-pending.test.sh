#!/usr/bin/env bash
# update-pending.test.sh — W1-cc-pending (docs/superpowers/plans/2026-11-13-seamless-update-restart.md):
# `heimdall-cc-selfheal pending [--pid P]` answers, machine-readably, "is a newer claude installed than the
# one THIS session runs?", and the pin notice (the human-readable form of the same question) says
# "restarting automatically" only while the launcher supervises the session and auto restart is on.
#
# Everything runs in a scrubbed env (env -i) against temp dirs: a temp HOME, a fake versions dir, a fake
# ~/.claude/sessions dir shaped like the one Claude Code writes (docs/analysis/2026-11-13-seamless-restart-spike.md,
# Q4) and a stub `lsof`. The scrub matters twice: the real machine is never read, and a run from inside an
# hmd-SUPERVISED session (the launcher exports HMD_SUPERVISED=1 into claude's environment, so every child
# inherits it) cannot turn the "old wording" cases into the new ones.
#
# Falsifiability: HEAL_UNDER_TEST points the whole file at a mutated copy of the product.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEAL="${HEAL_UNDER_TEST:-$REPO/bin/heimdall-cc-selfheal}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
[ -x "$HEAL" ] || { echo "FATAL: $HEAL not executable"; exit 2; }
bash -n "$HEAL" || { echo "FATAL: syntax"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/update-pending-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
VERS="$WORK/versions"; SESS="$WORK/sessions"; HMDH="$WORK/hmd"; LSOF="$WORK/lsof-stub"
mkdir -p "$WORK/home"

# ── harness ─────────────────────────────────────────────────────────────────────
heal() { env -i PATH=/usr/bin:/bin HOME="$WORK/home" HEIMDALL_HOME="$HMDH" \
  HEIMDALL_CLAUDE_CONFIG="$WORK/claude.json" HEIMDALL_CC_VERSIONS="$VERS" \
  HEIMDALL_CC_SESSIONS_DIR="$SESS" HEIMDALL_CC_LSOF="$LSOF" "$@"; }
run()     { OUT="$(heal "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
pending() { run bash "$HEAL" pending "$@"; }
notice()  { run HEIMDALL_CC_PIN_PID=4242 "$@" bash "$HEAL" pin-notice; }   # extra env words go first

mkver()  { rm -rf "$VERS"; mkdir -p "$VERS"; local v; for v in "$@"; do : > "$VERS/$v"; done; }
# a sessions file shaped like the one Claude writes: pid, sessionId, version (the RUNNING binary), status
mksess() { printf '{"pid":%s,"sessionId":"sid-%s","cwd":"/tmp","kind":"interactive","version":"%s","status":"idle","statusUpdatedAt":1}\n' "$1" "$1" "$2" > "$SESS/$1.json"; }
# stub for `lsof -p <pid>`: the one line the real one prints for the binary a pid has open (or nothing)
mklsof() {
  if [ "$1" = none ]; then printf '#!/bin/sh\nexit 0\n' > "$LSOF"
  else printf '#!/bin/sh\necho "claude 4242 rj txt REG 1,15 240377264 60375379 %s/%s"\n' "$VERS" "$1" > "$LSOF"; fi
  chmod +x "$LSOF"
}
native() { printf '{"installMethod":"native","autoUpdates":true}\n' > "$WORK/claude.json"; }
reset()  { rm -rf "$SESS" "$HMDH"; mkdir -p "$SESS" "$HMDH"; mklsof none; native; }

# expect <label> <want-rc> <want-stdout> — judges the last run. A clean answer (rc 0/1) must be silent on
# stderr; a malformed call (rc 2) must explain itself there and print no answer.
expect() {
  local label="$1" wrc="$2" wout="$3"
  if [ "$RC" != "$wrc" ] || [ "$OUT" != "$wout" ]; then bad "$label (rc=$RC want $wrc; stdout='$OUT' want '$wout')"; return; fi
  if [ "$wrc" != 2 ] && [ -n "$ERR" ]; then bad "$label (unexpected stderr: $ERR)"; return; fi
  if [ "$wrc" = 2 ] && [ -z "$ERR" ]; then bad "$label (a malformed call must explain itself on stderr)"; return; fi
  ok "$label"
}

# ── 1) behind / equal / ahead, running version read from the sessions file ──────
reset; mkver 2.1.318 2.1.322 2.1.323; mksess 4242 2.1.322
pending --pid 4242; expect "behind: prints 'claude <running> <newest>', exit 0" 0 "claude 2.1.322 2.1.323"
mksess 4242 2.1.323
pending --pid 4242; expect "equal: prints nothing, exit 1" 1 ""
mksess 4242 2.1.330
pending --pid 4242; expect "ahead of the newest installed: not pending (silent, exit 1)" 1 ""

# ── 2) sort -V, never a lexical compare ─────────────────────────────────────────
reset; mkver 2.1.9 2.1.10; mksess 4242 2.1.9
pending --pid 4242; expect "numeric order: 2.1.9 is behind 2.1.10" 0 "claude 2.1.9 2.1.10"
mksess 4242 2.1.10
pending --pid 4242; expect "numeric order: 2.1.10 is the newest, not pending" 1 ""

# ── 3) an unreadable sessions file, with nothing else to go on, is never a pending update ─
reset; mkver 2.1.322 2.1.323
for body in 'not json{' '' '[]' '{"pid":4242}' '{"pid":4242,"version":2}' '{"pid":4242,"version":"2.1.322 evil"}' \
            '{"pid":4242,"version":"../../x"}' '{"pid":9999,"version":"2.1.322"}'; do
  printf '%s\n' "$body" > "$SESS/4242.json"
  pending --pid 4242; expect "sessions file '$body' is not trusted: exit 1, nothing printed" 1 ""
done
# only the first 64 KiB is ever read, so a giant file cannot stall the Stop hook that asks this on every turn
{ printf '{"pid":4242,"version":"2.1.322","pad":"'; head -c 70000 /dev/zero | tr '\0' 'A'; printf '"}\n'; } > "$SESS/4242.json"
pending --pid 4242; expect "oversized sessions file (> 64 KiB) is not parsed: exit 1, nothing printed" 1 ""

# ── 4) lsof is the fallback when the sessions file cannot answer ────────────────
reset; mkver 2.1.319 2.1.323; mklsof 2.1.319
pending --pid 4242; expect "lsof fallback (no sessions file): behind" 0 "claude 2.1.319 2.1.323"
printf 'not json{\n' > "$SESS/4242.json"
pending --pid 4242; expect "lsof fallback (garbage sessions file): behind" 0 "claude 2.1.319 2.1.323"
rm -f "$SESS/4242.json"; mklsof 2.1.323
pending --pid 4242; expect "lsof fallback: on the newest, not pending" 1 ""

# ── 5) and the sessions file wins when both answer ──────────────────────────────
reset; mkver 2.1.319 2.1.323; mksess 4242 2.1.323; mklsof 2.1.319
pending --pid 4242; expect "source order: sessions file (current) beats lsof (old)" 1 ""
mksess 4242 2.1.319; mklsof 2.1.323
pending --pid 4242; expect "source order: sessions file (old) beats lsof (current)" 0 "claude 2.1.319 2.1.323"

# ── 6) no --pid: the nearest claude ancestor, the seam the pin notice already had ─
reset; mkver 2.1.322 2.1.323; mksess 4242 2.1.322
run HEIMDALL_CC_PIN_PID=4242 bash "$HEAL" pending; expect "no --pid: resolves the claude ancestor, same answer" 0 "claude 2.1.322 2.1.323"
run HEIMDALL_CC_PIN_PID=7 bash "$HEAL" pending;    expect "no --pid: an ancestor with no sessions file and no lsof answer is not pending" 1 ""

# ── 7) the guards the pin notice already had: opt-out, native-only, a versions dir ─
reset; mkver 2.1.322 2.1.323; mksess 4242 2.1.322
run HEIMDALL_NO_SELFHEAL=1 bash "$HEAL" pending --pid 4242; expect "opt-out env: not pending" 1 ""
: > "$HMDH/no-selfheal"
pending --pid 4242; expect "opt-out file: not pending" 1 ""
rm -f "$HMDH/no-selfheal"
printf '{"installMethod":"npm"}\n' > "$WORK/claude.json"
pending --pid 4242; expect "non-native install: not pending (never ours to touch)" 1 ""
native; rm -rf "$VERS"
pending --pid 4242; expect "no versions dir: not pending" 1 ""

# ── 8) a malformed call is exit 2 with a message, never an answer ───────────────
reset; mkver 2.1.322 2.1.323; mksess 4242 2.1.322
pending --pid;        expect "--pid without a value: usage error" 2 ""
pending --pid abc;    expect "--pid not a number: usage error" 2 ""
pending --pid '../x'; expect "--pid that is a path: usage error (never reaches the filesystem)" 2 ""
pending --pid '';     expect "--pid empty: usage error" 2 ""
pending --bogus;      expect "unknown option: usage error" 2 ""

# ── 9) the pin notice wording ───────────────────────────────────────────────────
OLD='[heimdall] claude 2.1.322 is pinned by this session; 2.1.323 is installed — restart to adopt it (auto-update cannot swap a running binary).'
NEW='[heimdall] claude 2.1.322 is pinned by this session; 2.1.323 is installed - restarting automatically at the next idle moment (HMD_AUTO_RESTART=off to disable)'
reset; mkver 2.1.322 2.1.323; mksess 4242 2.1.322
notice;                                         expect "notice, not supervised: the old wording, byte for byte" 0 "$OLD"
notice HMD_SUPERVISED=1;                        expect "notice, supervised, auto restart on: says it restarts automatically" 0 "$NEW"
notice HMD_SUPERVISED=1 HMD_AUTO_RESTART=on;    expect "notice, supervised, HMD_AUTO_RESTART=on: restarts automatically" 0 "$NEW"
notice HMD_SUPERVISED=1 HMD_AUTO_RESTART=off;   expect "notice, supervised, HMD_AUTO_RESTART=off: the old wording (no false promise)" 0 "$OLD"
notice HMD_AUTO_RESTART=on;                     expect "notice, HMD_AUTO_RESTART=on but not supervised: the old wording" 0 "$OLD"
notice HMD_SUPERVISED=true;                     expect "notice, HMD_SUPERVISED must be exactly 1" 0 "$OLD"
: > "$HMDH/no-auto-restart"
notice HMD_SUPERVISED=1;                        expect "notice, supervised but the no-auto-restart file exists: the old wording" 0 "$OLD"
rm -f "$HMDH/no-auto-restart"
mksess 4242 2.1.323
notice HMD_SUPERVISED=1;                        expect "notice, supervised, already on the newest: silent" 0 ""

# ── 10) one detection, two consumers: the notice speaks exactly when pending says yes ─
reset; mkver 2.1.318 2.1.323
for running in 2.1.322 2.1.323 2.1.330; do
  mksess 4242 "$running"
  pending --pid 4242; prc="$RC"
  notice;             nout="$OUT"
  state=silent; [ -n "$nout" ] && state=spoke
  if { [ "$prc" = 0 ] && [ "$state" = spoke ]; } || { [ "$prc" = 1 ] && [ "$state" = silent ]; }; then
    ok "one detection: running $running -> pending rc=$prc, pin-notice $state"
  else
    bad "pending (rc=$prc) and pin-notice ($state) disagree for running $running"
  fi
done

# ── 11) the usage text names the new subcommand ─────────────────────────────────
run bash "$HEAL" bogus
if [ "$RC" = 2 ] && grep -q 'pending' <<<"$ERR"; then ok "unknown subcommand: the usage line names pending"; else bad "usage line does not name pending (rc=$RC err='$ERR')"; fi
run bash "$HEAL" --help
if grep -q 'pending \[--pid P\]' <<<"$OUT"; then ok "--help documents pending [--pid P]"; else bad "--help does not document pending"; fi

echo "──────────────────────────────────────"
printf 'update-pending: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
