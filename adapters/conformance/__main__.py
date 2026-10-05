"""python3 -m adapters.conformance: grade an adapter against the contract in docs/ADAPTERS.md.

  --adapter NAME            grade adapters/NAME.py (its driver is adapters/conformance/drivers/NAME.py)
  --adapter-file PATH       grade an adapter that lives elsewhere; needs --driver
  --driver NAME             the driver to use (default: the adapter's name)
  --json                    print the runhmd.adapter-conformance/1 report on stdout instead of text
  --list                    print the adapters present, one per line
  --rules                   print every rule id and title, tab separated

Exit: 0 every rule passed, 1 a rule failed (an adapter that cannot even be imported fails M1),
2 usage (unknown adapter or driver, unreadable file), 5 the suite itself could not run.
"""
from __future__ import annotations

import argparse
import importlib
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

from . import fixture, rules

EXIT_OK, EXIT_VIOLATION, EXIT_USAGE, EXIT_INFRA = 0, 1, 2, 5
ADAPTERS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write("adapters.conformance: %s\n" % message)
        sys.exit(EXIT_USAGE)


def adapters_present():
    return sorted(f[:-3] for f in os.listdir(ADAPTERS_DIR) if f.endswith(".py") and not f.startswith("_"))


def _usage(message):
    sys.stderr.write("adapters.conformance: %s\n" % message)
    return EXIT_USAGE


def _load_driver(name):
    full = "adapters.conformance.drivers." + name
    try:
        module = importlib.import_module(full)
    except ModuleNotFoundError as exc:
        if exc.name == full:
            return None, _usage("no driver %r: add adapters/conformance/drivers/%s.py exposing variants(fixture) (see docs/ADAPTERS.md)" % (name, name))
        raise
    if not callable(getattr(module, "variants", None)):
        return None, _usage("driver %r has no variants(fixture) function" % name)
    return module, None


def _load_adapter(args):
    """(module, load_error, name) or (None, None, exit code)."""
    if args.adapter_file:
        path = os.path.abspath(args.adapter_file)
        if not os.path.isfile(path):
            return None, None, _usage("cannot read the adapter file %s" % args.adapter_file)
        spec = importlib.util.spec_from_file_location("adapter_under_test", path)
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:  # noqa: BLE001 - an adapter that cannot be imported is nonconformant, not a crash
            return None, "import of %s failed: %s: %s" % (os.path.basename(path), type(exc).__name__, exc), os.path.basename(path)[:-3]
        return module, None, os.path.basename(path)[:-3]
    if not _NAME.match(args.adapter):
        return None, None, _usage("%r is not an adapter name (lower-case letters, digits, underscore)" % args.adapter)
    if not os.path.isfile(os.path.join(ADAPTERS_DIR, args.adapter + ".py")):
        return None, None, _usage("no adapter named %r (present: %s)" % (args.adapter, ", ".join(adapters_present()) or "none"))
    try:
        return importlib.import_module("adapters." + args.adapter), None, args.adapter
    except Exception as exc:  # noqa: BLE001
        return None, "import of adapters.%s failed: %s: %s" % (args.adapter, type(exc).__name__, exc), args.adapter


def _report(name, results, as_json):
    counts = {s: sum(1 for r in results if r["status"] == s) for s in ("pass", "fail", "skip")}
    if as_json:
        sys.stdout.write(json.dumps({
            "schema": "runhmd.adapter-conformance/1", "adapter": name, "contract": rules.CONTRACT, "ok": counts["fail"] == 0,
            "passed": counts["pass"], "failed": counts["fail"], "skipped": counts["skip"], "checks": results}, indent=2) + "\n")
    else:
        sys.stdout.write("adapter: %s  contract: %s\n" % (name, rules.CONTRACT))
        for r in results:
            sys.stdout.write("  %s %s  %s\n" % (r["status"].upper(), r["id"], r["title"]))
            if r["detail"] and r["status"] != "pass":
                sys.stdout.write("       %s\n" % r["detail"])
        sys.stdout.write("RESULT: %d passed, %d failed, %d skipped\n" % (counts["pass"], counts["fail"], counts["skip"]))
    return EXIT_VIOLATION if counts["fail"] else EXIT_OK


def main(argv):
    parser = _Parser(prog="python3 -m adapters.conformance", add_help=True, allow_abbrev=False)
    parser.add_argument("--adapter")
    parser.add_argument("--adapter-file")
    parser.add_argument("--driver")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--rules", action="store_true")
    args = parser.parse_args(argv)

    if args.list:
        sys.stdout.write("".join(name + "\n" for name in adapters_present()))
        return EXIT_OK
    if args.rules:
        sys.stdout.write("".join("%s\t%s\n" % row for row in rules.catalogue()))
        return EXIT_OK
    if bool(args.adapter) == bool(args.adapter_file):
        return _usage("give exactly one of --adapter NAME or --adapter-file PATH (--list shows the adapters present)")
    if args.adapter_file and not args.driver:
        return _usage("--adapter-file needs --driver NAME (the driver that turns the scenario into this adapter's tasks)")

    driver_name = args.driver or args.adapter
    if not _NAME.match(driver_name):
        return _usage("%r is not a driver name" % driver_name)
    driver, failure = _load_driver(driver_name)
    if failure is not None:
        return failure
    mod, load_error, name = _load_adapter(args)
    if mod is None and load_error is None:
        return name

    if load_error:
        return _report(name, rules.run(None, None, [], load_error=load_error), args.json)
    work = tempfile.mkdtemp(prefix="runhmd-conformance-")
    try:
        try:
            fx = fixture.Fixture(os.path.join(work, "fx")).build()
            variants = driver.variants(fx)
        except fixture.FixtureError as exc:
            sys.stderr.write("adapters.conformance: cannot build the fixture: %s\n" % exc)
            return EXIT_INFRA
        if not variants or not all(isinstance(v, tuple) and len(v) == 2 and isinstance(v[0], str) and isinstance(v[1], dict) for v in variants):
            sys.stderr.write("adapters.conformance: driver %r must return a non-empty list of (name, task) pairs\n" % driver_name)
            return EXIT_INFRA
        return _report(name, rules.run(mod, fx, variants), args.json)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
