#!/usr/bin/env bash
# test/heimdall-ui-attention.test.sh
#
# Oracle for the `attention` slice of /api/state (A1, docs/HANDOFF-TO-HEIMDALL-product-asks.md):
# bin/lib/companion_ui_attention.py derives {state,id,since,kind,summary,options,turn} from the
# repo's Claude Code session transcript and sentinels/hmd-ui.py serves it. Written from the
# handoff's acceptance list, never from the collector's source.
#
#   U*  the collector in isolation (python, injected `now`): every state reachable from a
#       synthetic transcript, the exact wire shape, id/since anchoring, secret scrub, session
#       choice, and the cost bound (a 50 MB transcript, a 10 MiB final line, an unchanged file).
#   L*  the real server (bin/heimdall-ui): replay user-prompt -> stop-with-question -> stop-plain
#       -> permission -> session-end and read .attention after every step; one /api/events frame
#       per transition and none for repeated tool-call entries; the ETag stays put while tool
#       calls pile up; a secret-shaped summary is dropped; public mode (--allow-host) redacts a
#       path and an email; a 50 MB transcript costs one bounded read. L1-L11 run with the native
#       companion publishers (A3) OFF; L12 runs attention WITH them on -- see "Publishers" below.
#
# Publishers: bin/lib/companion_ui_publish.py rewrites the chat / hmd-question / agents panels
# from the SAME transcript attention is derived from, and the digest covers panels -- so with
# them on, one transcript append that adds text is two digest changes. Measured (a dump of every
# SSE frame of this suite with them on): whenever a GET /api/state -- this suite's `poke`, and
# att_is's polling -- lands before the poller's next publish pass, the append arrives as TWO
# frames, attention first (StateCache.refresh() on a GET never publishes) and the chat /
# hmd-question panels one poll tick later. L1-L11 count frames per ATTENTION transition, so they
# run with HMD_UI_COMPANION_PANELS=0. L12 turns the publishers on and makes NO GET: on the
# poller-only path (the one bin/heimdall-relay-client reads, via StateCache.latest()) the first
# frame announcing a transition must already carry the panels it implies.
#
# Hermetic: HOME/HEIMDALL_HOME/TMPDIR are a temp dir, the fixture repo is a temp dir, the
# session id env vars are unset, every background process is reaped on EXIT. No `timeout` on
# macOS -- every wait is a bounded sleep-0.2 poll. The secret fixture is assembled at RUNTIME
# (never a literal), same discipline as heimdall-ui-inbox.test.sh.
#
# Out of scope here (A1's other halves, built elsewhere): the hook script / attention.json and
# the relay client's {"type":"notify"} frame.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="${HEIMDALL_UI_BIN:-$REPO/bin/heimdall-ui}"
LIBPY="$REPO/bin/lib/companion_ui_attention.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "heimdall-ui-attention (A1 attention state derived from the session transcript tail)"

if [ ! -x "$UI" ]; then
  printf '  SKIP bin/heimdall-ui is absent or not executable (%s)\n' "$UI"
  printf '\n0 passed, 1 failed (harness could not start the server under test)\n'
  exit 1
fi
for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  FAIL required tool missing: %s\n' "$tool"
    printf '\n0 passed, 1 failed\n'
    exit 1
  fi
done

# ── sandbox ─────────────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)"
export TMPROOT LIBPY REPO
export TMPDIR="$TMPROOT"
export HOME="$TMPROOT/home"
export HEIMDALL_HOME="$TMPROOT/home/.heimdall"
export HEIMDALL_FALLBACK_ASSUME_REACHABLE=0
unset CLAUDE_SESSION_ID SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR
export HMD_UI_COMPANION_PANELS=0   # L1-L11 only (see "Publishers" above); L12 turns it on for its own server
FIX="$TMPROOT/fixture-repo"
mkdir -p "$HOME/.claude" "$FIX"
FIX_REAL="$(cd "$FIX" && pwd -P)"
SLUG="$(printf '%s' "$FIX_REAL" | sed 's/[^A-Za-z0-9]/-/g')"
PROJ="$HOME/.claude/projects/$SLUG"
mkdir -p "$PROJ"
SID="aaaaaaaa-0000-4000-8000-000000000001"
TX="$PROJ/$SID.jsonl"
( cd "$FIX" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true

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

# ── transcript fixture writer (importable by the unit script, callable from bash) ────────────
TXPY="$TMPROOT/tx.py"
cat > "$TXPY" <<'PYEOF'
import argparse
import datetime
import json
import sys
import uuid
import time

SID = "aaaaaaaa-0000-4000-8000-000000000001"


def iso(t):
    d = datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % int((t % 1) * 1000)


def entry(kind, age=0.0, text="", name="Bash", tid=None, tool_input=None, mode="default",
          entrypoint="cli", sidechain=False, session=SID, pad=0):
    t = time.time() - age
    if kind == "mode":
        return {"type": "permission-mode", "permissionMode": mode, "sessionId": session}
    base = {"parentUuid": None, "isSidechain": sidechain, "uuid": str(uuid.uuid4()),
            "timestamp": iso(t), "sessionId": session, "entrypoint": entrypoint, "cwd": "/fixture"}
    if kind == "prompt":
        base.update(type="user", message={"role": "user", "content": text or "do the thing"})
    elif kind == "tool_use":
        blk = {"type": "tool_use", "id": tid or "toolu_" + uuid.uuid4().hex[:12], "name": name,
               "input": tool_input if tool_input is not None else {"command": "echo hi"}}
        base.update(type="assistant", message={"role": "assistant", "stop_reason": "tool_use", "content": [blk]})
    elif kind == "tool_result":
        base.update(type="user", message={"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": "x" * pad}]})
    elif kind == "end":
        base.update(type="assistant", message={"role": "assistant", "stop_reason": "end_turn",
                                               "content": [{"type": "text", "text": text}]})
    elif kind == "turn":
        base.update(type="system", subtype="turn_duration", durationMs=1000)
    elif kind == "interrupt":
        base.update(type="user", message={"role": "user", "content": [
            {"type": "text", "text": "[Request interrupted by user]"}]})
    else:
        raise ValueError(kind)
    return base


