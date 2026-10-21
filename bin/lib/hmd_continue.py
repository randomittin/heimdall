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
  heimdall-continue inject [--repo DIR] [--source S]
        the SessionStart(compact) side, run by the `continue-inject` hook of hooks/hooks.json: a SessionStart entry of its own with matcher "compact",
        so switching bin/heimdall-resume-probe off (`heimdall-hooks disable resume-probe`) leaves it working and `heimdall-hooks disable continue-inject`
        turns it off. When a handoff is waiting -- written by `write` no more than HMD_CONTINUE_WINDOW_MIN minutes ago (default 30, 0 turns this off),
        not yet consumed, and PROVEN (below) -- and the restart is a compaction (--source compact, or the "source" of the hook payload on stdin), it
        prints ONE line of hookSpecificOutput JSON whose additionalContext is the whole handoff behind a one-line header, then marks the handoff
        consumed. Anything else prints nothing and leaves the handoff where it is.

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
never injected twice and a new `write` is a new handoff. A file without that line is not a handoff. A date in the future is never fresh (the date is
the cheapest check, not the one that keeps a repository from supplying a handoff: see PROVENANCE). The injected text is cut at 9000 chars: the harness
caps hook context at 10000 and replaces the rest with a preview.

LINKS. Every read and write below the repository goes through bin/lib/hmd_nofollow_write.py (each component opened O_NOFOLLOW relative to the one
before). A link on the way down (.planning, CONTINUE.md) or an entry that is not a regular file is REFUSED: `write` exits 4 and writes nothing,
`inject` reads and rewrites nothing.

