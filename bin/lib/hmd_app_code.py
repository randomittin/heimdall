#!/usr/bin/env python3
"""hmd_app_code.py -- print the 5-character session code the `hmd ui` instance for --repo DIR shows
(stdlib only).

`hmd app connect` offers this same code for pairing by typing it on the phone, and the statusline and
/api/state show it too, so all three must print ONE value. The rule that decides it -- the Claude Code
session this repo's instance reads when its id names one of the repo's own transcripts, else the session
the SessionStart hook recorded for the repo (.heimdall/app/session.json, while its process lives), else the
repo path -- is bin/lib/hmd_session_code.py's resolve_session_code, reached through sentinels/hmd-ui.py's
collect_session_code. This asks that very function, with the root resolved the way `hmd ui --repo DIR`
resolves it, instead of deriving anything a second time.

    python3 hmd_app_code.py --repo DIR      the code on stdout (exit 0);
                                            nothing on stdout and exit 1 when none can be derived
"""
import argparse
import os
import sys
from importlib.util import module_from_spec, spec_from_file_location

HERE = os.path.dirname(os.path.realpath(__file__))
UI_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "sentinels", "hmd-ui.py"))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hmd_app_code.py",
                                 description="the 5-character session code `hmd ui --repo DIR` shows")
    ap.add_argument("--repo", required=True, metavar="DIR")
    args = ap.parse_args(argv)
    try:
        spec = spec_from_file_location("hmd_ui", UI_PATH)
        ui = module_from_spec(spec)
        spec.loader.exec_module(ui)
        code = ui.collect_session_code(ui.resolve_root(args.repo))
    except Exception as exc:  # any failure to load or derive is "no code available" to the caller, said once
        print("hmd_app_code: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 1
    if not code:
        print("hmd_app_code: no session code for %s" % args.repo, file=sys.stderr)
        return 1
    print(code)
    return 0


if __name__ == "__main__":
    sys.exit(main())
