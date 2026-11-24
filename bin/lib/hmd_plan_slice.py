#!/usr/bin/env python3
"""hmd_plan_slice.py -- give a spawned agent ONLY its task's section of a plan, and tell one that reaches for the whole file where its slice is.

WHY. Plan files were read whole by the coders spawned from them: 76, 22, 17 and 13 coders for four plans, 12.5% of a measured session's subagent Read
characters (docs/analysis/2026-11-22-token-utilization-next.md lever 6; docs/analysis/2026-11-24-market-token-techniques.md gap 5). A plan is 28-128 KB, a
coder needs one task's few lines (its files and acceptance criteria), and every character it reads rides every later request it makes. bin/heimdall-brief
build --plan inlines the slice where the spawn prompt is built, so the coder has nothing to look up; this is the slicer behind it, and the one reader of
where a task starts and ends (the brief, an agent asking for its own slice and the hint below cannot disagree).

VERBS (stdlib only, run as `python3 -I -S`; bin/heimdall-plan-slice is the launcher)
    slice --plan FILE --task ID [--max-chars N]   the section of task ID, verbatim, under one header line. N defaults to 8000: a longer section is cut at a
                                                  line and the last line says which Read gets the rest. Exit 0; 4 when the file or the id is absent (stderr names
                                                  the ids that exist); 2 usage.
    list  --plan FILE                             one line per task: ID, TAB, first-last line, TAB, title. Exit 4 when the file holds no task.
    hint                                          the PreToolUse hook on Read, the payload on stdin (THE HINT).

TASK SHAPES. One reader for every shape the plans of this repo use (docs/superpowers/plans/*.md, .planning/plans/PLAN-*.md, the architect's and the planner's
templates). A task starts at a line that is, outside a code fence:
    #### Task W0-spike  /  ### Task: issue-ledger  /  ### Task: Login Endpoint (note)
                a heading whose text starts with the word Task. Its id is the first token when that holds a digit, else the kebab slug of the name; the name
                (without a trailing parenthetical) answers too, in any case
    ### T1.2 name
                a heading whose text starts with an id: letters then a digit (T1, W0-spike), or N.M (1.2)
    - **T0.1 name.** ...      or      **T0.1 name** ...
                a top-level bullet, or a paragraph, that opens with a bold id
A bold field line (`- **Files:** ...`) has no digit in its first word and is never a task, and a numbered section heading (`## 1. Inventory`) is no id. A
section runs to the line before the next task or the next heading (a task heading: the next heading of its own level or a higher one; a bullet or bold
paragraph: any heading), minus trailing blank lines. Ids compare in lower case; the first task holding an id answers for it.

THE HINT. A subagent's PreToolUse payload carries agent_id (the main thread's does not: the orchestrator may read a plan whole). A Read of a plan path with no
offset and no limit, of 6000 bytes or more, gets hookSpecificOutput.additionalContext naming the slice and list commands. Plan paths: .planning/**/PLAN*.md,
.planning/plans/*.md, docs/superpowers/plans/*.md. It never denies, never rewrites the Read and keeps no state. FAIL-OPEN: `hint` exits 0 on every path and prints
nothing unless it holds a hint; an unexpected error is one line on stderr and the Read goes through.
"""
import json
import os
import re
import sys

LAUNCHER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "heimdall-plan-slice")
MAX_CHARS = 8000
MIN_HINT_BYTES = 6000
MAX_PLAN_BYTES = 4 * 1024 * 1024
KNOWN_SHOWN = 12

PLAN_PATH = re.compile(r"(?:^|/)(?:\.planning/(?:.+/)?PLAN[^/]*\.md|\.planning/plans/[^/]+\.md|docs/superpowers/plans/[^/]+\.md)$")
FENCE = re.compile(r"^ {0,3}(?:```|~~~)")
HEADING = re.compile(r"^(#{1,6})[ \t]+\S")
TASK_HEADING = re.compile(r"^(#{2,6})[ \t]+Task\b[ \t]*:?[ \t]*(\S.*?)[ \t]*$", re.I)
BULLET = re.compile(r"^[-*+][ \t]+\*\*(?=\S)")
BOLD = re.compile(r"^\*\*(?=\S)")
ID = re.compile(r"(?:[A-Za-z]{1,3}\d|\d+\.\d)[\w.\-]*")


def norm(text):
    return re.sub(r"\s+", " ", text).strip().lower()


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def idtok(text):
    """The id a line opens with ('' when it opens with none): up to the first space or *, minus trailing punctuation, and shaped like an id."""
    m = re.match(r"[^\s*]+", text)
    tok = m.group(0).rstrip(".:,;)") if m else ""
    return tok if ID.fullmatch(tok) else ""


def named_task(index, level, rest):
    base = re.sub(r"\s*\([^)]*\)\s*$", "", rest)
    base = re.split(r"\s+[-–—:]\s+", base, maxsplit=1)[0].strip()
    tok = idtok(rest)
    ids = [x for x in (norm(tok), norm(rest), norm(base), slug(base)) if x]
    return {"i": index, "level": level, "id": tok or slug(base) or norm(rest), "ids": ids, "title": rest}


