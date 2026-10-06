#!/usr/bin/env bash
# heimdall-inbox-lockless-writer.test.sh -- a writer that never heard of the inbox flock must not
# lose a message to a pop of the (still empty) inbox.
#
# WHY THIS EXISTS. test/heimdall-inbox-wiring.test.sh section 9 went RED in a loaded full sweep
# and in its solo retry: the wired Stop hook held 20s, delivered nothing, and the message was in
# neither inbox.jsonl nor inbox-delivered.jsonl. Reproduced (and bisected) under CPU contention,
# the cause was a race between the suite's plain `printf ... >> inbox.jsonl` and the hold:
#
#   writer   open(O_CREAT|O_APPEND)   .....(descheduled).....   write(line)
#   hold          (kqueue: the directory changed -> wake) pop: rename the EMPTY file away, read "", remove
#
# The line is written into the inode the pop just renamed and removed. bin/heimdall-inbox-deliver's
# inline fallback pop (the one every repo without bin/lib/companion_ui_inbox.py importable runs)
# renamed the inbox away even when it was empty; the real module's pop_all() returns [] and touches
# nothing in that case. The event-driven hold wakes on the create itself, so any writer that is slow
# between its open and its write meets the pop: ~14% of runs at load average 45, ~2% with the old 2s
# poll. The real writer (companion_ui_inbox.append) takes the flock the pop takes, so it never met it.
#
# This suite delays the write by a full second after the create, so the race is not a matter of
# load: both pop implementations must leave an empty inbox where it is and deliver the line once it
# lands.
#
# Oracle: bin/heimdall-inbox-deliver (stop mode, inline fallback and with the real module present).
# Exit 0 = every proof holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$REPO/bin/heimdall-inbox-deliver"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing or not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

# An attended session, the typing release off, nothing the operator exported steering the hold.
export CLAUDE_CODE_ENTRYPOINT=cli HMD_INBOX_TTY=off
unset HMD_AGENT_TYPE HMD_JUDGMENT HMD_INBOX_GATED HMD_INBOX_WAIT_S HMD_INBOX_WATCH HMD_INBOX_PRESENCE_CMD HMD_TMUX_TARGET

# A project with a live companion: connect.json naming this shell, so `stop` holds after any message.
make_project() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/.heimdall/ui" "$d/.heimdall/app"
  printf '{"mode":"relay","pid_ui":%s,"pid_client":%s,"port":1,"relay":"x","started_at":"t"}\n' "$$" "$$" > "$d/.heimdall/app/connect.json"
  printf '%s' "$d"
}
with_module() { mkdir -p "$1/bin/lib"; cp "$REPO/bin/lib/companion_ui_inbox.py" "$1/bin/lib/companion_ui_inbox.py"; }
inode_of() { python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$1" 2>/dev/null || echo gone; }

echo "1. a pop of an EMPTY inbox leaves the file where it is (same inode), with and without the real module:"
for FLAVOUR in inline module; do
  D="$(make_project)"
  [ "$FLAVOUR" = module ] && with_module "$D"
  : > "$D/.heimdall/ui/inbox.jsonl"
  BEFORE="$(inode_of "$D/.heimdall/ui/inbox.jsonl")"
  OUT="$(printf '{}' | "$HOOK" prompt --repo "$D" 2>&1)"
  RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$FLAVOUR: prompt pop of an empty inbox -> exit 0, nothing printed"; else bad "$FLAVOUR: rc=$RC out: $OUT"; fi
  AFTER="$(inode_of "$D/.heimdall/ui/inbox.jsonl")"
  if [ "$BEFORE" = "$AFTER" ]; then ok "$FLAVOUR: the empty inbox.jsonl is the same inode afterwards ($AFTER)"; else bad "$FLAVOUR: inbox.jsonl was $BEFORE, is now $AFTER -- a writer holding it open would write into a removed file"; fi
  rm -rf "$D"
done

# run_straddle DIR -- a Stop hold waiting on an idle companion; a writer that creates inbox.jsonl, sits
# on it for a full second, THEN writes its line. Sets OUT (the hold's stdout) and ELAPSED (seconds).
run_straddle() {
  local d="$1" ui="$1/.heimdall/ui" i=0 hold t0
  : > "$ui/hold.out"
  t0=$(date +%s)
  printf '{"session_id":"s1","transcript_path":"","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done implementing the feature."}' "$d" \
    | HMD_INBOX_WAIT_S=15 "$HOOK" stop --repo "$d" > "$ui/hold.out" 2>&1 &
  hold=$!
  # The hold has written its marker: it is in its loop, watching the queue.
  while [ ! -e "$ui/inbox-waiting" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$ui/inbox.jsonl"   # a drained queue: no file at all, so the writer's open CREATES it
  python3 -c '
import os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)   # the file exists, empty, from here on
time.sleep(1.0)                                                              # a writer that is slow to its first write
os.write(fd, (sys.argv[2] + "\n").encode())
os.close(fd)
' "$ui/inbox.jsonl" '{"id":"l1","ts":1,"text":"slow writer hello","source":"test"}'
  wait "$hold" 2>/dev/null
  ELAPSED=$(( $(date +%s) - t0 ))
  OUT="$(cat "$ui/hold.out")"
}

echo "2. a writer that creates inbox.jsonl and writes a second later still reaches the Stop hold (no flock taken by the writer):"
for FLAVOUR in inline module; do
  D="$(make_project)"
  [ "$FLAVOUR" = module ] && with_module "$D"
  run_straddle "$D"
  if printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then ok "$FLAVOUR: decision:block delivered"; else bad "$FLAVOUR: no delivery after ${ELAPSED}s: $OUT"; fi
  if printf '%s' "$OUT" | grep -q "slow writer hello"; then ok "$FLAVOUR: the reason carries the slow writer's text"; else bad "$FLAVOUR: text missing from: $OUT"; fi
  if [ "$ELAPSED" -le 8 ]; then ok "$FLAVOUR: delivered in ${ELAPSED}s -- the hold woke for the write, it did not run out its 15s"; else bad "$FLAVOUR: took ${ELAPSED}s"; fi
  if grep -q "slow writer hello" "$D/.heimdall/ui/inbox-delivered.jsonl" 2>/dev/null; then ok "$FLAVOUR: archived in inbox-delivered.jsonl"; else bad "$FLAVOUR: not in the delivered archive"; fi
  if [ ! -s "$D/.heimdall/ui/inbox.jsonl" ]; then ok "$FLAVOUR: popped (inbox.jsonl is empty or gone)"; else bad "$FLAVOUR: still queued"; fi
  rm -rf "$D"
done

echo ""
echo "heimdall-inbox-lockless-writer.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
