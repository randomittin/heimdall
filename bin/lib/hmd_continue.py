#!/usr/bin/env python3
r"""heimdall-continue -- /compact and /continue in one move (stdlib only).

WHY. No skill, command or hook can run /compact or /clear: only the user types them. PreCompact cannot inject context. SessionStart with
source "compact" can (hookSpecificOutput.additionalContext). So "compact, then carry on with full context" is three jobs, and this tool does the
two that are not the user's: it WRITES a handoff before the compaction and INJECTS it after. The third, typing the line, stays with the user.

Usage:
  heimdall-continue write  [--repo DIR]
        the note on stdin. Records the next step and the gated items through the existing notes seam (`heimdall-checkpoint note`), takes a fresh
        checkpoint (`heimdall-checkpoint write`, the existing writer), writes .planning/CONTINUE.md (the note + the checkpoint's "What must never be
        lost" block as it stood) and prints ONE ready-to-paste line, `/compact <focus>`, as the LAST line of stdout. The line is under 1500 chars
        however much state it is given: decisions are dropped first, then agents, then gated items; the next step is kept whole.
  heimdall-continue focus
        the note on stdin; prints the `/compact <focus>` line and nothing else (no checkpoint, nothing written).
  heimdall-continue inject [--repo DIR] [--source S] [--prefix TEXT]
        the SessionStart side, run by bin/heimdall-resume-probe. When a handoff is waiting -- written by `write` no more than
        HMD_CONTINUE_WINDOW_MIN minutes ago (default 30, 0 turns this off), not yet consumed -- and the restart is a compaction (--source compact, or
        the "source" of the hook payload on stdin), it prints ONE line of hookSpecificOutput JSON whose additionalContext is --prefix (the probe's
        verdict, which the probe's own output would have carried) plus the whole handoff, then marks the handoff consumed. Anything else prints
        nothing and leaves the handoff where it is.

THE NOTE (stdin, one `key: value` per line; a quoted heredoc passes any text without shell quoting):
    goal: <the current task, one line>                                   once
    next: <the exact next step>                                          once, required
    agent: <what it does> | <worktree path> | <state>                    any number: the agents still in flight
    decision: <what was decided this session, and why>                   any number
    gated: <what waits on a human call>                                  any number
  Blank lines and lines starting with # are ignored; any other key is refused (exit 2). A value is flattened to one line (control characters
  become spaces) and cut at 300 chars (next: 600); at most 10 of each list are kept.

THE HANDOFF. .planning/CONTINUE.md, first line `<!-- hmd-continue:v1 id=<8 hex> written_ts=<epoch> consumed_ts=<epoch or empty> -->`, then the
note and the contract block. The state lives in that first line: `inject` rewrites it with consumed_ts when it injects, so the same handoff is
never injected twice and a new `write` is a new handoff. A file without that line is not a handoff. A date in the future is never fresh (a
repository can ship a file; it cannot ship a date inside the window). The injected text is cut at 9000 chars: the harness caps hook context at
10000 and replaces the rest with a preview.

LINKS. Every read and write below the repository goes through bin/lib/hmd_nofollow_write.py (each component opened O_NOFOLLOW relative to the one
before). A link on the way down (.planning, CONTINUE.md) or an entry that is not a regular file is REFUSED: `write` exits 4 and writes nothing,
`inject` reads and rewrites nothing.

EXIT  0 done | 1 failed (an I/O error) | 2 usage or a bad note | 3 `write` made the handoff but the checkpoint was not saved (said on stderr; the
      line is still printed) | 4 REFUSED (a link or an entry that is not plain)

Python 3.7+, standard library only.
"""
import argparse
import json
import os
import re
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_nofollow_write as nf  # noqa: E402  (the no-follow walk every read and write goes through)

