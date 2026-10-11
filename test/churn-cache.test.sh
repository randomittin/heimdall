#!/usr/bin/env bash
# churn-cache.test.sh -- proves the per-tick work the handoff of 2026-10-11 named is cached or skipped when nothing changed.
#
# Measured on the operator's box: 16 concurrent heimdall-agents, 28 `python3 -c`, 9 heimdall-identity, several
# `heimdall-hooks list --json`, and `grep -hF <task-notification>` over whole session transcripts, re-spawned by three sessions
# every tick -- most of a 10-core box's load (load avg 90/72/56). Two sources:
#   A. bin/heimdall-agents re-grepped every parent transcript (up to 16 MB, append-only) on every call. bin/lib/agents_notif_index.pl
#      keeps a per-transcript (inode, offset, last status per task id) cache and reads only the bytes appended since. The oracle
#      here is the exact grep|perl|awk pipeline it replaced: same answer on every fixture, a fraction of the bytes read.
#   B. every `hmd ui` re-ran its spawn-backed collectors (hooks, identity, fallback, quality gate, agents) every POLL_INTERVAL_S
#      for as long as it lived -- read by nobody (a leaked test server, a tab left open on a closed session). The warmer now skips
#      them for a ui nobody has looked at for IDLE_AFTER_S, and re-runs one every IDLE_WARM_INTERVAL_S at most.
#
# Usage:  bash test/churn-cache.test.sh        bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
HELPER="$REPO/bin/lib/agents_notif_index.pl"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/churn-cache.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CACHE="$T/cache"

echo "churn-cache (heimdall-agents notification index, hmd-ui warmer)"

