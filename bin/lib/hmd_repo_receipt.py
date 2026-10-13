#!/usr/bin/env python3
r"""hmd_repo_receipt -- the ONE definition of a repo-checks receipt: what `heimdall-repo-checks run` writes and what the push gate
(`heimdall-repo-checks status`, called by bin/heimdall-precheck-bash) accepts.

Before this file the writer and the checker each spelled out the receipt's fields on their own (two jq programs in one script), so a
field could be renamed, retyped or reformatted on one side and still pass review. Now there is a single table of fields, with a type
test and a plain-English "what it must be" for each, and BOTH sides go through it:
  build_receipt()   `run` builds the receipt here and refuses to write one the checker would reject on shape
  verify_receipt()  `status` checks shape first (the very same table), then the bindings, then the verdict
  facts()           the commit-side facts both bind to (HEAD, HEAD's tree, the declaration AS COMMITTED), read from git objects
  DECLARATION, RECEIPT  the two paths, also what bin/lib/hmd_push_target.py looks for when it classifies a repository
test/heimdall-push-gate-per-repo.test.sh walks FIELD_NAMES and CHECK_FIELD_NAMES from here: a receipt written by `run` must pass the
gate, and every field mutated on its own (deleted, retyped, given a wrong value or a malformed one) must fail it.

THE RECEIPT, exactly these fields (a receipt with another one is refused):
  schema       the number 1
  head_sha     the full object id of HEAD (40 lowercase hex digits; 64 in a sha256 repository)
  tree_sha     the full object id of HEAD's tree
  decl_sha256  the sha256 (64 lowercase hex digits) of repo-checks.json AS COMMITTED at HEAD
  dirty        true or false: whether tracked files had uncommitted changes before or after the run, or the declaration on disk was
               not the committed one
  exit_code    an integer, 0 only when every check exited 0
  finished_at  a UTC timestamp, 2026-10-13T12:00:00Z
  checks       a non-empty list of {name, cmd, exit_code, secs}

A COOPERATING-AGENT CONTROL, NOT A SECURITY BOUNDARY. Like heimdall's own .heimdall/receipts/last-sweep.json this is a plain local file:
the three bindings (commit, tree, committed declaration) catch a receipt that is stale, copied from another checkout or commit, left
over from other checks, or written by hand without them. Anyone who can write the file can also write all three values correctly, so
it does not stop a local adversary; the native hook of the repository and CI stay the backstop.

Python 3.7+, standard library only.
"""
import hashlib
import os
import re
import subprocess

