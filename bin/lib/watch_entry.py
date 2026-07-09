#!/usr/bin/env python3
"""
watch_entry.py — the arg-parsing entry for `hmd watch`, invoked by the bin launcher.

Resolves the shared render core (caps + sigil), decides Textual-vs-static, and either
launches the interactive dashboard (watch_tui) or prints the static one-shot wall+feed
dump (watch_data.static_dump). Every path here reads LOCAL caches only — no network.
"""

import os
import sys
import time
import argparse
import importlib.util


def _here():
    return os.path.dirname(os.path.abspath(__file__))


def _truthy(v):
    return str(v or "").strip().lower() in ("1", "true", "yes", "on")


def _emit_beat(wd, root):
    """Best-effort: shell the existing `heimdall-presence beat` so opening the wall marks
    you present (TTL-live). Runs from `root` so the beat's project + team.json match the
    repo being watched. Short timeout + swallowed errors: a single `hmd watch` self-includes
    on the roster, and the dump still renders even if the beat drops (offline / CP down)."""
    import contextlib
    import subprocess
    with contextlib.suppress(Exception):
        argv = wd.build_beat_argv(wd.resolve_presence_bin(os.environ))
        subprocess.run(argv, cwd=root, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _stdout_is_tty(env):
    """A non-TTY stdout (piped / CI) must NEVER enter the infinite live loop — it gets a
    single static dump instead. Test hooks (HEIMDALL_WATCH_ASSUME_TTY / _ASSUME_NOTTY)
    force either way so the loop is drivable under a pipe without hanging the suite."""
    if _truthy(env.get("HEIMDALL_WATCH_ASSUME_TTY")):
        return True
    if _truthy(env.get("HEIMDALL_WATCH_ASSUME_NOTTY")):
        return False
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


def _choose_mode(args, textual_present, is_tty):
    """Pure branch selector for `hmd watch` (unit-testable, no side effects). Precedence:
      install_tui   -> provision textual into hmd's own interpreter, then exit
      once           -> single static wall+feed dump (scripting / pipes)
      textual        -> the rich Textual dashboard (ENHANCED path, when importable)
      live           -> no-textual ANSI auto-refresh live wall (TTY fallback; self-beating)
      dump           -> single static dump when textual is absent AND stdout is not a TTY
                        (pipe/CI: NEVER an infinite loop)."""
    if args.install_tui:
        return "install_tui"
    if args.once:
        return "once"
    if textual_present:
        return "textual"
    if is_tty:
        return "live"
    return "dump"


# ── the no-textual auto-refresh LIVE wall (the durable, zero-dependency fix) ──
# When textual is absent we do NOT fall back to a single static dump for the interactive
# `hmd watch` — instead this loop clears the screen and re-renders the wall+feed every
# ~2s (pure ANSI reprint) AND emits the presence beat each cycle. Result: a live,
# self-beating wall with ZERO extra dependencies. Ctrl-C restores the terminal (cursor)
# and stops beating. The whole loop imports NO textual (see watch_data.render_dump).
_CLEAR = "\033[2J\033[H"        # clear screen + cursor home
_HIDE_CURSOR = "\033[?25l"
_SHOW_CURSOR = "\033[?25h"


def _auto_refresh_loop(wd, root, caps, sig):
    env = os.environ
    try:
        interval = float(env.get("HEIMDALL_WATCH_INTERVAL", "2.0"))
    except ValueError:
        interval = 2.0
    if interval < 0:
        interval = 0.0
    # Optional cycle cap: bounds the loop so a test (and only a test) can drive it without
    # hanging. Absent => a genuinely unbounded live loop that only Ctrl-C stops.
    max_cycles = None
    mc = env.get("HEIMDALL_WATCH_MAX_CYCLES")
    if mc:
        try:
            max_cycles = max(1, int(mc))
        except ValueError:
            max_cycles = None
    footer = [
        "",
        "LIVE · no-textual wall · auto-refresh %gs · Ctrl-C to exit" % interval,
        "rich TUI (optional): %s" % wd.textual_install_hint(env),
    ]
    out = sys.stdout
    cycles = 0
    try:
        out.write(_HIDE_CURSOR)
        while True:
            _emit_beat(wd, root)                      # each cycle marks you present
            body = wd.render_dump(root, caps, sig, env)   # LOCAL re-read, zero network
            out.write(_CLEAR)
            out.write("\n".join(body + footer))
            out.write("\n")
            out.flush()
            cycles += 1
            if max_cycles is not None and cycles >= max_cycles:
                break
            time.sleep(interval)
    except KeyboardInterrupt:
        out.write("\n")                                # Ctrl-C: newline so the prompt returns clean
    finally:
        out.write(_SHOW_CURSOR)                        # restore the terminal on exit
        out.flush()
    return 0


def _install_tui_argv(wd):
    """The argv that installs textual into hmd-watch's OWN interpreter (sys.executable),
    PEP-668-aware. NOT pipx (isolated venv hmd can't import from). Pure — no side effect."""
    py = sys.executable or "python3"
    argv = [py, "-m", "pip", "install", "--user", "textual"]
    if wd._externally_managed():
        argv.append("--break-system-packages")
    return argv


def _install_tui(wd):
    """`hmd watch --install-tui`: install textual INTO hmd-watch's own interpreter so the
    very next `hmd watch` gets the rich TUI. Targets the exact python that does
    `import textual`, PEP-668-aware."""
    import shlex
    import subprocess
    argv = _install_tui_argv(wd)
    sys.stdout.write("installing textual into hmd's interpreter:\n  %s\n"
                     % " ".join(shlex.quote(a) for a in argv))
    sys.stdout.flush()
    try:
        rc = subprocess.run(argv).returncode
    except Exception as exc:
        sys.stderr.write("install failed: %s\n" % exc)
        sys.stderr.write("manual: %s\n" % wd.textual_install_hint(os.environ))
        return 1
    if rc == 0:
        sys.stdout.write("textual installed — run `hmd watch` for the rich TUI.\n")
    else:
        sys.stderr.write("pip exited %d. Try: %s\n"
                         % (rc, wd.textual_install_hint(os.environ)))
    return rc


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(prog="hmd watch", add_help=False)
    ap.add_argument("--once", action="store_true",
                    help="one-shot static wall+feed dump, no interactive loop")
    ap.add_argument("--pane", action="store_true",
                    help="slim tmux-split wall-only view")
    ap.add_argument("--install-tui", dest="install_tui", action="store_true",
                    help="install textual into hmd's own python for the rich TUI")
    args, _unknown = ap.parse_known_args(argv)

    wd = _load("watch_data", os.path.join(_here(), "watch_data.py"))

    # HEIMDALL_WATCH_FORCE_NO_TEXTUAL: force the textual-absent path even where textual is
    # installed (test hook) so the no-textual live loop is drivable in CI.
    force_no_textual = _truthy(os.environ.get("HEIMDALL_WATCH_FORCE_NO_TEXTUAL"))
    textual_present = (not force_no_textual) and (importlib.util.find_spec("textual") is not None)

    mode = _choose_mode(args, textual_present, _stdout_is_tty(os.environ))

    if mode == "install_tui":
        return _install_tui(wd)

    root = wd.resolve_root(os.environ)
    try:
        caps = wd.load_caps()
    except Exception:
        caps = None
    try:
        sig = wd.load_sigil()
    except Exception:
        sig = None

    # once / dump -> single static dump. Never a hard failure. Beat ONCE before the read
    # so a single `hmd watch` self-includes on the roster (opening the wall marks you
    # present). Best-effort — the dump renders regardless of the beat's fate.
    if mode in ("once", "dump"):
        _emit_beat(wd, root)
        sys.stdout.write(
            wd.static_dump(root, caps, sig, textual_present=textual_present) + "\n"
        )
        return 0

    # textual absent + interactive TTY -> the no-textual auto-refresh live wall.
    if mode == "live":
        return _auto_refresh_loop(wd, root, caps, sig)

    # textual present -> the rich dashboard; watch_tui beats on open + on a TTL interval.
    app = _load("watch_tui", os.path.join(_here(), "watch_tui.py"))
    app.run(root, caps, sig, slim=args.pane)
    return 0


if __name__ == "__main__":
    sys.exit(main())
