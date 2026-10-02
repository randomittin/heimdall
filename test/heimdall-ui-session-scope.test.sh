#!/usr/bin/env bash
# test/heimdall-ui-session-scope.test.sh
#
# Oracle for per-repo session scoping of `hmd ui` and bin/heimdall-relay-client (operator
# decision, 2026-10-01).
#
# THE INCIDENT. The relay client serving /Users/rj/Downloads/heimdall (port 8711) showed the
# hmdapp session's edits. Both relay clients (8710 hmdapp / 8711 heimdall) inherit the SAME
# CLAUDE_CODE_SESSION_ID from the shell that launched them, and every session-keyed collector
# in sentinels/hmd-ui.py trusted that env: `edit-tracker paths` (ledger =
# $TMPDIR/heimdall-edits/<id>.log), the parallelism-tracker counters, the session code. The
# attention / chat / agents derivations read transcripts under the repo's own Claude project dir
# but the publishers ignored the pin altogether.
#
# THE RULE UNDER TEST (bin/lib/hmd_session_resolve.py -- ONE helper, used by every collector):
#   S1  an instance reads ONLY sessions whose transcript is a top-level *.jsonl directly under
#       ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug-of-its---repo>/ (slug: every
#       non-alphanumeric char -> '-')
#   S2  an inherited CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID / SESSION_ID is honoured ONLY
#       when it names a transcript under THIS repo's own project dir; a foreign id (the other
#       repo's session) is ignored, never "trusted anyway"
#   S3  otherwise the session is the newest top-level transcript, skipping headless (`sdk*`
#       entrypoint) sessions
#   S4  edits are the ledger of THAT session, filtered to paths under the repo root: repo-relative,
#       out-of-repo entries dropped (never an absolute path, never a `../` path)
#   S5  parallelism counters, session code, attention, chat / hmd-question follow the same session
#
# Cases (every one cites the rule it proves):
#   U*  the resolver module in isolation (S1-S3) and hmd-ui's collectors in-process (S4, S5)
#   H*  two REAL `hmd ui` servers on two fake repos, BOTH launched with the other repo's session
#       id in the inherited env -- each shows only its own repo's edits / chat / attention /
#       parallelism / session code; a same-repo id is honoured; a newer headless session never
#       displaces the interactive one; a repo with no sessions never shows a foreign ledger
#   R*  the REAL relay client + REAL E2E crypto against test/lib/fake-relay.py, launched with the
#       foreign id: the decrypted state frame carries only its own repo's data
#
# Hermetic: HOME / HEIMDALL_HOME / TMPDIR live in one sandbox (TMPDIR keys edit-tracker's ledger
# dir and parallelism-tracker's state dir), the ambient session-id env is cleared and set
# explicitly per launch, heimdall-fallback's network probe is short-circuited. The sandbox path is
# short and low-entropy on purpose: the panel writer refuses secret-SHAPED strings.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"
UI_PY="$REPO/sentinels/hmd-ui.py"
RES_PY="$REPO/bin/lib/hmd_session_resolve.py"
SC_PY="$REPO/bin/lib/hmd_session_code.py"
RELAY_CLIENT="$REPO/bin/heimdall-relay-client"
FAKE_RELAY="$REPO/test/lib/fake-relay.py"
E2E_MOD="$REPO/bin/lib/hmd_relay_e2e.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-session-scope (each hmd ui / relay client reads only the sessions of its own --repo)"

for f in "$UI" "$UI_PY" "$SC_PY" "$RELAY_CLIENT" "$FAKE_RELAY" "$E2E_MOD"; do
  if [ ! -e "$f" ]; then
    printf 'FATAL: required file missing: %s\n\n0 passed, 1 failed\n' "$f"
    exit 1
  fi
done
for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FATAL: required tool missing: %s\n\n0 passed, 1 failed\n' "$tool"
    exit 1
  fi
done

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d /tmp/hmd-session-scope.XXXXXX)"
export TMPROOT REPO_DIR="$REPO"
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset CLAUDE_CONFIG_DIR HMD_AGENT_PROJECTS_DIR HMD_UI_COMPANION_PANELS
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID SESSION_ID
mkdir -p "$HOME/.claude/projects" "$HEIMDALL_HOME" "$TMPDIR/heimdall-edits" "$TMPDIR/heimdall-parallel" "$TMPROOT/repos"

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ── fixture writers ─────────────────────────────────────────────────────────
# mk.py PATH SID ENTRYPOINT PROMPT REPLY SETTLED AGE_S: a three-entry session transcript in the
# shapes real Claude Code writes (prompt, end_turn reply, turn_duration) whose last write was AGE_S
# seconds ago; the file's mtime is set to match, so "newest" is controllable.
MK="$TMPROOT/mk.py"
cat > "$MK" <<'PYEOF'
import datetime
import json
import os
import sys
import time
import uuid


def iso(t):
    d = datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % int((t % 1) * 1000)


path, sid, entrypoint, prompt, reply, settled, age = sys.argv[1:8]
t_end = time.time() - float(age)


