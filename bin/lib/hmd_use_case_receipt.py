#!/usr/bin/env python3
r"""hmd_use_case_receipt -- the ONE definition of heimdall's use-case journey receipt: what `bash test/use-cases/run.sh` writes after a green full run, and
what the push gate of heimdall's own repo accepts in place of a full sweep.

Operator decision 2026-11-22 ("B"): for heimdall's OWN repo a push passes on a green use-case journey receipt; the full sweep (`bash test/run-all.sh`) is
required only for a release, and release/ship.sh keeps asking for its full-equivalent sweep receipt, unchanged. `heimdall-state check-quality-gates` therefore
passes the sweep part of the gate when EITHER a green full-equivalent sweep receipt covers HEAD (the old rule) OR the receipt defined here does, and
bin/lib/hmd_sweep_advice.py reads it the same way, so the advice and the gate cannot disagree about what "proven" means. Three programs touch the file and
all of them go through this module: run.sh writes it (`write`, after `clean` at the start of the run), the gate and the advice verify it (`status`,
record_problem, covers).

THE RECEIPT -- <$HEIMDALL_HOME or <repo>/.heimdall>/receipts/use-cases.json, exactly these fields (a receipt with another one is refused):
  schema       the number 1
  head_sha     the full object id of the commit the journeys ran on
  tree_sha     the full object id of that commit's tree
  exit_code    an integer, 0 only when every journey passed and every mutant was killed
  journeys     {total, passed}: the journeys the run found, and the ones that passed
  mutants      {total, killed}: the mutants of test/use-cases/mutants.list, and the ones that made their journey go RED
  duration_s   how long the run took, in seconds (the advice quotes it as the cost of the next one)
  finished_at  a UTC timestamp, 2026-11-22T12:00:00Z
GREEN means exit_code 0, at least one journey and every journey passed, at least one mutant and every mutant killed: a run that checked nothing, or whose
mutants survived (a journey that would not notice that break), is no proof.

`write` -- run.sh calls it only after a FULL run (no --only, no --no-mutants) that is green. It refuses unless the journeys graded one commit: the tree held no
uncommitted code when the run started (run.sh asked `clean` first) and holds none now, and HEAD is the commit the run started on, or only the hooks' own
journal and ledger records (bin/lib/hook-owned-path.sh, the allowlist the sweep shares) came after it. The receipt names the commit the run STARTED on, and
tree_sha is that commit's tree as git says, not a value the caller hands over. The file is written atomically (a temp file in the same directory, then rename).
`clean` -- run-all.sh's own tree_clean predicate: a tracked change counts, so does an untracked file, except the hooks' own records and the receipts directory.

`status` -- what the gate and the advice believe, re-derived from git and never taken from the file's word: the shape is exactly the schema; the run was
green; head_sha is a COMMIT this checkout has and tree_sha is that commit's tree; and the commit covers HEAD: it IS HEAD, or only the hooks' own journal and
ledger records came after it (they commit those after every real commit, so equality alone could never hold). A missing, unreadable, linked (a symlink is never
followed), oversized, garbled, mistyped, red, forged, stale or unverifiable receipt is "not proven" with one line saying why, and the gate then falls back to the
sweep receipt, exactly as before. Fail closed: anything git or the filesystem cannot answer is a refusal, never a pass.

A COOPERATING-AGENT CONTROL, NOT A SECURITY BOUNDARY, like heimdall's sweep receipt and the repo-checks receipt: it is a plain local file, so the bindings
catch a receipt that is stale, copied from another commit, hand-edited by accident or left by a run that was not green, not someone who can write the file
and its hashes. The native hook and CI stay the backstop.

Protocol: `status|clean|write --repo PATH ...`; ONE line on stdout. status: exit 0 = green and vouches for HEAD (the line says so), 1 = not (the line says why),
2 = could not run. clean: 0 = clean (no output), 1 = uncommitted code (the line names it), 2 = could not tell. write: 0 = written (the line names the file),
1 = refused (the line says why), 2 = failed. Python 3.7+, standard library only (plus the sibling hmd_sweep_guard, which reads git and the hooks' own paths).
"""
import argparse
import contextlib
import json
import os
import re
import stat
import sys
import tempfile
import time

sys.dont_write_bytecode = True  # a grader must not dirty the tree it grades: importing the sibling libs would leave bin/lib/__pycache__ in the very checkout whose cleanliness is the question
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hmd_sweep_guard as sg  # noqa: E402  (git, the hooks' own path shapes and ancestry: what the sweep gate and the advice already read the records with)

