#!/usr/bin/env python3
"""runhmd_demo -- `hmd demo --offline`: an agent writes a bug, runhmd attacks it, the agent fixes it.

The trial path: what runhmd does, in about a second, with nothing to install, configure or trust.
It runs the REAL attack engine (bin/heimdall-attack) twice on the bundled fixture pair:

    fixtures/attack/buggy-webhook   a settlement webhook that looks done and has one real defect  -> DENIED
    fixtures/attack/clean-sample    the same webhook with the claim made atomic (the fix)          -> PROVEN

The story is never scripted. The sequence in the output is whatever the engine answered: if the
buggy fixture is not DENIED, the fixed one not PROVEN, or either cannot be attacked, the demo exits 5
and says why - it never prints an arc the engine did not produce.

Offline by construction: the engine is deterministic (no model, no network, $0.00) and nothing in this
module opens a socket. Zero footprint: each attack runs with HOME and TMPDIR inside one temp dir that is
removed on the way out, and with bytecode writing off, so nothing lands in HOME, the cwd or the install.
test/zero-footprint.test.sh proves both, the first under a sandbox that kills any network call.

Exit: 0 the arc ran as told (DENIED, then PROVEN); 2 usage; 5 it did not (a fixture is missing, the
engine failed, or the fixtures did not behave).
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time

sys.dont_write_bytecode = True  # before the sibling imports: the demo writes nothing into the install it runs from

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import runhmd_card  # noqa: E402
from runhmd_attack import EXIT_DENIED, EXIT_INFRA, EXIT_PROVEN, EXIT_USAGE  # noqa: E402

FIXTURE_ROOT = os.path.join(PLUGIN_DIR, "fixtures", "attack")
ATTACK_BIN = os.path.join(PLUGIN_DIR, "bin", "heimdall-attack")
BUGGY, FIXED, MODULE = "buggy-webhook", "clean-sample", "webhook.mjs"
CLAIM = "done: redelivered events are deduplicated and the tests pass"
ATTACK_WALL_S = 120

# Flags of the scaffold demo (bin/heimdall-demo without --offline): named here so the refusal can say why.
SCAFFOLD_FLAGS = {"--run", "--dry", "--force", "--no-reel", "--intro", "--no-intro"}

HELP = """hmd demo --offline -- an agent writes a bug, runhmd DENIES it, the agent fixes it, runhmd PROVES it.

usage:
  hmd demo --offline [--json]

Runs the real `hmd attack` engine twice on a bundled fixture pair. First a settlement webhook that
looks done and has one real defect (a provider retry within 50ms credits the account twice): DENIED,
with the counterexample. Then the same webhook with the claim made atomic: PROVEN. What is printed
is what the engine answered - the demo cannot be made to say DENIED -> PROVEN by anything but the
engine saying so.

No network, no model, $0.00. Nothing is written outside one temp dir, removed on exit.

options:
  --json       print the runhmd.demo/1 document on stdout (the canonical output; the default is a render of it)
  -h, --help   this text

exit codes:
  0  the arc ran as told: DENIED, then PROVEN
  2  usage error
  5  the arc did not happen: a bundled fixture is missing, the engine failed, or the fixtures did not
     behave (the buggy one was not DENIED, or the fixed one not PROVEN)
"""


class DemoError(Exception):
    """The arc could not be told. `kind` is the machine-readable reason (the JSON error field)."""

    def __init__(self, kind, detail):
        super().__init__(detail)
        self.kind = kind
        self.detail = detail


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("hmd demo --offline: %s (see hmd demo --offline --help)\n" % message)
        sys.exit(EXIT_USAGE)


def _parse(argv):
    parser = _Parser(prog="hmd demo --offline", add_help=False, allow_abbrev=False)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--json", action="store_true")
    args, extra = parser.parse_known_args(argv)
    for word in extra:
        if word in SCAFFOLD_FLAGS:
            parser.error("%s belongs to the scaffold demo; --offline is self-contained and takes no other mode flags" % word)
        parser.error("unrecognized argument: %s (--offline takes no directory and only --json)" % word)
    if not args.offline:
        parser.error("this runner is only for --offline")
    return args


def _tail(text, limit=300):
    lines = (text or "").strip().splitlines()
    return (lines[-1] if lines else "no output")[:limit]


def _check_install():
    """The bundled pieces the arc needs, or a DemoError naming the first one that is missing."""
    needed = [ATTACK_BIN] + [os.path.join(FIXTURE_ROOT, name, part)
                             for name in (BUGGY, FIXED) for part in (MODULE, "runhmd.attack.json")]
    for path in needed:
        if not os.path.isfile(path):
            raise DemoError("demo_fixture_missing", "this install is missing %s - reinstall hmd" % os.path.relpath(path, PLUGIN_DIR))


def _attack(name, work):
    """Attack one bundled fixture with the real CLI and return its runhmd.verdict/1 document."""
    target = os.path.join(FIXTURE_ROOT, name)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=os.path.join(work, "home"), TMPDIR=os.path.join(work, "tmp"), PYTHONDONTWRITEBYTECODE="1")
    for key in ("HOME", "TMPDIR"):
        os.makedirs(env[key], exist_ok=True)
    argv = [sys.executable, ATTACK_BIN, target, "--json", "--yes", "--no-network"]
    try:
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=ATTACK_WALL_S, env=env)
    except subprocess.TimeoutExpired:
        raise DemoError("demo_attack_failed", "hmd attack on %s did not finish within %ds" % (name, ATTACK_WALL_S))
    except OSError as exc:
        raise DemoError("demo_attack_failed", "cannot run hmd attack: %s" % exc)
    try:
        doc = json.loads(done.stdout)
    except ValueError:
        doc = None
    if not isinstance(doc, dict) or doc.get("schema") != "runhmd.verdict/1":
        detail = doc.get("detail") if isinstance(doc, dict) and doc.get("detail") else _tail(done.stderr)
        raise DemoError("demo_attack_failed", "hmd attack on %s gave no verdict (exit %d): %s" % (name, done.returncode, detail))
    if (done.returncode, doc.get("verdict")) not in ((EXIT_PROVEN, "PROVEN"), (EXIT_DENIED, "DENIED")):
        raise DemoError("demo_attack_failed", "hmd attack on %s: exit %d with verdict %r" % (name, done.returncode, doc.get("verdict")))
    return doc


def _fix_diff():
    """The agent's fix, as a unified diff of the module between the two fixtures."""
    sides = []
    for name in (BUGGY, FIXED):
        with open(os.path.join(FIXTURE_ROOT, name, MODULE), "r", encoding="utf-8") as fh:
            sides.append(fh.read().splitlines(keepends=True))
    return "".join(difflib.unified_diff(sides[0], sides[1], fromfile="%s (the agent's version)" % MODULE,
                                        tofile="%s (fixed)" % MODULE, n=1))