def base(t):
    return {"parentUuid": None, "isSidechain": False, "uuid": str(uuid.uuid4()), "timestamp": iso(t),
            "sessionId": sid, "entrypoint": entrypoint, "cwd": "/fixture"}


entries = []
e = base(t_end - 2)
e.update(type="user", message={"role": "user", "content": prompt})
entries.append(e)
e = base(t_end - 1)
e.update(type="assistant", message={"id": "msg_" + uuid.uuid4().hex[:10], "role": "assistant",
                                    "stop_reason": "end_turn", "content": [{"type": "text", "text": reply}]})
entries.append(e)
if settled == "1":
    e = base(t_end)
    e.update(type="system", subtype="turn_duration", durationMs=1000)
    entries.append(e)
with open(path, "w", encoding="utf-8") as f:
    for e in entries:
        f.write(json.dumps(e, separators=(",", ":")) + "\n")
os.utime(path, (t_end, t_end))
PYEOF

# mkrepo NAME -> the repo's PHYSICAL path (hmd-ui realpaths --repo; /tmp is a symlink on macOS)
mkrepo() {
  local d="$TMPROOT/repos/$1"
  mkdir -p "$d/src" "$d/docs"
  ( cd "$d" && pwd -P )
}
# slugdir REAL_REPO -> its Claude project dir, created
slugdir() {
  local d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$d"
  printf '%s' "$d"
}
# mksession REAL_REPO SID ENTRYPOINT PROMPT REPLY SETTLED AGE_S
mksession() {
  python3 "$MK" "$(slugdir "$1")/$2.jsonl" "$2" "$3" "$4" "$5" "$6" "$7"
}
# ledger SID PATH... : append edit-tracker ledger lines (ts_ms|tool|path)
ledger() {
  local sid="$1" p n=1000
  shift
  for p in "$@"; do
    printf '%s|Edit|%s\n' "$n" "$p" >> "$TMPDIR/heimdall-edits/$sid.log"
    n=$((n + 1))
  done
}
# tracker_state SID TURNS CALLS BATCH : parallelism-tracker's live counters for one session
tracker_state() {
  printf 'total_turns=%s\ncalls=%s\nbatch_turns=%s\nagent_calls=0\nagent_batched=0\n' "$2" "$3" "$4" \
    > "$TMPDIR/heimdall-parallel/$1.state"
}

# Session ids (UUID-shaped like real ones)
SID_A="aaaaaaaa-0000-4000-8000-0000000000a1"   # alpha's session -- the id both servers inherit
SID_B="bbbbbbbb-0000-4000-8000-0000000000b1"
SID_G1="11111111-0000-4000-8000-0000000000c1"  # gamma: older, ends on a question
SID_G2="22222222-0000-4000-8000-0000000000c2"  # gamma: newer, settled
SID_D1="33333333-0000-4000-8000-0000000000d1"  # delta: older, ends on a question
SID_D2="44444444-0000-4000-8000-0000000000d2"  # delta: newer interactive, settled
SID_D3="55555555-0000-4000-8000-0000000000d3"  # delta: NEWEST but headless (sdk-cli)
SID_E="66666666-0000-4000-8000-0000000000e1"   # epsilon: the relay client's repo

A_REAL="$(mkrepo alpha)"
B_REAL="$(mkrepo beta)"
G_REAL="$(mkrepo gamma)"
D_REAL="$(mkrepo delta)"
N_REAL="$(mkrepo nosession)"
E_REAL="$(mkrepo epsilon)"
OTHER_REAL="$(mkrepo elsewhere)"

# alpha: ends on a question (-> needs_input); its ledger also holds a path INSIDE beta
mksession "$A_REAL" "$SID_A" cli "alpha-prompt-marker" "alpha-reply-marker: shall I continue?" 1 300
ledger "$SID_A" "$A_REAL/src/a1.txt" "$A_REAL/README.md" "$B_REAL/src/stolen-from-beta.txt"
tracker_state "$SID_A" 11 22 4
# beta: ends on a settled statement (-> idle); its ledger holds a duplicate and an outside path
mksession "$B_REAL" "$SID_B" cli "beta-prompt-marker" "beta-reply-marker done." 1 300
ledger "$SID_B" "$B_REAL/src/b1.txt" "$B_REAL/docs/b2.md" "$B_REAL/src/b1.txt" "$OTHER_REAL/lib/outside.ts"
tracker_state "$SID_B" 7 9 2
# gamma: two interactive sessions; the OLDER one is the one a launching shell will name
mksession "$G_REAL" "$SID_G1" cli "gamma1-prompt-marker" "gamma1-reply-marker: ready?" 1 900
mksession "$G_REAL" "$SID_G2" cli "gamma2-prompt-marker" "gamma2-reply-marker done." 1 300
ledger "$SID_G1" "$G_REAL/src/g1.txt"
ledger "$SID_G2" "$G_REAL/src/g2.txt"
tracker_state "$SID_G1" 3 4 1
tracker_state "$SID_G2" 8 12 5
# delta: no pin; a NEWER headless session sits above the interactive ones and must not win
mksession "$D_REAL" "$SID_D1" cli "delta1-prompt-marker" "delta1-reply-marker: ready?" 1 900
mksession "$D_REAL" "$SID_D2" cli "delta2-prompt-marker" "delta2-reply-marker done." 1 300
mksession "$D_REAL" "$SID_D3" sdk-cli "delta3-prompt-marker" "delta3-reply-marker done." 1 100
ledger "$SID_D1" "$D_REAL/src/d1.txt"
ledger "$SID_D2" "$D_REAL/src/d2.txt"
ledger "$SID_D3" "$D_REAL/src/d3-headless.txt"
tracker_state "$SID_D2" 6 10 3
tracker_state "$SID_D3" 90 91 90
# epsilon: the relay client's repo (same shape as beta)
mksession "$E_REAL" "$SID_E" cli "epsilon-prompt-marker" "epsilon-reply-marker done." 1 300
ledger "$SID_E" "$E_REAL/src/e1.txt" "$E_REAL/docs/e2.md" "$A_REAL/src/alpha-from-epsilon.txt"
tracker_state "$SID_E" 5 6 2

