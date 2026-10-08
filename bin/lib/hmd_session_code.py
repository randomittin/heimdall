#!/usr/bin/env python3
"""hmd_session_code.py -- deterministic 5-char code identifying an hmd session
(stdlib only, no runtime deps).

WHY THIS EXISTS
The companion app (/Users/rj/Downloads/hmdapp) shows each paired `hmd ui` backend
as a tab a person can pick by typing a short code shown on this statusline
(src/sessioncode/SessionCodeEntry.tsx). Today the app MINTS that code itself,
client-side, at pairing time: src/sessioncode/code.ts's generateSessionCode()
draws 5 characters from crypto-random bytes and retries on collision against
the codes already assigned to other sessions paired on that device
(src/store/sessions.ts holds the assignment). There is no derivation there to
match -- the value is random, chosen once, and never a function of anything
hmd knows (not the session id, not the repo). That makes hmd, not the app,
the only place a DETERMINISTIC code can live: the same input always produces
the same code here, so sentinels/hmd-statusline.py and sentinels/hmd-ui.py's
/api/state both read it from this ONE module and can never disagree with
each other. The app's own generator is unchanged by this file; matching its
alphabet (below) is what lets a code minted here already pass the app's own
validation the day it switches to reading this value instead of rolling its
own -- see the coder's report for the exact one-line change that needs.

ALPHABET -- matches hmdapp's CODE_ALPHABET EXACTLY (src/sessioncode/code.ts):

    ABCDEFGHJKLMNPQRSTUVWXYZ23456789   (32 characters)

Uppercase A-Z with I and O dropped, digits 2-9 with 0 and 1 dropped: no
0/1/I/O anywhere, so nothing in a code can be misread as one of the other
three characters in that visually-ambiguous set. This is deliberately NOT
the standard Crockford base32 alphabet (which keeps 0/1 and instead drops
I/L/O/U) -- it is hmdapp's own 32-symbol set, matched character-for-character
on purpose: the app's lenient typo-correction (mistyped '1' or 'I' -> 'L',
see normalizeSessionCode) only makes sense against this exact alphabet, and
its choice to leave '0'/'O' unmapped (rather than guess) only stays correct
if hmd never emits either. 32 symbols == 2**5: one alphabet character per 5
bits of hash, with no remainder.

DERIVATION
    code = the first 25 bits of sha256(input.encode("utf-8")), MSB-first,
    cut into five 5-bit groups, each indexing CODE_ALPHABET.

`input` is the Claude Code session_id when the caller has one (the live
identifier riding statusLine's stdin JSON, one per Claude Code conversation);
otherwise the repo's filesystem path. Two different inputs collide only by
the ordinary odds of a 25-bit hash (1 in 2**25 per pair -- see
test/hmd-session-code.test.sh's 50-input probabilistic no-collision case).

ONE CODE, WHOEVER ASKS (resolve_session_code)
The statusline hashes the live session_id on its stdin; a process that is NOT
Claude Code's statusline -- `hmd ui`'s /api/state, `hmd app connect` run from a
plain terminal, the pair window -- has no such stdin, and used to fall back to the
repo path, so the code it showed or registered was not the one typed from the
statusline. The SessionStart hook now records the live session in
<repo>/.heimdall/app/session.json {session_id, pid, ts} (0600; record_session) and
removes it at SessionEnd (forget_session). resolve_session_code is the ONE function
every reader goes through, with one precedence:
    1. the caller's own live session id (the statusline's stdin);
    2. a pinned id (the session this process inherited, when it names one of the
       repo's own transcripts -- sentinels/hmd-ui.py's repo_session);
    3. the session recorded in session.json, while the pid it names is alive;
    4. the repo path.
The statusline, /api/state, bin/lib/hmd_app_code.py and `hmd app` therefore agree by
construction: they differ only when no session is known to any of them.

CLI
    python3 hmd_session_code.py --session-id ID     code for that session
    python3 hmd_session_code.py --repo DIR          code for that repo
    python3 hmd_session_code.py --repo DIR --json   {"code": ..., "source": ...}
    python3 hmd_session_code.py --record-session --repo DIR --session-id ID --pid N
                                                    write DIR/.heimdall/app/session.json
    python3 hmd_session_code.py --forget-session --repo DIR --session-id ID
                                                    remove it, when it names ID

--session-id wins when both are given, matching session_code_for()'s own
precedence below.
"""
import hashlib
import os
import sys

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 5
_BITS_PER_CHAR = 5                            # 2**5 == len(CODE_ALPHABET)
_TOTAL_BITS = _BITS_PER_CHAR * CODE_LENGTH    # 25

