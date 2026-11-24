#!/usr/bin/env python3
"""hmd_read_dedup.py -- keep a Read from putting the same text in an agent's context twice, or a big file in whole for no reason.

Two behaviours of ONE PostToolUse hook of a Read (verb `post-read`, the payload on stdin): the STUB for a re-read, and the OUTLINE for a
big file a subagent reads whole. Both replace the tool's output through hookSpecificOutput.updatedToolOutput before the model sees it; the
transcript keeps the replacement, so the prompt-cache prefix is never edited afterwards.

WHY. 24.3% of the tool-result characters of a measured session's subagents were Reads of a file the same agent had read with the same
offset and limit, unchanged since (docs/analysis/2026-11-24-market-token-techniques.md, section 2 and gap 1); Cline and Roo drop such a
copy. Gap 3 of that document: 20.6M of the 32.7M Read characters were unsliced reads, and an agent rarely needs a whole big file.

PROBED 2026-11-24 on Claude Code 2.1.331 (claude -p, a throwaway hook, one Agent-spawned subagent that Reads one file twice): the
replacement DOES reach a subagent's Read. That payload carries agent_id and agent_type, the PARENT's session_id and the MAIN
transcript_path. So the state key is (session_id, agent_id); the main thread, which has no agent_id, is (session_id, "_main").

THE STUB. The response is hashed (sha256 of the text the model was given) under a key made of the path, offset and limit asked for. The
read is stubbed when ALL of these hold, else it is recorded and the original output goes through (no output, exit 0):
  * this agent's last full read of that exact key has the same content hash: a changed file, A then B then A, and any other offset or
    limit are all "full";
  * that read has not already been answered with a stub. A model that asks again after being told the content is in its context cannot
    find it (a compaction nothing here saw, say): it gets the real text, which is then recorded afresh. A stub is never repeated in a row;
  * nothing shows that the earlier read left the agent's context. The existing PreCompact hook (bin/heimdall-precompact-checkpoint) calls
    `clear --session` first thing, which forgets every agent of the session. That hook can be switched off, so the check does not depend
    on it: each record keeps the size of the main transcript (and, for a subagent, of its own transcript, which sits at
    <transcript_path minus .jsonl>/subagents/agent-<agent_id>.jsonl) and the bytes written since are searched for ANY of these signs:
      - a compaction or a clearing: a system entry whose subtype contains "compact" in any case, the entry that carries a compaction
        summary ("isCompactSummary":true), a compactMetadata or microcompactMetadata key, a tool result swapped for Claude Code's
        clearing placeholder ("[Old tool result content cleared]"), an API context edit that cleared tool uses ("clear_tool_uses_<date>",
        "cleared_tool_uses" above 0). Where the words come from (2026-11-24): the 2.1.331 binary names the subtypes compact_boundary and
        microcompact_boundary, isCompactSummary, the placeholder and clear_tool_uses_20250919; the 8.4 GB of local transcripts hold
        compact_boundary 91 times, with isCompactSummary and compactMetadata 91 times each, and none of the others, which are matched on
        the binary's word. Only a JSON key or a whole value matches: a message that quotes a marker in its text is escaped and does not;
      - a rewind or a branch: the entry that carries the earlier read's tool call (its tool_use id is kept as a hash) is not an ancestor of
        the newest entry of the transcript that holds the agent's chain (the main one for the main thread, the agent's own for a
        subagent), following parentUuid. A fork is NOT the sign: every transcript is full of them (a result and an attachment, or the
        next parallel call, hang off one assistant entry: 1,284 forks in a 22,871-entry transcript, 1,281 of that shape), so what is tested
        is reachability from the newest entry;
      - more than 8 MiB written since, a file that shrank, a main transcript that cannot be read, a read recorded with no call id, a call
        that is nowhere in the transcript. Not being able to tell is "do not stub";
  * only a text result is stubbed (an image, a PDF, a notebook or a native "unchanged" result is left alone), and only when the stub is
    shorter than what it replaces.
The stub names itself and how to get the text back, and keeps the shape of the Read result (only content, numLines and startLine change):
    unchanged since your earlier read of <path> (lines a-b); content is already in your context [hmd read-dedup stub: ...]

THE OUTLINE. An unsliced Read (no offset, no limit) of a python or shell file of more than OUTLINE_MIN_LINES lines by a SUBAGENT is answered
with its first OUTLINE_HEAD_LINES lines, a note and the file's outline (first line-last line, kind, name; at most OUTLINE_MAX_SYMBOLS):
    <the first 100 lines>
    [hmd read-outline: <path> has N lines; this Read shows lines 1-100 and an outline of the file, not the whole file. Read again with
    offset/limit, or Read with limit 100000 for the whole file]
    outline (lines kind name):
    12-40 function parse_args
The outline is what `bin/heimdall-graph outline` serves: the extractors of bin/lib/symbolgraph.py (python: ast; shell: its state machine),
run on the one file in the payload instead of an index of the repository, which a hook with a 10 s budget cannot afford, and with no cache
written. Nothing else is parsed: javascript needs tree-sitter, which a `python -S` hook cannot import, and the graph indexes no other
language. Never a trap, never a guess:
  * the second unsliced Read of that file by the same agent gets the whole file, and so does the first one of an agent that read it whole
    before: a mark under a hash of the path, and the dedup record of the whole read, say so. The outlined read is not recorded as a read of
    the content, so the whole file that follows is the one the stub rule remembers;
  * not the main thread (4 Reads in 72 days there), not a slice, not a Read cut short (fewer lines returned than the file has: the outline
    would miss the end), not a test file or a path under test/, tests/, __tests__/, evals/ or fixtures/ (a straight-line script has no
    outline worth reading), not a file with under OUTLINE_MIN_SYMBOLS symbols, not a result that would be no shorter, not a language the
    graph does not parse, not a file its parser cannot read; any error leaves the original output;
  * HMD_READ_OUTLINE=off (also 0, false, no) turns the outline off and keeps the stub; HMD_READ_DEDUP=off, checked by the launcher, turns
    the whole hook off.
THRESHOLD, measured on the data of the analysis (171 subagent files of session 0e12831c: 1,853 Reads, 875 unsliced, 11.9M of 18.7M
characters). Over 400 lines the unsliced reads are 16.1% of them and 38.4% of their characters; over 500 lines 11.0% and 29.2%; over 600
lines 4.0% and 12.2%. A head and outline cost about 7.5K characters, so a file must be about three times that, 500 lines of 45 characters,
for a first read that suffices to save two thirds while a read that has to go on costs a third more: over 500 lines the outline stands in
for 29.2% of the unsliced characters, 14.7% of all Read characters, before any re-read.

STATE. $HEIMDALL_HOME/read-dedup/<session>.<agent or _main>.json: {"v":1,"e":{<sha256 of path/offset/limit, 32 hex>: {"h": <content hash,
32 hex>, "n": <1 once a stub was issued for it>, "o": [transcript sizes at the read], "t": <hash of the tool_use id, or null>},
<sha256 of "outline" and the path, 32 hex>: {"w": 1}}}, the last form meaning "the outline of that file was served". HASHES ONLY: no content
and no path is ever stored. Every read and write goes through bin/lib/hmd_private_state.py (0700 directory, 0600 files, no link followed,
one flock around every change). Bounded: HMD_READ_DEDUP_MAX_ENTRIES entries per agent (default 256, newest kept), and a state file untouched
for 24 hours is removed by the next agent that starts recording. A file nobody can trust (wrong owner or mode, a link, damaged, over
256 KiB) counts as no state.

FAIL-OPEN. `post-read` exits 0 on every path and prints nothing unless it holds a stub or an outline: an unexpected error is one line on
stderr and the original output stands. `clear` is the one verb with exit codes (0 done, 1 the state could not be changed, 2 usage).

    heimdall-read-dedup post-read              hook verb (PostToolUse, matcher Read), the payload on stdin
    heimdall-read-dedup clear --session ID     forget every agent's reads of that session (run by the PreCompact hook)
"""
import contextlib
import hashlib
import json
import os
import re
import stat
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_private_state as ps  # noqa: E402  (the 0700/0600, link-free state every per-user record of hmd uses)

