#!/usr/bin/env python3
# persona_store.py — the real engine behind `bin/heimdall-persona`.
#
# F1 (Onboarding) global persona: a SET-ONCE, product-wide identity that decides
# tone, defaults, and which paths surface. The first run asks ONE question
# (coder / non-coder); every later run reads the remembered answer and never
# re-prompts. This module is the persistence + validation core; the bash CLI is
# a thin wrapper over it.
#
# WHY GLOBAL (not per-project): the persona is the user, not the repo. A coder in
# project A is a coder in project B. So it persists at the HOME root, never under
# a project dir:
#
#   ${HEIMDALL_HOME:-$HOME/.heimdall}/persona.json
#
# The path is resolved from the environment at call time (never a baked literal),
# so it relocates with HEIMDALL_HOME and is testable against a temp HOME.
#
# ON-DISK SHAPE (persona.json):
#   { "version": 1,
#     "persona": "coder" | "non-coder",
#     "set_at":  "<ISO-8601 UTC>" }
# An absent file, an empty file, malformed JSON, or an unknown persona value all
# read back as the sentinel "unset" — the store NEVER invents a persona, and a
# corrupt file degrades to unset (so onboarding re-asks once) rather than raising.
#
# HOW A CONSUMER BRANCHES ON IT (the propagation contract):
#   from persona_store import get_persona, is_coder
#   p = get_persona()                 # "coder" | "non-coder" | "unset"
#   if p == "unset":  run_onboarding()        # cold: ask once, then set()
#   tone     = "technical" if is_coder() else "plain-language"
#   defaults = CODER_DEFAULTS if is_coder() else NONCODER_DEFAULTS
# `is_coder()` is the single branch point product code should call so the
# coder/non-coder split (terse+code-first vs guided+plain-language) stays
# consistent everywhere instead of each call-site re-deriving it.

import datetime
import json
import os

VALID_PERSONAS = ("coder", "non-coder")
UNSET = "unset"
STORE_VERSION = 1


def heimdall_home():
    """The global Heimdall home — ${HEIMDALL_HOME:-$HOME/.heimdall}.

    Resolved from the environment every call (no module-load caching) so a test
    that sets HEIMDALL_HOME/HOME in a subprocess always sees its own dir. Never a
    baked path.
    """
    explicit = os.environ.get("HEIMDALL_HOME")
    if explicit:
        return explicit
    return os.path.join(os.path.expanduser("~"), ".heimdall")


def persona_path():
    """Absolute path to the global persona.json."""
    return os.path.join(heimdall_home(), "persona.json")


def _read_raw():
    """Load and parse persona.json, or return None on any read/parse failure."""
    path = persona_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return None


def get_persona():
    """Return the stored persona, or the sentinel "unset".

    Returns one of: "coder", "non-coder", "unset". A missing file, corrupt JSON,
    or an unrecognized persona value all map to "unset" — the store never guesses.
    """
    data = _read_raw()
    if not isinstance(data, dict):
        return UNSET
    persona = data.get("persona")
    if persona in VALID_PERSONAS:
        return persona
    return UNSET


def is_set():
    """True iff a valid persona is persisted. The onboarding gate's predicate."""
    return get_persona() != UNSET


def is_coder():
    """Single branch point for the coder vs non-coder product split.

    Defaults to False when unset, so a cold path surfaces the guided (non-coder)
    experience until onboarding records an explicit choice.
    """
    return get_persona() == "coder"


def set_persona(persona):
    """Persist the global persona (set-once write).

    Validates against VALID_PERSONAS, creates the Heimdall home if missing, and
    writes atomically (temp file + os.replace) so a crash mid-write never leaves a
    half-written persona.json that would read back corrupt. Returns the persona.
    Raises ValueError on an invalid persona value.
    """
    if persona not in VALID_PERSONAS:
        raise ValueError(
            "invalid persona %r — must be one of %s"
            % (persona, ", ".join(VALID_PERSONAS))
        )
    home = heimdall_home()
    os.makedirs(home, exist_ok=True)
    path = persona_path()
    payload = {
        "version": STORE_VERSION,
        "persona": persona,
        "set_at": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
    return persona


def _cli(argv):
    """CLI core. Subcommands: get | set <persona> | is-set | path.

    Kept here (not in the bash wrapper) so the behavior is one testable unit.
    Returns the process exit code; prints the human-facing result to stdout.
    """
    if not argv:
        _usage()
        return 2
    cmd = argv[0]
    if cmd in ("-h", "--help", "help"):
        _usage()
        return 0
    if cmd == "get":
        print(get_persona())
        return 0
    if cmd == "is-set":
        # Print the boolean AND mirror it in the exit code so shell callers can
        # branch either way: `heimdall-persona is-set && ...` or read the word.
        if is_set():
            print("true")
            return 0
        print("false")
        return 1
    if cmd == "path":
        print(persona_path())
        return 0
    if cmd == "set":
        if len(argv) < 2:
            print("persona: 'set' needs a value: coder | non-coder", flush=True)
            return 2
        try:
            value = set_persona(argv[1])
        except ValueError as exc:
            print("persona: %s" % exc, flush=True)
            return 2
        print(value)
        return 0
    _usage()
    return 2


def _usage():
    print(
        "usage: heimdall-persona <get | set <coder|non-coder> | is-set | path>\n"
        "  get      print the global persona, or 'unset'\n"
        "  set V    persist the global persona (coder | non-coder), set-once\n"
        "  is-set   print true/false; exit 0 if set, 1 if unset\n"
        "  path     print the resolved persona.json path"
    )


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