echo "-- A. the notification index is incremental and answers exactly what the grep pipeline did --"
notif() { printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>%s</task-id>\\n<status>%s</status>\\n</task-notification>"}}\n' "$1" "$2"; }
filler() { printf '{"type":"assistant","message":"%s"}\n' "$1"; }
oracle() { grep -hF '<task-notification>' "$@" 2>/dev/null | perl -ne 'while(m{<task-id>([^<]+)</task-id>.*?<status>([^<]+)</status>}g){print "$1\t$2\n"}' 2>/dev/null | awk -F'\t' 'NF==2{last[$1]=$2} END{printf " "; for(k in last) printf "%s:%s ", k, last[k]}'; }
norm() { tr ' ' '\n' | grep . | sort | tr '\n' ' '; }
idx() { perl "$HELPER" "$CACHE" "$@" 2>/dev/null; }
scanned() { HMD_NOTIF_INDEX_DEBUG=1 perl "$HELPER" "$CACHE" "$@" 2>&1 >/dev/null | sed -n 's/^scanned_bytes=//p'; }
same() { [ "$(idx "$@" | norm)" = "$(oracle "$@" | norm)" ]; }

if [ ! -f "$HELPER" ]; then bad "bin/lib/agents_notif_index.pl is missing"; fi
S1="$T/s1.jsonl"; S2="$T/s2.jsonl"
{ filler one; notif a1 completed; filler two; notif a2 failed; notif a1 killed; filler three; } > "$S1"
{ filler four; notif a2 completed; notif a5 completed; } > "$S2"
if same "$S1"; then ok "one transcript: the same index as the grep pipeline (a1 resumed then killed -> last wins)"; else bad "one transcript: [$(idx "$S1")] vs oracle [$(oracle "$S1")]"; fi
if same "$S1" "$S2"; then ok "two transcripts: a later file's notification wins over an earlier one's (a2 failed -> completed)"; else bad "two transcripts: [$(idx "$S1" "$S2")] vs [$(oracle "$S1" "$S2")]"; fi
if [ "$(scanned "$S1" "$S2")" = 0 ]; then ok "a second call on unchanged transcripts reads 0 bytes"; else bad "unchanged transcripts rescanned: $(scanned "$S1" "$S2") bytes"; fi
BEFORE="$(wc -c < "$S1" | tr -d ' ')"; notif a3 completed >> "$S1"; AFTER="$(wc -c < "$S1" | tr -d ' ')"
GOT="$(scanned "$S1" "$S2")"
if [ "$GOT" = "$((AFTER - BEFORE))" ]; then ok "after an append only the appended $((AFTER - BEFORE)) bytes are read"; else bad "append read $GOT bytes, want $((AFTER - BEFORE))"; fi
if same "$S1" "$S2" && idx "$S1" "$S2" | grep -q ' a3:completed '; then ok "...and the appended notification is in the index"; else bad "appended notification missing: [$(idx "$S1" "$S2")]"; fi
printf '{"x":"<task-notification><task-id>a4</task-id><status>completed</status>' >> "$S1"
if same "$S1" "$S2" && idx "$S1" "$S2" | grep -q ' a4:completed '; then ok "a half-written last line (no newline yet) is answered like grep answers it"; else bad "unterminated tail: [$(idx "$S1" "$S2")] vs [$(oracle "$S1" "$S2")]"; fi
printf '"}\n' >> "$S1"
if same "$S1" "$S2"; then ok "...and still agrees once that line is finished (it was never cached half-read)"; else bad "after completing the tail: [$(idx "$S1" "$S2")] vs [$(oracle "$S1" "$S2")]"; fi
{ filler fresh; notif b9 completed; } > "$S1"
if same "$S1" "$S2" && ! idx "$S1" "$S2" | grep -q ' a1:'; then ok "a transcript that shrank (rewritten) is rescanned from byte 0 -- no stale ids"; else bad "shrunk transcript: [$(idx "$S1" "$S2")]"; fi
if [ "$(perl "$HELPER" /dev/null/nope "$S1" "$S2" 2>/dev/null | norm)" = "$(oracle "$S1" "$S2" | norm)" ]; then ok "an unusable cache dir costs speed only, never correctness"; else bad "unusable cache dir changed the answer"; fi
if [ "$(perl "$HELPER" "$CACHE" "$T/nope.jsonl" 2>/dev/null)" = " " ]; then ok "no readable transcript: a single space, the empty index the caller expects"; else bad "empty case: [$(perl "$HELPER" "$CACHE" "$T/nope.jsonl" 2>/dev/null)]"; fi
if grep -q 'agents_notif_index.pl' "$REPO/bin/heimdall-agents"; then ok "bin/heimdall-agents builds its index through the helper"; else bad "bin/heimdall-agents does not use agents_notif_index.pl"; fi

BIG="$T/big.jsonl"
python3 -I - "$BIG" <<'PYEOF'
import sys
line = '{"type":"assistant","message":"' + "x" * 480 + '"}\n'
with open(sys.argv[1], "w") as f:
    for n in range(40000):
        f.write(line)
        if n % 5000 == 0:
            f.write('{"m":"<task-notification>\\n<task-id>t%d</task-id>\\n<status>completed</status>"}\n' % n)
PYEOF
MEAS="$(python3 -I - "$HELPER" "$CACHE.big" "$BIG" <<'PYEOF'
import subprocess, sys, time
helper, cache, big = sys.argv[1:4]
def timed(cmd, shell=False):
    t = time.perf_counter(); subprocess.run(cmd, shell=shell, capture_output=True); return (time.perf_counter() - t) * 1000
old = timed("grep -hF '<task-notification>' %s | perl -ne 'while(m{<task-id>([^<]+)</task-id>.*?<status>([^<]+)</status>}g){print \"$1\\t$2\\n\"}' | awk -F'\\t' 'NF==2{last[$1]=$2} END{printf \" \"; for(k in last) printf \"%%s:%%s \", k, last[k]}'" % big, shell=True)
cold = timed(["perl", helper, cache, big]); warm = timed(["perl", helper, cache, big])
print("grep pipeline %.0f ms, helper cold %.0f ms, helper warm %.0f ms (%.1f MB transcript)" % (old, cold, warm, len(open(big, "rb").read()) / 1e6))
PYEOF
)"
ok "measured per call, before -> after: $MEAS"
if [ "$(scanned "$BIG")" -gt 0 ] 2>/dev/null; then :; fi
if [ "$(scanned "$BIG")" = 0 ]; then ok "the big transcript's warm call reads 0 bytes"; else bad "warm big transcript not 0 bytes"; fi

