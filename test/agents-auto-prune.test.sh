#!/usr/bin/env bash
# test/agents-auto-prune.test.sh -- acceptance for the AUTOMATIC half of `hmd agents prune`: bin/heimdall-agents-auto-prune, which the
# agents-auto-prune SessionStart hook launches (detached, silent) at most once a day to COMPRESS -- never delete -- the transcripts
# of old, finished subagents (operator, 2026-11-22: "add a capability in hmd to auto compress older conversations").
#
# WHY IT EXISTS. bin/heimdall-agents-prune frees the space (one session measured 8.7 GB of subagent transcripts), but a person has to
# remember to run it. Running it for them is a job that touches a person's history on every session start of every project, so
# what can go wrong, in this order (each guard below has an assertion that goes RED when the guard is removed):
#   1. Deleting. Only `--compress --older-than <N>d` may ever be asked of the tool (argv recorded by a fake tool), nothing is lost
#      (every old file reads back byte for byte from its .gz, the file count is unchanged), and no setting turns it into a delete.
#   2. Touching what the prune tool protects: a session with a live process, a session written in the last 10 minutes, an agent
#      newer than the threshold, a main transcript, a symlink, a file that is not an agent's. The wrapper adds no rule of its own
#      and drops none: those paths are byte, mode and mtime identical after a run, even at the lowest threshold (3 days).
#   3. Running more than once a day, or twice at once: a stamp (a fresh one, a 23 h old one: nothing; a 25 h old, garbage or
#      future one: due) and an flock lock (held by another session: nothing; its holder killed: no stale lock left behind; five
#      sessions started together: one run).
#   4. Not being switchable: HMD_AUTO_PRUNE=off|0|false|no (nothing is created, not even a stamp), `hmd guardrails off
#      agents-auto-prune` (through the real CLI, the real hook command), HMD_AUTO_PRUNE_DAYS (default 14, at least 3, junk is 14).
#   5. Costing the session something: the hook returns while the job still runs, in its own session and holding none of the hook's
#      pipes (a SessionStart hook's stdout is read by the model, and a held pipe would make the session wait), prints nothing, and
#      a tool that hangs is killed at HMD_AUTO_PRUNE_TIMEOUT_S; a subagent's own session start (CLAUDE_CODE_CHILD_SESSION set; every
#      subagent start fires SessionStart, thousands in a long session) launches nothing.
#   6. Failing silently: a failed, timed-out or missing prune tool is ONE line of $HEIMDALL_HOME/logs/agents-prune.log, and the
#      wrapper still exits 0 (housekeeping never fails a session). The bytes in the log line are what the disk lost.
#
# Hermetic: every scenario runs the real script against a FAKE HOME (HOME=<tmp>, CLAUDE_CONFIG_DIR and HEIMDALL_HOME unset, the
# cwd an empty directory), so no real ~/.claude or ~/.heimdall is read. The "running" session is a real live process (a
# background sleep). The tool's own contract (what it selects and protects) is proven by test/agents-prune.test.sh; here the real
# tool is the engine and a fake tool, placed beside a COPY of the wrapper (it finds the tool next to itself), records what it is asked.
# budget: about 18 s solo (measured on a busy laptop): about 100 python starts (the wrapper, the real tool, the fixtures) dominate. Six fixture builds; the cases
# about the wrapper's own arguments, stamp and paths run it beside a recording tool and build none. The detach and switch cases poll
# in 50 ms steps and finish in well under a second; one case waits 1 s for something that must NOT appear, one lets a 1 s timeout fire.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AUTO="$ROOT/bin/heimdall-agents-auto-prune"
GUARD="$ROOT/bin/heimdall-guardrails"
HOOKTOOL="$ROOT/bin/heimdall-hooks"
HOOKS="$ROOT/hooks/hooks.json"
META="$ROOT/hooks/hooks.metadata.json"
MANIFEST="$ROOT/guardrails.manifest.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
check()     { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }
eq()        { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

for tool in python3 jq perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not found" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-auto-prune-test.XXXXXX")"
OUT="$WORK/out"; ERR="$WORK/err"
CWD="$WORK/cwd"; mkdir -p "$CWD"
HOLDER=""
sleep 300 &
LIVE_PID=$!
disown "$LIVE_PID" 2>/dev/null   # off the job table: killing it at exit prints no "Terminated" line
cleanup() {
  kill "$LIVE_PID" 2>/dev/null
  [ -z "$HOLDER" ] || kill -9 "$HOLDER" 2>/dev/null
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

SLUG="-Users-x-alpha"
S1="11111111-1111-4111-8111-111111111111"   # finished long ago: agents of 40, 20, 10, 4 and 2 days
S2="22222222-2222-4222-8222-222222222222"   # RUNNING: a live pid in <config>/sessions, its agent is 40 days old
S3="33333333-3333-4333-8333-333333333333"   # not recorded as running, but its main transcript was written 2 minutes ago

# world HOME -- the fake HOME tree. At the default 14 days the tool selects a1old and a2old (4 files); it keeps a3mid, a5four and
# a4two by age, a6run (live pid) and a7act (session written 2 min ago) by the session rules, and never reaches the decoys.
world() {
  python3 -I - "$1" "$LIVE_PID" "$SLUG" "$S1" "$S2" "$S3" <<'PY'
import json, os, sys, time
root, live_pid, A, S1, S2, S3 = sys.argv[1:]
live_pid = int(live_pid)
now = time.time()
DAY = 86400
proj = os.path.join(root, ".claude", "projects")

def stamp(path, age):
    os.utime(path, (now - age, now - age))

def put(path, age, lines, tag):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for i in range(lines):
            fh.write('{"type":"assistant","n":%d,"tag":"%s","text":"%s"}\n' % (i, tag, "the quick brown fox jumps " * 5))
    os.chmod(path, 0o600)
    stamp(path, age)

def agent(sess, aid, age, lines):
    sub = os.path.join(proj, A, sess, "subagents")
    put(os.path.join(sub, "agent-%s.jsonl" % aid), age, lines, aid)
    meta = os.path.join(sub, "agent-%s.meta.json" % aid)
    with open(meta, "w") as fh:
        json.dump({"agentType": "hmd:coder", "description": "fixture " + aid}, fh)
    os.chmod(meta, 0o644)
    stamp(meta, age)

def main_transcript(sess, age):
    put(os.path.join(proj, A, sess + ".jsonl"), age, 30, "main-" + sess[:4])

main_transcript(S1, 40 * DAY)
agent(S1, "a1old", 40 * DAY, 150)
agent(S1, "a2old", 20 * DAY, 90)
agent(S1, "a3mid", 10 * DAY, 70)
agent(S1, "a5four", 4 * DAY, 60)
agent(S1, "a4two", 2 * DAY, 50)
main_transcript(S2, 40 * DAY)
agent(S2, "a6run", 40 * DAY, 100)
main_transcript(S3, 120)
agent(S3, "a7act", 40 * DAY, 110)

sessions = os.path.join(root, ".claude", "sessions")
os.makedirs(sessions)
with open(os.path.join(sessions, "%d.json" % live_pid), "w") as fh:
    json.dump({"pid": live_pid, "sessionId": S2, "cwd": "/Users/x/alpha", "kind": "interactive", "status": "idle"}, fh)

# decoys: old enough to be selected if anything were careless about WHAT it touches
outside = os.path.join(root, "outside")
put(os.path.join(outside, "target.jsonl"), 40 * DAY, 20, "target")
os.symlink(os.path.join(outside, "target.jsonl"), os.path.join(proj, A, S1, "subagents", "agent-sym.jsonl"))
put(os.path.join(proj, A, S1, "subagents", "notes.txt"), 40 * DAY, 20, "notes")
put(os.path.join(proj, A, S1, "tool-results", "blob.txt"), 40 * DAY, 20, "blob")
PY
}

# add_agent HOME SESSION ID AGE_DAYS -- one more old finished agent (both files), for the "second start the same day" cases
add_agent() {
  python3 -I - "$1" "$SLUG" "$2" "$3" "$4" <<'PY'
import json, os, sys, time
root, slug, sess, aid, days = sys.argv[1:]
age = int(days) * 86400
sub = os.path.join(root, ".claude", "projects", slug, sess, "subagents")
now = time.time()
jsonl = os.path.join(sub, "agent-%s.jsonl" % aid)
meta = os.path.join(sub, "agent-%s.meta.json" % aid)
with open(jsonl, "w") as fh:
    for i in range(80):
        fh.write('{"type":"assistant","n":%d,"tag":"%s","text":"%s"}\n' % (i, aid, "pack my box with five dozen liquor jugs " * 4))
with open(meta, "w") as fh:
    json.dump({"agentType": "hmd:coder", "description": "fixture " + aid}, fh)
for path in (jsonl, meta):
    os.utime(path, (now - age, now - age))
PY
}

N=0
fresh() { N=$((N+1)); H="$WORK/h$N"; world "$H"; }
bare()  { N=$((N+1)); H="$WORK/h$N"; mkdir -p "$H"; }

SD() { printf '%s/.claude/projects/%s/%s/subagents' "$1" "$SLUG" "$2"; }                          # SD HOME SESSION
AF() { local d; d="$(SD "$1" "$2")"; printf '%s/agent-%s.jsonl %s/agent-%s.meta.json' "$d" "$3" "$d" "$3"; }   # AF HOME SESSION ID: an agent's two files
TR() { printf '%s/.claude/projects/%s/%s.jsonl' "$1" "$SLUG" "$2"; }                              # a session's main transcript
sel_files()  { echo "$(AF "$1" "$S1" a1old) $(AF "$1" "$S1" a2old)"; }                            # selected at 14 days
mid_files()  { echo "$(AF "$1" "$S1" a3mid)"; }                                                  # 10 days
four_files() { echo "$(AF "$1" "$S1" a5four)"; }                                                 # 4 days
two_files()  { echo "$(AF "$1" "$S1" a4two)"; }                                                  # 2 days
guarded()    { echo "$(AF "$1" "$S2" a6run) $(AF "$1" "$S3" a7act)"; }                           # old, but their session is running / was just written
bystanders() {
  local h="$1" p="$1/.claude/projects/$SLUG"
  echo "$(TR "$h" "$S1") $(TR "$h" "$S2") $(TR "$h" "$S3") $p/$S1/subagents/notes.txt $p/$S1/subagents/agent-sym.jsonl $p/$S1/tool-results/blob.txt $h/outside/target.jsonl $h/.claude/sessions/$LIVE_PID.json"
}
gz_of()      { local f out=""; for f in "$@"; do out="$out $f.gz"; done; echo "$out"; }
all_exist()  { local f; for f in "$@"; do [ -e "$f" ] || return 1; done; }
none_exist() { local f; for f in "$@"; do if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi; done; }
silent()     { [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; }

stamps() {   # mode, size, mtime and link target of each path: equal output = untouched
  python3 -I -c '
import os, sys
for p in sys.argv[1:]:
    st = os.lstat(p)
    print("%s|%o|%d|%d|%s" % (p, st.st_mode, st.st_size, st.st_mtime_ns, os.readlink(p) if os.path.islink(p) else ""))' "$@"
}
treebytes() {
  python3 -I -c '
import os, sys
total = 0
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        total += os.lstat(os.path.join(base, name)).st_size
print(total)' "$1/.claude/projects"
}
filecount() { find "$1/.claude/projects" -type f | wc -l | tr -d ' '; }
partials()  { find "$1/.claude/projects" -name '*.partial' | wc -l | tr -d ' '; }
sums()      { local f; for f in "$@"; do cksum < "$f"; done; }
gzsums()    { local f; for f in "$@"; do gzip -dc "$f" | cksum; done; }
mode_of()   { python3 -I -c 'import os, sys; print(" ".join("%o" % (os.stat(p).st_mode & 0o777) for p in sys.argv[1:]))' "$@"; }

LOGF()   { printf '%s/.heimdall/logs/agents-prune.log' "$1"; }
STAMPF() { printf '%s/.heimdall/agents-prune.stamp' "$1"; }
LOCKF()  { printf '%s/.heimdall/agents-prune.lock' "$1"; }
log_lines() { if [ -f "$(LOGF "$1")" ]; then wc -l < "$(LOGF "$1")" | tr -d ' '; else echo 0; fi; }
log_bytes() { sed -n 's/.*reclaimed [^(]*(\(-\{0,1\}[0-9]*\) bytes).*/\1/p' "$(LOGF "$1")"; }
stamp_age() { echo $(( $(date +%s) - $(cat "$1") )); }                                                                   # seconds since the stamp's epoch
fresh_stamp() { local age; age="$(stamp_age "$1")"; [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; }                             # written in the last minute, not in the future
set_stamp() { mkdir -p "$(dirname "$(STAMPF "$1")")"; printf '%s\n' "$2" > "$(STAMPF "$1")"; }                         # set_stamp HOME CONTENT
now_minus() { echo $(( $(date +%s) - $1 )); }

await() {        # await PATH -- the file shows up non-empty within 10 s (200 polls of 50 ms)
  local i=0
  while [ "$i" -lt 200 ]; do
    [ -s "$1" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}
stays_absent() { # stays_absent PATH -- the path does not appear within 1 s
  local i=0
  while [ "$i" -lt 20 ]; do
    [ -e "$1" ] && return 1
    sleep 0.05; i=$((i + 1))
  done
  return 0
}

# what an ambient session (a developer's own Claude Code, the sweep) may export and a scenario must not inherit
ENV_CLEAN=(-u CLAUDE_CONFIG_DIR -u HEIMDALL_HOME -u HMD_AUTO_PRUNE -u HMD_AUTO_PRUNE_DAYS -u HMD_AUTO_PRUNE_TIMEOUT_S
           -u CLAUDE_PLUGIN_ROOT -u HMD_HOOKS_METADATA -u HMD_GUARDRAILS_MANIFEST -u CLAUDE_CODE_CHILD_SESSION)

run_auto() {   # run_auto BIN HOME [NAME=VALUE ...] -- BIN against a fake HOME, from an empty cwd, no tty and no stdin; sets RC, fills $OUT and $ERR
  local bin="$1" home="$2"; shift 2
  ( cd "$CWD" && env "${ENV_CLEAN[@]}" HOME="$home" "$@" "$bin" >"$OUT" 2>"$ERR" </dev/null )
  RC=$?
}
auto() { local home="$1"; shift; run_auto "$AUTO" "$home" "$@"; }

mkfake() {     # mkfake DIR -- DIR/bin/heimdall-agents-auto-prune is a COPY of the wrapper: it looks for the prune tool beside itself
  mkdir -p "$1/bin" && cp "$AUTO" "$1/bin/heimdall-agents-auto-prune"
}

# A wrapper beside a RECORDING tool: what the tool was started with (its arguments, its CPU priority) is a file, and "the tool
# ran" is a file too. It answers like a tool with nothing to do, so the cases that are about the WRAPPER (which days it asks for,
# when it runs, where its state lives) cost no fixture and no second interpreter.
mkdir -p "$WORK/fake-out"
FK_REC="$WORK/fk-rec"; mkfake "$FK_REC"
cat > "$FK_REC/bin/heimdall-agents-prune" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$HMD_FAKE_DIR/argv"
ps -o nice= -p $$ | tr -d ' ' > "$HMD_FAKE_DIR/nice"
echo "hmd agents prune: nothing to prune"
EOF
chmod +x "$FK_REC/bin/heimdall-agents-prune"
rec() {        # rec HOME [NAME=VALUE ...] -- the wrapper beside the recording tool; the tool's files in $WORK/fake-out are cleared first
  local home="$1"; shift
  rm -f "$WORK/fake-out/argv" "$WORK/fake-out/nice"
  run_auto "$FK_REC/bin/heimdall-agents-auto-prune" "$home" HMD_FAKE_DIR="$WORK/fake-out" "$@"
}
argv_of()  { paste -sd'|' "$WORK/fake-out/argv" 2>/dev/null; }
tool_ran() { [ -e "$WORK/fake-out/argv" ]; }

# ══════════════════════════════════════════════════════════════════════════════
echo "1. wired: a SessionStart hook of its own, switchable, one recommended manifest row, a sidecar in sync"
# ══════════════════════════════════════════════════════════════════════════════
check "bin/heimdall-agents-auto-prune is executable" [ -x "$AUTO" ]
HOOK_CMD="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(contains("heimdall-agents-auto-prune"))] | first // empty' "$HOOKS")"
eq "hooks.json: exactly one SessionStart command runs heimdall-agents-auto-prune" 1 \
   "$(jq '[.hooks.SessionStart[]?.hooks[]?.command | select(contains("heimdall-agents-auto-prune"))] | length' "$HOOKS")"
check "hooks.json: that command can be extracted" test -n "$HOOK_CMD"
check_not "hooks.json: that command never says --delete (the hook cannot ask for one)" grep -q -- '--delete' <<<"$HOOK_CMD"
check "hooks.metadata.json: id agents-auto-prune, SessionStart, unlocked (so hmd hooks disable works), not remote-toggled" \
  jq -e '[.hooks[] | select(.id == "agents-auto-prune")] | length == 1 and .[0].event == "SessionStart" and .[0].locked == false and .[0].remote_toggle == false' "$META"
check "guardrails.manifest.json: ONE agents-auto-prune row, recommended, layer hook, on that hook" \
  jq -e '[.guardrails[] | select(.id == "agents-auto-prune")] | length == 1 and .[0].tier == "recommended" and .[0].layer == "hook" and .[0].hook == "agents-auto-prune"' "$MANIFEST"
check "heimdall-hooks check: the sidecar matches hooks.json (regenerated, not hand-typed)" "$HOOKTOOL" check --quiet

# ══════════════════════════════════════════════════════════════════════════════
echo "2. the first start of the day compresses the old finished agents, and nothing else"
# ══════════════════════════════════════════════════════════════════════════════
fresh
KEPT_BEFORE="$(stamps $(mid_files "$H") $(four_files "$H") $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"
SEL_SUMS="$(sums $(sel_files "$H"))"
FILES_BEFORE="$(filecount "$H")"
BYTES_BEFORE="$(treebytes "$H")"
auto "$H"
eq "first start: exits 0" 0 "$RC"
check "first start: prints nothing on stdout or stderr" silent
check "first start: the 4 old files are now .gz" all_exist $(gz_of $(sel_files "$H"))
check "first start: the originals are gone (replaced, not copied)" none_exist $(sel_files "$H")
eq "first start: each .gz reads back byte for byte" "$SEL_SUMS" "$(gzsums $(gz_of $(sel_files "$H")))"
eq "first start: nothing was deleted (the same number of files, the old ones renamed to .gz)" "$FILES_BEFORE" "$(filecount "$H")"
eq "first start: newer agents, running and just-written sessions, main transcripts, symlink and other files are untouched" \
   "$KEPT_BEFORE" "$(stamps $(mid_files "$H") $(four_files "$H") $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"
eq "first start: no .partial file left behind" 0 "$(partials "$H")"
eq "log: exactly one line" 1 "$(log_lines "$H")"
check "log: names the threshold" grep -q ' older-than=14d ' "$(LOGF "$H")"
check "log: says what was compressed" grep -q 'compressed 2 finished agents (4 files)' "$(LOGF "$H")"
check "log: starts with a UTC timestamp" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "$(LOGF "$H")"
eq "log: the bytes reclaimed are what the disk lost" "$((BYTES_BEFORE - $(treebytes "$H")))" "$(log_bytes "$H")"
check "stamp: holds the epoch seconds of this run" fresh_stamp "$(STAMPF "$H")"
eq "stamp and log are private (0600)" "600 600" "$(mode_of "$(STAMPF "$H")" "$(LOGF "$H")")"

# ══════════════════════════════════════════════════════════════════════════════
echo "3. the second start the same day does nothing; a day later it continues"
# ══════════════════════════════════════════════════════════════════════════════
add_agent "$H" "$S1" a8new 40
STAMP_BEFORE="$(cat "$(STAMPF "$H")")"
auto "$H"
eq "second start, same day: exits 0" 0 "$RC"
check "second start, same day: an agent that became old meanwhile is NOT compressed (nothing ran)" none_exist $(gz_of $(AF "$H" "$S1" a8new))
eq "second start, same day: still one log line" 1 "$(log_lines "$H")"
eq "second start, same day: the stamp is unchanged" "$STAMP_BEFORE" "$(cat "$(STAMPF "$H")")"
set_stamp "$H" "$(now_minus 82800)"
auto "$H"
check "23 h after the last run: still within the day, nothing compressed" none_exist $(gz_of $(AF "$H" "$S1" a8new))
set_stamp "$H" "$(now_minus 90000)"
auto "$H"
eq "25 h after the last run: exits 0" 0 "$RC"
check "25 h after the last run: it runs again and compresses the new one" all_exist $(gz_of $(AF "$H" "$S1" a8new))
eq "25 h after the last run: a second log line" 2 "$(log_lines "$H")"
eq "25 h after the last run: the new line counts only what this run compressed (1 agent, 2 files)" 1 \
   "$(tail -n 1 "$(LOGF "$H")" | grep -c 'compressed 1 finished agent (2 files)')"
check "25 h after the last run: the stamp is fresh again" fresh_stamp "$(STAMPF "$H")"

bare
set_stamp "$H" "not a number"
rec "$H"
check "a garbage stamp counts as due: the tool runs" tool_ran
check "a garbage stamp is replaced by a real epoch" fresh_stamp "$(STAMPF "$H")"
bare
set_stamp "$H" "$(( $(date +%s) + 86400 ))"
rec "$H"
check "a stamp from the future (a clock set back) counts as due: the tool runs" tool_ran
check "a stamp from the future is replaced by the present" fresh_stamp "$(STAMPF "$H")"

# ══════════════════════════════════════════════════════════════════════════════
echo "4. the switches: HMD_AUTO_PRUNE, HMD_AUTO_PRUNE_DAYS, HEIMDALL_HOME"
# ══════════════════════════════════════════════════════════════════════════════
fresh
BEFORE="$(stamps $(sel_files "$H") $(mid_files "$H"))"
for v in off OFF 0 false No; do
  auto "$H" HMD_AUTO_PRUNE="$v"
  eq "HMD_AUTO_PRUNE=$v: exits 0" 0 "$RC"
done
eq "HMD_AUTO_PRUNE off (five spellings): nothing compressed" "$BEFORE" "$(stamps $(sel_files "$H") $(mid_files "$H"))"
check_not "HMD_AUTO_PRUNE off: nothing created, not even \$HEIMDALL_HOME (no stamp, no lock, no log)" test -e "$H/.heimdall"
check "HMD_AUTO_PRUNE off: prints nothing" silent
for v in on maybe 1 ""; do
  bare; rec "$H" HMD_AUTO_PRUNE="$v"
  check "HMD_AUTO_PRUNE='$v': the tool runs (only off, 0, false and no turn it off)" tool_ran
done

# every HMD_AUTO_PRUNE_DAYS value, as the tool is asked for it: VALUE:DAYS-ASKED-FOR
for pair in 30:30 7:7 45:45 3:3 1:3 0:3 2:3 soon:14 -5:14 7d:14 1.5:14 " :14" 999999:14 :14; do
  v="${pair%:*}"; want="${pair##*:}"
  bare; rec "$H" HMD_AUTO_PRUNE_DAYS="$v"
  eq "HMD_AUTO_PRUNE_DAYS='$v': the tool is asked for --older-than ${want}d" "--compress|--older-than|${want}d" "$(argv_of)"
done
fresh
LOW_BEFORE="$(stamps $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"
auto "$H" HMD_AUTO_PRUNE_DAYS=1
check "HMD_AUTO_PRUNE_DAYS=1, the real tool: the log says older-than=3d (the floor)" grep -q ' older-than=3d ' "$(LOGF "$H")"
check "HMD_AUTO_PRUNE_DAYS=1, the real tool: the 4-day-old agent is compressed" all_exist $(gz_of $(four_files "$H"))
eq "HMD_AUTO_PRUNE_DAYS=1, the real tool: the 2-day-old agent, the running and just-written sessions' agents, the decoys: untouched at the lowest threshold" \
   "$LOW_BEFORE" "$(stamps $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"

bare; rec "$H" HEIMDALL_HOME="$WORK/elsewhere"
check "HEIMDALL_HOME: the stamp, the lock and the log live there" all_exist "$WORK/elsewhere/agents-prune.stamp" "$WORK/elsewhere/agents-prune.lock" "$WORK/elsewhere/logs/agents-prune.log"
check_not "HEIMDALL_HOME: and not under \$HOME/.heimdall" test -e "$H/.heimdall"
bare; rec "$H" HEIMDALL_HOME=relative-home
eq "HEIMDALL_HOME relative (the cwd, which a repository controls): exits 0" 0 "$RC"
check_not "HEIMDALL_HOME relative: the tool never ran" tool_ran
check_not "HEIMDALL_HOME relative: nothing created in the cwd" test -e "$CWD/relative-home"
if [ "$(id -u)" -ne 0 ]; then
  bare; mkdir -p "$WORK/ro"; chmod 500 "$WORK/ro"
  rec "$H" HEIMDALL_HOME="$WORK/ro/home"
  eq "HEIMDALL_HOME unwritable: exits 0, silently" "0 1" "$RC $(silent && echo 1 || echo 0)"
  check_not "HEIMDALL_HOME unwritable: the tool never ran (without a stamp it could run on every start)" tool_ran
  chmod 700 "$WORK/ro"
else
  echo "  (skipped: the unwritable-home case, root ignores directory modes)"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "5. never a delete: the tool is only ever asked for --compress --older-than <N>d, at the lowest CPU priority"
# ══════════════════════════════════════════════════════════════════════════════
bare; rec "$H"
eq "the tool is run with exactly --compress --older-than 14d" "--compress|--older-than|14d" "$(argv_of)"
eq "nothing to prune: one log line saying so" 1 "$(grep -c ' older-than=14d nothing to prune$' "$(LOGF "$H")")"
eq "the tool runs at the lowest CPU priority (nice 19)" 19 "$(cat "$WORK/fake-out/nice" 2>/dev/null)"
bare; rec "$H" HMD_AUTO_PRUNE_ACTION=delete HMD_AUTO_PRUNE_DELETE=1 HMD_AUTO_PRUNE_YES=1 YES=1
eq "no environment variable turns it into a delete or adds --yes" "--compress|--older-than|14d" "$(argv_of)"

# ══════════════════════════════════════════════════════════════════════════════
echo "6. a lock: held by another session, left by a dead one, and five sessions starting together"
# ══════════════════════════════════════════════════════════════════════════════
fresh
mkdir -p "$(dirname "$(LOCKF "$H")")"
python3 -I - "$(LOCKF "$H")" "$WORK/lock-ready" "$WORK/lock-release" <<'PY' &
import fcntl, os, sys, time
path, ready, release = sys.argv[1:4]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(ready, "w") as marker:
    marker.write("held\n")
deadline = time.time() + 30
while not os.path.exists(release) and time.time() < deadline:
    time.sleep(0.05)
PY
HOLDER=$!
disown "$HOLDER" 2>/dev/null
check "the test's lock holder is up" await "$WORK/lock-ready"
auto "$H"
eq "lock held by another session: exits 0" 0 "$RC"
check "lock held by another session: nothing compressed" none_exist $(gz_of $(sel_files "$H"))
check_not "lock held by another session: no stamp written (it did not run)" test -e "$(STAMPF "$H")"
eq "lock held by another session: no log line" 0 "$(log_lines "$H")"
kill -9 "$HOLDER" 2>/dev/null
i=0; while kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
HOLDER=""
auto "$H"
check "the holder was killed (kill -9): the lock FILE it left behind does not block the next run" all_exist $(gz_of $(sel_files "$H"))
eq "the holder was killed: one log line for that run" 1 "$(log_lines "$H")"

fresh
pids=""
for i in 1 2 3 4 5; do
  ( cd "$CWD" && env "${ENV_CLEAN[@]}" HOME="$H" "$AUTO" >/dev/null 2>&1 </dev/null ) &
  pids="$pids $!"
done
wait $pids
check "five sessions starting together: the old agents are compressed" all_exist $(gz_of $(sel_files "$H"))
eq "five sessions starting together: ONE run (one log line)" 1 "$(log_lines "$H")"
eq "five sessions starting together: no .partial left behind" 0 "$(partials "$H")"
eq "five sessions starting together: every file readable back" "$SEL_SUMS" "$(gzsums $(gz_of $(sel_files "$H")))"

# ══════════════════════════════════════════════════════════════════════════════
echo "7. a failed, hung or missing tool is one log line, and the wrapper still exits 0"
# ══════════════════════════════════════════════════════════════════════════════
FK2="$WORK/fk-fail"; mkfake "$FK2"
cat > "$FK2/bin/heimdall-agents-prune" <<'EOF'
#!/bin/sh
echo "hmd agents prune: cannot read /x: Permission denied; nothing was changed" >&2
exit 1
EOF
chmod +x "$FK2/bin/heimdall-agents-prune"
bare
run_auto "$FK2/bin/heimdall-agents-auto-prune" "$H"
eq "tool fails: the wrapper exits 0 and prints nothing" "0 1" "$RC $(silent && echo 1 || echo 0)"
eq "tool fails: ONE log line" 1 "$(log_lines "$H")"
check "tool fails: the line says exit 1 and why" grep -Eq 'exit 1: hmd agents prune: cannot read /x: Permission denied' "$(LOGF "$H")"
check "tool fails: the stamp is written anyway (a failing run is not retried by every session of the day)" test -s "$(STAMPF "$H")"

FK3="$WORK/fk-missing"; mkfake "$FK3"
bare
run_auto "$FK3/bin/heimdall-agents-auto-prune" "$H"
eq "tool missing: the wrapper exits 0 and prints nothing" "0 1" "$RC $(silent && echo 1 || echo 0)"
check "tool missing: the log line says heimdall-agents-prune was not found" grep -q 'heimdall-agents-prune not found' "$(LOGF "$H")"

FK4="$WORK/fk-sleep"; mkfake "$FK4"
cat > "$FK4/bin/heimdall-agents-prune" <<'EOF'
#!/bin/sh
echo $$ > "$HMD_FAKE_DIR/pid"
exec sleep 60
EOF
chmod +x "$FK4/bin/heimdall-agents-prune"
rm -f "$WORK/fake-out/pid"
bare
run_auto "$FK4/bin/heimdall-agents-auto-prune" "$H" HMD_FAKE_DIR="$WORK/fake-out" HMD_AUTO_PRUNE_TIMEOUT_S=1
eq "tool hangs: the wrapper gives up at HMD_AUTO_PRUNE_TIMEOUT_S and exits 0" 0 "$RC"
check "tool hangs: the log line says it timed out after 1s" grep -q 'timed out after 1s' "$(LOGF "$H")"
check "tool hangs: the tool was started" test -s "$WORK/fake-out/pid"
check_not "tool hangs: the hung tool was killed, not left running" kill -0 "$(cat "$WORK/fake-out/pid" 2>/dev/null || echo 99999999)"
rm -f "$WORK/fake-out/pid"
run_auto "$FK4/bin/heimdall-agents-auto-prune" "$H" HMD_FAKE_DIR="$WORK/fake-out" HMD_AUTO_PRUNE_TIMEOUT_S=1
check_not "tool hangs: the same day it is not started again" test -e "$WORK/fake-out/pid"

# ══════════════════════════════════════════════════════════════════════════════
echo "8. the real hook command: silent, detached, in its own session, switchable"
# ══════════════════════════════════════════════════════════════════════════════
run_hook() {   # run_hook ROOT HOME [NAME=VALUE ...] -- the REAL SessionStart command under sh -c (as Claude Code runs it), a payload on stdin; sets RC, fills $OUT and $ERR
  local root="$1" home="$2"; shift 2
  ( cd "$CWD" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup","session_id":"s-test"}' \
      | env "${ENV_CLEAN[@]}" CLAUDE_PLUGIN_ROOT="$root" HOME="$home" "$@" sh -c "$HOOK_CMD" >"$OUT" 2>"$ERR" )
  RC=$?
}

fresh
HOOK_KEPT_BEFORE="$(stamps $(mid_files "$H") $(four_files "$H") $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"
run_hook "$ROOT" "$H"
eq "hook: exits 0" 0 "$RC"
check "hook: prints nothing (a SessionStart hook's stdout reaches the model)" silent
check "hook: the detached job runs and logs" await "$(LOGF "$H")"
check "hook: ...and it compressed the old finished agents" all_exist $(gz_of $(sel_files "$H"))
eq "hook: ...and nothing else (newer agents, running sessions, decoys untouched)" \
   "$HOOK_KEPT_BEFORE" "$(stamps $(mid_files "$H") $(four_files "$H") $(two_files "$H") $(guarded "$H") $(bystanders "$H"))"

STUB="$WORK/stubroot"; MARK="$WORK/stubmark"
mkdir -p "$STUB/bin/lib" "$STUB/hooks"
cp "$ROOT/bin/lib/hook-enabled.sh" "$STUB/bin/lib/hook-enabled.sh"
cp "$META" "$STUB/hooks/hooks.metadata.json"
cat > "$STUB/bin/heimdall-agents-auto-prune" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" > "$HMD_STUB_DIR/started"
i=0
while [ ! -e "$HMD_STUB_DIR/release" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
echo done > "$HMD_STUB_DIR/done"
EOF
chmod +x "$STUB/bin/heimdall-agents-auto-prune"
bare
mkdir -p "$MARK"
( cd "$CWD" && printf '%s' '{}' | env "${ENV_CLEAN[@]}" CLAUDE_PLUGIN_ROOT="$STUB" HOME="$H" HMD_STUB_DIR="$MARK" sh -c "$HOOK_CMD" 2>&1 | cat > "$OUT" )
check "stub job: started (the hook launches the script it names)" await "$MARK/started"
check_not "hook: returned while the job still runs, and the job holds none of the hook's pipes (the pipe closed first)" test -e "$MARK/done"
STUB_PID=""; STUB_PGID=""
{ read -r STUB_PID STUB_PGID < "$MARK/started"; } 2>/dev/null || true
if [ -n "$STUB_PID" ]; then
  eq "hook: the job is a session leader of its own (setsid), so it outlives the hook's shell" "$STUB_PID" "$STUB_PGID"
else
  bad "hook: the job is a session leader of its own (the stub recorded no pid: it never started)"
fi
check "hook: nothing was printed through the pipe" test ! -s "$OUT"
: > "$MARK/release"
check "stub job: finishes once released" await "$MARK/done"

GH="$WORK/gh-home"; mkdir -p "$GH"
env "${ENV_CLEAN[@]}" HEIMDALL_HOME="$GH" "$GUARD" off agents-auto-prune >"$OUT" 2>"$ERR"; RC=$?
eq "hmd guardrails off agents-auto-prune: exit 0" 0 "$RC"
check "hmd guardrails off agents-auto-prune: the hook is listed in hooks-disabled" grep -qx agents-auto-prune "$GH/hooks-disabled"
rm -rf "$MARK"; mkdir -p "$MARK"
run_hook "$STUB" "$H" HEIMDALL_HOME="$GH" HMD_STUB_DIR="$MARK"
eq "switched off: the hook exits 0" 0 "$RC"
check "switched off: the hook launches nothing" stays_absent "$MARK/started"
env "${ENV_CLEAN[@]}" HEIMDALL_HOME="$GH" "$GUARD" on agents-auto-prune >"$OUT" 2>"$ERR"; RC=$?
eq "hmd guardrails on agents-auto-prune: exit 0" 0 "$RC"
run_hook "$STUB" "$H" HEIMDALL_HOME="$GH" HMD_STUB_DIR="$MARK" CLAUDE_CODE_CHILD_SESSION=1
eq "a subagent's own session start (CLAUDE_CODE_CHILD_SESSION set): the hook exits 0" 0 "$RC"
check "a subagent's own session start: the hook launches nothing (every subagent start fires SessionStart too)" stays_absent "$MARK/started"
run_hook "$STUB" "$H" HEIMDALL_HOME="$GH" HMD_STUB_DIR="$MARK"
check "a top-level session start, switched back on: the hook launches the job again" await "$MARK/started"
: > "$MARK/release"
await "$MARK/done" >/dev/null 2>&1

# ══════════════════════════════════════════════════════════════════════════════
echo "9. documented"
# ══════════════════════════════════════════════════════════════════════════════
for needle in 'HMD_AUTO_PRUNE=off' 'HMD_AUTO_PRUNE_DAYS' 'hmd guardrails off agents-auto-prune' 'agents-prune.log' 'never deletes'; do
  check "docs/INSTALL.md says: $needle" grep -qF -- "$needle" "$ROOT/docs/INSTALL.md"
done
unreleased_mentions() { [ "$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$ROOT/CHANGELOG.md" | grep -c -- "$1")" -ge 1 ]; }
check "CHANGELOG.md [Unreleased] names the agents-auto-prune hook" unreleased_mentions agents-auto-prune
check "CHANGELOG.md [Unreleased] names the off switch" unreleased_mentions 'HMD_AUTO_PRUNE=off'

echo
printf "  agents-auto-prune: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
