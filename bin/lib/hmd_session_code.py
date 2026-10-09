#!/usr/bin/env python3
"""hmd_session_code.py -- the deterministic 5-char code a repo is paired by, and the record of which Claude Code
sessions are alive in it (stdlib only, no runtime deps).

WHY THIS EXISTS
The companion app (/Users/rj/Downloads/hmdapp) shows each paired `hmd ui` backend
as a tab a person can pick by typing a short code shown on this statusline
(src/sessioncode/SessionCodeEntry.tsx). Today the app MINTS that code itself,
client-side, at pairing time: src/sessioncode/code.ts's generateSessionCode()
draws 5 characters from crypto-random bytes and retries on collision against
the codes already assigned to other sessions paired on that device
(src/store/sessions.ts holds the assignment). There is no derivation there to
match -- the value is random, chosen once, and never a function of anything
hmd knows. That makes hmd, not the app, the only place a DETERMINISTIC code can
live: the same input always produces the same code here, so sentinels/hmd-statusline.py
and sentinels/hmd-ui.py's /api/state both read it from this ONE module and can
never disagree with each other. The app's own generator is unchanged by this file;
matching its alphabet (below) is what lets a code minted here already pass the app's
own validation the day it switches to reading this value instead of rolling its own.

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
    code = the first 25 bits of
           HMAC-SHA256(seed, "hmd-session-code-v1" 0x00 kind 0x00 input.encode("utf-8")),
    MSB-first, cut into five 5-bit groups, each indexing CODE_ALPHABET.

What a person is shown is ALWAYS the code of the REPO: kind "repo", input canonical_repo(path) -- the real path,
links resolved. It is a function of the repo and the machine's seed and of nothing else: not of the Claude Code
session (a repo has a new one at every start, resume and /clear, and several at once), not of who asks, not of
whether a session record exists. The statusline, `hmd ui`'s /api/state, bin/lib/hmd_app_code.py, `hmd app connect`,
the pair window and the relay client (which renders the same /api/state for the phone) all get it from
resolve_session_code, so a code typed from any one of them is the code every other one offers, and the code a phone
holds is still the right one after the session it was read from has ended. session_code_for itself is the primitive
under that (it can also hash a bare session id, kind "session_id"; no hmd surface shows such a code).

THE SEED. The code is a bearer secret: typed on a phone signed in to the same
GitHub account it pairs that phone, with no number to compare. So it must not be
a function of anything a stranger can guess or learn -- a repo path, or a session
id that sits in file names and in the environment of every process a session
spawns. The input is therefore KEYED with a per-machine secret seed: 32 random
bytes made on first use, kept as 64 hex characters in
$HEIMDALL_HOME/session-code.key (default ~/.heimdall), 0600 and ours, outside
every repo, read without following a link (bin/lib/hmd_private_state.py). A seed
file that exists but is a link, is not ours or not 0600, or is not exactly 64
hex characters is never replaced and never guessed around: there is no code
(session_code_for raises ValueError) and every reader degrades to "no code" --
the QR still pairs. A code is also unpredictable only up to its 25 bits: what
stops a guess is the relay (one GitHub identity, a throttle, a lockout), not this.
The seed is MADE by whatever first needs a code to register or serve -- the
SessionStart hook's record_session, `hmd ui`, `hmd app`, the CLI -- and only READ by
the statusline (create_seed=False): a render writes nothing, so the same stdin
renders the same bytes whatever the home directory is, and until a seed exists the
statusline shows no code rather than one nobody registered.

LIVE SESSIONS (record_session, live_sessions, forget_session)
The code does not need them; the pair window does. A repo's window must outlive any one session of it and end when none
is left, so the SessionStart hook records each session in <repo>/.heimdall/app/sessions/<session id>.json
{session_id, pid, ts[, transcript]} (0600, written through hmd_private_state: no link followed) and the SessionEnd hook
removes it. live_sessions lists the ones whose Claude process is still alive -- and only files this user wrote: a link,
a file of someone else's or one a git checkout planted (0644) is no session -- and the newest modification time of their
transcripts, the "activity" the window's idle stop watches across all of them.

CLI
    python3 hmd_session_code.py --repo DIR            the repo's code (what every surface shows)
    python3 hmd_session_code.py --repo DIR --json     {"code": ..., "source": "repo"}
    python3 hmd_session_code.py --session-id ID       the code a bare session id hashes to (a primitive, shown nowhere)
    python3 hmd_session_code.py --record-session --repo DIR --session-id ID --pid N [--transcript FILE]
                                                      write DIR/.heimdall/app/sessions/ID.json
    python3 hmd_session_code.py --forget-session --repo DIR --session-id ID
                                                      remove it
    python3 hmd_session_code.py --live-sessions --repo DIR
                                                      {"sessions": N, "activity": T} over the live ones

--session-id wins over --repo for the code, matching session_code_for()'s own precedence below.
"""
import hashlib
import hmac
import os
import sys

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 5
_BITS_PER_CHAR = 5                            # 2**5 == len(CODE_ALPHABET)
_TOTAL_BITS = _BITS_PER_CHAR * CODE_LENGTH    # 25

