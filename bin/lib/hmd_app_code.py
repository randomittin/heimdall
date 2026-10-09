#!/usr/bin/env python3
"""hmd_app_code.py -- print the 5-character code of the repo --repo DIR (stdlib only).

`hmd app connect` offers this code for pairing by typing it on the phone, and the statusline, /api/state, the pair
window and the relay client's own state show it too, so all of them must print ONE value: the code of the repo, keyed by
the machine's seed and the repo's real path and by nothing a Claude Code session has (see bin/lib/hmd_session_code.py's
resolve_session_code, which every one of them goes through -- this asks that very function instead of deriving anything
a second time).

    python3 hmd_app_code.py --repo DIR      the code on stdout (exit 0);
                                            nothing on stdout and exit 1 when none can be derived
"""
import argparse
import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
SESSION_CODE_PATH = os.path.join(HERE, "hmd_session_code.py")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_app_code.py",
                                 description="the 5-character code of a repo, the one every hmd surface shows")
    ap.add_argument("--repo", required=True, metavar="DIR")
    args = ap.parse_args(argv)
    try:
        spec = spec_from_file_location("hmd_session_code", SESSION_CODE_PATH)
        lib = module_from_spec(spec)
        spec.loader.exec_module(lib)
        code, _source = lib.resolve_session_code(args.repo)
    except Exception as exc:  # any failure to load or derive is "no code available" to the caller, said once
        print("hmd_app_code: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 1
    if not code:
        print("hmd_app_code: no code for %s" % args.repo, file=sys.stderr)
        return 1
    print(code)
    return 0


if __name__ == "__main__":
    sys.exit(main())