def _run(work, started):
    _check_install()
    before = _attack(BUGGY, work)
    after = _attack(FIXED, work)
    sequence = [before["verdict"], after["verdict"]]
    if sequence != ["DENIED", "PROVEN"]:
        raise DemoError("demo_sequence", "the bundled fixtures did not behave as the demo needs: %s was %s and %s was %s "
                        "(wanted DENIED, then PROVEN). This install is damaged; `bin/falsify attack` shows whether the "
                        "attack gate itself is sound." % (BUGGY, sequence[0], FIXED, sequence[1]))
    return {
        "schema": "runhmd.demo/1",
        "mode": "offline",
        "sequence": sequence,
        "before": before,
        "fix": {"file": MODULE, "diff": _fix_diff()},
        "after": after,
        "cost_usd": round(before["cost_usd"] + after["cost_usd"], 6),
        "duration_s": round(time.monotonic() - started, 2),
    }


def _shown(ref):
    """A fixture path as the reader would type it from the install root."""
    return os.path.relpath(ref, PLUGIN_DIR)


def _indented(text, prefix="   "):
    return "\n".join(prefix + line for line in text.splitlines())


def render(doc):
    """The human text for one runhmd.demo/1 document: built from nothing but the document's own fields."""
    before, after = doc["before"], doc["after"]
    shown = before["findings"][0]["counterexample"]
    lines = [
        "runhmd demo (offline): an agent says it is done, runhmd checks.",
        "No network, no model, nothing written outside a temp dir.",
        "",
        "1. The agent ships a settlement webhook and reports: \"%s\"." % CLAIM,
        "",
        "2. $ hmd attack %s" % _shown(before["target"]["ref"]),
        _indented(runhmd_card.render_card(before).rstrip("\n")),
        textwrap.fill("counterexample: " + shown["summary"], width=78, initial_indent="   ", subsequent_indent="   "),
        "   reproduce: " + shown["repro_cmd"],
        "",
        "3. The agent fixes %s:" % doc["fix"]["file"],
        _indented(doc["fix"]["diff"].rstrip("\n")),
        "",
        "4. $ hmd attack %s" % _shown(after["target"]["ref"]),
        _indented(runhmd_card.render_card(after).rstrip("\n")),
        "",
        "%s -> %s in %.1fs, $%.2f." % (before["verdict"], after["verdict"], doc["duration_s"], doc["cost_usd"]),
    ]
    return "\n".join(lines) + "\n"


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        sys.stdout.write(HELP)
        return EXIT_PROVEN
    args = _parse(argv)
    started = time.monotonic()
    work = tempfile.mkdtemp(prefix="runhmd-demo-")
    try:
        doc = _run(work, started)
    except DemoError as err:
        if args.json:
            sys.stdout.write(json.dumps({"error": err.kind, "detail": err.detail}, indent=2) + "\n")
        else:
            sys.stderr.write("hmd demo --offline: %s: %s\n" % (err.kind, err.detail))
        return EXIT_INFRA
    finally:
        shutil.rmtree(work, ignore_errors=True)
    sys.stdout.write(json.dumps(doc, indent=2) + "\n" if args.json else render(doc))
    return EXIT_PROVEN


def _terminate(signum, _frame):
    # unwinds through main()'s cleanup: the running attack is killed, the temp dir removed
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # `hmd demo --offline | head -3` ends quietly
    signal.signal(signal.SIGTERM, _terminate)
    sys.exit(main(sys.argv[1:]))