SESSIONS_REL = ".heimdall/app/sessions"
_SID_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
_SID_MAX = 128
_TRANSCRIPT_MAX = 2000                        # a record is read back at most hmd_private_state.READ_LIMIT (4096) bytes long

_KEY_NAME = "session-code.key"
_KEY_HEX = frozenset("0123456789abcdef")
_DOMAIN = b"hmd-session-code-v1\x00"

_PRIVATE = None
_SEEDS = {}


def _private():
    """bin/lib/hmd_private_state.py, loaded by path beside this file (this module is itself loaded by path by the
    statusline and `hmd ui`, so a plain import would not find it). Only the paths that touch a file come here."""
    global _PRIVATE
    if _PRIVATE is None:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hmd_private_state.py")
        spec = importlib.util.spec_from_file_location("hmd_private_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _PRIVATE = mod
    return _PRIVATE


def _heimdall_home():
    return os.environ.get("HEIMDALL_HOME") or os.path.join(os.path.expanduser("~"), ".heimdall")


def _seed(create=True):
    """The machine's session-code seed (see THE SEED in the module docstring). With `create`, made on first use:
    link(2) makes the file once, so two processes starting together end up reading the same one. Without it this only
    READS -- nothing is created, so a caller that must write nothing (the statusline's render) never does. ValueError
    when there is none (and none is to be made, or none can be), or what is stored is not exactly 64 hex characters."""
    home = _heimdall_home()
    cached = _SEEDS.get(home)
    if cached is not None:
        return cached
    private = _private()
    raw = private.read(home, "", _KEY_NAME, 128)
    if raw is None and not create:
        raise ValueError("no session code key yet in %s" % home)
    if raw is None:
        try:
            os.makedirs(home, mode=0o700, exist_ok=True)
            private.create_once(home, "", _KEY_NAME, (os.urandom(32).hex() + "\n").encode("ascii"))
        except FileExistsError:
            raw = private.read(home, "", _KEY_NAME, 128)  # lost the race to another process: its seed is the seed
        except OSError as exc:
            raise ValueError("session code key not made in %s: %s" % (home, exc))
        else:
            raw = private.read(home, "", _KEY_NAME, 128)
    text = raw.decode("ascii", "replace").strip() if raw is not None else ""
    if len(text) != 64 or not all(ch in _KEY_HEX for ch in text):
        raise ValueError("session code key %s is missing, not ours, not 0600, a link, or not 64 hex characters -- "
                         "remove it to have hmd make a new one" % os.path.join(home, _KEY_NAME))
    _SEEDS[home] = bytes.fromhex(text)
    return _SEEDS[home]


def canonical_repo(repo):
    """The one spelling of a repo's path that its code is keyed on: ~ expanded, links and `..` resolved. Every reader
    reaches the code through here (resolve_session_code), so a path given as a link, a relative path or with a
    trailing slash is the same repo. ValueError when `repo` is not a non-empty string."""
    if not isinstance(repo, str) or not repo.strip():
        raise ValueError("canonical_repo: need a non-empty repo path")
    return os.path.realpath(os.path.expanduser(repo))


def session_code_for(session_id=None, repo=None, create_seed=True):
    """(code, source) for `session_id` if it is a non-empty string, else for
    `repo` if IT is a non-empty string. `source` is the literal string
    "session_id" or "repo" naming which one won, so a caller (or a test)
    never has to re-derive that from the inputs. `create_seed=False` makes the
    machine's seed if it is missing no more than a ValueError: a caller that
    must write nothing asks that way. This is the primitive: it keys on the string it is given, and
    what a person is shown is resolve_session_code's -- the repo's, canonicalised.

    Raises ValueError when neither argument is a usable non-empty string, or when
    the machine's seed cannot be read (THE SEED, in the module docstring).
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
    digest = hmac.new(_seed(create_seed), _DOMAIN + source.encode("ascii") + b"\x00" + raw.encode("utf-8"),
                      hashlib.sha256).digest()
    top32 = int.from_bytes(digest[:4], "big")     # first 32 bits of the digest
    top25 = top32 >> (32 - _TOTAL_BITS)           # keep only the FIRST 25 of those
    chars = []
    for i in range(CODE_LENGTH):
        shift = (CODE_LENGTH - 1 - i) * _BITS_PER_CHAR
        chars.append(CODE_ALPHABET[(top25 >> shift) & 0x1F])
    return "".join(chars), source


def resolve_session_code(repo, create_seed=True):
    """(code, "repo"): THE derivation every reader of "this repo's code" goes through (see DERIVATION in the module
    docstring): the code of canonical_repo(repo), whoever asks and whatever Claude Code session -- if any -- they are in.
    Raises ValueError when there is no repo path, or no seed (with `create_seed=False`, none YET: the statusline passes
    it, since a render writes nothing)."""
    return session_code_for(repo=canonical_repo(repo), create_seed=create_seed)


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


def _record_name(session_id):
    return session_id + ".json"


def record_session(repo, session_id, pid, transcript=None):
    """Write <repo>/.heimdall/app/sessions/<session_id>.json {session_id, pid, ts[, transcript]}: 0600, atomically, the
    directories 0700, through hmd_private_state.write -- a link anywhere below the repo, or a directory of someone else's,
    is refused (OSError) with nothing created, chmod'ed or written through it. `pid` is the Claude Code process that owns
    the session -- the record only counts while it is alive. `transcript` is the session's transcript (an absolute path,
    which is kept; anything else is not): its modification time is the session's activity. Raises ValueError for an id
    or pid that could not have come from Claude Code."""
    import json
    import time
    if not valid_session_id(session_id):
        raise ValueError("record_session: not a session id: %r" % (session_id,))
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        raise ValueError("record_session: not a pid: %r" % (pid,))
    rec = {"session_id": session_id, "pid": pid, "ts": int(time.time())}
    if isinstance(transcript, str) and os.path.isabs(transcript) and len(transcript) <= _TRANSCRIPT_MAX and "\x00" not in transcript:
        rec["transcript"] = transcript
    _private().write(repo, SESSIONS_REL, _record_name(session_id),
                     json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return os.path.join(repo, SESSIONS_REL, _record_name(session_id))


def forget_session(repo, session_id):
    """Remove the record of `session_id`. True when it was removed. Other sessions' records are untouched: a repo has
    several sessions at once, and one ending must not take another's away."""
    if not valid_session_id(session_id):
        return False
    return _private().remove(repo, SESSIONS_REL, _record_name(session_id))