echo "-- B. an idle hmd ui stops re-running its spawn-backed collectors every poll --"
PYOUT="$(python3 -I - "$REPO/sentinels/hmd-ui.py" <<'PYEOF'
import importlib.util, sys, threading, time
spec = importlib.util.spec_from_file_location("hmd_ui_under_test", sys.argv[1])
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
lines = []
def check(name, cond):
    lines.append(("ok " if cond else "FAIL ") + name)
has = hasattr(ui, "IDLE_AFTER_S") and hasattr(ui, "IDLE_WARM_INTERVAL_S") and hasattr(ui.StateCache, "observe")
check("hmd-ui has the warmer's idle gate (IDLE_AFTER_S, IDLE_WARM_INTERVAL_S, StateCache.observe)", has)
if has:
    calls = []
    ui.SLOW_COLLECTORS = (lambda root: calls.append(time.monotonic()),)
    ui.POLL_INTERVAL_S = 0.05
    ui.IDLE_AFTER_S = 0.4
    ui.IDLE_WARM_INTERVAL_S = 1.0
    sc = ui.StateCache.__new__(ui.StateCache)
    sc.root = "/nonexistent"
    sc._stop = threading.Event()
    sc._warmed = threading.Event()
    sc._observed_at = time.monotonic()
    th = threading.Thread(target=sc._warm_loop, daemon=True)
    th.start()
    time.sleep(0.3)
    active = len(calls)
    time.sleep(0.5)
    base = len(calls)
    time.sleep(0.8)
    idle = len(calls) - base
    sc.observe()
    base = len(calls)
    time.sleep(0.3)
    resumed = len(calls) - base
    sc._stop.set()
    th.join(2)
    check("a ui someone is reading warms at the poll rate (%d warms in 0.3 s)" % active, active >= 3)
    check("a ui nobody has looked at for IDLE_AFTER_S warms at most once per IDLE_WARM_INTERVAL_S (%d in 0.8 s)" % idle, idle <= 1)
    check("looked at again, it is back at the poll rate (%d warms in 0.3 s)" % resumed, resumed >= 2)
    sc2 = ui.StateCache.__new__(ui.StateCache)
    sc2._cond = threading.Condition(); sc2._digest = "d"; sc2._state = {}
    sc2._refreshed_at = time.monotonic(); sc2._observed_at = 0.0
    sc2.wait_for_change("d", 0.01)
    check("wait_for_change (an SSE stream, the relay client) counts as being looked at", sc2._observed_at > 0.0)
    sc2._observed_at = 0.0; sc2.latest()
    check("latest() (a GET /api/state) counts as being looked at", sc2._observed_at > 0.0)
    sc2._observed_at = 0.0; sc2._refresh = lambda publish: ({}, "d"); sc2.refresh()
    check("a full refresh() counts as being looked at", sc2._observed_at > 0.0)
    sc2._observed_at = 0.0; sc2.refresh(publish=True, partial=True)
    check("the poller's own partial pass does NOT count (a ui must not keep itself warm)", sc2._observed_at == 0.0)
print("\n".join(lines))
print("done")
PYEOF
)"
if [ "$(printf '%s\n' "$PYOUT" | tail -1)" = "done" ]; then
  while IFS= read -r line; do
    case "$line" in "ok "*) ok "${line#ok }" ;; "FAIL "*) bad "${line#FAIL }" ;; esac
  done <<< "$PYOUT"
else
  bad "the warmer probe did not run to the end: $(printf '%s' "$PYOUT" | tail -5)"
fi

printf '\nchurn-cache: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
