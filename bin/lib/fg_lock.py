#!/usr/bin/env python3
"""fg_lock: the design-freeze manifest of the false-green suite (PREREG.md section 11).

PREREG.lock.json records the sha256 of the preregistration, the enumerated case set, every file under
tasks/ (ground truth, naive check, spec, frozen base, design-set list) and every design-set source.
`verify` recomputes all of it and reports any drift, so an instrument cannot change after the freeze
without a visible, committed re-lock.

  fg_lock.py write  --suite DIR --repo DIR     (re)write PREREG.lock.json
  fg_lock.py verify --suite DIR --repo DIR     exit 1 and list problems when anything drifted
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

SCHEMA = "fg.prereg-lock/1"
LOCK_NAME = "PREREG.lock.json"


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locked_files(suite):
    """Suite-relative paths under the freeze: the prereg, the case set and everything in tasks/."""
    found = ["PREREG.md", "cases.json"]
    for root, _dirs, files in os.walk(os.path.join(suite, "tasks")):
        for name in files:
            found.append(os.path.relpath(os.path.join(root, name), suite))
    return sorted(found)


def design_set_paths(suite):
    with open(os.path.join(suite, "tasks", "settlement-webhook", "design_set.json"), "r", encoding="utf-8") as fh:
        return sorted(entry["path"] for entry in json.load(fh)["entries"])


def compute(suite, repo):
    return {
        "schema": SCHEMA,
        "files": {rel: _sha256_file(os.path.join(suite, rel)) for rel in locked_files(suite)},
        "design_set": {rel: _sha256_file(os.path.join(repo, rel)) for rel in design_set_paths(suite)},
    }


def verify(suite, repo):
    """Problems (empty when the tree matches the committed lock)."""
    lock_path = os.path.join(suite, LOCK_NAME)
    try:
        with open(lock_path, "r", encoding="utf-8") as fh:
            lock = json.load(fh)
    except (OSError, ValueError) as exc:
        return ["%s is missing or unreadable: %s" % (LOCK_NAME, exc)]
    problems = []
    if lock.get("schema") != SCHEMA:
        problems.append("%s has schema %r, expected %s" % (LOCK_NAME, lock.get("schema"), SCHEMA))
    try:
        now = compute(suite, repo)
    except OSError as exc:
        return problems + ["cannot hash a locked file: %s" % exc]
    for section, base in (("files", suite), ("design_set", repo)):
        locked, current = lock.get(section, {}), now[section]
        for rel in sorted(set(locked) | set(current)):
            if rel not in current:
                problems.append("%s: locked file is gone: %s" % (section, rel))
            elif rel not in locked:
                problems.append("%s: file is not in the lock (added after the freeze): %s" % (section, rel))
            elif locked[rel] != current[rel]:
                problems.append("%s: changed after the freeze: %s" % (section, rel))
    return problems


def main(argv):
    parser = argparse.ArgumentParser(prog="fg_lock", description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("write", "verify"))
    parser.add_argument("--suite", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args(argv)
    if args.command == "write":
        with open(os.path.join(args.suite, LOCK_NAME), "w", encoding="utf-8") as fh:
            fh.write(json.dumps(compute(args.suite, args.repo), indent=2) + "\n")
        return 0
    problems = verify(args.suite, args.repo)
    for problem in problems:
        sys.stderr.write("fg_lock: %s\n" % problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
