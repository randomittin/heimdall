#!/usr/bin/env python3
"""hmd_read_dedup.py -- replace a Read that returns what the same agent already holds in context with a one-line stub.

WHY. 24.3% of the tool-result characters of a measured session's subagents were Reads of a file the same agent had read with the same
offset and limit, unchanged since (docs/analysis/2026-11-24-market-token-techniques.md, section 2 and gap 1); Cline and Roo drop such a
copy. A PostToolUse hook may replace a built-in tool's output before the model sees it (hookSpecificOutput.updatedToolOutput); the
transcript keeps the replacement, so the prompt-cache prefix is never edited afterwards.

PROBED 2026-11-24 on Claude Code 2.1.331 (claude -p, a throwaway hook, one Agent-spawned subagent that Reads one file twice): the
replacement DOES reach a subagent's Read. That payload carries agent_id and agent_type, the PARENT's session_id and the MAIN
transcript_path. So the state key is (session_id, agent_id); the main thread, which has no agent_id, is (session_id, "_main").

THE RULE. On the PostToolUse hook of a Read (verb `post-read`, the payload on stdin) the response is hashed (sha256 of the text the model
was given) under a key made of the path, offset and limit asked for. The read is stubbed when ALL of these hold, else it is recorded and
the original output goes through (no output, exit 0):
  * this agent's last full read of that exact key has the same content hash: a changed file, A then B then A, and any other offset or
    limit are all "full";
  * that read has not already been answered with a stub. A model that asks again after being told the content is in its context cannot
    find it (a compaction nothing here saw, say): it gets the real text, which is then recorded afresh. A stub is never repeated in a row;
  * no compaction can have removed that read from context. The existing PreCompact hook (bin/heimdall-precompact-checkpoint) calls
    `clear --session` first thing, which forgets every agent of the session. That hook can be switched off, so the check does not
    depend on it: each record keeps the size of the main transcript (and, for a subagent, of its own transcript, which sits at
    <transcript_path minus .jsonl>/subagents/agent-<agent_id>.jsonl) and a stub is refused when the bytes written since hold
    "subtype":"compact_boundary" (what Claude Code appends at a compaction), when more than 8 MiB were written since, when a file
    shrank, or when the main transcript cannot be read at all. Not being able to tell is "do not stub";
  * only a text result is stubbed (an image, a PDF, a notebook or a native "unchanged" result is left alone), and only when the stub is
    shorter than what it replaces.
The stub names itself and how to get the text back, and keeps the shape of the Read result (only content, numLines and startLine change):
    unchanged since your earlier read of <path> (lines a-b); content is already in your context [hmd read-dedup stub: ...]

STATE. $HEIMDALL_HOME/read-dedup/<session>.<agent or _main>.json: {"v":1,"e":{<sha256 of path/offset/limit, 32 hex>: {"h": <content hash,
32 hex>, "n": <1 once a stub was issued for it>, "o": [transcript sizes at the read]}}}. HASHES ONLY: no content and no path is ever
stored. Every read and write goes through bin/lib/hmd_private_state.py (0700 directory, 0600 files, no link followed, one flock around
every change). Bounded: HMD_READ_DEDUP_MAX_ENTRIES entries per agent (default 256, newest kept), and a state file untouched for 24 hours is
removed by the next agent that starts recording. A file nobody can trust (wrong owner or mode, a link, damaged, over 256 KiB) counts as
no state.

FAIL-OPEN. `post-read` exits 0 on every path and prints nothing unless it holds a stub: an unexpected error is one line on stderr and the
original output stands. `clear` is the one verb with exit codes (0 done, 1 the state could not be changed, 2 usage).

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
MAX_SCAN = 8 << 20         # transcript bytes read to look for a compaction; more growth than this means "do not stub"
DEFAULT_MAX_ENTRIES = 256  # reads remembered per agent: the newest
STATE_TTL_S = 24 * 3600    # a state file untouched this long is removed by the next agent that starts recording
PRUNE_AT_MOST = 200        # files removed per call, so a huge directory never stalls one hook
MAX_SHOWN_PATH = 400       # characters of the path the stub repeats

SESSION_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
AGENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}")
BOUNDARY_RE = re.compile(rb'"subtype"\s*:\s*"compact_boundary"')
CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f  ]+")

STUB = ("unchanged since your earlier read of %s (lines %d-%d); content is already in your context "
        "[hmd read-dedup stub: Read the same range again to get the full text]")


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


def plain(value, pattern):
    return value if isinstance(value, str) and pattern.fullmatch(value) else None


def digest(text):
    return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()[:32]


def request_key(path, offset, limit):
    return digest("\0".join((path, "" if offset is None else repr(offset), "" if limit is None else repr(limit))))


def state_name(session, agent):
    return "%s.%s.json" % (session, agent)


# -- transcripts: has a compaction happened since the read? --------------------------------------------------------------------------

def transcript_paths(payload, agent):
    """The files whose growth can carry a compaction of this agent's context: the main transcript and, for a subagent, its own."""
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
    """True when the transcripts hold a compaction written after `then` (their sizes at the read), or when that cannot be told."""
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
            if BOUNDARY_RE.search(read_from(fd, start, size - start)):
                return True
        except OSError:
            return True
        finally:
            os.close(fd)
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


def stubbed_result(response, stub):
    shaped = json.loads(json.dumps(response))
    shaped["file"]["content"] = stub
    shaped["file"]["numLines"] = 1
    shaped["file"]["startLine"] = 1
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": shaped}}


def decide(payload):
    """The hook output for this Read: a stub, or None to let the original output stand. Records the read either way."""
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
    paths = transcript_paths(payload, agent)
    marks = sizes_now(paths) if paths else None
    if marks is None:
        return None

    key, fingerprint = request_key(path, tool_input.get("offset"), tool_input.get("limit")), digest(content)
    stub = stub_text(path, body, content)
    root, name = state_root(), state_name(session, agent)
    os.makedirs(root, 0o700, exist_ok=True)
    first_of_agent = ps.stat_file(root, REL, name) is None
    with ps.lock(root, REL, LOCK):
        entries = load_entries(root, name)
        prior = entries.get(key)
        if (prior is not None and prior.get("h") == fingerprint and prior.get("n") == 0 and len(stub) < len(content)
                and not compaction_possible(paths, prior.get("o"))):
            prior["n"] = 1
            save_entries(root, name, entries)
            return stubbed_result(response, stub)
        entries.pop(key, None)
        entries[key] = {"h": fingerprint, "n": 0, "o": marks}
        save_entries(root, name, entries)
        if first_of_agent:
            prune_old(root, name)
    return None


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