# ── helpers shared by the server and relay groups ──────────────────────────
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
# chk LABEL FILTER FILE [jq args...]: ok when FILTER is true over FILE
chk() {
  local label="$1" filter="$2" file="$3"
  shift 3
  if jq -e "$@" "$filter" "$file" >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label -- got: $(jq -c "$@" "$filter" "$file" 2>&1 | head -c 400)"
  fi
}
FOREIGN_A=(CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_SESSION_ID="$SID_A" SESSION_ID="$SID_A")
NO_INHERIT=(-u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u SESSION_ID)

# ═══ U. in-process: the resolver module (S1-S3) and hmd-ui's collectors (S4, S5) ═════════════
UNITPY="$TMPROOT/unit.py"
cat > "$UNITPY" <<'PYEOF'
import importlib.util
import json
import os
import re
import sys
import time

REPO = os.environ["REPO_DIR"]
TMPROOT = os.environ["TMPROOT"]
HOME = os.environ["HOME"]
TMPDIR = os.environ["TMPDIR"]
NAMES = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "SESSION_ID")
FAILED = [0]


def check(label, cond, detail=""):
    if cond:
        print("PASS " + label)
    else:
        FAILED[0] += 1
        print("FAIL %s :: %s" % (label, json.dumps(detail, default=str)[:400]))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    R = load("hmd_session_resolve_unit", os.path.join(REPO, "bin", "lib", "hmd_session_resolve.py"))
except Exception as exc:
    print("FAIL import bin/lib/hmd_session_resolve.py :: %r" % (exc,))
    sys.exit(1)
UI = load("hmd_ui_unit", os.path.join(REPO, "sentinels", "hmd-ui.py"))
SC = load("hmd_session_code_unit", os.path.join(REPO, "bin", "lib", "hmd_session_code.py"))


class Env(object):
    """Set exactly the given session-id env names for a block, everything else cleared."""
    def __init__(self, **kw):
        self.kw = kw

    def __enter__(self):
        self.saved = {n: os.environ.get(n) for n in NAMES}
        for n in NAMES:
            os.environ.pop(n, None)
        os.environ.update(self.kw)
        return self

    def __exit__(self, *a):
        for n in NAMES:
            os.environ.pop(n, None)
        for n, v in self.saved.items():
            if v is not None:
                os.environ[n] = v


_n = [0]


