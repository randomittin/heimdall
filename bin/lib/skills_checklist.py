#!/usr/bin/env python3
"""skills_checklist.py -- the first-launch checklist: ONE list of the skills this machine could add, one question, the answer.

    skills_checklist.py ask

Run by bin/lib/first_launch_checklist.sh from the launcher's first-run setup, at a terminal. It lists, each with the manifest's one-line why:
  recommended   the `recommended` entries of skills.manifest.json that hmd installs and this machine does not have;
  left out      on a lean install (bin/lib/hmd_profile.py get), the bundled entries it leaves out (on_demand_paths or a pack), which `hmd skills install ID` puts back
                from the copy hmd already holds: nothing is downloaded.
Declined entries are not offered again (`hmd skills suggest --reset` brings them back), and nothing listed is installed here: this prints the list and reads the
answer, the shell side acts on it.

ANSWER, one line from stdin:  numbers ("1 3" or "1,3": those entries) | a (all) | Enter (none for now; end of input is the same) | n (never ask).
A line that is none of these is asked again, three times in all, then it counts as Enter: nobody is ever left waiting.

OUTPUT. The list and the question go to stderr (the terminal), so the shell can capture stdout, which is two lines for it and nothing when there is nothing to offer:
    listed ID ID ...          every id that was on the list
    pick ID ID ... | none | never
EXIT. 0 asked (or nothing to offer); 1 the manifest or a lock cannot be read (the launcher then asks its one question instead); 2 usage. Never a traceback. stdlib only;
run as `python3 -I`.
"""
import os
import re
import sys

sys.dont_write_bytecode = True  # importing the sibling modules must not leave a .pyc in the plugin directory
LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB_DIR)  # python3 -I keeps the script's directory off sys.path
import skills_cli_install as install  # noqa: E402
import skills_resolver  # noqa: E402

TRIES = 3
HEADING = "Add skills to hmd? Nothing is installed until you pick."
LEFT_OUT = "Left out of this lean install (put back from this copy, nothing is downloaded)"
QUESTION = "  Pick numbers (e.g. 1 3), a = all, Enter = none for now, n = never ask: "
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@/+:-]{0,127}")  # the lock's id rule: nothing else reaches the shell


def offered(doc):
    """(the recommended entries, the left-out bundled entries) that this machine does not have and has not declined."""
    present, declined = install.present_ids(doc), install.declined_ids()
    recommended = [entry for entry in doc["entries"]
                   if entry["tier"] == "recommended" and install.installable(entry) and entry["id"] not in present | declined]
    return recommended, [entry for entry in install.left_out(doc, present) if entry["id"] not in declined]


def show(groups):
    width = max(len(entry["id"]) for _, entries in groups for entry in entries)
    sys.stderr.write("\n  %s\n" % HEADING)
    number = 0
    for title, entries in groups:
        sys.stderr.write("\n  %s\n" % title)
        for entry in entries:
            number += 1
            sys.stderr.write("  %2d) %-*s  %s\n" % (number, width, entry["id"], install.shown_why(entry)))
    sys.stderr.write("\n")


def parse(line, count):
    """One answer line -> ("pick", [numbers]) | ("none", []) | ("never", []), or None when it is not an answer."""
    words = [word for word in re.split(r"[,\s]+", line.strip().lower()) if word]
    if not words:
        return "none", []
    if words in (["a"], ["all"]):
        return "pick", list(range(1, count + 1))
    if words in (["n"], ["never"]):
        return "never", []
    if all(re.fullmatch(r"[0-9]{1,4}", word) and 1 <= int(word) <= count for word in words):
        return "pick", sorted({int(word) for word in words})
    return None


def ask(count):
    for _ in range(TRIES):
        sys.stderr.write(QUESTION)
        sys.stderr.flush()
        line = sys.stdin.readline()
        if line == "":  # end of input: nobody is there to answer
            return "none", []
        answer = parse(line, count)
        if answer:
            return answer
        sys.stderr.write("  Not understood: type numbers such as 1 3, a, n, or just Enter.\n")
    return "none", []


def main(argv):
    if argv != ["ask"]:
        sys.stderr.write("usage: skills_checklist.py ask\n")
        return 2
    try:
        recommended, left_out = offered(skills_resolver.load_manifest(install.MANIFEST))
    except Exception as exc:  # reported with a non-zero status, never a traceback: the launcher falls back to its one question
        sys.stderr.write("skills checklist: %s: %s\n" % (type(exc).__name__, exc))
        return 1
    groups = [(title, entries) for title, entries in (("Recommended", recommended), (LEFT_OUT, left_out)) if entries]
    if not groups:
        return 0
    entries = [entry for _, group in groups for entry in group]
    ids = [entry["id"] for entry in entries if ID_RE.fullmatch(entry["id"])]
    show(groups)
    action, numbers = ask(len(entries))
    print("listed " + " ".join(ids))
    if action == "pick":
        print("pick " + " ".join(entries[number - 1]["id"] for number in numbers if ID_RE.fullmatch(entries[number - 1]["id"])))
    else:
        print(action)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