REL = "read-dedup"
LOCK = ".lock"
MAIN = "_main"

MAX_PAYLOAD = 32 << 20     # bytes read from a hook's stdin
MAX_STATE = 256 << 10      # a state file past this is not trusted (ps.read) and is rewritten from nothing
MAX_SCAN = 8 << 20         # transcript bytes read to look for a sign of compaction; more growth than this means "do not stub"
CHAIN_BACK = 1 << 20       # transcript bytes read BEFORE a read's mark: the entry that carries its tool call may sit just before it
MAX_LINE = 2 << 20         # a transcript line longer than this is not parsed
DEFAULT_MAX_ENTRIES = 256  # reads remembered per agent: the newest
STATE_TTL_S = 24 * 3600    # a state file untouched this long is removed by the next agent that starts recording
PRUNE_AT_MOST = 200        # files removed per call, so a huge directory never stalls one hook
MAX_SHOWN_PATH = 400       # characters of the path the stub repeats

OUTLINE_MIN_LINES = 500    # a file of more lines than this is outlined (measured: see THRESHOLD)
OUTLINE_HEAD_LINES = 100
OUTLINE_MAX_SYMBOLS = 80
OUTLINE_MIN_SYMBOLS = 3    # fewer symbols is nothing to navigate by
OUTLINE_SKIP_DIRS = frozenset(("test", "tests", "__tests__", "evals", "fixtures"))