SCHEMA = 1
NAME = "use-cases.json"
RUNNER = "bash test/use-cases/run.sh"
MAX_BYTES = 1 << 20  # a receipt is a few hundred bytes: more than 1 MiB is not one, and is never read whole
OID_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
STAMP_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


class Refused(Exception):
    """`write` will not vouch for this run: the journeys did not grade one commit."""


def _int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _seconds(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < 10 ** 9


def _matching(pattern):
    return lambda value: isinstance(value, str) and pattern.fullmatch(value) is not None


def _counts(*keys):
    return lambda value: isinstance(value, dict) and set(value) == set(keys) and all(_int(value[k]) and value[k] >= 0 for k in keys)


# name, test, what the value must be -- the receipt's top level, in the order it is written
FIELDS = (
    ("schema", lambda v: _int(v) and v == SCHEMA, "the number 1"),
    ("head_sha", _matching(OID_RE), "the full object id of the commit the journeys ran on (40 lowercase hex digits, 64 in a sha256 repository)"),
    ("tree_sha", _matching(OID_RE), "the full object id of that commit's tree (40 lowercase hex digits, 64 in a sha256 repository)"),
    ("exit_code", _int, "an integer"),
    ("journeys", _counts("total", "passed"), "an object {total, passed} of whole numbers"),
    ("mutants", _counts("total", "killed"), "an object {total, killed} of whole numbers"),
    ("duration_s", _seconds, "a number of seconds, 0 or more"),
    ("finished_at", _matching(STAMP_RE), "a UTC timestamp like 2026-11-22T12:00:00Z"),
)
FIELD_NAMES = tuple(name for name, _, _ in FIELDS)


def shape_problem(receipt):
    """The first thing wrong with a receipt's shape (a missing, mistyped or malformed field, an unknown one), or None."""
    if not isinstance(receipt, dict):
        return "the receipt is not a JSON object"
    for name, ok, what in FIELDS:
        if name not in receipt:
            return "%s is missing (it must be %s)" % (name, what)
        if not ok(receipt[name]):
            return "%s must be %s" % (name, what)
    unknown = sorted(set(receipt) - set(FIELD_NAMES))
    if unknown:
        return "unknown field(s) %s (the schema is exactly %s)" % (", ".join(unknown), ", ".join(FIELD_NAMES))
    return None


def red_problem(receipt):
    """Why a receipt of a good shape does not record a green run (None when it does): the run exited non-zero, found no journey, failed one, ran no mutant or let one survive."""
    journeys, mutants = receipt["journeys"], receipt["mutants"]
    if receipt["exit_code"] != 0:
        return "the run exited %d, not 0" % receipt["exit_code"]
    if journeys["total"] < 1:
        return "no journey ran, and a run that checked nothing is no proof"
    if journeys["passed"] != journeys["total"]:
        return "%d of %d journeys passed" % (journeys["passed"], journeys["total"])
    if mutants["total"] < 1:
        return "no mutant ran, so nothing showed that the journeys notice a break"
    if mutants["killed"] != mutants["total"]:
        return "%d of %d mutants were killed (a survivor is a break the journey would not notice)" % (mutants["killed"], mutants["total"])
    return None


def build_receipt(head_sha, tree_sha, journeys_total, journeys_passed, mutants_total, mutants_killed, duration_s, finished_at):
    """The receipt `write` emits, for a run whose counts are green. ValueError when it would not pass shape_problem: a writer cannot emit what the gate would refuse."""
    receipt = {"schema": SCHEMA, "head_sha": head_sha, "tree_sha": tree_sha, "exit_code": 0,
               "journeys": {"total": journeys_total, "passed": journeys_passed}, "mutants": {"total": mutants_total, "killed": mutants_killed},
               "duration_s": duration_s, "finished_at": finished_at}
    problem = shape_problem(receipt)
    if problem:
        raise ValueError(problem)
    return receipt


def receipt_path(repo):
    """<$HEIMDALL_HOME or <repo>/.heimdall>/receipts/use-cases.json: where the sweep writer and the push gate keep theirs (test/run-all.sh, bin/heimdall-state)."""
    home = os.environ.get("HEIMDALL_HOME", "")
    return os.path.join(home or os.path.join(repo, ".heimdall"), "receipts", NAME)


def read(repo):
    """(the parsed JSON, None), or (None, the sentence for why there is none): missing, not a regular file (a link is never followed), too large, not JSON."""
    path = receipt_path(repo)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None, "there is no use-case journey receipt at %s" % path
    except OSError as exc:
        return None, "the use-case journey receipt at %s cannot be inspected (%s)" % (path, exc.strerror)
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
        return None, "the use-case journey receipt at %s is not a regular file of a sane size (a link is never followed)" % path
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as handle:
            return json.loads(handle.read(MAX_BYTES + 1).decode("utf-8")), None
    except (OSError, ValueError, RecursionError):
        return None, "the use-case journey receipt at %s is not valid JSON" % path


def commit_tree(repo, sha):
    """The tree of commit `sha` as git says, or None when this checkout has no such COMMIT (an id of a tree or a blob is none)."""
    rc, out = sg.git(repo, "rev-parse", "-q", "--verify", sha + "^{commit}")
    if rc != 0 or out.strip() != sha:
        return None
    rc, out = sg.git(repo, "rev-parse", "-q", "--verify", sha + "^{tree}")
    return out.strip() if rc == 0 and OID_RE.fullmatch(out.strip()) else None


def record_problem(repo, receipt):
    """None when `receipt` is a green record that is genuinely this checkout's: the schema, a green run, and a commit and tree as git says (re-derived here, never read
    off the file). Whether it covers HEAD is covers()'s question. May raise sg.Unread when git cannot be run."""
    problem = shape_problem(receipt)
    if problem:
        return "the use-case journey receipt is malformed: %s" % problem
    problem = red_problem(receipt)
    if problem:
        return "the use-case journey receipt is RED: %s" % problem
    sha = receipt["head_sha"]
    tree = commit_tree(repo, sha)
    if tree is None:
        return "the use-case journey receipt is for %s, a commit this checkout does not have" % sha[:12]
    if tree != receipt["tree_sha"]:
        return ("the use-case journey receipt's tree sha (%s) is not the tree of its commit %s (%s), so it does not describe that commit's content"
                % (receipt["tree_sha"][:12], sha[:12], tree[:12]))
    return None


def covers(repo, receipt, sha, owned):
    """Does the receipt vouch for commit `sha`: is it the receipt's own, or did only the hooks' own journal and ledger records come after it? Whatever git cannot say is no."""
    base = receipt["head_sha"]
    if sha == base:
        return True
    try:
        return sg.hooks_only_since(repo, base, sha, owned)
    except sg.Unread:
        return False


def stale_problem(repo, base, head, owned):
    """The sentence for why the receipt of commit `base` does not cover `head`: history rewritten, or the paths that are not the hooks' own."""
    lead = "STALE: the use-case journey receipt is for %s, HEAD is %s" % (base[:12], head[:12])
    if not sg.ancestor(repo, base, head):
        return lead + " (the receipt's commit is not an ancestor of HEAD: history was rewritten since the journeys ran)"
    shape = re.compile("^(?:%s)$" % owned) if owned else None
    names = [n for n in sg.git_out(repo, "diff", "--name-only", "-z", base, head).split("\0") if n and not (shape and shape.match(n))]
    shown = ", ".join(names[:3]) + (" and %d more" % (len(names) - 3) if len(names) > 3 else "")
    return lead + " (commits landed since the journeys ran, including paths that are not the hooks' own: %s)" % (shown or "none could be named")


def status(repo):
    """(True, one line saying the receipt is green and vouches for HEAD) or (False, one line saying why it does not)."""
    receipt, why = read(repo)
    if receipt is None:
        return False, why
    try:
        problem = record_problem(repo, receipt)
        if problem:
            return False, problem
        head = sg.git_out(repo, "rev-parse", "HEAD").strip()
        owned = sg.hook_owned()
        if head == receipt["head_sha"]:
            where = "HEAD"
        elif covers(repo, receipt, head, owned):
            where = "HEAD, which is past it by only the hooks' own journal and ledger records"
        else:
            return False, stale_problem(repo, receipt["head_sha"], head, owned)
    except sg.Unread as exc:
        return False, "the use-case journey receipt cannot be verified: %s" % exc
    journeys, mutants = receipt["journeys"], receipt["mutants"]
    return True, ("the use-case journey receipt is green (%d journeys, %d mutants killed, finished %s) and vouches for %s (%s)"
                  % (journeys["total"], mutants["killed"], receipt["finished_at"], receipt["head_sha"][:12], where))


def dirty_lines(repo, owned):
    """The `git status` lines that are uncommitted CODE: the predicate of run-all.sh's receipt (tree_clean) and of hmd_sweep_guard.dirty, here with the files an untracked
    directory holds listed one by one (-uall), so a hook-owned record in a directory git has not seen before is still told from a stray file."""
    ignored = [re.compile(r"^\?\? \.heimdall/(receipts/.*)?$")]
    if owned:
        ignored.append(re.compile(r"^(?:\?\?|.M|M.|A.|.A) (?:%s)$" % owned))
    out = sg.git_out(repo, "status", "--porcelain=v1", "--no-renames", "-uall")
    return [line for line in out.splitlines() if line and not any(p.match(line) for p in ignored)]


def named(lines):
    return ", ".join(line.strip() for line in lines[:3]) + (", and %d more" % (len(lines) - 3) if len(lines) > 3 else "")


def clean_problem(repo):
    """None when the work tree holds no uncommitted code, else the sentence that names it."""
    lines = dirty_lines(repo, sg.hook_owned())
    if not lines:
        return None
    return "the tree holds uncommitted changes (%s): a receipt attests a commit, so commit first and run again" % named(lines)


def write(repo, started_head, journeys_total, journeys_passed, mutants_total, mutants_killed, duration_s):
    """Write the receipt of a green full run that started on `started_head`; returns (path, receipt). Refused when the journeys did not grade ONE commit."""
    owned = sg.hook_owned()
    head = sg.git_out(repo, "rev-parse", "HEAD").strip()
    if head != started_head and not sg.hooks_only_since(repo, started_head, head, owned):
        raise Refused("HEAD moved during the run (%s -> %s) and not only by the hooks' own journal and ledger records, so the journeys no longer say which commit "
                      "they graded: run again on the final commit" % (started_head[:12], head[:12]))
    lines = dirty_lines(repo, owned)
    if lines:
        raise Refused("the tree holds uncommitted changes now (%s): a receipt attests a commit, so commit first and run again" % named(lines))
    tree = commit_tree(repo, started_head)
    if tree is None:
        raise Refused("the commit the run started on (%s) cannot be read from git" % started_head[:12])
    receipt = build_receipt(started_head, tree, journeys_total, journeys_passed, mutants_total, mutants_killed, duration_s,
                            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    problem = red_problem(receipt)
    if problem:
        raise Refused("this run is no proof: %s" % problem)
    path = receipt_path(repo)
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".use-cases.", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(receipt, handle, indent=2)
            handle.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return path, receipt


def oid(text):
    if not OID_RE.fullmatch(text):
        raise argparse.ArgumentTypeError("%r is not a full object id" % text)
    return text


def count(text):
    if not text.isdigit():
        raise argparse.ArgumentTypeError("%r is not a whole number" % text)
    return int(text)


def main(argv):
    parser = argparse.ArgumentParser(prog="hmd_use_case_receipt", description="heimdall's use-case journey receipt: write, clean, status")
    sub = parser.add_subparsers(dest="cmd")
    sub.required = True
    for name in ("status", "clean", "write"):
        one = sub.add_parser(name)
        one.add_argument("--repo", default=".")
        if name == "write":
            one.add_argument("--started-head", required=True, type=oid)
            one.add_argument("--journeys-total", required=True, type=count)
            one.add_argument("--journeys-passed", required=True, type=count)
            one.add_argument("--mutants-total", required=True, type=count)
            one.add_argument("--mutants-killed", required=True, type=count)
            one.add_argument("--duration-s", required=True, type=count)
    args = parser.parse_args(argv)
    repo = os.path.realpath(args.repo)
    try:
        if args.cmd == "status":
            ok, line = status(repo)
            print(line)
            return 0 if ok else 1
        if args.cmd == "clean":
            why = clean_problem(repo)
            if why:
                print(why)
            return 1 if why else 0
        path, receipt = write(repo, args.started_head, args.journeys_total, args.journeys_passed, args.mutants_total, args.mutants_killed, args.duration_s)
        print("use-cases receipt: %s (head %s, %d journeys, %d mutants killed, %ds)"
              % (path, receipt["head_sha"][:12], receipt["journeys"]["total"], receipt["mutants"]["killed"], receipt["duration_s"]))
        return 0
    except Refused as exc:
        print(str(exc))
        return 1
    except (sg.Unread, OSError, ValueError) as exc:
        print("the use-case journey receipt could not be %s: %s" % ({"status": "verified", "clean": "checked", "write": "written"}[args.cmd], exc))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