SESSION_FILE_REL = os.path.join(".heimdall", "app", "session.json")
_SID_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
_SID_MAX = 128


def session_code_for(session_id=None, repo=None):
    """(code, source) for `session_id` if it is a non-empty string, else for
    `repo` if IT is a non-empty string. `source` is the literal string
    "session_id" or "repo" naming which one won, so a caller (or a test)
    never has to re-derive that from the inputs.

    Raises ValueError when neither argument is a usable non-empty string.
    Every caller in this repo treats that as "no code available" and
    degrades accordingly -- see sentinels/hmd-statusline.py's _session_code
    and sentinels/hmd-ui.py's collect_session_code, both of which catch this
    and return None rather than let it surface. The CLI below turns it into
    a clean exit 1 + stderr message instead of a traceback."""
    if isinstance(session_id, str) and session_id.strip():
        raw, source = session_id, "session_id"
    elif isinstance(repo, str) and repo.strip():
        raw, source = repo, "repo"
    else:
        raise ValueError("session_code_for: need a non-empty session_id or repo")
    digest = hashlib.sha256(raw.encode("utf-8")).digest()
    top32 = int.from_bytes(digest[:4], "big")     # first 32 bits of the digest
    top25 = top32 >> (32 - _TOTAL_BITS)           # keep only the FIRST 25 of those
    chars = []
    for i in range(CODE_LENGTH):
        shift = (CODE_LENGTH - 1 - i) * _BITS_PER_CHAR
        chars.append(CODE_ALPHABET[(top25 >> shift) & 0x1F])
    return "".join(chars), source


def valid_session_id(session_id):
    """A Claude Code session id as a file-name-safe key: 1..128 of [A-Za-z0-9_-]."""
    return (isinstance(session_id, str) and 0 < len(session_id) <= _SID_MAX
            and all(ch in _SID_CHARS for ch in session_id))


def _pid_alive(pid):
    """Signal 0 delivers nothing; it only asks whether the pid exists and is ours to signal. A pid that
    belongs to another user is not Claude Code (the same user started it), so EPERM counts as gone."""
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def session_file(repo):
    return os.path.join(repo, SESSION_FILE_REL)


def live_session_id(repo):
    """The session id <repo>/.heimdall/app/session.json records, while that file is whole and the process it
    names is alive; else None. Never raises: a missing, torn or foreign-looking file is no session."""
    if not isinstance(repo, str) or not repo.strip():
        return None
    import json  # lazy: the statusline's render path only comes here when its own stdin named no session
    try:
        with open(session_file(repo), "r", encoding="utf-8") as f:
            rec = json.loads(f.read(4096))
    except (OSError, ValueError):
        return None
    if not isinstance(rec, dict):
        return None
    sid = rec.get("session_id")
    if not valid_session_id(sid) or not _pid_alive(rec.get("pid")):
        return None
    return sid