SESSION_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
AGENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}")
CALL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")
# Any sign that a read may have left the agent's context. A key or a whole value, never a word inside a text: JSON escapes the quotes of
# a message that quotes a marker, so it does not match.
SIGN_RE = re.compile(
    rb'"subtype"\s*:\s*"[^"]*compact[^"]*"'                       # compact_boundary, microcompact_boundary, any later *compact* subtype
    rb'|"isCompactSummary"\s*:\s*true'                            # the entry that carries a compaction summary
    rb'|"(?:micro)?compactMetadata"\s*:'                          # the metadata every boundary carries
    rb'|"content"\s*:\s*"\[Old tool result content cleared\]"'    # a tool result swapped for Claude Code's clearing placeholder
    rb'|"type"\s*:\s*"clear_tool_uses_\d+"'                       # an API context edit that clears tool uses
    rb'|"cleared_tool_uses"\s*:\s*[1-9]',                         # ... and its report that it did
    re.IGNORECASE)
CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f  ]+")

STUB = ("unchanged since your earlier read of %s (lines %d-%d); content is already in your context "
        "[hmd read-dedup stub: Read the same range again to get the full text]")
OUTLINE_NOTE = ("[hmd read-outline: %s has %d lines; this Read shows lines 1-%d and an outline of the file, not the whole file. "
                "Read again with offset/limit, or Read with limit 100000 for the whole file]")


def state_root():
    home = os.environ.get("HEIMDALL_HOME")
    if home:
        return home
    return os.path.join(os.environ.get("HOME") or "/tmp", ".heimdall")


def max_entries():
    try:
        count = int(os.environ.get("HMD_READ_DEDUP_MAX_ENTRIES", ""))
    except ValueError:
        return DEFAULT_MAX_ENTRIES
    return min(count, 4096) if count >= 1 else DEFAULT_MAX_ENTRIES


def switched_off(variable):
    return os.environ.get(variable, "").strip().lower() in ("off", "0", "false", "no")