def live_sessions(repo):
    """[{"session_id", "pid", "transcript"}] for every session recorded for `repo` whose process is alive. A record whose
    process is gone is removed on the way (a Claude that was killed runs no SessionEnd hook). Only a record this user
    wrote counts (hmd_private_state.read_json: no link, ours, 0600); one that is not, or that names another session than
    its file does, is skipped and left alone. Never raises: no directory is no session."""
    private = _private()
    live = []
    try:
        names = private.names(repo, SESSIONS_REL)
    except Exception:
        return live
    for name in names:
        if not name.endswith(".json"):
            continue
        sid = name[:-len(".json")]
        try:
            rec = private.read_json(repo, SESSIONS_REL, name)
        except Exception:
            continue
        if rec is None or rec.get("session_id") != sid or not valid_session_id(sid):
            continue
        if not _pid_alive(rec.get("pid")):
            private.remove(repo, SESSIONS_REL, name)
            continue
        transcript = rec.get("transcript")
        live.append({"session_id": sid, "pid": rec["pid"], "transcript": transcript if isinstance(transcript, str) else None})
    return live


def sessions_activity(sessions):
    """The newest modification time (epoch seconds, an int) of the transcripts of `sessions` (live_sessions' answer) that
    exist, 0 when none does: the last time anything happened in any session of the repo."""
    newest = 0
    for rec in sessions:
        path = rec.get("transcript")
        if not path:
            continue
        try:
            newest = max(newest, int(os.stat(path).st_mtime))
        except OSError:
            continue
    return newest


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
        description="The 5-char hmd code of a repo (stdlib only), and the record of the sessions alive in it.",
    )
    parser.add_argument("--session-id", default=None, help="Claude Code session_id (hashed as-is by the code form: a "
                                                          "primitive, shown nowhere; the key of a session record)")
    parser.add_argument("--repo", default=None, help="repo path: the code every hmd surface shows is this repo's")
    parser.add_argument("--json", action="store_true", help='emit {"code": ..., "source": ...}')
    parser.add_argument("--record-session", action="store_true",
                        help="write <repo>/.heimdall/app/sessions/<id>.json for --session-id, owned by --pid")
    parser.add_argument("--forget-session", action="store_true",
                        help="remove <repo>/.heimdall/app/sessions/<id>.json")
    parser.add_argument("--live-sessions", action="store_true",
                        help='print {"sessions": N, "activity": T} for the sessions recorded in --repo whose process lives')
    parser.add_argument("--pid", type=int, default=None, help="the Claude Code process (with --record-session)")
    parser.add_argument("--transcript", default=None, help="the session's transcript, an absolute path (with --record-session)")
    args = parser.parse_args(argv)

    if args.record_session or args.forget_session or args.live_sessions:
        if args.record_session + args.forget_session + args.live_sessions > 1:
            print("error: --record-session, --forget-session and --live-sessions are exclusive", file=sys.stderr)
            return 2
        needs_session = args.record_session or args.forget_session
        if not args.repo or (needs_session and not args.session_id) or (args.record_session and args.pid is None):
            print("error: --record-session needs --repo, --session-id and --pid; --forget-session needs --repo and "
                  "--session-id; --live-sessions needs --repo", file=sys.stderr)
            return 2
        try:
            if args.record_session:
                record_session(args.repo, args.session_id, args.pid, args.transcript)
                # a recorded session is one the statusline is about to show a code for, and the statusline only READS the
                # seed (it writes nothing at render): this is where it comes to exist. Best effort -- no seed, no code shown
                import contextlib
                with contextlib.suppress(ValueError):
                    _seed()
            elif args.forget_session:
                forget_session(args.repo, args.session_id)
            else:
                sessions = live_sessions(args.repo)
                print(json.dumps({"sessions": len(sessions), "activity": sessions_activity(sessions)}))
        except (ValueError, OSError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        return 0

    try:
        if args.session_id:
            code, source = session_code_for(session_id=args.session_id, repo=args.repo)
        else:
            code, source = resolve_session_code(args.repo)
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