def newroot(prefix="unit"):
    _n[0] += 1
    root = os.path.realpath(os.path.join(TMPROOT, "repos", "%s-%d" % (prefix, _n[0])))
    os.makedirs(os.path.join(root, "src"), exist_ok=True)
    pdir = os.path.join(HOME, ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", root))
    os.makedirs(pdir, exist_ok=True)
    return root, pdir


def put(pdir, sid, age=0.0, entrypoint="cli", name=None):
    p = os.path.join(pdir, (name or sid) + ".jsonl")
    with open(p, "w", encoding="utf-8") as f:
        f.write(json.dumps({"type": "user", "entrypoint": entrypoint, "sessionId": sid,
                            "message": {"role": "user", "content": "hi"}}) + "\n")
    t = time.time() - age
    os.utime(p, (t, t))
    return p


def fresh():
    R.reset_caches()
    UI.SESSIONS.reset_caches()
    UI._subprocess_cache.clear()
    UI._file_cache.clear()


def sid_of(s):
    return s.id if s is not None else None


# ── U1-U12: the resolver (S1-S3) ────────────────────────────────────────────────
root, pdir = newroot()
with Env():
    fresh()
    check("U1. a repo with no transcript dir content resolves to no session", R.resolve(root) is None)

    old = put(pdir, "sess-old", age=500)
    new = put(pdir, "sess-new", age=100)
    fresh()
    s = R.resolve(root)
    check("U2. no inherited id -> the NEWEST top-level transcript (S3); id = file name; not pinned",
          s is not None and s.path == new and s.id == "sess-new" and s.pinned is False, s)

    put(pdir, "sess-sdk", age=10, entrypoint="sdk-cli")
    fresh()
    check("U3. a NEWER headless (sdk*) session never displaces the interactive one (S3)",
          sid_of(R.resolve(root)) == "sess-new")
    os.remove(new)
    os.remove(old)
    fresh()
    check("U3b. with only headless sessions, the newest of them is used", sid_of(R.resolve(root)) == "sess-sdk")
    new = put(pdir, "sess-new", age=100)
    old = put(pdir, "sess-old", age=500)

    # foreign repo's session: lives ONLY under the other repo's project dir
    oroot, opdir = newroot("other")
    put(opdir, "sess-foreign", age=1)

with Env(CLAUDE_CODE_SESSION_ID="sess-old"):
    fresh()
    s = R.resolve(root)
    check("U4. an inherited id that names a transcript of THIS repo is honoured over recency (S2)",
          s is not None and s.id == "sess-old" and s.pinned is True, s)

with Env(CLAUDE_CODE_SESSION_ID="sess-foreign"):
    fresh()
    s = R.resolve(root)
    check("U5. an inherited id that only exists under ANOTHER repo is ignored -> newest (S2)",
          s is not None and s.id == "sess-new" and s.pinned is False, s)

with Env(CLAUDE_SESSION_ID="sess-foreign", SESSION_ID="sess-foreign"):
    fresh()
    check("U5b. ... the same for the shorter env names", sid_of(R.resolve(root)) == "sess-new")

bad_values = ["../../etc/passwd", "a/b", "", " ", "x" * 200, "sess-old\n", "sess old", "sess.old"]
ok_all = True
for v in bad_values:
    with Env(CLAUDE_CODE_SESSION_ID=v):
        fresh()
        try:
            s = R.resolve(root)
        except Exception as exc:  # noqa: BLE001
            ok_all = False
            print("       | %r raised %r" % (v, exc))
            continue
        if sid_of(s) != "sess-new":
            ok_all = False
            print("       | %r resolved %r" % (v, s))
check("U6. a malformed / path-shaped inherited id is ignored, never joined into a path", ok_all)

with Env(CLAUDE_CODE_SESSION_ID="sess-foreign", SESSION_ID="sess-old"):
    fresh()
    check("U7. a foreign first name does not block a valid later one (the first name that fits THIS repo wins)",
          sid_of(R.resolve(root)) == "sess-old")
with Env(CLAUDE_CODE_SESSION_ID="sess-new", CLAUDE_SESSION_ID="sess-old", SESSION_ID="sess-old"):
    fresh()
    check("U7b. two names that both fit: CLAUDE_CODE_SESSION_ID (Claude Code's own export) first",
          sid_of(R.resolve(root)) == "sess-new")

with Env():
    sub = os.path.join(pdir, "sess-new", "subagents")
    os.makedirs(sub, exist_ok=True)
    put(sub, "agent-1", age=1)
    put(pdir, "hidden", age=1, name=".hidden")
    fresh()
    check("U8. only TOP-LEVEL non-hidden *.jsonl are sessions: a sub-agent file and a dot-file never win",
          sid_of(R.resolve(root)) == "sess-new")
    check("U8b. transcripts() lists exactly the top-level ones, newest first",
          [os.path.basename(p) for _m, _s, p in R.transcripts(root)] == ["sess-sdk.jsonl", "sess-new.jsonl", "sess-old.jsonl"],
          R.transcripts(root))

    link = os.path.join(TMPROOT, "repos", "symlinked-root")
    os.symlink(root, link)
    fresh()
    check("U9. a repo reached through a symlink resolves via its physical path too (both slugs are searched)",
          sid_of(R.resolve(link)) == "sess-new")

    weird = put(pdir, "x", age=1, name="weird.name")
    fresh()
    s = R.resolve(root)
    check("U10. a transcript whose name is not a safe session key is still selectable but its id is None",
          s is not None and s.path == weird and s.id is None, s)
    os.remove(weird)

    fresh()
    first = R.resolve(root, ttl=0)
    later = put(pdir, "sess-later", age=0.5)
    check("U11. ttl=0 re-scans: a transcript created a moment ago is seen at once",
          sid_of(R.resolve(root, ttl=0)) == "sess-later" and sid_of(first) == "sess-new")
    R.reset_caches()
    os.remove(later)

    fresh()
    s = R.resolve(root, denied=lambda p: os.path.basename(p) == "sess-new.jsonl")
    check("U12. a denied candidate is skipped (the deny-list reaches the selection)",
          s is not None and s.id != "sess-new" and s.path != new, s)
with Env(CLAUDE_CODE_SESSION_ID="sess-old"):
    fresh()
    s = R.resolve(root, denied=lambda p: os.path.basename(p) == "sess-old.jsonl")
    check("U12b. a denied PIN falls through to the newest instead of being honoured", sid_of(s) == "sess-new", s)

# ── U13-U17: hmd-ui's collectors (S4, S5) ────────────────────────────────────────
root, pdir = newroot("collect")
sid = "uuuuuuuu-0000-4000-8000-000000000001"
put(pdir, sid, age=60)
ledger = os.path.join(TMPDIR, "heimdall-edits", sid + ".log")
rows = [os.path.join(root, "src", "x.ts"),            # in the repo
        root + "-evil/z.ts",                           # a sibling that merely shares the name prefix
        os.path.join(root, "..", "outside", "w.ts"),   # escapes the root through ..
        "/elsewhere/q.ts",                             # nowhere near it
        "src/rel.ts",                                  # relative -> relative to the repo
        os.path.join(root, "src", ".", "x.ts"),        # the same file as row 1 after normalisation
        root]                                          # the root itself
with open(ledger, "w", encoding="utf-8") as f:
    for i, p in enumerate(rows):
        f.write("%d|Edit|%s\n" % (1000 + i, p))
with Env():
    fresh()
    got = UI.collect_edits(root)
    check("U13. edits = the repo session's ledger filtered to paths UNDER the root, repo-relative, unique (S4): "
          "sibling-prefix, ..-escape, outside, root-itself dropped; relative kept; normalised duplicate merged",
          got == {"count": 2, "paths": ["src/x.ts", "src/rel.ts"]}, got)

foreign_ledger = os.path.join(TMPDIR, "heimdall-edits", "ffffffff-0000-4000-8000-00000000000f.log")
with open(foreign_ledger, "w", encoding="utf-8") as f:
    f.write("1|Edit|%s\n" % os.path.join(root, "src", "from-foreign-session.ts"))
with Env(CLAUDE_CODE_SESSION_ID="ffffffff-0000-4000-8000-00000000000f"):
    fresh()
    got = UI.collect_edits(root)
    check("U14. a foreign inherited id never selects the ledger: the repo's own session's ledger is read (S2, S4)",
          got == {"count": 2, "paths": ["src/x.ts", "src/rel.ts"]}, got)

nroot, npdir = newroot("nosess")
with open(os.path.join(TMPDIR, "heimdall-edits", "default.log"), "w", encoding="utf-8") as f:
    f.write("1|Edit|%s\n" % os.path.join(nroot, "src", "unkeyed.ts"))
with Env(CLAUDE_CODE_SESSION_ID="ffffffff-0000-4000-8000-00000000000f"):
    fresh()
    got = UI.collect_edits(nroot)
    check("U15. a repo with NO session of its own + a foreign inherited id reads the unkeyed ledger, never the foreign one",
          got == {"count": 1, "paths": ["src/unkeyed.ts"]}, got)
os.remove(os.path.join(TMPDIR, "heimdall-edits", "default.log"))

# parallelism: which state file
pdir_state = os.path.join(TMPDIR, "heimdall-parallel")


def state(name, turns):
    with open(os.path.join(pdir_state, name + ".state"), "w", encoding="utf-8") as f:
        f.write("total_turns=%d\ncalls=%d\nbatch_turns=1\nagent_calls=0\nagent_batched=0\n" % (turns, turns + 1))


proot, ppdir = newroot("par")
put(ppdir, "par-old", age=400)
put(ppdir, "par-new", age=40)
state("par-old", 1)
state("par-new", 2)
state("par-foreign", 99)
with Env():
    fresh()
    check("U16. parallelism counters = the repo's resolved session's state file (S5)",
          os.path.basename(UI._tracker_state_path(proot)) == "par-new.state", UI._tracker_state_path(proot))
with Env(CLAUDE_SESSION_ID="par-old"):
    fresh()
    check("U16b. a same-repo inherited id is honoured", os.path.basename(UI._tracker_state_path(proot)) == "par-old.state")
with Env(CLAUDE_SESSION_ID="par-foreign", SESSION_ID="par-foreign"):
    fresh()
    check("U16c. a foreign inherited id (whose state file exists!) is ignored",
          os.path.basename(UI._tracker_state_path(proot)) == "par-new.state")
os.remove(os.path.join(pdir_state, "par-new.state"))
with Env():
    fresh()
    p = UI._tracker_state_path(proot)
    check("U16d. no state file for the repo's session and no unkeyed one: nothing -- never 'the newest state file of any session'",
          p is None, p)
state("default", 4)
with Env():
    fresh()
    check("U16e. ... but the tracker's own unkeyed `default` counters still back the slice",
          os.path.basename(UI._tracker_state_path(proot) or "") == "default.state")
os.remove(os.path.join(pdir_state, "default.state"))

# session code
croot, cpdir = newroot("code")
put(cpdir, "code-sess", age=30)
want_repo = SC.session_code_for(repo=croot)[0]
want_sess = SC.session_code_for(session_id="code-sess")[0]
want_foreign = SC.session_code_for(session_id="code-foreign")[0]
with Env():
    fresh()
    check("U17. no inherited id -> the repo-derived code (repo scoped, as before)",
          UI.collect_session_code(croot) == want_repo, [UI.collect_session_code(croot), want_repo])
with Env(CLAUDE_CODE_SESSION_ID="code-sess"):
    fresh()
    check("U17b. a same-repo inherited id -> the code of that session (the statusline's own code)",
          UI.collect_session_code(croot) == want_sess, [UI.collect_session_code(croot), want_sess])
with Env(CLAUDE_CODE_SESSION_ID="code-foreign", CLAUDE_SESSION_ID="code-foreign", SESSION_ID="code-foreign"):
    fresh()
    got = UI.collect_session_code(croot)
    check("U17c. a foreign inherited id never becomes this repo's session code",
          got == want_repo and got != want_foreign, [got, want_repo, want_foreign])

sys.exit(1 if FAILED[0] else 0)
PYEOF

UNIT_OUT="$TMPROOT/unit.out"
python3 "$UNITPY" >"$UNIT_OUT" 2>&1
urc=$?
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) printf '       | %s\n' "$line" ;;
  esac