def plain(value, pattern):
    return value if isinstance(value, str) and pattern.fullmatch(value) else None


def digest(text):
    return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()[:32]


def request_key(path, offset, limit):
    return digest("\0".join((path, "" if offset is None else repr(offset), "" if limit is None else repr(limit))))


def state_name(session, agent):
    return "%s.%s.json" % (session, agent)


# -- transcripts: did the earlier read leave context? --------------------------------------------------------------------------------

def transcript_paths(payload, agent):
    """The files whose growth can carry a compaction of this agent's context: the main transcript and, for a subagent, its own.
    The LAST one holds the agent's own chain of entries."""
    main = payload.get("transcript_path")
    if not isinstance(main, str) or not main.endswith(".jsonl"):
        return None
    paths = [main]
    if agent != MAIN:
        paths.append(os.path.join(main[:-len(".jsonl")], "subagents", "agent-%s.jsonl" % agent))
    return paths


def open_regular(path):
    """A read-only descriptor of the regular file at path, never through a link; None when it is missing or anything else."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        regular = stat.S_ISREG(os.fstat(fd).st_mode)
    except OSError:
        regular = False
    if not regular:
        os.close(fd)
        return None
    return fd


def sizes_now(paths):
    """The size of each transcript, or None when the main one cannot be read. A subagent's own file that does not exist yet counts 0."""
    sizes = []
    for index, path in enumerate(paths):
        fd = open_regular(path)
        if fd is None:
            if index == 0:
                return None
            sizes.append(0)
            continue
        try:
            sizes.append(os.fstat(fd).st_size)
        finally:
            os.close(fd)
    return sizes


def read_from(fd, start, want):
    os.lseek(fd, start, os.SEEK_SET)
    chunks = []
    while want > 0:
        chunk = os.read(fd, want)
        if not chunk:
            break
        chunks.append(chunk)
        want -= len(chunk)
    return b"".join(chunks)


def compaction_possible(paths, then):
    """True when the transcripts hold a sign of a compaction or a clearing written after `then` (their sizes at the read), or when that
    cannot be told."""
    if not isinstance(then, list) or len(then) != len(paths) or any(type(n) is not int or n < 0 for n in then):
        return True
    for index, (path, start) in enumerate(zip(paths, then)):
        fd = open_regular(path)
        if fd is None:
            if index > 0 and start == 0 and not os.path.lexists(path):
                continue  # a subagent's own transcript that was never written: nothing in it
            return True
        try:
            size = os.fstat(fd).st_size
            if size < start or size - start > MAX_SCAN:
                return True
            if SIGN_RE.search(read_from(fd, start, size - start)):
                return True
        except OSError:
            return True
        finally:
            os.close(fd)
    return False


def carries_call(entry, call):
    """True when this transcript entry holds a tool_use block whose id hashes to `call`."""
    message = entry.get("message")
    blocks = message.get("content") if isinstance(message, dict) else None
    if not isinstance(blocks, list):
        return False
    return any(isinstance(block, dict) and block.get("type") == "tool_use" and isinstance(block.get("id"), str)
               and digest(block["id"]) == call for block in blocks)


def on_chain(path, start, call):
    """True only when the entry that carries the earlier read's tool call (`call`, a hash) is an ancestor of the newest entry of the
    transcript at `path`, following parentUuid: the read was not rewound away and no branch left it behind. `start` is the size of the
    file at that read. Anything this cannot see for sure is False."""
    if type(start) is not int or start < 0 or not isinstance(call, str):
        return False
    fd = open_regular(path)
    if fd is None:
        return False
    try:
        size = os.fstat(fd).st_size
        begin = max(0, start - CHAIN_BACK)
        if size < start or size - begin > MAX_SCAN + CHAIN_BACK:
            return False
        data = read_from(fd, begin, size - begin)
    except OSError:
        return False
    finally:
        os.close(fd)
    lines = data.split(b"\n")
    if begin:
        lines = lines[1:]  # cut at `begin`, so not a whole entry
    parent, anchor, newest = {}, None, None
    for raw in lines:
        if not raw or len(raw) > MAX_LINE:
            continue
        try:
            entry = json.loads(raw)
        except (ValueError, RecursionError):
            continue  # a line still being written
        uid = entry.get("uuid") if isinstance(entry, dict) else None
        if not isinstance(uid, str):
            continue
        above = entry.get("parentUuid")
        parent[uid] = above if isinstance(above, str) else None
        newest = uid
        if anchor is None and carries_call(entry, call):
            anchor = uid
    node = newest
    for _ in range(len(parent)):
        if node is None:
            return False
        if node == anchor:
            return True
        node = parent.get(node)
    return False