OK, FAILED, USAGE, PARTIAL, REFUSED = 0, 1, 2, 3, nf.REFUSED
REL, NAME, CKPT_NAME = ".planning", "CONTINUE.md", "CHECKPOINT.md"
LINE_CAP = 1500  # chars of the pasted line, "/compact " included
INJECT_CAP = 9000  # chars of additionalContext (the harness caps hook context at 10000)
PREFIX_CAP = 1000  # chars of the probe verdict that rides along
DEFAULT_WINDOW_MIN = 30
SKEW_S = 120  # a clock this far ahead still reads as now; further is a planted date
MAX_FILE = 1 << 20
MAX_NOTE = 1 << 16
MAX_ITEMS = 10
WRITER_BUDGET_S = 60
PAYLOAD_WAIT_S = 2.0
CAPS = {"goal": 300, "next": 600, "agent": 200, "decision": 200, "gated": 200}
SINGLE = ("goal", "next")
LISTS = ("agent", "decision", "gated")
DROP_ORDER = ("decision", "agent", "gated")  # the first to go when the line is too long
LABELS = ("In progress", "Gated decisions", "Held branches", "Unpushed", "Open warnings", "Refuted claims")
FIELD_CAP = 600
TAIL = "The full handoff is re-injected from .planning/CONTINUE.md after compaction."
MARK_RE = re.compile(r"<!-- hmd-continue:v1 id=([0-9a-f]{8}) written_ts=([0-9]{1,12}) consumed_ts=([0-9]{0,12}) -->")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]+")
BLOCK_CONTROL_RE = re.compile(r"[\x00-\x09\x0b-\x1f\x7f-\x9f\u2028\u2029]+")  # the same, but a newline stays (the probe verdict is several lines)