done < "$UNIT_OUT"
if [ "$urc" -ne 0 ] && ! grep -q '^FAIL ' "$UNIT_OUT"; then
  bad "U. the unit script crashed (rc=$urc) before reporting a verdict"
fi

# ═══ H. two real `hmd ui` servers, each launched with the OTHER repo's session id ═══════════
# launch LABEL REPO ENVARG...  -> sets L_BASE / L_AUTH (rc 1 when the server never came up)
launch() {
  local label="$1" repo="$2" out port re url q
  shift 2
  port="$(free_port)"
  out="$TMPROOT/srv-$label.out"
  ( cd "$repo" && HEIMDALL_WATCH_ROOT="$repo" exec env "$@" "$UI" --repo "$repo" --port "$port" --no-open ) \
    >"$out" 2>&1 &
  PIDS+=("$!")
  re="^http://127\.0\.0\.1:$port/\?(t|token)=[A-Za-z0-9_-]+\$"
  if ! wait_for "$out" "$re" 10; then
    bad "$label: the server never printed its URL line within 10s"
    sed 's/^/       | /' "$out"
    return 1
  fi
  url="$(grep -E "$re" "$out" | head -1)"
  q="${url#*\?}"
  L_BASE="http://127.0.0.1:$port"
  L_AUTH="$q"
  return 0
}
# snap BASE AUTH OUTFILE [want-chat]: GET /api/state; with want-chat, poll (<= ~25s) until the poller
# has published the chat panel (the publishers run on the poll tick, not on a GET)
snap() {
  local base="$1" auth="$2" out="$3" want="${4:-}" i=0
  while [ "$i" -lt 125 ]; do
    curl -s -o "$out" "$base/api/state?$auth"
    if [ -z "$want" ] || jq -e '[.panels[]? | select(.id=="chat")] | length > 0' "$out" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# the two servers of the incident: both inherit alpha's session id
launch alpha "$A_REAL" "${FOREIGN_A[@]}" && { A_BASE="$L_BASE"; A_AUTH="$L_AUTH"; A_UP=1; } || A_UP=0
launch beta "$B_REAL" "${FOREIGN_A[@]}" && { B_BASE="$L_BASE"; B_AUTH="$L_AUTH"; B_UP=1; } || B_UP=0
# same-repo pin (gamma, older session named), no pin + newer headless (delta), foreign id + no session (nosession)
launch gamma "$G_REAL" CLAUDE_CODE_SESSION_ID="$SID_G1" && { G_BASE="$L_BASE"; G_AUTH="$L_AUTH"; G_UP=1; } || G_UP=0
launch delta "$D_REAL" "${NO_INHERIT[@]}" && { D_BASE="$L_BASE"; D_AUTH="$L_AUTH"; D_UP=1; } || D_UP=0
launch nosession "$N_REAL" "${FOREIGN_A[@]}" && { N_BASE="$L_BASE"; N_AUTH="$L_AUTH"; N_UP=1; } || N_UP=0

SA="$TMPROOT/state-alpha.json"; SB="$TMPROOT/state-beta.json"; SG="$TMPROOT/state-gamma.json"
SD="$TMPROOT/state-delta.json"; SN="$TMPROOT/state-nosession.json"

if [ "$A_UP" = 1 ] && [ "$B_UP" = 1 ]; then
  snap "$A_BASE" "$A_AUTH" "$SA" want-chat || bad "H0. alpha: the chat panel was never published"
  snap "$B_BASE" "$B_AUTH" "$SB" want-chat || bad "H0. beta: the chat panel was never published"

  chk "H1. beta (inherited ALPHA's id) shows ONLY beta's edits, repo-relative, deduplicated (S1, S2, S4)" \
      '.edits == {"count": 2, "paths": ["src/b1.txt", "docs/b2.md"]}' "$SB"
  chk "H1b. ... nothing of alpha's ledger leaks in (no a1.txt / README.md / alpha path, nothing absolute or ..-relative)" \
      '[.edits.paths[] | (contains("a1.txt") or contains("README") or contains("alpha") or contains("stolen") or startswith("/") or startswith(".."))] | any | not' "$SB"
  chk "H2. alpha shows only alpha's edits: its ledger's entry INSIDE beta (a path out of alpha's root) is filtered out (S4)" \
      '.edits == {"count": 2, "paths": ["src/a1.txt", "README.md"]}' "$SA"
  chk "H3. beta's chat is beta's conversation only (S1, S5)" \
      '[.panels[] | select(.id=="chat") | .data.lines[]] as $l | ($l | length) == 2 and ($l | map(contains("beta")) | all) and ($l | map(contains("alpha")) | any | not)' "$SB"
  chk "H3b. alpha's chat is alpha's conversation only" \
      '[.panels[] | select(.id=="chat") | .data.lines[]] as $l | ($l | length) == 2 and ($l | map(contains("alpha")) | all) and ($l | map(contains("beta")) | any | not)' "$SA"
  chk "H4. attention follows each repo's own transcript: alpha needs_input (its question), beta idle (settled statement)" \
      '.attention.state == "idle" and .attention.kind == "stopped"' "$SB"
  chk "H4b. ... alpha: needs_input / question" \
      '.attention.state == "needs_input" and .attention.kind == "question" and (.attention.summary | contains("alpha"))' "$SA"
  chk "H5. parallelism counters: beta reads ITS session's state (7 turns), not alpha's (11) (S5)" \
      '.parallelism.turns == 7 and .parallelism.calls == 9 and .parallelism.source == "live"' "$SB"
  chk "H5b. ... alpha reads its own (11 turns)" \
      '.parallelism.turns == 11 and .parallelism.calls == 22 and .parallelism.source == "live"' "$SA"
  WANT_B_CODE="$(python3 "$SC_PY" --repo "$B_REAL")"
  WANT_A_SESS="$(python3 "$SC_PY" --session-id "$SID_A")"
  chk "H6. beta's session code is its repo's code, never alpha's session's (S2, S5)" \
      '.identity.session_code == $b and .identity.session_code != $a' "$SB" --arg b "$WANT_B_CODE" --arg a "$WANT_A_SESS"
  chk "H6b. alpha (same repo as the inherited id) shows the code of that session" \
      '.identity.session_code == $a' "$SA" --arg a "$WANT_A_SESS"
  chk "H7. the hmd-question panel follows the same session: alpha's open question is alpha's, beta has none" \
      '([.panels[] | select(.id=="hmd-question")] | length) == 1 and ([.panels[] | select(.id=="hmd-question") | .data.text | contains("alpha")] | all)' "$SA"
  chk "H7b. ... beta publishes no question" \
      '[.panels[] | select(.id=="hmd-question")] | length == 0' "$SB"
fi

if [ "$G_UP" = 1 ]; then
  snap "$G_BASE" "$G_AUTH" "$SG" want-chat || bad "H0. gamma: the chat panel was never published"
  chk "H8. a same-repo inherited id is HONOURED over recency: gamma (id = the OLDER session) reads that session's ledger (S2)" \
      '.edits == {"count": 1, "paths": ["src/g1.txt"]}' "$SG"
  chk "H8b. ... its chat and question are the pinned session's, not the newest one's" \
      '([.panels[] | select(.id=="chat") | .data.lines[]] | (map(contains("gamma1")) | all) and (map(contains("gamma2")) | any | not)) and ([.panels[] | select(.id=="hmd-question") | .data.text | contains("gamma1")] | all)' "$SG"
  chk "H8c. ... attention (needs_input from the pinned session's question) and parallelism (3 turns) agree" \
      '.attention.state == "needs_input" and .parallelism.turns == 3' "$SG"
fi

if [ "$D_UP" = 1 ]; then
  snap "$D_BASE" "$D_AUTH" "$SD" want-chat || bad "H0. delta: the chat panel was never published"
  chk "H9. no inherited id: the session is the newest INTERACTIVE one -- delta2's ledger, not the newer headless delta3's (S3)" \
      '.edits == {"count": 1, "paths": ["src/d2.txt"]}' "$SD"
  chk "H9b. ... chat, attention (idle) and parallelism (6 turns) come from delta2 too" \
      '([.panels[] | select(.id=="chat") | .data.lines[]] | (map(contains("delta2")) | all) and (map(contains("delta3")) | any | not)) and .attention.state == "idle" and .parallelism.turns == 6' "$SD"
fi

if [ "$N_UP" = 1 ]; then
  snap "$N_BASE" "$N_AUTH" "$SN"
  chk "H10. a repo with NO session of its own that inherited alpha's id shows no edits at all (S2)" \
      '.edits == {"count": 0, "paths": []}' "$SN"
  chk "H10b. ... and the default attention shape, no chat panel, no foreign parallelism" \
      '.attention.state == "idle" and .attention.id == null and ([.panels[]? | select(.id=="chat")] | length == 0) and (.parallelism.turns != 11)' "$SN"
fi

# ═══ R. the real relay client + real E2E crypto, launched with the OTHER repo's session id ═══
E2E_OK="$(python3 - "$E2E_MOD" <<'PYEOF' 2>/dev/null
import sys
from importlib.util import module_from_spec, spec_from_file_location
spec = spec_from_file_location("hmd_relay_e2e", sys.argv[1])
mod = module_from_spec(spec)
spec.loader.exec_module(mod)
print("yes" if mod.e2e_available() else "no")
PYEOF
)"
if [ "$E2E_OK" != "yes" ]; then
  printf '  SKIP R1-R3 no E2E backend available here (hmd_relay_e2e.e2e_available() is false)\n'