# -- state ---------------------------------------------------------------------------------------------------------------------------

def load_entries(root, name):
    raw = ps.read(root, REL, name, limit=MAX_STATE)
    if raw is None:
        return {}
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError):
        return {}
    entries = obj.get("e") if isinstance(obj, dict) else None
    if not isinstance(entries, dict):
        return {}
    return {key: value for key, value in entries.items() if isinstance(value, dict)}


def save_entries(root, name, entries):
    limit = max_entries()
    while len(entries) > limit:
        del entries[next(iter(entries))]
    ps.write(root, REL, name, json.dumps({"v": 1, "e": entries}, separators=(",", ":")).encode("ascii"))


def commit(root, name, entries, first_of_agent):
    """Save the entries; the first write of an agent also removes the state files nobody has touched for a day."""
    save_entries(root, name, entries)
    if first_of_agent:
        prune_old(root, name)


def prune_old(root, keep):
    """Remove state files untouched for STATE_TTL_S, never `keep`: a session that went quiet is a first reader again, which is safe."""
    try:
        dirfd = ps.open_dir(root, REL, False)
    except OSError:
        return
    try:
        cutoff = time.time() - STATE_TTL_S
        removed = 0
        with os.scandir(dirfd) as listing:
            for entry in listing:
                if entry.name == keep or not entry.name.endswith(".json"):
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                    with contextlib.suppress(OSError):
                        os.unlink(entry.name, dir_fd=dirfd)
                        removed += 1
                    if removed >= PRUNE_AT_MOST:
                        break
    finally:
        os.close(dirfd)


# -- the outline ---------------------------------------------------------------------------------------------------------------------

def skipped_path(path):
    """A test file or a path under a test, fixture or eval directory: a straight-line script has no outline worth reading."""
    parts = [part.lower() for part in re.split(r"[\\/]+", path) if part]
    if not parts:
        return True
    name = parts[-1]
    return (bool(OUTLINE_SKIP_DIRS.intersection(parts[:-1])) or ".test." in name or name.startswith("test_")
            or name.endswith("_test.py"))


def outline_rows(path, content):
    """[(first line, last line, kind, name)] of the symbols the symbol graph finds in `content`, in file order, closures left out; None
    when the graph does not parse this kind of file."""
    import symbolgraph as sg  # the engine behind bin/heimdall-graph (stdlib only), imported here: only a big file needs it
    if len(content) > sg.MAX_FILE_BYTES:
        return None
    ext = os.path.splitext(path)[1].lower()
    lang = sg.EXT_LANG.get(ext)
    if lang is None and not ext:  # an extensionless executable is read by its shebang, as the graph reads it
        first = content.split("\n", 1)[0].lower() if content.startswith("#!") else ""
        lang = next((name for token, name in sg.SHEBANG_LANG if token in first), None)
    if lang == "python":
        found, _edges = sg._py_extract(path, content)
    elif lang == "shell":
        code, _scan = sg._shell_texts(content.splitlines())
        found = sg._sh_defs(code)
    else:
        return None  # javascript needs tree-sitter, which a `python -S` hook cannot import; the graph indexes nothing else
    rows, open_spans = [], []
    for name, kind, first, last in sorted(found, key=lambda symbol: (symbol[2], -symbol[3])):
        while open_spans and open_spans[-1][1] < first:
            open_spans.pop()
        if open_spans and open_spans[-1][2] != "class":
            continue  # a def inside a def: a closure, not something to navigate by
        rows.append((first, last, kind, name))
        open_spans.append((first, last, kind))
    return rows


