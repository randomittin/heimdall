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

CLI
    python3 hmd_session_code.py --session-id ID     code for that session
    python3 hmd_session_code.py --repo DIR          code for that repo
    python3 hmd_session_code.py --repo DIR --json   {"code": ..., "source": ...}

--session-id wins when both are given, matching session_code_for()'s own
precedence below.
"""
import hashlib
import sys

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 5
_BITS_PER_CHAR = 5                            # 2**5 == len(CODE_ALPHABET)
_TOTAL_BITS = _BITS_PER_CHAR * CODE_LENGTH    # 25


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
    args = parser.parse_args(argv)

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