else
  PORT_R="$(free_port)"
  LOG_R="$TMPROOT/r.log"; CTL_R="$TMPROOT/r.ctl"
  mkdir -p "$LOG_R" "$CTL_R"
  python3 "$FAKE_RELAY" serve "$PORT_R" --log "$LOG_R" --ctl "$CTL_R" >"$TMPROOT/r.srv.out" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT_R))==0 else 1)" && break
    sleep 0.1
  done
  # the device key must be on disk BEFORE the client's first stream connection
  DEV_KEY_JSON="$(python3 "$FAKE_RELAY" device keygen)"
  DEV_PRIV_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .priv_b64)"
  DEV_PUB_B64="$(printf '%s' "$DEV_KEY_JSON" | jq -r .pub_b64)"
  printf '%s' "$DEV_PUB_B64" > "$CTL_R/bind-device"

  CLIENT_OUT="$TMPROOT/r.client.out"
  ( cd "$E_REAL" && exec env "${FOREIGN_A[@]}" "$RELAY_CLIENT" --relay "http://127.0.0.1:$PORT_R" --repo "$E_REAL" --ui-port 1 ) \
    >"$CLIENT_OUT" 2>"$TMPROOT/r.client.err" &
  PIDS+=("$!")

  STATE_R="$TMPROOT/r.state.json"
  GOT_STATE=false
  if wait_for "$CLIENT_OUT" '"event":"pair_init"' 15; then
    SID_R="$(jq -r 'select(.event=="pair_init") | .qr.session_id' "$CLIENT_OUT" | head -1)"
    HMD_PUB_R="$(jq -r 'select(.event=="pair_init") | .qr.hmd_pubkey' "$CLIENT_OUT" | head -1)"
    KEY_R="$(python3 "$FAKE_RELAY" device derive --dev-priv-b64 "$DEV_PRIV_B64" --hmd-pub-b64 "$HMD_PUB_R" --session-id "$SID_R" | jq -r .key_b64)"
    # the FIRST frame can predate the poller's first publish: take the first one that carries the chat panel
    python3 - "$LOG_R/frames.ndjson" "$KEY_R" "$E2E_MOD" "$STATE_R" <<'PYEOF'