class Fail(Exception):
    """A refusal or failure with its exit status; the message is printed on stderr."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def scrub(text):
    """`text` with anything that is not valid UTF-8 (a lone surrogate from a raw argv byte) replaced, so it can always be written out."""
    return text.encode("utf-8", "replace").decode("utf-8", "replace")


def say(text):
    sys.stdout.buffer.write((scrub(text) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def warn(text):
    sys.stderr.buffer.write((scrub(text) + "\n").encode("utf-8"))
    sys.stderr.buffer.flush()


def clean(text, cap):
    """One line: control characters become spaces, runs of white space one space, cut at `cap` chars."""
    text = " ".join(CONTROL_RE.sub(" ", scrub(text)).split())
    return text if len(text) <= cap else text[: cap - 3].rstrip() + "..."


def repo_root(path):
    path = path or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if not os.path.isdir(path):
        raise Fail(USAGE, "%s is not a directory" % path)
    return os.path.realpath(path)


# ── reading and writing below the repository, never through a link ────────────
class Capped(object):
    """The sink hmd_nofollow_write.read copies into: it keeps the chunks and refuses to hold more than `cap` bytes."""

    def __init__(self, cap, shown):
        self.chunks, self.size, self.cap, self.shown = [], 0, cap, shown

    def write(self, chunk):
        self.size += len(chunk)
        if self.size > self.cap:
            raise Fail(FAILED, "%s is larger than %d bytes" % (self.shown, self.cap))
        self.chunks.append(chunk)


def read_file(root, name):
    """The text of <root>/.planning/<name>, None when it (or .planning) is not there. nf.Refused when a link, a hard-linked file or an entry that is
    not a regular file is in the way."""
    sink = Capped(MAX_FILE, "%s/%s" % (REL, name))
    try:
        nf.read(root, REL, name, sink)
    except FileNotFoundError:
        return None
    return b"".join(sink.chunks).decode("utf-8", "replace")


def put_file(root, text):
    try:
        nf.write(root, REL, NAME, text.encode("utf-8"), 0o600)
    except nf.Refused as exc:
        raise Fail(REFUSED, "refused: %s; nothing was written" % exc)
    except OSError as exc:
        raise Fail(FAILED, "cannot write %s/%s: %s" % (REL, NAME, exc))


def marker(hid, written, consumed):
    return "<!-- hmd-continue:v1 id=%s written_ts=%d consumed_ts=%s -->" % (hid, written, consumed)


# ── the note ──────────────────────────────────────────────────────────────────
def read_note_text():
    if sys.stdin is None or sys.stdin.isatty():
        raise Fail(USAGE, "the note goes on stdin (goal:/next:/agent:/decision:/gated: lines, e.g. a quoted heredoc); see --help")
    raw = sys.stdin.buffer.read(MAX_NOTE + 1)
    if len(raw) > MAX_NOTE:
        raise Fail(USAGE, "the note is larger than %d bytes" % MAX_NOTE)
    return raw.decode("utf-8", "replace")


def parse_note(text):
    note = {"goal": "", "next": "", "agent": [], "decision": [], "gated": [], "extra": 0}
    seen = set()
    for lineno, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, colon, value = line.partition(":")
        key = key.strip().lower()
        if not colon or key not in CAPS:
            raise Fail(USAGE, "note line %d (%r) does not start with goal:, next:, agent:, decision: or gated:" % (lineno, clean(line, 60)))
        value = clean(value, CAPS[key])
        if not value:
            continue
        if key in SINGLE:
            if key in seen:
                raise Fail(USAGE, "note line %d: %s: is given twice" % (lineno, key))
            seen.add(key)
            note[key] = value
        elif len(note[key]) < MAX_ITEMS:
            note[key].append(value)
        else:
            note["extra"] += 1
    if not note["next"]:
        raise Fail(USAGE, "the note has no next: line -- the /compact line must carry the exact next step")
    return note


def focus_line(note, cap=LINE_CAP):
    """`/compact <focus>` in one line of at most `cap` chars. When it is too long the lowest-priority items go first (decisions, then agents, then
    gated items), each drop is counted on the line, a long goal is shortened next, and only then is the next step cut -- from its end."""
    goal, nxt = note["goal"], note["next"]
    items = dict((key, list(note[key])) for key in LISTS)
    dropped = note["extra"]

    def render():
        parts = []
        if goal:
            parts.append("Goal: " + goal)
        parts.append("Next step: " + nxt)
        if items["agent"]:
            parts.append("In flight: " + "; ".join(items["agent"]))
        if items["gated"]:
            parts.append("Gated on a human: " + "; ".join(items["gated"]))
        if items["decision"]:
            parts.append("Decided: " + "; ".join(items["decision"]))
        more = " (+%d more in the handoff)" % dropped if dropped else ""
        return "/compact Keep for the resume. " + ". ".join(parts) + "." + more + " " + TAIL

    while len(render()) > cap:
        victim = next((key for key in DROP_ORDER if items[key]), None)
        if victim is not None:
            items[victim].pop()
            dropped += 1
        elif len(goal) > 120:
            goal = goal[:117].rstrip() + "..."
        else:
            nxt = nxt[: max(40, len(nxt) - (len(render()) - cap) - 3)].rstrip() + "..."
            break
    return render()[:cap]


# ── the checkpoint (the existing writer and notes seam) ───────────────────────
def sibling(name):
    path = os.path.join(os.path.dirname(HERE), name)
    return path if os.path.isfile(path) and os.access(path, os.X_OK) else None


def run(argv, cwd, timeout):
    """(exit status, stdout, stderr); 142 when it ran past `timeout`, 127 when it could not start."""
    try:
        done = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 142, "", "ran past %d s" % timeout
    except OSError as exc:
        return 127, "", str(exc)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def last_line(text):
    lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
    return clean(lines[-1], 200) if lines else ""


def checkpoint_pass(root, note):
    """Record the session-only knowledge, take the checkpoint, read the contract block back. (fields or None, branch/HEAD text, problems)."""
    problems = []
    ckpt = sibling("heimdall-checkpoint")
    if ckpt is None:
        return None, "", ["bin/heimdall-checkpoint was not found beside this tool"]
    notes = [("in-progress", "next: " + note["next"])] + [("gated", item) for item in note["gated"]]
    for kind, text in notes:
        rc, _, err = run([ckpt, "note", kind, text], root, 10)
        if rc != 0:
            problems.append("note %s not recorded (exit %d: %s)" % (kind, rc, last_line(err)))
    rc, _, err = run([ckpt, "write", root], root, WRITER_BUDGET_S)
    if rc != 0:
        problems.append("heimdall-checkpoint write exited %d (%s)" % (rc, last_line(err)))
        return None, "", problems
    try:
        text = read_file(root, CKPT_NAME) or ""
    except (nf.Refused, OSError, Fail) as exc:
        problems.append("CHECKPOINT.md cannot be read back (%s)" % exc)
        return None, "", problems
    fields = {}
    for label in LABELS:
        found = re.findall(r"^- \*\*%s:\*\* (.*)$" % re.escape(label), text, re.M)
        if len(found) != 1:
            problems.append("the %r field did not read back from CHECKPOINT.md exactly once" % label)
            return None, "", problems
        fields[label] = clean(found[0], FIELD_CAP)
    where = re.search(r"^- \*\*Branch:\*\* (.+)$", text, re.M), re.search(r"^- \*\*HEAD:\*\* (.+)$", text, re.M)
    facts = " @ ".join(m.group(1).strip() for m in where if m)
    return fields, clean(facts, 200), problems


def render_note(note, fields, facts, problems, stamp, window):
    out = ["# Continue note - %s (written by /hmd:continue)" % stamp, ""]
    out.append("Re-injected once, after the first compaction within %d min of this note. Act on the next step first." % window)
    out.append("")
    if note["goal"]:
        out.append("- **Goal:** " + note["goal"])
    out.append("- **Next step:** " + note["next"])
    if facts:
        out.append("- **Branch / HEAD:** " + facts)
    for title, key in (("In-flight agents", "agent"), ("Decisions made this session", "decision"), ("Gated on a human", "gated")):
        if note[key]:
            out += ["", "## " + title] + ["- " + item for item in note[key]]
    if note["extra"]:
        out += ["", "(+%d more items were over the limit of %d per list and were not kept)" % (note["extra"], MAX_ITEMS)]
    out += ["", "### What must never be lost (the resume contract, as /hmd:continue saw it)"]
    if fields is None:
        out.append("- Checkpoint unavailable: %s. Run `heimdall-checkpoint write` and read .planning/CHECKPOINT.md before relying on this note." % "; ".join(problems))
    else:
        out += ["- **%s:** %s" % (label, fields[label]) for label in LABELS]
    out += ["", "Full state: .planning/CHECKPOINT.md (the PreCompact hook refreshes it when the session compacts)."]
    return "\n".join(out) + "\n"


def window_minutes():
    raw = os.environ.get("HMD_CONTINUE_WINDOW_MIN", "")
    if raw == "":
        return DEFAULT_WINDOW_MIN
    if re.fullmatch("[0-9]{1,6}", raw):
        return int(raw)
    warn("[heimdall-continue] HMD_CONTINUE_WINDOW_MIN=%r is not a whole number of minutes; using %d" % (raw, DEFAULT_WINDOW_MIN))
    return DEFAULT_WINDOW_MIN


def cmd_focus(args):
    say(focus_line(parse_note(read_note_text())))
    return OK


def cmd_write(args):
    note = parse_note(read_note_text())
    root = repo_root(args.repo)
    try:
        nf.check(root, [REL + "/", "%s/%s" % (REL, NAME)])
    except nf.Refused as exc:
        raise Fail(REFUSED, "refused: %s; nothing was written" % exc)
    except OSError as exc:
        raise Fail(FAILED, "cannot check %s: %s" % (root, exc))
    fields, facts, problems = checkpoint_pass(root, note)
    window = window_minutes()
    now = int(time.time())
    hid = os.urandom(4).hex()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    put_file(root, marker(hid, now, "") + "\n" + render_note(note, fields, facts, problems, stamp, window))
    say("[heimdall-continue] handoff written: %s/%s/%s (id %s)" % (root, REL, NAME, hid))
    if problems:
        warn("[heimdall-continue] WARNING - checkpoint not fully saved: %s. The handoff has the note but no resume-contract snapshot; run heimdall-checkpoint write too."
             % "; ".join(problems))
    else:
        say("[heimdall-continue] checkpoint saved, all %d resume fields are in the handoff" % len(LABELS))
    if window == 0:
        warn("[heimdall-continue] HMD_CONTINUE_WINDOW_MIN=0: the handoff will NOT be re-injected after compaction")
    else:
        say("[heimdall-continue] it is re-injected once, after the first compaction within %d min" % window)
    line = focus_line(note)
    say("[heimdall-continue] paste this as your next message (%d of %d chars; only you can run /compact):" % (len(line), LINE_CAP))
    say(line)
    return PARTIAL if problems else OK


# ── the SessionStart side ─────────────────────────────────────────────────────
def payload_source():
    """The "source" of the hook payload on stdin ("startup", "resume", "clear", "compact"), None when there is no payload to read: a terminal, an
    empty or closed stdin, a payload that is not JSON, or one that does not arrive within PAYLOAD_WAIT_S."""
    if sys.stdin is None or sys.stdin.isatty():
        return None
    try:
        fd = sys.stdin.fileno()
        chunks, size, deadline = [], 0, time.monotonic() + PAYLOAD_WAIT_S
        while size < MAX_NOTE:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                break
            chunk = os.read(fd, 1 << 14)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        data = json.loads(b"".join(chunks).decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    source = data.get("source") if isinstance(data, dict) else None
    return source if isinstance(source, str) else None


def ago(seconds):
    return "%d s" % seconds if seconds < 90 else "%d min" % (seconds // 60)


def mark_consumed(root, hid, now):
    """Rewrite the marker line with consumed_ts. Not done when the file is a newer handoff by now (a `write` raced this) or cannot be rewritten."""
    try:
        text = read_file(root, NAME) or ""
        first, newline, rest = text.partition("\n")
        found = MARK_RE.fullmatch(first.strip())
        if found is None or found.group(1) != hid:
            return
        nf.write(root, REL, NAME, (marker(hid, int(found.group(2)), str(now)) + newline + rest).encode("utf-8"), 0o600)
    except (nf.Refused, OSError, Fail) as exc:
        warn("[heimdall-continue] injected, but the handoff could not be marked consumed (%s); it may be injected again within its window" % exc)


def cmd_inject(args):
    root = repo_root(args.repo)
    try:
        text = read_file(root, NAME)
    except nf.Refused as exc:
        raise Fail(REFUSED, "handoff skipped: %s" % exc)
    except OSError as exc:
        raise Fail(FAILED, "handoff unreadable: %s" % exc)
    if text is None:
        return OK
    first, _, body = text.partition("\n")
    found = MARK_RE.fullmatch(first.strip())
    if found is None:
        warn("[heimdall-continue] %s/%s has no handoff marker line: ignored" % (REL, NAME))
        return OK
    hid, written, consumed = found.group(1), int(found.group(2)), found.group(3)
    now = int(time.time())
    window = window_minutes()
    if consumed or window == 0 or written > now + SKEW_S or now - written > window * 60:
        return OK
    if (args.source or payload_source()) != "compact":
        return OK
    parts = []
    if args.prefix:
        parts.append(BLOCK_CONTROL_RE.sub(" ", scrub(args.prefix))[:PREFIX_CAP].strip())
    parts.append("[heimdall] /hmd:continue handoff (written %s ago), re-injected once because this session was just compacted:" % ago(max(0, now - written)))
    parts.append(scrub(body).strip("\n"))
    context = "\n\n".join(parts)
    if len(context) > INJECT_CAP:
        cut = "\n[cut at %d chars: the whole handoff is in %s/%s]" % (INJECT_CAP, REL, NAME)
        context = context[: INJECT_CAP - len(cut)] + cut
    say(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
    mark_consumed(root, hid, now)
    return OK


def main(argv=None):
    parser = argparse.ArgumentParser(prog="heimdall-continue", description="/compact and /continue in one move: write the handoff, print the line to paste, re-inject the handoff after compaction.")
    sub = parser.add_subparsers(dest="action", required=True)
    wr = sub.add_parser("write", help="the note on stdin: checkpoint, write .planning/CONTINUE.md, print ONE /compact line")
    wr.add_argument("--repo", default="", help="the project dir (default: $CLAUDE_PROJECT_DIR, else the cwd)")
    sub.add_parser("focus", help="the note on stdin: print the /compact line only")
    inj = sub.add_parser("inject", help="the SessionStart side: print the hook JSON for a fresh, unconsumed handoff on a compaction restart")
    inj.add_argument("--repo", default="", help="the project dir (default: $CLAUDE_PROJECT_DIR, else the cwd)")
    inj.add_argument("--source", default="", help="the SessionStart source; default: the \"source\" of the hook payload on stdin")
    inj.add_argument("--prefix", default="", help="text that leads the injected context (the probe's verdict)")
    args = parser.parse_args(argv)
    try:
        return {"write": cmd_write, "focus": cmd_focus, "inject": cmd_inject}[args.action](args)
    except Fail as exc:
        warn("[heimdall-continue] %s" % exc.message)
        return exc.code


if __name__ == "__main__":
    sys.exit(main())