def resolve_session_code(repo=None, session_id=None, pinned_session_id=None):
    """(code, source): THE derivation every reader of "this session's code" goes through (see ONE CODE, WHOEVER
    ASKS in the module docstring). `session_id` is the caller's own live id (the statusline's stdin),
    `pinned_session_id` an id the caller inherited that names one of the repo's own transcripts. Raises
    ValueError exactly when session_code_for would: no session known and no repo path to fall back to."""
    sid = None
    for candidate in (session_id, pinned_session_id):
        if isinstance(candidate, str) and candidate.strip():
            sid = candidate
            break
    if sid is None:
        sid = live_session_id(repo)
    return session_code_for(session_id=sid, repo=repo)


def record_session(repo, session_id, pid):
    """Write <repo>/.heimdall/app/session.json {session_id, pid, ts}: 0600, atomically, the directory 0700 (the
    mode every file hmd keeps there has). `pid` is the Claude Code process that owns the session -- the file
    only counts while it is alive. Raises ValueError for an id or pid that could not have come from Claude Code."""
    import contextlib
    import json
    import tempfile
    import time
    if not valid_session_id(session_id):
        raise ValueError("record_session: not a session id: %r" % (session_id,))
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        raise ValueError("record_session: not a pid: %r" % (pid,))
    path = session_file(repo)
    app = os.path.dirname(path)
    os.makedirs(app, exist_ok=True)
    os.chmod(app, 0o700)
    fd, tmp = tempfile.mkstemp(dir=app, prefix="session.json.tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps({"session_id": session_id, "pid": pid, "ts": int(time.time())},
                               sort_keys=True, separators=(",", ":")))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return path


def forget_session(repo, session_id):
    """Remove session.json when -- and only when -- it names `session_id`: a session that started later in the same
    repo owns the file now, and an earlier one ending must not take its record away. True when removed."""
    import json
    path = session_file(repo)
    try:
        with open(path, "r", encoding="utf-8") as f:
            rec = json.loads(f.read(4096))
    except (OSError, ValueError):
        return False
    if not isinstance(rec, dict) or rec.get("session_id") != session_id:
        return False
    try:
        os.unlink(path)
    except OSError:
        return False
    return True


def main(argv=None):
    # Lazy: session_code_for() (the hot render path, loaded in-process by
    # sentinels/hmd-statusline.py's _session_code()) never touches argparse or
    # json -- only this CLI entry point does. Importing them here instead of at
    # module top keeps every statusline render from paying for a stdlib import
    # (argparse pulls in re/textwrap/warnings) it never uses.
    import argparse
    import json

    parser = argparse.ArgumentParser(
        prog="hmd_session_code.py",
        description="Deterministic 5-char hmd session code (stdlib only).",
    )
    parser.add_argument("--session-id", default=None, help="Claude Code session_id")
    parser.add_argument("--repo", default=None, help="repo path (fallback input)")
    parser.add_argument("--json", action="store_true", help='emit {"code": ..., "source": ...}')
    parser.add_argument("--record-session", action="store_true",
                        help="write <repo>/.heimdall/app/session.json for --session-id, owned by --pid")
    parser.add_argument("--forget-session", action="store_true",
                        help="remove <repo>/.heimdall/app/session.json if it names --session-id")
    parser.add_argument("--pid", type=int, default=None, help="the Claude Code process (with --record-session)")
    args = parser.parse_args(argv)

    if args.record_session or args.forget_session:
        if args.record_session and args.forget_session:
            print("error: --record-session and --forget-session are exclusive", file=sys.stderr)
            return 2
        if not args.repo or not args.session_id or (args.record_session and args.pid is None):
            print("error: --record-session needs --repo, --session-id and --pid; "
                  "--forget-session needs --repo and --session-id", file=sys.stderr)
            return 2
        try:
            if args.record_session:
                record_session(args.repo, args.session_id, args.pid)
            else:
                forget_session(args.repo, args.session_id)
        except (ValueError, OSError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        return 0

    try:
        code, source = session_code_for(session_id=args.session_id, repo=args.repo)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"code": code, "source": source}))
    else:
        print(code)
    return 0


if __name__ == "__main__":
    sys.exit(main())