PROVENANCE. A repository controls every name below its root, so a clone can ship a .planning/CONTINUE.md with a fresh-looking marker line, and whatever
it says would enter the session as context the model acts on. `inject` therefore believes a handoff only when BOTH hold:
  1. git does not track the file: `git ls-files --error-unmatch` (5 s, run with no GIT_* variable in its environment: a session's environment is the
     repository's to set, and GIT_INDEX_FILE or GIT_DIR would make git answer about another index). A tracked file, a git that fails, times out or is
     not there, and any answer but "unknown to git" are refusals.
  2. its id and written_ts match the record `write` kept for this repository in the operator's home: $HEIMDALL_HOME/continue/<sha256(realpath repo)[:16]>.json,
     {"v":1,"repo":<realpath>,"id":<id>,"written_ts":<epoch>}, 0600 in a 0700 directory, written and read through bin/lib/hmd_private_state.py (no link
     followed; a file of this user's with no group or other permission bits, or it is not believed). HEIMDALL_HOME is resolved as the relay-approval and
     pair-optin stores resolve it (bin/lib/hmd_relay_approval.py, one definition): an absolute path, else ~/.heimdall -- a relative one would mean the
     repository -- and a store inside the repository or inside ANY git work tree is neither read nor made, because a record planted there would vouch for itself.
Anything else injects nothing, says why on stderr and leaves the file alone. `write` checks the same two things when it is done and says so -- stderr,
exit 3, the line still printed -- when the handoff will NOT come back. The record binds the handoff's identity and time, not its body: it keeps a clone
from supplying a handoff, not a process that can already write your working tree.

EXIT  0 done | 1 failed (an I/O error) | 2 usage or a bad note | 3 `write` made the handoff but something is incomplete (said on stderr; the line is still
      printed): the checkpoint was not saved, or the handoff will not be re-injected (no record could be kept, or git tracks it, or git cannot say) |
      4 REFUSED (a link or an entry that is not plain)

Python 3.7+, standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_nofollow_write as nf  # noqa: E402  (the no-follow walk every read and write below the repository goes through)
import hmd_relay_approval as approval  # noqa: E402  (where HEIMDALL_HOME is, what is inside a git work tree, and the vetted reader of a record in the operator's home: one definition, shared with the relay-approval and pair-optin stores)

private = approval.PRIVATE  # hmd_private_state: the no-follow, 0600-in-0700 writer the record goes through

OK, FAILED, USAGE, PARTIAL, REFUSED = 0, 1, 2, 3, nf.REFUSED
REL, NAME, CKPT_NAME = ".planning", "CONTINUE.md", "CHECKPOINT.md"
HOME_REL = "continue"  # <HEIMDALL_HOME>/continue/<sha256(realpath repo)[:16]>.json: the record `write` keeps of the handoff it made for that repository
RECORD_VERSION = 1
GIT_BUDGET_S = 5  # how long `git ls-files` may take before the handoff is refused
LINE_CAP = 1500  # chars of the pasted line, "/compact " included
INJECT_CAP = 9000  # chars of additionalContext (the harness caps hook context at 10000)
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


def run(argv, cwd, timeout, env=None):
    """(exit status, stdout, stderr); 142 when it ran past `timeout`, 127 when it could not start. `env`, when given, is the whole environment."""
    try:
        done = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
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


# ── provenance: who made this handoff (see PROVENANCE above) ───────────────────
def record_name(root):
    return "%s.json" % hashlib.sha256(os.fsencode(root)).hexdigest()[:16]


def keep_record(root, hid, written):
    """Keep what `inject` will ask for: this handoff's id and time, for this repository, in the operator's home. None when it is kept, else the reason it is not --
    nothing is created, in the repository or in any git work tree, when the home cannot be believed."""
    base = approval.home()
    if base is None:
        return "there is no absolute HEIMDALL_HOME or HOME to keep a record under"
    try:
        probe = approval._deepest_dir(os.path.join(base, HOME_REL))  # the directory the record is in, or will be made in, judged before anything is created
        try:
            inside = approval.in_a_repo(probe, root)
        finally:
            os.close(probe)
        if inside:
            return "%s is inside a git work tree or this repository, where a repository could plant a record" % base
        os.makedirs(base, mode=0o700, exist_ok=True)
        body = json.dumps({"v": RECORD_VERSION, "repo": root, "id": hid, "written_ts": written}, sort_keys=True, separators=(",", ":"))
        private.write(base, HOME_REL, record_name(root), body.encode("utf-8"))
    except (OSError, ValueError) as exc:
        return "cannot write a record under %s/%s: %s" % (base, HOME_REL, exc)
    return None


def look_up(root):
    """(record, "") -- the record `write` kept for `root`, a dict -- or (None, why there is none that is believed). Nothing is made. The directory that is OPENED is judged
    (inside the repository or any git work tree: not read) and the record is read through that descriptor, so the check and the read cannot disagree."""
    base = approval.home()
    if base is None:
        return None, "there is no absolute HEIMDALL_HOME or HOME to look under"
    try:
        store = private.open_dir(base, HOME_REL, False)
    except OSError:
        return None, "no believable record for this repository: there is no store at %s/%s" % (base, HOME_REL)
    try:
        if approval.in_a_repo(store, root):
            return None, "%s is inside a git work tree or this repository, where a repository could plant a record" % base
        rec = approval._record(store, record_name(root))
    finally:
        os.close(store)
    if rec is None:
        return None, "no believable record for this repository in %s/%s (missing, loose permissions, a link, not ours, or not JSON)" % (base, HOME_REL)
    return rec, ""


def git_env():
    """The environment of the git that is asked about the handoff: no GIT_* variable, and English messages (the answer is read from one)."""
    env = dict((key, value) for key, value in os.environ.items() if not key.startswith("GIT_"))
    env["LC_ALL"] = "C"
    return env


def tracked_reason(root):
    """None when git says the handoff is not tracked, else why it is not believed: git tracks it (a repository can ship a tracked file), or git could not say -- not a
    repository, a failure, a timeout, any answer but the one for "unknown to git"."""
    rc, _, err = run(["git", "ls-files", "--error-unmatch", "--", "%s/%s" % (REL, NAME)], root, GIT_BUDGET_S, git_env())
    if rc == 0:
        return "git tracks %s/%s (a repository can ship a tracked file; keep the handoff out of git: .gitignore it and `git rm --cached` it)" % (REL, NAME)
    if rc == 1 and "did not match any file(s) known to git" in err:
        return None
    return "git could not say whether %s/%s is tracked (exit %d: %s)" % (REL, NAME, rc, last_line(err) or "no message")


def unproven(root, hid, written):
    """None when this handoff is believed -- the record in the operator's home names this id and time for this repository, and git does not track the file -- else the
    reason it is not."""
    rec, why = look_up(root)
    if rec is None:
        return why
    if rec.get("v") != RECORD_VERSION or rec.get("repo") != root or rec.get("id") != hid or rec.get("written_ts") != written:
        return "its id and time do not match the record /hmd:continue kept for this repository"
    return tracked_reason(root)


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
    holds = [why for why in (keep_record(root, hid, now), tracked_reason(root)) if why]  # what `inject` will ask: both are checked, so both are reported
    say("[heimdall-continue] handoff written: %s/%s/%s (id %s)" % (root, REL, NAME, hid))
    if problems:
        warn("[heimdall-continue] WARNING - checkpoint not fully saved: %s. The handoff has the note but no resume-contract snapshot; run heimdall-checkpoint write too."
             % "; ".join(problems))
    else:
        say("[heimdall-continue] checkpoint saved, all %d resume fields are in the handoff" % len(LABELS))
    if window == 0:
        warn("[heimdall-continue] HMD_CONTINUE_WINDOW_MIN=0: the handoff will NOT be re-injected after compaction")
    elif holds:
        warn("[heimdall-continue] WARNING - the handoff will NOT be re-injected after compaction: %s. The /compact line below still steers the summary; after the compaction have %s/%s read."
             % ("; ".join(holds), REL, NAME))
    else:
        say("[heimdall-continue] it is re-injected once, after the first compaction within %d min" % window)
    line = focus_line(note)
    say("[heimdall-continue] paste this as your next message (%d of %d chars; only you can run /compact):" % (len(line), LINE_CAP))
    say(line)
    return PARTIAL if problems or (holds and window) else OK


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
    why = unproven(root, hid, written)
    if why is not None:
        warn("[heimdall-continue] %s/%s not injected: %s" % (REL, NAME, why))
        return OK
    parts = ["[heimdall] /hmd:continue handoff (written %s ago), re-injected once because this session was just compacted:" % ago(max(0, now - written)),
             scrub(body).strip("\n")]
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
    inj = sub.add_parser("inject", help="the SessionStart(compact) side: print the hook JSON for a fresh, unconsumed handoff that /hmd:continue wrote here and git does not track")
    inj.add_argument("--repo", default="", help="the project dir (default: $CLAUDE_PROJECT_DIR, else the cwd)")
    inj.add_argument("--source", default="", help="the SessionStart source; default: the \"source\" of the hook payload on stdin")
    args = parser.parse_args(argv)
    try:
        return {"write": cmd_write, "focus": cmd_focus, "inject": cmd_inject}[args.action](args)
    except Fail as exc:
        warn("[heimdall-continue] %s" % exc.message)
        return exc.code


if __name__ == "__main__":
    sys.exit(main())