def pair(age=0.0, name="Bash", tool_input=None, pad=0):
    tid = "toolu_" + uuid.uuid4().hex[:12]
    return [entry("tool_use", age=age + 0.01, name=name, tid=tid, tool_input=tool_input),
            entry("tool_result", age=age, tid=tid, pad=pad)]


def append(path, *entries):
    with open(path, "a", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("kind")
    ap.add_argument("--age", type=float, default=0.0)
    ap.add_argument("--text", default="")
    ap.add_argument("--name", default="Bash")
    ap.add_argument("--input")
    ap.add_argument("--mode", default="default")
    ap.add_argument("--pad", type=int, default=0)
    a = ap.parse_args()
    ti = json.loads(a.input) if a.input else None
    if a.kind == "pair":
        append(a.file, *pair(age=a.age, name=a.name, tool_input=ti, pad=a.pad))
    elif a.kind == "stop":
        # end_turn + its turn_duration in ONE write: a Stop whose hooks have already finished
        append(a.file, entry("end", age=a.age + 0.01, text=a.text), entry("turn", age=a.age))
    else:
        append(a.file, entry(a.kind, age=a.age, text=a.text, name=a.name, tool_input=ti,
                             mode=a.mode, pad=a.pad))
PYEOF
txa() { python3 "$TXPY" "$TX" "$@"; }

# ═══ U. the collector in isolation ══════════════════════════════════════════════════════════
UNITPY="$TMPROOT/unit.py"
cat > "$UNITPY" <<'PYEOF'
import builtins
import importlib.util
import json
import os
import re
import sys
import time

sys.path.insert(0, os.environ["TMPROOT"])
import tx

FAILED = [0]


def check(label, cond, detail=""):
    if cond:
        print("PASS " + label)
    else:
        FAILED[0] += 1
        print("FAIL %s :: %s" % (label, json.dumps(detail, default=str)[:300]))


try:
    spec = importlib.util.spec_from_file_location("att_unit", os.environ["LIBPY"])
    att = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(att)
except Exception as exc:
    print("FAIL import bin/lib/companion_ui_attention.py :: %r" % (exc,))
    sys.exit(1)

HOME = os.environ["HOME"]
TMPROOT = os.environ["TMPROOT"]
DEFAULT = {"state": "idle", "id": None, "since": None, "kind": None, "summary": None,
           "options": None, "turn": None}
ID_RE = re.compile(r"^a-[0-9a-f]{10}$")
SEEN = []
_n = [0]


def clear():
    for d in (att._SELECT, att._HEADS, att._EVIDENCE, att._EPISODE):
        d.clear()


def newroot():
    _n[0] += 1
    root = os.path.realpath(os.path.join(TMPROOT, "unit-root-%d" % _n[0]))
    os.makedirs(root, exist_ok=True)
    pdir = os.path.join(HOME, ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", root))
    os.makedirs(pdir, exist_ok=True)
    return root, pdir, os.path.join(pdir, tx.SID + ".jsonl")


def run(root, **kw):
    out = att.collect(root, **kw)
    SEEN.append(out)
    return out


def case(entries, **kw):
    root, pdir, p = newroot()
    tx.append(p, *entries)
    return run(root, **kw), root, p


def ts_of(e):
    return att._parse_ts(e["timestamp"])


# U1 -- no evidence
root, pdir, p = newroot()
check("U1. no transcript -> exactly the handoff's absent-file shape", run(root) == DEFAULT)

# U2/U3 -- working, and a run that grows without changing identity
prompt = tx.entry("prompt", age=5)
g, root, p = case([prompt], turn=7)
check("U2. prompt -> working; kind/summary/options null; turn passed through; id a-<10 hex>; since = the prompt's own timestamp",
      g["state"] == "working" and g["kind"] is None and g["summary"] is None and g["options"] is None
      and g["turn"] == 7 and ID_RE.match(g["id"] or "") and abs(g["since"] - ts_of(prompt)) < 0.002, g)
w_id, w_since = g["id"], g["since"]
for _ in range(3):
    tx.append(p, *tx.pair(age=1))
g = run(root)
check("U3. tool calls inside one working run change nothing: same state, id and since",
      g["state"] == "working" and g["id"] == w_id and g["since"] == w_since, g)
tx.append(p, tx.entry("tool_use", age=30, tid="toolu_young"))
g = run(root)
check("U3b. a Bash call 30s old with no result is still just working (inside its 180s grace)",
      g["state"] == "working" and g["id"] == w_id, g)

# U4 -- a run longer than the tail window keeps its first anchor
root, pdir, p = newroot()
tx.append(p, tx.entry("prompt", age=100))
first = run(root)
for _ in range(60):
    tx.append(p, *tx.pair(age=1, pad=4096))
g = run(root)
check("U4. a working run longer than the 64 KiB tail window keeps its id and since (in-process anchor)",
      os.path.getsize(p) > att.TAIL_WINDOWS[0] and g["state"] == "working"
      and g["id"] == first["id"] and g["since"] == first["since"], g)

# U5 -- needs_input
q = "I can do either.\n\nA) Keep the old schema\nB) Migrate now\n\nWhich do you want?"
end_q = tx.entry("end", age=10, text=q)
g, root, p = case([tx.entry("prompt", age=60), end_q])
check("U5. end_turn text ending in '?' -> needs_input/question at once, summary = the question, options parsed, since = the end_turn",
      g["state"] == "needs_input" and g["kind"] == "question" and g["summary"] == "Which do you want?"
      and g["options"] == [{"key": "A", "label": "Keep the old schema"}, {"key": "B", "label": "Migrate now"}]
      and abs(g["since"] - ts_of(end_q)) < 0.002 and g["id"] != w_id, g)
g, root, p = case([tx.entry("end", age=10, text="Which stack?\n\nA) native only\nB) native + web?")])
check("U5b. options in the closing paragraph lose the question's trailing '?'",
      g["options"] == [{"key": "A", "label": "native only"}, {"key": "B", "label": "native + web"}]
      and g["summary"] == "Which stack?", g)
g, root, p = case([tx.entry("end", age=10, text="What should I name the new module?")])
check("U5c. a bare OPEN question has a summary and options null (nothing enumerated, not yes/no: the phone shows a free-text answer)",
      g["state"] == "needs_input" and g["summary"] == "What should I name the new module?" and g["options"] is None, g)

# U5d -- Yes/No is attached ONLY to a question that really is yes/no: exactly ONE question, and it is a closed
# polar one (starts with an auxiliary/modal, optionally after a short lead-in; not "A or B?"; no which/what/how/
# why/when/where/who). Everything else carries NO options, so the phone shows a free-text answer instead of two
# buttons that cannot answer it -- an hmd reply that ended in THREE open questions was offered Yes/No.
YES_NO = [{"key": "yes", "label": "Yes"}, {"key": "no", "label": "No"}]
OPERATOR_THREE = ("Stop-hook hold: keep 30 min, shorten, or hold only when away? "
                  "Paths: show ../hmdapp — yes or no? A4: go or hold?")
POLAR = (
    ("a single closed polar question", "Should I proceed with the migration?"),
    ("... after a statement paragraph", "Tests are green on both targets and the tree is clean.\n\nShall I push to origin?"),
    ("... after a long statement sentence",
     "The migration touched fourteen tables and three views and I verified every row count twice. Should I push?"),
    ("... after a short lead-in (em dash)", "Quick check — can I delete the stale worktrees?"),
    ("... after a short lead-in (spaced hyphen)", "Quick check - can I delete the stale worktrees?"),
    ("... after a short lead-in (colon)", "Heads up: the gate was red earlier. Is it fine to ship anyway?"),
    ("... after a short lead-in (commas)", "OK, so, should I push?"),
    ("... after a lead-in of exactly 8 words", "one two three four five six seven eight — should I push?"),
    ("... in bold", "**Is the schema change safe to ship?**"),
    ("... with an explicit yes/no tag (not an 'A or B')", "Have you already rotated the key, yes or no?"),
    ("... in a negative contraction", "Doesn't the relay client already retry?"),
    ("... in a negative contraction with a curly apostrophe", "Doesn’t the relay client already retry?"),
    ("... in the irregular negative contraction", "Won't the gate go red again?"),
    ("... with a `?` and a space inside an inline code span", "I rewrote the branch.\n\nShould I keep the `cond ? a : b` form?"),
    ("... with which/or as identifiers inside code spans", "Should I rename `which` to `which_or_what`?"),
    ("... with a what/which inside a URL", "Should I open https://example.test/run?what=1&which=2 now?"),
    ("... ending in a URL that ends in the '?'", "Should I open https://example.test/page?"),
    ("... with a `?` inside a fenced block", "```\nwhy?\n```\n\nCan I apply the patch?"),
    ("... with a `?` glued inside a token", "Should I rename foo?bar.txt now?"),
)
for label, text in POLAR:
    g, root, p = case([tx.entry("end", age=10, text=text)])
    check("U5d. %s -> options are exactly Yes/No" % label,
          g["state"] == "needs_input" and g["kind"] == "question" and g["options"] == YES_NO, [text, g])
g["options"][0]["label"] = "tampered"
g["options"].append({"key": "x", "label": "x"})
g2, root, p = case([tx.entry("end", age=10, text="Should I proceed with the migration?")])
check("U5d2. each result owns its Yes/No list (a consumer mutating one cannot corrupt the next)",
      g2["options"] == YES_NO, g2)
# every auxiliary/modal of the rule opens a closed polar question
AUX_QUESTIONS = ("Is the tree clean?", "Are the suites green?", "Was the gate green?", "Were the checkpoints committed?",
                 "Do the docs need an update?", "Does the relay retry?", "Did the sweep pass?", "Can I merge it?",
                 "Could the cache be stale?", "Should I push?", "Shall we ship?", "Will the gate pass?",
                 "Would a rebase be cleaner?", "May I delete the branch?", "Might the cache be stale?",
                 "Have you rotated the key?", "Has the sweep finished?", "Had the tree been clean?",
                 "Am I right that the gate is green?")
bad_aux = [t for t in AUX_QUESTIONS
           if case([tx.entry("end", age=10, text=t)])[0]["options"] != YES_NO]
check("U5d3. each of is/are/was/were/am/do/does/did/can/could/should/shall/will/would/may/might/have/has/had opens "
      "a closed polar question -> Yes/No", not bad_aux, bad_aux)

OPEN = (
    ("THREE open questions (the operator's real reply shape)", OPERATOR_THREE),
    ("the same three questions, one per line", OPERATOR_THREE.replace("? ", "?\n")),
    ("the same three questions, one per paragraph", OPERATOR_THREE.replace("? ", "?\n\n")),
    ("two polar questions", "Is the tree clean? Should I push?"),
    ("an open question before a polar one", "Which branch is this? Should I push it?"),
    ("an 'A or B?' question", "Should I keep the old schema or migrate now?"),
    ("a bare 'A or B?'", "Keep or drop?"),
    ("an aux-led question that is really 'which'", "Can you tell me which file you meant?"),
    ("a which question", "Which file should I edit?"),
    ("a what question", "What should I name it?"),
    ("a how question", "How do you want to handle the rollback?"),
    ("a why question", "Why did the gate go red?"),
    ("a when question", "When should I merge?"),
    ("a where question", "Where should the config live?"),
    ("a who question", "Who owns the relay client?"),
    ("a closed question that does not start with an auxiliary", "Want me to push?"),
    ("a one-word closed question", "Ship it?"),
    ("an imperative tagged 'yes or no' (not an aux-led question)", "Paths: show ../hmdapp — yes or no?"),
    ("a long run-on lead-in is not a short lead-in",
     "The migration touched fourteen tables and three views and I verified every row count twice, so should I push?"),
    ("a lead-in of 9 words (one over the limit)", "one two three four five six seven eight nine — should I push?"),
    ("an earlier QUOTED question plus a polar one", 'You asked "is it done?" earlier. Should I push?'),
)
for label, text in OPEN:
    g, root, p = case([tx.entry("end", age=10, text=text)])
    check("U5e. %s -> state needs_input, options null (free-text answer)" % label,
          g["state"] == "needs_input" and g["kind"] == "question" and g["options"] is None, [text, g])

g, root, p = case([tx.entry("end", age=10, text="Pick one:\n\nA) alpha\nB) beta\n\nShould I go with A?")])
check("U5f. enumerated options keep their parsed options even when the closing line is itself a polar question",
      g["options"] == [{"key": "A", "label": "alpha"}, {"key": "B", "label": "beta"}], g)
g, root, p = case([tx.entry("end", age=10, text="Here are the two ways to land it:\n\n1. Squash\n2. Rebase\n\nShould I use the first?")])
check("U5g. a numbered list keeps its parsed options, never Yes/No",
      g["options"] == [{"key": "1", "label": "Squash"}, {"key": "2", "label": "Rebase"}], g)
g, root, p = case([tx.entry("end", age=10, text="Pick:\n\nA) alpha\nA) again\n\nShould I go?")])
check("U5h. an enumeration that cannot be represented (duplicate keys) -> options null, NOT a Yes/No stand-in",
      g["options"] is None, g)

settled_three = [tx.entry("prompt", age=300), tx.entry("end", age=200, text=OPERATOR_THREE.rstrip("?") + ". Tell me."),
                 tx.entry("turn", age=199.9)]
g, root, p = case(settled_three)
check("U5i. the same three questions closed by a statement (text no longer ends in '?') -> idle/stopped, no summary, no options",
      g["state"] == "idle" and g["kind"] == "stopped" and g["summary"] is None and g["options"] is None, g)
g, root, p = case([tx.entry("end", age=10, text="Should I push (yes/no)")])
check("U5j. a polar question with no closing '?' is not a question at all: not needs_input, no options",
      g["state"] != "needs_input" and g["options"] is None, g)

# U6 -- idle: stopped / done
settled = [tx.entry("prompt", age=300), *tx.pair(age=250), tx.entry("end", age=200, text="All done."),
           tx.entry("turn", age=199.9)]
g, root, p = case(settled)
check("U6. a settled end_turn without '?' -> idle/stopped, summary and options null",
      g["state"] == "idle" and g["kind"] == "stopped" and g["summary"] is None and g["options"] is None, g)
rec = {"head_sha": "abcdef0123456789abcdef0123456789abcdef01"}
ck = {"head": "abcdef01"}
gate = {"clear_to_push": True}
g = run(root, sweep_receipt=rec, checkpoint=ck, quality_gate=gate)
check("U6b. receipt.head_sha ~ checkpoint.head AND the gate clear -> kind done", g["state"] == "idle" and g["kind"] == "done", g)
nots = [dict(sweep_receipt={"head_sha": "1234567890abcdef"}, checkpoint=ck, quality_gate=gate),
        dict(sweep_receipt=rec, checkpoint=ck, quality_gate={"clear_to_push": False}),
        dict(sweep_receipt=rec, checkpoint={"head": "abc"}, quality_gate=gate),
        dict(sweep_receipt=None, checkpoint=ck, quality_gate=gate)]
check("U6c. head mismatch / gate not clear / head shorter than 7 chars / no receipt -> stopped",
      all(run(root, **kw)["kind"] == "stopped" for kw in nots), [run(root, **kw)["kind"] for kw in nots])

# U7 -- an end_turn is not idle until it settles
g, root, p = case([tx.entry("prompt", age=20), tx.entry("end", age=1, text="Finished the refactor.")])
check("U7. an end_turn with no turn_duration yet (Stop hooks still running) stays working", g["state"] == "working", g)
g = run(root, now=time.time() + 60)
check("U7b. ... and settles to idle/stopped once SETTLE_S has passed", g["state"] == "idle" and g["kind"] == "stopped", g)

# U8 -- interrupt, sidechain, live subagents
g, root, p = case([tx.entry("prompt", age=50), tx.entry("tool_use", age=40, tid="t1"),
                   tx.entry("tool_result", age=39, tid="t1"), tx.entry("interrupt", age=30),
                   tx.entry("turn", age=29.9)])
check("U8. a user interrupt ends the turn: idle/stopped, not working forever", g["state"] == "idle" and g["kind"] == "stopped", g)
g, root, p = case([*settled, tx.entry("end", text="Really?", sidechain=True)])
check("U8b. a sidechain (sub-agent) entry is ignored", g["state"] == "idle" and g["kind"] == "stopped", g)
g, root, p = case(settled)
cache = os.path.join(root, ".heimdall", ".agents-count-cache")
os.makedirs(os.path.dirname(cache))
with open(cache, "w") as f:
    f.write("2\n")
check("U8c. fresh live-subagent count > 0 keeps a finished turn working", run(root)["state"] == "working")
with open(cache, "w") as f:
    f.write("0\n")
check("U8d. count 0 -> idle", run(root)["state"] == "idle")
with open(cache, "w") as f:
    f.write("3\n")
old = time.time() - 300
os.utime(cache, (old, old))
check("U8e. a stale count is ignored -> idle", run(root)["state"] == "idle")

# U9 -- needs_approval and what must NOT be one
call = tx.entry("tool_use", age=400, name="Bash", tid="t1", tool_input={"command": "npm publish"})
g, root, p = case([tx.entry("prompt", age=500), call])
check("U9. a Bash call with no result for 400s (grace 180s) -> needs_approval/permission; the summary names only the tool; since = the call",
      g["state"] == "needs_approval" and g["kind"] == "permission" and g["summary"] == "permission requested: Bash"
      and g["options"] is None and abs(g["since"] - ts_of(call)) < 0.002 and g["id"] != w_id, g)
g, root, p = case([tx.entry("prompt", age=500),
                   tx.entry("tool_use", age=400, tid="t1", tool_input={"command": "make", "timeout": 600000})])
check("U9b. the same age is still just working when the call asked for a 600s timeout", g["state"] == "working", g)
g, root, p = case([tx.entry("prompt", age=5000), tx.entry("tool_use", age=4000, name="Agent", tid="t1", tool_input={})])
check("U9c. a long-pending Agent call is working, never an approval", g["state"] == "working", g)
g, root, p = case([tx.entry("mode", mode="bypassPermissions"), tx.entry("prompt", age=500),
                   tx.entry("tool_use", age=400, tid="t1")])
check("U9d. permission-mode bypassPermissions can never be waiting on a prompt -> working", g["state"] == "working", g)
g, root, p = case([tx.entry("prompt", age=500), tx.entry("tool_use", age=400, name="Bash", tid="t1"),
                   tx.entry("tool_result", age=399, tid="t1")])
check("U9e. a call that has its result is not pending", g["state"] == "working", g)
g, root, p = case([tx.entry("prompt", age=5), tx.entry("tool_use", age=1, name="ExitPlanMode", tid="t1", tool_input={"plan": "p"})])
check("U9f. a pending ExitPlanMode is an approval at once (no timer)", g["state"] == "needs_approval" and g["kind"] == "permission", g)
ask = {"questions": [{"question": "Which database should we use?", "options": [{"label": "pg"}, {"label": "sqlite"}]}]}
g, root, p = case([tx.entry("prompt", age=5), tx.entry("tool_use", age=1, name="AskUserQuestion", tid="t1", tool_input=ask)])
check("U9g. a pending AskUserQuestion is needs_input/question at once; options stay null (the TUI owns the choice)",
      g["state"] == "needs_input" and g["kind"] == "question" and g["summary"] == "Which database should we use?"
      and g["options"] is None, g)

# U10 -- ended
g, root, p = case([tx.entry("prompt", age=60), tx.entry("end", age=50, text="Which one?")])
old = time.time() - 8 * 3600
os.utime(p, (old, old))
g = run(root)
check("U10. a transcript untouched for 8h -> ended (every state ages out, even needs_input); kind/summary/options null; since = its mtime",
      g["state"] == "ended" and g["kind"] is None and g["summary"] is None and g["options"] is None
      and abs(g["since"] - old) < 0.01 and ID_RE.match(g["id"] or ""), g)

# U11 -- secret scrub: the field is dropped, never the payload
secret = "ghp_" + "A1b2" * 9
g, root, p = case([tx.entry("end", age=5, text="Is %s the right token to use?" % secret)])
check("U11. a secret-shaped question -> summary null, state still needs_input/question",
      g["state"] == "needs_input" and g["kind"] == "question" and g["summary"] is None, g)
g, root, p = case([tx.entry("end", age=5, text="Pick a credential:\n\nA) %s\nB) none\n\nWhich one?" % secret)])
check("U11b. a secret-shaped option label -> options null, the clean summary survives",
      g["options"] is None and g["summary"] == "Which one?", g)
g, root, p = case([tx.entry("end", age=5, text="Is %s the right token to use?" % secret)])
check("U11c. a secret-shaped polar question gets NO Yes/No either (hmd-question is dropped for it, so the phone could not even show what Yes/No answers)",
      g["state"] == "needs_input" and g["options"] is None, g)

# U12 -- caps
long_q = ("This is a fairly long preamble sentence that keeps going and going. " * 6) \
    + "Should I go ahead and apply the migration to the staging database now?"
g, root, p = case([tx.entry("end", age=5, text=long_q)])
check("U12. a long paragraph -> the closing sentence, <= 160 chars, one line",
      g["summary"] == "Should I go ahead and apply the migration to the staging database now?", g)
g, root, p = case([tx.entry("end", age=5, text=("word " * 80).strip() + "?")])
check("U12b. one overlong sentence -> its tail with a leading ellipsis, exactly <= 160 chars",
      g["summary"].startswith("…") and len(g["summary"]) <= 160 and g["summary"].endswith("?"), g)
g, root, p = case([tx.entry("end", age=5, text="Line one\nline two?")])
check("U12c. a multi-line paragraph is flattened to a single line", g["summary"] == "Line one line two?", g)
many = "Pick:\n\n" + "\n".join("%s) option %d" % (chr(65 + i), i) for i in range(9)) + "\n\nWhich?"
g, root, p = case([tx.entry("end", age=5, text=many)])
check("U12d. nine enumerated options are not representable (max 8) -> options null", g["options"] is None, g)
g, root, p = case([tx.entry("end", age=5, text="Pick:\n\nA) " + "y" * 100 + "\nB) short\n\nWhich?")])
check("U12e. a 100-char label is cut to exactly 80 chars with an ellipsis",
      len(g["options"][0]["label"]) == 80 and g["options"][0]["label"].endswith("…"), g)
check("U12f. turn must be a non-negative int (bool and negatives -> null)",
      run(root, turn=True)["turn"] is None and run(root, turn=-1)["turn"] is None and run(root, turn=0)["turn"] == 0)

# U13 -- which transcript
root, pdir, p_cli = newroot()
sid_sdk = "bbbbbbbb-0000-4000-8000-000000000002"
p_sdk = os.path.join(pdir, sid_sdk + ".jsonl")
tx.append(p_cli, tx.entry("end", age=100, text="Which branch?"))
tx.append(p_sdk, tx.entry("prompt", age=10, entrypoint="sdk-py", session=sid_sdk))
now = time.time()
os.utime(p_cli, (now - 100, now - 100))
os.utime(p_sdk, (now - 10, now - 10))
clear()
check("U13. a NEWER headless (sdk-*) transcript does not displace the interactive one", run(root)["state"] == "needs_input")
os.environ["CLAUDE_CODE_SESSION_ID"] = sid_sdk
clear()
check("U13b. a pinned session id (env) wins over recency", run(root)["state"] == "working")
del os.environ["CLAUDE_CODE_SESSION_ID"]
os.remove(p_cli)
clear()
check("U13c. with only headless transcripts, the newest is used", run(root)["state"] == "working")

# U14 -- cost bounds
BYTES = [0]
OPENS = [0]
real_open = builtins.open


class Counting(object):
    def __init__(self, f):
        self._f = f

    def read(self, n=-1):
        data = self._f.read(n)
        BYTES[0] += len(data)
        return data

    def seek(self, *a):
        return self._f.seek(*a)

    def __enter__(self):
        self._f.__enter__()
        return self

    def __exit__(self, *a):
        return self._f.__exit__(*a)


def counting_open(path, mode="r", *a, **k):
    OPENS[0] += 1
    return Counting(real_open(path, mode, *a, **k))


g, root, p = case([tx.entry("prompt", age=5), tx.entry("end", age=2, text="Ready to ship?")])
clear()
run(root)
att.open = counting_open
BYTES[0] = OPENS[0] = 0
run(root)
del att.open
check("U14. an unchanged transcript costs zero reads (stat-keyed evidence + cached selection)", BYTES[0] == 0 and OPENS[0] == 0, [BYTES[0], OPENS[0]])

root, pdir, p = newroot()
line = (json.dumps(tx.entry("tool_use", age=1000, tid="tbig", tool_input={"command": "x" * 350})) + "\n").encode()
with open(p, "wb") as f:
    chunk = line * 2000
    while f.tell() < 50 * 1024 * 1024:
        f.write(chunk)
tx.append(p, tx.entry("end", age=3, text="Merge it?"))
clear()
att.open = counting_open
BYTES[0] = OPENS[0] = 0
t0 = time.perf_counter()
g = run(root)
dt = time.perf_counter() - t0
del att.open
check("U14b. a 50 MB transcript: correct state, %.0f ms, %d KiB read (<= 5 MiB, < 1 s)" % (dt * 1000, BYTES[0] // 1024),
      os.path.getsize(p) > 50 * 1024 * 1024 and g["state"] == "needs_input" and g["summary"] == "Merge it?"
      and dt < 1.0 and BYTES[0] <= 5 * 1024 * 1024, [g, dt, BYTES[0]])

root, pdir, p = newroot()
with open(p, "wb") as f:
    f.write(b'{"type":"user","pad":"' + b"x" * (10 * 1024 * 1024) + b'"}\n')
clear()
att.open = counting_open
BYTES[0] = OPENS[0] = 0
t0 = time.perf_counter()
g = run(root)
dt = time.perf_counter() - t0
del att.open
check("U14c. one 10 MiB final line: reads stay inside the 4 MiB window cap (+ head probe), result is the default shape",
      g == DEFAULT and dt < 1.0 and BYTES[0] <= 5 * 1024 * 1024, [g, dt, BYTES[0]])

# U15 -- the wire shape, over everything collected above
problems = []
for g in SEEN:
    if sorted(g) != sorted(DEFAULT):
        problems.append(("keys", g))
    elif g["state"] not in att.STATES or (g["kind"] is not None and g["kind"] not in att.KINDS):
        problems.append(("enum", g))
    elif g["id"] is not None and not ID_RE.match(g["id"]):
        problems.append(("id", g))
    elif g["since"] is not None and not isinstance(g["since"], float):
        problems.append(("since", g))
    elif g["summary"] is not None and (not isinstance(g["summary"], str) or len(g["summary"]) > 160 or "\n" in g["summary"]):
        problems.append(("summary", g))
    elif g["options"] is not None and (len(g["options"]) > 8 or any(
            sorted(o) != ["key", "label"] or len(o["label"]) > 80 for o in g["options"])):
        problems.append(("options", g))
    elif g["turn"] is not None and not isinstance(g["turn"], int):
        problems.append(("turn", g))
check("U15. all %d collected results have exactly the 7 documented keys, enum values, and caps" % len(SEEN), not problems, problems[:2])
check("U15b. the five documented states are all reachable (%s)" % ",".join(sorted({g["state"] for g in SEEN})),
      {g["state"] for g in SEEN} == set(att.STATES))

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

# ═══ L. the real server ═════════════════════════════════════════════════════════════════════
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
wait_for() {
  local file="$1" re="$2" secs="${3:-10}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    grep -Eq "$re" "$file" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
start_server() {
  local port="$1" out="$2"; shift 2
  ( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --port "$port" --no-open "$@" ) >"$out" 2>&1 &
  PIDS+=("$!")
}

PORT="$(free_port)"
SRV_OUT="$TMPROOT/server.out"
start_server "$PORT" "$SRV_OUT"
URL_RE="^http://127\.0\.0\.1:$PORT/\?(t|token)=[A-Za-z0-9_-]+\$"
if ! wait_for "$SRV_OUT" "$URL_RE" 10; then
  bad "L0. the server never printed its URL line within 10s; output:"
  sed 's/^/       | /' "$SRV_OUT"
  printf '\n%s passed, %s failed (server never came up; live cases not run)\n' "$PASS" "$FAIL"
  exit 1
fi
URL="$(grep -E "$URL_RE" "$SRV_OUT" | head -1)"
Q="${URL#*\?}"; TP="${Q%%=*}"; TOKEN="${Q#*=}"
BASE="http://127.0.0.1:$PORT"
AUTH="$TP=$TOKEN"
STATE_URL="$BASE/api/state?$AUTH"
DEFAULT_JSON='{"state":"idle","id":null,"since":null,"kind":null,"summary":null,"options":null,"turn":null}'

etag_of() {
  curl -s -D - -o /dev/null "$STATE_URL" | grep -i '^ETag:' | tr -d '\r' | sed -E 's/^ETag: *"(.*)"$/\1/'
}
poke() { curl -s -o /dev/null "$STATE_URL"; }   # a GET recollects and wakes the SSE stream
# att_is <label> <state> <kind-as-json>: poll .attention until it matches (bounded)
att_is() {
  local label="$1" st="$2" kd="$3" i=0 got=""
  while [ "$i" -lt 25 ]; do
    got="$(curl -s "$STATE_URL" | jq -c '.attention | [.state,.kind]' 2>/dev/null)"
    if [ "$got" = "[\"$st\",$kd]" ]; then ok "$label"; return 0; fi
    sleep 0.2; i=$((i + 1))
  done
  bad "$label (got $got; attention: $(curl -s "$STATE_URL" | jq -c .attention 2>/dev/null))"
  return 1
}
EV="$TMPROOT/events.out"
frames() { local n; n="$(grep -c '^data:' "$EV" 2>/dev/null)"; printf '%s' "${n:-0}"; }
wait_frames() {
  local want="$1" secs="${2:-6}" i=0 max
  max=$(( secs * 5 ))
  while [ "$i" -lt "$max" ]; do
    [ "$(frames)" -ge "$want" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
# exactly_frames <label> <n>: n frames arrived, and no extra one follows
exactly_frames() {
  local label="$1" want="$2"
  wait_frames "$want" 6
  sleep 1
  if [ "$(frames)" -eq "$want" ]; then ok "$label"; else bad "$label (frames=$(frames), expected exactly $want)"; fi
}

PS_OUT="$TMPROOT/print-sources.out"
( cd "$FIX" && HEIMDALL_WATCH_ROOT="$FIX" exec "$UI" --repo "$FIX" --print-sources ) >"$PS_OUT" 2>&1
if grep -q 'projects/<slug>/<session>.jsonl' "$PS_OUT" && grep -q '\.agents-count-cache' "$PS_OUT"; then
  ok "L0. --print-sources names the transcript and the subagent-count cache it reads"
else
  bad "L0. --print-sources omits the attention sources: $(grep -c . "$PS_OUT") lines"
fi

# L1 -- no transcript yet: the documented default, and the key sits beside the old ones
BODY="$TMPROOT/l1.json"
curl -s -o "$BODY" "$STATE_URL"
if jq -e --argjson d "$DEFAULT_JSON" '.attention == $d and .schema_version == 1 and has("inbox") and has("parallelism")' "$BODY" >/dev/null 2>&1; then
  ok "L1. no transcript -> .attention is the handoff's absent-file shape; schema_version and the old keys untouched"
else
  bad "L1. default attention wrong: $(jq -c .attention "$BODY" 2>/dev/null)"
fi

curl -sN "$BASE/api/events?$AUTH" >"$EV" 2>/dev/null &
PIDS+=("$!")
exactly_frames "L2. SSE: one frame on connect" 1

# L3 -- the handoff's replay order, .attention read after every step
txa prompt --text "start the refactor"; poke
att_is "L3a. user-prompt -> {working, null}" working null
exactly_frames "L3b. SSE: exactly one new frame for idle -> working" 2
BODY="$TMPROOT/l3.json"
curl -s -o "$BODY" "$STATE_URL"
SINCE_W="$(jq -r '.attention.since' "$BODY")"
ID_W="$(jq -r '.attention.id' "$BODY")"

# repeated tool-call entries while working: no frame, same ETag, same id/since
E0="$(etag_of)"
same=0
for _attempt in 1 2 3; do
  txa pair; E1="$(etag_of)"; txa pair; E2="$(etag_of)"; txa pair; E3="$(etag_of)"
  if [ "$E0" = "$E1" ] && [ "$E1" = "$E2" ] && [ "$E2" = "$E3" ]; then same=1; break; fi
  E0="$E3"
done
curl -s -o "$BODY" "$STATE_URL"
if [ "$same" = "1" ] && jq -e --arg i "$ID_W" --argjson s "$SINCE_W" '.attention.id == $i and .attention.since == $s' "$BODY" >/dev/null 2>&1; then
  ok "L4. three tool-call pairs while working -> same ETag, same attention.id and since"
else
  bad "L4. digest moved under tool calls: etags [$E0 $E1 $E2 $E3] attention=$(jq -c .attention "$BODY")"
fi
exactly_frames "L4b. SSE: no frame for repeated tool-call entries" 2

txa end --text "Shall I ship it now?"; poke
att_is "L5a. stop-with-question -> {needs_input, question}" needs_input '"question"'
exactly_frames "L5b. SSE: exactly one new frame for working -> needs_input" 3
curl -s -o "$BODY" "$STATE_URL"
if jq -e '.attention.summary == "Shall I ship it now?" and .attention.options == [{"key":"yes","label":"Yes"},{"key":"no","label":"No"}] and (.attention.id != null) and (.attention.since | type) == "number"' "$BODY" >/dev/null 2>&1; then
  ok "L5c. needs_input carries the question as its summary, Yes/No for a single closed polar question, a fresh id and a numeric since"
else
  bad "L5c. needs_input payload wrong: $(jq -c .attention "$BODY")"
fi

txa stop --text "Done, nothing else to report."; poke
att_is "L6a. stop-plain -> {idle, stopped}" idle '"stopped"'
exactly_frames "L6b. SSE: exactly one new frame for needs_input -> idle" 4

txa tool_use --age 400 --name Bash --input '{"command":"npm publish"}'; poke
att_is "L7a. permission pending -> {needs_approval, permission}" needs_approval '"permission"'
exactly_frames "L7b. SSE: exactly one new frame for idle -> needs_approval" 5
curl -s -o "$BODY" "$STATE_URL"
if jq -e '.attention.summary == "permission requested: Bash"' "$BODY" >/dev/null 2>&1; then
  ok "L7c. needs_approval names the tool and nothing else"
else
  bad "L7c. needs_approval summary: $(jq -c .attention.summary "$BODY")"
fi

python3 -c "import os,sys,time; t=time.time()-8*3600; os.utime(sys.argv[1],(t,t))" "$TX"; poke
att_is "L8a. session-end (no write for 8h) -> {ended, null}" ended null
exactly_frames "L8b. SSE: exactly one new frame for needs_approval -> ended" 6

# L9 -- a secret-shaped question: the field goes, the state stays
SECRET="ghp_$(python3 -c 'print("A1b2" * 9)')"
txa end --text "Is $SECRET the right token to use?"; poke
att_is "L9a. secret-shaped question -> still {needs_input, question}" needs_input '"question"'
curl -s -o "$BODY" "$STATE_URL"
if jq -e '.attention.summary == null and .attention.options == null' "$BODY" >/dev/null 2>&1 && ! grep -q "$SECRET" "$BODY"; then
  ok "L9b. ... summary is null and the secret appears nowhere in /api/state"
else
  bad "L9b. secret handling: $(jq -c .attention "$BODY")"
fi

# L10 -- public mode redacts a path and an email; loopback keeps them
RAW="Delete /Users/rj/private/notes.txt and email bob@example.com?"
txa end --text "$RAW"; poke
PORT2="$(free_port)"
SRV2_OUT="$TMPROOT/server2.out"
start_server "$PORT2" "$SRV2_OUT" --allow-host fixture.example
URL2_RE="^http://127\.0\.0\.1:$PORT2/\?(t|token)=[A-Za-z0-9_-]+\$"
if wait_for "$SRV2_OUT" "$URL2_RE" 10; then
  URL2="$(grep -E "$URL2_RE" "$SRV2_OUT" | head -1)"
  Q2="${URL2#*\?}"
  PUB="$TMPROOT/public.json"
  curl -s -H "Host: fixture.example" -o "$PUB" "http://127.0.0.1:$PORT2/api/state?$Q2"
  curl -s -o "$BODY" "$STATE_URL"
  if jq -e --arg raw "$RAW" '.attention.summary == $raw' "$BODY" >/dev/null 2>&1; then
    ok "L10a. loopback keeps the summary byte-for-byte"
  else
    bad "L10a. loopback summary changed: $(jq -c .attention.summary "$BODY")"
  fi
  if jq -e '.attention.summary == "Delete notes.txt and email [email]?" and .attention.state == "needs_input"' "$PUB" >/dev/null 2>&1; then
    ok "L10b. public mode (--allow-host): the path becomes its basename and the email '[email]' inside attention.summary"
  else
    bad "L10b. public attention: $(jq -c .attention "$PUB" 2>/dev/null)"
  fi
else
  bad "L10. the --allow-host server never came up: $(head -c 300 "$SRV2_OUT")"
fi

# L11 -- a 50 MB transcript is one bounded read
BIG="$PROJ/cccccccc-0000-4000-8000-000000000003.jsonl"
python3 - "$BIG" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["TMPROOT"])
import tx

p = sys.argv[1]
sess = "cccccccc-0000-4000-8000-000000000003"
line = (json.dumps(tx.entry("tool_use", age=1000, tid="tbig", session=sess, tool_input={"command": "x" * 350})) + "\n").encode()
with open(p, "wb") as f:
    chunk = line * 2000
    while f.tell() < 50 * 1024 * 1024:
        f.write(chunk)
tx.append(p, tx.entry("end", age=1, text="Big transcript, still one question?", session=sess))
PYEOF
att_is "L11a. the newest transcript (50 MB) is picked up: {needs_input, question}" needs_input '"question"'
TT="$(curl -s -o /dev/null -w '%{time_total}' "$STATE_URL")"
if awk -v t="$TT" 'BEGIN{exit !(t < 1.0)}' && [ "$(wc -c < "$BIG" | tr -d ' ')" -gt 52428800 ]; then
  ok "L11b. GET /api/state over the 50 MB transcript: ${TT}s (< 1s)"
else
  bad "L11b. GET /api/state over the 50 MB transcript took ${TT}s"
fi

# L12 -- attention and the native companion publishers (A3) together: both ON, and NO GET anywhere.
# One transcript append now changes attention AND the chat / hmd-question panels. On the poller-only
# path (what bin/heimdall-relay-client reads, via StateCache.latest()) the contract is coherence: the
# FIRST frame announcing a transition already carries the panels it implies. Inside one poller pass
# attention is read before the publishers run and a transcript only grows, so attention can lag the
# panels but never lead them -- which is why this asserts content, not a frame count (a pass that
# lags is a legal second frame). A GET /api/state in between WOULD break it: refresh() on a GET
# never publishes, so it shows the new attention a poll tick before the panels (see "Publishers").
FIX3="$TMPROOT/fixture-repo-3"
mkdir -p "$FIX3"
FIX3_REAL="$(cd "$FIX3" && pwd -P)"
PROJ3="$HOME/.claude/projects/$(printf '%s' "$FIX3_REAL" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$PROJ3"
TX3="$PROJ3/$SID.jsonl"
( cd "$FIX3" && git init -q . 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture >/dev/null 2>&1 ) || true
txf() { python3 "$TXPY" "$TX3" "$@"; }
# first_frame <jq-condition>: the first SSE frame of $EV3 satisfying it (compact JSON), else nothing.
first_frame() { sed -n 's/^data: //p' "$EV3" | jq -c "select($1)" 2>/dev/null | head -1; }
# announced_with_panels <label> <announce-condition> <implied-condition>: wait (bounded, polling the
# stream file -- never /api/state) for the first frame announcing the transition, then require it to
# satisfy what the same append implies for the panels.
announced_with_panels() {
  local label="$1" announce="$2" implied="$3" i=0 f=""
  while [ "$i" -lt 40 ]; do
    f="$(first_frame "$announce")"
    [ -n "$f" ] && break
    sleep 0.2; i=$((i + 1))
  done
  if [ -z "$f" ]; then bad "$label (no frame announced it within 8s)"; return 1; fi
  if printf '%s' "$f" | jq -e "$implied" >/dev/null 2>&1; then ok "$label"; return 0; fi
  bad "$label (first frame: attention=$(printf '%s' "$f" | jq -c '[.attention.state,.attention.kind]') panels=$(printf '%s' "$f" | jq -c '[.panels[].id]'))"
  return 1
}
PORT3="$(free_port)"
SRV3_OUT="$TMPROOT/server3.out"
( cd "$FIX3" && HEIMDALL_WATCH_ROOT="$FIX3" HMD_UI_COMPANION_PANELS=1 exec "$UI" --repo "$FIX3" --port "$PORT3" --no-open ) >"$SRV3_OUT" 2>&1 &
PIDS+=("$!")
URL3_RE="^http://127\.0\.0\.1:$PORT3/\?(t|token)=[A-Za-z0-9_-]+\$"
if wait_for "$SRV3_OUT" "$URL3_RE" 10; then
  URL3="$(grep -E "$URL3_RE" "$SRV3_OUT" | head -1)"
  EV3="$TMPROOT/events3.out"
  curl -sN "http://127.0.0.1:$PORT3/api/events?${URL3#*\?}" >"$EV3" 2>/dev/null &
  PIDS+=("$!")
  wait_for "$EV3" '^data:' 10   # the connect frame is in; from here only the poller touches the cache
  txf prompt --text "start the refactor"
  announced_with_panels "L12a. publishers on, no GET: the first frame announcing working already carries the prompt in chat" \
    '.attention.state == "working"' \
    '[.panels[] | select(.id == "chat") | .data.lines[]] | any(test("you start the refactor$"))'
  txf end --text "Shall I ship it now?"
  announced_with_panels "L12b. ... the first needs_input frame already carries hmd-question and the question as chat's last line" \
    '.attention.state == "needs_input"' \
    '([.panels[] | select(.id == "hmd-question") | .data.text] == ["Shall I ship it now?"]) and (([.panels[] | select(.id == "chat") | .data.lines[-1]] | .[0] // "") | test("hmd Shall I ship it now\\?$"))'
  txf stop --text "Done, nothing else to report."
  announced_with_panels "L12c. ... the first idle frame already dropped hmd-question and carries the reply as chat's last line" \
    '.attention.state == "idle" and .attention.id != null' \
    '(([.panels[].id] | index("hmd-question")) == null) and (([.panels[] | select(.id == "chat") | .data.lines[-1]] | .[0] // "") | test("hmd Done, nothing else to report\\.$"))'
else
  bad "L12. the server with the publishers on never came up: $(head -c 300 "$SRV3_OUT")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