import base64, json, sys, time
from importlib.util import module_from_spec, spec_from_file_location

frames, key_b64, e2e_path, out_path = sys.argv[1:5]
spec = spec_from_file_location("hmd_relay_e2e", e2e_path)
e2e = module_from_spec(spec)
spec.loader.exec_module(e2e)
key = base64.b64decode(key_b64)
deadline = time.time() + 30
while time.time() < deadline:
    try:
        with open(frames, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            env = json.loads(line)
        except ValueError:
            continue
        if env.get("sender") != "hmd" or env.get("type") != "state":
            continue
        state = json.loads(e2e.open_(key, env["seq"], "hmd", env["nonce"], env["ciphertext"]).decode("utf-8"))["state"]
        if any(p.get("id") == "chat" for p in state.get("panels") or []):
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(json.dumps(state))
            sys.exit(0)
    time.sleep(0.2)
sys.exit(1)
PYEOF
    [ "$?" -eq 0 ] && [ -s "$STATE_R" ] && GOT_STATE=true
  fi

  if [ "$GOT_STATE" = true ]; then
    chk "R1. the relay client launched with ALPHA's session id seals only epsilon's edits (repo-relative; alpha-from-epsilon, a path out of epsilon's root, is filtered)" \
        '.edits == {"count": 2, "paths": ["src/e1.txt", "docs/e2.md"]}' "$STATE_R"
    chk "R2. ... its chat is epsilon's conversation only, its attention is epsilon's (idle), its parallelism epsilon's (5 turns)" \
        '([.panels[] | select(.id=="chat") | .data.lines[]] | (map(contains("epsilon")) | all) and (map(contains("alpha")) | any | not)) and .attention.state == "idle" and .parallelism.turns == 5' "$STATE_R"
    chk "R3. ... and nothing in the frame mentions alpha's session (edits, chat, panels)" \
        '[.edits.paths[], (.panels[] | select(.id=="chat") | .data.lines[])] | all(.[]; (contains("alpha") or contains("a1.txt")) | not)' "$STATE_R"
  else
    bad "R1. no decrypted state frame carrying the chat panel from the real relay client -- client stderr: $(head -c 400 "$TMPROOT/r.client.err" 2>/dev/null)"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