def outline_text(path, content, total, rows):
    shown = CONTROL_RE.sub(" ", path).strip()[:MAX_SHOWN_PATH]
    lines = ["\n".join(content.split("\n")[:OUTLINE_HEAD_LINES]), OUTLINE_NOTE % (shown, total, OUTLINE_HEAD_LINES),
             "outline (lines kind name):"]
    for first, last, kind, name in rows[:OUTLINE_MAX_SYMBOLS]:
        lines.append("%d-%d %s %s" % (first, last, kind, CONTROL_RE.sub(" ", name)))
    if len(rows) > OUTLINE_MAX_SYMBOLS:
        lines.append("+%d more symbols (Read a range to see them)" % (len(rows) - OUTLINE_MAX_SYMBOLS))
    return "\n".join(lines)


def outline_decide(read):
    """The hook output for an unsliced Read of a big source file by a subagent: its head and outline. None lets the Read stand."""
    body, path, content = read["body"], read["path"], read["content"]
    total, count = body.get("totalLines"), body.get("numLines")
    if (not read["subagent"] or read["offset"] is not None or read["limit"] is not None or type(total) is not int
            or type(count) is not int or total <= OUTLINE_MIN_LINES or count < total or skipped_path(path)):
        return None
    try:
        rows = outline_rows(path, content)
    except Exception as exc:  # a file the parser chokes on is read whole, and the read is still recorded for dedup
        sys.stderr.write("heimdall-read-dedup: outline: %s: %s\n" % (type(exc).__name__, exc))
        return None
    if rows is None or len(rows) < OUTLINE_MIN_SYMBOLS:
        return None
    text = outline_text(path, content, total, rows)
    if len(text) >= len(content):
        return None
    key, mark = request_key(path, None, None), digest("outline\0" + path)
    root, name = state_root(), state_name(read["session"], read["agent"])
    os.makedirs(root, 0o700, exist_ok=True)
    first_of_agent = ps.stat_file(root, REL, name) is None
    with ps.lock(root, REL, LOCK):
        entries = load_entries(root, name)
        if key in entries or mark in entries:
            return None  # this agent read the file whole before, or was shown its outline: the whole file is what it gets now
        entries[mark] = {"w": 1}
        commit(root, name, entries, first_of_agent)
    return rewritten(read["response"], text)


# -- the hook ------------------------------------------------------------------------------------------------------------------------

def read_payload():
    try:
        raw = sys.stdin.buffer.read(MAX_PAYLOAD)
        obj = json.loads(raw.decode("utf-8", "replace"))
    except (OSError, ValueError, RecursionError):
        return {}
    return obj if isinstance(obj, dict) else {}


def stub_text(path, body, content):
    start = body.get("startLine")
    if type(start) is not int or start < 1:
        start = 1
    count = body.get("numLines")
    if type(count) is not int or count < 1:
        count = content.count("\n") + 1
    shown = CONTROL_RE.sub(" ", path).strip()[:MAX_SHOWN_PATH]
    return STUB % (shown, start, start + count - 1)


def rewritten(response, text):
    """The Read result with `text` as its content, in the shape of the original: only content, numLines and startLine change."""
    shaped = json.loads(json.dumps(response))
    shaped["file"]["content"] = text
    shaped["file"]["numLines"] = text.count("\n") + 1
    shaped["file"]["startLine"] = 1
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": shaped}}


