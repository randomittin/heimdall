#!/usr/bin/env bash
# test/agents-prune.test.sh -- acceptance for `hmd agents prune` (bin/heimdall-agents-prune), the OPT-IN clean-up of the
# transcripts of old, finished subagents.
#
# WHY IT EXISTS. docs/analysis/2026-11-20-finished-agents-still-listed.md measured 8.7 GB of subagent transcripts in ONE long
# session (2,051 files, five over 425 MB) and named a prune as the only fix that recovers real space; it is opt-in because those
# transcripts are also the only record of what an agent did. The tool can delete a person's history, so what can go wrong,
# in this order (each guard below has an assertion that goes RED when the guard is removed):
#   1. Touching what it must never touch: a main session transcript, the subagents of a RUNNING session (a live pid in
#      <config>/sessions/*.json, or anything written in the last 10 minutes), an agent newer than the threshold, a file in a
#      subagents dir that is not agent-*.jsonl / .meta.json, a symlink (never followed), anything outside
#      <config>/projects/<slug>/<session>/subagents/.
#   2. Acting when only asked to look: the default is a dry run, --dry-run beats --compress and --delete, --delete needs --yes
#      or a "yes" typed at a terminal (and an agent written to while the prompt waited is kept).
#   3. Losing data while "compressing": the .gz must read back byte for byte, keep mode and mtime, never replace a .gz that is
#      already there and never be trusted when the source grew while it was being written.
#   4. Lying about bytes: "reclaimed" is what the disk lost.
#
# Hermetic: every scenario runs the real script against a FAKE HOME (HOME=<tmp>, CLAUDE_CONFIG_DIR unset), so no real
# ~/.claude is read. The "running" session is a real live process (a background sleep). The last section runs a COPY of
# bin/heimdall beside the real prune script and a stub heimdall-bg-sessions: `hmd agents prune ...` must reach the script,
# `hmd agents` must still list background sessions, `hmd agents --help` must mention prune.
# budget: a few seconds solo (about 60 runs of a python script, five dispatcher runs, one 16 MB compress for the growth race;
# the only polling is that race's poller, capped at 5 s and over as soon as the compress starts).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRUNE="$ROOT/bin/heimdall-agents-prune"
HMD="$ROOT/bin/heimdall"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
check()     { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }
eq()        { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hmd-prune-test.XXXXXX")"
OUT="$WORK/out"; ERR="$WORK/err"
sleep 300 &
LIVE_PID=$!
disown "$LIVE_PID" 2>/dev/null   # off the job table: killing it at exit prints no "Terminated" line
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

SLUG_A="-Users-x-alpha"; SLUG_B="-Users-x-beta"
S1="11111111-1111-4111-8111-111111111111"   # finished long ago: two old agents, a 10-day-old one, one whose meta is 1 day old
S2="22222222-2222-4222-8222-222222222222"   # RUNNING: a live pid in <config>/sessions
S3="33333333-3333-4333-8333-333333333333"   # not recorded as running, but its main transcript was written 2 minutes ago
S4="44444444-4444-4444-8444-444444444444"   # a record with a DEAD pid: protects nothing
S5="55555555-5555-4555-8555-555555555555"   # another project (beta)
S6="66666666-6666-4666-8666-666666666666"   # an agent written 3 minutes ago

# world HOME -- the fake HOME tree. Selected by default (older than 14d, session finished): a1old a2old a8dead b1old (8 files).
# Kept: a3mid and a4mix (newer than 14d), a9new (3 min old), a6run (live pid), a7act (session written 2 min ago).
world() {
  python3 -I - "$1" "$LIVE_PID" "$SLUG_A" "$SLUG_B" "$S1" "$S2" "$S3" "$S4" "$S5" "$S6" <<'PY'
import json, os, sys, time
root, live_pid, A, B, S1, S2, S3, S4, S5, S6 = sys.argv[1:]
live_pid = int(live_pid)
now = time.time()
DAY = 86400
proj = os.path.join(root, ".claude", "projects")

def stamp(path, age):
    os.utime(path, (now - age, now - age))

def put(path, age, lines, tag, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for i in range(lines):
            fh.write('{"type":"assistant","n":%d,"tag":"%s","text":"%s"}\n' % (i, tag, "the quick brown fox jumps " * 5))
    os.chmod(path, mode)
    stamp(path, age)

def agent(slug, sess, aid, age, lines, meta_age=None):
    sub = os.path.join(proj, slug, sess, "subagents")
    put(os.path.join(sub, "agent-%s.jsonl" % aid), age, lines, aid)
    meta = os.path.join(sub, "agent-%s.meta.json" % aid)
    with open(meta, "w") as fh:
        json.dump({"agentType": "hmd:coder", "description": "fixture " + aid}, fh)
    os.chmod(meta, 0o644)
    stamp(meta, age if meta_age is None else meta_age)

def main_transcript(slug, sess, age):
    put(os.path.join(proj, slug, sess + ".jsonl"), age, 30, "main-" + sess[:4])

main_transcript(A, S1, 40 * DAY)
agent(A, S1, "a1old", 30 * DAY, 150)
agent(A, S1, "a2old", 20 * DAY, 90)
agent(A, S1, "a3mid", 10 * DAY, 70)
agent(A, S1, "a4mix", 30 * DAY, 80, meta_age=1 * DAY)
main_transcript(A, S2, 40 * DAY)
agent(A, S2, "a6run", 40 * DAY, 100)
main_transcript(A, S3, 120)
agent(A, S3, "a7act", 40 * DAY, 110)
main_transcript(A, S4, 35 * DAY)
agent(A, S4, "a8dead", 35 * DAY, 200)
main_transcript(B, S5, 25 * DAY)
agent(B, S5, "b1old", 25 * DAY, 60)
main_transcript(A, S6, 40 * DAY)
agent(A, S6, "a9new", 180, 50)

sessions = os.path.join(root, ".claude", "sessions")
os.makedirs(sessions)
for pid, sid in ((live_pid, S2), (99999999, S4)):
    with open(os.path.join(sessions, "%d.json" % pid), "w") as fh:
        json.dump({"pid": pid, "sessionId": sid, "cwd": "/Users/x/alpha", "kind": "interactive", "status": "idle"}, fh)
with open(os.path.join(sessions, "garbled.json"), "w") as fh:
    fh.write("{not json")

# Decoys: old enough to be selected if the tool were careless about WHERE it looks.
outside = os.path.join(root, "outside")
put(os.path.join(outside, "slug", "OS", "subagents", "agent-out1.jsonl"), 40 * DAY, 20, "out1")
os.symlink(os.path.join(outside, "slug"), os.path.join(proj, "-Users-x-link"))
put(os.path.join(outside, "target.jsonl"), 40 * DAY, 20, "target")
os.symlink(os.path.join(outside, "target.jsonl"), os.path.join(proj, A, S1, "subagents", "agent-sym.jsonl"))
put(os.path.join(root, "projects", A, S1, "subagents", "agent-lookalike.jsonl"), 40 * DAY, 20, "lookalike")
put(os.path.join(root, ".claude", "agent-loose.jsonl"), 40 * DAY, 20, "loose")
put(os.path.join(proj, A, S1, "subagents", "notes.txt"), 40 * DAY, 20, "notes")
put(os.path.join(proj, A, S1, "tool-results", "blob.txt"), 40 * DAY, 20, "blob")
PY
}

N=0
fresh() { N=$((N+1)); H="$WORK/h$N"; world "$H"; }

SD() { printf '%s/.claude/projects/%s/%s/subagents' "$1" "$2" "$3"; }              # SD HOME SLUG SESSION
AF() { local d; d="$(SD "$1" "$2" "$3")"; printf '%s/agent-%s.jsonl %s/agent-%s.meta.json' "$d" "$4" "$d" "$4"; }   # an agent's two files
TR() { printf '%s/.claude/projects/%s/%s.jsonl' "$1" "$2" "$3"; }                  # a session's main transcript
selected_files() { local h="$1"; echo "$(AF "$h" "$SLUG_A" "$S1" a1old) $(AF "$h" "$SLUG_A" "$S1" a2old) $(AF "$h" "$SLUG_A" "$S4" a8dead) $(AF "$h" "$SLUG_B" "$S5" b1old)"; }
age_kept_files() { local h="$1"; echo "$(AF "$h" "$SLUG_A" "$S1" a3mid) $(AF "$h" "$SLUG_A" "$S1" a4mix)"; }
guarded_files()  { local h="$1"; echo "$(AF "$h" "$SLUG_A" "$S2" a6run) $(AF "$h" "$SLUG_A" "$S3" a7act) $(AF "$h" "$SLUG_A" "$S6" a9new)"; }
bystanders() {
  local h="$1" p="$1/.claude/projects"
  echo "$(TR "$h" "$SLUG_A" "$S1") $(TR "$h" "$SLUG_A" "$S2") $(TR "$h" "$SLUG_A" "$S3") $(TR "$h" "$SLUG_A" "$S4") $(TR "$h" "$SLUG_B" "$S5") $(TR "$h" "$SLUG_A" "$S6")" \
       "$p/$SLUG_A/$S1/subagents/notes.txt $p/$SLUG_A/$S1/tool-results/blob.txt $h/outside/target.jsonl $h/outside/slug/OS/subagents/agent-out1.jsonl" \
       "$h/projects/$SLUG_A/$S1/subagents/agent-lookalike.jsonl $h/.claude/agent-loose.jsonl $h/.claude/sessions/$LIVE_PID.json"
}
all_exist()  { local f; for f in "$@"; do [ -e "$f" ] || return 1; done; }
none_exist() { local f; for f in "$@"; do if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi; done; }

sizeof() { python3 -I -c 'import os, sys; print(sum(os.lstat(p).st_size for p in sys.argv[1:]))' "$@"; }
treebytes() {
  python3 -I -c '
import os, sys
total = 0
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        total += os.lstat(os.path.join(base, name)).st_size
print(total)' "$1/.claude/projects"
}
snap() {   # every path under $1 with mode, size, mtime and link target: equal snapshots = nothing touched
  python3 -I -c '
import os, sys
rows = []
for base, dirs, files in os.walk(sys.argv[1]):
    for name in dirs + files:
        path = os.path.join(base, name)
        st = os.lstat(path)
        rows.append("%s|%o|%d|%d|%s" % (os.path.relpath(path, sys.argv[1]), st.st_mode, st.st_size, st.st_mtime_ns, os.readlink(path) if os.path.islink(path) else ""))
print("\n".join(sorted(rows)))' "$1"
}
stamps() { python3 -I -c 'import os, sys; print(" ".join("%o:%d" % (os.stat(p).st_mode & 0o777, os.stat(p).st_mtime_ns) for p in sys.argv[1:]))' "$@"; }
sums() { local f; for f in "$@"; do cksum < "$f"; done; }
gzsums() { local f; for f in "$@"; do gzip -dc "$f" | cksum; done; }
gz_of() { local f out=""; for f in "$@"; do out="$out $f.gz"; done; echo "$out"; }

prune() {   # prune HOME [ARGS...] -- the real script against a fake HOME, no tty, no stdin; sets RC, fills $OUT and $ERR
  local home="$1"; shift
  env -u CLAUDE_CONFIG_DIR HOME="$home" "$PRUNE" "$@" >"$OUT" 2>"$ERR" </dev/null
  RC=$?
}
listed_bytes()    { sed -n 's/^ *selected .*(\([0-9]*\) bytes)$/\1/p' "$OUT"; }
reclaimed_bytes() { sed -n 's/.*reclaimed [^(]*(\(-\{0,1\}[0-9]*\) bytes).*/\1/p' "$OUT"; }

# pty_prune HOME ANSWER TOUCH_FILE ARGS... -- the script on a pseudo terminal: waits for the "Type yes" prompt, optionally
# touches TOUCH_FILE ("" = none) while the prompt waits, then types ANSWER. Prints what the terminal showed; exits with the script's status.
pty_prune() {
  env -u CLAUDE_CONFIG_DIR HOME="$1" python3 -I - "$PRUNE" "${@:2}" <<'PY'
import os, pty, select, sys, time
prune, answer, touch, *args = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(prune, [prune] + args)
seen, typed, deadline = b"", False, time.time() + 30
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.5)
    if not ready:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    seen += data
    if not typed and b"Type yes" in seen:
        if touch:
            os.utime(touch, None)
        os.write(fd, answer.encode() + b"\n")
        typed = True
else:
    os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
sys.stdout.write(seen.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY
}

# ══════════════════════════════════════════════════════════════════════════════
echo "1. the tool exists and says what it is"
# ══════════════════════════════════════════════════════════════════════════════
check "bin/heimdall-agents-prune is executable" [ -x "$PRUNE" ]
prune "$WORK" --help
eq "--help exits 0" 0 "$RC"
for flag in --older-than --compress --delete --dry-run --project --yes; do
  check "--help names $flag" grep -q -- "$flag" "$OUT"
done
check "--help says --delete never runs by itself" grep -qi -- '--delete never runs by itself' "$OUT"
check "--help names the one automatic caller, what it asks for and its off switch" grep -q 'HMD_AUTO_PRUNE=off' "$OUT"
check "--help tells how to read a compressed transcript back" grep -q 'gzip -dc' "$OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "2. default = dry run: lists count and bytes, touches nothing"
# ══════════════════════════════════════════════════════════════════════════════
fresh
BEFORE="$(snap "$H")"
prune "$H"
eq "no flags: exits 0" 0 "$RC"
check "no flags: says it is a dry run and nothing changed" grep -q 'dry run, nothing changed' "$OUT"
check "no flags: lists the 4 finished agents older than 14d (8 files)" grep -Eq 'selected +4 finished agents older than 14d: 8 files' "$OUT"
eq "no flags: the bytes listed are the bytes of the 8 selected files" "$(sizeof $(selected_files "$H"))" "$(listed_bytes)"
check "no flags: counts what it keeps (3 newer than 14d, 2 in running sessions)" grep -Eq 'kept +3 newer than 14d, 2 in running sessions' "$OUT"
check "no flags: shows how to act" grep -q -- '--compress' "$OUT"
eq "no flags: nothing under the fake HOME changed" "$BEFORE" "$(snap "$H")"

prune "$H" --delete --yes --dry-run
eq "--delete --yes --dry-run: exits 0" 0 "$RC"
check "--delete --yes --dry-run: says what it would delete" grep -q 'would delete 8 files' "$OUT"
eq "--delete --yes --dry-run: nothing changed (--dry-run beats --delete and --yes)" "$BEFORE" "$(snap "$H")"
prune "$H" --compress --dry-run
eq "--compress --dry-run: exits 0" 0 "$RC"
check "--compress --dry-run: says what it would gzip" grep -q 'would gzip 8 files' "$OUT"
eq "--compress --dry-run: nothing changed" "$BEFORE" "$(snap "$H")"

# ══════════════════════════════════════════════════════════════════════════════
echo "3. --delete: needs a yes, then removes exactly the selected agents and says what the disk gained"
# ══════════════════════════════════════════════════════════════════════════════
prune "$H" --delete
eq "--delete with no --yes and no terminal: exit 3 (needs a yes)" 3 "$RC"
check "--delete with no --yes: stderr names --yes" grep -q -- '--yes' "$ERR"
eq "--delete with no --yes: nothing deleted" "$BEFORE" "$(snap "$H")"

BYTES_BEFORE="$(treebytes "$H")"
SEL_BYTES="$(sizeof $(selected_files "$H"))"
prune "$H" --delete --yes
eq "--delete --yes: exits 0" 0 "$RC"
check "--delete --yes: the 4 old finished agents are gone (both files each)" none_exist $(selected_files "$H")
check "--delete --yes: agents newer than 14d stay (a3mid, and a4mix whose meta is 1 day old)" all_exist $(age_kept_files "$H")
check "--delete --yes: the running session's agent stays (live pid)" all_exist $(AF "$H" "$SLUG_A" "$S2" a6run)
check "--delete --yes: an agent of a session written 2 minutes ago stays" all_exist $(AF "$H" "$SLUG_A" "$S3" a7act)
check "--delete --yes: an agent written 3 minutes ago stays" all_exist $(AF "$H" "$SLUG_A" "$S6" a9new)
check "--delete --yes: main transcripts, non-agent files and everything outside projects/ stay" all_exist $(bystanders "$H")
check "--delete --yes: a symlinked project dir and a symlinked agent file are left alone, never followed" test -L "$H/.claude/projects/-Users-x-link" -a -L "$(SD "$H" "$SLUG_A" "$S1")/agent-sym.jsonl"
check "--delete --yes: it says what it deleted" grep -Eq 'deleted 4 finished agents \(8 files\)' "$OUT"
eq "--delete --yes: the bytes it says it reclaimed are the bytes of the selected files" "$SEL_BYTES" "$(reclaimed_bytes)"
eq "--delete --yes: and are what the tree really lost" "$((BYTES_BEFORE - $(treebytes "$H")))" "$(reclaimed_bytes)"

# ══════════════════════════════════════════════════════════════════════════════
echo "4. --compress: lossless, in place, same mode and mtime, idempotent; --delete later removes the .gz"
# ══════════════════════════════════════════════════════════════════════════════
fresh
SEL="$(selected_files "$H")"
SUMS_BEFORE="$(sums $SEL)"
STAMPS_BEFORE="$(stamps $SEL)"
BYTES_BEFORE="$(treebytes "$H")"
prune "$H" --compress
eq "--compress: exits 0" 0 "$RC"
check "--compress: the plain files of the 4 selected agents are gone" none_exist $SEL
check "--compress: each became a .gz" all_exist $(gz_of $SEL)
eq "--compress: every .gz reads back byte for byte (gzip -dc)" "$SUMS_BEFORE" "$(gzsums $(gz_of $SEL))"
eq "--compress: every .gz keeps the mode and the mtime of its file (so the age survives)" "$STAMPS_BEFORE" "$(stamps $(gz_of $SEL))"
check "--compress: agents newer than 14d, guarded sessions and bystanders are untouched" all_exist $(age_kept_files "$H") $(guarded_files "$H") $(bystanders "$H")
check "--compress: it says what it compressed" grep -Eq 'compressed 4 finished agents \(8 files\)' "$OUT"
RECLAIMED="$(reclaimed_bytes)"
eq "--compress: the bytes it says it reclaimed are what the tree really lost" "$((BYTES_BEFORE - $(treebytes "$H")))" "$RECLAIMED"
check "--compress: and that is a real saving" test "$RECLAIMED" -gt 1000

AFTER_COMPRESS="$(snap "$H")"
prune "$H" --compress
eq "--compress again: exits 0" 0 "$RC"
check "--compress again: says nothing is left to compress" grep -q 'nothing left to compress' "$OUT"
eq "--compress again: nothing changed" "$AFTER_COMPRESS" "$(snap "$H")"

prune "$H" --delete --yes
eq "--delete --yes after --compress: exits 0" 0 "$RC"
check "--delete --yes after --compress: the .gz of the old agents are removed too" none_exist $(gz_of $SEL)
check "--delete --yes after --compress: the rest is still there" all_exist $(age_kept_files "$H") $(guarded_files "$H") $(bystanders "$H")

# A .gz that is already there is never overwritten: the agent is left whole, the others go on, the run says so.
fresh
SEL="$(selected_files "$H")"
CONFLICT="$(SD "$H" "$SLUG_A" "$S1")/agent-a1old.jsonl.gz"
printf 'someone else wrote this\n' | gzip > "$CONFLICT"
python3 -I -c 'import os, sys, time; old = time.time() - 30 * 86400; os.utime(sys.argv[1], (old, old))' "$CONFLICT"
CONFLICT_SUM="$(cksum < "$CONFLICT")"
prune "$H" --compress
eq "--compress with a .gz in the way: exit 1" 1 "$RC"
check "--compress with a .gz in the way: stderr says it already exists" grep -q 'already exists' "$ERR"
check "--compress with a .gz in the way: that agent's files are left whole" all_exist $(AF "$H" "$SLUG_A" "$S1" a1old)
eq "--compress with a .gz in the way: the .gz that was there is untouched" "$CONFLICT_SUM" "$(cksum < "$CONFLICT")"
check "--compress with a .gz in the way: the other 3 agents were still compressed" all_exist $(gz_of $(AF "$H" "$SLUG_A" "$S1" a2old) $(AF "$H" "$SLUG_A" "$S4" a8dead) $(AF "$H" "$SLUG_B" "$S5" b1old))

# A source that grows while it is being compressed is not trusted: the .gz is dropped, the file kept whole.
R="$WORK/race"
RS="$R/.claude/projects/-Users-x-race/77777777-7777-4777-8777-777777777777/subagents"
python3 -I - "$RS" <<'PY'
import os, sys, time
sub = sys.argv[1]
os.makedirs(sub)
old = time.time() - 30 * 86400
for name, data in (("agent-race1.jsonl", os.urandom(16 * 1024 * 1024)), ("agent-race1.meta.json", b'{"agentType":"hmd:coder"}')):
    path = os.path.join(sub, name)
    with open(path, "wb") as fh:
        fh.write(data)
    os.utime(path, (old, old))
PY
(
  i=0
  while [ ! -e "$RS/agent-race1.jsonl.gz.partial" ] && [ "$i" -lt 1000 ]; do i=$((i+1)); sleep 0.005; done
  [ -e "$RS/agent-race1.jsonl.gz.partial" ] && printf '{"late":"append"}\n' >> "$RS/agent-race1.jsonl"
) &
POLL=$!
prune "$R" --compress
wait "$POLL"
eq "--compress of a file that grew meanwhile: exit 1" 1 "$RC"
check "--compress of a file that grew meanwhile: stderr says it changed" grep -q 'changed while' "$ERR"
eq "--compress of a file that grew meanwhile: the appended line is still in the original" '{"late":"append"}' "$(tail -c 18 "$RS/agent-race1.jsonl")"
check_not "--compress of a file that grew meanwhile: no .gz and no .partial left behind" test -e "$RS/agent-race1.jsonl.gz" -o -e "$RS/agent-race1.jsonl.gz.partial"
check "--compress of a file that grew meanwhile: its meta was not touched either" all_exist "$RS/agent-race1.meta.json"

# ══════════════════════════════════════════════════════════════════════════════
echo "5. --delete at a terminal: a typed yes, and a session written to while the prompt waited is kept"
# ══════════════════════════════════════════════════════════════════════════════
fresh
BEFORE="$(snap "$H")"
pty_prune "$H" no "" --delete >"$OUT" 2>&1
RC=$?
eq "--delete at a terminal, answered no: exit 3" 3 "$RC"
check "--delete at a terminal: it asked, with the count" grep -Eq 'Delete 4 finished agents \(8 files' "$OUT"
eq "--delete at a terminal, answered no: nothing deleted" "$BEFORE" "$(snap "$H")"

LATE="$(SD "$H" "$SLUG_A" "$S1")/agent-a2old.jsonl"
pty_prune "$H" yes "$LATE" --delete >"$OUT" 2>&1
RC=$?
eq "--delete at a terminal, answered yes: exit 0" 0 "$RC"
check "--delete at a terminal, answered yes: the finished agents of the sessions left alone are gone" none_exist $(AF "$H" "$SLUG_A" "$S4" a8dead) $(AF "$H" "$SLUG_B" "$S5" b1old)
check "--delete at a terminal: the session written to while the prompt waited is kept whole (a2old was touched, a1old shares its session)" all_exist $(AF "$H" "$SLUG_A" "$S1" a1old) $(AF "$H" "$SLUG_A" "$S1" a2old)
check "--delete at a terminal: it deleted 2, not the 4 it had asked about" grep -Eq 'deleted 2 finished agents \(4 files\)' "$OUT"

# ══════════════════════════════════════════════════════════════════════════════
echo "6. --older-than, --project, bad input"
# ══════════════════════════════════════════════════════════════════════════════
fresh
BEFORE="$(snap "$H")"
prune "$H" --older-than 5d
check "--older-than 5d: the 10-day-old agent is selected too (5 agents, 10 files)" grep -Eq 'selected +5 finished agents older than 5d: 10 files' "$OUT"
prune "$H" --older-than 14 --delete --yes
eq "--older-than 14 (no unit): exit 2 (usage)" 2 "$RC"
check "--older-than 14 (no unit): stderr shows the accepted form" grep -Eq 'unit.*14d' "$ERR"
for bad_age in soon -3d 5y ""; do
  prune "$H" --older-than "$bad_age" --delete --yes
  eq "--older-than '$bad_age': exit 2 (usage)" 2 "$RC"
done
prune "$H" --compress --delete
eq "--compress with --delete: exit 2 (pick one)" 2 "$RC"
eq "bad input never touched anything" "$BEFORE" "$(snap "$H")"

prune "$H" --delete --yes --older-than 1m
eq "--older-than 1m: exits 0" 0 "$RC"
check "--older-than 1m: a short threshold selects agents of any age (a3mid, a4mix gone)" none_exist $(age_kept_files "$H")
check "--older-than 1m: but nothing written in the last 10 minutes is ever touched (a9new stays)" all_exist $(AF "$H" "$SLUG_A" "$S6" a9new)
check "--older-than 1m: running sessions are still protected" all_exist $(AF "$H" "$SLUG_A" "$S2" a6run) $(AF "$H" "$SLUG_A" "$S3" a7act)

fresh
prune "$H" --project /Users/x/alpha --delete --yes
eq "--project: exits 0" 0 "$RC"
check "--project: that project's old agents are gone" none_exist $(AF "$H" "$SLUG_A" "$S1" a1old) $(AF "$H" "$SLUG_A" "$S1" a2old) $(AF "$H" "$SLUG_A" "$S4" a8dead)
check "--project: another project's old agent is untouched" all_exist $(AF "$H" "$SLUG_B" "$S5" b1old)
check "--project: the scope line names the project" grep -q 'project /Users/x/alpha' "$OUT"
BEFORE="$(snap "$H")"
prune "$H" --project /Users/x/nope --delete --yes
eq "--project with no such project: exit 2" 2 "$RC"
check "--project with no such project: stderr says so" grep -q 'no Claude project' "$ERR"
eq "--project with no such project: nothing changed" "$BEFORE" "$(snap "$H")"

# ══════════════════════════════════════════════════════════════════════════════
echo "7. where it looks: CLAUDE_CONFIG_DIR, an empty machine, an unreadable sessions dir"
# ══════════════════════════════════════════════════════════════════════════════
fresh
env CLAUDE_CONFIG_DIR="$H/.claude" HOME="$WORK/nohome" "$PRUNE" >"$OUT" 2>"$ERR" </dev/null
check "CLAUDE_CONFIG_DIR is honoured (HOME has no .claude, the config dir does)" grep -Eq 'selected +4 finished agents' "$OUT"
mkdir -p "$WORK/empty"
prune "$WORK/empty" --delete --yes
eq "no projects directory at all: exit 0" 0 "$RC"
check "no projects directory at all: says there is nothing to prune" grep -q 'nothing to prune' "$OUT"

rm -rf "$H/.claude/sessions"; printf 'not a directory\n' > "$H/.claude/sessions"
BEFORE="$(snap "$H")"
prune "$H" --delete --yes
eq "sessions path unreadable: exit 1" 1 "$RC"
check "sessions path unreadable: stderr says it cannot tell which sessions run" grep -q 'cannot read' "$ERR"
eq "sessions path unreadable: nothing deleted (it will not guess which sessions run)" "$BEFORE" "$(snap "$H")"

# ══════════════════════════════════════════════════════════════════════════════
echo "8. through the real dispatcher: hmd agents prune ..., hmd agents, hmd agents --help"
# ══════════════════════════════════════════════════════════════════════════════
PLUG="$WORK/plugin"
mkdir -p "$PLUG/bin" "$PLUG/.claude-plugin" "$WORK/hd-home" "$WORK/cwd"
cp "$HMD" "$PLUG/bin/heimdall"
cp "$PRUNE" "$PLUG/bin/heimdall-agents-prune" 2>/dev/null
touch "$WORK/hd-home/setup-done"
printf '#!/bin/sh\nexit 0\n' > "$PLUG/bin/claude"
printf '#!/bin/sh\nprintf "bg-sessions ARGS: %%s\\n" "$*" >> "${HMD_STUB_OUT:-/dev/null}"\n' > "$PLUG/bin/heimdall-bg-sessions"
chmod +x "$PLUG/bin/"*
STUB_OUT="$WORK/stub-out"
dispatch() {   # dispatch HOME ARGS... -- the dispatcher copy in $WORK/cwd, fake HOME, stubs first on PATH; sets RC, fills $OUT and $ERR
  local home="$1"; shift
  : > "$STUB_OUT"
  ( cd "$WORK/cwd" && env -u CLAUDE_CONFIG_DIR PATH="$PLUG/bin:$PATH" HOME="$home" HEIMDALL_HOME="$WORK/hd-home" \
      HEIMDALL_NO_INTRO=1 HEIMDALL_NO_UPDATE_CHECK=1 HMD_STUB_OUT="$STUB_OUT" bash "$PLUG/bin/heimdall" "$@" ) >"$OUT" 2>"$ERR" </dev/null
  RC=$?
}

fresh
dispatch "$H" agents prune --older-than 5d
eq "hmd agents prune: exits 0" 0 "$RC"
check "hmd agents prune: reaches the prune script with its arguments (5d, 5 agents)" grep -Eq 'selected +5 finished agents older than 5d' "$OUT"
check "hmd agents prune: does not list background sessions" test ! -s "$STUB_OUT"
dispatch "$H" agents prune --help
check "hmd agents prune --help: the script's own help" grep -q -- '--older-than' "$OUT"

dispatch "$H" agents --newer-flag
eq "hmd agents <other flags>: exits 0" 0 "$RC"
check "hmd agents <other flags>: still lists background sessions, args forwarded" grep -Eq "bg-sessions ARGS: list --dir .*/cwd --newer-flag$" "$STUB_OUT"
dispatch "$H" agents
check "hmd agents: still lists this directory's background sessions" grep -Eq "bg-sessions ARGS: list --dir .*/cwd$" "$STUB_OUT"

dispatch "$H" agents --help
eq "hmd agents --help: exits 0" 0 "$RC"
check "hmd agents --help: mentions the prune verb" grep -q 'hmd agents prune' "$OUT"
check "hmd agents --help: mentions its options" grep -q -- '--older-than' "$OUT"
check "hmd agents --help: says --delete never runs by itself" grep -qi -- '--delete never runs by itself' "$OUT"
check "hmd agents --help: names the off switch of the daily compress" grep -q 'HMD_AUTO_PRUNE=off' "$OUT"
check "hmd agents --help: does not go ask for background sessions" test ! -s "$STUB_OUT"

rm -f "$PLUG/bin/heimdall-agents-prune"
dispatch "$H" agents prune
eq "hmd agents prune with the script missing: exit 1" 1 "$RC"
check "hmd agents prune with the script missing: says which file" grep -q 'heimdall-agents-prune not found' "$ERR"

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
