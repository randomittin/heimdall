#!/usr/bin/env python3
"""skills_shadow.py -- shadow mode for the stack packs: the same stack-detect fixtures resolved from two roots, the pack text diffed.

    skills_shadow.py --bundled ROOT --package ROOT [--package-home HOME] [--stack-pack FILE] [--timeout SECONDS]

WHY. The lean profile moves the stack packs out of the install and ships them as a package (docs/superpowers/plans/2026-11-12-3x-lean-core.md, T1.3; spec
section 5 Stage 2: "Shadow mode: run both package and bundled versions on the same tasks, compare outcomes. Promote only if outcomes are identical"). This is that
comparison, written before anything moves, so the gate exists before the thing it gates. INV-L5 (a package that does not match falls back to the bundled copy,
silently) is what it checks from the outside: the two answers must be the same bytes, and the resolver must say nothing.

WHAT RUNS. A ROOT is a plugin root laid out the way bin/stack-pack reads it: ROOT/skills/stacks/<stack-id>/PACK.md. For each built-in fixture (FIXTURES: one project tree
per shipped stack, a two-stack monorepo, a repo with .planning/skills refinements, a detected stack with no pack, a tree with no signal; the same trees for both sides)
the harness runs `FILE load PROJECT` once per side with CLAUDE_PLUGIN_ROOT set to that side's root, then reads the files it printed. FILE is the real resolver (default:
bin/stack-pack next to this script), so whatever bin/stack-pack does later is what gets compared. Per fixture the two sides must agree on the exit status, the stderr
text and the ordered list of (the file's `<dir>/<name>`, its bytes). Order is part of the answer (base packs first, refinements on top); the root part of a path is not
(the roots differ by design). Both roots are only read and the package root is never run: the resolver is FILE, not anything inside a root.

THE INSTALLED PACK (--package-home HOME). The package side may read its packs from an installed pack instead of from its root (lean-core plan T3.1): HOME is the HEIMDALL_HOME
the package side runs with, holding the pack as bin/heimdall-pack-build makes it at HOME/packs/stacks and the machine lock, HOME/skills.lock, that pins it: what bin/stack-pack
resolves through bin/lib/skills_packs.py. Before any run the harness asks that resolver's own check, once, whether the pack is exactly the build the lock pins. If it is not, the
real resolver would fall back to the bundled copy (INV-L5) and the pack would go uncompared, so there is no verdict. A verified pack is then read like a root's skills/stacks, which
is the point of a package root that holds none (a lean one). The bundled side never gets a home to read: its answer is always the bundled copy. HOME is only read.

HERMETIC. Each call gets an environment built from nothing: PATH as inherited, LC_ALL=C, CLAUDE_PLUGIN_ROOT of its side, and a HOME and HEIMDALL_HOME of its own (HEIMDALL_HOME
does not exist, as on a machine where nothing was ever installed, unless --package-home gives the package side's), so an answer never depends on the operator's machine. The
calls run in parallel; the report is in fixture order.

TRUST. A root is third-party content. A file the resolver names is read only if its real path stays inside the root's skills/stacks (or the fixture project, for a
refinement; or, on the package side, its verified installed pack), it is a regular file and it is at most 4 MiB: a symlink out of the root, a missing file or an oversized
one is "no verdict", never a pass. Everything printed from a root (names, stderr, diff lines) is escaped: a pack is untrusted text.

COVERAGE. A comparison that resolves nothing proves nothing. Every pack the bundled root ships (skills/stacks/<id>/PACK.md) must be resolved by at least one fixture on the
bundled side, and the bundled side must exit 0 on every fixture (it is the reference); otherwise there is no verdict. Add a row to FIXTURES when a pack is added.

OUTPUT. stdout: a header, one `PASS <fixture>: identical (...)` or `FAIL <fixture>: ...` block per fixture, a summary. A difference lists the exit status, the stderr, and
per file: only in one side, a different name at that position, or the sizes, the first differing byte and a short unified diff. Nothing is printed on stdout without a verdict.

EXIT. 0 every fixture identical; 1 at least one differs; 2 usage, or no verdict (a root that is not a directory, the same directory twice, a resolver that is not
executable, hangs, fails on the bundled side or names a path it must not, a shipped pack no fixture exercises, a package home whose pack is not the build its lock pins). stdlib only
(the pack check imports bin/lib/skills_packs.py, and only with --package-home), Python 3.7+: run it as `python3 -I`.
"""
import argparse
import collections
import concurrent.futures
import difflib
import itertools
import os
import shutil
import subprocess
import sys
import tempfile