def parse_read(payload):
    """The fields of a Read's PostToolUse payload this hook reasons about, or None when it is not a text Read it can."""
    if payload.get("tool_name") != "Read":
        return None
    session = plain(payload.get("session_id"), SESSION_RE)
    raw_agent = payload.get("agent_id")
    agent = MAIN if raw_agent is None else plain(raw_agent, AGENT_RE)
    tool_input, response = payload.get("tool_input"), payload.get("tool_response")
    if session is None or agent is None or not isinstance(tool_input, dict):
        return None
    if not isinstance(response, dict) or response.get("type") != "text" or not isinstance(response.get("file"), dict):
        return None
    body, path = response["file"], tool_input.get("file_path")
    content = body.get("content")
    if not isinstance(path, str) or not path or not isinstance(content, str):
        return None
    return {"session": session, "agent": agent, "subagent": raw_agent is not None, "path": path,
            "offset": tool_input.get("offset"), "limit": tool_input.get("limit"), "response": response, "body": body,
            "content": content, "call": plain(payload.get("tool_use_id"), CALL_RE)}


def dedup_decide(read, payload):
    """The stub for a re-read of what this agent still holds, or None. Records the read either way."""
    paths = transcript_paths(payload, read["agent"])
    marks = sizes_now(paths) if paths else None
    if marks is None:
        return None
    path, content = read["path"], read["content"]
    key, fingerprint = request_key(path, read["offset"], read["limit"]), digest(content)
    call = digest(read["call"]) if read["call"] else None
    stub = stub_text(path, read["body"], content)
    root, name = state_root(), state_name(read["session"], read["agent"])
    os.makedirs(root, 0o700, exist_ok=True)
    first_of_agent = ps.stat_file(root, REL, name) is None
    with ps.lock(root, REL, LOCK):
        entries = load_entries(root, name)
        prior = entries.get(key)
        if (prior is not None and prior.get("h") == fingerprint and prior.get("n") == 0 and len(stub) < len(content)
                and not compaction_possible(paths, prior.get("o")) and on_chain(paths[-1], prior["o"][-1], prior.get("t"))):
            prior["n"] = 1
            save_entries(root, name, entries)
            return rewritten(read["response"], stub)
        entries.pop(key, None)
        entries[key] = {"h": fingerprint, "n": 0, "o": marks, "t": call}
        commit(root, name, entries, first_of_agent)
    return None


def decide(payload):
    """The hook output for this Read: an outline, a stub, or None to let the original output stand."""
    read = parse_read(payload)
    if read is None:
        return None
    if not switched_off("HMD_READ_OUTLINE"):
        out = outline_decide(read)
        if out is not None:
            return out
    return dedup_decide(read, payload)


def hook_post_read():
    out = decide(read_payload())
    if out is not None:
        sys.stdout.write(json.dumps(out) + "\n")


# -- clear ---------------------------------------------------------------------------------------------------------------------------

def cmd_clear(args):
    if len(args) != 2 or args[0] != "--session" or plain(args[1], SESSION_RE) is None:
        sys.stderr.write("usage: heimdall-read-dedup clear --session ID\n")
        return 2
    prefix, root = args[1] + ".", state_root()
    if not ps.names(root, REL):
        return 0
    try:
        with ps.lock(root, REL, LOCK):
            for name in ps.names(root, REL):
                if name.startswith(prefix) and name.endswith(".json"):
                    ps.remove(root, REL, name)
    except OSError as exc:
        sys.stderr.write("heimdall-read-dedup: %s\n" % exc)
        return 1
    return 0


def main(argv):
    verb = argv[0] if argv else ""
    if verb == "post-read":
        try:
            hook_post_read()
        except Exception as exc:  # a hook never breaks a read: the original output stands
            sys.stderr.write("heimdall-read-dedup: %s: %s\n" % (type(exc).__name__, exc))
        return 0
    if verb == "clear":
        return cmd_clear(argv[1:])
    sys.stderr.write("usage: heimdall-read-dedup post-read | clear --session ID\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