def parse(lines):
    """Every task of the plan, in order: {i: first line (0-based), end: one past its last line, id, ids: what answers to it, title}."""
    starts, heads, infence = [], {}, False
    for i, line in enumerate(lines):
        if FENCE.match(line):
            infence = not infence
            continue
        if infence:
            continue
        h = HEADING.match(line)
        if h:
            level = len(h.group(1))
            heads[i] = level
            t = TASK_HEADING.match(line)
            if t:
                starts.append(named_task(i, level, t.group(2)))
                continue
            text = line[level:].strip()
            tok = idtok(text)
            if tok:
                starts.append({"i": i, "level": level, "id": tok, "ids": [norm(tok)], "title": text[len(tok):].strip(" .:-*")})
            continue
        m = BULLET.match(line) or BOLD.match(line)
        if m:
            text = line[m.end():]
            tok = idtok(text)
            if tok:
                title = re.split(r"\*\*", text[len(tok):], maxsplit=1)[0].strip(" .:-")
                starts.append({"i": i, "level": 0, "id": tok, "ids": [norm(tok)], "title": title})
    first_lines = set(s["i"] for s in starts)
    for s in starts:
        stop = len(lines)
        for j in range(s["i"] + 1, len(lines)):
            if j in first_lines or (j in heads and (s["level"] == 0 or heads[j] <= s["level"])):
                stop = j
                break
        while stop > s["i"] + 1 and not lines[stop - 1].strip():
            stop -= 1
        s["end"] = stop
    return starts


def find(starts, want):
    w, sg = norm(want), slug(want)
    for s in starts:
        if w in s["ids"] or (sg and sg in s["ids"]):
            return s
    return None


def load(path):
    """(lines, None) or (None, one-line reason)."""
    try:
        if not os.path.isfile(path):
            return None, "not a file"
        if os.path.getsize(path) > MAX_PLAN_BYTES:
            return None, "larger than %d bytes" % MAX_PLAN_BYTES
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines(), None
    except OSError as e:
        return None, e.strerror or "unreadable"


def die(message):
    sys.stderr.write("heimdall-plan-slice: %s\n" % message)
    return 4


def cmd_slice(plan, task, cap):
    lines, err = load(plan)
    if err:
        return die("cannot read plan %s: %s" % (plan, err))
    starts = parse(lines)
    s = find(starts, task)
    if s is None:
        ids = [x["id"] for x in starts]
        known = ", ".join(ids[:KNOWN_SHOWN]) + (" (+%d more)" % (len(ids) - KNOWN_SHOWN) if len(ids) > KNOWN_SHOWN else "")
        return die("no task '%s' in %s (known: %s)" % (task, plan, known or "none recognised"))
    a, b = s["i"] + 1, s["end"]
    body = "\n".join(lines[a - 1:b])
    note = ""
    if len(body) > cap:
        cut = body[:cap]
        nl = cut.rfind("\n")
        first = a
        if nl > 0:
            cut = cut[:nl]
            first = a + cut.count("\n") + 1
        note = "\n[hmd: slice cut at %d of %d chars; Read %s offset=%d limit=%d for the rest]" % (len(cut), len(body), plan, first, b - first + 1)
        body = cut
    print("PLAN SLICE (task %s, %s lines %d-%d of %d; the rest of the plan is not yours, do not Read it whole):" % (s["id"], plan, a, b, len(lines)))
    print(body + note)
    return 0


def cmd_list(plan):
    lines, err = load(plan)
    if err:
        return die("cannot read plan %s: %s" % (plan, err))
    starts = parse(lines)
    if not starts:
        return die("no task recognised in %s" % plan)
    for s in starts:
        print("%s\t%d-%d\t%s" % (s["id"], s["i"] + 1, s["end"], s["title"][:70]))
    return 0


def hint(raw):
    """The hook JSON for a subagent's unsliced Read of a plan, else None."""
    try:
        p = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(p, dict) or p.get("tool_name") != "Read" or not p.get("agent_id"):
        return None
    ti = p.get("tool_input")
    if not isinstance(ti, dict) or "offset" in ti or "limit" in ti:
        return None
    path = ti.get("file_path")
    if not isinstance(path, str) or not PLAN_PATH.search(path.replace("\\", "/")):
        return None
    try:
        size = os.stat(path).st_size
    except OSError:
        return None
    if size < MIN_HINT_BYTES:
        return None
    msg = ("[hmd plan-slice] %s is a whole plan (%d KB) and a task needs only its own section: %s slice --plan %s --task <your task id> prints it "
           "(task ids and line ranges: %s list --plan %s), or Read with offset and limit. A PLAN SLICE in your spawn brief is already your section."
           % (os.path.basename(path), (size + 1023) // 1024, LAUNCHER, path, LAUNCHER, path))
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=True)


def usage():
    sys.stderr.write("usage: heimdall-plan-slice slice --plan FILE --task ID [--max-chars N] | list --plan FILE | hint\n")
    return 2


def main(argv):
    if not argv:
        return usage()
    verb, rest = argv[0], argv[1:]
    if verb == "hint":
        try:
            out = hint(sys.stdin.read())
            if out:
                sys.stdout.write(out + "\n")
        except Exception as e:  # a hook never breaks a session: one line on stderr, and the Read goes through
            sys.stderr.write("heimdall-plan-slice: hint failed (%s: %s)\n" % (type(e).__name__, e))
        return 0
    if verb not in ("slice", "list"):
        return usage()
    opts = {"--plan": None, "--task": None, "--max-chars": str(MAX_CHARS)}
    i = 0
    while i < len(rest):
        if rest[i] not in opts or i + 1 >= len(rest):
            return usage()
        opts[rest[i]] = rest[i + 1]
        i += 2
    try:
        cap = int(opts["--max-chars"])
    except ValueError:
        cap = 0
    if not opts["--plan"] or cap < 1 or (verb == "slice" and not opts["--task"]):
        return usage()
    return cmd_slice(opts["--plan"], opts["--task"], cap) if verb == "slice" else cmd_list(opts["--plan"])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