PACK_SKILL = "stacks"  # the skill id of the stack packs: skills/stacks in a plugin root, packs/stacks in a heimdall home
STACKS_REL = os.path.join("skills", PACK_SKILL)
LIB_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STACK_PACK = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "bin", "stack-pack")
TIMEOUT_S = 30.0
MAX_PACK_BYTES = 4 * 1024 * 1024
JOBS = max(1, min(8, os.cpu_count() or 2))
SHOWN_DIFF_LINES = 12
LINE_WIDTH = 200

NEXT_PACKAGE = '{"name": "shadow-web", "dependencies": {"next": "14.2.0", "react": "18.3.0"}}\n'
FASTAPI_REQUIREMENTS = "fastapi==0.110.0\nuvicorn==0.29.0\n"

# One project tree per row, written fresh for every run. A refinement directory is read by the shell's glob, which LC_ALL=C sorts bytewise: api.md, then ui.md.
FIXTURES = (
    ("nextjs", {"package.json": NEXT_PACKAGE}),
    ("react-native", {"package.json": '{"name": "shadow-app", "dependencies": {"react": "18.2.0", "react-native": "0.74.0"}}\n'}),
    ("fastapi", {"requirements.txt": FASTAPI_REQUIREMENTS}),
    ("spring-boot", {"build.gradle": "plugins {\n    id 'org.springframework.boot' version '3.2.4'\n    id 'java'\n}\n"}),
    ("monorepo", {"package.json": NEXT_PACKAGE, "requirements.txt": FASTAPI_REQUIREMENTS}),
    ("refined", {"package.json": NEXT_PACKAGE,
                 ".planning/skills/api.md": "# API refinement\n\nRoute handlers live in app/api.\n",
                 ".planning/skills/ui.md": "# UI refinement\n\nComponents live in components/ui.\n"}),
    ("go-no-pack", {"go.mod": "module example.com/shadow\n\ngo 1.22\n"}),
    ("no-signal", {"README.md": "# a tree with no stack signal\n"}),
)

Side = collections.namedtuple("Side", "name root home pack")  # home, pack: the HEIMDALL_HOME the side runs with and its verified installed pack (real paths), or None
Resolved = collections.namedtuple("Resolved", "identity kind data")  # kind: "pack" (under the root's skills/stacks) or "refinement" (under the project)
Outcome = collections.namedtuple("Outcome", "status stderr files")


class Unjudgeable(Exception):
    """No verdict is possible: a side could not give an answer the harness can trust, or the fixtures leave a shipped pack unchecked (exit 2)."""


def escaped(text):
    """TEXT with control and non-ASCII characters backslash-escaped (no quotes), cut to one line's width."""
    body = ascii(text)[1:-1]
    return body if len(body) <= LINE_WIDTH else body[:LINE_WIDTH - 3] + "..."


def shown(text):
    return "'" + escaped(text) + "'"


