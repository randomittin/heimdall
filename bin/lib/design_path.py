#!/usr/bin/env python3
# design_path.py is the engine behind bin/heimdall-frontdoor's design subcommand.
#
# F1 (Onboarding) TIERED design path: the entry decision for the design route.
# Two tiers, with A the default:
#
#   A  inline-variant (DEFAULT) : generate design variants inline. No external
#                                 tool, no wiring. This is what a user gets unless
#                                 they explicitly ask for a real design tool. The
#                                 launch path picks A whenever no tier is named.
#
#   B  connect-a-real-design-tool : wire to an external design tool (the
#                                 designmatch flow, which matches a Claude Design
#                                 canonical to a real app at >=95% parity). Chosen
#                                 only when the user asks for it; this module then
#                                 routes to bin/designmatch (it does NOT re-build
#                                 designmatch).
#
# THE SELECTION RULE (select_tier):
#   - explicit "A" / "inline" / "inline-variant"  -> tier A
#   - explicit "B" / "connect" / "tool" / a design-source URL/path -> tier B
#   - nothing given                               -> tier A (the documented default)
#
# THE ENTRY (design_entry):
#   Returns a routing record { tier, route, ... }. For A the route is
#   "inline-variant" (handled inline by the launch path / variant generator). For
#   B the route is "designmatch" and the record carries the resolved designmatch
#   invocation (argv) so the caller can hand off to bin/designmatch init <source>.
#   We only BUILD the invocation; the launch path executes it (Wave 2), keeping
#   this module a pure decision unit.

import json
import os

TIER_A = "A"
TIER_B = "B"

# Tokens that explicitly select each tier (lower-cased match).
TIER_A_TOKENS = ("a", "inline", "inline-variant", "variant", "variants", "default")
TIER_B_TOKENS = ("b", "connect", "tool", "designmatch", "real", "external")

TIER_ROUTE = {
    TIER_A: "inline-variant",
    TIER_B: "designmatch",
}


def _looks_like_source(value):
    """True if value looks like a design SOURCE (URL or filesystem path).

    A bare source (a Claude Design URL or a local html/dir) implies tier B: the
    user handed us a real design to connect, so connect it.
    """
    if not value:
        return False
    if value.startswith(("http://", "https://")):
        return True
    if value.startswith(("/", "./", "../", "~")):
        return True
    # A path-ish token with a separator or a design file extension.
    if "/" in value or value.endswith((".html", ".htm")):
        return True
    return False


def select_tier(choice=None):
    """Select the design tier from an optional user choice.

    choice is a free-form token (case-insensitive) or None. Returns "A" or "B".
    The DEFAULT (None / empty / unrecognized non-source) is tier A: inline
    variants, no external tool. An explicit B token, or a design source value,
    selects tier B.
    """
    if choice is None:
        return TIER_A
    token = str(choice).strip()
    if token == "":
        return TIER_A
    low = token.lower()
    if low in TIER_A_TOKENS:
        return TIER_A
    if low in TIER_B_TOKENS:
        return TIER_B
    if _looks_like_source(token):
        return TIER_B
    # An unrecognized token is not a reason to leave the safe default; A is the
    # documented fallback so onboarding never dead-ends on a typo.
    return TIER_A


def designmatch_argv(source=None, app_dir=None):
    """Build the bin/designmatch invocation for tier B (argv list, not executed).

    Mirrors bin/designmatch's own interface: `init <source>` bootstraps from a
    canonical source; `wire` does the app-side setup when no source is given yet.
    The launch path (Wave 2) runs this argv; here we only resolve it.
    """
    if source:
        argv = ["designmatch", "init", source]
    else:
        argv = ["designmatch", "wire"]
    if app_dir:
        argv += ["--app-dir", app_dir]
    return argv


def design_entry(choice=None, source=None, app_dir=None):
    """Resolve the full design-path entry decision.

    Returns { tier, route, default, source, designmatch_argv } where:
      - tier            : "A" | "B"
      - route           : "inline-variant" (A) | "designmatch" (B)
      - default         : True iff tier A was reached as the default (no explicit
                          choice), so a caller can tell "chose A" from "fell back".
      - source          : the design source carried into tier B (or None)
      - designmatch_argv: the bin/designmatch invocation for tier B (None for A)
    """
    # A source value implies B even if `choice` was not the tier token.
    effective = choice
    if effective is None and source:
        effective = source
    tier = select_tier(effective)
    is_default = (choice is None or str(choice).strip() == "") and not source

    record = {
        "tier": tier,
        "route": TIER_ROUTE[tier],
        "default": bool(is_default and tier == TIER_A),
        "source": source if tier == TIER_B else None,
        "designmatch_argv": None,
    }
    if tier == TIER_B:
        record["designmatch_argv"] = designmatch_argv(source, app_dir)
    return record


def _cli(argv):
    """CLI core. Usage: heimdall-frontdoor design [--json] [--source S] [--app-dir D] [TIER].

    Wired as the `design` subcommand of bin/heimdall-frontdoor. Prints
    "<tier> -> <route>" for humans, or the full record with --json. Returns 0.
    """
    as_json = False
    source = None
    app_dir = None
    tier_arg = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help", "help"):
            _usage()
            return 0
        if arg == "--json":
            as_json = True
        elif arg == "--source":
            if i + 1 >= len(argv):
                print("design: --source needs a value")
                return 2
            source = argv[i + 1]
            i += 1
        elif arg == "--app-dir":
            if i + 1 >= len(argv):
                print("design: --app-dir needs a value")
                return 2
            app_dir = argv[i + 1]
            i += 1
        elif arg.startswith("-"):
            print("design: unknown option: %s" % arg)
            return 2
        else:
            if tier_arg is not None:
                print("design: only one TIER token may be given")
                return 2
            tier_arg = arg
        i += 1

    record = design_entry(choice=tier_arg, source=source, app_dir=app_dir)
    if as_json:
        print(json.dumps(record, indent=2, sort_keys=True))
    else:
        suffix = ""
        if record["tier"] == TIER_B and record["designmatch_argv"]:
            suffix = "  (%s)" % " ".join(record["designmatch_argv"])
        elif record["default"]:
            suffix = "  (default)"
        print("tier %s -> %s%s" % (record["tier"], record["route"], suffix))
    return 0


def _usage():
    print(
        "usage: heimdall-frontdoor design [--json] [--source S] [--app-dir D] [TIER]\n"
        "  resolve the design-path tier entry. TIER is one of:\n"
        "    A | inline | inline-variant   inline design variants (DEFAULT)\n"
        "    B | connect | tool            connect a real design tool (designmatch)\n"
        "  no TIER and no --source         -> tier A (the default)\n"
        "  --source S                      a design source (URL/path) implies tier B\n"
        "  --app-dir D                     RN app dir forwarded to designmatch\n"
        "  --json                          emit the full entry record"
    )


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