DECLARATION = ".heimdall/repo-checks.json"
RECEIPT = ".heimdall/receipts/repo-checks.json"
SCHEMA = 1
GIT_AMBIENT = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")  # a stray one in THIS process must not redirect git
REGULAR_MODES = (b"100644", b"100755")
OID_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
STAMP_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def _int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _seconds(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < 10 ** 9


def _text(value):
    return isinstance(value, str) and value != ""


def _matching(pattern):
    return lambda value: isinstance(value, str) and pattern.fullmatch(value) is not None


# name, test, what the value must be -- the receipt's top level, in the order it is written
FIELDS = (
    ("schema", lambda v: _int(v) and v == SCHEMA, "the number 1"),
    ("head_sha", _matching(OID_RE), "the full object id of HEAD (40 lowercase hex digits, 64 in a sha256 repository)"),
    ("tree_sha", _matching(OID_RE), "the full object id of HEAD's tree (40 lowercase hex digits, 64 in a sha256 repository)"),
    ("decl_sha256", _matching(SHA256_RE), "the sha256 (64 lowercase hex digits) of the declaration, repo-checks.json"),
    ("dirty", lambda v: isinstance(v, bool), "true or false"),
    ("exit_code", _int, "an integer"),
    ("finished_at", _matching(STAMP_RE), "a UTC timestamp like 2026-10-13T12:00:00Z"),
    ("checks", lambda v: isinstance(v, list) and len(v) > 0, "a non-empty list of recorded checks"),
)
# name, test, what the value must be -- each entry of `checks`
CHECK_FIELDS = (
    ("name", _text, "a non-empty string"),
    ("cmd", _text, "a non-empty string"),
    ("exit_code", _int, "an integer"),
    ("secs", _seconds, "a number of seconds, 0 or more"),
)
FIELD_NAMES = tuple(name for name, _, _ in FIELDS)
CHECK_FIELD_NAMES = tuple(name for name, _, _ in CHECK_FIELDS)


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
    for i, check in enumerate(receipt["checks"]):
        if not isinstance(check, dict):
            return "checks[%d] must be an object" % i
        for name, ok, what in CHECK_FIELDS:
            if name not in check:
                return "checks[%d].%s is missing (it must be %s)" % (i, name, what)
            if not ok(check[name]):
                return "checks[%d].%s must be %s" % (i, name, what)
        unknown = sorted(set(check) - set(CHECK_FIELD_NAMES))
        if unknown:
            return "checks[%d] has unknown field(s) %s (each is exactly %s)" % (i, ", ".join(unknown), ", ".join(CHECK_FIELD_NAMES))
    return None


def declaration_problem(declaration):
    """The first thing wrong with a parsed repo-checks.json, or None. It names at least one check; names are unique."""
    if not isinstance(declaration, dict) or not _int(declaration.get("schema")) or declaration.get("schema") != SCHEMA:
        return "it must be a JSON object with \"schema\": 1"
    checks = declaration.get("checks")
    if not isinstance(checks, list) or not checks:
        return "\"checks\" must be a non-empty list"
    names = []
    for i, check in enumerate(checks):
        if not isinstance(check, dict) or not _text(check.get("name")) or not _text(check.get("cmd")):
            return "checks[%d] must be an object with a non-empty \"name\" and \"cmd\"" % i
        names.append(check["name"])
    if len(set(names)) != len(names):
        return "check names must be unique"
    return None


def build_receipt(head_sha, tree_sha, decl_sha256, dirty, exit_code, finished_at, checks):
    """The receipt `run` writes. ValueError when it would not pass shape_problem: a writer cannot emit what the gate would refuse."""
    receipt = {"schema": SCHEMA, "head_sha": head_sha, "tree_sha": tree_sha, "decl_sha256": decl_sha256, "dirty": dirty,
               "exit_code": exit_code, "finished_at": finished_at, "checks": checks}
    problem = shape_problem(receipt)
    if problem:
        raise ValueError(problem)
    return receipt


def verify_receipt(receipt, head_sha, tree_sha, decl_sha256, declared):
    """(True, "") when `receipt` is green AND describes exactly this commit, tree and committed declaration; else (False, why).
    `declared` is the declaration's list of {name, cmd}. Order: shape, then the three bindings, then the verdict."""
    problem = shape_problem(receipt)
    if problem:
        return False, "the receipt is malformed: %s" % problem
    if receipt["head_sha"] != head_sha:
        return False, "STALE: the receipt is for %s, HEAD is %s (commits landed since the checks ran)" % (receipt["head_sha"][:12], head_sha[:12])
    if receipt["tree_sha"] != tree_sha:
        return False, ("the receipt's tree sha (%s) is not the tree of HEAD (%s), so it does not describe this commit's content"
                       % (receipt["tree_sha"][:12], tree_sha[:12]))
    if receipt["decl_sha256"] != decl_sha256:
        return False, ("the declaration changed since the receipt was written (the committed repo-checks.json has sha256 %s, the receipt is for %s)"
                       % (decl_sha256[:12], receipt["decl_sha256"][:12]))
    if receipt["dirty"]:
        return False, "the checks ran with uncommitted tracked changes (dirty is true), so the record does not describe the commit being pushed"
    failing = [c["name"] for c in receipt["checks"] if c["exit_code"] != 0]
    if failing:
        return False, "RED - check(s) failed: %s" % ", ".join(failing)
    if receipt["exit_code"] != 0:
        return False, "RED - the receipt does not record a clean run (exit_code is %d, not 0)" % receipt["exit_code"]
    recorded = [(c["name"], c["cmd"]) for c in receipt["checks"]]
    wanted = [(c["name"], c["cmd"]) for c in declared]
    if recorded != wanted:
        return False, ("the receipt records other checks than the declared ones (the declaration lists %d, the receipt names %d)"
                       % (len(wanted), len(recorded)))
    return True, ""


PUSHED_NONE = "-"       # a push that sends no commit (a deletion)
PUSHED_UNKNOWN = "?"    # a push whose source commits cannot be listed


def render_pushed(pushed):
    """The text the resolver gives the hook and the hook gives `status --pushes`: the full object ids of the commits a push names as its
    sources, comma separated; "-" when no commit travels; "?" when `pushed` is None (the commits cannot be listed)."""
    if pushed is None:
        return PUSHED_UNKNOWN
    return ",".join(pushed) if pushed else PUSHED_NONE


def parse_pushed(text):
    """render_pushed's inverse: a list of ids, or None for "?" and for anything that is not exactly its output (an empty argument, a
    malformed or abbreviated id): what cannot be read is not modelled."""
    if text == PUSHED_NONE:
        return []
    ids = text.split(",")
    return ids if all(OID_RE.fullmatch(i) for i in ids) else None


def verify_pushed(receipt, pushed):
    """(True, "") when every commit a push names as a source is the one commit `receipt` was recorded for; else (False, why). `pushed` is
    parse_pushed's answer: None means the commits cannot be listed (--all, --mirror, --tags, a wildcard, push configuration that picks the
    refs), and a receipt that attests ONE commit cannot cover them. Call it only on a receipt verify_receipt accepted."""
    if pushed is None:
        return False, ("this push names commits that cannot be tied to the receipt (--all, --mirror, --tags, a refspec with a wildcard, an "
                       "option this cannot read, or push configuration that picks the refs); a receipt attests one commit, so push one "
                       "named branch of it, for example: git push <remote> HEAD")
    for sha in pushed:
        if sha != receipt["head_sha"]:
            return False, ("the push carries %s but the receipt is for %s: a receipt attests the one commit it was recorded for, so every "
                           "commit a push names must be it. Push that commit, or record the checks at the commit you are pushing"
                           % (sha[:12], receipt["head_sha"][:12]))
    return True, ""


def git_env(extra):
    env = dict((k, v) for k, v in os.environ.items() if k not in GIT_AMBIENT)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env.update(extra)
    return env


def run_git_bytes(args, cwd, env, timeout=30):
    """(exit status, stdout bytes) of git, or None when it cannot run at all (no git, no such directory, a timeout)."""
    try:
        done = subprocess.run(["git"] + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.returncode, done.stdout


def run_git(args, cwd, env, timeout=30):
    """run_git_bytes with the output decoded."""
    got = run_git_bytes(args, cwd, env, timeout)
    return None if got is None else (got[0], got[1].decode("utf-8", "replace"))


class Unreadable(Exception):
    """HEAD, its tree or its declaration cannot be read from git."""


class Facts(object):
    """What a receipt binds to, read from git OBJECTS (never the work tree): HEAD, HEAD's tree, and repo-checks.json as committed.
    declaration is its bytes, or None when `state` is not "ok": "absent" (HEAD has none) or "irregular" (a link, a submodule, a directory)."""
    __slots__ = ("head", "tree", "declaration", "state")

    def __init__(self, head, tree, declaration, state):
        self.head, self.tree, self.declaration, self.state = head, tree, declaration, state

    @property
    def decl_sha256(self):
        return sha256_hex(self.declaration)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def facts(top):
    env = git_env({})
    head = run_git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], top, env)
    tree = run_git(["rev-parse", "-q", "--verify", "HEAD^{tree}"], top, env)
    if head is None or tree is None or head[0] != 0 or tree[0] != 0 or not head[1].strip() or not tree[1].strip():
        raise Unreadable("cannot read HEAD of %s (no commits yet?)" % top)
    listed = run_git_bytes(["ls-tree", "-z", "HEAD", "--", DECLARATION], top, env)
    if listed is None or listed[0] != 0:
        raise Unreadable("cannot list the tree of HEAD in %s" % top)
    entry = [rec for rec in listed[1].split(b"\0") if rec]
    if not entry:
        return Facts(head[1].strip(), tree[1].strip(), None, "absent")
    meta = entry[0].partition(b"\t")[0].split(b" ")
    if len(meta) != 3 or meta[1] != b"blob" or meta[0] not in REGULAR_MODES:
        return Facts(head[1].strip(), tree[1].strip(), None, "irregular")
    blob = run_git_bytes(["cat-file", "blob", meta[2].decode("ascii", "replace")], top, env)
    if blob is None or blob[0] != 0:
        raise Unreadable("cannot read %s at HEAD in %s" % (DECLARATION, top))
    return Facts(head[1].strip(), tree[1].strip(), blob[1], "ok")
