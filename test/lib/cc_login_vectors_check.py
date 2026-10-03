#!/usr/bin/env python3
"""test/lib/cc_login_vectors_check.py -- run the shared remote-login vectors through a copy of
bin/lib/companion_cc_login.py. Used by test/companion-cc-login-vectors.test.sh twice over: against the
real module (every vector must agree) and against a mutated copy of it (at least one must disagree --
a vector set that cannot tell the mutant from the original proves nothing).

    cc_login_vectors_check.py --module PATH [--vectors DIR]

The vectors (docs/samples/login/url-vectors.json, code-vectors.json) are always read from --vectors
(default: this checkout's); the module under test brings its own allowlist.json, found relative to the
module file, so a mutant that edits the allowlist is judged against the unmutated vectors.

Prints "module loaded" once the module imported (a mutant that fails to even import is not a caught
mutant, and the caller checks for that line), one "  FAIL <vector>: <what differed>" line per
disagreement and a final "N passed, M failed". Exit 0 only when M == 0.
"""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))


def load_module(path):
    spec = importlib.util.spec_from_file_location("companion_cc_login_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def authority_of(url):
    return url.split("://", 1)[1].split("/", 1)[0]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", required=True)
    ap.add_argument("--vectors", default=os.path.join(REPO, "docs", "samples", "login"))
    args = ap.parse_args(argv)

    mod = load_module(args.module)
    print("module loaded")
    passed = failed = 0

    def check(ok, name, detail):
        nonlocal passed, failed
        if ok:
            passed += 1
        else:
            failed += 1
            print("  FAIL %s: %s" % (name, detail))

    def outcome(fn, *a):
        """('ok', value) or ('error', LoginError.code) or ('crash', 'Type: message')."""
        try:
            return "ok", fn(*a)
        except mod.LoginError as e:
            return "error", e.code
        except Exception as e:  # a vector must never make the module raise anything but LoginError
            return "crash", "%s: %s" % (type(e).__name__, e)

    with open(os.path.join(args.vectors, "url-vectors.json"), encoding="utf-8") as f:
        url_vectors = json.load(f)["vectors"]
    for v in url_vectors:
        kind, value = outcome(mod.validate_url, v["url"], v["kind"])
        if v["expect"] == "ok":
            want = authority_of(v["url"])
            check(kind == "ok" and value == want, v["name"], "want host %r, got %s %r" % (want, kind, value))
        else:
            check(kind == "error" and value == v["expect"], v["name"],
                  "want LoginError(%r), got %s %r" % (v["expect"], kind, value))

    with open(os.path.join(args.vectors, "code-vectors.json"), encoding="utf-8") as f:
        code_vectors = json.load(f)["vectors"]
    for v in code_vectors:
        kind, value = outcome(mod.normalize_code, v["code"])
        if v["expect"] == "ok":
            check(kind == "ok" and value == v["normalized"], v["name"],
                  "want %r, got %s %r" % (v["normalized"], kind, value))
        else:
            check(kind == "error" and value == v["expect"], v["name"],
                  "want LoginError(%r), got %s %r" % (v["expect"], kind, value))

    # Boundary lengths come from the real allowlist, so no code-shaped literal lives in a fixture.
    with open(os.path.join(args.vectors, "allowlist.json"), encoding="utf-8") as f:
        allow = json.load(f)
    lo, hi = 8, 512
    part = lambda n, ch: ch * n  # noqa: E731 -- a run of one letter, never a real code
    boundary = [
        ("code-min-8", part(lo, "a"), True),
        ("code-7-below-min", part(lo - 1, "a"), False),
        ("code-max-512", part(hi, "a"), True),
        ("code-513-above-max", part(hi + 1, "a"), False),
        ("code-and-state-both-max", part(hi, "a") + "#" + part(hi, "b"), True),
        ("code-max-state-513", part(hi, "a") + "#" + part(hi + 1, "b"), False),
        ("code-513-state-max", part(hi + 1, "a") + "#" + part(hi, "b"), False),
        ("code-and-state-both-min", part(lo, "a") + "#" + part(lo, "b"), True),
    ]
    assert allow["code_max_length"] == 1025, "boundary table assumes the 1025 cap of spec 4.4"
    for name, value, accepted in boundary:
        kind, got = outcome(mod.normalize_code, value)
        if accepted:
            check(kind == "ok" and got == value, name, "want accepted, got %s %r" % (kind, got))
        else:
            check(kind == "error" and got == "bad-code", name, "want bad-code, got %s %r" % (kind, got))

    print("\n%d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
