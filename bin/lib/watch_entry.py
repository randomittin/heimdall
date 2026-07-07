#!/usr/bin/env python3
"""
watch_entry.py — the arg-parsing entry for `hmd watch`, invoked by the bin launcher.

Resolves the shared render core (caps + sigil), decides Textual-vs-static, and either
launches the interactive dashboard (watch_tui) or prints the static one-shot wall+feed
dump (watch_data.static_dump). Every path here reads LOCAL caches only — no network.
"""

import os
import sys
import argparse
import importlib.util


def _here():
    return os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(prog="hmd watch", add_help=False)
    ap.add_argument("--once", action="store_true",
                    help="one-shot static wall+feed dump, no interactive loop")
    ap.add_argument("--pane", action="store_true",
                    help="slim tmux-split wall-only view")
    args, _unknown = ap.parse_known_args(argv)

    wd = _load("watch_data", os.path.join(_here(), "watch_data.py"))

    root = wd.resolve_root(os.environ)
    try:
        caps = wd.load_caps()
    except Exception:
        caps = None
    try:
        sig = wd.load_sigil()
    except Exception:
        sig = None

    textual_present = importlib.util.find_spec("textual") is not None

    # --once (or Textual absent) -> static dump. Never a hard failure.
    if args.once or not textual_present:
        sys.stdout.write(
            wd.static_dump(root, caps, sig, textual_present=textual_present) + "\n"
        )
        return 0

    # interactive dashboard
    app = _load("watch_tui", os.path.join(_here(), "watch_tui.py"))
    app.run(root, caps, sig, slim=args.pane)
    return 0


if __name__ == "__main__":
    sys.exit(main())