def write_fixtures(base):
    """Write every fixture project under BASE; returns [(name, project dir)] in FIXTURES order."""
    projects = []
    for name, files in FIXTURES:
        project = os.path.join(base, name)
        os.makedirs(project)
        for rel, text in files.items():
            path = os.path.join(project, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
        projects.append((name, project))
    return projects


def inside(path, base):
    return path == base or path.startswith(base + os.sep)


def read_resolved(label, line, project, side):
    """One path the resolver printed -> Resolved; Unjudgeable when it names something the harness must not read."""
    if "\0" in line:
        raise Unjudgeable("%s: the resolver names a path with a NUL byte" % label)
    real = os.path.realpath(os.path.join(project, line))
    if inside(real, os.path.join(side.root, STACKS_REL)) or (side.pack is not None and inside(real, side.pack)):
        kind = "pack"
    elif inside(real, os.path.realpath(project)):
        kind = "refinement"
    else:
        where = "its root, its installed pack and the fixture project" if side.pack is not None else "its root and the fixture project"
        raise Unjudgeable("%s: the resolver names %s, outside %s" % (label, shown(line), where))
    if not os.path.isfile(real):
        raise Unjudgeable("%s: the resolver names %s, which is not a regular file" % (label, shown(line)))
    try:
        with open(real, "rb") as handle:
            data = handle.read(MAX_PACK_BYTES + 1)
    except OSError as exc:
        raise Unjudgeable("%s: cannot read %s: %s" % (label, shown(line), exc.strerror or exc))
    if len(data) > MAX_PACK_BYTES:
        raise Unjudgeable("%s: %s is larger than %d bytes, too big to be a pack" % (label, shown(line), MAX_PACK_BYTES))
    return Resolved(os.path.basename(os.path.dirname(line)) + "/" + os.path.basename(line), kind, data)


def resolve(stack_pack, side, name, project, work, timeout):
    """Run `stack-pack load PROJECT` for one side of one fixture, in an environment that holds nothing of the caller's."""
    label = "%s side, fixture %s" % (side.name, name)
    home = os.path.join(work, "home", side.name, name)
    os.makedirs(home)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "HOME": home, "HEIMDALL_HOME": side.home or os.path.join(home, ".heimdall"),
           "CLAUDE_PLUGIN_ROOT": side.root}
    try:
        done = subprocess.run([stack_pack, "load", project], env=env, cwd=project, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Unjudgeable("%s: stack-pack did not answer within %gs" % (label, timeout))
    except OSError as exc:
        raise Unjudgeable("%s: cannot run %s: %s" % (label, shown(stack_pack), exc.strerror or exc))
    text = os.fsdecode(done.stdout)
    lines = text.split("\n")
    if lines.pop() != "" or "" in lines:
        raise Unjudgeable("%s: stack-pack's answer is not a list of paths, one per line: %s" % (label, shown(text)))
    files = tuple(read_resolved(label, line, project, side) for line in lines)
    return Outcome(done.returncode, done.stderr.decode("utf-8", "replace"), files)


def first_difference(left, right):
    """(offset, description) of the first byte at which two byte strings differ."""
    for offset, (a, b) in enumerate(zip(left, right)):
        if a != b:
            return offset, "0x%02x vs 0x%02x" % (a, b)
    return min(len(left), len(right)), "one file ends there"


def text_lines(data):
    return data.decode("utf-8", "replace").splitlines(True)


def file_differences(position, left, right):
    """Report lines for the file at POSITION in each answer (None: that side has no file there); empty means the same file."""
    if left is None:
        return ["file %d: only in package: %s" % (position, shown(right.identity))]
    if right is None:
        return ["file %d: only in bundled: %s" % (position, shown(left.identity))]
    if left.identity != right.identity:
        return ["file %d: bundled resolves %s, package resolves %s" % (position, shown(left.identity), shown(right.identity))]
    if left.data == right.data:
        return []
    offset, detail = first_difference(left.data, right.data)
    lines = ["file %d %s: %d vs %d bytes, first difference at byte %d (%s)" % (position, shown(left.identity), len(left.data), len(right.data), offset, detail)]
    diff = difflib.unified_diff(text_lines(left.data), text_lines(right.data), fromfile="bundled", tofile="package", n=1, lineterm="")
    head = list(itertools.islice(diff, SHOWN_DIFF_LINES + 1))
    lines.extend("  " + escaped(line) for line in head[:SHOWN_DIFF_LINES])
    if len(head) > SHOWN_DIFF_LINES:
        lines.append("  ...")
    return lines


def differences(left, right):
    """What differs between the bundled and the package outcome of one fixture, as report lines; empty means identical."""
    problems = []
    if left.status != right.status:
        problems.append("exit status: bundled %d, package %d" % (left.status, right.status))
    if left.stderr != right.stderr:
        problems.append("stderr: bundled %s, package %s" % (shown(left.stderr), shown(right.stderr)))
    for index in range(max(len(left.files), len(right.files))):
        problems.extend(file_differences(index + 1,
                                         left.files[index] if index < len(left.files) else None,
                                         right.files[index] if index < len(right.files) else None))
    return problems


def describe(outcome):
    """What an identical answer consists of, for the PASS line."""
    if not outcome.files:
        return "no pack resolved"
    return "%s; %d bytes" % (", ".join(shown(item.identity) for item in outcome.files), sum(len(item.data) for item in outcome.files))


def shipped_packs(root):
    """The stack ids ROOT ships: the directories of skills/stacks that hold a PACK.md."""
    stacks = os.path.join(root, STACKS_REL)
    if not os.path.isdir(stacks):
        return set()
    return {entry for entry in os.listdir(stacks) if os.path.isfile(os.path.join(stacks, entry, "PACK.md"))}


def real_dir(what, path):
    real = os.path.realpath(path)
    if not path or not os.path.isdir(real):
        raise Unjudgeable("the %s %s is not a directory" % (what, shown(path)))
    return real


def verified_pack(root, home):
    """The real path of the installed pack of the stacks under HOME when it is exactly the build HOME's machine lock pins, judged by the resolver's own check
    (bin/lib/skills_packs.py); Unjudgeable when it is not: the resolver would fall back to the bundled copy and the pack would go uncompared."""
    sys.path.insert(0, LIB_DIR)  # python3 -I keeps this script's directory off sys.path
    import skills_packs
    try:
        found = skills_packs.resolve(PACK_SKILL, plugin_root=root, heimdall_home=home)
    except OSError as exc:
        raise Unjudgeable("cannot check the installed pack of %s under %s: %s" % (PACK_SKILL, shown(home), exc.strerror or exc))
    if found.source != "pack":
        raise Unjudgeable("the installed pack of %s under %s is not the build its lock pins (SHA256SUMS, the files and %s must agree): the resolver would fall back "
                          "to the bundled copy and the pack would go unchecked" % (PACK_SKILL, shown(home), skills_packs.LOCK_FILE))
    return os.path.realpath(found.path)


def shadow(args):
    bundled = Side("bundled", real_dir("bundled root", args.bundled), None, None)
    package = Side("package", real_dir("package root", args.package), None, None)
    if bundled.root == package.root:
        raise Unjudgeable("the bundled and package roots are the same directory (%s): a tree compared with itself proves nothing" % shown(bundled.root))
    if not (os.path.isfile(args.stack_pack) and os.access(args.stack_pack, os.X_OK)):
        raise Unjudgeable("the resolver %s is not an executable file" % shown(args.stack_pack))
    shipped = shipped_packs(bundled.root)
    if not shipped:
        raise Unjudgeable("the bundled root ships no pack (skills/stacks/<id>/PACK.md): nothing to shadow")
    if args.package_home is not None:
        home = real_dir("package home", args.package_home)
        package = package._replace(home=home, pack=verified_pack(package.root, home))

    work = tempfile.mkdtemp(prefix="skills-shadow.")
    try:
        projects = write_fixtures(os.path.join(work, "projects"))
        jobs = [(side, name, project) for name, project in projects for side in (bundled, package)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
            outcomes = list(pool.map(lambda job: resolve(args.stack_pack, job[0], job[1], job[2], work, args.timeout), jobs))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    pairs = {}
    for (side, name, _project), outcome in zip(jobs, outcomes):
        pairs.setdefault(name, {})[side.name] = outcome
    exercised = set()
    for name, _project in projects:
        reference = pairs[name]["bundled"]
        if reference.status != 0:
            raise Unjudgeable("bundled side, fixture %s: stack-pack exited %d (%s): the reference answer must be clean"
                              % (name, reference.status, escaped(reference.stderr.strip())))
        exercised.update(item.identity.split("/")[0] for item in reference.files if item.kind == "pack")
    unreached = sorted(shipped - exercised)
    if unreached:
        raise Unjudgeable("no fixture resolves the bundled pack(s) %s: shadow mode would leave them unchecked (add a fixture to FIXTURES in %s)"
                          % (", ".join(escaped(pack) for pack in unreached), os.path.abspath(__file__)))

    report = ["skills-shadow: bundled=%s package=%s%s" % (escaped(bundled.root), escaped(package.root), " package-home=" + escaped(package.home) if package.home else "")]
    different = 0
    for name, _project in projects:
        problems = differences(pairs[name]["bundled"], pairs[name]["package"])
        if problems:
            different += 1
            report.append("  FAIL %s: the package answer differs from the bundled one" % name)
            report.extend("    " + problem for problem in problems)
        else:
            report.append("  PASS %s: identical (%s)" % (name, describe(pairs[name]["bundled"])))
    report.append("skills-shadow: %d fixtures, %d identical, %d different; all %d shipped packs exercised"
                  % (len(projects), len(projects) - different, different, len(shipped)))
    sys.stdout.write("\n".join(report) + "\n")
    return 1 if different else 0


def parse(argv):
    parser = argparse.ArgumentParser(
        prog="skills_shadow.py", allow_abbrev=False,
        description="Shadow mode for the stack packs: resolve the same stack-detect fixtures from two roots and diff the pack text. "
                    "Exit 0 identical, 1 different, 2 usage or no verdict.")
    parser.add_argument("--bundled", required=True, metavar="ROOT", help="plugin root holding the bundled packs: ROOT/skills/stacks/<id>/PACK.md")
    parser.add_argument("--package", required=True, metavar="ROOT", help="plugin root laid out the same way, holding the package's packs")
    parser.add_argument("--package-home", metavar="HOME",
                        help="HEIMDALL_HOME of the package side: its installed pack of the stacks (HOME/packs/stacks, as bin/heimdall-pack-build makes it) and the machine lock "
                             "(HOME/skills.lock) that pins it; the pack must be exactly the build the lock pins, else there is no verdict (default: an empty home, as for the bundled side)")
    parser.add_argument("--stack-pack", default=DEFAULT_STACK_PACK, metavar="FILE",
                        help="the resolver, run as `FILE load PROJECT` (default: bin/stack-pack next to this script)")
    parser.add_argument("--timeout", type=float, default=TIMEOUT_S, metavar="SECONDS", help="per resolver call (default: %g)" % TIMEOUT_S)
    args = parser.parse_args(argv)
    if not 0 < args.timeout < 86400:
        parser.error("--timeout must be more than 0 and less than 86400 seconds")
    return args


def main(argv=None):
    args = parse(argv)
    try:
        return shadow(args)
    except (Unjudgeable, OSError) as exc:
        sys.stderr.write("skills-shadow: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
